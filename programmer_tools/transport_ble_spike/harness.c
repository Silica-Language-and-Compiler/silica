/*
   Copyright 2026 COPYRIGHT-HOLDER-PLACEHOLDER (to be decided before this leaves the spike)

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

/* Stage 1 spike, step A: drives silica_ble.m from plain C with no run loop, the way a dangerous
   actor's thread would. Usage: harness scan | central | peripheral [seconds]
   scan       counts advertisers for 5 s; needs no peer. Proves the callbacks arrive.
   central    connects to a peripheral offering the Nordic UART Service, sends a line, prints what
              comes back.
   peripheral advertises the service as "Silica", waits for a subscriber, sends a line, prints what
              is written to it. */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct { int64_t tag, value, error_code; } tagged;
typedef struct { int64_t tag; const uint8_t *text_ptr; uint64_t text_len; int64_t error_code; } bytes;

tagged silica_ble_set_args(int64_t a, int64_t b);
tagged silica_ble_open(int64_t role, int64_t timeout_ms);
tagged silica_ble_phase(int64_t from, int64_t timeout_ms);
tagged silica_ble_mtu(int64_t handle);
tagged silica_ble_seen(int64_t handle);
tagged silica_ble_send(const uint8_t *data_ptr, uint64_t data_len);
tagged silica_ble_recv(int64_t handle, int64_t max, int64_t timeout_ms);
bytes silica_ble_take(int64_t handle);
tagged silica_ble_close(int64_t handle);

static void show(const char *what, tagged r) {
    printf("%s: tag %lld value %lld error_code %lld\n", what, (long long)r.tag, (long long)r.value, (long long)r.error_code);
    fflush(stdout);
}

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "scan";
    int seconds = argc > 2 ? atoi(argv[2]) : 60;
    int64_t role = strcmp(mode, "central") == 0 ? 0 : strcmp(mode, "peripheral") == 0 ? 1 : 2;

    tagged r = silica_ble_open(role, 10000);
    show("open", r);
    if (r.tag != 0) return 2;

    if (role == 2) {
        for (int i = 0; i < 5; i++) {
            sleep(1);
            show("seen", silica_ble_seen(1));
        }
        show("close", silica_ble_close(1));
        return 0;
    }

    int64_t phase = 1;
    for (int i = 0; i < seconds && phase != 2; i++) {
        r = silica_ble_phase(1, 1000);
        phase = r.value;
        if (phase == 0) phase = 1, silica_ble_phase(0, 1000);
    }
    show("phase", silica_ble_phase(-1, 0));
    if (phase != 2) { printf("no peer within %d s\n", seconds); silica_ble_close(1); return 3; }
    show("mtu", silica_ble_mtu(1));

    const char *hello = role == 0 ? "hello from the silica central" : "hello from the silica peripheral";
    silica_ble_set_args(1, 5000);
    show("send", silica_ble_send((const uint8_t *)hello, strlen(hello)));

    for (int i = 0; i < seconds; i++) {
        r = silica_ble_recv(1, 512, 1000);
        if (r.tag == 2) continue;
        if (r.tag != 0) { show("recv", r); break; }
        bytes b = silica_ble_take(1);
        printf("rx %llu bytes: ", (unsigned long long)b.text_len);
        for (uint64_t k = 0; k < b.text_len; k++) printf("%02x", b.text_ptr[k]);
        printf("  \"%.*s\"\n", (int)b.text_len, (const char *)b.text_ptr);
        fflush(stdout);
        free((void *)b.text_ptr);
    }
    show("close", silica_ble_close(1));
    return 0;
}
