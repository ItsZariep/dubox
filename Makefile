# dubox: no dub needed, just a D compiler with a DMD-compatible CLI.
#
#   make                 release build: bin/yes bin/ls bin/rm + multicall bin/dubox
#   make MODE=debug      keep asserts / bounds checks everywhere, with debug info
#   make links           bin/multicall/{yes,ls,rm} -> ../dubox  (argv[0] dispatch)
#   make test            build, then run tests/smoke.sh
#   make DC=dmd          use DMD instead of LDC
#
# All tools are built with -betterC (no druntime startup, no GC). Bounds checks
# stay ON in @safe code even in release mode (that is D's default for -release).

DC    ?= ldmd2
BIN   := bin
TOOLSRC := $(wildcard source/tools/*.d)
# TOOLS := yes ls rm
TOOLS := $(notdir $(basename $(TOOLSRC)))
MODE  ?= release

COMMON  := $(wildcard source/common/*.d)
TOOLSRC := $(wildcard source/tools/*.d)

ifeq ($(MODE),debug)
  FLAGS := -g -debug -betterC -Isource
else
  FLAGS := -O -release -inline -betterC -Isource
endif

.PHONY: all links test clean
all: $(addprefix $(BIN)/,$(TOOLS)) $(BIN)/dubox

# One standalone binary per tool: tool source + shared common/ modules.
$(BIN)/%: source/tools/%.d $(COMMON) | $(BIN)
	$(DC) $(FLAGS) -of=$@ $< $(COMMON)

# The multicall binary: every tool + dispatcher + common/.
$(BIN)/dubox: source/multicall.d $(TOOLSRC) $(COMMON) | $(BIN)
	$(DC) $(FLAGS) -version=Multicall -of=$@ $^

$(BIN):
	mkdir -p $(BIN)

links: $(BIN)/dubox
	mkdir -p $(BIN)/multicall
	for t in $(TOOLS); do ln -sf ../dubox $(BIN)/multicall/$$t; done

test: all links
	bash tests/smoke.sh

clean:
	rm -rf $(BIN) *.o
