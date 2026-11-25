-module(dream_http_client_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    ets:new(dream_http_client_ref_mapping, [set, public, named_table]),
    ets:new(dream_http_client_stream_recorders, [set, public, named_table]),
    ets:new(dream_http_client_transport_config, [set, public, named_table]),
    ets:new(dream_http_client_connections, [bag, public, named_table]),
    %% The default log level is the log_level of client.transport_config().
    dream_http_shim:apply_log_level('dream_http_client@client':transport_config()),
    dream_http_client_sup:start_link().

stop(_State) ->
    ok.
