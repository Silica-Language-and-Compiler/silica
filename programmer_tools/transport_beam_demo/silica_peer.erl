%% The Erlang end of the demo (transport_serialization_design.md §13.4): listen with {packet, 4},
%% take one accelerometer reading as a term, answer one LED command, and print both.
-module(silica_peer).
-export([main/1]).

main([PortArg]) ->
    Port = list_to_integer(atom_to_list(PortArg)),
    {ok, L} = gen_tcp:listen(Port, [binary, {packet, 4}, {active, false}, {reuseaddr, true}, {ip, {127,0,0,1}}]),
    io:format("peer: listening on ~p~n", [Port]),
    {ok, S} = gen_tcp:accept(L, 20000),
    {ok, Bin} = gen_tcp:recv(S, 0, 20000),
    Term = binary_to_term(Bin),
    io:format("peer: got ~p (~p bytes)~n", [Term, byte_size(Bin)]),
    {accel, #{x := X, y := Y, z := Z, at_ms := T}} = Term,
    io:format("peer: x=~p y=~p z=~p at_ms=~p~n", [X, Y, Z, T]),
    ok = gen_tcp:send(S, term_to_binary({led, #{which => red, on => true}})),
    timer:sleep(200),
    gen_tcp:close(S),
    gen_tcp:close(L),
    halt(0).
