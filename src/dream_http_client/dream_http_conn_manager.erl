-module(dream_http_conn_manager).
-behaviour(gen_server).

-export([start_link/0, ensure_connection/4, release/1, abandon/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TABLE, dream_http_client_connections).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Gives the calling process a connection for one request, and a lease on it.
%% Returns {ok, ConnPid, Protocol, Lease} or {error, Reason}.
%%
%% A connection with a lease is busy: the pool gives it to no other request
%% while it has a free connection, or while it can open a new one. The caller
%% gives the lease back with release/1 when the response is complete, or
%% with abandon/1 when the response did not end. When the caller stops with
%% the lease, the pool treats the lease as abandoned.
ensure_connection(Scheme, Host, Port, GunOpts) ->
    gen_server:call(?MODULE, {ensure_connection, Scheme, Host, Port, GunOpts}, 30000).

%% The response on the leased connection is complete. The connection is free.
release(Lease) ->
    gen_server:cast(?MODULE, {release, Lease}).

%% The response on the leased connection did not end. An HTTP/1.1 connection
%% would send the next request behind the rest of that response, so the pool
%% closes it. An HTTP/2 connection is free again.
abandon(Lease) ->
    gen_server:cast(?MODULE, {abandon, Lease}).

%% Update LastUsed for a connection entry. A connection that stopped has no
%% entry, and nothing changes.
%% bag tables don't support select_replace, so we delete+insert.
touch(ConnPid) ->
    Now = erlang:monotonic_time(millisecond),
    Entries = ets:match_object(?TABLE, {'_', ConnPid, '_', '_', '_'}),
    ets:match_delete(?TABLE, {'_', ConnPid, '_', '_', '_'}),
    [ets:insert(?TABLE, {Key, ConnPid, MonRef, Protocol, Now})
     || {Key, _, MonRef, Protocol, _OldLastUsed} <- Entries],
    ok.

%% ============================================================================
%% gen_server callbacks
%% ============================================================================

init([]) ->
    %% After a restart, the table can still hold the connections of the old
    %% manager. gun closes a connection when its owner stops, so none of them
    %% can be used again.
    ets:delete_all_objects(?TABLE),
    schedule_idle_check(),
    %% `leases` maps each lease to {ConnPid, Protocol}. A lease is the
    %% reference of the monitor on the process that holds it.
    {ok, #{leases => #{}}}.

%% The caller of ensure_connection/4 holds the lease.
handle_call({ensure_connection, Scheme, Host, Port, GunOpts}, {Holder, _Tag}, State) ->
    Transport = case Scheme of
        https -> tls;
        _ -> tcp
    end,
    Protocols = resolve_protocols(GunOpts, Transport),
    ResolvedOpts = GunOpts#{protocols => Protocols},
    %% Requests that trust different certificate authorities never share a
    %% connection.
    Key = {Scheme, Host, Port, Protocols, maps:get(certificate_authority_file, GunOpts, system)},
    %% A connection that stopped stays in the table until its 'DOWN'
    %% message removes it.
    Alive = [E || {_, Pid, _, _, _} = E <- ets:lookup(?TABLE, Key), erlang:is_process_alive(Pid)],
    MaxConns = maps:get(max_connections, GunOpts, 50),
    #{leases := Leases} = State,
    Loads = [{lease_count(Pid, Leases), E} || {_, Pid, _, _, _} = E <- Alive],
    case choose(lists:keysort(1, Loads), length(Alive) < MaxConns) of
        {use, {_, Pid, _, Proto, _}} ->
            touch(Pid),
            {Lease, NewState} = lease(Holder, Pid, Proto, State),
            {reply, {ok, Pid, Proto, Lease}, NewState};
        open ->
            case open_connection(Scheme, Host, Port, ResolvedOpts) of
                {ok, ConnPid, Protocol} ->
                    MonRef = erlang:monitor(process, ConnPid),
                    Now = erlang:monotonic_time(millisecond),
                    ets:insert(?TABLE, {Key, ConnPid, MonRef, Protocol, Now}),
                    {Lease, NewState} = lease(Holder, ConnPid, Protocol, State),
                    {reply, {ok, ConnPid, Protocol, Lease}, NewState};
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end
    end.

%% A lease of a manager that restarted is not in `leases`, and nothing
%% changes.
handle_cast({release, Lease}, State = #{leases := Leases}) ->
    erlang:demonitor(Lease, [flush]),
    [touch(ConnPid) || {ConnPid, _Protocol} <- maps:values(maps:with([Lease], Leases))],
    {noreply, State#{leases := maps:remove(Lease, Leases)}};
handle_cast({abandon, Lease}, State) ->
    erlang:demonitor(Lease, [flush]),
    {noreply, abandon_lease(Lease, State)};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', MonRef, process, Pid, _Reason}, State = #{leases := Leases}) ->
    case maps:is_key(MonRef, Leases) of
        %% The process that held the lease stopped.
        true ->
            {noreply, abandon_lease(MonRef, State)};
        %% A connection stopped.
        false ->
            ets:match_delete(?TABLE, {'_', Pid, '_', '_', '_'}),
            {noreply, State}
    end;

handle_info(check_idle, State = #{leases := Leases}) ->
    reap_idle_connections(Leases),
    schedule_idle_check(),
    {noreply, State};

handle_info({gun_up, _ConnPid, _Protocol}, State) ->
    {noreply, State};

handle_info({gun_down, ConnPid, Protocol, Reason, KilledStreams}, State) ->
    log_gun_down(ConnPid, Protocol, Reason, length(KilledStreams)),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

%% ============================================================================
%% Internal
%% ============================================================================

%% Picks the connection for a request. Loads is a list of
%% {LeaseCount, Entry}, fewest leases first.
%%
%% 1. A connection with no lease: use it.
%% 2. Every connection is busy, and the pool can open one more: open it.
%% 3. Every connection is busy at max_connections: use the connection with
%%    the fewest leases.
choose([{0, Entry} | _], _CanOpen) -> {use, Entry};
choose(_Loads, true) -> open;
choose([{_, Entry} | _], false) -> {use, Entry}.

%% Monitors the holder. The monitor reference is the lease.
lease(Holder, ConnPid, Protocol, State = #{leases := Leases}) ->
    Lease = erlang:monitor(process, Holder),
    {Lease, State#{leases := Leases#{Lease => {ConnPid, Protocol}}}}.

lease_count(ConnPid, Leases) ->
    length([Lease || Lease := {Pid, _} <- Leases, Pid =:= ConnPid]).

%% Removes an abandoned lease. An HTTP/1.1 connection still carries the rest
%% of the response, so the pool closes it, unless another request still
%% uses it (only at max_connections). An HTTP/2 connection is free again.
abandon_lease(Lease, State = #{leases := Leases}) ->
    Rest = maps:remove(Lease, Leases),
    [close(ConnPid) || {ConnPid, http} <- maps:values(maps:with([Lease], Leases)),
                       lease_count(ConnPid, Rest) =:= 0],
    State#{leases := Rest}.

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
        retry => maps:get(retry, GunOpts),
        retry_timeout => maps:get(retry_timeout, GunOpts),
        domain_lookup_timeout => maps:get(domain_lookup_timeout, GunOpts),
        tls_handshake_timeout => maps:get(tls_handshake_timeout, GunOpts),
        http2_opts => maps:with([keepalive, keepalive_tolerance, max_concurrent_streams,
                                 initial_connection_window_size, initial_stream_window_size,
                                 closing_timeout], GunOpts)
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
    case gun:open(Host, Port, TlsOpts) of
        {ok, ConnPid} ->
            case gun:await_up(ConnPid, ConnectTimeout) of
                {ok, Protocol} ->
                    {ok, ConnPid, Protocol};
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

schedule_idle_check() ->
    IdleTimeout = get_idle_timeout(),
    erlang:send_after(IdleTimeout, self(), check_idle).

%% Closes each connection that has no lease and was not used for longer
%% than the idle timeout. A connection that serves a long response is busy,
%% not idle.
reap_idle_connections(Leases) ->
    IdleTimeout = get_idle_timeout(),
    Now = erlang:monotonic_time(millisecond),
    lists:foreach(fun({_Key, ConnPid, _MonRef, _Protocol, LastUsed}) ->
        case Now - LastUsed > IdleTimeout andalso lease_count(ConnPid, Leases) =:= 0 of
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

