-module(application_ffi).

%% Helpers for the lifecycle tests. They stop and start the application and
%% the connection manager while coverage runs, and read state that the
%% public API does not show.

-export([restart_application/0, restart_connection_manager/0, shim_log_level/0,
         send_unknown_messages/0, connection_count/0]).

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

shim_log_level() ->
    [{dream_http_shim, Level}] = logger:get_module_level(dream_http_shim),
    atom_to_binary(Level, utf8).

%% Sends a cast and a plain message that the connection manager does not
%% know.
send_unknown_messages() ->
    gen_server:cast(dream_http_conn_manager, unknown_cast),
    dream_http_conn_manager ! unknown_message,
    nil.

connection_count() ->
    ets:info(dream_http_client_connections, size).
