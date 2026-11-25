-module(connection_stop_ffi).

%% Shows whether the pool can stop a connection between the moment its
%% socket closed and the moment the connection reported it. gun reports a
%% lost socket (the gun_down message, which the pool logs as a warning) while
%% it handles the message of the socket. The test makes that order certain:
%% it suspends the connection process, closes the socket on the server side,
%% stops the connection the way the pool does, and only then lets the
%% connection run.

-export([down_reported_when_stopped/0, stop_stopped_connection/0]).

%% Returns true when the owner got gun_down for the closed socket.
down_reported_when_stopped() ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Listen),
    {ok, ConnPid} = gun:open("127.0.0.1", Port, #{retry => 0, protocols => [http]}),
    {ok, ServerSide} = gen_tcp:accept(Listen, 5000),
    {ok, http} = gun:await_up(ConnPid, 5000),
    MonitorRef = erlang:monitor(process, ConnPid),
    true = erlang:suspend_process(ConnPid),
    ok = gen_tcp:close(ServerSide),
    %% The connection gets the message of the closed socket while it is
    %% suspended.
    ok = await_message_count(ConnPid, 1),
    %% Stopping can wait for the connection to stop, so it runs in a process
    %% of its own while the connection is suspended.
    spawn(fun() -> dream_http_conn_manager:stop_connection(ConnPid) end),
    timer:sleep(100),
    %% An exit signal stops even a suspended process, so the connection can
    %% be gone here.
    try erlang:resume_process(ConnPid) catch _:_ -> ok end,
    Reported = receive
        {gun_down, ConnPid, http, closed, []} -> true
    after 2000 -> false
    end,
    receive {'DOWN', MonitorRef, process, ConnPid, _} -> ok after 5000 -> ok end,
    ok = gen_tcp:close(Listen),
    Reported.

%% Stops a connection that already stopped. Returns true when that does not
%% crash the caller.
stop_stopped_connection() ->
    Pid = spawn(fun() -> ok end),
    MonitorRef = erlang:monitor(process, Pid),
    receive {'DOWN', MonitorRef, process, Pid, _} -> ok end,
    dream_http_conn_manager:stop_connection(Pid),
    timer:sleep(100),
    true.

await_message_count(Pid, Count) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, Length} when Length >= Count -> ok;
        _ -> timer:sleep(5), await_message_count(Pid, Count)
    end.
