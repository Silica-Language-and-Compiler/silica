# ethernet_remote

Silica runs on both ends of a TCP link across the Internet: this Apple Silicon Mac and a Linux x86-64 host
(`manager@aalang.org` by default). **Both ends dial, and both ends are asked**: two connections, requests from both
sides interleaved, every reply matched to its request by id.

- One source, `dangerous_ethernet_silica_pair.silica`, holds both ends. `run_mac_linux.sh` makes the per-host copy
  with sed at compile time. It sets the ports and the host name, and it picks the side (see below).
- The Mac end is built with `binaries/silica-compiler`.
- The Linux end is built **on the remote** with `binaries/silica-compiler-linux_x86_64`, the hosted Linux compiler.
  - **Which build.** It was silica-999959 for the results below. Since late 2026-11-10 it is silica-999958, which has
    `carried_on`.
  - **Staging.** The script copies the compiler into `~/silica_demo/toolchain` when its checksum differs.
- Both ends use the hosted `(:tcp)` carrier (`dangerous_tcp_carrier`): one listener and one connecting carrier per
  end.

```
            Mac (accel side)                                        Linux x86-64 (status side)
  listener 127.0.0.1:4551  <---- ssh -R remote 127.0.0.1:4561 ----  dialer -> 127.0.0.1:4561
  dialer -> 127.0.0.1:4560 ----  ssh -L 127.0.0.1:4560        ---->  listener 127.0.0.1:4550

  Mac -> Linux   (:request, 1 | 3 | 5, (:accel, { x, y, z, at_ms }))   Linux -> Mac  (:reply, id, (:led, { which: :red, on: z > 256 }))
  Linux -> Mac   (:request, 2 | 4 | 6, :status)                          Mac -> Linux  (:reply, id, (:status, { host, uptime_ms, requests_seen }))
```

The terms are ETF, and each frame has a 4-byte length prefix (`wireframe`, the same as Erlang's `gen_tcp`
`{packet, 4}`).

## The network

- **No public port.** Each listener binds 127.0.0.1 only.
- **One ssh connection carries both directions.** The Mac reaches the remote listener through `ssh -L`. The remote
  reaches the Mac listener through `ssh -R`, which the remote's sshd binds on its loopback.
- **Nothing changes on the remote's system.** There is no firewall change and nothing runs as root.
- **ssh access.** ssh runs with `BatchMode=yes` and key authentication. No key is printed or copied.
- **The bytes are encrypted only by the tunnel.** The TCP carrier itself is plain.

## How each end works

- **The coordinator.** It owns the listener. Once the listener is bound, the coordinator starts the dialer. Every
  accepted connection gets a session. The dialer and the sessions are actors with the same behaviour
  (`connection`) and the same state record, which has a `dials` flag.
- **Requests.** The dialer sends its three requests 250 ms apart, so several are in flight at once. It records the
  outstanding ids in a bit mask and matches each reply by id. A session answers each request as soon as it arrives.
- **Flow control and framing.** These work as in `../usb_silica_pair`:
  - a frame goes out only while the end holds a transmit credit; otherwise it waits in an outbox string;
  - every `:rx` is reassembled with `wireframe@unframe` and drained.
- **Redialing.** The dialer may start before the other listener exists. On the remote this happens every run: the
  Linux end starts first. A refused connection is retried. So is a connection that ssh accepts and then closes
  (`connect_to 127.0.0.1 port 4551: failed` in `build/ssh.log`). Each retry closes that carrier and dials again
  500 ms later with a fresh state, at most 80 times. Retries print nothing, so the output does not depend on the
  start order.
- **Completion.** An end is done when its dialer has matched 3 replies and a session has answered 3 requests, with
  every `:tx` confirmed. It then prints `pair complete`, waits 1.5 s, closes the listener and exits 0.
- **Failure paths.** With no completion 45 s after start, the end prints
  `timeout: dialer done <yes|no> listener done <yes|no>` and exits 5. A listener that cannot bind prints
  `listen failed <why>` and exits 1.

### The side blocks

The source ends with two blocks:

- **The accel side** (the Mac). It sends accel requests and decodes LED replies. It decodes status requests and
  answers them.
- **The status side** (the Linux end). It sends status requests and decodes status replies. It decodes accel
  requests and answers them by the rule.

As written, the accel block is code and the status block is a `{- -}` comment, so the file compiles as the Mac end.
For the Linux copy, `run_mac_linux.sh` swaps the two with sed.

Each end compiles only its own block because of a compiler limit. The first version decided the side with a run-time
flag, so both sides' decoders were in one unit. The Linux compiler could not compile that unit on the remote: see
"Compiler problems" below.

## Running it

```sh
REMOTE=manager@aalang.org examples/transport_pairs/ethernet_remote/run_mac_linux.sh                  # the pair
REMOTE=manager@aalang.org examples/transport_pairs/ethernet_remote/run_mac_linux.sh --timeout-check  # no Linux end: exit 5
```

Options and overrides:

- **Ports.** `--remote-listen 4550 --remote-dial 4561 --mac-listen 4551 --mac-dial 4560`.
- **Compilers.** `SILICA_COMPILER` for the Mac end, `LINUX_SILICA_COMPILER` for the Linux end.

What the script does:

1. **Builds the Mac end.**
2. **Stages the remote toolchain.** It copies the Linux compiler only when its checksum differs. It also copies the
   six stdlib modules, `trial_wait_int64`, `silica_sockets.c` and `build_linux.sh`.
3. **Builds the Linux end on the remote.** This takes about 15 s.
4. **Starts the Linux end** under `timeout 90`.
5. **Opens the forwards.** One `ssh -N -L ... -R ...` connection carries both, with `ExitOnForwardFailure`.
6. **Runs the Mac end** and fetches the remote's output.
7. **Compares both outputs** with `expected/mac_peer.txt` and `expected/linux_peer.txt`. Both sides are sorted before
   the comparison, because the two connections' lines interleave differently from run to run. `uptime_ms` values
   become `<n>`.
8. **Tears down.** A trap closes the ssh connection and kills the remote program. The script then checks that
   neither host has a listener, forward or program left.

### What is left on the remote

Only `~/silica_demo/`:

- `toolchain/`: the compiler (23 MB), the stdlib sources and `build_linux.sh`;
- `ethernet_pair/`: the build and `peer.out`;
- the E0 files `silica_peer.erl`, `silica_peer.beam` and `peer.out`.

The old checkout `~/silica` on the remote is not used.

## Results (2026-11-10)

The pair ran five times, all PASS: three runs in a row, then two more in a row after the last change to the
script. Each run took about 37 s including both builds. The timeout check also
passed: `timeout: dialer done no listener done no`, exit 5. After every run the teardown check reported
`remote: no program, no listener on 4550 or 4561` and `mac: no program, no listener on 4551 or 4560`.

One run, as the ends printed it (the order of the lines varies from run to run):

```
--- Mac end (accel side):
listening
request 1 accel x=1 y=-2 z=512 at_ms=250 -> reply led red on
request 3 accel x=3 y=1 z=100 at_ms=500 -> reply led red off
peer request 2 status -> reply status requests_seen=1
request 5 accel x=-4 y=0 z=300 at_ms=750 -> reply led red on
dialer done: 3 replies matched
peer request 4 status -> reply status requests_seen=2
peer request 6 status -> reply status requests_seen=3
listener done: 3 requests answered
pair complete: 3 replies matched, 3 peer requests answered
exit 0
--- Linux end (status side):
listening
peer request 1 accel x=1 y=-2 z=512 at_ms=250 -> reply led red on
peer request 3 accel x=3 y=1 z=100 at_ms=500 -> reply led red off
request 2 status -> reply status host=mac-arm64 uptime_ms=339989029 requests_seen=1
peer request 5 accel x=-4 y=0 z=300 at_ms=750 -> reply led red on
listener done: 3 requests answered
request 4 status -> reply status host=mac-arm64 uptime_ms=339989244 requests_seen=2
request 6 status -> reply status host=mac-arm64 uptime_ms=339989501 requests_seen=3
dialer done: 3 replies matched
pair complete: 3 replies matched, 3 peer requests answered
exit 0
MATCH: mac end
MATCH: linux end
=== PASS
```

## Compiler problems found, and the workarounds

1. **The Linux compiler runs out of memory in its type-surface cache on the remote.** The remote has 3.9 GB of RAM
   and no swap. Compiling the first version of this program (both sides' decoders in one unit) failed there with:

   ```
   reason: (:explicit, :out_of_memory)
     #0  type_surface_cache_cache_beh
   ```

   The driver reported that "the compiler crashed while compiling" the unit.

   - **Not a system limit.** The whole process stayed under 530 MB RSS. strace showed no failed `mmap` or
     `mprotect`, and the run hit no `ulimit`.
   - **Where the limit comes from.** The Linux runtime gives each actor a reservation the size of physical memory
     plus swap (`prims_actors_stack_asm`). The cache actor appears to outgrow that reservation in address space
     while touching little memory. This is an inference, not confirmed.
   - **The same unit compiles on the Mac.** The Mac has 32 GB, so the reservation is 32 GB. Peak memory there is
     about 750 MB, with both the Nov 8 Mac compiler (999926) and the current one (999925).
   - **The trigger.** Bisecting showed that no single construct causes it. It depends on how much is in the unit: a
     prefix of the functions compiled, and one more decoder function crashed it. Each piece also compiled alone.
   - **Workaround.** Each end compiles only its own side block.
   - **To fix it.** Make the cache actor's state area stop growing in address space (or give it its own
     reservation), or rebuild the Linux compiler with a fix. Then a host with less memory can compile larger units.
   - **2026-11-10, with the remote temporarily at 16 GB RAM.** The both-sides unit compiled at about 640 MB peak RSS,
     with no crash: the module-named version with both 999959 and 999958, and the `carried_on` version with 999958.
     So the limit grows with physical memory, as inferred. It is presumably still there on a 4 GB host.

2. **The Linux compiler predates `carried_on`.** silica-999959 does not expand `carried_on` declarations. The
   `usb_silica_pair` Mac peer fails there with E2005 at the first use of its declared name (`Carrier@mtu(board)`).
   This program names its carrier by module instead: `spawn_dangerous` of `dangerous_tcp_carrier@carrier`, with the
   address string. Installing a Linux x86-64 compiler built from the current tree would allow `carried_on` here.
   - **Done 2026-11-10.** silica-999958-linux-x86_64 was built on the remote from the current tree, with the Linux
     x86-64 transport pack given the Mac's link rows. It compiles `carried_on wire: (:tcp) (:loopback);`. The program
     here has not been switched to that form yet.

3. **The compiler defects found by `../usb_silica_pair`.**
   - A nested tagged tuple written inline in `encode` is encoded flattened, so each term is bound to an annotated
     name before `encode`.
   - A `to_int64(...)` written as an argument can clobber an earlier argument, so its result is bound to a name
     first.

   Neither defect is fixed, so both workarounds are kept on both ends.

4. **`silica_sockets.c` and strict C11 on glibc.** Under `-std=c11` alone, glibc hides `cfmakeraw`. Like the trials
   (`trials/ffi_addition/fixtures.mk`), `build_linux.sh` compiles the file with `-D_GNU_SOURCE`.

**Security.** The `(:tcp)` carrier is plain TCP. It provides no authentication, no encryption and no peer identity: anyone who can reach a listening port can connect and send frames, and anyone on the path can read and change the bytes. Secure interchange is being built on top of this carrier in Project BEES (https://github.com/Silica-Language-and-Compiler/project-bees): SEMP/TRUST over mutual TLS 1.3 (ALPN `trust/1`, a certificate whitelist; the TLS engine is selected: OpenSSL on macOS and Linux, Mbed TLS on the NUCLEO-L476RG and the ESP32-S3) and an Erlang-compatible BEAM mode with cookie authentication. As of 2026-11-10 BEES's TLS and TRUST code is not built yet and its cookie handshake is in progress; both build on this carrier's non-loopback support. Today BEES's BEAM-mode wire runs between BEES nodes on loopback only, without the cookie digest (test-only, unauthenticated).
