-module(output_capture_ffi).
-export([capture/1]).

%% Runs Fun with a group leader that keeps what the process prints, and
%% returns {Value, Text}. A process that Fun spawns inherits the group
%% leader, so its output is kept too.
capture(Fun) ->
    Previous = group_leader(),
    Collector = spawn(fun() -> collect([]) end),
    group_leader(Collector, self()),
    Value = try Fun() after group_leader(Previous, self()) end,
    Reference = erlang:monitor(process, Collector),
    Collector ! {finish, self(), Reference},
    receive
        {captured, Reference, Text} ->
            erlang:demonitor(Reference, [flush]),
            {Value, Text}
    end.

collect(Parts) ->
    receive
        {io_request, From, ReplyAs, Request} ->
            {Reply, NewParts} = io_request(Request, Parts),
            From ! {io_reply, ReplyAs, Reply},
            collect(NewParts);
        {finish, From, Reference} ->
            From ! {captured, Reference, unicode:characters_to_binary(lists:reverse(Parts))}
    end.

io_request({put_chars, Encoding, Chars}, Parts) ->
    {ok, [unicode:characters_to_binary(Chars, Encoding) | Parts]};
io_request({put_chars, Encoding, Module, Function, Arguments}, Parts) ->
    io_request({put_chars, Encoding, apply(Module, Function, Arguments)}, Parts);
io_request({put_chars, Chars}, Parts) ->
    io_request({put_chars, latin1, Chars}, Parts);
io_request(_Request, Parts) ->
    {{error, request}, Parts}.
