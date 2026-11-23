-module(dream_http_shim).

%% The values this module returns to Gleam are Gleam values:
%%
%% - a transport error is a `client.TransportError`, for example
%%   `{timed_out, TimeoutMs}` or `remote_closed`;
%% - a stream failure is a `client.StreamFailure`:
%%   `{transport_failure, TransportError}` or
%%   `{http_failure, {http_response, Status, [{header, Name, Value}], Body}}`;
%% - a pull stream event is an `internal.StreamEvent`:
%%   `{chunk, Data}`, `{done, Trailers}` or `{failed, StreamFailure}`;
%% - a translator message is a `client.TranslatorMessage`:
%%   `{translator_start, Headers}`, `{translator_chunk, Data}`,
%%   `{translator_end, Trailers}` or `{translator_error, StreamFailure}`.

-export([request_sync/8, request_stream/8, fetch_next/1, fetch_start_headers/1,
         request_stream_messages/8, configure_transport/1]).

-define(MAX_REDIRECTS, 5).

%% The state of the process that owns a pull-based stream.
%% `events` holds the stream events that no caller has fetched yet, and
%% `waiter` is the caller that waits for the next event. `requester` is the
%% process that started the stream: the owner stops when it stops.
-record(owner, {requester, conn, ref, headers, zlib, timeout, events = [], waiter = none}).

%% ============================================================================
%% Requests and redirects
%% ============================================================================

request(Method, Url, Headers, Body, TimeoutMs, ConnectTimeoutMs, AutoRedirect, Settings) ->
    #{method => Method, url => Url, headers => maybe_add_accept_encoding(Headers),
      body => Body, timeout => TimeoutMs, connect_timeout => ConnectTimeoutMs,
      auto_redirect => AutoRedirect, settings => Settings}.

%% Sends the request and follows redirects. Returns the response head of the
%% last response, or {error, TransportError}.
open_response(_Request, Redirects) when Redirects >= ?MAX_REDIRECTS ->
    {error, {unexpected, <<"Too many redirects (max 5)">>}};
open_response(Request, Redirects) ->
    #{method := Method, url := Url, body := Body, timeout := TimeoutMs,
      auto_redirect := AutoRedirect} = Request,
    case open_stream(Request, 1) of
        {ok, ConnPid, StreamRef, IsFin, Status, RespHeaders} = Response ->
            case AutoRedirect andalso redirect_location(Status, RespHeaders) of
                {ok, Location} ->
                    _ = await_body(ConnPid, StreamRef, IsFin, TimeoutMs),
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

%% Sends one request. A request on a connection that the server closed
%% while it was idle is sent once more on a new connection.
open_stream(Request, RetriesLeft) ->
    #{method := Method, url := Url, headers := Headers, body := Body,
      timeout := TimeoutMs, connect_timeout := ConnectTimeoutMs,
      settings := Settings} = Request,
    case parse_url(Url) of
        {ok, Scheme, Host, Port, PathQs} ->
            GunOpts = build_gun_opts(ConnectTimeoutMs, Settings),
            case get_or_open_connection(Scheme, Host, Port, GunOpts) of
                {ok, ConnPid, _Protocol} ->
                    StreamRef = gun:request(ConnPid, method_binary(Method), PathQs, Headers, Body),
                    case gun:await(ConnPid, StreamRef, TimeoutMs) of
                        {response, IsFin, Status, RespHeaders} ->
                            {ok, ConnPid, StreamRef, IsFin, Status, RespHeaders};
                        {error, Reason} ->
                            case RetriesLeft > 0 andalso is_stale_connection_error(Reason) of
                                true ->
                                    gun:close(ConnPid),
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

%% Reads the whole body of a response.
await_body(_ConnPid, _StreamRef, fin, _TimeoutMs) ->
    {ok, <<>>};
await_body(ConnPid, StreamRef, nofin, TimeoutMs) ->
    case gun:await_body(ConnPid, StreamRef, TimeoutMs) of
        {ok, Body, _Trailers} -> {ok, Body};
        Result -> Result
    end.

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
    Request = request(Method, Url, Headers, Body, TimeoutMs, ConnectTimeoutMs, AutoRedirect, Settings),
    case open_response(Request, 0) of
        {ok, ConnPid, StreamRef, IsFin, Status, RespHeaders} ->
            case await_body(ConnPid, StreamRef, IsFin, TimeoutMs) of
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

%% Returns the head of a 2xx response, or {error, StreamFailure}.
open_streaming_response(Request = #{timeout := TimeoutMs}) ->
    case open_response(Request, 0) of
        {ok, ConnPid, StreamRef, IsFin, Status, RespHeaders} when Status >= 200, Status < 300 ->
            {ok, ConnPid, StreamRef, IsFin, RespHeaders};
        {ok, ConnPid, StreamRef, IsFin, Status, RespHeaders} ->
            Body = case await_body(ConnPid, StreamRef, IsFin, TimeoutMs) of
                {ok, FullBody} -> body_text(FullBody);
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
    Request = request(Method, Url, Headers, Body, TimeoutMs, ConnectTimeoutMs, AutoRedirect, Settings),
    Requester = self(),
    spawn(fun() -> stream_owner_init(Request, Requester) end).

stream_owner_init(Request = #{timeout := TimeoutMs}, Requester) ->
    erlang:monitor(process, Requester),
    case open_streaming_response(Request) of
        {ok, ConnPid, StreamRef, IsFin, RespHeaders} ->
            Owner = #owner{requester = Requester, conn = ConnPid, ref = StreamRef,
                           headers = RespHeaders, zlib = stream_zlib(RespHeaders),
                           timeout = TimeoutMs},
            stream_owner_loop(Owner#owner{events = [{done, []} || IsFin =:= fin]});
        {error, Failure} ->
            exit({stream_start_failed, Failure})
    end.

%% Gives each fetched event to its caller, and collects the gun messages of
%% the stream until a caller fetches them. The owner stops after it gives
%% the last event of the stream.
stream_owner_loop(Owner = #owner{waiter = Waiter, events = [Event | Events]}) when Waiter =/= none ->
    Waiter ! {stream_event, self(), Event},
    case Event of
        {chunk, _Data} -> stream_owner_loop(Owner#owner{waiter = none, events = Events});
        _ -> ok
    end;
stream_owner_loop(Owner = #owner{requester = Requester, conn = ConnPid, ref = StreamRef,
                                 waiter = Waiter, timeout = TimeoutMs}) ->
    receive
        {'DOWN', _MonitorRef, process, Requester, _Reason} ->
            ok;
        {fetch_next, From} ->
            stream_owner_loop(Owner#owner{waiter = From});
        {fetch_start_headers, From} ->
            From ! {stream_start_headers, self(), Owner#owner.headers},
            stream_owner_loop(Owner);
        Message = {gun_data, ConnPid, StreamRef, _IsFin, _Data} ->
            stream_owner_loop(add_events(Owner, Message));
        Message = {Tag, ConnPid, StreamRef, _Value} when Tag =:= gun_trailers; Tag =:= gun_error ->
            stream_owner_loop(add_events(Owner, Message));
        Message = {gun_error, ConnPid, _Reason} ->
            stream_owner_loop(add_events(Owner, Message))
    after wait_timeout(Waiter, TimeoutMs) ->
        Waiter ! {stream_event, self(), {failed, {transport_failure, {timed_out, TimeoutMs}}}},
        stream_owner_loop(Owner#owner{waiter = none})
    end.

add_events(Owner = #owner{events = Events, zlib = ZlibCtx}, Message) ->
    {NewEvents, NewZlibCtx} = stream_events(Message, ZlibCtx),
    Owner#owner{events = Events ++ NewEvents, zlib = NewZlibCtx}.

wait_timeout(none, _TimeoutMs) -> infinity;
wait_timeout(_Waiter, TimeoutMs) -> TimeoutMs.

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
        {stream_start_headers, Owner, Headers} ->
            erlang:demonitor(MonitorRef, [flush]),
            {ok, Headers};
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
%% the stream process.
request_stream_messages(Method, Url, Headers, Body, TimeoutMs, ConnectTimeoutMs, AutoRedirect, Settings) ->
    Request = request(Method, Url, Headers, Body, TimeoutMs, ConnectTimeoutMs, AutoRedirect, Settings),
    StreamPid = self(),
    _TranslatorPid = spawn_link(fun() -> translator_init(Request, StreamPid) end),
    nil.

translator_init(Request = #{timeout := TimeoutMs}, StreamPid) ->
    process_flag(trap_exit, true),
    case open_streaming_response(Request) of
        {ok, ConnPid, StreamRef, IsFin, RespHeaders} ->
            StreamPid ! {http, {translator_start, gleam_headers(RespHeaders)}},
            Translator = {ConnPid, StreamRef, StreamPid, TimeoutMs},
            case IsFin of
                fin -> send_events(Translator, [{done, []}]);
                nofin -> translator_loop(Translator, stream_zlib(RespHeaders))
            end;
        {error, Failure} ->
            StreamPid ! {http, {translator_error, Failure}}
    end.

translator_loop(Translator = {ConnPid, StreamRef, StreamPid, TimeoutMs}, ZlibCtx) ->
    receive
        Message = {gun_data, ConnPid, StreamRef, _IsFin, _Data} ->
            translate(Translator, Message, ZlibCtx);
        Message = {Tag, ConnPid, StreamRef, _Value} when Tag =:= gun_trailers; Tag =:= gun_error ->
            translate(Translator, Message, ZlibCtx);
        Message = {gun_error, ConnPid, _Reason} ->
            translate(Translator, Message, ZlibCtx);
        {'EXIT', StreamPid, _Reason} ->
            close_zlib(ZlibCtx),
            gun:cancel(ConnPid, StreamRef)
    after TimeoutMs ->
        close_zlib(ZlibCtx),
        StreamPid ! {http, {translator_error, {transport_failure, {timed_out, TimeoutMs}}}}
    end.

translate(Translator, Message, ZlibCtx) ->
    {Events, NewZlibCtx} = stream_events(Message, ZlibCtx),
    case send_events(Translator, Events) of
        {chunk, _Data} -> translator_loop(Translator, NewZlibCtx);
        _ -> ok
    end.

%% Sends the events to the stream process and returns the last one.
send_events({_ConnPid, _StreamRef, StreamPid, _TimeoutMs}, Events) ->
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
    LogLevel = map_log_level(element(15, Config)),
    logger:set_module_level([dream_http_conn_manager, dream_http_shim], LogLevel),
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
            %%   DomainLookupTimeout, TlsHandshakeTimeout, Retry, RetryTimeout, Keepalive,
            %%   KeepaliveTolerance, MaxConcurrentStreams, InitConnWindowSize, InitStreamWindowSize,
            %%   ClosingTimeout, LogLevel, DefaultCertificateAuthorityFile}
            #{max_connections => element(2, Config),
              idle_timeout => element(3, Config),
              connect_timeout => element(4, Config),
              domain_lookup_timeout => element(5, Config),
              tls_handshake_timeout => element(6, Config),
              retry => element(7, Config),
              retry_timeout => element(8, Config),
              keepalive => element(9, Config),
              keepalive_tolerance => element(10, Config),
              max_concurrent_streams => element(11, Config),
              initial_connection_window_size => element(12, Config),
              initial_stream_window_size => element(13, Config),
              closing_timeout => element(14, Config),
              certificate_authority_file => element(16, Config)};
        [] ->
            #{max_connections => 50,
              idle_timeout => 60000,
              connect_timeout => 15000,
              domain_lookup_timeout => 5000,
              tls_handshake_timeout => 10000,
              retry => 3,
              retry_timeout => 1000,
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
%% {connection_settings, Protocols, CertificateAuthorityFile}.
build_gun_opts(ConnectTimeoutMs, {connection_settings, Protocols, CertificateAuthorityFile}) ->
    Opts = #{connect_timeout => ConnectTimeoutMs},
    WithProtocols = case Protocols of
        default -> Opts;
        _ -> Opts#{protocols => Protocols}
    end,
    case CertificateAuthorityFile of
        none -> WithProtocols;
        {some, File} -> WithProtocols#{certificate_authority_file => File}
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
            logger:warning("unrecognized Content-Encoding, passing through raw bytes: ~s", [Other]),
            {Body, Headers}
    end.

try_decompress(DecompressFn, Body, Headers) ->
    try
        Decompressed = DecompressFn(Body),
        {Decompressed, [Header || Header = {Name, _} <- Headers, Name =/= <<"content-encoding">>]}
    catch
        _:_ ->
            logger:warning("decompression failed, passing through raw bytes", []),
            {Body, Headers}
    end.

stream_zlib(Headers) ->
    case get_content_encoding(Headers) of
        <<"gzip">> -> open_zlib(31);
        <<"deflate">> -> open_zlib(15);
        <<>> -> undefined;
        <<"identity">> -> undefined;
        Other ->
            logger:warning("unrecognized Content-Encoding for stream, passing through raw bytes: ~s",
                           [Other]),
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

%% gun:await/3 and gun:await_body/3 return an error that the server closed
%% the connection when a request reuses a connection that the server closed
%% while it was idle. A GOAWAY frame refuses a stream that the server did not
%% start to process. In both cases a new connection can send the request.
is_stale_connection_error({stream_error, closed}) -> true;
is_stale_connection_error({stream_error, {goaway, _Code, _HumanReadable}}) -> true;
is_stale_connection_error(_Reason) -> false.

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
    {stream_reset, atom_to_binary(Code, utf8), atom_to_binary(HumanReadable, utf8)};
transport_error({Code, HumanReadable}, _TimeoutMs) when is_atom(Code), is_atom(HumanReadable) ->
    {connection_error, atom_to_binary(Code, utf8), atom_to_binary(HumanReadable, utf8)};
transport_error(Reason, _TimeoutMs) ->
    {unexpected, inspect(Reason)}.

connect_error(econnrefused) -> {connect_failed, <<"Connection refused">>};
connect_error(timeout) -> {connect_failed, <<"Connection timed out">>};
connect_error(nxdomain) -> {connect_failed, <<"DNS resolution failed (NXDOMAIN)">>};
connect_error(Reason) -> {connect_failed, inspect(Reason)}.

inspect(Term) ->
    unicode:characters_to_binary(io_lib:format("~p", [Term])).

%% A Gleam String must be UTF-8. A body that is not UTF-8 is read as Latin-1.
body_text(Body) ->
    case unicode:characters_to_binary(Body) of
        Text when is_binary(Text) -> Text;
        _ -> unicode:characters_to_binary(Body, latin1)
    end.
