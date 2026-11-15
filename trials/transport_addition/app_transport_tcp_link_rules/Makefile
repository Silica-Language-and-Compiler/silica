# The link rules of the (:tcp) carrier (hosted Ethernet plan stage E2, transport_links_design.md §3.2): what a
# declared link allows a listener and a dialer to do, and what it refuses at :open with (:link_down, :fault)
# to the owner and the carrier ending (:explicit, :link_unavailable). Every program is one carrier and one
# owner on this host; none picks a fixed port (listeners take port 0, refused or absent links bind nothing), so
# parallel runs cannot collide. Same shape as app_transport_tcp_listen_any: it links the socket wrappers like the
# ffi_addition apps do, so it reuses that suite's fixtures and integrate body. The Mac goldens (.scout) are the
# only ones; the Linux hosts are unverified. The refusal trials end with an actor-failure banner (the carrier's
# :link_unavailable), which the normalized compare reduces to <PTR> lines.
THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
APP_TRIAL_DIR := $(abspath $(THIS_DIR))
APP_LABEL := app_transport_tcp_link_rules
APP_EXECUTABLES := dangerous_link_interface_absent dangerous_link_wifi_absent dangerous_link_ethernet_absent dangerous_link_listen_ip dangerous_link_listen_ip_refused_loopback dangerous_link_listen_any_refused_interface
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
