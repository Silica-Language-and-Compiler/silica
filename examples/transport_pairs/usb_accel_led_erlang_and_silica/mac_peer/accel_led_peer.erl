%% The Erlang Mac peer of the accel/LED pair (examples/transport_pairs/usb_accel_led_erlang_and_silica).
%%
%% It listens on a local TCP port with {packet, 4}; serial_to_tcp_bridge.py copies the board's USB-Serial-JTAG
%% bytes into that socket and back, so each board frame (a 4-byte length prefix and an ETF term) arrives as one
%% packet. For every reading {accel, #{x, y, z, at_ms}} it answers one LED command by the pair's rule,
%% z > 256 -> {led, #{which => red, on => true}}, otherwise on => false, exactly as the Silica peer
%% (dangerous_accel_led_peer.silica) does. The reply is encoded with term_to_binary(T, [deterministic]) so the
%% map keys go out in term order (on, which), the order Silica's encode writes a record's fields: the two peers
%% send byte-identical replies. (Without `deterministic`, OTP 26 and later order small-map atom keys by the
%% atom table.) The board ends the stream with {done, N}, N the readings it sent; the peer stops on it. As a
%% fallback it also stops when the socket closes or no frame arrives for 3 s after its last reply. It prints
%% only fixed fields (not the map with ~p, whose key order is not stable), so its output can be compared.
-module(accel_led_peer).
-export([main/1]).

main([PortArg]) ->
    Port = list_to_integer(atom_to_list(PortArg)),
    {ok, L} = gen_tcp:listen(Port, [binary, {packet, 4}, {active, false}, {reuseaddr, true}, {ip, {127,0,0,1}}]),
    io:format("peer: listening on ~p~n", [Port]),
    {ok, S} = gen_tcp:accept(L, 20000),
    N = serve(S, 20000, 0),
    io:format("peer: answered ~p readings~n", [N]),
    timer:sleep(200),
    gen_tcp:close(S),
    gen_tcp:close(L),
    halt(0).

serve(S, Timeout, N) ->
    case gen_tcp:recv(S, 0, Timeout) of
        {ok, Bin} ->
            case binary_to_term(Bin) of
                {accel, #{x := X, y := Y, z := Z, at_ms := T}} ->
                    io:format("peer: reading x=~p y=~p z=~p at_ms=~p (~p bytes)~n", [X, Y, Z, T, byte_size(Bin)]),
                    On = Z > 256,
                    io:format("peer: reply led red ~s~n", [case On of true -> "on"; false -> "off" end]),
                    ok = gen_tcp:send(S, term_to_binary({led, #{which => red, on => On}}, [deterministic])),
                    serve(S, 3000, N + 1);
                {done, Sent} ->
                    io:format("peer: board done after ~p readings~n", [Sent]),
                    N
            end;
        {error, _ClosedOrTimeout} ->
            N
    end.
