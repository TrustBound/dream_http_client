-module(edge_server_ffi).

%% A small HTTP server for the tests. It sends the exact bytes of server
%% edge cases that the mock server cannot produce: trailers, stalled
%% bodies, closed connections, redirect loops and HTTP/2 frames such as
%% RST_STREAM and GOAWAY.
%%
%% start/1 returns {Port, Listener}. stop/1 stops the listener and every
%% connection process, which are linked to it.

-export([start/1, stop/1, kill_connections/1]).

start(Scenario) ->
    Parent = self(),
    Listener = spawn(fun() ->
        {ok, Socket} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true},
                                          {ip, {127, 0, 0, 1}}]),
        {ok, Port} = inet:port(Socket),
        Parent ! {edge_server_port, self(), Port},
        accept_loop(Socket, Scenario)
    end),
    receive
        {edge_server_port, Listener, Port} -> {Port, Listener}
    end.

stop({_Port, Listener}) ->
    MonitorRef = erlang:monitor(process, Listener),
    exit(Listener, kill),
    receive
        {'DOWN', MonitorRef, process, Listener, _Reason} -> nil
    end.

%% Waits until the client has a connection to the port, gives the request
%% time to reach the server, then kills the connection processes. A
%% request on them sees its connection process stop.
kill_connections(Port) ->
    case [Pid || {{_Scheme, _Host, P, _Protocols, _Authority}, Pid, _, _, _}
                     <- ets:tab2list(dream_http_client_connections), P =:= Port] of
        [] ->
            timer:sleep(10),
            kill_connections(Port);
        Pids ->
            timer:sleep(100),
            lists:foreach(fun(Pid) -> exit(Pid, kill) end, Pids),
            length(Pids)
    end.

accept_loop(Socket, Scenario) ->
    {ok, Client} = gen_tcp:accept(Socket),
    Handler = spawn_link(fun() ->
        receive go -> ok end,
        serve(Scenario, Client)
    end),
    ok = gen_tcp:controlling_process(Client, Handler),
    Handler ! go,
    accept_loop(Socket, Scenario).

%% ============================================================================
%% HTTP/1.1 scenarios
%% ============================================================================

serve(<<"h2_", _/binary>> = Scenario, Socket) ->
    serve_h2(Scenario, Socket);
serve(Scenario, Socket) ->
    case read_request(Socket, <<>>) of
        ok ->
            respond(Scenario, Socket),
            %% A keep-alive connection can carry more requests.
            serve(Scenario, Socket);
        closed ->
            ok
    end.

read_request(Socket, Buffer) ->
    case binary:match(Buffer, <<"\r\n\r\n">>) of
        {_Pos, _Len} ->
            ok;
        nomatch ->
            case gen_tcp:recv(Socket, 0) of
                {ok, Data} -> read_request(Socket, <<Buffer/binary, Data/binary>>);
                {error, _Reason} -> closed
            end
    end.

%% Waits until the client closes the connection.
hold(Socket) ->
    _ = gen_tcp:recv(Socket, 0),
    exit(normal).

respond(<<"silent">>, Socket) ->
    hold(Socket);
respond(<<"close">>, Socket) ->
    gen_tcp:close(Socket),
    exit(normal);
respond(<<"reset">>, Socket) ->
    ok = inet:setopts(Socket, [{linger, {true, 0}}]),
    gen_tcp:close(Socket),
    exit(normal);
respond(<<"redirect_loop">>, Socket) ->
    send(Socket, [<<"HTTP/1.1 302 Found\r\n">>,
                  <<"location: /loop\r\n">>,
                  <<"content-length: 0\r\n\r\n">>]);
respond(<<"bad_location">>, Socket) ->
    send(Socket, [<<"HTTP/1.1 302 Found\r\n">>,
                  <<"location: http://bad host/\r\n">>,
                  <<"content-length: 0\r\n\r\n">>]);
respond(<<"trailers">>, Socket) ->
    send(Socket, [<<"HTTP/1.1 200 OK\r\n">>,
                  <<"transfer-encoding: chunked\r\n">>,
                  <<"trailer: x-checksum\r\n\r\n">>,
                  <<"5\r\nhello\r\n">>,
                  <<"0\r\nx-checksum: abc\r\n\r\n">>]);
respond(<<"content_range">>, Socket) ->
    send(Socket, [<<"HTTP/1.1 200 OK\r\n">>,
                  <<"content-range: bytes 0-3/10\r\n">>,
                  <<"content-length: 4\r\n\r\n">>,
                  <<"part">>]);
respond(<<"stall_body">>, Socket) ->
    send(Socket, [<<"HTTP/1.1 200 OK\r\n">>,
                  <<"content-length: 10\r\n\r\n">>]),
    hold(Socket);
respond(<<"error_stall">>, Socket) ->
    send(Socket, [<<"HTTP/1.1 500 Internal Server Error\r\n">>,
                  <<"content-length: 10\r\n\r\n">>]),
    hold(Socket).

send(Socket, Data) ->
    ok = gen_tcp:send(Socket, Data).

%% ============================================================================
%% HTTP/2 scenarios (prior knowledge, over TCP)
%% ============================================================================

serve_h2(Scenario, Socket) ->
    {ok, <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>} = gen_tcp:recv(Socket, 24),
    send(Socket, [cow_http2:settings(#{}), cow_http2:settings_ack()]),
    StreamId = await_headers(Socket, <<>>),
    respond_h2(Scenario, Socket, StreamId),
    hold(Socket).

%% Reads frames until the client sends the HEADERS frame of a request.
await_headers(Socket, Buffer) ->
    case cow_http2:parse(Buffer) of
        {ok, {headers, StreamId, _IsFin, _HeadFin, _HeaderBlock}, _Rest} ->
            StreamId;
        {ok, _Frame, Rest} ->
            await_headers(Socket, Rest);
        {ignore, Rest} ->
            await_headers(Socket, Rest);
        more ->
            {ok, Data} = gen_tcp:recv(Socket, 0),
            await_headers(Socket, <<Buffer/binary, Data/binary>>)
    end.

respond_h2(<<"h2_rst">>, Socket, StreamId) ->
    send(Socket, cow_http2:rst_stream(StreamId, internal_error));
respond_h2(<<"h2_rst_after_headers">>, Socket, StreamId) ->
    send(Socket, [ok_headers(StreamId), cow_http2:rst_stream(StreamId, internal_error)]);
respond_h2(<<"h2_goaway">>, Socket, _StreamId) ->
    send(Socket, cow_http2:goaway(0, no_error, <<>>));
respond_h2(<<"h2_connection_error">>, Socket, StreamId) ->
    %% A DATA frame on stream 0 is a connection error (RFC 7540 6.1).
    send(Socket, [ok_headers(StreamId), cow_http2:data(0, fin, <<>>)]).

ok_headers(StreamId) ->
    {HeaderBlock, _State} = cow_hpack:encode([{<<":status">>, <<"200">>}]),
    cow_http2:headers(StreamId, nofin, HeaderBlock).
