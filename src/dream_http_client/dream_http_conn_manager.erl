-module(dream_http_conn_manager).
-behaviour(gen_server).

-export([start_link/0, ensure_connection/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TABLE, dream_http_client_connections).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Cold path: create or reuse a connection via the gen_server.
ensure_connection(Scheme, Host, Port, GunOpts) ->
    gen_server:call(?MODULE, {ensure_connection, Scheme, Host, Port, GunOpts}, 30000).

%% Update LastUsed for a connection entry.
%% bag tables don't support select_replace, so we delete+insert.
touch(ConnPid) ->
    Now = erlang:monotonic_time(millisecond),
    [{Key, _, MonRef, Protocol, _OldLastUsed}] =
        ets:match_object(?TABLE, {'_', ConnPid, '_', '_', '_'}),
    ets:match_delete(?TABLE, {'_', ConnPid, '_', '_', '_'}),
    ets:insert(?TABLE, {Key, ConnPid, MonRef, Protocol, Now}).

%% ============================================================================
%% gen_server callbacks
%% ============================================================================

init([]) ->
    %% After a restart, the table can still hold the connections of the old
    %% manager. gun closes a connection when its owner stops, so none of them
    %% can be used again.
    ets:delete_all_objects(?TABLE),
    schedule_idle_check(),
    {ok, #{}}.

handle_call({ensure_connection, Scheme, Host, Port, GunOpts}, _From, State) ->
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
    AliveCount = length(Alive),
    case AliveCount < MaxConns of
        true ->
            case open_connection(Scheme, Host, Port, ResolvedOpts) of
                {ok, ConnPid, Protocol} ->
                    MonRef = erlang:monitor(process, ConnPid),
                    Now = erlang:monotonic_time(millisecond),
                    ets:insert(?TABLE, {Key, ConnPid, MonRef, Protocol, Now}),
                    {reply, {ok, ConnPid, Protocol}, State};
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end;
        false ->
            %% At max — round-robin an existing one
            Idx = erlang:unique_integer([monotonic, positive]) rem AliveCount,
            {_, Pid, _, Proto, _} = lists:nth(Idx + 1, Alive),
            touch(Pid),
            {reply, {ok, Pid, Proto}, State}
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', _MonRef, process, ConnPid, _Reason}, State) ->
    ets:match_delete(?TABLE, {'_', ConnPid, '_', '_', '_'}),
    {noreply, State};

handle_info(check_idle, State) ->
    reap_idle_connections(),
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

reap_idle_connections() ->
    IdleTimeout = get_idle_timeout(),
    Now = erlang:monotonic_time(millisecond),
    lists:foreach(fun({_Key, ConnPid, _MonRef, _Protocol, LastUsed}) ->
        case Now - LastUsed > IdleTimeout of
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

