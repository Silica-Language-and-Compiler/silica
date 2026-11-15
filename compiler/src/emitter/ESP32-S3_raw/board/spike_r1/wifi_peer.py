#!/usr/bin/env python3
# Copyright 2026 COPYRIGHT-HOLDER-PLACEHOLDER (to be decided before this is merged)
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""The Mac's end of run_wifi.sh --tcp: listens on a TCP port, and for each of <links> connections reads
one frame behind a 4-byte length (Erlang's {packet, 4}), prints it, sends it back and waits for the
other end to close.

    wifi_peer.py <port> [<links>] [<seconds>]

Exits 0 when every connection gave a whole frame, 1 at the timeout."""
import socket, struct, sys

port = int(sys.argv[1]); links = int(sys.argv[2]) if len(sys.argv) > 2 else 1
seconds = float(sys.argv[3]) if len(sys.argv) > 3 else 90


def read(conn, n):
    data = b''
    while len(data) < n:
        part = conn.recv(n - len(data))
        if not part:
            raise EOFError
        data += part
    return data


server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('0.0.0.0', port))
server.listen(1)
server.settimeout(seconds)
try:
    for link in range(links):
        conn, peer = server.accept()
        conn.settimeout(seconds)
        with conn:
            head = read(conn, 4)
            frame = read(conn, struct.unpack('>I', head)[0])
            conn.sendall(head + frame)
            # the other end closes when it has the frame: a carrier that sees its peer close first ends
            # at once, and its owner may still be answering the frame
            try:
                while conn.recv(4096):
                    pass
            except socket.timeout:
                pass
        print('link %d: frame in %d bytes %s, sent back' % (link, len(frame), frame.hex().upper()), flush=True)
except (socket.timeout, EOFError) as e:
    print('no whole frame: %s' % type(e).__name__, flush=True)
    sys.exit(1)
