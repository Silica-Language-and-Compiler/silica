%% actor_msgs: spawn 1000 processes and send each of them 1000 messages.
%%
%% Each message carries the parameters {Id, N, Last} for work/2; the process's behavior calls it,
%% adds the returned value to its running sum, and on the last message sends the sum to the
%% collector (the main process), which prints the grand total.
-module(actor_msgs).
-export([main/0, run/0, work/2]).

-define(ACTORS, 1000).
-define(MSGS, 1000).

%% The function every message asks for: it needs Id and N from the message and returns a value.
work(Id, N) -> Id * N + 1.

main() ->
    {Us, Total} = timer:tc(fun run/0),
    io:format("~p actors x ~p messages, total ~p~n", [?ACTORS, ?MSGS, Total]),
    io:format("elapsed ~.3f s~n", [Us / 1.0e6]).

run() ->
    Collector = self(),
    Pids = [spawn(fun() -> worker(Collector, 0) end) || _ <- lists:seq(1, ?ACTORS)],
    lists:foreach(fun({Id, Pid}) -> send_all(Pid, Id, 1) end,
                  lists:zip(lists:seq(1, ?ACTORS), Pids)),
    collect(?ACTORS, 0).

send_all(_Pid, _Id, N) when N > ?MSGS -> ok;
send_all(Pid, Id, N) ->
    Pid ! {Id, N, N =:= ?MSGS},
    send_all(Pid, Id, N + 1).

worker(Collector, Sum) ->
    receive
        {Id, N, Last} ->
            NewSum = Sum + work(Id, N),
            case Last of
                true -> Collector ! {sum, NewSum};
                false -> worker(Collector, NewSum)
            end
    end.

collect(0, Total) -> Total;
collect(Left, Total) ->
    receive {sum, S} -> collect(Left - 1, Total + S) end.
