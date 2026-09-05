ODIN      ?= odin
BUILD_DIR := build
ODINFLAGS := -disallow-do -warnings-as-errors -vet-style -vet-shadowing

# MODE selects whether the debug scaffolding is compiled in. `make debug` and
# `make release` just re-invoke this file with MODE set; MODE can also be passed
# directly, e.g. `make MODE=release test`.
MODE ?= debug

ifeq ($(MODE),release)
MODEFLAGS := -o:speed -define:DEBUG=false
else ifeq ($(MODE),debug)
MODEFLAGS := -debug -define:DEBUG=true
else
$(error MODE must be 'debug' or 'release', got '$(MODE)')
endif

MO8_SRC := $(shell find src -name '*.odin')
ASM_SRC := $(shell find src/assembler src/debug -name '*.odin')

.DEFAULT_GOAL := build
.PHONY: build debug release test clean help FORCE

build: $(BUILD_DIR)/MO8.bin $(BUILD_DIR)/assembler.bin

debug:
	@$(MAKE) --no-print-directory MODE=debug build

release:
	@$(MAKE) --no-print-directory MODE=release build

# NOTE: the phony target `build` and the output directory `build` share a name,
# so the directory cannot be an order-only prerequisite without creating a
# dependency cycle. Each recipe makes the directory itself instead.
$(BUILD_DIR)/MO8.bin: $(MO8_SRC) $(BUILD_DIR)/.mode
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build src -out:$@ $(ODINFLAGS) $(MODEFLAGS)

$(BUILD_DIR)/assembler.bin: $(ASM_SRC) $(BUILD_DIR)/.mode
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build src/assembler -out:$@ $(ODINFLAGS) $(MODEFLAGS)

# Records the mode the tree was last built in. The recipe only rewrites the file
# when the mode actually changed, so switching modes forces a rebuild while
# repeated builds in the same mode stay incremental.
$(BUILD_DIR)/.mode: FORCE
	@mkdir -p $(BUILD_DIR)
	@[ "$$(cat $@ 2>/dev/null)" = "$(MODE)" ] || echo "$(MODE)" > $@

# The suite is parallel-safe: every test builds its own Machine, so the runner
# is left to pick its own thread count. Pass THREADS=1 to serialise a run when
# debugging a failure.
THREADS ?=
test:
	@mkdir -p $(BUILD_DIR)
	$(ODIN) test tests -out:$(BUILD_DIR)/tests.bin $(ODINFLAGS) $(MODEFLAGS) \
		$(if $(THREADS),-define:ODIN_TEST_THREADS=$(THREADS),)

FORCE:

clean:
	rm -rf $(BUILD_DIR)

help:
	@echo "usage: make [target] [MODE=debug|release]"
	@echo "    build   - builds the project in MODE (default: debug)"
	@echo "    debug   - builds with debug output compiled in"
	@echo "    release - builds optimised, with all debug output stripped"
	@echo "    test    - runs the test suite (THREADS=1 to serialise it)"
	@echo "    clean   - removes the build directory"
	@echo "    help    - display this help message"
