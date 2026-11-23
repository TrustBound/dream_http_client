# dream_http_client Makefile

.PHONY: test build format check check-snippets docs clean

# Run the tests with line coverage (fails below 100%)
test:
	@gleam test

# Build the package
build:
	@gleam build

# Format code
format:
	@gleam format src test

# Format check, build, tests, docs snippet check and docs build (what CI runs)
check:
	@gleam format --check src test
	@gleam build
	@gleam test
	@$(MAKE) check-snippets
	@gleam docs build

# Check that every docs code block matches a tested snippet
check-snippets:
	@gleam run -m dream_snippets

# Generate documentation
docs:
	@gleam docs build

# Clean build artifacts
clean:
	@gleam clean
	@rm -f erl_crash.dump
