#include <stdint.h>

int8_t silica_abi_i8_identity(int8_t value) {
    return value;
}

int16_t silica_abi_i16_identity(int16_t value) {
    return value;
}

int32_t silica_abi_i32_identity(int32_t value) {
    return value;
}

int64_t silica_abi_i64_identity(int64_t value) {
    return value;
}

uint8_t silica_abi_u8_identity(uint8_t value) {
    return value;
}

uint16_t silica_abi_u16_identity(uint16_t value) {
    return value;
}

uint32_t silica_abi_u32_identity(uint32_t value) {
    return value;
}

uint64_t silica_abi_u64_identity(uint64_t value) {
    return value;
}

float silica_abi_f32_identity(float value) {
    return value;
}

double silica_abi_f64_identity(double value) {
    return value;
}

uint8_t silica_abi_bool_identity(uint8_t value) {
    return value != 0 ? 1 : 0;
}

typedef struct silica_abi_i64_pair {
    int64_t left;
    int64_t right;
} silica_abi_i64_pair;

silica_abi_i64_pair silica_abi_i64_pair_make(int64_t left, int64_t right) {
    silica_abi_i64_pair pair;
    pair.left = left;
    pair.right = right;
    return pair;
}

int64_t silica_abi_i64_pair_sum(silica_abi_i64_pair pair) {
    return pair.left + pair.right;
}

typedef struct silica_abi_i64_result {
    int64_t tag;
    int64_t value;
    int64_t error_code;
} silica_abi_i64_result;

silica_abi_i64_result silica_abi_i64_result_ok(int64_t value) {
    silica_abi_i64_result result;
    result.tag = 0;
    result.value = value;
    result.error_code = 0;
    return result;
}

/* Three int64 arguments and a struct result: more argument words than a 32-bit target has argument
   registers. Each argument shows in its own digits of the value. */
silica_abi_i64_result silica_abi_i64_result_of3(int64_t a, int64_t b, int64_t c) {
    silica_abi_i64_result result;
    result.tag = 0;
    result.value = a * 10000 + b * 100 + c;
    result.error_code = 0;
    return result;
}
