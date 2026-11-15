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

    wifi_peer.py <port> [<links>] [<seconds>] [<this Mac's IPv4 address>]

With the fourth argument the board is the listener: the peer finds it on this Mac's /24 network and
connects to it for each exchange.

Exits 0 when every connection gave a whole frame, 1 at the timeout."""
import socket, struct, sys, time
from concurrent.futures import ThreadPoolExecutor

port = int(sys.argv[1]); links = int(sys.argv[2]) if len(sys.argv) > 2 else 1
seconds = float(sys.argv[3]) if len(sys.argv) > 3 else 90
connect_to = sys.argv[4] if len(sys.argv) > 4 else None     # this Mac's address: connect to the board instead


def read(conn, n):
    data = b''
    while len(data) < n:
        part = conn.recv(n - len(data))
        if not part:
            raise EOFError
        data += part
    return data


def exchange(conn, link):
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


def find(prefix):
    """The address under <prefix> (a.b.c.) that accepts a connection on the port, None when none does."""
    def one(n):
        try:
            with socket.create_connection((prefix + str(n), port), 0.7):
                return prefix + str(n)
        except OSError:
            return None
    with ThreadPoolExecutor(64) as pool:
        for found in pool.map(one, range(1, 255)):
            if found:
                return found
    return None


try:
    if connect_to:
        # the board listens: its address is found by trying every address of this Mac's /24 network
        prefix = connect_to.rsplit('.', 1)[0] + '.'
        end = time.time() + seconds
        board = None
        while board is None and time.time() < end:
            board = find(prefix)
        if board is None:
            raise socket.timeout
        time.sleep(1)       # the connection that found it is accepted and ended by the board first
        for link in range(links):
            exchange(socket.create_connection((board, port), seconds), link)
    else:
        server = socket.socket()
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(('0.0.0.0', port))
        server.listen(1)
        server.settimeout(seconds)
        for link in range(links):
            conn, peer = server.accept()
            exchange(conn, link)
except (OSError, EOFError) as e:
    print('no whole frame: %s' % type(e).__name__, flush=True)
    sys.exit(1)
