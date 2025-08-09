
# ===========================
# Project configuration
# ===========================

# Helpers
comma := ,

# Tools
HOSTCC          ?= gcc
RISCV_PREFIX    ?= riscv64-unknown-elf
RISCV_CC        := $(RISCV_PREFIX)-gcc
OBJCOPY         := $(RISCV_PREFIX)-objcopy

# Mentor/Questa commands (override if needed)
VLOG            ?= vlog
VSIM            ?= vsim
VLIB            ?= vlib
VMAP            ?= vmap

# ---------------------------
# Unicorn detection (robust)
# ---------------------------
# Option 1 (explicit): set UNICORN_ROOT to the install prefix
#   e.g. make UNICORN_ROOT=/usr/local/unicorn
UNICORN_ROOT ?=

# Option 2 (auto): try pkg-config only if it resolves to real files
PKG_INCLUDEDIR := $(shell pkg-config --variable=includedir unicorn 2>/dev/null)
PKG_LIBDIR     := $(shell pkg-config --variable=libdir     unicorn 2>/dev/null)
PKG_HAS_HDR    := $(if $(PKG_INCLUDEDIR),$(wildcard $(PKG_INCLUDEDIR)/unicorn/unicorn.h),)
PKG_HAS_LIB    := $(if $(PKG_LIBDIR),$(wildcard $(PKG_LIBDIR)/libunicorn.so*),)
PKG_VALID      := $(if $(and $(PKG_HAS_HDR),$(PKG_HAS_LIB)),yes,no)

# Option 3 (scan): common prefixes if pkg-config is unusable
UNICORN_PREFIXES ?= /usr/local/unicorn /usr/local /usr
SCAN_INCLUDEDIR  := $(firstword $(foreach p,$(UNICORN_PREFIXES),$(if $(wildcard $(p)/include/unicorn/unicorn.h),$(p)/include,)))
SCAN_LIBDIR      := $(firstword $(foreach p,$(UNICORN_PREFIXES),$(if $(wildcard $(p)/lib/libunicorn.so*),$(p)/lib,)))

# Choose source of truth in priority order
ifeq ($(strip $(UNICORN_ROOT)),)
  ifeq ($(PKG_VALID),yes)
    # pkg-config is valid
    UNICORN_CFLAGS := $(shell pkg-config --cflags unicorn)
    UNICORN_LIBS   := $(shell pkg-config --libs   unicorn)
    UNICORN_LIBDIRS := $(patsubst -L%,%,$(filter -L%,$(UNICORN_LIBS)))
    HOST_RPATH      := $(addprefix -Wl$(comma)-rpath$(comma),$(UNICORN_LIBDIRS))
    DETECT_SRC      := pkg-config
  else
    # fallback scan
    ifneq ($(strip $(SCAN_INCLUDEDIR)),)
      UNICORN_CFLAGS := -I$(SCAN_INCLUDEDIR)
    else
      UNICORN_CFLAGS := -I/usr/local/include
    endif
    ifneq ($(strip $(SCAN_LIBDIR)),)
      UNICORN_LIBS   := -L$(SCAN_LIBDIR) -lunicorn
      HOST_RPATH     := -Wl$(comma)-rpath$(comma)$(SCAN_LIBDIR)
    else
      UNICORN_LIBS   := -L/usr/local/lib -lunicorn
      HOST_RPATH     := -Wl$(comma)-rpath$(comma)/usr/local/lib
    endif
    DETECT_SRC      := prefix-scan
  endif
else
  # forced prefix
  UNICORN_CFLAGS := -I$(UNICORN_ROOT)/include
  UNICORN_LIBS   := -L$(UNICORN_ROOT)/lib -lunicorn
  HOST_RPATH     := -Wl$(comma)-rpath$(comma)$(UNICORN_ROOT)/lib
  DETECT_SRC     := forced($(UNICORN_ROOT))
endif

# Output directories
BUILD_DIR       := build
SIM_WORK_LIB    := work

# Sources
ISS_SRC         := iss_driver.c
FW_SRC          := fw.c
START_ASM       := _start.S
LD_SCRIPT       := linker.ld
TB_SV           := tb_iss_axil.sv

# Artifacts
ISS_SO          := $(BUILD_DIR)/libiss.so
FW_ELF          := $(BUILD_DIR)/fw.elf
FW_BIN          := $(BUILD_DIR)/fw.bin

# RISC-V firmware flags
FW_CFLAGS       := -O0 -g -ffreestanding -nostdlib -march=rv32im -mabi=ilp32
FW_LDFLAGS      := -T $(LD_SCRIPT) -Wl,--gc-sections

# Host build flags for DPI/ISS
HOST_CFLAGS     := -fPIC -shared -O2 -Wall -Wextra $(UNICORN_CFLAGS)
HOST_LDFLAGS    := $(UNICORN_LIBS) $(HOST_RPATH)

# Extract primary include dir from UNICORN_CFLAGS (first -I…)
INC_DIRS        := $(patsubst -I%,%,$(filter -I%,$(UNICORN_CFLAGS)))
PRIMARY_INC     := $(firstword $(INC_DIRS))

# ===========================
# Phony targets
# ===========================
.PHONY: all run sim clean reallyclean env firmware iss sv check_unicorn

all: dirs $(ISS_SO) $(FW_BIN)

dirs:
	@mkdir -p $(BUILD_DIR)

# ===========================
# Build rules
# ===========================

# 1) Unicorn + DPI driver -> shared library
$(ISS_SO): $(ISS_SRC) | dirs check_unicorn
	$(HOSTCC) $(HOST_CFLAGS) -o $@ $< $(HOST_LDFLAGS)

# 2) Firmware -> ELF -> BIN (RISC-V)
$(FW_ELF): $(FW_SRC) $(START_ASM) $(LD_SCRIPT) | dirs
	$(RISCV_CC) $(FW_CFLAGS) $(FW_LDFLAGS) $(START_ASM) $(FW_SRC) -o $@

$(FW_BIN): $(FW_ELF)
	$(OBJCOPY) -O binary $< $@

firmware: $(FW_BIN)
iss:      $(ISS_SO)

# 3) Compile SV and run simulation
sv:
	@mkdir -p $(BUILD_DIR)
	cd $(BUILD_DIR) && \
	    $(VLIB) work && \
	    $(VMAP) work work && \
	    $(VLOG) -sv ../$(TB_SV)

sim: all sv
	cd $(BUILD_DIR) && \
	$(VSIM) -c tb -sv_lib libiss -do "run -all; quit"

run: sim

# Sanity checks (fail fast with helpful message)
check_unicorn:
	@if [ -z "$(PRIMARY_INC)" ] || [ ! -f "$(PRIMARY_INC)/unicorn/unicorn.h" ]; then \
	  echo "ERROR: Could not find unicorn/unicorn.h"; \
	  echo "  UNICORN_CFLAGS = $(UNICORN_CFLAGS)"; \
	  echo "  Searched: $(PRIMARY_INC)/unicorn/unicorn.h"; \
	  echo "Fixes:"; \
	  echo "  1) If you installed to a custom prefix, run:  make UNICORN_ROOT=/path/to/unicorn"; \
	  echo "     (expects headers at \$$UNICORN_ROOT/include/unicorn/unicorn.h)"; \
	  echo "  2) Or export PKG_CONFIG_PATH=<prefix>/lib/pkgconfig so pkg-config finds the right one."; \
	  exit 1; \
	fi

# Environment diagnostic
env:
	@echo "DETECT_SRC        = $(DETECT_SRC)"
	@echo "UNICORN_ROOT      = $(UNICORN_ROOT)"
	@echo "UNICORN_CFLAGS    = $(UNICORN_CFLAGS)"
	@echo "UNICORN_LIBS      = $(UNICORN_LIBS)"
	@echo "HOST_RPATH        = $(HOST_RPATH)"
	@echo "PRIMARY_INC       = $(PRIMARY_INC)"
	@echo "RISCV_PREFIX      = $(RISCV_PREFIX)"
	@echo "RISCV_CC          = $(RISCV_CC)"
	@echo "OBJCOPY           = $(OBJCOPY)"
	@echo "START_ASM         = $(START_ASM)"
	@echo "LD_SCRIPT         = $(LD_SCRIPT)"

clean:
	@rm -f $(ISS_SO) $(FW_ELF) $(FW_BIN)
	@rm -f transcript vsim.wlf
	@rm -rf $(SIM_WORK_LIB)

reallyclean: clean
	@rm -rf $(BUILD_DIR)
