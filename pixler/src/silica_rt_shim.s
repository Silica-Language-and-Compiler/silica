// silica_rt_shim.s - transitional runtime shim for the Rust-free selfhost build.
//
// src links NO Rust libraries. The bootstrap crate's libsilica_compiler.a
// used to supply the runtime; these four symbols are the only ones the seed-built
// objects still reference. They are SCAFFOLDING: src's own emitter already
// emits inline implementations (file_io_inline.silica, print_string_inline.silica),
// so once selfhost compiles itself these become dead and this file can be deleted.
//
// ABI (matches the bootstrap crate's C ABI):
//   SilicaString { tag: u64 (+0, first byte 0xFF), data: *u8 (+8), length: u64 (+16) }
//   SilicaResult { success: bool (+0), data: *u8 (+8) }  -> returned in x0 / x1
// Every string argument is a SilicaString* (tag = all ones). There is no raw-char*
// form: a string is a byte buffer and may contain 0x00 (spec 4.1.6). Path data is
// length-delimited, so it is copied NUL-terminated before syscalls.

.text
.align 2

// x0 = ptr -> x0 = data, x1 = len. Clobbers x2, x3.
_shim_get_string:
    cbz  x0, Lgs_null
    ldr  x1, [x0, #16]
    ldr  x0, [x0, #8]
    ret
Lgs_null:
    mov  x1, #0
    ret

// x0 = data, x1 = len -> x0 = malloc'd NUL-terminated copy (0 on failure).
_shim_cpath:
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    mov  x19, x0
    mov  x20, x1
    add  x0, x20, #1
    bl   _malloc
    cbz  x0, Lcp_out
    mov  x21, x0
    mov  x22, #0
Lcp_loop:
    cmp  x22, x20
    b.hs Lcp_term
    ldrb w2, [x19, x22]
    strb w2, [x21, x22]
    add  x22, x22, #1
    b    Lcp_loop
Lcp_term:
    strb wzr, [x21, x20]
    mov  x0, x21
Lcp_out:
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret

.globl _silica_print_string
_silica_print_string:
    cbz  x0, Lps_ret
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    bl   _shim_get_string
    cbz  x0, Lps_out
    cbz  x1, Lps_out
    mov  x2, x1
    mov  x1, x0
    mov  x0, #1
    bl   _write
Lps_out:
    ldp  x29, x30, [sp], #16
Lps_ret:
    ret

.globl _silica_delete_file_path
_silica_delete_file_path:
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    bl   _shim_get_string
    bl   _shim_cpath
    cbz  x0, Ldf_fail
    mov  x19, x0
    bl   _unlink
    mov  x20, x0
    mov  x0, x19
    bl   _free
    cmp  x20, #0
    cset w0, eq
    mov  x1, #0
    b    Ldf_out
Ldf_fail:
    mov  x0, #0
    mov  x1, #0
Ldf_out:
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret

.section __TEXT,__cstring
Lmode_append:
    .asciz "a"
Lmode_read:
    .asciz "rb"

.text
.align 2

// x0 = path ptr -> x0 = success, x1 = SilicaString*
.globl _silica_read_file_path
_silica_read_file_path:
    stp  x29, x30, [sp, #-80]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    bl   _shim_get_string
    bl   _shim_cpath
    cbz  x0, Lrf_fail
    mov  x19, x0
    mov  x0, x19
    mov  x1, #0
    bl   _open
    cmp  w0, #0
    b.lt Lrf_free_fail
    mov  x20, x0
    mov  x0, x20
    mov  x1, #0
    mov  x2, #2
    bl   _lseek
    mov  x21, x0
    cmp  x21, #0
    b.lt Lrf_close_fail
    mov  x0, x20
    mov  x1, #0
    mov  x2, #0
    bl   _lseek
    add  x0, x21, #1
    bl   _malloc
    cbz  x0, Lrf_close_fail
    mov  x22, x0
    mov  x0, x20
    mov  x1, x22
    mov  x2, x21
    bl   _read
    mov  x23, x0
    cmp  x23, #0
    b.ge Lrf_term
    mov  x23, #0
Lrf_term:
    strb wzr, [x22, x23]
    mov  x0, x20
    bl   _close
    mov  x0, #24
    bl   _malloc
    cbz  x0, Lrf_freebuf
    mov  x24, x0
    mov  x2, #-1
    str  x2, [x24]
    str  x22, [x24, #8]
    str  x23, [x24, #16]
    mov  x0, x19
    bl   _free
    mov  x0, #1
    mov  x1, x24
    b    Lrf_out
Lrf_freebuf:
    mov  x0, x22
    bl   _free
    b    Lrf_free_fail
Lrf_close_fail:
    mov  x0, x20
    bl   _close
Lrf_free_fail:
    mov  x0, x19
    bl   _free
Lrf_fail:
    mov  x0, #0
    mov  x1, #0
Lrf_out:
    ldp  x23, x24, [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #80
    ret

// x0 = path ptr, x1 = content ptr -> x0 = success, x1 = 0
.globl _silica_append_file_path
_silica_append_file_path:
    stp  x29, x30, [sp, #-80]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    mov  x23, x1
    bl   _shim_get_string
    bl   _shim_cpath
    cbz  x0, Laf_fail
    mov  x19, x0
    mov  x0, x19
    adrp x1, Lmode_append@PAGE
    add  x1, x1, Lmode_append@PAGEOFF
    bl   _fopen
    cbz  x0, Laf_free_fail
    mov  x20, x0
    mov  x0, x23
    bl   _shim_get_string
    mov  x21, x0
    mov  x22, x1
    cbz  x21, Laf_close
    cbz  x22, Laf_close
    mov  x0, x21
    mov  x1, #1
    mov  x2, x22
    mov  x3, x20
    bl   _fwrite
Laf_close:
    mov  x0, x20
    bl   _fclose
    mov  x0, x19
    bl   _free
    mov  x0, #1
    mov  x1, #0
    b    Laf_out
Laf_free_fail:
    mov  x0, x19
    bl   _free
Laf_fail:
    mov  x0, #0
    mov  x1, #0
Laf_out:
    ldp  x23, x24, [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #80
    ret
