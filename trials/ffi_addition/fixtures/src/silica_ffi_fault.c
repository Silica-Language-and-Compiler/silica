#include <fcntl.h>
#include <sys/types.h>
#include <stdint.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

void silica_ffi_null_deref(void) {
    volatile int *p = 0;
    (void)*p;
}

void silica_ffi_past_end_of_ptr(uint8_t *base, int64_t offset) {
    if (base == 0) {
        volatile int *p = 0;
        (void)*p;
        return;
    }
    base[offset] = 1;
}


void silica_ffi_sigill_probe(void) {
#if defined(__aarch64__)
    __asm__ volatile("udf #0" ::: "memory");
#elif defined(__x86_64__)
    __asm__ volatile("ud2" ::: "memory");
#else
    silica_ffi_null_deref();
#endif
}

void silica_ffi_sigfpe_probe(void) {
    raise(SIGFPE);
}

void silica_ffi_sigbus_probe(void) {
    /* The mapping has to be at least one whole page longer than the file, and the access has
       to land in that extra page. A partial final page is zero filled by the kernel, so the
       earlier form here (a one byte file, a 4096 byte mapping, a read at offset 4096) read a
       zero and returned on any machine whose page size is larger than 4096 -- every Apple
       silicon Mac, where the page size is 16384. The trial then reported success for a probe
       that never faulted. */
    long page = sysconf(_SC_PAGESIZE);
    if (page <= 0) {
        return;
    }
    char path[] = "/tmp/silica_sigbus_XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0) {
        return;
    }
    (void)unlink(path);
    if (ftruncate(fd, (off_t)page) != 0) {
        close(fd);
        return;
    }
    void *p = mmap(0, (size_t)page * 2, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (p == MAP_FAILED) {
        return;
    }
    volatile char c = ((char *)p)[page];
    (void)c;
}

int main_unguarded_null_deref_trial(void) {
    silica_ffi_null_deref();
    return 0;
}
