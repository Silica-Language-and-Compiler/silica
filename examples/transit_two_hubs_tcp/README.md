# transit_two_hubs_tcp: two hub-and-spoke groups joined by one link

Two sub-graphs, A and B, each have one hub and three spokes. The eight processes are separate OS processes on one Mac, over 127.0.0.1 loopback, so no network is needed and the example can be run as a check. Each spoke dials only its own hub. The only connection between the groups is one TCP connection between hub A and hub B. That makes seven connections.

Added 2026-11-20; supervised and nested 2026-11-20 (the `(:accepted, fd, peer)` contract). It is an example, not part of `make integrate`.

## Topology

```
     a1     a2     a3                     b1     b2     b3
      \      |      /                       \      |      /
       \     |     /                         \     |     /
        +----+----+                           +----+----+
             |                                     |
          [hub A] ============================ [hub B]
     listens :4620      one TCP connection     listens :4621
                        (A dials B)
```

Nodes are named by group and number: the spokes are a1, a2, a3, b1, b2, b3 and the hubs are hub A and hub B. In the messages a node is the number `10 * group + k`: 11, 12, 13 for a1 to a3 and 21, 22, 23 for b1 to b3. The hubs are 10 and 20. Hub B's listener on 127.0.0.1:4621 takes b1 to b3 and hub A's link. Hub A's listener on 127.0.0.1:4620 takes a1 to a3.

## Traffic and routes

Every spoke sends one request to each of the other five spokes, so there are 30 requests, and each has a reply matched by id.

- Inside a group the path is spoke, hub, spoke. For example a1 to a3 goes a1, hub A, a3, and the reply goes back the same way.
- Across groups the path is spoke, its own hub, the other hub, spoke. For example a1 to b2 goes a1, hub A, hub B, b2, and the reply returns b2, hub B, hub A, a1.

Each hub knows only its own three spokes. It delivers a frame whose destination is one of them and sends everything else over the link to the other hub. There is no routing table beyond that rule.

## Messages

Messages are ETF terms (`encode((:etf), ...)` and `decode`), each behind a 4-byte length prefix (`wireframe`), which is what Erlang's `gen_tcp` `{packet, 4}` speaks.

```
(:data, Kind, Src, Dest, Id)    Kind 1 = request, 2 = reply; Id = 100 * Src + Dest
(:ctl, Code, Who)               Code 1 = hello, 2 = ready, 3 = go
```

Start. Every connection begins with a hello from both ends, so each hub learns which session is which spoke and which one is the link. A hub that knows its three spokes and the link sends ready over the link. A hub that knows all four and has received the other hub's ready sends go to its spokes. The spokes send their requests only after go, so no frame reaches a hub before the other group is registered.

## Supervision

Every actor and every carrier is a child of a supervisor, and the supervisors are nested. Nothing runs unsupervised except the failure reporter, which the runtime requires to exist before the supervisor starts.

Hub:

```
main
 |- failure reporter
 `- transit_sup               (the root supervisor)
      |- actors_sup           (a :supervisor child; its children are all :temporary)
      |    |- coordinator
      |    |- ses_k           (the session of the k-th accepted connection: three spokes, and for hub B the link)
      |    `- link_ses        (hub A only: the session that dials hub B)
      `- carriers_sup         (a :supervisor child; its children are all :temporary)
           |- listener        (the (:tcp) carrier that listens: 4620 for hub A, 4621 for hub B)
           |- conn_k          (the carrier of the k-th accepted connection)
           `- link_conn       (hub A only: the carrier that dials hub B)
```

Spoke:

```
main
 |- failure reporter
 `- transit_sup
      |- actors_sup           (coordinator, dialer)
      `- carriers_sup         (hub_conn, the carrier that dials its hub)
```

`../transit_common/transit_sup.silica` is the supervisor module. The root supervisor starts `actors_sup` and `carriers_sup` as `:supervisor` children, both with no children of their own. At run time each program adds every actor to `actors_sup` and every carrier to `carriers_sup` as a `:temporary` child with `call_supervisor` (`add_child`), after finding the sub-supervisor with `get_child` on the root. A connection that ends normally is therefore not restarted. Both sub-supervisors share one declared child row type (the carrier's), because they are rows of the same list in the root; the actors added to `actors_sup` have other types, and `add_child` takes them all the same. The failure reporter is registered before anything starts (the compiler requires it). A supervised carrier that ends normally still produces a report with reason `:normal`; the reporter drops those and writes every report with any other reason to standard error, so a real failure is never hidden and `run.sh` compares the full output.

## Output

Each hub prints one line for each frame it relays and says whether the frame stayed local or crossed the link:

```
hub a: relay request id=1123 a1 -> b3 cross
hub b: relay request id=1123 a1 -> b3 cross
hub a: relay request id=1112 a1 -> a2 local
```

A frame between groups is relayed twice, once by each hub, and both lines say cross. Each hub then prints a total line. Each hub relays 12 local frames (6 requests and 6 replies inside its group) and 36 crossing frames (every one of the 18 requests and 18 replies between the groups passes through each hub):

```
hub a: 12 local relays, 36 cross relays
```

Each spoke prints one line for each request it answers and each reply it receives, then its summary:

```
spoke a1: 5 of 5 replies, 5 requests answered
```

Every line is printed by one actor in its process, so lines never mix. The order of the lines inside one process can change from run to run, so `run.sh` compares each process's output sorted with the files in `expected/`. Those files were taken from real output.

## Two programs, copies made by sed

`dangerous_transit_two_hubs_hub.silica` is the hub and `dangerous_transit_two_hubs_spoke.silica` is the spoke. This language has no command line arguments and no environment access, so each program holds its identity in one line (`my_hub` or `my_node`), and `run.sh` makes the eight copies with sed. Each copy is compiled separately.

The carrier is declared with `carried_on wire: (:tcp) (:loopback);`, which supplies the frame size and boundaries (`Carrier@mtu(wire)`, `Carrier@boundaries(wire)`). The carriers themselves are not started with `spawn_dangerous_carrier`: each one is added to `carriers_sup` with `call_supervisor(sup, { op: :add_child, child: { ..., behavior: dangerous_tcp_carrier@carrier, flavor: :dangerous, restart: :temporary, ... } })` from the carrier state record, with link `"loopback"` for a listener or a dialer and `""` for an accepted connection. That bypasses the compile-time link checks of `carried_on`, which Lee accepted. A listener reports an accepted connection as `(:accepted, fd, peer)` and starts no actor, so this program starts the connection carrier and its session itself. A carrier is driven with `(:open, owner, address)`. A listen address is `"listen:4620"` and a dial address is `"127.0.0.1:4620:3000"` (the last part is the connect timeout in milliseconds). A refused dial is not retried here, so `run.sh` starts each process only after the listener it needs is accepting connections.

## Running

```sh
examples/transit_two_hubs_tcp/run.sh
```

The compiler is `binaries/silica-compiler` of this checkout. Set `HOST_SILICA_COMPILER` to use another. The script builds the eight programs under `build/`, starts hub B, hub A and the six spokes, waits at most 60 seconds, kills anything left over, compares the outputs with `expected/` and prints PASS or FAIL. It refuses to start if port 4620 or 4621 is in use. `run.sh --record` rewrites `expected/` from the run.

## Security

The `(:tcp)` carrier is plain TCP. It provides no authentication, no encryption and no peer identity: anyone who can reach a listening port can connect and send frames, and anyone on the path can read and change the bytes. Here every listener is bound to 127.0.0.1 by the declared `(:loopback)` link, so only processes on this Mac can reach it. Secure interchange is being built on top of this carrier in Project BEES (https://github.com/Silica-Language-and-Compiler/project-bees): SEMP/TRUST over mutual TLS 1.3 and an Erlang-compatible BEAM mode with cookie authentication. As of 2026-11-10 BEES's TLS and TRUST code is not built yet.
