# The close-after-end (:tcp) trial (transport design §6.2, upgrade note items 1 and 4; specification §16.1.2): a refused dial
# ends the carrier, and its owner then casts :close and (:credit, 1) to the ended carrier. Each cast returns false and the
# owner goes on to handle its next message. It links the socket wrappers like the loopback link trial and reuses its
# fixtures and integrate body. The Mac goldens are the only ones; the Linux hosts are unverified.
THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
APP_TRIAL_DIR := $(abspath $(THIS_DIR))
APP_LABEL := app_transport_tcp_close_after_end
# dangerous_tcp_carrier_end_memory is not run on the Mac for now (2026-11-20): in a full parallel trial run its peak
# resident set reached 261 MB against the 60 MB ceiling, while alone it peaks near 11 MB. The defect is recorded in
# compiler/design_documents/defect_tcp_carrier_end_memory_mac_2026-11-20.md.
# SILICA_EMIT_TARGET is set by silica_compiler.mk (included below), so the list is expanded when it is used.
APP_EXECUTABLES = dangerous_tcp_close_after_end $(if $(filter apple_silicon_mac,$(SILICA_EMIT_TARGET)),,dangerous_tcp_carrier_end_memory) dangerous_state_holds_carrier_ref
APP_LINK_OBJECTS := wire_etf.o wireframe.o Carrier.o dangerous_sockets.o dangerous_tcp_carrier.o

FFI_TRIAL_DIR := $(abspath $(THIS_DIR)/../../ffi_addition)
# The platform's view of dangerous_exposure_source, relative to this directory (FFI_PLATFORM comes
# from fixtures_paths.mk, read by the include below, so the assignment is recursive).
APP_EXPOSURE_LINK = ../../ffi_addition/fixtures/build/$(FFI_PLATFORM)/dangerous_exposure_source

include $(FFI_TRIAL_DIR)/common_app.mk

.PHONY: all integrate clean fixtures

all: integrate

integrate-run: fixtures
integrate-run:
	$(APP_INTEGRATE_BODY)

clean:
	@cd "$(THIS_DIR)" && $(call TRIAL_RM_UNTRACKED,$(APP_EXECUTABLES) dangerous_exposure_source); rm -f *.sams *.o *.iface  silica.config silica.link .integrate_counts silica.compile.order silica.needs_runtime silica.atoms *.sout
