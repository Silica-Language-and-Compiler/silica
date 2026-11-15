%% The Erlang status side of examples/transport_pairs/ethernet_mac_silica_remote_erlang (run.sh): it runs on the
%% Linux remote (OTP 27), LISTENS on 0.0.0.0:4550 ({ip, {0,0,0,0}}), and the Silica accel side on the Mac (the Mac
%% end of ../ethernet_direct) dials it. There is one TCP connection, and requests flow both ways over it:
%%
%%   peer -> this side  {request, 1 | 3 | 5, {accel, #{x, y, z, at_ms}}}   this side -> {reply, Id, {led, #{which => red, on => Z > 256}}}
%%   this side -> peer  {request, 2 | 4 | 6, status}                       peer -> {reply, Id, {status, #{host, uptime_ms, requests_seen}}}
%%
%% These are the Erlang forms of the Silica terms in ../ethernet_direct/dangerous_ethernet_direct_pair.silica: a
%% Silica tagged tuple (:led, r) is the tuple {led, R}, a record is a map with atom keys, a Silica string (the
%% status host) is an Erlang binary, a boolean is the atom true or false. Each frame is one ETF term behind a
%% 4-byte length prefix ({packet, 4}, Silica's wireframe).
%%
%% It does what the Silica status side does and prints the same lines: it accepts one connection, sends its three
%% status requests 250 ms apart, matches each status reply to its request by id, and answers each accel request at
%% once by the rule (the red LED on when z > 256). Every term it sends is encoded with term_to_binary(T,
%% [deterministic]): map keys in term order, the order in which Silica's encode writes a record's fields, so the
%% bytes are what the Silica status side would send for the same term. It also checks the other way: every frame
%% it receives must equal term_to_binary(binary_to_term(F), [deterministic]) byte for byte, and it reports that in
%% its "etf:" line. Frames are decoded with [safe] (no new atoms from the network).
%%
%% Complete: 3 replies matched and 3 accel requests answered. It prints "pair complete", waits 1.5 s (the peer
%% reads the last reply), closes the connection and the listener and exits 0. No completion 45 s after start
%% prints "timeout: pair not complete" and exits 5. run.sh also runs it under `timeout 90`.
%%
%%   erl -noshell -pa DIR -s status_side_peer main any|loopback PORT
%%
%% SECURITY: plain TCP, no authentication and no encryption. While it listens on every interface, anyone who can
%% reach the port can connect (see README.md).
-module(status_side_peer).
-export([main/1]).

-define(TIMEOUT_MS, 45000).
-define(COUNT, 3).

main([Bind, PortA]) ->
    Port = list_to_integer(atom_to_list(PortA)),
    Ip = case Bind of any -> {0, 0, 0, 0}; loopback -> {127, 0, 0, 1} end,
    T0 = erlang:monotonic_time(millisecond),
    case gen_tcp:listen(Port, [binary, {packet, 4}, {active, false}, {reuseaddr, true}, {nodelay, true}, {ip, Ip}]) of
        {ok, L} ->
            io:format("listening~n"),
            accept(L, T0);
        {error, Why} ->
            io:format("listen failed ~p~n", [Why]),
            halt(1)
    end.

accept(L, T0) ->
    Left = max(0, ?TIMEOUT_MS - (erlang:monotonic_time(millisecond) - T0)),
    case gen_tcp:accept(L, Left) of
        {ok, S} ->
            io:format("accepted~n"),
            erlang:send_after(Left, self(), timeout),
            ok = inet:setopts(S, [{active, true}]),
            self() ! {next, S},
            loop(#{sock => S, listener => L, sent => 0, waiting => [], got => 0, served => 0, frames => 0, odd => 0});
        {error, timeout} ->
            timed_out();
        {error, Why} ->
            io:format("accept failed ~p~n", [Why]),
            timed_out()
    end.

send(S, T) -> ok = gen_tcp:send(S, term_to_binary(T, [deterministic])).

loop(St = #{sock := S}) ->
    receive
        {next, S} ->
            loop(send_next(St));
        {tcp, S, Bin} ->
            loop(maybe_done(frame(Bin, St)));
        {tcp_closed, S} ->
            io:format("accepted connection down before completion: closed~n"),
            receive timeout -> timed_out() end;
        timeout ->
            timed_out();
        _Stale ->
            loop(St)
    end.

send_next(St = #{sock := S, sent := K, waiting := W}) ->
    Id = 2 * K + 2,
    send(S, {request, Id, status}),
    case K + 1 < ?COUNT of
        true -> erlang:send_after(250, self(), {next, S});
        false -> ok
    end,
    St#{sent := K + 1, waiting := [Id | W]}.

frame(Bin, St = #{frames := F, odd := Odd}) ->
    T = binary_to_term(Bin, [safe]),
    Canon = Bin =:= term_to_binary(T, [deterministic]),
    St1 = St#{frames := F + 1, odd := case Canon of true -> Odd; false -> Odd + 1 end},
    case Canon of
        true -> ok;
        false -> io:format("etf: frame not in deterministic form: ~w~n", [Bin])
    end,
    take(T, St1).

take({reply, Id, {status, #{host := Host, uptime_ms := Up, requests_seen := Seen}}}, St = #{waiting := W, got := G})
  when is_integer(Id), is_binary(Host), is_integer(Up), is_integer(Seen) ->
    case lists:member(Id, W) of
        true ->
            io:format("request ~b status -> reply status host=~s uptime_ms=~b requests_seen=~b~n", [Id, Host, Up, Seen]),
            St#{waiting := lists:delete(Id, W), got := G + 1};
        false ->
            io:format("reply to unknown id ~b~n", [Id]),
            St
    end;
take({request, Id, {accel, #{x := X, y := Y, z := Z, at_ms := At}}}, St = #{sock := S, served := N})
  when is_integer(Id), is_integer(X), is_integer(Y), is_integer(Z), is_integer(At) ->
    On = Z > 256,
    send(S, {reply, Id, {led, #{which => red, on => On}}}),
    io:format("peer request ~b accel x=~b y=~b z=~b at_ms=~b -> reply led red ~s~n",
              [Id, X, Y, Z, At, case On of true -> "on"; false -> "off" end]),
    St#{served := N + 1};
take(Other, St) ->
    io:format("rejected ~p~n", [Other]),
    St.

maybe_done(#{sent := ?COUNT, got := ?COUNT, served := ?COUNT, waiting := [], sock := S, listener := L, frames := F, odd := Odd}) ->
    io:format("etf: ~b frames received, ~b in deterministic form~n", [F, F - Odd]),
    io:format("pair complete: 3 replies matched, 3 peer requests answered~n"),
    timer:sleep(1500),
    gen_tcp:close(S),
    gen_tcp:close(L),
    halt(0);
maybe_done(St) ->
    St.

timed_out() ->
    io:format("timeout: pair not complete~n"),
    halt(5).
