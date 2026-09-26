PACKAGE_NAME := $(shell awk -F'"' '/^name = / { print $$2; exit }' Cargo.toml)
BIN := target/release/$(PACKAGE_NAME)
DEBUG_BIN := target/debug/$(PACKAGE_NAME)
INSTALL_BIN_DIR ?= $(HOME)/.local/bin

.PHONY: build build-debug check fmt lint test test-all test-services test-ignored validate install instal-debug uninstall clean

build:
	cargo build --release --offline

build-debug:
	cargo build --offline

$(INSTALL_BIN_DIR):
	mkdir -p "$@"

install: build $(INSTALL_BIN_DIR)
	install -m 755 "$(BIN)" "$(INSTALL_BIN_DIR)/$(PACKAGE_NAME)"
	@case ":$$PATH:" in \
		*":$(INSTALL_BIN_DIR):"*) ;; \
		*) printf '%s\n' \
			'Hint: $(INSTALL_BIN_DIR) is not in your PATH.' \
			'Add this to your shell profile:' \
			'  export PATH="$(INSTALL_BIN_DIR):$$PATH"' ;; \
	esac

instal-debug: build-debug $(INSTALL_BIN_DIR)
	install -m 755 "$(DEBUG_BIN)" "$(INSTALL_BIN_DIR)/$(PACKAGE_NAME)"

uninstall:
	rm -f "$(INSTALL_BIN_DIR)/$(PACKAGE_NAME)"

check:
	cargo check --offline --all-targets

fmt:
	cargo fmt --all -- --check

lint:
	cargo clippy --offline --all-targets -- -D warnings

test:
	cargo test --offline

test-services: build
	$(BIN) svc test

test-ignored: build
	cargo test --offline -- --ignored --test-threads=1

test-all: fmt lint test test-services

validate: build
	$(BIN) svc validate

clean:
	cargo clean
