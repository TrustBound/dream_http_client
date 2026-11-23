-module(application_ffi).

%% Helpers for the lifecycle tests. They stop and start the application and
%% the connection manager while coverage runs, and read state that the
%% public API does not show.

-export([connection_protocols/1, restart_application/0, restart_connection_manager/0, client_log_level/0,
         send_unknown_messages/0, connection_count/0, await_connection_count/2, lease_count/0,
         kill_stream_owner/0]).

restart_application() ->
    ok = application:stop(dream_http_client),
    ok = application:start(dream_http_client),
    nil.

%% Kills the connection manager and waits until its supervisor started a
%% new one.
restart_connection_manager() ->
    Old = whereis(dream_http_conn_manager),
    exit(Old, kill),
    await_new_manager(Old).

await_new_manager(Old) ->
    case whereis(dream_http_conn_manager) of
        New when is_pid(New), New =/= Old ->
            nil;
        _ ->
            timer:sleep(10),
            await_new_manager(Old)
    end.

%% The logger module level of dream_http_client_log, the module that
%% writes every log line of the client.
client_log_level() ->
    [{dream_http_client_log, Level}] = logger:get_module_level(dream_http_client_log),
    atom_to_binary(Level, utf8).

%% Sends a cast and a plain message that the connection manager does not
%% know.
send_unknown_messages() ->
    gen_server:cast(dream_http_conn_manager, unknown_cast),
    dream_http_conn_manager ! unknown_message,
    nil.

%% The protocol of each open connection to Port: "http" for HTTP/1.1 and
%% "http2" for HTTP/2, sorted.
connection_protocols(Port) ->
    lists:sort([atom_to_binary(Protocol)
                || {{_Scheme, _Host, P, _Protocols, _Authority, _Pool}, _Pid, _, Protocol, _}
                       <- ets:tab2list(dream_http_client_connections), P =:= Port]).

connection_count() ->
    ets:info(dream_http_client_connections, size).

%% Waits until the pool holds Count connections, or until TimeoutMs passed,
%% and returns the number of connections then.
await_connection_count(Count, TimeoutMs) ->
    await_connection_count(Count, erlang:monotonic_time(millisecond) + TimeoutMs, connection_count()).

await_connection_count(Count, _Deadline, Count) ->
    Count;
await_connection_count(Count, Deadline, Current) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true -> Current;
        false ->
            timer:sleep(10),
            await_connection_count(Count, Deadline, connection_count())
    end.

%% The number of leases in the state of the connection manager.
lease_count() ->
    #{leases := Leases} = sys:get_state(dream_http_conn_manager),
    map_size(Leases).

%% Kills the owner process of each pull stream that the calling process
%% reads (the owner monitors the process that started the stream), and
%% waits until they stopped. Returns the number of killed owners.
kill_stream_owner() ->
    Self = self(),
    Owners = [Pid || Pid <- erlang:processes(), is_stream_owner_of(Pid, Self)],
    lists:foreach(fun kill_and_wait/1, Owners),
    length(Owners).

is_stream_owner_of(Pid, Requester) ->
    case erlang:process_info(Pid, [current_function, monitors]) of
        [{current_function, {dream_http_shim, stream_owner_loop, 1}}, {monitors, Monitors}] ->
            lists:member({process, Requester}, Monitors);
        _ ->
            false
    end.

kill_and_wait(Pid) ->
    MonitorRef = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive
        {'DOWN', MonitorRef, process, Pid, _Reason} -> ok
    end.
