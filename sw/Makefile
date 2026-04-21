# AttoIO firmware build.
#
# Usage:
#   make FW=<name>        -> build build/<name>.elf  + .bin + .hex
#   make clean
#
# Defaults:
#   FW ?= empty           (picks up sw/empty/main.c)
#
# Layout assumed per firmware:
#   sw/<name>/main.c       (plus optional .c/.S/.h siblings)
#   sw/<name>/config.h     (optional; pin map, constants)

FW           ?= empty
BUILD_DIR    ?= build
FW_DIR       := $(CURDIR)/$(FW)
OUT_DIR      := $(CURDIR)/../build/sw/$(FW)

# ---- Toolchain ---------------------------------------------------------
CROSS   ?= riscv64-unknown-elf-
CC       = $(CROSS)gcc
LD       = $(CROSS)gcc
OBJCOPY  = $(CROSS)objcopy
OBJDUMP  = $(CROSS)objdump
SIZE     = $(CROSS)size

MARCH    = rv32ec_zicsr
MABI     = ilp32e

CFLAGS   = -march=$(MARCH) -mabi=$(MABI) \
           -Os -g3 -ffunction-sections -fdata-sections \
           -fno-builtin -ffreestanding \
           -Wall -Wextra -Wno-unused-parameter -Wno-array-bounds \
           -I$(CURDIR) -I$(CURDIR)/common -I$(FW_DIR)

ASFLAGS  = -march=$(MARCH) -mabi=$(MABI)

LDFLAGS  = -march=$(MARCH) -mabi=$(MABI) \
           -nostartfiles -nostdlib \
           -Wl,-T,$(CURDIR)/link.ld \
           -Wl,--gc-sections -Wl,-Map=$(OUT_DIR)/$(FW).map

# ---- Sources -----------------------------------------------------------
COMMON_SRCS := $(wildcard $(CURDIR)/common/*.c)
FW_SRCS     := $(wildcard $(FW_DIR)/*.c) $(wildcard $(FW_DIR)/*.S)
CRT0_SRC    := $(CURDIR)/crt0.S

ALL_SRCS    := $(CRT0_SRC) $(COMMON_SRCS) $(FW_SRCS)

OBJS := $(patsubst %.c,$(OUT_DIR)/%.o,$(notdir $(filter %.c,$(ALL_SRCS)))) \
        $(patsubst %.S,$(OUT_DIR)/%.o,$(notdir $(filter %.S,$(ALL_SRCS))))

VPATH := $(CURDIR) $(CURDIR)/common $(FW_DIR)

# ---- Targets -----------------------------------------------------------
.PHONY: all clean size dump

all: $(OUT_DIR)/$(FW).elf $(OUT_DIR)/$(FW).bin $(OUT_DIR)/$(FW).hex size

$(OUT_DIR):
	@mkdir -p $@

$(OUT_DIR)/%.o: %.c | $(OUT_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(OUT_DIR)/%.o: %.S | $(OUT_DIR)
	$(CC) $(ASFLAGS) -c $< -o $@

$(OUT_DIR)/$(FW).elf: $(OBJS) $(CURDIR)/link.ld | $(OUT_DIR)
	$(LD) $(LDFLAGS) $(OBJS) -o $@

$(OUT_DIR)/$(FW).bin: $(OUT_DIR)/$(FW).elf
	$(OBJCOPY) -O binary $< $@

# 32-bit-per-line hex image for $readmemh in Icarus testbenches.
# We use objcopy -> binary -> awk to emit one 8-hex-digit word per line.
$(OUT_DIR)/$(FW).hex: $(OUT_DIR)/$(FW).bin
	@xxd -c 4 -p $< | awk '{ \
	    b1=substr($$0,1,2); b2=substr($$0,3,2); \
	    b3=substr($$0,5,2); b4=substr($$0,7,2); \
	    printf "%s%s%s%s\n", b4, b3, b2, b1; \
	}' > $@

size: $(OUT_DIR)/$(FW).elf
	@$(SIZE) $<
	@echo "max SRAM A = 512 B (code + data + bss + stack), Phase 0.9 layout"

dump: $(OUT_DIR)/$(FW).elf
	$(OBJDUMP) -d $< | less

clean:
	rm -rf $(OUT_DIR)
