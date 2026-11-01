.text
.align 2

.global main_print
.global diagnostics_core_print
.global main_compile_pipeline_print
.global main_parse_print
.global main_unit_print
main_print:
diagnostics_core_print:
main_compile_pipeline_print:
main_parse_print:
main_unit_print:
    STP X29, X30, [SP, #-16]!
    BL _silica_print_string
    MOV X0, #0
    LDP X29, X30, [SP], #16
    RET

.global main_file_exists
.global module_iface_file_exists
.global ffi_link_manifest_file_exists
.global ffi_sidecar_loader_file_exists
.global main_driver_file_exists
.global main_hygiene_file_exists
.global main_lists_file_exists
main_file_exists:
module_iface_file_exists:
ffi_link_manifest_file_exists:
ffi_sidecar_loader_file_exists:
main_driver_file_exists:
main_hygiene_file_exists:
main_lists_file_exists:
    STP X29, X30, [SP, #-16]!
    BL _silica_read_file_path
    AND X0, X0, #1
    LDP X29, X30, [SP], #16
    RET

.global main_read_lines
.global module_iface_read_lines
.global ffi_sidecar_loader_read_lines
.global lexer_runner_read_lines
.global main_driver_read_lines
main_read_lines:
module_iface_read_lines:
ffi_sidecar_loader_read_lines:
lexer_runner_read_lines:
main_driver_read_lines:
    STP X29, X30, [SP, #-64]!
    STP X19, X20, [SP, #16]
    STP X21, X22, [SP, #32]
    BL _silica_read_file_path
    MOV X19, X0          // success bits
    MOV X20, X1          // SilicaString*
    AND X9, X19, #1
    CBZ X9, rl_fail
    CBZ X20, rl_fail
    LDR X21, [X20, #8]   // data
    LDR X22, [X20, #16]  // length
    // mmap
    ADD X1, X22, #25
    MOV X0, #0
    MOV X2, #3
    MOV X3, #0x1002
    MOV X4, #-1
    MOV X5, #0
    MOVZ X16, #0xC5
    MOVK X16, #0x200, LSL #16
    SVC #0x80
    // check mmap fail: -1
    CMN X0, #1
    B.EQ rl_fail
    MOV X19, X0
    // build the SilicaString descriptor in place: tag / data / length
    MOV X9, #-1
    STR X9, [X19]
    ADD X9, X19, #24
    STR X9, [X19, #8]
    STR X22, [X19, #16]
    MOV X10, X21
    MOV X11, X22
rl_cp:
    CBZ X11, rl_cp_done
    LDRB W12, [X10], #1
    STRB W12, [X9], #1
    SUB X11, X11, #1
    B rl_cp
rl_cp_done:
    STRB WZR, [X9]
    MOV X0, X19
    B rl_ret
rl_fail:
    MOV X0, #0
rl_ret:
    LDP X21, X22, [SP, #32]
    LDP X19, X20, [SP, #16]
    LDP X29, X30, [SP], #64
    RET

.global main_delete_file
.global module_iface_delete_file
.global build_output_delete_file
.global main_hygiene_delete_file
.global main_lists_delete_file
main_delete_file:
module_iface_delete_file:
build_output_delete_file:
main_hygiene_delete_file:
main_lists_delete_file:
    STP X29, X30, [SP, #-16]!
    BL _silica_delete_file_path
    AND X0, X0, #1
    LDP X29, X30, [SP], #16
    RET

.global main_append_file
.global module_iface_append_file
.global build_output_append_file
.global main_hygiene_append_file
.global main_lists_append_file
main_append_file:
module_iface_append_file:
build_output_append_file:
main_hygiene_append_file:
main_lists_append_file:
    STP X29, X30, [SP, #-16]!
    BL _silica_append_file_path
    AND X0, X0, #1
    LDP X29, X30, [SP], #16
    RET
