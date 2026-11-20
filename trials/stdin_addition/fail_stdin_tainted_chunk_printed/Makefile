# One compile-fail trial: the program must be rejected (see trial.mk, TRIAL_COMPILE_FAIL).
THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
TRIAL_COMPILE_FAIL := 1
include $(THIS_DIR)../trial.mk
