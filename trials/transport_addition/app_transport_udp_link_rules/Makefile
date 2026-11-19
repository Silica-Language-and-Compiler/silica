# The link rules of the (:udp) carrier (hosted Ethernet plan stage E2, transport_links_design.md §3.2): the local
# address form "<host>:<port>@<local>" a declared link allows (<port>, <ipv4>:<port>, any:<port>), what it refuses at
# :open with (:link_down, :fault) to the owner and the carrier ending (:explicit, :link_unavailable), and the strict
# IPv4 parser's (:explicit, :bad_address) for a malformed peer or local address. Every program is one carrier and one
# owner on this host; none picks a fixed port (local port 0), so parallel runs cannot collide. Same shape as
# app_transport_tcp_link_rules, and it links the socket wrappers like that app does. The Mac goldens (.scout) are the
# only ones; the Linux hosts are unverified. The refusal trials end with an actor-failure banner (the carrier's
# reason), which the normalized compare reduces to <PTR> lines.
THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
APP_TRIAL_DIR := $(abspath $(THIS_DIR))
APP_LABEL := app_transport_udp_link_rules
APP_EXECUTABLES := dangerous_udp_link_listen_ip dangerous_udp_link_ip_refused_loopback dangerous_udp_link_any_refused_interface dangerous_udp_link_interface_absent dangerous_udp_link_ethernet_absent dangerous_udp_bad_peer dangerous_udp_bad_local
APP_LINK_OBJECTS := wire_etf.o wireframe.o Carrier.o dangerous_sockets.o dangerous_udp_carrier.o

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
