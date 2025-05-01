.PHONY: test test-file test-interactive clean

# Run all tests
test:
	nvim -l tests/busted.lua tests/checkmate -o tests/custom_reporter -Xoutput color

# Run a specific test file
# Usage: make test-file FILE=tests/specs/parser_spec.lua
test-file:
	nvim -l tests/busted.lua $(FILE) tests/custom_reporter --color

# Enter test environment for interactive testing
test-interactive:
	nvim -u tests/busted.lua

# Clean test data
clean:
	rm -rf .testdata
