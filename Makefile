PACKAGE_NAME := $(shell awk -F'"' '/^name = / { print $$2; exit }' Cargo.toml)
BIN := target/release/$(PACKAGE_NAME)
INSTALL_BIN_DIR ?= $(HOME)/.local/bin

.PHONY: build check fmt lint test test-all test-services test-ignored validate clean   

build:
	cargo build --release --offline

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
