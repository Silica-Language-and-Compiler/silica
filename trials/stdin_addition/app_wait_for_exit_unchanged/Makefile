# The regression trial without a (:stdin) link: it needs none of the stdin stdlib modules, so none is compiled or linked.
STDLIB_MODS :=
THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
include $(THIS_DIR)../trial.mk
