-module(edge_server_ffi).

%% A small HTTP server for the tests. It sends the exact bytes of server
%% edge cases that the mock server cannot produce: trailers, stalled
%% bodies, empty bodies, chunks 100 ms apart, closed connections, redirect
%% loops and HTTP/2 frames such as RST_STREAM and GOAWAY. The `echo_body`
%% scenario sends the body of the request back.
%%
%% start/1 returns {Port, Listener}. stop/1 stops the listener and every
%% connection process, which are linked to it.
%%
%% The `h2s_` scenarios serve many HTTP/2 streams on each connection, so the
%% tests can check how the pool shares a connection. Each connection knows
%% its number: 1 for the first connection to the listener.

-export([start/1, start_tls/3, stop/1, kill_connections/1, stop_connections/1, flood_sent/1]).

start(Scenario) ->
    Parent = self(),
    Listener = spawn(fun() ->
        {ok, Socket} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true},
                                          {ip, {127, 0, 0, 1}}]),
        {ok, Port} = inet:port(Socket),
        Parent ! {edge_server_port, self(), Port},
        accept_loop(Socket, Scenario, 1)
    end),
    receive
        {edge_server_port, Listener, Port} -> {Port, Listener}
    end.

%% Starts a TLS listener for an `h2s_` scenario. It offers only h2 with ALPN,
%% so the client must negotiate HTTP/2 the way it does with a real server.
start_tls(Scenario, CertFile, KeyFile) ->
    Parent = self(),
    Listener = spawn(fun() ->
        {ok, Socket} = ssl:listen(0, [binary, {active, false}, {reuseaddr, true},
                                      {ip, {127, 0, 0, 1}},
                                      {certfile, binary_to_list(CertFile)},
                                      {keyfile, binary_to_list(KeyFile)},
                                      {alpn_preferred_protocols, [<<"h2">>]}]),
        {ok, {_Address, Port}} = ssl:sockname(Socket),
        Parent ! {edge_server_port, self(), Port},
        tls_accept_loop(Socket, Scenario, 1)
    end),
    receive
        {edge_server_port, Listener, Port} -> {Port, Listener}
    end.

tls_accept_loop(Socket, Scenario, Number) ->
    {ok, Transport} = ssl:transport_accept(Socket),
    Handler = spawn_link(fun() ->
        receive go -> ok end,
        {ok, Client} = ssl:handshake(Transport),
        {ok, <<"h2">>} = ssl:negotiated_protocol(Client),
        serve_h2_streams(Scenario, {ssl, Client}, Number)
    end),
    ok = ssl:controlling_process(Transport, Handler),
    Handler ! go,
    tls_accept_loop(Socket, Scenario, Number + 1).

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
    end_connections(Port, kill).

%% As kill_connections/1, but the connection processes stop with the reason
%% `shutdown`, as a connection does that lost its socket.
stop_connections(Port) ->
    end_connections(Port, shutdown).

end_connections(Port, Reason) ->
    case [Pid || {{_Scheme, _Host, P, _Protocols, _Authority, _Pool}, Pid, _, _, _}
                     <- ets:tab2list(dream_http_client_connections), P =:= Port] of
        [] ->
            timer:sleep(10),
            end_connections(Port, Reason);
        Pids ->
            timer:sleep(100),
            lists:foreach(fun(Pid) -> exit(Pid, Reason) end, Pids),
            length(Pids)
    end.

accept_loop(Socket, Scenario, Number) ->
    {ok, Client} = gen_tcp:accept(Socket),
    Handler = spawn_link(fun() ->
        receive go -> ok end,
        serve(Scenario, Client, Number)
    end),
    ok = gen_tcp:controlling_process(Client, Handler),
    Handler ! go,
    accept_loop(Socket, Scenario, Number + 1).

serve(<<"h2s_", _/binary>> = Scenario, Socket, Number) ->
    serve_h2_streams(Scenario, {gen_tcp, Socket}, Number);
serve(<<"echo_body">>, Socket, _Number) ->
    serve_echo(Socket);
serve(Scenario, Socket, _Number) ->
    serve(Scenario, Socket).

%% Reads one request that has a content-length, and sends its body back
%% with the same bytes.
serve_echo(Socket) ->
    {Head, Rest} = read_head(Socket, <<>>),
    [_, LengthAndMore] = binary:split(Head, <<"content-length: ">>),
    [LengthText | _] = binary:split(LengthAndMore, <<"\r\n">>),
    Length = binary_to_integer(LengthText),
    Body = read_body(Socket, Rest, Length),
    send(Socket, [<<"HTTP/1.1 200 OK\r\ncontent-length: ">>, LengthText, <<"\r\n\r\n">>, Body]),
    hold(Socket).

read_head(Socket, Buffer) ->
    case binary:split(Buffer, <<"\r\n\r\n">>) of
        [Head, Rest] ->
            {<<Head/binary, "\r\n">>, Rest};
        [_] ->
            {ok, Data} = gen_tcp:recv(Socket, 0),
            read_head(Socket, <<Buffer/binary, Data/binary>>)
    end.

read_body(_Socket, Buffer, Length) when byte_size(Buffer) >= Length ->
    Buffer;
read_body(Socket, Buffer, Length) ->
    {ok, Data} = gen_tcp:recv(Socket, 0),
    read_body(Socket, <<Buffer/binary, Data/binary>>, Length).

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
respond(<<"chunks">>, Socket) ->
    send(Socket, [<<"HTTP/1.1 200 OK\r\n">>,
                  <<"transfer-encoding: chunked\r\n\r\n">>,
                  <<"3\r\none\r\n">>]),
    timer:sleep(100),
    send(Socket, <<"3\r\ntwo\r\n">>),
    timer:sleep(100),
    send(Socket, <<"5\r\nthree\r\n0\r\n\r\n">>);
respond(<<"created_stream">>, Socket) ->
    send(Socket, [<<"HTTP/1.1 201 Created\r\n">>,
                  <<"transfer-encoding: chunked\r\n\r\n">>,
                  <<"3\r\none\r\n0\r\n\r\n">>]);
respond(<<"chunk_then_close">>, Socket) ->
    send(Socket, [<<"HTTP/1.1 200 OK\r\n">>,
                  <<"transfer-encoding: chunked\r\n\r\n">>,
                  <<"3\r\none\r\n">>]),
    timer:sleep(100),
    gen_tcp:close(Socket),
    exit(normal);
respond(<<"flood">>, Socket) ->
    %% 64 MB, which is more than the socket buffers hold. The server can
    %% send all of it only when the client keeps reading.
    {ok, Port} = inet:port(Socket),
    send(Socket, [<<"HTTP/1.1 200 OK\r\n">>,
                  <<"content-length: 67108864\r\n\r\n">>]),
    flood(Socket, binary:copy(<<0>>, 65536), 1024),
    persistent_term:put({edge_server_flood_sent, Port}, true);
respond(<<"sixteen_parts">>, Socket) ->
    %% 16 body parts, 20 ms apart, so the client reads 16 data messages. The
    %% last one ends the response.
    send(Socket, [<<"HTTP/1.1 200 OK\r\n">>,
                  <<"content-length: 16\r\n\r\n">>]),
    lists:foreach(fun(_Part) -> timer:sleep(20), send(Socket, <<"x">>) end, lists:seq(1, 16));
respond(<<"error_parts">>, Socket) ->
    send(Socket, [<<"HTTP/1.1 500 Internal Server Error\r\n">>,
                  <<"transfer-encoding: chunked\r\n">>,
                  <<"trailer: x-checksum\r\n\r\n">>,
                  <<"5\r\nhello\r\n">>]),
    timer:sleep(50),
    send(Socket, <<"5\r\nworld\r\n">>),
    timer:sleep(50),
    send(Socket, <<"0\r\nx-checksum: abc\r\n\r\n">>);
respond(<<"close_after_response">>, Socket) ->
    %% A complete response, then the server closes the connection and does
    %% not say so in a header.
    send(Socket, [<<"HTTP/1.1 200 OK\r\n">>,
                  <<"content-length: 2\r\n\r\n">>,
                  <<"ok">>]),
    gen_tcp:close(Socket),
    exit(normal);
respond(<<"early_hints">>, Socket) ->
    %% Two 1xx responses, then the final response.
    send(Socket, [<<"HTTP/1.1 103 Early Hints\r\n">>,
                  <<"link: </style.css>; rel=preload\r\n\r\n">>,
                  <<"HTTP/1.1 103 Early Hints\r\n">>,
                  <<"link: </app.js>; rel=preload\r\n\r\n">>,
                  <<"HTTP/1.1 200 OK\r\n">>,
                  <<"content-length: 2\r\n\r\n">>,
                  <<"ok">>]);
respond(<<"empty">>, Socket) ->
    send(Socket, [<<"HTTP/1.1 200 OK\r\n">>,
                  <<"content-length: 0\r\n\r\n">>]);
respond(<<"content_range">>, Socket) ->
    send(Socket, [<<"HTTP/1.1 206 Partial Content\r\n">>,
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

%% Sends Block to the client Count times. Stops when the client closed the
%% connection.
flood(_Socket, _Block, 0) ->
    ok;
flood(Socket, Block, Count) ->
    case gen_tcp:send(Socket, Block) of
        ok -> flood(Socket, Block, Count - 1);
        {error, _Reason} -> exit(normal)
    end.

%% True when the `flood` server on Port sent its whole body.
flood_sent(Port) ->
    persistent_term:get({edge_server_flood_sent, Port}, false).

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

%% ============================================================================
%% HTTP/2 scenarios with many streams on one connection
%% ============================================================================

%% h2s_limit_2: the server allows 2 streams at a time. Each stream gets
%% response headers and stays open.
%% h2s_limit_raise: the server allows 1 stream, and raises the limit to 10
%% after the first stream. Each stream gets headers and stays open.
%% h2s_refuse_first: connection 1 refuses its first stream with
%% REFUSED_STREAM. Every other stream gets a complete 200 response.
%% h2s_goaway_second: on connection 1, stream 1 gets headers and stays open,
%% and stream 3 gets a GOAWAY that keeps stream 1. Every stream on another
%% connection gets a complete 200 response.
%% h2s_sixteen_parts: each stream gets 16 DATA frames, 20 ms apart.
%% h2s_early_hints: each stream gets a 103 response, then a complete 200.
%% h2s_no_settings: the server never sends its SETTINGS frame.
serve_h2_streams(<<"h2s_no_settings">>, Socket, _Number) ->
    {ok, <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>} = recv(Socket, 24),
    _ = recv(Socket, 0),
    exit(normal);
serve_h2_streams(Scenario, Socket, Number) ->
    {ok, <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>} = recv(Socket, 24),
    send_to(Socket, [cow_http2:settings(initial_settings(Scenario)), cow_http2:settings_ack()]),
    stream_loop(Scenario, Socket, Number, <<>>).

initial_settings(<<"h2s_limit_2">>) -> #{max_concurrent_streams => 2};
initial_settings(<<"h2s_limit_raise">>) -> #{max_concurrent_streams => 1};
initial_settings(_Scenario) -> #{}.

stream_loop(Scenario, Socket, Number, Buffer) ->
    case next_headers(Socket, Buffer) of
        {ok, StreamId, Rest} ->
            respond_stream(Scenario, Socket, Number, StreamId),
            stream_loop(Scenario, Socket, Number, Rest);
        closed ->
            exit(normal)
    end.

%% Reads frames until the client sends the HEADERS frame of a request.
%% Returns the stream and the bytes after the frame.
next_headers(Socket, Buffer) ->
    case cow_http2:parse(Buffer) of
        {ok, {headers, StreamId, _IsFin, _HeadFin, _HeaderBlock}, Rest} ->
            {ok, StreamId, Rest};
        {ok, _Frame, Rest} ->
            next_headers(Socket, Rest);
        {ignore, Rest} ->
            next_headers(Socket, Rest);
        more ->
            case recv(Socket, 0) of
                {ok, Data} -> next_headers(Socket, <<Buffer/binary, Data/binary>>);
                {error, _Reason} -> closed
            end
    end.

respond_stream(<<"h2s_limit_raise">>, Socket, _Number, 1) ->
    send_to(Socket, [ok_headers(1), cow_http2:settings(#{max_concurrent_streams => 10})]);
respond_stream(<<"h2s_refuse_first">>, Socket, 1, 1) ->
    send_to(Socket, cow_http2:rst_stream(1, refused_stream));
respond_stream(<<"h2s_goaway_second">>, Socket, 1, 3) ->
    send_to(Socket, cow_http2:goaway(1, no_error, <<>>));
respond_stream(<<"h2s_goaway_second">>, Socket, 1, StreamId) ->
    send_to(Socket, ok_headers(StreamId));
respond_stream(Scenario, Socket, _Number, StreamId)
        when Scenario =:= <<"h2s_refuse_first">>; Scenario =:= <<"h2s_goaway_second">> ->
    send_to(Socket, [ok_headers(StreamId), cow_http2:data(StreamId, fin, <<"ok">>)]);
respond_stream(<<"h2s_sixteen_parts">>, Socket, _Number, StreamId) ->
    %% 16 DATA frames, 20 ms apart. The last one ends the stream.
    send_to(Socket, ok_headers(StreamId)),
    lists:foreach(fun(_Part) ->
        timer:sleep(20),
        send_to(Socket, cow_http2:data(StreamId, nofin, <<"x">>))
    end, lists:seq(1, 15)),
    timer:sleep(20),
    send_to(Socket, cow_http2:data(StreamId, fin, <<"x">>));
respond_stream(<<"h2s_early_hints">>, Socket, _Number, StreamId) ->
    {Hints, _State} = cow_hpack:encode([{<<":status">>, <<"103">>}]),
    send_to(Socket, [cow_http2:headers(StreamId, nofin, Hints),
                     ok_headers(StreamId),
                     cow_http2:data(StreamId, fin, <<"ok">>)]);
respond_stream(_Scenario, Socket, _Number, StreamId) ->
    send_to(Socket, ok_headers(StreamId)).

%% Socket is {gen_tcp, Socket} or {ssl, Socket}.
recv({Module, Socket}, Length) -> Module:recv(Socket, Length).

send_to({Module, Socket}, Data) -> ok = Module:send(Socket, Data).
