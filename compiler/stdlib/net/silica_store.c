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

/* The Fifi wrappers of the hosted (:backing) storage medium (transport_serialization_design.md §6.8.6):
   the one place a host file exists for a storage carrier. They open and lock the backing, read and
   write byte spans of it, and make them durable; what the bytes mean (blocks, records, checks) is the
   language's, in compiler/stdlib/storelog.silica and the carrier
   compiler/stdlib/dangerous_store_backing_carrier.silica.

   A backing is one region of a fixed size. The first open creates it at the declared capacity; a
   backing that already exists at another size is refused, never resized. It is held under an exclusive
   lock while open, so a second carrier, in this process or another, is refused. Durability is each
   platform's own full flush: F_FULLFSYNC on macOS (fsync alone leaves the bytes in the drive's cache
   there), fdatasync on Linux.

   Result conventions (FFI wrapper specification §9): a tagged result { tag, value, error_code } with
   tag 0 = ok, 1 = error (errno in error_code), 4 = the backing is already open (locked), 5 = the
   backing exists at another size. Bytes read land in a buffer private to the calling thread;
   silica_store_take answers them as a pointer plus length that the compiler copies into a Silica
   string before the next call. */

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/file.h>

typedef struct silica_store_tagged {
    int64_t tag;
    int64_t value;
    int64_t error_code;
} silica_store_tagged;

typedef struct silica_store_bytes {
    int64_t tag;
    const uint8_t *text_ptr;
    uint64_t text_len;
    int64_t error_code;
} silica_store_bytes;

/* The bytes of the last read on this thread; grown as needed and kept. */
static __thread uint8_t *silica_store_rx = 0;
static __thread uint64_t silica_store_rx_cap = 0;
static __thread uint64_t silica_store_rx_len = 0;

/* The FFI carries a pointer-plus-length pair only as a wrapper's sole parameters, so a wrapper that
   needs a string and scalars takes the scalars first through silica_store_set_args, kept per thread:
   a dangerous actor is its own thread. */
static __thread int64_t silica_store_arg_a = 0;
static __thread int64_t silica_store_arg_b = 0;

static silica_store_tagged ok(int64_t v) { silica_store_tagged r = {0, v, 0}; return r; }
static silica_store_tagged err(void) { silica_store_tagged r = {1, 0, (int64_t)errno}; return r; }
static silica_store_tagged err_code(int e) { silica_store_tagged r = {1, 0, (int64_t)e}; return r; }
static silica_store_tagged in_use(void) { silica_store_tagged r = {4, 0, 0}; return r; }
static silica_store_tagged mismatch(int64_t size) { silica_store_tagged r = {5, size, 0}; return r; }

static int room(uint64_t n) {
    if (n <= silica_store_rx_cap) return 1;
    uint8_t *p = (uint8_t *)realloc(silica_store_rx, (size_t)n);
    if (p == 0) return 0;
    silica_store_rx = p;
    silica_store_rx_cap = n;
    return 1;
}

/* Reads exactly n bytes at offset; what lies past the end of the backing reads as zeros. */
static int read_full(int fd, uint8_t *to, uint64_t n, int64_t offset) {
    uint64_t done = 0;
    while (done < n) {
        ssize_t got = pread(fd, to + done, (size_t)(n - done), (off_t)(offset + (int64_t)done));
        if (got < 0) { if (errno == EINTR) continue; return 0; }
        if (got == 0) { memset(to + done, 0, (size_t)(n - done)); return 1; }
        done += (uint64_t)got;
    }
    return 1;
}

static int write_full(int fd, const uint8_t *from, uint64_t n, int64_t offset) {
    uint64_t done = 0;
    while (done < n) {
        ssize_t w = pwrite(fd, from + done, (size_t)(n - done), (off_t)(offset + (int64_t)done));
        if (w < 0) { if (errno == EINTR) continue; return 0; }
        done += (uint64_t)w;
    }
    return 1;
}

static uint64_t be(const uint8_t *p, int n) {
    uint64_t v = 0;
    for (int i = 0; i < n; i++) v = (v << 8) | p[i];
    return v;
}

silica_store_tagged silica_store_set_args(int64_t a, int64_t b) {
    silica_store_arg_a = a;
    silica_store_arg_b = b;
    return ok(0);
}

/* Opens the backing at path and takes its exclusive lock. capacity: set_args a. A backing that does
   not exist, or exists empty, is made capacity bytes long (all zeros); one that exists at another
   size is refused with tag 5 and its size in value. value is the descriptor. */
silica_store_tagged silica_store_open(const uint8_t *path_ptr, uint64_t path_len) {
    char path[1024];
    struct stat st;
    int64_t capacity = silica_store_arg_a;
    if (path_ptr == 0 || path_len == 0 || path_len >= sizeof path || capacity <= 0) return err_code(EINVAL);
    memcpy(path, path_ptr, (size_t)path_len);
    path[path_len] = 0;
    int fd = open(path, O_RDWR | O_CREAT, 0600);
    if (fd < 0) return err();
    if (flock(fd, LOCK_EX | LOCK_NB) < 0) {
        int e = errno;
        close(fd);
        if (e == EWOULDBLOCK) return in_use();
        return err_code(e);
    }
    if (fstat(fd, &st) < 0) { int e = errno; close(fd); return err_code(e); }
    if (st.st_size == 0) {
        if (ftruncate(fd, (off_t)capacity) < 0) { int e = errno; close(fd); return err_code(e); }
    } else if ((int64_t)st.st_size != capacity) {
        close(fd);
        return mismatch((int64_t)st.st_size);
    }
    return ok(fd);
}

/* Reads the first 16 bytes of each of count blocks of block_size bytes, from block `first` on, one
   after another, into the thread's buffer: block headers, several in one call (block_size: set_args a,
   first: set_args b). value is the byte count. */
silica_store_tagged silica_store_headers(int64_t fd, int64_t count) {
    int64_t block_size = silica_store_arg_a;
    int64_t first = silica_store_arg_b;
    if (block_size < 16 || first < 0 || count < 0) return err_code(EINVAL);
    if (!room((uint64_t)count * 16 + 1)) return err_code(ENOMEM);
    for (int64_t b = 0; b < count; b++) {
        if (!read_full((int)fd, silica_store_rx + b * 16, 16, (first + b) * block_size)) return err();
    }
    silica_store_rx_len = (uint64_t)count * 16;
    return ok(count * 16);
}

/* Reads length bytes at offset into the thread's buffer. value is the byte count. */
silica_store_tagged silica_store_read(int64_t fd, int64_t offset, int64_t length) {
    if (offset < 0 || length < 0) return err_code(EINVAL);
    if (!room((uint64_t)length + 1)) return err_code(ENOMEM);
    if (!read_full((int)fd, silica_store_rx, (uint64_t)length, offset)) return err();
    silica_store_rx_len = (uint64_t)length;
    return ok(length);
}

/* The bytes of the last read on this thread, as the compiler's pointer-plus-length string form: a
   malloc'd span, which the compiler's string-out helper copies into a Silica string and frees. */
silica_store_bytes silica_store_take(int64_t fd) {
    silica_store_bytes r;
    (void)fd;
    r.tag = 0;
    r.text_ptr = 0;
    r.text_len = 0;
    r.error_code = 0;
    if (silica_store_rx_len > 0) {
        uint8_t *span = (uint8_t *)malloc(silica_store_rx_len);
        if (span == 0) { r.tag = 1; r.error_code = ENOMEM; return r; }
        memcpy(span, silica_store_rx, silica_store_rx_len);
        r.text_ptr = span;
        r.text_len = silica_store_rx_len;
    }
    return r;
}

/* Writes a list of pending writes, in order (fd: set_args a). The list is storelog's write-behind
   form: for each write, the offset (8 bytes, big-endian), the length (4 bytes) and the bytes. The
   first write that fails ends the call with an error; the writes before it have been made. value is
   the number of writes made. */
silica_store_tagged silica_store_write(const uint8_t *data_ptr, uint64_t data_len) {
    int64_t fd = silica_store_arg_a;
    uint64_t at = 0;
    int64_t made = 0;
    while (at + 12 <= data_len) {
        int64_t offset = (int64_t)be(data_ptr + at, 8);
        uint64_t n = be(data_ptr + at + 8, 4);
        if (at + 12 + n > data_len) return err_code(EINVAL);
        if (!write_full((int)fd, data_ptr + at + 12, n, offset)) return err();
        at += 12 + n;
        made++;
    }
    return ok(made);
}

/* Makes everything written so far durable: the platform's full flush. */
silica_store_tagged silica_store_flush(int64_t fd) {
#ifdef F_FULLFSYNC
    if (fcntl((int)fd, F_FULLFSYNC) < 0) return err();
#else
    if (fdatasync((int)fd) < 0) return err();
#endif
    return ok(0);
}

/* Closes the backing; its lock goes with the descriptor. */
silica_store_tagged silica_store_close(int64_t fd) {
    if (close((int)fd) < 0) return err();
    return ok(0);
}
