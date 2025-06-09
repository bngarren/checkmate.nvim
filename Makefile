.PHONY: test test-file test-interactive clean

FILE ?= $(f)
TEST ?= $(t)

BASENAME := $(basename $(notdir $(FILE)))

#    - If FILE is empty, leave FILE_PATH empty.
#    - Else if FILE contains “/”, assume it’s already a path.
#    - Otherwise, search under tests/ for the first match.
ifeq ($(strip $(FILE)),)
  FILE_PATH :=
else
  FILE_PATH := $(shell \
    find tests -type f -iname "*$(BASENAME)*.lua" 2>/dev/null | head -n 1 \
  )
endif

#    If we found a FILE_PATH, use it; otherwise default to tests/checkmate.
ROOT := $(if $(FILE_PATH),$(FILE_PATH),tests/checkmate)

FILTER_ARG := $(if $(TEST),--filter='$(TEST)',)

# -------------------------------------------------
# Primary “test” target
#
# Usage examples:
#
#   # Run everything:
#   make test
#
#   # Run a single spec by basename:
#   make test FILE=parser_spec.lua
#   # same as:
#   make test f=parser_spec.lua
#
#   # Run everything, but only tests whose names contain “Foo”:
#   make test TEST="Foo"
#   # same as:
#   make test t="Foo"
#
#   # Combine: if you know which file, and also filter inside it:
#   make test f=parser_spec.lua TEST="invalid input"
#
#   # You can still append arbitrary busted flags via ARGS:
#   make test ARGS="--tags=unit"
# -------------------------------------------------
test:
	@echo 'Running tests$(if $(FILE_PATH), (file=$(FILE_PATH)))$(if $(TEST), (test=$(TEST)))…'
	@# If FILE_PATH is empty, busted runs the entire tests/checkmate tree. 
	@nvim -l tests/busted.lua \
	     $(ROOT) \
	     -o tests/custom_reporter -Xoutput color \
	     $(FILTER_ARG) \
	     $(ARGS)

# -------------------------------------------------
# (Optional) “test-file” target if you still want to force a single-file invocation:
#
#   make test-file FILE=tests/specs/parser_spec.lua
#
#   This one does NOT do the “basename lookup” logic – it just uses FILE verbatim.
# -------------------------------------------------
test-file:
	@echo 'Running single test file: $(FILE)'
	@nvim -l tests/busted.lua $(FILE) \
	     -o tests/custom_reporter -Xoutput color \
	     $(ARGS)

# -------------------------------------------------
#   make test-interactive
# -------------------------------------------------
test-interactive:
	@nvim -u tests/interactive.lua

# -------------------------------------------------
# Clean up any test artifacts
# -------------------------------------------------
clean:
	@rm -rf .testdata
