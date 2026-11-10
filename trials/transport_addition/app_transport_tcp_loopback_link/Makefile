# The loopback apps of ffi_addition/app_transport_tcp_loopback with their carriers declared on
# (:loopback) (transport_links_design.md §3.3, §10 phase A: `app_transport_tcp_loopback_link`,
# `app_transport_udp_loopback_link`): `carried_on` declarations and spawn_dangerous_carrier in place of
# the module names and initial-state literals; the outputs are the loopback trial's goldens. The
# original trial is kept unchanged so its Linux goldens stay valid.
THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
APP_TRIAL_DIR := $(abspath $(THIS_DIR))
APP_LABEL := app_transport_tcp_loopback_link
APP_EXECUTABLES := dangerous_tcp_loopback_link dangerous_udp_loopback_link
APP_LINK_OBJECTS := wire_etf.o wireframe.o Carrier.o dangerous_sockets.o dangerous_tcp_carrier.o dangerous_udp_carrier.o

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
