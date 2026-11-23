-module(dream_http_conn_manager).
-behaviour(gen_server).

%% The connection pool. Each request gets a lease on one connection.
%%
%% - An HTTP/1.1 connection carries one request at a time.
%% - An HTTP/2 connection carries streams up to the limit the server sets
%%   with SETTINGS_MAX_CONCURRENT_STREAMS (RFC 9113, section 6.5.2). The pool
%%   waits for the first SETTINGS frame of the server before it uses a new
%%   connection, and follows every later SETTINGS frame.
%% - The pool opens a new connection only when every connection to the
%%   origin is full. At max_connections, a request waits until a connection
%%   has room, or until its timeout.
%% - A retired connection (after a GOAWAY or a stale-connection error) gets
%%   no new request. The pool closes it when its last lease ends.

-export([start_link/0, ensure_connection/4, release/1, release_paused/1, abandon/1, refuse/1,
         retire/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TABLE, dream_http_client_connections).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Gives the calling process a connection for one request, and a lease on it.
%% Returns {ok, ConnPid, Protocol, Lease}, {error, {pool_timeout, Ms}} when
%% no connection had room within the request timeout, or {error, Reason}
%% when a new connection failed.
%%
%% The caller gives the lease back with release/1 when the response is
%% complete, abandon/1 when the response did not end, refuse/1 when the
%% server refused the stream, or retire/1 when the connection is stale.
%% When the caller stops with the lease, the pool treats it as abandoned.
%% The pool replies before the request timeout, so the call has no timeout
%% of its own.
ensure_connection(Scheme, Host, Port, GunOpts) ->
    gen_server:call(?MODULE, {ensure_connection, Scheme, Host, Port, GunOpts}, infinity).

%% The response on the leased connection is complete.
release(Lease) ->
    gen_server:cast(?MODULE, {release, Lease}).

%% The response is complete, but gun can have stopped reading the
%% connection: the stream got as many data messages as its flow window
%% holds, or more. gun does not read an HTTP/1.1 connection again after
%% that, so the pool retires it. An HTTP/2 connection has no such limit and
%% is released.
release_paused(Lease) ->
    gen_server:cast(?MODULE, {release_paused, Lease}).

%% The response on the leased connection did not end. An HTTP/1.1 connection
%% would send the next request behind the rest of that response, so the pool
%% closes it. The stream of an HTTP/2 connection is gone, and the connection
%% has room again.
abandon(Lease) ->
    gen_server:cast(?MODULE, {abandon, Lease}).

%% The stream was refused: gun's local `too_many_streams`, or the server's
%% REFUSED_STREAM. The server did not process the request. The pool treats
%% the connection as full until the server sends new SETTINGS.
refuse(Lease) ->
    gen_server:cast(?MODULE, {refuse, Lease}).

%% The connection is stale: the server closed it, or sent a GOAWAY. It gets
%% no new request. Streams that still run on it finish.
retire(Lease) ->
    gen_server:cast(?MODULE, {retire, Lease}).

%% Records that a request used the connection now. The time is in the state
%% of the manager, so the table entry of a connection never changes while
%% the connection lives: a reader of the table always sees the connection.
touch(ConnPid, State = #{last_used := LastUsed}) ->
    State#{last_used := LastUsed#{ConnPid => erlang:monotonic_time(millisecond)}}.

%% ============================================================================
%% gen_server callbacks
%% ============================================================================

%% State:
%% - `leases` maps each lease to {ConnPid, Protocol}. A lease is the
%%   reference of the monitor on the process that holds it.
%% - `limits` maps each connection to the number of leases it may carry, or
%%   `retired`. For HTTP/2 it is the server's limit, `infinity` when the
%%   server sets none, or the count of running streams after a refused
%%   stream. An HTTP/1.1 connection carries at most 1.
%% - `waiting` is the list of requests that wait for room, oldest first.
%% - `last_used` maps each connection to the time of its last use. The
%%   idle check reads it.
init([]) ->
    %% After a restart, the table can still hold the connections of the old
    %% manager. gun closes a connection when its owner stops, so none of them
    %% can be used again.
    ets:delete_all_objects(?TABLE),
    schedule_idle_check(),
    {ok, #{leases => #{}, limits => #{}, waiting => [], last_used => #{}}}.

%% The caller of ensure_connection/4 holds the lease.
handle_call({ensure_connection, Scheme, Host, Port, GunOpts}, From, State) ->
    Request = request(Scheme, Host, Port, GunOpts, From),
    case attempt(Request, State) of
        {reply, Reply, NewState} ->
            {reply, Reply, NewState};
        wait ->
            Timeout = maps:get(request_timeout, GunOpts),
            erlang:send_after(Timeout, self(), {waiter_timeout, Request}),
            #{waiting := Waiting} = State,
            {noreply, State#{waiting := Waiting ++ [Request]}}
    end.

%% A lease of a manager that restarted is not in `leases`, and nothing
%% changes.
handle_cast({release, Lease}, State = #{leases := Leases}) ->
    erlang:demonitor(Lease, [flush]),
    Released = [ConnPid || {ConnPid, _Protocol} <- maps:values(maps:with([Lease], Leases))],
    {noreply, serve_waiting(end_lease(Lease, lists:foldl(fun touch/2, State, Released)))};
handle_cast({release_paused, Lease}, State = #{leases := Leases}) ->
    case maps:get(Lease, Leases, none) of
        {_ConnPid, http} -> handle_cast({retire, Lease}, State);
        _ -> handle_cast({release, Lease}, State)
    end;
handle_cast({abandon, Lease}, State) ->
    erlang:demonitor(Lease, [flush]),
    {noreply, serve_waiting(abandon_lease(Lease, State))};
handle_cast({refuse, Lease}, State = #{leases := Leases, limits := Limits}) ->
    erlang:demonitor(Lease, [flush]),
    Rest = maps:remove(Lease, Leases),
    Full = maps:from_list([{ConnPid, lease_count(ConnPid, Rest)}
                           || {ConnPid, _Protocol} <- maps:values(maps:with([Lease], Leases))]),
    {noreply, serve_waiting(State#{leases := Rest, limits := maps:merge(Limits, Full)})};
handle_cast({retire, Lease}, State = #{leases := Leases, limits := Limits}) ->
    erlang:demonitor(Lease, [flush]),
    Retired = maps:from_list([{ConnPid, retired}
                              || {ConnPid, _Protocol} <- maps:values(maps:with([Lease], Leases))]),
    {noreply, serve_waiting(end_lease(Lease, State#{limits := maps:merge(Limits, Retired)}))};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', MonRef, process, Pid, _Reason}, State = #{leases := Leases}) ->
    case maps:is_key(MonRef, Leases) of
        %% The process that held the lease stopped.
        true ->
            {noreply, serve_waiting(abandon_lease(MonRef, State))};
        %% A connection stopped.
        false ->
            ets:match_delete(?TABLE, {'_', Pid, '_', '_', '_'}),
            #{limits := Limits, last_used := LastUsed} = State,
            {noreply, serve_waiting(State#{limits := maps:remove(Pid, Limits),
                                           last_used := maps:remove(Pid, LastUsed)})}
    end;

%% The server sent new SETTINGS on an HTTP/2 connection. A retired
%% connection stays retired.
handle_info({gun_notify, ConnPid, settings_changed, Settings}, State = #{limits := Limits}) ->
    Updated = [{ConnPid, stream_limit(Settings)} || maps:get(ConnPid, Limits, retired) =/= retired],
    {noreply, serve_waiting(State#{limits := maps:merge(Limits, maps:from_list(Updated))})};

handle_info({waiter_timeout, Request}, State = #{waiting := Waiting}) ->
    {TimedOut, Rest} = lists:partition(fun(Waiter) -> Waiter =:= Request end, Waiting),
    [gen_server:reply(From, {error, {pool_timeout, maps:get(request_timeout, GunOpts)}})
     || #{from := From, gun_opts := GunOpts} <- TimedOut],
    {noreply, State#{waiting := Rest}};

handle_info(check_idle, State) ->
    reap_idle_connections(State),
    schedule_idle_check(),
    {noreply, State};

%% The connection lost its socket. gun stops by itself (retry is 0), and
%% the 'DOWN' message removes the connection from the pool.
handle_info({gun_down, ConnPid, Protocol, Reason, KilledStreams}, State) ->
    log_gun_down(ConnPid, Protocol, Reason, length(KilledStreams)),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

%% ============================================================================
%% Internal
%% ============================================================================

request(Scheme, Host, Port, GunOpts, From) ->
    Transport = case Scheme of
        https -> tls;
        _ -> tcp
    end,
    Protocols = resolve_protocols(GunOpts, Transport),
    %% Requests that trust different certificate authorities, or that use
    %% different pools, never share a connection.
    Key = {Scheme, Host, Port, Protocols, maps:get(certificate_authority_file, GunOpts, system),
           maps:get(pool, GunOpts, default)},
    %% A unique reference tells two waiting requests apart.
    #{key => Key, scheme => Scheme, host => Host, port => Port,
      gun_opts => GunOpts#{protocols => Protocols}, from => From, id => make_ref()}.

%% Finds room for a request. Returns {reply, Reply, State}, or `wait` when
%% every connection is full at max_connections.
%%
%% 1. A connection with room: use the one with the fewest leases.
%% 2. Every connection is full, and the pool can open one more: open it.
%% 3. Every connection is full at max_connections: wait.
attempt(Request = #{key := Key, gun_opts := GunOpts, from := {Holder, _Tag}},
        State = #{leases := Leases, limits := Limits}) ->
    %% A connection that stopped stays in the table until its 'DOWN'
    %% message removes it.
    Alive = [E || {_, Pid, _, _, _} = E <- ets:lookup(?TABLE, Key), erlang:is_process_alive(Pid)],
    WithRoom = lists:keysort(1, [{lease_count(Pid, Leases), E}
                                  || {_, Pid, _, Proto, _} = E <- Alive,
                                     lease_count(Pid, Leases) < capacity(Pid, Proto, Limits)]),
    MaxConns = maps:get(max_connections, GunOpts, 50),
    case {WithRoom, length(Alive) < MaxConns} of
        {[{_, {_, Pid, _, Proto, _}} | _], _} ->
            {Lease, NewState} = lease(Holder, Pid, Proto, touch(Pid, State)),
            {reply, {ok, Pid, Proto, Lease}, NewState};
        {[], true} ->
            open(Request, State);
        {[], false} ->
            wait
    end.

open(#{key := Key, scheme := Scheme, host := Host, port := Port, gun_opts := GunOpts,
       from := {Holder, _Tag}}, State = #{limits := Limits}) ->
    case open_connection(Scheme, Host, Port, GunOpts) of
        {ok, ConnPid, Protocol, Limit} ->
            MonRef = erlang:monitor(process, ConnPid),
            Opened = erlang:monotonic_time(millisecond),
            ets:insert(?TABLE, {Key, ConnPid, MonRef, Protocol, Opened}),
            {Lease, NewState} = lease(Holder, ConnPid, Protocol,
                                      touch(ConnPid, State#{limits := Limits#{ConnPid => Limit}})),
            {reply, {ok, ConnPid, Protocol, Lease}, NewState};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end.

%% Gives room to waiting requests, oldest first. A request whose caller
%% stopped is dropped.
serve_waiting(State = #{waiting := Waiting}) ->
    Alive = [W || W = #{from := {Pid, _Tag}} <- Waiting, erlang:is_process_alive(Pid)],
    serve_waiting(Alive, [], State#{waiting := []}).

serve_waiting([], Kept, State) ->
    State#{waiting := lists:reverse(Kept)};
serve_waiting([Request = #{from := From} | Rest], Kept, State) ->
    case attempt(Request, State) of
        {reply, Reply, NewState} ->
            gen_server:reply(From, Reply),
            serve_waiting(Rest, Kept, NewState);
        wait ->
            serve_waiting(Rest, [Request | Kept], State)
    end.

%% The number of leases a connection may carry. `infinity` is larger than
%% every integer in Erlang term order.
capacity(ConnPid, http, Limits) -> min(1, limit_value(maps:get(ConnPid, Limits, 1)));
capacity(ConnPid, http2, Limits) -> limit_value(maps:get(ConnPid, Limits, retired)).

limit_value(retired) -> 0;
limit_value(Limit) -> Limit.

%% The server's SETTINGS_MAX_CONCURRENT_STREAMS. A server that sets none
%% allows any number of streams.
stream_limit(Settings) ->
    maps:get(max_concurrent_streams, Settings, infinity).

%% Monitors the holder. The monitor reference is the lease.
lease(Holder, ConnPid, Protocol, State = #{leases := Leases}) ->
    Lease = erlang:monitor(process, Holder),
    {Lease, State#{leases := Leases#{Lease => {ConnPid, Protocol}}}}.

lease_count(ConnPid, Leases) ->
    length([Lease || Lease := {Pid, _} <- Leases, Pid =:= ConnPid]).

%% Removes a lease. A retired connection with no lease left is closed.
end_lease(Lease, State = #{leases := Leases, limits := Limits}) ->
    Rest = maps:remove(Lease, Leases),
    [close(ConnPid) || {ConnPid, _Protocol} <- maps:values(maps:with([Lease], Leases)),
                       maps:get(ConnPid, Limits, 1) =:= retired,
                       lease_count(ConnPid, Rest) =:= 0],
    State#{leases := Rest}.

%% Removes an abandoned lease. An HTTP/1.1 connection still carries the rest
%% of the response, so the pool closes it.
abandon_lease(Lease, State = #{leases := Leases}) ->
    [close(ConnPid) || {ConnPid, http} <- maps:values(maps:with([Lease], Leases))],
    end_lease(Lease, State).

close(ConnPid) ->
    gun:close(ConnPid),
    ets:match_delete(?TABLE, {'_', ConnPid, '_', '_', '_'}).

open_connection(Scheme, Host, Port, GunOpts) ->
    Transport = case Scheme of
        https -> tls;
        _ -> tcp
    end,
    ConnectTimeout = maps:get(connect_timeout, GunOpts),
    Protocols = maps:get(protocols, GunOpts),
    BaseOpts = #{
        transport => Transport,
        connect_timeout => ConnectTimeout,
        protocols => Protocols,
        %% A connection in the pool never connects again by itself. When it
        %% loses its socket, gun stops, the pool removes it, and the next
        %% request gets a new connection. With a retry, gun would hold new
        %% requests while it connects again, and a held request can get
        %% response headers and no body.
        retry => 0,
        domain_lookup_timeout => maps:get(domain_lookup_timeout, GunOpts),
        tls_handshake_timeout => maps:get(tls_handshake_timeout, GunOpts),
        %% gun tells the owner (this process) about every SETTINGS frame of
        %% the server, so the pool knows its stream limit.
        http2_opts => (maps:with([keepalive, keepalive_tolerance, max_concurrent_streams,
                                  initial_connection_window_size, initial_stream_window_size,
                                  closing_timeout], GunOpts))#{notify_settings_changed => true}
    },
    TlsOpts = case Transport of
        tls ->
            AlpnProtocols = resolve_alpn(Protocols),
            Trusted = case maps:get(certificate_authority_file, GunOpts, system) of
                system -> {cacerts, public_key:cacerts_get()};
                File -> {cacertfile, File}
            end,
            BaseOpts#{tls_opts => [
                {verify, verify_peer},
                Trusted,
                {depth, 3},
                {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]},
                {alpn_advertised_protocols, AlpnProtocols}
            ]};
        tcp -> BaseOpts
    end,
    Deadline = erlang:monotonic_time(millisecond) + ConnectTimeout,
    case gun:open(Host, Port, TlsOpts) of
        {ok, ConnPid} ->
            case gun:await_up(ConnPid, ConnectTimeout) of
                {ok, Protocol} ->
                    await_limit(ConnPid, Protocol, Deadline);
                {error, {down, {shutdown, Reason}}} ->
                    {error, Reason};
                {error, Reason} ->
                    %% `timeout`, or the connection process stopped.
                    gun:close(ConnPid),
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% Returns {ok, ConnPid, Protocol, Limit}. An HTTP/2 server must send
%% SETTINGS as its first frame (RFC 9113, section 3.4). The pool waits for
%% it until the connect deadline, so the stream limit is known before the
%% first request.
await_limit(ConnPid, http, _Deadline) ->
    {ok, ConnPid, http, 1};
await_limit(ConnPid, http2, Deadline) ->
    receive
        {gun_notify, ConnPid, settings_changed, Settings} ->
            {ok, ConnPid, http2, stream_limit(Settings)}
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        gun:close(ConnPid),
        {error, timeout}
    end.

schedule_idle_check() ->
    IdleTimeout = get_idle_timeout(),
    erlang:send_after(IdleTimeout, self(), check_idle).

%% Closes each connection that has no lease and was not used for longer
%% than the idle timeout. A connection that serves a long response is busy,
%% not idle.
reap_idle_connections(#{leases := Leases, last_used := LastUsed}) ->
    IdleTimeout = get_idle_timeout(),
    Now = erlang:monotonic_time(millisecond),
    lists:foreach(fun({_Key, ConnPid, _MonRef, _Protocol, Opened}) ->
        Used = maps:get(ConnPid, LastUsed, Opened),
        case Now - Used > IdleTimeout andalso lease_count(ConnPid, Leases) =:= 0 of
            true ->
                gun:close(ConnPid),
                ets:match_delete(?TABLE, {'_', ConnPid, '_', '_', '_'});
            false ->
                ok
        end
    end, ets:tab2list(?TABLE)).

log_gun_down(ConnPid, Protocol, Reason, Killed) ->
    case is_expected_disconnect(Reason, Killed) of
        true ->
            logger:info(
                "[dream_http] connection closed: pid=~p protocol=~p reason=~p",
                [ConnPid, Protocol, Reason]);
        false ->
            logger:warning(
                "[dream_http] connection down: pid=~p protocol=~p reason=~p killed_streams=~p",
                [ConnPid, Protocol, Reason, Killed])
    end.

is_expected_disconnect(Reason, 0) when Reason =:= closed; Reason =:= normal -> true;
is_expected_disconnect(_Reason, _Killed) -> false.

resolve_protocols(GunOpts, Transport) ->
    case maps:get(protocols, GunOpts, default) of
        default ->
            case Transport of
                tls -> [http2, http];
                tcp -> [http]
            end;
        http1_only -> [http];
        http2_only -> [http2];
        http2_preferred -> [http2, http]
    end.

resolve_alpn(Protocols) ->
    [alpn_protocol(Protocol) || Protocol <- Protocols].

alpn_protocol(http2) -> <<"h2">>;
alpn_protocol(http) -> <<"http/1.1">>.

get_idle_timeout() ->
    case ets:lookup(dream_http_client_transport_config, config) of
        [{config, Config}] ->
            element(3, Config);  % idle_timeout is the 3rd field (after tag + max_connections)
        [] ->
            60000
    end.

