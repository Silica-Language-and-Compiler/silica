-module(spawn_bench).
-export([main/0, main/1, run/1, run/2]).

-define(DEFAULT_COUNT, 1000000).

%% Entry point for `escript`-style or `erl -noshell -run` invocation.
main() ->
    main(init:get_plain_arguments()).

%% Usage: main([ "[N]", "[--send]" ]) -- args may appear in any order.
main(Args) ->
    Send = lists:member("--send", Args),
    case [A || A <- Args, A =/= "--send"] of
        [] -> run(?DEFAULT_COUNT, #{send => Send});
        [N] -> run(list_to_integer(N), #{send => Send})
    end.

run(Count) ->
    run(Count, #{}).

run(Count, Opts) ->
    %% Default max process limit is 262144; it must be raised at VM start
    %% with `+P`. Fail early with a useful message if it is too low.
    Limit = erlang:system_info(process_limit),
    case Limit < Count + 1000 of
        true ->
            io:format("process_limit is ~p, need > ~p. Start with: erl +P ~p~n",
                      [Limit, Count, Count * 2]),
            halt(1);
        false ->
            ok
    end,

    erlang:garbage_collect(),
    MemBefore = erlang:memory(),
    ProcsBefore = erlang:system_info(process_count),

    T0 = erlang:monotonic_time(),
    Pids = spawn_all(Count, []),
    T1 = erlang:monotonic_time(),

    MemAfter = erlang:memory(),
    ProcsAfter = erlang:system_info(process_count),

    SpawnUs = erlang:convert_time_unit(T1 - T0, native, microsecond),
    report(Count, SpawnUs, MemBefore, MemAfter, ProcsBefore, ProcsAfter),

    case maps:get(send, Opts, false) of
        true -> send_phase(Pids, Count);
        false -> ok
    end,

    %% Tear down and time it too.
    T2 = erlang:monotonic_time(),
    stop_all(Pids),
    T3 = erlang:monotonic_time(),
    KillUs = erlang:convert_time_unit(T3 - T2, native, microsecond),
    io:format("Teardown time:      ~.3f s~n", [KillUs / 1.0e6]),
    ok.

%% Each process blocks in receive so it stays alive until told to stop.
spawn_all(0, Acc) -> Acc;
spawn_all(N, Acc) -> spawn_all(N - 1, [spawn(fun loop/0) | Acc]).

loop() ->
    receive
        {ping, From} ->
            From ! {pong, self()},
            loop();
        stop ->
            ok
    end.

%% Send a ping to every process and wait for every pong, so the time covers
%% delivery and the receiving process actually running, not just enqueueing.
send_phase(Pids, Count) ->
    Self = self(),
    MemBefore = erlang:memory(),
    T0 = erlang:monotonic_time(),
    [P ! {ping, Self} || P <- Pids],
    T1 = erlang:monotonic_time(),
    wait_pongs(Count),
    T2 = erlang:monotonic_time(),
    MemAfter = erlang:memory(),
    SendUs = erlang:convert_time_unit(T1 - T0, native, microsecond),
    RoundUs = erlang:convert_time_unit(T2 - T0, native, microsecond),
    io:format("~n=== Send benchmark ===~n"),
    io:format("Send time:          ~.3f s (~.3f us/message)~n",
              [SendUs / 1.0e6, SendUs / Count]),
    io:format("Send + all replies: ~.3f s (~p msgs/s round trip)~n",
              [RoundUs / 1.0e6, round(Count / (RoundUs / 1.0e6))]),
    io:format("Memory change:      ~s~n",
              [fmt(mem(total, MemAfter) - mem(total, MemBefore))]).

wait_pongs(0) -> ok;
wait_pongs(N) ->
    receive {pong, _} -> wait_pongs(N - 1) end.

stop_all(Pids) ->
    Refs = [begin
                Ref = erlang:monitor(process, P),
                P ! stop,
                Ref
            end || P <- Pids],
    [receive {'DOWN', Ref, process, _, _} -> ok end || Ref <- Refs],
    ok.

report(Count, SpawnUs, Before, After, PBefore, PAfter) ->
    Total = mem(total, After) - mem(total, Before),
    Procs = mem(processes, After) - mem(processes, Before),
    io:format("~n=== Spawn benchmark ===~n"),
    io:format("Schedulers online:  ~p~n", [erlang:system_info(schedulers_online)]),
    io:format("Processes spawned:  ~p (count ~p -> ~p)~n",
              [Count, PBefore, PAfter]),
    io:format("Spawn time:         ~.3f s (~.3f us/process, ~p procs/s)~n",
              [SpawnUs / 1.0e6, SpawnUs / Count, round(Count / (SpawnUs / 1.0e6))]),
    io:format("Memory (total):     ~s (~.1f bytes/process)~n",
              [fmt(Total), Total / Count]),
    io:format("Memory (processes): ~s (~.1f bytes/process)~n",
              [fmt(Procs), Procs / Count]),
    io:format("Memory (system):    ~s~n",
              [fmt(mem(system, After) - mem(system, Before))]),
    io:format("Total VM memory now:~s~n", [fmt(mem(total, After))]).

mem(Key, List) -> proplists:get_value(Key, List).

fmt(Bytes) when Bytes >= 1024 * 1024 * 1024 ->
    io_lib:format("~.2f GiB", [Bytes / (1024 * 1024 * 1024)]);
fmt(Bytes) when Bytes >= 1024 * 1024 ->
    io_lib:format("~.2f MiB", [Bytes / (1024 * 1024)]);
fmt(Bytes) when Bytes >= 1024 ->
    io_lib:format("~.2f KiB", [Bytes / 1024]);
fmt(Bytes) ->
    io_lib:format("~p B", [Bytes]).
