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

clean:
	rm -f sandpile.exe $(BUILD)/*.exe

.PHONY: all compiler-variants clean
