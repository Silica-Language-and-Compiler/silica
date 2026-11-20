# The accepted-connection trial: the listener casts (:accepted, fd, peer) and its owner starts the connection carrier as a
# :temporary :dangerous child of its own supervisor; the dialling carrier is a child of the same supervisor. Two connections
# are made one after the other with the same child ids; after each close the supervisor holds no live child.
THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
APP_TRIAL_DIR := $(abspath $(THIS_DIR))
APP_LABEL := app_transport_tcp_accept_supervised
APP_EXECUTABLES := dangerous_tcp_accept_supervised
APP_LINK_OBJECTS := Supervisor.o dangerous_sockets.o dangerous_tcp_carrier.o

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
