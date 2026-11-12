/*
   Copyright 2026 Lee Scott Barney

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*/

/* The Fifi wrappers of the mutual-TLS example (examples/transport_pairs/ethernet_direct_mtls): the calls
   of compiler/stdlib/net/silica_sockets.c that a TCP carrier uses, with TLS 1.3 between the socket and
   the caller. The engine is the host's OpenSSL 3. An example, not the language's TLS: secure interchange
   for Silica is Project BEES's TRUST.

   Identity and trust (README.md has the whole procedure). Nothing here is created at run time and
   nothing is fetched from anywhere:

     own key          ~/.ssh/id_ed25519, the host's existing OpenSSH ed25519 key, read where it lies.
                      OpenSSL cannot read the OpenSSH container, so the 32-byte seed is taken out of it
                      in memory (read_ssh_ed25519 below); no copy of the key is ever written.
     own certificate  ~/.silica_mtls/own.cert.pem, a self-signed X.509 certificate over that key, made
                      ONCE by the make_cert tool (this file built with -DSILICA_TLS_MAKE_CERT) and kept:
                      a restart presents the same certificate.
     accepted peers   ~/.silica_mtls/peers/<name>.pem, the certificates of the nodes this node accepts, each
                      put there by the node's operator. There is no certificate authority: a peer is
                      accepted when the SHA-512 of the certificate it presents is the SHA-512 of one of
                      these files (the rule of TRUST's certificate whitelist) and the certificate is
                      within its dates.

   SILICA_MTLS_KEY and SILICA_MTLS_DIR override the key path and the ~/.silica_mtls directory.

   Both ends present a certificate and both ends check the peer's: the server asks for the client's
   certificate and fails the handshake without one. A peer that is not accepted never reaches Silica:
   connect answers an error, accept answers "no peer this time" (a timeout) and says why on stderr.

   Result conventions: those of silica_sockets.c. A tagged result { tag, value, error_code } with tag 0 =
   ok, 1 = error, 2 = timeout, 3 = closed by the peer; received bytes land in a buffer private to the
   calling thread and silica_tls_take answers them as a pointer plus length. A connection is named by its
   socket descriptor, as in silica_sockets.c; the table below maps it to its TLS state. */

#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <dirent.h>
#include <pthread.h>
#include <time.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/x509.h>
#include <openssl/x509_vfy.h>
#include <openssl/crypto.h>
#include <openssl/rand.h>

/* ---- identity: the OpenSSH ed25519 key, read in memory ---------------------------------------- */

static uint32_t be32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }

/* One length-prefixed field of the OpenSSH container: answers its bytes and moves *at past it. */
static int ssh_field(const uint8_t *buf, size_t len, size_t *at, const uint8_t **out, uint32_t *out_len) {
    if (*at + 4 > len) return 0;
    uint32_t n = be32(buf + *at);
    if (n > len - *at - 4) return 0;
    *out = buf + *at + 4;
    *out_len = n;
    *at += 4 + (size_t)n;
    return 1;
}

/* The ed25519 private key of an unencrypted OpenSSH key file ("openssh-key-v1"), as an EVP_PKEY.
   Every buffer that held key bytes is wiped before this returns. why names the reason for a 0. */
static EVP_PKEY *read_ssh_ed25519(const char *path, const char **why) {
    static const char begin[] = "-----BEGIN OPENSSH PRIVATE KEY-----";
    static const char end[] = "-----END OPENSSH PRIVATE KEY-----";
    static const char magic[] = "openssh-key-v1";
    char text[8192];
    uint8_t b64[8192], raw[8192];
    EVP_PKEY *key = 0;
    *why = "cannot read the key file";
    FILE *f = fopen(path, "r");
    if (f == 0) return 0;
    size_t got = fread(text, 1, sizeof text - 1, f);
    fclose(f);
    text[got] = 0;
    const char *p = strstr(text, begin);
    const char *q = strstr(text, end);
    *why = "not an OpenSSH private key file";
    if (p != 0 && q != 0 && q > p) {
        size_t n = 0;
        for (p += sizeof begin - 1; p < q; p++) if (*p != '\n' && *p != '\r' && *p != ' ') b64[n++] = (uint8_t)*p;
        int dec = (n > 0 && n % 4 == 0) ? EVP_DecodeBlock(raw, b64, (int)n) : -1;
        if (dec > 0) {
            size_t len = (size_t)dec, at = sizeof magic;   /* the magic and its NUL */
            const uint8_t *cipher, *kdf, *kdfopt, *pub, *priv, *type, *pk, *sk;
            uint32_t cipher_n, kdf_n, kdfopt_n, pub_n, priv_n, type_n, pk_n, sk_n;
            if (len > sizeof magic && memcmp(raw, magic, sizeof magic) == 0
                && ssh_field(raw, len, &at, &cipher, &cipher_n) && ssh_field(raw, len, &at, &kdf, &kdf_n)
                && ssh_field(raw, len, &at, &kdfopt, &kdfopt_n) && at + 4 <= len) {
                uint32_t nkeys = be32(raw + at);
                at += 4;
                if (cipher_n != 4 || memcmp(cipher, "none", 4) != 0) *why = "the key has a passphrase; this example reads unencrypted keys only";
                else if (nkeys == 1 && ssh_field(raw, len, &at, &pub, &pub_n) && ssh_field(raw, len, &at, &priv, &priv_n) && priv_n >= 8) {
                    size_t pat = 8;   /* the two check words */
                    if (ssh_field(priv, priv_n, &pat, &type, &type_n) && ssh_field(priv, priv_n, &pat, &pk, &pk_n)
                        && ssh_field(priv, priv_n, &pat, &sk, &sk_n)) {
                        if (type_n != 11 || memcmp(type, "ssh-ed25519", 11) != 0) *why = "the key is not ed25519";
                        else if (pk_n == 32 && sk_n == 64) {
                            /* sk is the 32-byte seed followed by the public key */
                            key = EVP_PKEY_new_raw_private_key(EVP_PKEY_ED25519, 0, sk, 32);
                            if (key == 0) *why = "OpenSSL refused the key";
                        }
                    }
                }
            }
        }
    }
    OPENSSL_cleanse(text, sizeof text);
    OPENSSL_cleanse(b64, sizeof b64);
    OPENSSL_cleanse(raw, sizeof raw);
    return key;
}

static void identity_paths(char *key, char *dir, size_t cap) {
    const char *home = getenv("HOME");
    const char *k = getenv("SILICA_MTLS_KEY");
    const char *d = getenv("SILICA_MTLS_DIR");
    if (home == 0) home = ".";
    if (k != 0 && k[0] != 0) snprintf(key, cap, "%s", k); else snprintf(key, cap, "%s/.ssh/id_ed25519", home);
    if (d != 0 && d[0] != 0) snprintf(dir, cap, "%s", d); else snprintf(dir, cap, "%s/.silica_mtls", home);
}

/* The SHA-512 of a certificate's DER encoding: what a peer is recognised by. */
static int cert_sha512(X509 *x, uint8_t out[64]) {
    unsigned int n = 0;
    return X509_digest(x, EVP_sha512(), out, &n) == 1 && n == 64;
}

#ifdef SILICA_TLS_MAKE_CERT
/* ---- make_cert: the node's certificate, made once ---------------------------------------------- */

/* make_cert NAME [--force]
   Writes ~/.silica_mtls/own.cert.pem: a self-signed certificate, subject and issuer CN=NAME, over the
   public half of ~/.ssh/id_ed25519, valid for ten years from now. It refuses to replace an existing
   certificate without --force, because every peer that accepts this node holds a copy of the file and
   would have to be given the new one. Prints the SHA-512 fingerprint, the value to compare by eye or
   by voice when the file is carried to a peer. */
int main(int argc, char **argv) {
    char key_path[1024], dir[1024], out[1100];
    const char *why = "";
    if (argc < 2 || argv[1][0] == '-') { fprintf(stderr, "usage: make_cert NAME [--force]\n"); return 2; }
    int force = argc > 2 && strcmp(argv[2], "--force") == 0;
    identity_paths(key_path, dir, sizeof key_path);
    snprintf(out, sizeof out, "%s/own.cert.pem", dir);
    if (!force && access(out, F_OK) == 0) { fprintf(stderr, "make_cert: %s exists; it is kept (--force replaces it, and then every peer needs the new file)\n", out); return 1; }
    EVP_PKEY *key = read_ssh_ed25519(key_path, &why);
    if (key == 0) { fprintf(stderr, "make_cert: %s: %s\n", key_path, why); return 1; }
    X509 *x = X509_new();
    X509_NAME *name = X509_NAME_new();
    uint8_t serial[16], fp[64];
    BIGNUM *bn = 0;
    int good = x != 0 && name != 0 && RAND_bytes(serial, sizeof serial) == 1;
    if (good) {
        serial[0] &= 0x7f;
        bn = BN_bin2bn(serial, sizeof serial, 0);
        good = bn != 0 && X509_set_version(x, 2) == 1 && BN_to_ASN1_INTEGER(bn, X509_get_serialNumber(x)) != 0
            && X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, (const unsigned char *)argv[1], -1, -1, 0) == 1
            && X509_set_subject_name(x, name) == 1 && X509_set_issuer_name(x, name) == 1
            && X509_gmtime_adj(X509_getm_notBefore(x), 0) != 0
            && X509_gmtime_adj(X509_getm_notAfter(x), 60L * 60 * 24 * 3652) != 0
            && X509_set_pubkey(x, key) == 1
            && X509_sign(x, key, 0) > 0;   /* ed25519 signs without a separate digest */
    }
    if (!good) { fprintf(stderr, "make_cert: could not build the certificate\n"); ERR_print_errors_fp(stderr); return 1; }
    mkdir(dir, 0700);
    FILE *f = fopen(out, "w");
    if (f == 0 || PEM_write_X509(f, x) != 1) { fprintf(stderr, "make_cert: cannot write %s\n", out); return 1; }
    fclose(f);
    chmod(out, 0644);
    cert_sha512(x, fp);
    printf("wrote %s (CN=%s)\nsha512 ", out, argv[1]);
    for (int i = 0; i < 64; i++) printf("%02x", fp[i]);
    printf("\n");
    BN_free(bn); X509_NAME_free(name); X509_free(x); EVP_PKEY_free(key);
    return 0;
}

#else
/* ---- the wrappers ------------------------------------------------------------------------------ */

typedef struct silica_tls_tagged {
    int64_t tag;
    int64_t value;
    int64_t error_code;
} silica_tls_tagged;

typedef struct silica_tls_bytes {
    int64_t tag;
    const uint8_t *text_ptr;
    uint64_t text_len;
    int64_t error_code;
} silica_tls_bytes;

#define SILICA_TLS_BUF 65536
#define SILICA_TLS_MAX_CONN 256
#define SILICA_TLS_MAX_PEERS 64
#define SILICA_TLS_HANDSHAKE_SECONDS 5

static __thread uint8_t silica_tls_rx[SILICA_TLS_BUF];
static __thread uint64_t silica_tls_rx_len = 0;
static __thread int64_t silica_tls_arg_a = 0;
static __thread int64_t silica_tls_arg_b = 0;

static silica_tls_tagged ok(int64_t v) { silica_tls_tagged r = {0, v, 0}; return r; }
static silica_tls_tagged err(void) { silica_tls_tagged r = {1, 0, (int64_t)errno}; return r; }
static silica_tls_tagged err_code(int e) { silica_tls_tagged r = {1, 0, (int64_t)e}; return r; }
static silica_tls_tagged timeout(void) { silica_tls_tagged r = {2, 0, 0}; return r; }
static silica_tls_tagged closed(void) { silica_tls_tagged r = {3, 0, 0}; return r; }

/* The context both roles share, built once from the node's key, its certificate and its accepted
   peers. ctx stays 0 when the identity is incomplete, and every connect and accept then fails. */
static pthread_once_t identity_once = PTHREAD_ONCE_INIT;
static SSL_CTX *ctx = 0;
static uint8_t peers[SILICA_TLS_MAX_PEERS][64];
static int peer_count = 0;

/* Replaces OpenSSL's chain building: there is no authority to chain to. The peer is accepted when the
   certificate it presented is, byte for byte, one of the accepted peers' and is within its dates. */
static int verify_peer(X509_STORE_CTX *store, void *arg) {
    (void)arg;
    uint8_t fp[64];
    X509 *x = X509_STORE_CTX_get0_cert(store);
    int reason = X509_V_ERR_CERT_UNTRUSTED;
    if (x != 0 && cert_sha512(x, fp)) {
        for (int i = 0; i < peer_count; i++) {
            if (CRYPTO_memcmp(fp, peers[i], 64) == 0) {
                if (X509_cmp_current_time(X509_get0_notBefore(x)) > 0) reason = X509_V_ERR_CERT_NOT_YET_VALID;
                else if (X509_cmp_current_time(X509_get0_notAfter(x)) < 0) reason = X509_V_ERR_CERT_HAS_EXPIRED;
                else { X509_STORE_CTX_set_error(store, X509_V_OK); return 1; }
            }
        }
    }
    X509_STORE_CTX_set_error(store, reason);
    return 0;
}

static X509 *read_cert(const char *path) {
    FILE *f = fopen(path, "r");
    if (f == 0) return 0;
    X509 *x = PEM_read_X509(f, 0, 0, 0);
    fclose(f);
    return x;
}

static void load_identity(void) {
    char key_path[1024], dir[1024], path[2200];
    const char *why = "";
    identity_paths(key_path, dir, sizeof key_path);
    EVP_PKEY *key = read_ssh_ed25519(key_path, &why);
    if (key == 0) { fprintf(stderr, "tls: %s: %s\n", key_path, why); return; }
    snprintf(path, sizeof path, "%s/own.cert.pem", dir);
    X509 *own = read_cert(path);
    if (own == 0) { fprintf(stderr, "tls: no certificate at %s (make it once with make_cert; README.md)\n", path); EVP_PKEY_free(key); return; }
    snprintf(path, sizeof path, "%s/peers", dir);
    DIR *d = opendir(path);
    if (d != 0) {
        struct dirent *e;
        while ((e = readdir(d)) != 0 && peer_count < SILICA_TLS_MAX_PEERS) {
            size_t n = strlen(e->d_name);
            if (n < 5 || strcmp(e->d_name + n - 4, ".pem") != 0) continue;
            char one[2600];
            snprintf(one, sizeof one, "%s/%s", path, e->d_name);
            X509 *x = read_cert(one);
            if (x != 0 && cert_sha512(x, peers[peer_count])) peer_count++;
            else fprintf(stderr, "tls: %s is not a certificate; skipped\n", one);
            X509_free(x);
        }
        closedir(d);
    }
    if (peer_count == 0) fprintf(stderr, "tls: no accepted peer certificate in %s; every handshake will be refused\n", path);
    SSL_CTX *c = SSL_CTX_new(TLS_method());
    if (c != 0 && SSL_CTX_set_min_proto_version(c, TLS1_3_VERSION) == 1
        && SSL_CTX_use_certificate(c, own) == 1 && SSL_CTX_use_PrivateKey(c, key) == 1
        && SSL_CTX_check_private_key(c) == 1) {
        /* both roles demand the peer's certificate; verify_peer decides */
        SSL_CTX_set_verify(c, SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT, 0);
        SSL_CTX_set_cert_verify_callback(c, verify_peer, 0);
        /* no session tickets and no silent retry: a readable socket with no application bytes must
           answer "nothing yet", not block the carrier's poll */
        SSL_CTX_set_num_tickets(c, 0);
        SSL_CTX_clear_mode(c, SSL_MODE_AUTO_RETRY);
        ctx = c;
    } else {
        fprintf(stderr, "tls: the certificate in %s does not belong to the key %s\n", dir, key_path);
        SSL_CTX_free(c);
    }
    X509_free(own);
    EVP_PKEY_free(key);
}

/* descriptor -> TLS state. One actor (one thread) uses a connection; the table itself is shared. */
static pthread_mutex_t conn_lock = PTHREAD_MUTEX_INITIALIZER;
static struct { int fd; SSL *ssl; } conns[SILICA_TLS_MAX_CONN];
static int conn_used = 0;

static int conn_put(int fd, SSL *ssl) {
    int placed = 0;
    pthread_mutex_lock(&conn_lock);
    for (int i = 0; i < conn_used && !placed; i++) if (conns[i].ssl == 0) { conns[i].fd = fd; conns[i].ssl = ssl; placed = 1; }
    if (!placed && conn_used < SILICA_TLS_MAX_CONN) { conns[conn_used].fd = fd; conns[conn_used].ssl = ssl; conn_used++; placed = 1; }
    pthread_mutex_unlock(&conn_lock);
    return placed;
}

static SSL *conn_get(int fd, int take) {
    SSL *ssl = 0;
    pthread_mutex_lock(&conn_lock);
    for (int i = 0; i < conn_used; i++) if (conns[i].ssl != 0 && conns[i].fd == fd) { ssl = conns[i].ssl; if (take) conns[i].ssl = 0; break; }
    pthread_mutex_unlock(&conn_lock);
    return ssl;
}

static int wait_fd(int fd, short events, int64_t timeout_ms) {
    struct pollfd p;
    p.fd = fd;
    p.events = events;
    p.revents = 0;
    for (;;) {
        int n = poll(&p, 1, timeout_ms < 0 ? -1 : (int)timeout_ms);
        if (n < 0 && errno == EINTR) continue;
        return n;
    }
}

/* A write to a peer that has gone must fail with EPIPE and must not raise SIGPIPE, which would end the
   program. OpenSSL writes the socket itself, so each platform's own mechanism is used around it: macOS
   marks the socket (SO_NOSIGPIPE); Linux has no such option, so the calling thread holds SIGPIPE
   blocked for the write and takes back one that became pending. The program's dispositions are left
   alone on both. */
static void socket_options(int fd, int handshake) {
    int one = 1;
    struct timeval tv;
    tv.tv_sec = handshake ? SILICA_TLS_HANDSHAKE_SECONDS : 0;
    tv.tv_usec = 0;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
#ifdef SO_NOSIGPIPE
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
    /* the handshake is bounded: a peer that connects and says nothing is dropped */
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
}

#ifndef SO_NOSIGPIPE
static void sigpipe_hold(sigset_t *saved, int *was_pending) {
    sigset_t pipe_set, pending;
    sigemptyset(&pipe_set);
    sigaddset(&pipe_set, SIGPIPE);
    sigpending(&pending);
    *was_pending = sigismember(&pending, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &pipe_set, saved);
}
static void sigpipe_release(const sigset_t *saved, int was_pending) {
    sigset_t pipe_set;
    struct timespec zero = {0, 0};
    sigemptyset(&pipe_set);
    sigaddset(&pipe_set, SIGPIPE);
    if (!was_pending) while (sigtimedwait(&pipe_set, 0, &zero) == -1 && errno == EINTR) { }
    pthread_sigmask(SIG_SETMASK, saved, 0);
}
#define SIGPIPE_HOLD sigset_t sp_saved; int sp_pending; sigpipe_hold(&sp_saved, &sp_pending)
#define SIGPIPE_RELEASE sigpipe_release(&sp_saved, sp_pending)
#else
#define SIGPIPE_HOLD (void)0
#define SIGPIPE_RELEASE (void)0
#endif

/* The handshake on a connected socket, in the given role. Answers the TLS state, or 0 after saying on
   stderr why the peer was not accepted (the socket is then closed). */
static SSL *handshake(int fd, int server) {
    pthread_once(&identity_once, load_identity);
    if (ctx == 0) { fprintf(stderr, "tls: no usable identity; connection refused\n"); close(fd); return 0; }
    socket_options(fd, 1);
    SSL *ssl = SSL_new(ctx);
    if (ssl == 0 || SSL_set_fd(ssl, fd) != 1) { SSL_free(ssl); close(fd); return 0; }
    SIGPIPE_HOLD;
    int r = server ? SSL_accept(ssl) : SSL_connect(ssl);
    SIGPIPE_RELEASE;
    if (r != 1) {
        long v = SSL_get_verify_result(ssl);
        unsigned long e = ERR_peek_last_error();
        fprintf(stderr, "tls: %s handshake failed: %s\n", server ? "server" : "client",
                v != X509_V_OK ? X509_verify_cert_error_string(v) : (e != 0 ? ERR_reason_error_string(e) : "the peer went away or sent nothing"));
        ERR_clear_error();
        SSL_free(ssl);
        close(fd);
        return 0;
    }
    socket_options(fd, 0);
    if (!conn_put(fd, ssl)) { fprintf(stderr, "tls: connection table full\n"); SSL_free(ssl); close(fd); return 0; }
    return ssl;
}

silica_tls_tagged silica_tls_set_args(int64_t a, int64_t b) {
    silica_tls_arg_a = a;
    silica_tls_arg_b = b;
    return ok(0);
}

/* Dials host:port (port: set_args a), then the TLS handshake as the client. An error when the host
   does not answer, and EACCES when the handshake fails: this node or the peer was not accepted. */
silica_tls_tagged silica_tls_connect(const uint8_t *host_ptr, uint64_t host_len) {
    char host[256];
    struct sockaddr_in addr;
    int64_t port = silica_tls_arg_a;
    if (host_ptr == 0 || host_len == 0 || host_len >= sizeof host) return err_code(EINVAL);
    memcpy(host, host_ptr, (size_t)host_len);
    host[host_len] = 0;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) return err_code(EINVAL);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return err();
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) < 0) { int e = errno; close(fd); return err_code(e); }
    if (handshake(fd, 0) == 0) return err_code(EACCES);
    return ok(fd);
}

static silica_tls_tagged listen_on(int64_t port, uint32_t host_order_addr) {
    struct sockaddr_in addr;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return err();
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(host_order_addr);
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0) { int e = errno; close(fd); return err_code(e); }
    if (listen(fd, 16) < 0) { int e = errno; close(fd); return err_code(e); }
    return ok(fd);
}

/* A listening socket is plain: TLS begins on each accepted connection. */
silica_tls_tagged silica_tls_listen(int64_t port) { return listen_on(port, INADDR_LOOPBACK); }
silica_tls_tagged silica_tls_listen_any(int64_t port) { return listen_on(port, INADDR_ANY); }

silica_tls_tagged silica_tls_local_port(int64_t fd) {
    struct sockaddr_in addr;
    socklen_t n = sizeof addr;
    if (getsockname((int)fd, (struct sockaddr *)&addr, &n) < 0) return err();
    return ok((int64_t)ntohs(addr.sin_port));
}

/* Accepts one peer and runs the handshake as the server, which demands the peer's certificate. A peer
   that fails it is dropped here and the answer is "no peer this time" (a timeout), so the listener goes
   on listening and Silica never sees an unauthenticated connection. */
silica_tls_tagged silica_tls_accept(int64_t fd, int64_t timeout_ms) {
    int n = wait_fd((int)fd, POLLIN, timeout_ms);
    if (n < 0) return err();
    if (n == 0) return timeout();
    int c = accept((int)fd, 0, 0);
    if (c < 0) return err();
    if (handshake(c, 1) == 0) return timeout();
    return ok(c);
}

/* Writes the whole buffer as TLS records. fd: set_args a, timeout_ms: set_args b */
silica_tls_tagged silica_tls_send(const uint8_t *data_ptr, uint64_t data_len) {
    int64_t fd = silica_tls_arg_a;
    int64_t timeout_ms = silica_tls_arg_b;
    SSL *ssl = conn_get((int)fd, 0);
    if (ssl == 0) return err_code(EBADF);
    uint64_t done = 0;
    while (done < data_len) {
        int n = wait_fd((int)fd, POLLOUT, timeout_ms);
        if (n < 0) return err();
        if (n == 0) return timeout();
        size_t piece = (size_t)(data_len - done);
        if (piece > 16384) piece = 16384;
        SIGPIPE_HOLD;
        int w = SSL_write(ssl, data_ptr + done, (int)piece);
        int e = w > 0 ? SSL_ERROR_NONE : SSL_get_error(ssl, w);
        SIGPIPE_RELEASE;
        if (w > 0) { done += (uint64_t)w; continue; }
        if (e == SSL_ERROR_WANT_WRITE || e == SSL_ERROR_WANT_READ) continue;
        ERR_clear_error();
        return err_code(EPIPE);
    }
    return ok((int64_t)done);
}

/* Reads up to max decrypted bytes into the thread's buffer; value is the count. Tag 3 when the peer
   closed, with a TLS close or without one. */
silica_tls_tagged silica_tls_recv(int64_t fd, int64_t max, int64_t timeout_ms) {
    SSL *ssl = conn_get((int)fd, 0);
    if (ssl == 0) return err_code(EBADF);
    if (SSL_pending(ssl) == 0) {
        int n = wait_fd((int)fd, POLLIN, timeout_ms);
        if (n < 0) return err();
        if (n == 0) return timeout();
    }
    size_t cap = (max > 0 && max < SILICA_TLS_BUF) ? (size_t)max : SILICA_TLS_BUF;
    int got = SSL_read(ssl, silica_tls_rx, (int)cap);
    if (got > 0) { silica_tls_rx_len = (uint64_t)got; return ok((int64_t)got); }
    silica_tls_rx_len = 0;
    int e = SSL_get_error(ssl, got);
    unsigned long reason = ERR_peek_last_error();
    ERR_clear_error();
    if (e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE) return timeout();
    if (e == SSL_ERROR_ZERO_RETURN) return closed();
    if (e == SSL_ERROR_SYSCALL && (errno == EAGAIN || errno == EWOULDBLOCK)) return timeout();
    if (e == SSL_ERROR_SYSCALL && (errno == 0 || errno == ECONNRESET || errno == EPIPE)) return closed();
    if (e == SSL_ERROR_SSL && ERR_GET_REASON(reason) == SSL_R_UNEXPECTED_EOF_WHILE_READING) return closed();
    /* a fatal alert lands here: in TLS 1.3 a server that refuses the client's certificate says so
       only after the client's handshake has finished, so the refusal arrives on the first read */
    if (e == SSL_ERROR_SSL) fprintf(stderr, "tls: %s\n", reason != 0 ? ERR_reason_error_string(reason) : "protocol error");
    return err_code(EACCES);
}

/* The bytes of the last receive on this thread, as the compiler's pointer-plus-length string form:
   a malloc'd span, which the compiler's string-out helper copies into a Silica string and frees. */
silica_tls_bytes silica_tls_take(int64_t fd) {
    silica_tls_bytes r;
    (void)fd;
    r.tag = 0;
    r.text_ptr = 0;
    r.text_len = 0;
    r.error_code = 0;
    if (silica_tls_rx_len > 0) {
        uint8_t *span = (uint8_t *)malloc(silica_tls_rx_len);
        if (span == 0) { r.tag = 1; r.error_code = ENOMEM; return r; }
        memcpy(span, silica_tls_rx, silica_tls_rx_len);
        r.text_ptr = span;
        r.text_len = silica_tls_rx_len;
    }
    return r;
}

/* Closes a connection (with a TLS close to the peer) or a listening socket. */
silica_tls_tagged silica_tls_close(int64_t fd) {
    SSL *ssl = conn_get((int)fd, 1);
    if (ssl != 0) {
        SIGPIPE_HOLD;
        SSL_shutdown(ssl);
        SIGPIPE_RELEASE;
        ERR_clear_error();
        SSL_free(ssl);
    }
    if (close((int)fd) < 0) return err();
    return ok(0);
}

#endif
