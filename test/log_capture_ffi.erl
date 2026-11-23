-module(log_capture_ffi).

%% Keeps the log events of dream_http_client while a function
%% runs, so a test can assert the exact log output.

-export([capture/3, log/2]).

%% Runs Fun, then waits until Count log lines of the client arrived, or
%% until TimeoutMs passed, and returns {Value, Lines}. Other processes write
%% the lines, often after Fun returned, so the wait is for the lines, not
%% for a fixed time. A test that expects no line passes 0 and waits the
%% whole timeout. Each line is "level: message", with every pid written as
%% <pid>.
capture(Fun, Count, TimeoutMs) ->
    Id = list_to_atom("log_capture_" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = logger:add_handler(Id, ?MODULE, #{config => #{pid => self()}}),
    Value = Fun(),
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    Lines = collect(Count, Deadline, []),
    ok = logger:remove_handler(Id),
    {Value, Lines ++ drain([])}.

%% Every log line of the client comes from dream_http_client_log, and the
%% logger macros there put that module in the metadata, so the handler
%% keeps the events of that module.
log(#{level := Level, msg := Msg, meta := #{mfa := {dream_http_client_log, _, _}}},
    #{config := #{pid := Pid}}) ->
    Pid ! {log_capture, Level, text(Msg)};
log(_Event, _Config) ->
    ok.

text({string, String}) -> unicode:characters_to_binary(String);
text({report, Report}) -> unicode:characters_to_binary(io_lib:format("~p", [Report]));
text({Format, Args}) -> unicode:characters_to_binary(io_lib:format(Format, Args)).

%% Collects lines until Count arrived (Count 0 waits until the deadline),
%% then the lines that are already in the mailbox.
collect(Count, _Deadline, Lines) when Count > 0, length(Lines) >= Count ->
    Lines ++ drain([]);
collect(Count, Deadline, Lines) ->
    Wait = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {log_capture, Level, Text} ->
            collect(Count, Deadline, Lines ++ [line(Level, Text)])
    after Wait ->
        Lines
    end.

drain(Lines) ->
    receive
        {log_capture, Level, Text} -> drain(Lines ++ [line(Level, Text)])
    after 0 ->
        Lines
    end.

line(Level, Text) ->
    <<(atom_to_binary(Level))/binary, ": ", (hide_pids(Text))/binary>>.

hide_pids(Text) ->
    re:replace(Text, "<[0-9]+\\.[0-9]+\\.[0-9]+>", "<pid>", [global, {return, binary}]).
