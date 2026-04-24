# Fix Failing Molecule Tests and Add Local Test Runner

## Overview

Four Molecule test jobs fail on every CI push. All failures have exact known root causes identified from GitHub Actions logs. This plan fixes them and adds a `Makefile` so tests can be run locally before pushing.

- **Problem**: 3 bugs in test/role files cause firewall verify, postgres verify, walg converge, and integration converge to fail
- **Key benefit**: Green CI, plus a local runner to catch failures before push

## Context (from discovery)

- **Files involved**:
  - `roles/firewall/molecule/default/verify.yml` — 3x regex_search boolean type error
  - `roles/postgres/molecule/default/verify.yml` — pg_version int-vs-string + 2x regex_search boolean
  - `molecule/integration/verify.yml` — 4x regex_search boolean type error (same pattern)
  - `roles/walg/defaults/main.yml` — wrong WAL-G binary filename (404)
  - `playbooks/restore.yml` — 1x regex_search boolean (production code, same root cause)
  - `Makefile` (new) — local test runner
- **Related patterns**: pgbouncer molecule tests pass and serve as reference
- **Dependencies**: regex_search boolean bug affects 9 assertions across 4 files; walg fix cascades to integration automatically

## Development Approach

- **Testing approach**: Regular (fixes are targeted, tests already exist)
- Complete each task fully before moving to the next
- Each fix is a single-line or small change — verify locally after each

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix
- Document issues/blockers with ⚠️ prefix

## Solution Overview

Three independent bug fixes + one new file:

1. **regex_search boolean** — `regex_search()` returns `str|None`, not `bool`. Newer Ansible requires explicit boolean in `assert.that`. Affects 9 assertions across 3 test files + 1 production playbook.
2. **Postgres pg_version type** — `pg_version: 17` is an integer. Use `pg_version | string` in the `in` check.
3. **WAL-G binary name** — Wrong `ubuntu-` prefix. Actual v3.0.8 asset: `wal-g-pg-24.04-amd64`.
4. **Makefile** — Per-role targets + `test-all` + `lint` + `help`, matching CI env vars.

## Implementation Steps

---

### Task 1: Fix firewall verify.yml — regex_search boolean error

**Files:**
- Modify: `roles/firewall/molecule/default/verify.yml`

Root cause: `regex_search()` returns the matched string (truthy) or `None` (falsy), but newer Ansible requires explicit boolean in `assert.that`. A non-None string passes silently as `True` type `str`, causing the error.

- [x] Change `Assert port 6432 is allowed from private subnet` assertion:
  ```yaml
  # before
  - "ufw_status.stdout | regex_search('6432.*10\\.0\\.0\\.0/24|10\\.0\\.0\\.0/24.*6432')"
  # after
  - "(ufw_status.stdout | regex_search('6432.*10\\.0\\.0\\.0/24|10\\.0\\.0\\.0/24.*6432')) is not none"
  ```
- [x] Change `Assert SSH (port 22) is allowed` assertion:
  ```yaml
  # before
  - "ufw_status.stdout | regex_search('(22|OpenSSH).*ALLOW')"
  # after
  - "(ufw_status.stdout | regex_search('(22|OpenSSH).*ALLOW')) is not none"
  ```
- [x] Change `Assert port 5432 is not in ALLOW rules` assertion:
  ```yaml
  # before
  - not (ufw_status.stdout | regex_search('5432.*ALLOW'))
  # after
  - (ufw_status.stdout | regex_search('5432.*ALLOW')) is none
  ```

---

### Task 2: Fix postgres verify.yml — integer vs string + regex_search boolean errors

**Files:**
- Modify: `roles/postgres/molecule/default/verify.yml`

- [x] Fix `Assert PostgreSQL {{ pg_version }}` — `pg_version: 17` is an integer, causes `_AnsibleTaggedInt` error:
  ```yaml
  # before
  - "'{{ pg_version }}' in pg_version_output.stdout"
  # after
  - "(pg_version | string) in pg_version_output.stdout"
  ```
- [x] Fix `Assert port 5432 is NOT bound to 0.0.0.0` (line 32) — bare regex_search:
  ```yaml
  # before
  - not (ss_output.stdout | regex_search('0\\.0\\.0\\.0:5432'))
  # after
  - (ss_output.stdout | regex_search('0\\.0\\.0\\.0:5432')) is none
  ```
- [x] Fix `Assert listen_addresses is localhost` (line 95) — bare regex_search:
  ```yaml
  # before
  - "pg_conf_content.content | b64decode | regex_search(\"listen_addresses\\\\s*=\\\\s*'localhost'\")"
  # after
  - "(pg_conf_content.content | b64decode | regex_search(\"listen_addresses\\\\s*=\\\\s*'localhost'\")) is not none"
  ```

---

### Task 3: Fix integration verify.yml — regex_search boolean errors

**Files:**
- Modify: `molecule/integration/verify.yml`

Same root cause as Task 1 — integration scenario has its own copy of these assertions.

- [x] Fix line 38 — `Assert port 5432 is NOT bound to 0.0.0.0`:
  ```yaml
  # before
  - not (ss_output.stdout | regex_search('0\\.0\\.0\\.0:5432'))
  # after
  - (ss_output.stdout | regex_search('0\\.0\\.0\\.0:5432')) is none
  ```
- [x] Fix line 197 — `Assert port 6432 is allowed from private subnet`:
  ```yaml
  # before
  - "ufw_status.stdout | regex_search('6432.*10\\.0\\.0\\.0/24|10\\.0\\.0\\.0/24.*6432')"
  # after
  - "(ufw_status.stdout | regex_search('6432.*10\\.0\\.0\\.0/24|10\\.0\\.0\\.0/24.*6432')) is not none"
  ```
- [x] Fix line 203 — `Assert SSH (port 22) is allowed`:
  ```yaml
  # before
  - "ufw_status.stdout | regex_search('(22|OpenSSH).*ALLOW')"
  # after
  - "(ufw_status.stdout | regex_search('(22|OpenSSH).*ALLOW')) is not none"
  ```
- [x] Fix line 209 — `Assert port 5432 is not in ALLOW rules`:
  ```yaml
  # before
  - not (ufw_status.stdout | regex_search('5432.*ALLOW'))
  # after
  - (ufw_status.stdout | regex_search('5432.*ALLOW')) is none
  ```

---

### Task 4: Fix WAL-G binary filename — 404 on download

**Files:**
- Modify: `roles/walg/defaults/main.yml`

Root cause: WAL-G v3.0.8 release assets use `wal-g-pg-24.04-amd64` naming (no `ubuntu-` prefix). The configured name `wal-g-pg-ubuntu-24.04-amd64` returns HTTP 404 after 3 retries. Integration scenario inherits same failure.

- [x] Change `walg_binary_name` default value:
  ```yaml
  # before
  walg_binary_name: "wal-g-pg-ubuntu-24.04-amd64"
  # after
  walg_binary_name: "wal-g-pg-24.04-amd64"
  ```
- [x] Update inline comments for 22.04 and 20.04 examples to match correct naming (remove `ubuntu-` prefix from comments)

---

### Task 5: Fix restore.yml — regex_search boolean in production playbook

**Files:**
- Modify: `playbooks/restore.yml`

Same root cause. Line 38 validates `restore_time` format but will raise a type error on newer Ansible.

- [x] Fix line 38 — date format validation assertion:
  ```yaml
  # before
  - restore_time | regex_search('^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$')
  # after
  - (restore_time | regex_search('^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$')) is not none
  ```

---

### Task 6: Add Makefile local test runner

**Files:**
- Create: `Makefile`

Each per-role target `cd`s into the role directory so molecule picks up the local `molecule.yml` (which already sets `ANSIBLE_ROLES_PATH` via `provisioner.env`). Integration target runs from project root.

- [x] Create `Makefile` with `.PHONY` declarations and `help` target (auto-generated from `##` comments)
- [x] Add `test-firewall` target: `cd roles/firewall && molecule test`
- [x] Add `test-postgres` target: `cd roles/postgres && molecule test`
- [x] Add `test-pgbouncer` target: `cd roles/pgbouncer && molecule test`
- [x] Add `test-walg` target: `cd roles/walg && molecule test`
- [x] Add `test-integration` target: `molecule test -s integration` (runs from project root)
- [x] Add `test-all` target: runs `test-firewall`, `test-postgres`, `test-pgbouncer`, `test-walg`, then `test-integration` in sequence
- [x] Add `lint` target: `yamllint . && ansible-lint`
- [x] Export `ANSIBLE_FORCE_COLOR=1` and `PY_COLORS=1` to match CI output

---

### Task 7: Verify all fixes

- [ ] Run `make test-firewall` — must pass (verify step must complete green)
- [ ] Run `make test-postgres` — must pass (verify step must complete green)
- [ ] Run `make test-walg` — must pass (converge + verify must complete green)
- [ ] Run `make test-pgbouncer` — must still pass (regression check)
- [ ] Run `make test-integration` — must pass (converge + verify must complete green)

---

### Task 8: [Final] Update documentation

- [ ] Update `README.md` to mention `make test-<role>` and `make test-all` for local testing
- [ ] Move this plan to `docs/plans/completed/`

## Post-Completion

**Push and verify CI**: after merging, confirm all 5 Molecule jobs are green in GitHub Actions at https://github.com/tutunak/infra-pg/actions
