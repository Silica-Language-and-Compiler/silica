# The (:store) carrier kind on a hosted backing (transport_serialization_design.md §6.8, phase S1): six
# owner programs, each a scripted actor that declares `carried_on journal: (:store) (:backing,
# "<name>.sildat", <capacity>, <retention>);`, starts the carrier with spawn_dangerous_carrier and
# prints every message the carrier sends it. A program that uses a dangerous carrier is itself named
# dangerous_ (E4021).
#
#   dangerous_store_backing_restart   records survive the carrier: a new carrier on the same backing finds the
#                                     log, replays it and appends to it; a sync's padding is read across
#   dangerous_store_backing_torn      a torn tail ends the log; the next record is written past it
#   dangerous_store_backing_flipped   a flipped byte in the middle of the log stops a replay with :corrupt
#   dangerous_store_backing_stale     records of an earlier lap after the tail end the log by their numbers
#   dangerous_store_backing_mismatch  a backing of another size is refused, not resized
#   dangerous_store_backing_in_use    a second carrier on an open backing is refused (the lock)
#
# Before the run make_backings.py writes the damaged backings (independently of the Silica code, in the
# on-medium form of the design) and removes the two that a trial must create itself. After the run the
# restart program is run a SECOND time, a second process on the backing the first run left: it must
# find the six records of the first run (dangerous_store_backing_restart.second.scout).
#
# The backing carrier is a dangerous actor over the Fifi wrappers of compiler/stdlib/net/silica_store.c,
# built as a fixture (libsilica_store.a) like the socket wrappers.
THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
APP_TRIAL_DIR := $(abspath $(THIS_DIR))
APP_LABEL := app_transport_store_backing
APP_EXECUTABLES := dangerous_store_backing_restart dangerous_store_backing_torn dangerous_store_backing_flipped dangerous_store_backing_stale dangerous_store_backing_mismatch dangerous_store_backing_in_use
APP_LINK_OBJECTS := wireframe.o Carrier.o storelog.o dangerous_store.o dangerous_store_backing_carrier.o

FFI_TRIAL_DIR := $(abspath $(THIS_DIR)/../../ffi_addition)
# The platform's view of dangerous_exposure_source, relative to this directory (FFI_PLATFORM comes
# from fixtures_paths.mk, read by the include below, so the assignment is recursive).
APP_EXPOSURE_LINK = ../../ffi_addition/fixtures/build/$(FFI_PLATFORM)/dangerous_exposure_source

include $(FFI_TRIAL_DIR)/common_app.mk

.PHONY: all integrate clean fixtures

all: integrate

integrate-run: fixtures
integrate-run:
	@python3 "$(APP_TRIAL_DIR)/make_backings.py" "$(APP_TRIAL_DIR)"
	$(APP_INTEGRATE_BODY)
	@cd "$(APP_TRIAL_DIR)" && { python3 "$(FFI_TRIAL_DIR)/run_integration_exit_after_marker.py" "$(APP_TRIAL_DIR)" dangerous_store_backing_restart dangerous_store_backing_restart.second$(SOUT_EXT) done 1 > /dev/null 2>&1 & \
		runner=$$!; ( sleep 40; kill -TERM $$runner 2>/dev/null ) > /dev/null 2>&1 & watch=$$!; wait $$runner; kill $$watch 2>/dev/null; true; }; \
	if "$(SHELL)" "$(FFI_TRIAL_DIR)/compare_scout_normalized.sh" dangerous_store_backing_restart.second$(SOUT_EXT) dangerous_store_backing_restart.second.scout > /dev/null 2>&1; then \
		echo "  ✅✅ $(APP_LABEL)/dangerous_store_backing_restart (second run on the first run's backing) output matches .scout"; \
		read ok ko < .integrate_counts; printf '%d %d\n' $$((ok + 1)) "$$ko" > .integrate_counts; \
	else \
		echo "  ❌ $(APP_LABEL)/dangerous_store_backing_restart (second run on the first run's backing) differs from dangerous_store_backing_restart.second.scout"; \
		"$(SHELL)" "$(FFI_TRIAL_DIR)/compare_scout_normalized.sh" dangerous_store_backing_restart.second$(SOUT_EXT) dangerous_store_backing_restart.second.scout || true; \
		read ok ko < .integrate_counts; printf '%d %d\n' "$$ok" $$((ko + 1)) > .integrate_counts; \
		exit 1; \
	fi

clean:
	@cd "$(THIS_DIR)" && $(call TRIAL_RM_UNTRACKED,$(APP_EXECUTABLES) dangerous_exposure_source); rm -f *.sams *.o *.iface  silica.config silica.link .integrate_counts silica.compile.order silica.needs_runtime silica.atoms *.sout *.sildat
