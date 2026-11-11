%% The Erlang accel side of examples/transport_pairs/ethernet_mac_erlang_remote_silica (run.sh): it runs on the
%% Mac and DIALS the Silica status side (the Linux end of ../ethernet_direct, listening on "listen:any:4550").
%% There is one TCP connection, and requests flow both ways over it:
%%
%%   this side -> peer  {request, 1 | 3 | 5, {accel, #{x, y, z, at_ms}}}   peer -> {reply, Id, {led, #{which => red, on => Z > 256}}}
%%   peer -> this side  {request, 2 | 4 | 6, status}                       this side -> {reply, Id, {status, #{host, uptime_ms, requests_seen}}}
%%
%% These are the Erlang forms of the Silica terms in ../ethernet_direct/dangerous_ethernet_direct_pair.silica: a
%% Silica tagged tuple (:accel, r) is the tuple {accel, R}, a record is a map with atom keys, a Silica string (the
%% status host) is an Erlang binary, a boolean is the atom true or false. Each frame is one ETF term behind a
%% 4-byte length prefix ({packet, 4}, Silica's wireframe).
%%
%% It does what the Silica accel side does and prints the same lines: on connect it sends its three accel
%% requests 250 ms apart, matches each led reply to its request by id, and answers each status request at once.
%% Every term it sends is encoded with term_to_binary(T, [deterministic]): map keys in term order, the order in
%% which Silica's encode writes a record's fields, so the bytes are what the Silica accel side would send for the
%% same term. It also checks the other way: every frame it receives must equal term_to_binary(binary_to_term(F),
%% [deterministic]) byte for byte, and it reports that in its "etf:" line. Frames are decoded with [safe] (no
%% new atoms from the network).
%%
%% Complete: 3 replies matched and 3 status requests answered. It prints "pair complete", waits 1.5 s (the peer
%% reads the last reply), closes and exits 0. A refused dial is retried every 500 ms, at most 80 times, silently;
%% a connection lost before completion is dialed again with a fresh state. No completion 45 s after start prints
%% "timeout: pair not complete" and exits 5.
%%
%%   erl -noshell -pa DIR -s accel_side_peer main HOST PORT STATUS_HOST_NAME
%%
%% SECURITY: plain TCP, no authentication and no encryption (see README.md).
-module(accel_side_peer).
-export([main/1]).

-define(TIMEOUT_MS, 45000).
-define(COUNT, 3).

main([HostA, PortA, NameA]) ->
    Host = atom_to_list(HostA),
    Port = list_to_integer(atom_to_list(PortA)),
    Name = list_to_binary(atom_to_list(NameA)),
    erlang:send_after(?TIMEOUT_MS, self(), timeout),
    start(Host, Port, Name, 0).

start(Host, Port, Name, Tries) ->
    case gen_tcp:connect(Host, Port, [binary, {packet, 4}, {active, true}, {nodelay, true}], 5000) of
        {ok, S} ->
            io:format("connected~n"),
            self() ! {next, S},
            loop(#{sock => S, host => Host, port => Port, name => Name, tries => Tries,
                   sent => 0, waiting => [], got => 0, served => 0, frames => 0, odd => 0});
        {error, _Why} when Tries < 80 ->
            receive timeout -> timed_out() after 500 -> start(Host, Port, Name, Tries + 1) end;
        {error, _Why} ->
            receive timeout -> timed_out() end
    end.

%% The synthetic reading of the k-th accel request (k = 0, 1, 2; id 2k + 1), as in the Silica source.
reading(0) -> {1, -2, 512, 250};
reading(1) -> {3, 1, 100, 500};
reading(2) -> {-4, 0, 300, 750}.

send(S, T) -> ok = gen_tcp:send(S, term_to_binary(T, [deterministic])).

loop(St = #{sock := S}) ->
    receive
        {next, S} ->
            loop(send_next(St));
        {tcp, S, Bin} ->
            loop(maybe_done(frame(Bin, St)));
        {tcp_closed, S} ->
            #{host := H, port := P, name := N, tries := T} = St,
            gen_tcp:close(S),
            start(H, P, N, T + 1);
        timeout ->
            timed_out();
        _Stale ->
            loop(St)
    end.

send_next(St = #{sock := S, sent := K, waiting := W}) ->
    Id = 2 * K + 1,
    {X, Y, Z, At} = reading(K),
    send(S, {request, Id, {accel, #{x => X, y => Y, z => Z, at_ms => At}}}),
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

take({reply, Id, {led, #{which := _Which, on := On}}}, St = #{waiting := W, got := G}) when is_integer(Id) ->
    case lists:member(Id, W) of
        true ->
            {X, Y, Z, At} = reading((Id - 1) div 2),
            io:format("request ~b accel x=~b y=~b z=~b at_ms=~b -> reply led red ~s~n",
                      [Id, X, Y, Z, At, case On of true -> "on"; false -> "off" end]),
            St#{waiting := lists:delete(Id, W), got := G + 1};
        false ->
            io:format("reply to unknown id ~b~n", [Id]),
            St
    end;
take({request, Id, status}, St = #{sock := S, served := N, name := Name}) when is_integer(Id) ->
    Seen = N + 1,
    {UpMs, _} = erlang:statistics(wall_clock),
    send(S, {reply, Id, {status, #{host => Name, uptime_ms => UpMs, requests_seen => Seen}}}),
    io:format("peer request ~b status -> reply status requests_seen=~b~n", [Id, Seen]),
    St#{served := Seen};
take(Other, St) ->
    io:format("rejected ~p~n", [Other]),
    St.

maybe_done(#{sent := ?COUNT, got := ?COUNT, served := ?COUNT, waiting := [], sock := S, frames := F, odd := Odd}) ->
    io:format("etf: ~b frames received, ~b in deterministic form~n", [F, F - Odd]),
    io:format("pair complete: 3 replies matched, 3 peer requests answered~n"),
    timer:sleep(1500),
    gen_tcp:close(S),
    halt(0);
maybe_done(St) ->
    St.

timed_out() ->
    io:format("timeout: pair not complete~n"),
    halt(5).
