#!/bin/bash
# Makes THIS node's certificate, once: ~/.silica_mtls/own.cert.pem, self-signed over the public half of the
# node's existing ~/.ssh/id_ed25519 (the key is read where it lies; no copy of it is written). Run it on each
# node, by hand, before the first run; it is not part of run_mtls.sh. See README.md.
#
#   ./make_cert.sh NAME            NAME becomes the certificate's CN (the node's name, e.g. mac or aalang-web)
#   ./make_cert.sh NAME --force    replace an existing certificate (every peer then needs the new file)
#
# Needs net/silica_tls.c beside this script, a C compiler and OpenSSL 3 with its headers (macOS: Homebrew's
# openssl@3, or OPENSSL_PREFIX; Linux: libssl-dev). The tool is built under build/ and left there.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
[ $# -ge 1 ] || { sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2; }
mkdir -p "$HERE/build"
if [ "$(uname -s)" = Darwin ]; then
    O="${OPENSSL_PREFIX:-$(brew --prefix openssl@3 2>/dev/null)}"
    [ -f "$O/include/openssl/ssl.h" ] || { echo "make_cert: OpenSSL 3 headers not found (set OPENSSL_PREFIX)"; exit 1; }
    cc -std=c11 -O2 -DSILICA_TLS_MAKE_CERT -I"$O/include" "$HERE/net/silica_tls.c" -L"$O/lib" -lssl -lcrypto -o "$HERE/build/make_cert" || exit 1
else
    cc -std=c11 -D_GNU_SOURCE -O2 -DSILICA_TLS_MAKE_CERT "$HERE/net/silica_tls.c" -lssl -lcrypto -o "$HERE/build/make_cert" || exit 1
fi
exec "$HERE/build/make_cert" "$@"
