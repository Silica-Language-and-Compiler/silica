%% The Erlang Mac peer of the basic exchange (examples/transport_pairs/usb_basic_exchange).
%%
%% It listens on a local TCP port with {packet, 4}; serial_to_tcp_bridge.py copies the board's USB-Serial-JTAG
%% bytes into that socket and back. It takes the board's one reading, {accel, #{x, y, z, at_ms}} (design
%% transport_serialization_design.md §13.4), prints its fields, answers {led, #{which => red, on => true}} (the
%% same 39 framed bytes the Silica peer sends: `deterministic` puts the map keys in term order, the order
%% Silica writes record fields), and closes. It prints fixed fields only, so its output can be compared.
-module(basic_peer).
-export([main/1]).

main([PortArg]) ->
    Port = list_to_integer(atom_to_list(PortArg)),
    {ok, L} = gen_tcp:listen(Port, [binary, {packet, 4}, {active, false}, {reuseaddr, true}, {ip, {127,0,0,1}}]),
    io:format("peer: listening on ~p~n", [Port]),
    {ok, S} = gen_tcp:accept(L, 20000),
    {ok, Bin} = gen_tcp:recv(S, 0, 20000),
    {accel, #{x := X, y := Y, z := Z, at_ms := T}} = binary_to_term(Bin),
    io:format("peer: reading x=~p y=~p z=~p at_ms=~p (~p bytes)~n", [X, Y, Z, T, byte_size(Bin)]),
    ok = gen_tcp:send(S, term_to_binary({led, #{which => red, on => true}}, [deterministic])),
    io:format("peer: reply led red on~n"),
    timer:sleep(200),
    gen_tcp:close(S),
    gen_tcp:close(L),
    halt(0).
