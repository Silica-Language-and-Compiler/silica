# transport_interface_link

Trial `app_transport_tcp_interface_link` of hosted Ethernet plan stage E2 (`compiler/design_documents/transport_hosted_ethernet_plan.md`,
item 6): a listener and a dialer in one program, both declared `carried_on lan: (:tcp) (:interface, "<loopback>")`,
so the interface binding (`getifaddrs`, then `bind` of the interface's first IPv4 address) is exercised end to end:
the listener's `"listen:0"` listens on 127.0.0.1 and the client's dial leaves from it. Request `ping`, reply `pong`.

The loopback interface is `lo0` on macOS and `lo` on Linux, and a `carried_on` link is a literal, so there is no
portable form: the source carries the placeholder `IFNAME` and `run.sh` fills it in. That is why this trial is a
script and not part of `make integrate`. Run `SILICA_COMPILER=<path> ./run.sh`; it prints PASS when the output
equals `expected.txt`. Verified: not yet run (written while the hosted compilers were being rebuilt).
