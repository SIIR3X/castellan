# Castellan - quality checks.
#
#   make check     run every quality check (the CI gate)
#   make <target>  run a single check (see `make help`)
#
# External tools are skipped (with a notice) when not installed locally, so you
# can run a subset; CI installs them all, so nothing is skipped there.

SHELL := /bin/bash

# Shell scripts to lint (harden has no extension but a bash shebang).
SHELL_FILES := harden \
               lib/castellan-config.sh \
               inventory/castellan-inventory.sh \
               packaging/build-deb.sh \
               packaging/publish-apt.sh \
               $(wildcard test/*.sh)

# Directories to ignore in the ASCII scan (build output, generated reports, vcs).
ASCII_EXCLUDES := --exclude-dir=.git --exclude-dir=dist --exclude-dir=reports

.PHONY: help check ascii syntax ansible shell actions secrets test

help:
	@echo "Castellan targets:"
	@echo "  make check     - run all quality checks (CI gate)"
	@echo "  make ascii     - fail on any non-ASCII byte"
	@echo "  make syntax    - ansible-playbook --syntax-check"
	@echo "  make ansible   - ansible-lint (production profile)"
	@echo "  make shell     - shellcheck on the bash scripts"
	@echo "  make actions   - actionlint on the GitHub workflows"
	@echo "  make secrets   - gitleaks (no committed secrets)"
	@echo "  make test      - full end-to-end cycle on the Hyper-V VM (test/e2e.sh)"

check: ascii syntax ansible shell actions secrets
	@echo "==> all quality checks passed"

# Full live cycle on the disposable Hyper-V VM: reset -> audit -> apply ->
# audit -> re-apply -> check.sh -> fresh login -> rollback -> reset. Needs the
# VM reachable and the CastellanVMReset task registered (see test/README.md).
# Pass-through flags: SKIP_RESET=1 (VM already clean), KEEP_VM=1 (no final reset).
test:
	@./test/e2e.sh

ascii:
	@if grep -rlP '[^\x00-\x7F]' $(ASCII_EXCLUDES) . ; then \
	  echo "ascii: non-ASCII bytes found in the files above" >&2; exit 1; \
	else echo "ascii: ok"; fi

syntax:
	@ansible-playbook playbooks/site.yml --syntax-check >/dev/null && echo "syntax: ok"

ansible:
	@ansible-lint

shell:
	@if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck -x --severity=warning $(SHELL_FILES) && echo "shell: ok"; \
	else echo "shell: skipped (shellcheck not installed)"; fi

actions:
	@if command -v actionlint >/dev/null 2>&1; then \
	  actionlint && echo "actions: ok"; \
	else echo "actions: skipped (actionlint not installed)"; fi

secrets:
	@if command -v gitleaks >/dev/null 2>&1; then \
	  gitleaks detect --no-banner --redact && echo "secrets: ok"; \
	else echo "secrets: skipped (gitleaks not installed)"; fi
