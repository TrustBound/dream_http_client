-module(dream_http_shim).

%% The values this module returns to Gleam are Gleam values:
%%
%% - a transport error is a `client.TransportError`, for example
%%   `{timed_out, TimeoutMs}` or `remote_closed`. An HTTP/2 error code in it
%%   is a `client.Http2ErrorCode`, for example `refused_stream`;
%% - a stream failure is a `client.StreamFailure`:
%%   `{transport_failure, TransportError}` or
%%   `{http_failure, {http_response, Status, [{header, Name, Value}], Body}}`,
%%   where Body is the exact bytes of the response body;
%% - a pull stream event is an `internal.StreamEvent`:
%%   `{chunk, Data}`, `{done, Trailers}` or `{failed, StreamFailure}`;
%% - a translator message is a `client.TranslatorMessage`:
%%   `{translator_start, Status, Headers}`, `{translator_chunk, Data}`,
%%   `{translator_end, Trailers}` or `{translator_error, StreamFailure}`.

-export([request_sync/8, request_stream/8, fetch_next/1, fetch_start_headers/1,
         request_stream_messages/8, grant_next/1, configure_transport/1]).

-define(MAX_REDIRECTS, 5).

%% The number of data messages of a stream that gun reads ahead of the
%% caller. See request/9.
-define(STREAM_WINDOW, 16).

%% The state of the process that owns a pull-based stream.
%% `events` holds the stream events that no caller has fetched yet, and
%% `waiter` is the caller that waits for the next event. `requester` is the
%% process that started the stream: the owner stops when it stops.
%% `lease` is the lease on the connection (see dream_http_conn_manager).
%% `received` is the number of data messages that gun sent for the stream.
-record(owner, {requester, conn, ref, lease, status, headers, zlib, timeout,
                received = 0, events = [], waiter = none}).

%% ============================================================================
%% Requests and redirects
%% ============================================================================

%% `flow` is gun's flow control for the response body. `infinity`: gun reads
%% the body as fast as the server sends it. A number: gun reads that many
%% data messages, then stops reading from the server until
%% gun:update_flow/3 allows more. A stream uses ?STREAM_WINDOW and allows
%% one more message for each chunk the caller takes. So at most that many
%% messages wait in memory, and the rest of the response waits in the
%% network until the caller takes the next chunk.
%%
%% On HTTP/1.1, gun stops reading the socket when the flow is 0, and does
%% not start again when the stream ends at that moment: the connection
%% cannot carry another request. The flow can only reach 0 when gun sent
%% ?STREAM_WINDOW data messages or more, and nobody outside gun can know
%% if it did (an update_flow can arrive after the end of the stream). So a
%% stream that got that many data messages gives its lease back with
%% release_paused/1, and the pool does not use that HTTP/1.1 connection
%% again. A shorter stream leaves the connection for the next request.
request(Method, Url, Headers, Body, TimeoutMs, ConnectTimeoutMs, AutoRedirect, Settings, Flow) ->
    #{method => Method, url => Url, headers => maybe_add_accept_encoding(Headers),
      body => Body, timeout => TimeoutMs, connect_timeout => ConnectTimeoutMs,
      auto_redirect => AutoRedirect, settings => Settings, flow => Flow}.

request_options(infinity) -> #{};
request_options(Flow) -> #{flow => Flow}.

%% Sends the request and follows redirects. Returns the response head of the
%% last response and the lease on its connection, or {error, TransportError}.
open_response(_Request, Redirects) when Redirects >= ?MAX_REDIRECTS ->
    {error, {unexpected, <<"Too many redirects (max 5)">>}};
open_response(Request, Redirects) ->
    #{method := Method, url := Url, body := Body, timeout := TimeoutMs,
      auto_redirect := AutoRedirect, flow := Flow} = Request,
    case open_stream(Request, 1) of
        {ok, ConnPid, StreamRef, Lease, IsFin, Status, RespHeaders} = Response ->
            case AutoRedirect andalso redirect_location(Status, RespHeaders) of
                {ok, Location} ->
                    _ = finish_body(Lease, await_body(ConnPid, StreamRef, IsFin, TimeoutMs, Flow)),
                    Next = Request#{url := uri_string:resolve(Location, Url),
                                    method := redirect_method(Status, Method),
                                    body := redirect_body(Status, Body)},
                    open_response(Next, Redirects + 1);
                _ ->
                    Response
            end;
        Error ->
            Error
    end.

%% Sends one request. When the request gets no response head, the client
%% sends it once more on another connection only when that is safe (RFC 9110,
%% section 9.2.2): the server did not process it, or its method is idempotent
%% and the connection closed. failure/1 says which case an error is.
open_stream(Request, RetriesLeft) ->
    #{method := Method, url := Url, headers := Headers, body := Body,
      timeout := TimeoutMs, connect_timeout := ConnectTimeoutMs,
      settings := Settings, flow := Flow} = Request,
    case parse_url(Url) of
        {ok, Scheme, Host, Port, PathQs} ->
            GunOpts = build_gun_opts(TimeoutMs, ConnectTimeoutMs, Settings),
            case get_or_open_connection(Scheme, Host, Port, GunOpts) of
                {ok, ConnPid, _Protocol, Lease} ->
                    StreamRef = gun:request(ConnPid, method_binary(Method), PathQs, Headers, Body,
                                            request_options(Flow)),
                    case await_final_response(ConnPid, StreamRef, TimeoutMs) of
                        {response, IsFin, Status, RespHeaders} ->
                            {ok, ConnPid, StreamRef, Lease, IsFin, Status, RespHeaders};
                        {error, Reason} ->
                            {Connection, Delivery} = failure(Reason),
                            give_back(Connection, Lease),
                            case RetriesLeft > 0 andalso may_send_again(Delivery, Method) of
                                true ->
                                    open_stream(Request, RetriesLeft - 1);
                                false ->
                                    {error, transport_error(Reason, TimeoutMs)}
                            end
                    end;
                {error, Reason} ->
                    {error, connect_error(Reason)}
            end;
        {error, Reason} ->
            {error, transport_error(Reason, TimeoutMs)}
    end.

%% Waits for the final response of a request. A server can send one or
%% more 1xx responses first, for example 103 Early Hints (RFC 9110, section
%% 15.2). They are not the answer to the request, so the client skips them.
%% The timeout starts again after each one.
await_final_response(ConnPid, StreamRef, TimeoutMs) ->
    case gun:await(ConnPid, StreamRef, TimeoutMs) of
        {inform, _Status, _Headers} -> await_final_response(ConnPid, StreamRef, TimeoutMs);
        Result -> Result
    end.

%% Reads the whole body of a response.
await_body(_ConnPid, _StreamRef, fin, _TimeoutMs, _Flow) ->
    {ok, <<>>};
await_body(ConnPid, StreamRef, nofin, TimeoutMs, infinity) ->
    case gun:await_body(ConnPid, StreamRef, TimeoutMs) of
        {ok, Body, _Trailers} -> {ok, Body};
        Result -> Result
    end;
await_body(ConnPid, StreamRef, nofin, TimeoutMs, _Flow) ->
    await_flow_body(ConnPid, StreamRef, TimeoutMs, <<>>).

%% Reads the whole body of a response that has flow control: each data
%% message allows the next one.
await_flow_body(ConnPid, StreamRef, TimeoutMs, Acc) ->
    case gun:await(ConnPid, StreamRef, TimeoutMs) of
        {data, nofin, Data} ->
            gun:update_flow(ConnPid, StreamRef, 1),
            await_flow_body(ConnPid, StreamRef, TimeoutMs, <<Acc/binary, Data/binary>>);
        {data, fin, Data} ->
            {ok, <<Acc/binary, Data/binary>>};
        {trailers, _Trailers} ->
            {ok, Acc};
        {error, Reason} ->
            {error, Reason}
    end.

%% Gives the lease back after a body read: released when the body is
%% complete, abandoned when the read failed. Returns the read result.
finish_body(Lease, Result = {ok, _Body}) ->
    dream_http_conn_manager:release(Lease),
    Result;
finish_body(Lease, Result) ->
    dream_http_conn_manager:abandon(Lease),
    Result.

%% Gives the lease back after the last event of a stream. Received is the
%% number of data messages gun sent for the stream. See request/9.
finish_stream(Lease, {done, _Trailers}, Received) when Received >= ?STREAM_WINDOW ->
    dream_http_conn_manager:release_paused(Lease);
finish_stream(Lease, {done, _Trailers}, _Received) ->
    dream_http_conn_manager:release(Lease);
finish_stream(Lease, {failed, _Failure}, _Received) ->
    dream_http_conn_manager:abandon(Lease).

redirect_location(Status, Headers)
        when Status =:= 301; Status =:= 302; Status =:= 303; Status =:= 307; Status =:= 308 ->
    case lists:keyfind(<<"location">>, 1, Headers) of
        {_, Location} -> {ok, Location};
        false -> none
    end;
redirect_location(_Status, _Headers) ->
    none.

redirect_method(Status, _Method) when Status =:= 301; Status =:= 302; Status =:= 303 -> get;
redirect_method(_Status, Method) -> Method.

redirect_body(Status, _Body) when Status =:= 301; Status =:= 302; Status =:= 303 -> <<>>;
redirect_body(_Status, Body) -> Body.

%% ============================================================================
%% Synchronous (blocking) request
%% ============================================================================

request_sync(Method, Url, Headers, Body, TimeoutMs, ConnectTimeoutMs, AutoRedirect, Settings) ->
    Request = request(Method, Url, Headers, Body, TimeoutMs, ConnectTimeoutMs, AutoRedirect, Settings,
                      infinity),
    case open_response(Request, 0) of
        {ok, ConnPid, StreamRef, Lease, IsFin, Status, RespHeaders} ->
            case finish_body(Lease, await_body(ConnPid, StreamRef, IsFin, TimeoutMs, infinity)) of
                {ok, RespBody} ->
                    {DecompBody, CleanHeaders} = maybe_decompress_response(RespBody, RespHeaders),
                    {ok, {Status, CleanHeaders, DecompBody}};
                {error, Reason} ->
                    {error, transport_error(Reason, TimeoutMs)}
            end;
        Error ->
            Error
    end.

%% ============================================================================
%% Streaming responses (shared by the pull and the message streams)
%% ============================================================================

%% Returns the head of a 2xx response and the lease on its connection, or
%% {error, StreamFailure}.
open_streaming_response(Request = #{timeout := TimeoutMs, flow := Flow}) ->
    case open_response(Request, 0) of
        {ok, _ConnPid, _StreamRef, _Lease, _IsFin, Status, _RespHeaders} = Response
                when Status >= 200, Status < 300 ->
            Response;
        {ok, ConnPid, StreamRef, Lease, IsFin, Status, RespHeaders} ->
            Body = case finish_body(Lease, await_body(ConnPid, StreamRef, IsFin, TimeoutMs, Flow)) of
                {ok, FullBody} -> FullBody;
                {error, _Reason} -> <<>>
            end,
            {error, {http_failure, {http_response, Status, gleam_headers(RespHeaders), Body}}};
        {error, Error} ->
            {error, {transport_failure, Error}}
    end.

%% Turns one gun message of a stream into stream events.
%% Returns {Events, ZlibCtx}. The last event of a stream is `done` or `failed`.
stream_events({gun_data, _ConnPid, _StreamRef, nofin, Data}, ZlibCtx) ->
    {[{chunk, inflate(ZlibCtx, Data)}], ZlibCtx};
stream_events({gun_data, _ConnPid, _StreamRef, fin, Data}, ZlibCtx) ->
    Chunk = inflate(ZlibCtx, Data),
    close_zlib(ZlibCtx),
    {[{chunk, Chunk} || Chunk =/= <<>>] ++ [{done, []}], undefined};
stream_events({gun_trailers, _ConnPid, _StreamRef, Trailers}, ZlibCtx) ->
    close_zlib(ZlibCtx),
    {[{done, Trailers}], undefined};
stream_events({gun_error, ConnPid, _StreamRef, Reason}, ZlibCtx) ->
    stream_events({gun_error, ConnPid, Reason}, ZlibCtx);
stream_events({gun_error, _ConnPid, Reason}, ZlibCtx) ->
    close_zlib(ZlibCtx),
    {[{failed, {transport_failure, transport_error(Reason, 0)}}], undefined}.

%% ============================================================================
%% Pull-based streaming
%% ============================================================================

request_stream(Method, Url, Headers, Body, TimeoutMs, ConnectTimeoutMs, AutoRedirect, Settings) ->
    Request = request(Method, Url, Headers, Body, TimeoutMs, ConnectTimeoutMs, AutoRedirect, Settings,
                      ?STREAM_WINDOW),
    Requester = self(),
    spawn(fun() -> stream_owner_init(Request, Requester) end).

stream_owner_init(Request = #{timeout := TimeoutMs}, Requester) ->
    erlang:monitor(process, Requester),
    case open_streaming_response(Request) of
        {ok, ConnPid, StreamRef, Lease, IsFin, Status, RespHeaders} ->
            Owner = #owner{requester = Requester, conn = ConnPid, ref = StreamRef,
                           lease = Lease, status = Status, headers = RespHeaders, zlib = stream_zlib(RespHeaders),
                           timeout = TimeoutMs},
            stream_owner_loop(Owner#owner{events = [{done, []} || IsFin =:= fin]});
        {error, Failure} ->
            exit({stream_start_failed, Failure})
    end.

%% Gives each fetched event to its caller. gun reads at most ?STREAM_WINDOW
%% data messages of the stream ahead (flow control), and one more for each
%% chunk a caller takes, so the owner never holds more than that. The last
%% event of a stream is `done` or `failed`. The owner gives the lease back,
%% then gives the last event to its caller and stops. So the lease is back
%% before the caller sees the end of the stream. When the owner stops
%% before that, the connection manager sees the lease abandoned.
stream_owner_loop(Owner = #owner{waiter = Waiter, events = [{chunk, _Data} = Event | Events]})
        when Waiter =/= none ->
    Waiter ! {stream_event, self(), Event},
    gun:update_flow(Owner#owner.conn, Owner#owner.ref, 1),
    stream_owner_loop(Owner#owner{waiter = none, events = Events});
stream_owner_loop(Owner = #owner{waiter = Waiter, events = [LastEvent | _Events]}) when Waiter =/= none ->
    finish_stream(Owner#owner.lease, LastEvent, Owner#owner.received),
    Waiter ! {stream_event, self(), LastEvent};
stream_owner_loop(Owner = #owner{requester = Requester, conn = ConnPid, ref = StreamRef,
                                 waiter = Waiter, timeout = TimeoutMs}) ->
    receive
        {'DOWN', _MonitorRef, process, Requester, _Reason} ->
            %% Nobody reads the stream any more. The server can stop it.
            gun:cancel(ConnPid, StreamRef);
        {fetch_next, From} ->
            stream_owner_loop(Owner#owner{waiter = From});
        {fetch_start_headers, From} ->
            From ! {stream_start_headers, self(), {Owner#owner.status, Owner#owner.headers}},
            stream_owner_loop(Owner);
        Message = {gun_data, ConnPid, StreamRef, _IsFin, _Data} ->
            stream_owner_loop(add_events(Owner#owner{received = Owner#owner.received + 1}, Message));
        Message = {Tag, ConnPid, StreamRef, _Value} when Tag =:= gun_trailers; Tag =:= gun_error ->
            stream_owner_loop(add_events(Owner, Message));
        Message = {gun_error, ConnPid, _Reason} ->
            stream_owner_loop(add_events(Owner, Message))
    after wait_timeout(Waiter, TimeoutMs) ->
        %% A timeout ends the stream, as in the translator.
        close_zlib(Owner#owner.zlib),
        gun:cancel(ConnPid, StreamRef),
        stream_owner_loop(Owner#owner{zlib = undefined,
                                      events = [{failed, {transport_failure, {timed_out, TimeoutMs}}}]})
    end.

add_events(Owner = #owner{events = Events, zlib = ZlibCtx}, Message) ->
    {NewEvents, NewZlibCtx} = stream_events(Message, ZlibCtx),
    Owner#owner{events = Events ++ NewEvents, zlib = NewZlibCtx}.

%% No waiting caller, or no credit: nothing to time.
wait_timeout(none, _TimeoutMs) -> infinity;
wait_timeout(Credit, _TimeoutMs) when is_integer(Credit), Credit =< 0 -> infinity;
wait_timeout(_WaiterOrCredit, TimeoutMs) -> TimeoutMs.

fetch_next(Owner) ->
    MonitorRef = erlang:monitor(process, Owner),
    Owner ! {fetch_next, self()},
    receive
        {stream_event, Owner, Event} ->
            erlang:demonitor(MonitorRef, [flush]),
            Event;
        {'DOWN', MonitorRef, process, Owner, Reason} ->
            {failed, down_failure(Reason)}
    end.

fetch_start_headers(Owner) ->
    MonitorRef = erlang:monitor(process, Owner),
    Owner ! {fetch_start_headers, self()},
    receive
        {stream_start_headers, Owner, StatusAndHeaders} ->
            erlang:demonitor(MonitorRef, [flush]),
            {ok, StatusAndHeaders};
        {'DOWN', MonitorRef, process, Owner, Reason} ->
            {error, down_failure(Reason)}
    end.

down_failure({stream_start_failed, Failure}) -> Failure;
down_failure(Reason) -> {transport_failure, {process_down, inspect(Reason)}}.

%% ============================================================================
%% Message-based streaming
%% ============================================================================

%% Starts a translator process that sends the stream to the calling process
%% (the stream process) as `{http, TranslatorMessage}` messages.
%%
%% The translator is linked to the stream process and traps exits. When the
%% stream process stops, for example after a cancel, the translator cancels
%% the gun stream and stops too. When the translator crashes, the link stops
%% the stream process. The translator gives the lease on the connection back
%% after the last event. When it stops before that, the connection manager
%% sees the lease abandoned.
%%
%% gun reads at most ?STREAM_WINDOW data messages of the stream ahead (flow
%% control). The stream process calls grant_next/1 after it handled a
%% chunk, and gun then reads one more. A slow handler slows the server
%% down, and chunks do not collect in memory. Returns the translator.
request_stream_messages(Method, Url, Headers, Body, TimeoutMs, ConnectTimeoutMs, AutoRedirect, Settings) ->
    Request = request(Method, Url, Headers, Body, TimeoutMs, ConnectTimeoutMs, AutoRedirect, Settings,
                      ?STREAM_WINDOW),
    StreamPid = self(),
    spawn_link(fun() -> translator_init(Request, StreamPid) end).

%% The stream process handled a chunk. The translator lets gun read the
%% next data message.
grant_next(Translator) ->
    Translator ! grant_next,
    nil.

translator_init(Request = #{timeout := TimeoutMs}, StreamPid) ->
    process_flag(trap_exit, true),
    case open_streaming_response(Request) of
        {ok, ConnPid, StreamRef, Lease, IsFin, Status, RespHeaders} ->
            StreamPid ! {http, {translator_start, Status, gleam_headers(RespHeaders)}},
            Translator = {ConnPid, StreamRef, Lease, StreamPid, TimeoutMs},
            case IsFin of
                fin -> finish_stream(Lease, send_events(Translator, [{done, []}]), 0);
                nofin -> translator_loop(Translator, stream_zlib(RespHeaders), {?STREAM_WINDOW, 0})
            end;
        {error, Failure} ->
            StreamPid ! {http, {translator_error, Failure}}
    end.

%% Credit is the number of data messages the translator allowed and did not
%% get yet. Received is the number of data messages it got. The request
%% timeout runs only while credit is left: with no credit, the translator
%% waits for the stream process, not for the server.
translator_loop(Translator = {ConnPid, StreamRef, _Lease, StreamPid, TimeoutMs}, ZlibCtx,
                Counts = {Credit, Received}) ->
    receive
        grant_next ->
            gun:update_flow(ConnPid, StreamRef, 1),
            translator_loop(Translator, ZlibCtx, {Credit + 1, Received});
        Message = {gun_data, ConnPid, StreamRef, _IsFin, _Data} ->
            translate(Translator, Message, ZlibCtx, {Credit - 1, Received + 1});
        Message = {Tag, ConnPid, StreamRef, _Value} when Tag =:= gun_trailers; Tag =:= gun_error ->
            translate(Translator, Message, ZlibCtx, Counts);
        Message = {gun_error, ConnPid, _Reason} ->
            translate(Translator, Message, ZlibCtx, Counts);
        {'EXIT', StreamPid, _Reason} ->
            close_zlib(ZlibCtx),
            gun:cancel(ConnPid, StreamRef)
    after wait_timeout(Credit, TimeoutMs) ->
        close_zlib(ZlibCtx),
        gun:cancel(ConnPid, StreamRef),
        StreamPid ! {http, {translator_error, {transport_failure, {timed_out, TimeoutMs}}}}
    end.

translate(Translator = {_ConnPid, _StreamRef, Lease, _StreamPid, _TimeoutMs}, Message, ZlibCtx,
          Counts = {_Credit, Received}) ->
    {Events, NewZlibCtx} = stream_events(Message, ZlibCtx),
    case send_events(Translator, Events) of
        {chunk, _Data} -> translator_loop(Translator, NewZlibCtx, Counts);
        LastEvent -> finish_stream(Lease, LastEvent, Received)
    end.

%% Sends the events to the stream process and returns the last one.
send_events({_ConnPid, _StreamRef, _Lease, StreamPid, _TimeoutMs}, Events) ->
    lists:foreach(fun(Event) -> StreamPid ! {http, translator_message(Event)} end, Events),
    lists:last(Events).

translator_message({chunk, Data}) -> {translator_chunk, Data};
translator_message({done, Trailers}) -> {translator_end, gleam_headers(Trailers)};
translator_message({failed, Failure}) -> {translator_error, Failure}.

%% ============================================================================
%% Transport configuration
%% ============================================================================

configure_transport(Config) ->
    %% Config is a Gleam opaque type = Erlang tuple {transport_config, F1, F2, ...}
    ets:insert(dream_http_client_transport_config, {config, Config}),
    dream_http_client_log:set_level(map_log_level(element(13, Config))),
    dream_http_conn_manager:idle_timeout_changed(),
    nil.

map_log_level(log_debug) -> debug;
map_log_level(log_info) -> info;
map_log_level(log_warning) -> warning;
map_log_level(log_error) -> error;
map_log_level(log_none) -> none.

get_transport_config() ->
    case ets:lookup(dream_http_client_transport_config, config) of
        [{config, Config}] ->
            %% Gleam TransportConfig tuple: {transport_config, MaxConn, IdleTimeout, DefaultConnTimeout,
            %%   DomainLookupTimeout, TlsHandshakeTimeout, Keepalive,
            %%   KeepaliveTolerance, MaxConcurrentStreams, InitConnWindowSize, InitStreamWindowSize,
            %%   ClosingTimeout, LogLevel, DefaultCertificateAuthorityFile}
            #{max_connections => element(2, Config),
              idle_timeout => element(3, Config),
              connect_timeout => element(4, Config),
              domain_lookup_timeout => element(5, Config),
              tls_handshake_timeout => element(6, Config),
              keepalive => element(7, Config),
              keepalive_tolerance => element(8, Config),
              max_concurrent_streams => element(9, Config),
              initial_connection_window_size => element(10, Config),
              initial_stream_window_size => element(11, Config),
              closing_timeout => element(12, Config),
              certificate_authority_file => element(14, Config)};
        [] ->
            #{max_connections => 50,
              idle_timeout => 60000,
              connect_timeout => 15000,
              domain_lookup_timeout => 5000,
              tls_handshake_timeout => 10000,
              keepalive => 30000,
              keepalive_tolerance => 3,
              max_concurrent_streams => 100,
              initial_connection_window_size => 65535,
              initial_stream_window_size => 65535,
              closing_timeout => 15000,
              certificate_authority_file => none}
    end.

%% ============================================================================
%% Connection management helpers
%% ============================================================================

get_or_open_connection(Scheme, Host, Port, GunOpts) ->
    TransportConfig = get_transport_config(),
    %% The client-wide certificate authority file is `none` or `{some, File}`.
    %% A per-request file in GunOpts wins over it.
    Defaults = case maps:get(certificate_authority_file, TransportConfig) of
        {some, File} -> TransportConfig#{certificate_authority_file => File};
        none -> maps:remove(certificate_authority_file, TransportConfig)
    end,
    FullOpts = maps:merge(Defaults, GunOpts),
    dream_http_conn_manager:ensure_connection(Scheme, Host, Port, FullOpts).

%% Settings is the Gleam `internal.ConnectionSettings` record:
%% {connection_settings, Protocols, CertificateAuthorityFile, Pool}.
%% `request_timeout` is how long the request may wait for room in the pool.
%% A request with a pool of its own carries the reference and the
%% connection limit of that pool. The limit wins over the one of the transport config.
build_gun_opts(TimeoutMs, ConnectTimeoutMs,
               {connection_settings, Protocols, CertificateAuthorityFile, Pool}) ->
    Opts = #{connect_timeout => ConnectTimeoutMs, request_timeout => TimeoutMs},
    WithProtocols = case Protocols of
        default -> Opts;
        _ -> Opts#{protocols => Protocols}
    end,
    WithAuthority = case CertificateAuthorityFile of
        none -> WithProtocols;
        {some, File} -> WithProtocols#{certificate_authority_file => File}
    end,
    case Pool of
        none -> WithAuthority;
        {some, {PoolId, MaxConnections}} ->
            WithAuthority#{pool => PoolId, max_connections => MaxConnections}
    end.

method_binary(Method) ->
    string:uppercase(atom_to_binary(Method, utf8)).

%% ============================================================================
%% URL parsing
%% ============================================================================

%% Url is a binary, or the error that uri_string:resolve/2 returned for a
%% redirect location.
parse_url({error, Reason, _Term}) ->
    {error, Reason};
parse_url(Url) ->
    case uri_string:parse(Url) of
        #{scheme := Scheme, host := Host, path := Path} = Parsed ->
            Port = maps:get(port, Parsed, default_port(Scheme)),
            NonEmptyPath = case Path of
                <<>> -> <<"/">>;
                _ -> Path
            end,
            PathQs = case Parsed of
                #{query := Query} -> <<NonEmptyPath/binary, "?", Query/binary>>;
                _ -> NonEmptyPath
            end,
            {ok, binary_to_atom(Scheme, utf8), unicode:characters_to_list(Host), Port, PathQs};
        {error, Reason, _Term} ->
            {error, Reason}
    end.

default_port(<<"https">>) -> 443;
default_port(<<"http">>) -> 80.

%% ============================================================================
%% Headers
%% ============================================================================

gleam_headers(Headers) ->
    [{header, Name, Value} || {Name, Value} <- Headers].

maybe_add_accept_encoding(Headers) ->
    HasAcceptEncoding = lists:any(
        fun({K, _V}) -> string:lowercase(K) =:= <<"accept-encoding">> end,
        Headers),
    case HasAcceptEncoding of
        true -> Headers;
        false -> Headers ++ [{<<"accept-encoding">>, <<"gzip, deflate">>}]
    end.

%% gun gives response header names in lower case.
get_content_encoding(Headers) ->
    case lists:keyfind(<<"content-encoding">>, 1, Headers) of
        {_, Value} -> string:lowercase(string:trim(Value));
        false -> <<>>
    end.

%% ============================================================================
%% Decompression
%% ============================================================================

maybe_decompress_response(<<>>, Headers) ->
    {<<>>, Headers};
maybe_decompress_response(Body, Headers) ->
    case get_content_encoding(Headers) of
        <<"gzip">> ->
            try_decompress(fun zlib:gunzip/1, Body, Headers);
        <<"deflate">> ->
            try_decompress(fun zlib:uncompress/1, Body, Headers);
        <<"identity">> -> {Body, Headers};
        <<>> -> {Body, Headers};
        Other ->
            dream_http_client_log:warning(
              "unrecognized Content-Encoding, passing through raw bytes: ~s", [Other]),
            {Body, Headers}
    end.

try_decompress(DecompressFn, Body, Headers) ->
    try
        Decompressed = DecompressFn(Body),
        {Decompressed, [Header || Header = {Name, _} <- Headers, Name =/= <<"content-encoding">>]}
    catch
        _:_ ->
            dream_http_client_log:warning("decompression failed, passing through raw bytes", []),
            {Body, Headers}
    end.

stream_zlib(Headers) ->
    case get_content_encoding(Headers) of
        <<"gzip">> -> open_zlib(31);
        <<"deflate">> -> open_zlib(15);
        <<>> -> undefined;
        <<"identity">> -> undefined;
        Other ->
            dream_http_client_log:warning(
              "unrecognized Content-Encoding for stream, passing through raw bytes: ~s", [Other]),
            undefined
    end.

open_zlib(WindowBits) ->
    Z = zlib:open(),
    ok = zlib:inflateInit(Z, WindowBits),
    Z.

inflate(undefined, Data) -> Data;
inflate(ZlibCtx, Data) -> iolist_to_binary(zlib:inflate(ZlibCtx, Data)).

close_zlib(undefined) -> ok;
close_zlib(ZlibCtx) -> zlib:close(ZlibCtx).

%% ============================================================================
%% Errors
%% ============================================================================

%% Sorts the error of a request that got no response head. Returns
%% {Connection, Delivery}.
%%
%% Connection is what the pool does with the connection (see give_back/2):
%% `stale` when the server closed it, sent a GOAWAY, or its process stopped;
%% `refused` when the stream was refused; `other` for every other error.
%%
%% Delivery is what the client knows about the request:
%% - `not_processed`: the server did not process it, so any method can be
%%   sent again (RFC 9113, sections 6.8 and 8.7).
%% - `maybe_processed`: the connection closed after gun could have written
%%   the request. The server can have processed it, so only an idempotent
%%   method is sent again (RFC 9110, section 9.2.2).
%% - `failed`: any other error. The request is not sent again.
%%
%% The terms are the ones gun 2 gives:
%% - A GOAWAY ends only the streams above its last stream identifier, with
%%   {goaway, Code, HumanReadable} (gun_http2:goaway/2 and goaway_streams/6).
%%   The streams that the server kept continue.
%% - A RST_STREAM from the server gives {stream_error, Code, HumanReadable}
%%   (gun_http2:rst_stream_frame/5). Only REFUSED_STREAM means "not
%%   processed". gun gives `too_many_streams` when the stream limit of the
%%   server is reached, and does not send the request
%%   (gun_http2:request_common/8).
%% - When the socket closes, gun first ends each stream it sent with
%%   `closed` or {closed, SocketError} (gun:disconnect/2, the close/4
%%   functions of gun_http and gun_http2), and then stops by itself with
%%   `normal` or {shutdown, Reason} (gun:not_connected/3, retry is 0). A
%%   request that sees that stop with no error before it was never written.
%%   {closed, SocketError} is a socket that failed, and is not sent again.
%%   `noproc`: the process was gone before the request.
%% - `shutdown` comes from outside gun, for example its supervisor. The
%%   process can have written the request before it stopped.
failure({stream_error, {goaway, _Code, _HumanReadable}}) -> {stale, not_processed};
failure({stream_error, {stream_error, Code, _HumanReadable}})
        when Code =:= refused_stream; Code =:= too_many_streams -> {refused, not_processed};
failure({down, Reason}) when Reason =:= normal; Reason =:= noproc; element(1, Reason) =:= shutdown ->
    {stale, not_processed};
failure({stream_error, closed}) -> {stale, maybe_processed};
failure({down, shutdown}) -> {stale, maybe_processed};
failure(_Reason) -> {other, failed}.

%% True when a request that failed in this way can be sent once more.
may_send_again(not_processed, _Method) -> true;
may_send_again(maybe_processed, Method) -> is_idempotent(Method);
may_send_again(failed, _Method) -> false.

%% The idempotent methods of RFC 9110, section 9.2.2.
is_idempotent(Method) -> lists:member(Method, [get, head, options, trace, put, delete]).

%% Gives the lease of a failed request back to the pool.
give_back(stale, Lease) -> dream_http_conn_manager:retire(Lease);
give_back(refused, Lease) -> dream_http_conn_manager:refuse(Lease);
give_back(other, Lease) -> dream_http_conn_manager:abandon(Lease).

%% Turns a gun error into a `client.TransportError`. gun:await/3 and
%% gun:await_body/3 wrap the reason of the gun_error message in
%% {stream_error, Reason} or {connection_error, Reason}.
transport_error({stream_error, Reason}, TimeoutMs) -> transport_error(Reason, TimeoutMs);
transport_error({connection_error, Reason}, TimeoutMs) -> transport_error(Reason, TimeoutMs);
transport_error(timeout, TimeoutMs) -> {timed_out, TimeoutMs};
%% gun gives `closed`, or {closed, SocketError} when the socket failed.
transport_error(Reason, _TimeoutMs) when Reason =:= closed; element(1, Reason) =:= closed ->
    remote_closed;
transport_error({down, Reason}, _TimeoutMs) -> {process_down, inspect(Reason)};
transport_error({stream_error, Code, HumanReadable}, _TimeoutMs) ->
    {stream_reset, http2_error_code(Code), atom_to_binary(HumanReadable, utf8)};
transport_error({goaway, Code, HumanReadable}, _TimeoutMs) ->
    {goaway, http2_error_code(Code), atom_to_binary(HumanReadable, utf8)};
transport_error({Code, HumanReadable}, _TimeoutMs) when is_atom(Code), is_atom(HumanReadable) ->
    {connection_error, http2_error_code(Code), atom_to_binary(HumanReadable, utf8)};
transport_error(Reason, _TimeoutMs) ->
    {unexpected, inspect(Reason)}.

%% Turns the name gun gives an HTTP/2 error code into a
%% `client.Http2ErrorCode`. The names are those of cow_http2, and all but
%% one are also the names of the Gleam constructors.
http2_error_code(http_1_1_required) ->
    http11_required;
http2_error_code(Code) ->
    Known = [no_error, protocol_error, internal_error, flow_control_error, settings_timeout,
             stream_closed, frame_size_error, refused_stream, cancel, compression_error,
             connect_error, enhance_your_calm, inadequate_security],
    case lists:member(Code, Known) of
        true -> Code;
        false -> {unknown_error_code, atom_to_binary(Code, utf8)}
    end.

connect_error({pool_timeout, TimeoutMs}) -> {timed_out, TimeoutMs};
connect_error(econnrefused) -> {connect_failed, <<"Connection refused">>};
connect_error(timeout) -> {connect_failed, <<"Connection timed out">>};
connect_error(nxdomain) -> {connect_failed, <<"DNS resolution failed (NXDOMAIN)">>};
connect_error(Reason) -> {connect_failed, inspect(Reason)}.

inspect(Term) ->
    unicode:characters_to_binary(io_lib:format("~p", [Term])).
