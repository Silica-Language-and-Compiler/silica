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

// Runtime entries the emitter can reference that stage 1 of the STM32-L476RG_raw port does not
// implement yet. Each is a Thumb function that ends the program with the runtime abort
// "[silica] abort: runtime entry not yet ported to STM32-L476RG_raw at 0x<pc>" (status 71), the
// address being the stub's own, so a program that needs one fails loudly at the first use and the
// image always links. Remove an entry here when its real routine lands in another rt_*.S file
// (a duplicate definition is a link error, which is the point). The list is derived from every
// `silica_rt_*` name the emitter tree references (board/tools/list_runtime_stubs.sh regenerates it).

#include "rt_defs.h"

    .syntax unified
    .cpu cortex-m4
    .fpu fpv4-sp-d16
    .thumb

    .section .text.silica_rt_stubs, "ax", %progbits

.macro STUB name
    FUNC \name
    bl      silica_rt_unsupported
    .size   \name, . - \name
.endm

    STUB silica_rt_actor_call
    STUB silica_rt_actor_call_registered
    STUB silica_rt_actor_failure_agent_type
    STUB silica_rt_actor_failure_reason_atom
    STUB silica_rt_actor_failure_reason_tag
    STUB silica_rt_actor_failure_release
    STUB silica_rt_actor_fault_hook
    STUB silica_rt_actor_kill_abnormal
    STUB silica_rt_actor_kill_abnormal_named
    STUB silica_rt_actor_recv
    STUB silica_rt_actor_supervision_ingress_enqueue
    STUB silica_rt_actor_supervision_wait_and_drain_one
    STUB silica_rt_actor_unknown
    STUB silica_rt_behaviour_name
    STUB silica_rt_cancel_timer
    STUB silica_rt_child_table_first_ref
    STUB silica_rt_child_table_row_ref
    STUB silica_rt_fail_self
    STUB silica_rt_ffi_call
    STUB silica_rt_ffi_string_in
    STUB silica_rt_ffi_string_out
    STUB silica_rt_get_actor_memory_usage
    STUB silica_rt_get_core_capabilities
    STUB silica_rt_get_cpu_topology
    STUB silica_rt_get_registry_actor
    STUB silica_rt_message_copy
    STUB silica_rt_message_measure
    STUB silica_rt_ordering_bundle_make
    STUB silica_rt_ordering_env_fresh
    STUB silica_rt_ordering_env_next
    STUB silica_rt_ordering_identity_make
    STUB silica_rt_ordering_identity_same
    STUB silica_rt_region_alloc
    STUB silica_rt_region_grow
    STUB silica_rt_report_reason
    STUB silica_rt_send_after
    STUB silica_rt_stop_self_explicit
    STUB silica_rt_sup_exit_report
    STUB silica_rt_sup_op_child
    STUB silica_rt_sup_op_error
    STUB silica_rt_sup_op_tag
    STUB silica_rt_supervisor_add_child
    STUB silica_rt_supervisor_get_child
    STUB silica_rt_supervisor_get_child_agent_type
    STUB silica_rt_supervisor_get_child_id
    STUB silica_rt_supervisor_get_child_info
    STUB silica_rt_supervisor_get_child_restart
    STUB silica_rt_supervisor_remove_child
    STUB silica_rt_supervisor_restart_child
    STUB silica_rt_supervisor_set_report_sink
    STUB silica_rt_supervisor_start
    STUB silica_rt_supervisor_start_child
    STUB silica_rt_supervisor_terminate_child
    STUB silica_rt_supervisor_which_children
    STUB silica_rt_timer_prepare
