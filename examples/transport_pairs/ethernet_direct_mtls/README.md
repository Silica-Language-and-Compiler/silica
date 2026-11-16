# ethernet_direct_mtls

Silica runs on both ends of **one direct connection under mutual TLS 1.3** across the Internet: this Apple Silicon
Mac and a Linux x86-64 host (`manager@aalang.org`, 138.197.209.113 by default). It is
[`../ethernet_direct`](../ethernet_direct/) with one change, the carrier. Both ends present a certificate, each end
accepts only a peer whose certificate it has been given, and the bytes on the wire are encrypted
(`TLS_AES_256_GCM_SHA384`, ed25519 signatures).

This is an example, not the language's TLS. Silica's secure interchange is being built in
[Project BEES](https://github.com/Silica-Language-and-Compiler/project-bees) (TRUST over mutual TLS 1.3 with a
certificate whitelist). The trust rule here is that whitelist's rule.

## What is in the directory

| File | What it is |
|---|---|
| `dangerous_ethernet_mtls_pair.silica` | The program, both ends. It is `ethernet_direct`'s program; only the carrier it starts differs. |
| `dangerous_tls_carrier.silica` | The carrier. The standard `(:tcp)` carrier's text with the socket wrappers replaced by the TLS wrappers; the carrier contract (transport design §6.2) is unchanged. |
| `dangerous_tls.silica` | The Fifi bindings of the wrappers, with the names and answers of the standard `dangerous_sockets`. |
| `net/silica_tls.c`, `net/silica_tls_wrapper.meta` | The wrappers over the host's OpenSSL 3, and the certificate tool (the same file built with `-DSILICA_TLS_MAKE_CERT`). |
| `make_cert.sh` | Makes a node's certificate, once. Run by hand. |
| `run_mtls.sh`, `build_linux.sh` | Build both ends, run, compare with `expected/`. They touch no key and no certificate. |

Mutual TLS sits **below** the carrier contract, in the wrapper. The program sends and receives the same messages
as over plain TCP, so `expected/` is `ethernet_direct`'s expected output.

## Identity and trust

There is no certificate authority and no shared certificate store. Each node is given the certificate of each
node it talks to, and nothing else.

| What | Where, on each node | Notes |
|---|---|---|
| The node's key | `~/.ssh/id_ed25519` | The node's existing OpenSSH ed25519 key, read where it lies. OpenSSL cannot read the OpenSSH container, so the wrapper takes the key out of it in memory. No copy of the key is written anywhere. The key must have no passphrase. |
| The node's certificate | `~/.silica_mtls/own.cert.pem` | Self-signed over that key, valid ten years. Made **once** and kept: a restart presents the same certificate. |
| The peers it accepts | `~/.silica_mtls/peers/<name>.pem` | One file per accepted peer, any name. A peer is accepted when the SHA-512 of the certificate it presents equals the SHA-512 of one of these files and the certificate is within its dates. |

`SILICA_MTLS_KEY` and `SILICA_MTLS_DIR` override the key path and the `~/.silica_mtls` directory.

**Nothing under `~/.ssh` or `~/.silica_mtls` belongs in the repository.** The files live outside the checkout, and
`build/` is ignored. Do not copy a key or a certificate into this directory.

## Certificates: the one-time step, by hand

`run_mtls.sh` does none of this. It only checks that the files are in place and lists what is missing.

1. **On each node, make its certificate.** The node needs `make_cert.sh` and `net/silica_tls.c` (on the remote, copy
   those two files anywhere, keeping `net/` beside the script), a C compiler and OpenSSL 3 with headers
   (Homebrew `openssl@3` on the Mac, `libssl-dev` on Linux).

   ```
   ./make_cert.sh mac            # on the Mac
   ./make_cert.sh aalang-web     # on the remote
   ```

   Each prints the certificate's SHA-512 fingerprint. The tool refuses to replace an existing certificate
   without `--force`, because every peer holds a copy of it.

2. **Give each node the other's certificate.** A certificate is public; what matters is that the right one
   arrives. Copy each node's `~/.silica_mtls/own.cert.pem` into the other node's `~/.silica_mtls/peers/`, for
   example over the ssh access the two hosts already have:

   ```
   scp manager@aalang.org:.silica_mtls/own.cert.pem ~/.silica_mtls/peers/aalang-web.pem
   scp ~/.silica_mtls/own.cert.pem manager@aalang.org:.silica_mtls/peers/mac.pem
   ```

   Compare the fingerprints with the ones step 1 printed
   (`openssl x509 -in <file> -noout -fingerprint -sha512`).

To stop accepting a peer, delete its file from `peers/`. To replace a node's certificate, run
`make_cert.sh <name> --force` there and give the new file to every node that accepts it.

A system with more nodes works the same way: a node holds the certificates of the nodes it talks to, not of
every node.

## The dial address and its timeout

A dial address is `"<ipv4>:<port>:<timeout_ms>"`, for example `138.197.209.113:4550:5000`. The third part is the
connect timeout in whole milliseconds (1 to 9 decimal digits, greater than 0). The program must state it: there
is no default, as for the standard `(:tcp)` carrier since stage E8 of the hosted Ethernet plan.

- The timeout bounds the TCP connect **and** the client's TLS handshake together, against one deadline. Neither
  blocks: the socket is non-blocking for both and the carrier's worker waits in polls that end at the deadline.
- A peer that does not answer the connect, or does not finish the handshake, in that time gives the owner
  `(:link_down, :timeout)` and the carrier ends with `(:explicit, :link_timeout)`.
- An address without the timeout, or with a malformed or zero one, dials nothing: `(:link_down, :fault)`, and the
  carrier ends with `(:explicit, :bad_address)`.
- A refused connection and a failed handshake (a certificate not accepted) are `(:link_down, :fault)`, and the
  carrier ends with `(:explicit, :link_unavailable)`.
- `(:link_up, "<ipv4>:<port>")` carries the peer without the timeout.

## How the carrier ends

The carrier ends with its link, exactly as the standard `(:tcp)` carrier does: `:link_down` is the last message
the owner receives, the descriptor and its TLS state are released (a TLS `close_notify` goes to the peer on
`:close` and on a failed write), and a supervisor restarts a faulted link and leaves a closed one alone.

| Event | Owner receives | Carrier exit reason |
|---|---|---|
| `:close` from the owner | `(:link_down, :closed)` | `:normal` |
| The peer closed (`close_notify`, or the connection dropped) | `(:link_down, :closed)` | `:normal` |
| A read failed (fatal TLS alert, reset) | `(:link_down, :fault)` | `(:explicit, :link_lost)` |
| A write failed or timed out | `(:tx_failed, :link_down)`, then `(:link_down, :fault)` | `(:explicit, :link_lost)` |
| Dial refused (nothing listens) | `(:link_down, :fault)` | `(:explicit, :link_unavailable)` |
| Dial handshake failed (certificate not accepted) | `(:link_down, :fault)` | `(:explicit, :link_unavailable)` |
| Dial connect or handshake timed out | `(:link_down, :timeout)` | `(:explicit, :link_timeout)` |
| Dial address malformed (no stated timeout) | `(:link_down, :fault)` | `(:explicit, :bad_address)` |
| Listener cannot bind | `(:link_down, :fault)` | `(:explicit, :link_unavailable)` |

In TLS 1.3 a server that refuses the client's certificate says so only after the client's handshake has finished,
so that client sees `(:link_up, ...)` and then the read-failed row, not the failed-handshake row. A `:tx` on a
carrier that is not up answers `(:tx_failed, :link_down)` and the carrier goes on.

The source and `run_mtls.sh` state 5000 ms.

## Running

```
REMOTE=manager@aalang.org ./run_mtls.sh                  # build both ends, run once, compare
REMOTE=manager@aalang.org ./run_mtls.sh --runs 2         # the run twice in a row
REMOTE=manager@aalang.org ./run_mtls.sh --timeout-check  # no Linux end: the Mac end must time out (exit 5)
./run_mtls.sh --local                                    # both ends on this Mac
```

`--local` runs both ends as the Mac's one identity, so the Mac's own certificate must be among its accepted
peers. Use a separate trust directory for that rather than adding it to the real one:

```
mkdir -p /tmp/mtls_local/peers
cp ~/.silica_mtls/own.cert.pem /tmp/mtls_local/own.cert.pem
cp ~/.silica_mtls/own.cert.pem /tmp/mtls_local/peers/self.pem
SILICA_MTLS_DIR=/tmp/mtls_local ./run_mtls.sh --local
```

The remote firewall must admit TCP 4550 from the Mac's public address, as for `ethernet_direct`. The listener
exists only during a run.

## What a refused peer looks like

A peer that is not accepted never reaches the Silica program. The wrapper says why on standard error.

| Case | Listening end | Dialing end |
|---|---|---|
| The dialer presents a certificate the listener does not hold | `tls: server handshake failed: certificate not trusted`; no `accepted` line | `connected`, then `tls: ssl/tls alert bad certificate` and a link down; it dials again |
| The dialer presents no certificate | `tls: server handshake failed: peer did not return a certificate` | the handshake fails |
| The listener presents a certificate the dialer does not hold | the handshake fails | `tls: client handshake failed: certificate not trusted`; a link down |

In TLS 1.3 a server refuses a client's certificate after the client's own handshake has finished, so a refused
dialer prints `connected` before it learns of the refusal on its first read.

## Checked

2026-11-12, `binaries/silica-compiler` (silica-999925) on the Mac with OpenSSL 3.6.2 and the staged Linux compiler
on `aalang-web` with OpenSSL 3.5.3:

- Mac to `aalang.org:4550`: both ends exit 0 and match `expected/`.
- `--local`: both ends exit 0 and match.
- Refusals, both ends on the Mac: a listener that holds only a stranger's certificate refused the dialer twelve
  times in six seconds; `openssl s_client` with no certificate was refused, and reported TLSv1.3.

## Limits

- No revocation other than deleting a peer's file, and the accepted peers are read once, at the first handshake
  of a run.
- A certificate is not bound to an address or a name: an accepted peer may connect from anywhere the firewall
  admits.
- The frames carry no authorization of their own; an accepted peer may send any request.
- A listener's handshake with an accepted peer runs on the listener's thread and is bounded at five seconds for
  each read and write, so a silent peer delays the next accept by at least that long. Only the dialing side's
  handshake is under the stated connect timeout.
- The key is the node's ssh identity. A real deployment would give TLS a key of its own.
- The carrier is a copy of the standard `(:tcp)` carrier as of 2026-11-12 and does not follow later changes to it,
  except the required connect timeout and the carrier teardown (both 2026-11-16): it ends as the standard carrier
  does (see "How the carrier ends").
- The connect timeout and teardown changes of 2026-11-16 were checked with `run_timeout_checks.sh` (11 checks pass
  on the Mac, pix and nix; `happy_path` runs on the Mac only) and `run_mtls.sh` on the Mac. `run_mtls.sh` has no
  Linux mode. The older "Checked" runs above predate the change and dialled `<ip>:4550`.
