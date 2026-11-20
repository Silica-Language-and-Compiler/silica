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

/* The Fifi wrapper of the (:stdin) link of the (:serial) carrier (stdin_carrier_design.md): standard
   input, descriptor 0, read without ever blocking. silica_console_probe says whether it is a terminal;
   silica_console_read checks readiness with select(2) and a zero timeout (not poll(2), which on macOS
   often never reports a terminal readable) and then reads at most max bytes; silica_console_take
   answers those bytes. Descriptor 0 is never closed.

   Result conventions (FFI wrapper specification section 9): a tagged result { tag, value, error_code }
   with tag 0 = ok (probe: value 1 for a terminal, 0 otherwise; read: value the byte count), 1 = error
   (errno in error_code), 2 = nothing ready (also EINTR and EAGAIN), 3 = end of input. The bytes land
   in a buffer private to the calling thread. Every function takes one int64 the carrier does not use
   (the shape silica_sockets_take has), so each binding has a parameter list. */

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <unistd.h>
#include <sys/select.h>
#include <sys/time.h>
#include <sys/types.h>

typedef struct silica_console_tagged {
    int64_t tag;
    int64_t value;
    int64_t error_code;
} silica_console_tagged;

typedef struct silica_console_bytes {
    int64_t tag;
    const uint8_t *text_ptr;
    uint64_t text_len;
    int64_t error_code;
} silica_console_bytes;

#define SILICA_CONSOLE_BUF 65536

static __thread uint8_t silica_console_rx[SILICA_CONSOLE_BUF];
static __thread uint64_t silica_console_rx_len = 0;

static silica_console_tagged console_result(int64_t tag, int64_t value, int64_t error_code) {
    silica_console_tagged r;
    r.tag = tag;
    r.value = value;
    r.error_code = error_code;
    return r;
}

/* Value 1 when descriptor 0 is a terminal, 0 when it is a pipe or a file. */
silica_console_tagged silica_console_probe(int64_t unused) {
    (void)unused;
    return console_result(0, isatty(0) ? 1 : 0, 0);
}

/* Reads up to max bytes (at most 65536) if any are ready now; value is the count. */
silica_console_tagged silica_console_read(int64_t max) {
    fd_set readable;
    struct timeval none;
    int n;
    ssize_t got;
    size_t cap = (max > 0 && max < SILICA_CONSOLE_BUF) ? (size_t)max : SILICA_CONSOLE_BUF;
    silica_console_rx_len = 0;
    FD_ZERO(&readable);
    FD_SET(0, &readable);
    none.tv_sec = 0;
    none.tv_usec = 0;
    n = select(1, &readable, 0, 0, &none);
    if (n < 0) {
        if (errno == EINTR) return console_result(2, 0, 0);
        return console_result(1, 0, errno);
    }
    if (n == 0) return console_result(2, 0, 0);
    got = read(0, silica_console_rx, cap);
    if (got < 0) {
        if (errno == EINTR || errno == EAGAIN) return console_result(2, 0, 0);
        return console_result(1, 0, errno);
    }
    if (got == 0) return console_result(3, 0, 0);
    silica_console_rx_len = (uint64_t)got;
    return console_result(0, (int64_t)got, 0);
}

/* The bytes of the last read on this thread, as the compiler's pointer-plus-length string form: a
   malloc'd span, which the compiler's string-out helper copies into a Silica string and frees. */
silica_console_bytes silica_console_take(int64_t unused) {
    silica_console_bytes r;
    (void)unused;
    r.tag = 0;
    r.text_ptr = 0;
    r.text_len = 0;
    r.error_code = 0;
    if (silica_console_rx_len > 0) {
        uint8_t *span = (uint8_t *)malloc(silica_console_rx_len);
        if (span == 0) { r.tag = 1; r.error_code = ENOMEM; return r; }
        memcpy(span, silica_console_rx, silica_console_rx_len);
        r.text_ptr = span;
        r.text_len = silica_console_rx_len;
        silica_console_rx_len = 0;
    }
    return r;
}
