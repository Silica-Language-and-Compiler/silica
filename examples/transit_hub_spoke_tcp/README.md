# transit_hub_spoke_tcp: one hub and six spokes over (:tcp)

One hub and six spokes run as seven separate OS processes on one Mac, over 127.0.0.1 loopback, so no network is needed and the example can be run as a check. Each spoke dials only the hub. There are six TCP connections and no connection between two spokes, so a message from one spoke to another must be relayed by the hub.

Added 2026-11-20; supervised and nested 2026-11-20 (the `(:accepted, fd, peer)` contract). It is an example, not part of `make integrate`.

## Topology

```
        spoke 1    spoke 2    spoke 3
            \         |         /
             \        |        /
              +-------+-------+
                      |
                    [hub]   listens on 127.0.0.1:4610
                      |
              +-------+-------+
             /        |        \
            /         |         \
        spoke 4    spoke 5    spoke 6
```

Each line is one TCP connection, dialed by the spoke. The hub is node 0 and the spokes are nodes 1 to 6.

## Traffic

The traffic has two parts.

- Part (a). Each spoke sends one request to the hub, and the hub replies. That is six requests.
- Part (b). Each spoke sends one request to every other spoke, addressed by spoke number. The hub relays each request to its destination spoke. The destination answers, and the reply comes back through the hub and is matched to its request by id. That is 30 requests, and the hub relays 30 requests and 30 replies.

Part (b) starts only when the hub says so. When all six spokes have made their part (a) request, the hub knows which session belongs to which spoke, and it sends every spoke `(:go, 6)`. Without that, a spoke could address a spoke that has not connected yet.

## Messages

Messages are ETF terms (`encode((:etf), ...)` and `decode`), each behind a 4-byte length prefix (`wireframe`), which is what Erlang's `gen_tcp` `{packet, 4}` speaks.

```
(:request, Src, Dest, Id)     Id = 10 * Src + Dest; the hub is 0
(:reply,   Src, Dest, Id)     Src answers, Dest asked, Id is the request's
(:go, N)                      hub to spoke: all N spokes are connected
```

The hub relays a frame whose `Dest` is not 0 without changing it. It does not look at the payload beyond `Dest`.

## Supervision

Every actor and every carrier is a child of a supervisor, and the supervisors are nested. Nothing runs unsupervised except the failure reporter, which the runtime requires to exist before the supervisor starts.

Hub:

```
main
 |- failure reporter
 `- transit_sup               (the root supervisor)
      |- actors_sup           (a :supervisor child; its children are all :temporary)
      |    |- coordinator
      |    `- ses_k           (the session of the k-th accepted spoke, k = 1 to 6)
      `- carriers_sup         (a :supervisor child; its children are all :temporary)
           |- listener        (the (:tcp) carrier that listens on 4610)
           `- conn_k          (the carrier of the k-th accepted spoke)
```

Spoke:

```
main
 |- failure reporter
 `- transit_sup
      |- actors_sup           (coordinator, dialer)
      `- carriers_sup         (hub_conn, the carrier that dials the hub)
```

`../transit_common/transit_sup.silica` is the supervisor module. The root supervisor starts `actors_sup` and `carriers_sup` as `:supervisor` children, both with no children of their own. At run time each program adds every actor to `actors_sup` and every carrier to `carriers_sup` as a `:temporary` child with `call_supervisor` (`add_child`), after finding the sub-supervisor with `get_child` on the root. A connection that ends normally is therefore not restarted. Both sub-supervisors share one declared child row type (the carrier's), because they are rows of the same list in the root; the actors added to `actors_sup` have other types, and `add_child` takes them all the same. The failure reporter is registered before anything starts (the compiler requires it). A supervised carrier that ends normally still produces a report with reason `:normal`; the reporter drops those and writes every report with any other reason to standard error, so a real failure is never hidden and `run.sh` compares the full output.

## Output

The hub prints one line for each part (a) request it answers and one line for each frame it relays, then a total. For example:

```
hub: request id=30 from 3
hub: relay request id=35 3 -> 5
hub: relay reply id=35 5 -> 3
hub: 6 requests answered, 30 requests relayed, 30 replies relayed
```

Each spoke prints one line for each request it answers and each reply it receives, then its summary:

```
spoke 3: 6 of 6 replies, 5 requests answered
```

Every line is printed by one actor in its process, so lines never mix. The order of the lines inside one process can change from run to run, so `run.sh` compares each process's output sorted with `expected/hub.txt` and `expected/spoke1.txt` to `expected/spoke6.txt`. Those files were taken from real output.

## Two programs, six spoke copies

`dangerous_transit_hub.silica` is the hub. `dangerous_transit_spoke.silica` is the spoke. This language has no command line arguments and no environment access, so the spoke number is one line, `fn my_node() -> int64 { 1 }`, and `run.sh` makes the six copies with sed. Each copy is compiled separately.

The carrier is declared with `carried_on wire: (:tcp) (:loopback);`, which supplies the frame size and boundaries (`Carrier@mtu(wire)`, `Carrier@boundaries(wire)`). The carriers themselves are not started with `spawn_dangerous_carrier`: each one is added to `carriers_sup` with `call_supervisor(sup, { op: :add_child, child: { ..., behavior: dangerous_tcp_carrier@carrier, flavor: :dangerous, restart: :temporary, ... } })` from the carrier state record, with link `"loopback"` for a listener or a dialer and `""` for an accepted connection. That bypasses the compile-time link checks of `carried_on`, which Lee accepted. A listener reports an accepted connection as `(:accepted, fd, peer)` and starts no actor, so this program starts the connection carrier and its session itself. A carrier is driven with `(:open, owner, address)`, where the address is `"listen:4610"` for the hub and `"127.0.0.1:4610:3000"` for a spoke (the last part is the connect timeout in milliseconds). A refused dial is not retried here: `run.sh` starts a spoke only after the hub accepts connections.

## Running

```sh
examples/transit_hub_spoke_tcp/run.sh
```

The compiler is `binaries/silica-compiler` of this checkout. Set `HOST_SILICA_COMPILER` to use another. The script builds the seven programs under `build/`, starts the hub and then the spokes, waits at most 60 seconds, kills anything left over, compares the outputs with `expected/` and prints PASS or FAIL. It refuses to start if port 4610 is in use. `run.sh --record` rewrites `expected/` from the run.

## Security

The `(:tcp)` carrier is plain TCP. It provides no authentication, no encryption and no peer identity: anyone who can reach a listening port can connect and send frames, and anyone on the path can read and change the bytes. Here the hub's listener is bound to 127.0.0.1 by the declared `(:loopback)` link, so only processes on this Mac can reach it. Secure interchange is being built on top of this carrier in Project BEES (https://github.com/Silica-Language-and-Compiler/project-bees): SEMP/TRUST over mutual TLS 1.3 and an Erlang-compatible BEAM mode with cookie authentication. As of 2026-11-10 BEES's TLS and TRUST code is not built yet.
