/* Board version of fixtures/src/silica_text.c for ESP32-S3_raw: no malloc, so the echo is built in a
 * static buffer (a foreign call owns no heap; the Silica side copies the bytes out). One result at a
 * time: each call overwrites the buffer, as the trials call it once per dispatch.
 * Result codes: tag 0 ok; tag 1 with error_code 1 for a NULL pointer, 3 when the echo does not fit. */
#include <stddef.h>
#include <stdint.h>

#define ECHO_PREFIX "Echo: "
#define ECHO_PREFIX_LEN 6
#define ECHO_CAPACITY 256

typedef struct silica_text_echo_result {
    int64_t tag;
    const uint8_t *text_ptr;
    uint64_t text_len;
    int64_t error_code;
} silica_text_echo_result;

/* The layout the Silica "struct" result reads (see fixtures/dangerous_exposure_source/text/
 * silica_text_wrapper.h): four 8-byte words. */
_Static_assert(offsetof(silica_text_echo_result, tag) == 0, "tag at 0");
_Static_assert(offsetof(silica_text_echo_result, text_ptr) == 8, "text_ptr at 8");
_Static_assert(offsetof(silica_text_echo_result, text_len) == 16, "text_len at 16");
_Static_assert(offsetof(silica_text_echo_result, error_code) == 24, "error_code at 24");
_Static_assert(sizeof(silica_text_echo_result) == 32, "32-byte result");

static uint8_t echo_buf[ECHO_CAPACITY];

silica_text_echo_result silica_text_echo(const uint8_t *text_ptr, uint64_t text_len) {
    silica_text_echo_result result = {0, 0, 0, 0};

    if (text_ptr == 0) {
        result.tag = 1;
        result.error_code = 1;
        return result;
    }
    if (text_len > (uint64_t)(ECHO_CAPACITY - ECHO_PREFIX_LEN)) {
        result.tag = 1;
        result.error_code = 3;
        return result;
    }

    for (size_t i = 0; i < ECHO_PREFIX_LEN; i++) {
        echo_buf[i] = (uint8_t)ECHO_PREFIX[i];
    }
    for (size_t i = 0; i < (size_t)text_len; i++) {
        echo_buf[ECHO_PREFIX_LEN + i] = text_ptr[i];
    }

    result.tag = 0;
    result.text_ptr = echo_buf;
    result.text_len = ECHO_PREFIX_LEN + text_len;
    result.error_code = 0;
    return result;
}
