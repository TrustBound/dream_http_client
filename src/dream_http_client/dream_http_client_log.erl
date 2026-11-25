-module(dream_http_client_log).

%% The one place where dream_http_client writes to the log. Every log line
%% of the client goes through this module, and the `log_level` setting is
%% the OTP logger module level of this module (logger:set_module_level/2).
%% The logger macros add this module to the metadata of each event, so the
%% module level applies to every line, and only to the lines of the client:
%% the primary level and the logging of other applications do not change.

-export([set_level/1, info/2, warning/2, warning/1]).

-include_lib("kernel/include/logger.hrl").

%% Sets the lowest level that the client writes: debug, info, warning,
%% error or none.
set_level(Level) ->
    logger:set_module_level(?MODULE, Level).

info(Format, Args) ->
    ?LOG_INFO(Format, Args).

warning(Format, Args) ->
    ?LOG_WARNING(Format, Args).

%% A warning with a message from Gleam code.
warning(Message) ->
    ?LOG_WARNING("~ts", [Message]),
    nil.
