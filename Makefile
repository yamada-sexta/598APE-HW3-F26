CC = gcc
OPT_LEVEL ?= 3
CFLAGS ?= -O$(OPT_LEVEL) -g -Werror -march=native -flto -fopenmp
LDLIBS ?= -lm
BUILD := build

all: sandpile.exe

sandpile.exe: sandpile.c stb_image_write.h Makefile
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)

$(BUILD):
	mkdir -p $@

$(BUILD)/sandpile-O%.exe: sandpile.c stb_image_write.h Makefile | $(BUILD)
	$(CC) $(filter-out -O%,$(CFLAGS)) -O$* $< -o $@ $(LDLIBS)

compiler-variants: $(BUILD)/sandpile-O1.exe $(BUILD)/sandpile-O2.exe $(BUILD)/sandpile-O3.exe

PYTHON ?= python3
sat-search: | $(BUILD)
	$(PYTHON) experiments/sat/carry_lut.py --timeout 10 --directory $(BUILD)/sat --output $(BUILD)/sat.json

JULIA ?= julia
JULIA_FLAGS ?= --startup-file=no --history-file=no --threads=1 -O3 --check-bounds=yes
lut-bridge: | $(BUILD)
	$(JULIA) $(JULIA_FLAGS) experiments/julia/lut_bridge.jl $(BUILD)/lut experiments/sat/known-six.toml

giant-grid: | $(BUILD)
	$(JULIA) $(JULIA_FLAGS) experiments/julia/giant_grid.jl > $(BUILD)/giant-grid.toml

clean:
	rm -f sandpile.exe $(BUILD)/*.exe

.PHONY: all compiler-variants sat-search lut-bridge giant-grid clean
