# The (:store) carrier kind on the (:memory) medium (transport_serialization_design.md §6.8, phase S0):
# seven owner programs, each a scripted actor that declares `carried_on journal: (:store) (:memory,
# <capacity>, <retention>);`, starts the carrier with spawn_dangerous_carrier and prints every message
# the carrier sends it.
#
#   store_append_replay    (:etf) values appended and replayed; the two acknowledgement levels
#   store_replay_credit    credit-paced replay of a log five times the write-behind buffer
#   store_large_value      a value larger than the largest record, across records and back
#   store_ring             :ring wrap, a reader behind `oldest`, a replay overtaken by the writer
#   store_stop             :stop full; nothing is overwritten
#   store_trim             :trim full and release, the :log answer, at-least-once delivery
#   store_replay_control   an orphaned partial frame, a read inside a frame, :busy, :read_stop,
#                          :in_use, :beyond_tail, :empty, :too_long
#
# The memory medium is an ordinary actor, so nothing foreign is linked; the directory reuses the app
# integrate body of ffi_addition (several executables in one compile, the wait-for-exit marker) as the
# TCP carrier trials beside it do.
THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
APP_TRIAL_DIR := $(abspath $(THIS_DIR))
APP_LABEL := app_transport_store_memory
APP_EXECUTABLES := store_append_replay store_replay_credit store_large_value store_ring store_stop store_trim store_replay_control
APP_LINK_OBJECTS := wire_etf.o wireframe.o Carrier.o storelog.o store_memory_carrier.o

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
