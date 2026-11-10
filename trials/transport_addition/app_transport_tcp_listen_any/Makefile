# The (:tcp) wildcard listener trial (transport_serialization_design.md §6.2, §6.4): a listener opened
# with "listen:any:0" binds every IPv4 interface (0.0.0.0, a free port) and a client reaches it through
# 127.0.0.1. Same shape as app_transport_tcp_listener (one client here); it links the socket wrappers like
# the ffi_addition apps do, so it reuses that suite's fixtures and integrate body from here. Apple goldens
# only (the Linux goldens of the transport apps are stale until a Linux host runs them).
THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
APP_TRIAL_DIR := $(abspath $(THIS_DIR))
APP_LABEL := app_transport_tcp_listen_any
APP_EXECUTABLES := dangerous_tcp_listen_any
APP_LINK_OBJECTS := wire_etf.o wireframe.o carrier.o dangerous_sockets.o dangerous_tcp_carrier.o

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
