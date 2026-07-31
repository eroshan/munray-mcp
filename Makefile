BIN := target/release/luaris-mcp
SERVICE_DIR := $(CURDIR)/services
INSTALL_BIN_DIR ?= $(HOME)/.local/bin
LUARIS_MCP_HOME ?= $(HOME)/.local/share/luaris-mcp
INSTALLED_SERVICES := $(LUARIS_MCP_HOME)/services

.PHONY: build check fmt lint test test-all test-services test-ignored validate run mcp stats clean install uninstall services-install services-clean

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
	$(BIN) --svc-dir $(SERVICE_DIR) test

test-ignored: build
	cargo test --offline -- --ignored --test-threads=1

test-all: fmt lint test test-services

validate: build
	$(BIN) --svc-dir $(SERVICE_DIR) validate

run: build
	$(BIN)

mcp: build
	$(BIN) mcp

stats: build
	$(BIN) stats

clean:
	cargo clean

install: build
	install -d $(INSTALL_BIN_DIR)
	install -m 0755 $(BIN) $(INSTALL_BIN_DIR)/luaris-mcp

uninstall:
	rm -f $(INSTALL_BIN_DIR)/luaris-mcp

services-install:
	@mkdir -p $(INSTALLED_SERVICES)
	@for service in compass confluence gcloud gitlab jira terraform; do \
		if [ -e "$(INSTALLED_SERVICES)/$$service" ] || [ -L "$(INSTALLED_SERVICES)/$$service" ]; then \
			echo "  ! $$service already exists"; \
		else \
			ln -s "$(SERVICE_DIR)/$$service" "$(INSTALLED_SERVICES)/$$service"; \
			echo "  + $$service"; \
		fi; \
	done

services-clean:
	@for service in compass confluence gcloud gitlab jira terraform; do \
		if [ -L "$(INSTALLED_SERVICES)/$$service" ]; then \
			rm "$(INSTALLED_SERVICES)/$$service"; \
			echo "  - $$service"; \
		fi; \
	done
