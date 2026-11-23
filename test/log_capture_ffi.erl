-module(log_capture_ffi).

%% Keeps the log events of the dream_http_client modules while a function
%% runs, so a test can assert the exact log output.

-export([capture/2, log/2]).

%% Runs Fun, waits WaitMs for log events that other processes send late,
%% and returns {Value, Lines}. Each line is "level: message", with every
%% pid written as <pid>.
capture(Fun, WaitMs) ->
    Id = list_to_atom("log_capture_" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = logger:add_handler(Id, ?MODULE, #{config => #{pid => self()}}),
    Value = Fun(),
    timer:sleep(WaitMs),
    ok = logger:remove_handler(Id),
    {Value, collect([])}.

%% The client logs through logger:info/2 and logger:warning/2, which add
%% no module to the metadata, so the handler keeps the events by their text.
log(#{level := Level, msg := Msg}, #{config := #{pid := Pid}}) ->
    Text = text(Msg),
    case is_client_message(Text) of
        true -> Pid ! {log_capture, Level, Text};
        false -> ok
    end.

is_client_message(Text) ->
    binary:match(Text, [<<"[dream_http]">>, <<"passing through raw bytes">>]) =/= nomatch.

text({string, String}) -> unicode:characters_to_binary(String);
text({report, Report}) -> unicode:characters_to_binary(io_lib:format("~p", [Report]));
text({Format, Args}) -> unicode:characters_to_binary(io_lib:format(Format, Args)).

collect(Lines) ->
    receive
        {log_capture, Level, Text} ->
            Line = <<(atom_to_binary(Level))/binary, ": ", (hide_pids(Text))/binary>>,
            collect([Line | Lines])
    after 0 ->
        lists:reverse(Lines)
    end.

hide_pids(Text) ->
    re:replace(Text, "<[0-9]+\\.[0-9]+\\.[0-9]+>", "<pid>", [global, {return, binary}]).
