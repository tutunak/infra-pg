export ANSIBLE_FORCE_COLOR=1
export PY_COLORS=1

.PHONY: help test-firewall test-postgres test-pgbouncer test-walg test-integration test-all lint

help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "%-20s %s\n", $$1, $$2}'

test-firewall: ## Run molecule tests for the firewall role
	cd roles/firewall && molecule test

test-postgres: ## Run molecule tests for the postgres role
	cd roles/postgres && molecule test

test-pgbouncer: ## Run molecule tests for the pgbouncer role
	cd roles/pgbouncer && molecule test

test-walg: ## Run molecule tests for the walg role
	cd roles/walg && molecule test

test-integration: ## Run integration molecule tests from project root
	molecule test -s integration

test-all: test-firewall test-postgres test-pgbouncer test-walg test-integration ## Run all molecule tests in sequence

lint: ## Run yamllint and ansible-lint
	yamllint . && ansible-lint
