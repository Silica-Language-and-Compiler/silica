# nucleo_flash_max_actors: a FLASH image for the ST Nucleo-L476RG (STM32-L476RG_raw) that spawns as many
# actors as its SRAM holds, less three. See README.md.
#
#   make            same as `make build`: compile and link the flash image (touches no board)
#   make build      compile main.silica with the STM32-L476RG_raw compiler, link with BOARD_EXEC=flash
#   make size       flash footprint, SRAM budget and the actor estimate recomputed from the linker map
#   make flash      BY HAND ONLY: program the image into the board's flash and run it (WEARS THE FLASH)
#   make clean      remove build/
#
# Nothing here is part of the trials: no trial directory, skip row or make integrate hook names this
# directory, and `make flash` is never a prerequisite of another target.

REPO     := $(abspath $(CURDIR)/../..)
COMPILER := /Volumes/2T/silica/binaries/silica-compiler-STM32-L476RG_raw
BOARD    := $(REPO)/compiler/src/emitter/STM32-L476RG_raw/board
STDLIB   := $(REPO)/compiler/stdlib
PYTHON   ?= $(HOME)/.espressif/python_env/idf6.2_py3.14_env/bin/python
APP      := nucleo_flash_max_actors
BUILD    := build
IMAGE    := $(BUILD)/image/$(APP)

.DEFAULT_GOAL := build
.PHONY: build size flash clean

build: $(IMAGE).elf

# The compiler runs in build/ on a one-unit-per-line silica.config (exit 75/76: continue with the next unit).
$(BUILD)/main.sams: main.silica $(STDLIB)/Supervisor.silica
	@mkdir -p $(BUILD)
	@ln -sfn ../main.silica $(BUILD)/main.silica
	@ln -sfn $(STDLIB)/Supervisor.silica $(BUILD)/Supervisor.silica
	@printf '%s\n' main.silica Supervisor.silica > $(BUILD)/silica.config
	@echo "Compiling with $(COMPILER)"
	@cd $(BUILD) && while true; do "$(COMPILER)"; ec=$$?; \
	    [ $$ec -eq 0 ] && break; \
	    [ $$ec -eq 75 ] || [ $$ec -eq 76 ] || { echo "compile failed (exit $$ec)"; exit $$ec; }; done

$(IMAGE).elf: $(BUILD)/main.sams
	BOARD_EXEC=flash sh $(BOARD)/tools/build_image.sh -o $(IMAGE) \
	    $(BUILD)/main.sams $(BUILD)/Supervisor.sams $(BUILD)/__silica_runtime.sams

size: $(IMAGE).elf
	@sh ./estimate_actors.sh $(IMAGE) main.silica

# BY HAND ONLY. Erases and reprograms the flash pages the image covers (about 10,000 cycles per page).
# Not a prerequisite of anything; run it yourself with the board attached and nothing else using it.
flash: $(IMAGE).elf
	"$(PYTHON)" $(BOARD)/tools/run_on_board.py --exec flash --yes-wear-flash --timeout 60 $(IMAGE).elf

clean:
	rm -rf $(BUILD)
