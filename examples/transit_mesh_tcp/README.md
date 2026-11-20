# transit_mesh_tcp: five nodes in a full mesh over (:tcp)

Five copies of one Silica program run as five separate OS processes on one Mac. They talk over 127.0.0.1 loopback, so no network is needed and the example can be run as a check. Every pair of nodes shares one direct TCP connection, which makes ten connections. Every node sends one request to each of the other four nodes (20 requests in all). Each reply comes back over the same connection and is matched to its request by id.

Added 2026-11-20; supervised and nested 2026-11-20 (the `(:accepted, fd, peer)` contract). It is an example, not part of `make integrate`.

## Topology

Every node has a direct connection to every other node. An arrow points from the node that dials to the node that listens.

```
        listens on 4600  4601  4602  4603  4604
                    node1 node2 node3 node4 node5
dials   node 1        .    -->   -->   -->   -->
        node 2        .     .    -->   -->   -->
        node 3        .     .     .    -->   -->
        node 4        .     .     .     .    -->
        node 5        .     .     .     .     .
```

Each arrow is one TCP connection, so the ten pairs are 1-2, 1-3, 1-4, 1-5, 2-3, 2-4, 2-5, 3-4, 3-5 and 4-5. The lower-numbered node of a pair dials and the higher-numbered node listens.

Node n listens on 127.0.0.1 port 4599 + n (4600 to 4604) and dials every node above it. Node 1 dials four nodes and listens for none. Node 5 listens for four nodes and dials none.

## Messages

Messages are ETF terms (`encode((:etf), ...)` and `decode`), each behind a 4-byte length prefix (`wireframe`), which is what Erlang's `gen_tcp` `{packet, 4}` speaks.

```
(:request, Src, Id)     Id = 10 * Src + Dest
(:reply,   Src, Id)     the same Id, sent back over the same connection
```

The dialer sends its request as soon as the connection is up. The listener does not know who dialed until a request arrives, so it answers that request and then sends its own request to the sender. A node matches each reply to its request by id. A node is finished when all four of its connections are finished. It then prints `node N: 4 of 4 replies`, waits 1.5 seconds so its peers can read the last frames and exits 0.

## Supervision

Every actor and every carrier is a child of a supervisor, and the supervisors are nested. Nothing runs unsupervised except the failure reporter, which the runtime requires to exist before the supervisor starts.

```
main
 |- failure reporter          (a plain actor, registered before anything starts)
 `- transit_sup               (the root supervisor, started with spawn_registered_supervisor)
      |- actors_sup           (a :supervisor child; its children are all :temporary)
      |    |- coordinator
      |    `- dial_p, ses_k   (the link actor for each node p this node dials, and the session of the k-th accepted connection)
      `- carriers_sup         (a :supervisor child; its children are all :temporary)
           |- listener        (the (:tcp) carrier that listens; nodes 2 to 5)
           |- dcar_p          (the carrier that dials node p)
           `- conn_k          (the carrier of the k-th accepted connection)
```

`../transit_common/transit_sup.silica` is the supervisor module. The root supervisor starts `actors_sup` and `carriers_sup` as `:supervisor` children, both with no children of their own. At run time each program adds every actor to `actors_sup` and every carrier to `carriers_sup` as a `:temporary` child with `call_supervisor` (`add_child`), after finding the sub-supervisor with `get_child` on the root. A connection that ends normally is therefore not restarted. Both sub-supervisors share one declared child row type (the carrier's), because they are rows of the same list in the root; the actors added to `actors_sup` have other types, and `add_child` takes them all the same. The failure reporter is registered before anything starts (the compiler requires it). A supervised carrier that ends normally still produces a report with reason `:normal`; the reporter drops those and writes every report with any other reason to standard error, so a real failure is never hidden and `run.sh` compares the full output.

## Output

Each node prints one line for each request it answers and one line for each reply it receives, then its summary. For example, node 3 prints these lines in some order:

```
node 3: reply id=34 peer=4
node 3: request id=13 peer=1
node 3: 4 of 4 replies
```

Every line is printed by one actor in the node (the coordinator), so lines never mix, but the order of the lines inside one node can change from run to run. So `run.sh` compares each node's output sorted with `expected/node1.txt` to `expected/node5.txt`. Those files were taken from real output.

## One source, five copies

This language has no command line arguments and no environment access. `dangerous_transit_mesh_node.silica` holds the node number in one line, `fn my_node() -> int64 { 1 }`, and `run.sh` makes the five copies with sed. Each copy is compiled separately, the way `../transport_pairs/ethernet_direct/run_direct.sh` builds its two ends.

The carrier is declared with `carried_on wire: (:tcp) (:loopback);`, which supplies the frame size and boundaries (`Carrier@mtu(wire)`, `Carrier@boundaries(wire)`). The carriers themselves are not started with `spawn_dangerous_carrier`: each one is added to `carriers_sup` with `call_supervisor(sup, { op: :add_child, child: { ..., behavior: dangerous_tcp_carrier@carrier, flavor: :dangerous, restart: :temporary, ... } })` from the carrier state record, with link `"loopback"` for a listener or a dialer and `""` for an accepted connection. That bypasses the compile-time link checks of `carried_on`, which Lee accepted. A listener reports an accepted connection as `(:accepted, fd, peer)` and starts no actor, so this program starts the connection carrier and its session itself. A carrier is driven with `(:open, owner, address)`, where the address is `"listen:4601"` or `"127.0.0.1:4601:3000"` (the last part is the connect timeout in milliseconds).

## Running

```sh
examples/transit_mesh_tcp/run.sh
```

The compiler is `binaries/silica-compiler` of this checkout. Set `HOST_SILICA_COMPILER` to use another. The script builds the five copies under `build/`, starts the nodes in the order 5, 4, 3, 2, 1, each of nodes 5 to 2 only after its listener accepts connections, waits at most 60 seconds, kills anything left over, compares the outputs with `expected/` and prints PASS or FAIL. It refuses to start if one of the ports 4600 to 4604 is in use. `run.sh --record` rewrites `expected/` from the run.

## Security

The `(:tcp)` carrier is plain TCP. It provides no authentication, no encryption and no peer identity: anyone who can reach a listening port can connect and send frames, and anyone on the path can read and change the bytes. Here every listener is bound to 127.0.0.1 by the declared `(:loopback)` link, so only processes on this Mac can reach it. Secure interchange is being built on top of this carrier in Project BEES (https://github.com/Silica-Language-and-Compiler/project-bees): SEMP/TRUST over mutual TLS 1.3 and an Erlang-compatible BEAM mode with cookie authentication. As of 2026-11-10 BEES's TLS and TRUST code is not built yet.
