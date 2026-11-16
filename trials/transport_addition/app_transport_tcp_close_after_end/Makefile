# The close-after-end (:tcp) trial (transport design §6.2, upgrade note items 1 and 4; specification §16.1.2): a refused dial
# ends the carrier, and its owner then casts :close and (:credit, 1) to the ended carrier. Each cast returns false and the
# owner goes on to handle its next message. It links the socket wrappers like the loopback link trial and reuses its
# fixtures and integrate body. The Mac goldens are the only ones; the Linux hosts are unverified.
THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
APP_TRIAL_DIR := $(abspath $(THIS_DIR))
APP_LABEL := app_transport_tcp_close_after_end
APP_EXECUTABLES := dangerous_tcp_close_after_end
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
