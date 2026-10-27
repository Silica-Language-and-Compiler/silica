THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
APP_TRIAL_DIR := $(abspath $(THIS_DIR))
APP_LABEL := app_foreign_abi_valid
APP_EXECUTABLES := dangerous_scalar_abi_valid dangerous_string_two_layer_valid

include $(abspath $(THIS_DIR)/../common_app.mk)

.PHONY: all integrate clean fixtures

all: integrate

integrate-run: fixtures
integrate-run:
	$(APP_INTEGRATE_BODY)

clean:
	@cd "$(THIS_DIR)" && $(call TRIAL_RM_UNTRACKED,$(APP_EXECUTABLES) dangerous_exposure_source); rm -f *.sams *.o *.iface  silica.config silica.link .integrate_counts silica.compile.order silica.needs_runtime silica.atoms *.sout
