# CI Lint Prevention Checks

## Overview

Add two automated CI checks that prevent the classes of bugs fixed in the `pipe-fix` branch from ever merging again:

1. **Wrong `ANSIBLE_ROLES_PATH` depth** — all 4 `molecule.yml` files had `../../roles` instead of `../../../../roles`. Tests ran in CI but failed. A path validator script will catch this at PR time.
2. **`get_url` tasks without retry logic** — WAL-G binary download had no retries, making it fragile against transient network errors. A custom ansible-lint rule will enforce retry presence on all external download tasks.

Both checks run in a new `lint` CI job that gates the existing `molecule` jobs.

## Context (from discovery)

- **Affected files (path bug):** `roles/firewall/molecule/default/molecule.yml`, `roles/pgbouncer/molecule/default/molecule.yml`, `roles/postgres/molecule/default/molecule.yml`, `roles/walg/molecule/default/molecule.yml`, `molecule/integration/molecule.yml`
- **Affected files (retry bug — existing violations the rule will catch):**
  - `roles/walg/tasks/main.yml` — WAL-G binary download (fixed in pipe-fix)
  - `roles/postgres/tasks/main.yml:18` — PGDG GPG key download, no retries
  - `roles/pgbouncer/tasks/main.yml:18` — PGDG GPG key download, no retries
  - `roles/postgres/molecule/default/prepare.yml:26` — PGDG GPG key download, no retries
  - `roles/pgbouncer/molecule/default/prepare.yml:26` — PGDG GPG key download, no retries
  - `roles/walg/molecule/default/prepare.yml:26` — PGDG GPG key download, no retries
  - `molecule/integration/prepare.yml:17` — PGDG GPG key download, no retries
- **CI:** `.github/workflows/ci.yml` — matrix of molecule scenarios, no existing lint job
- **Lint config:** `.ansible-lint` at repo root — no `rulesdir` set, no custom rules yet
- **Existing:** `scripts/` directory already contains `walg-restore.sh`, `walg-wal-fetch.sh`
- **No existing:** `.ansible-lint-rules/` directory

## Development Approach

- **Testing approach:** Regular (code first, then tests/verification)
- Complete each task fully before moving to the next
- Make small, focused changes
- Every task must include verification that the new check actually catches the bug it's meant to prevent

## Testing Strategy

- **Path validator:** verified by running it against the repo (should pass after fix) and by temporarily introducing a wrong path and confirming it fails
- **ansible-lint rule:** verified by running `ansible-lint` against the fixed `walg/tasks/main.yml` (should pass) and a synthetic task without `retries` (should fail)
- **CI job:** verified by inspecting the YAML — no live CI run required before merge

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview

- `scripts/check_molecule_roles_path.py` — Python script (requires PyYAML, available via ansible) that walks the repo, finds every `molecule.yml`, computes the correct `ANSIBLE_ROLES_PATH` for each file's location using two known patterns, and fails with a clear message on mismatch or unknown pattern
- `.ansible-lint-rules/get_url_retries.py` — custom ansible-lint rule (`LOCAL001`) that flags any `get_url` task missing `retries`
- `.ansible-lint` updated with `rulesdir: [.ansible-lint-rules]`
- `.github/workflows/ci.yml` updated with a `lint` job; `molecule` jobs gain `needs: lint`

## What Goes Where

- **Implementation Steps** — all code lives in this repo, all verifiable locally
- **Post-Completion** — no external systems; CI will validate on next PR

## Implementation Steps

### Task 1: Path validator script

**Files:**
- Create: `scripts/check_molecule_roles_path.py`

- [x] create `scripts/check_molecule_roles_path.py` (note: `scripts/` dir already exists)
- [x] walk repo from root, collect all `molecule.yml` paths
- [x] for each file match against exactly two known patterns:
  - `roles/<name>/molecule/<scenario>/molecule.yml` → expected `../../../../roles`
  - `molecule/<scenario>/molecule.yml` → expected `../../roles`
  - any other pattern → fail loudly with "unknown molecule.yml location pattern"
- [x] read declared value from `provisioner.env.ANSIBLE_ROLES_PATH` in each `molecule.yml`
- [x] print PASS/FAIL per file; exit 1 if any mismatch or unknown pattern
- [x] verify: run `python scripts/check_molecule_roles_path.py` — must exit 0 on current repo state
- [x] verify: temporarily set one path to `../../roles`, re-run — must exit 1 with clear error, then revert

### Task 2: Fix existing get_url tasks missing retries

**Files:**
- Modify: `roles/postgres/tasks/main.yml`
- Modify: `roles/pgbouncer/tasks/main.yml`
- Modify: `roles/postgres/molecule/default/prepare.yml`
- Modify: `roles/pgbouncer/molecule/default/prepare.yml`
- Modify: `roles/walg/molecule/default/prepare.yml`
- Modify: `molecule/integration/prepare.yml`

All are PGDG GPG key downloads from `postgresql.org` — external HTTP calls that can fail transiently.

- [x] add `register`, `retries: 3`, `delay: 5`, `until: <result> is not failed` to `get_url` task in `roles/postgres/tasks/main.yml`
- [x] same for `roles/pgbouncer/tasks/main.yml`
- [x] same for `roles/postgres/molecule/default/prepare.yml`
- [x] same for `roles/pgbouncer/molecule/default/prepare.yml`
- [x] same for `roles/walg/molecule/default/prepare.yml`
- [x] same for `molecule/integration/prepare.yml`

### Task 3: ansible-lint custom rule for get_url retries

**Files:**
- Create: `.ansible-lint-rules/get_url_retries.py`
- Modify: `.ansible-lint`

- [x] create `.ansible-lint-rules/` directory
- [x] implement `get_url_retries.py` as an ansible-lint `AnsibleLintRule` subclass:
  - Rule ID: `LOCAL001`
  - description: `"External download task is missing retries — transient failures will abort the play"`
  - match tasks where module is `ansible.builtin.get_url` or `get_url`
  - violation if `retries` not present at task level
- [x] add `rulesdir: [.ansible-lint-rules]` to `.ansible-lint`
- [x] verify: run `ansible-lint` across all roles — must pass with no `LOCAL001` violations (Task 2 fixed all existing ones)
- [x] verify: create a temp task file with a bare `get_url` (no retries), run `ansible-lint` on it — must report `LOCAL001`, then remove temp file

### Task 4: CI lint job

**Files:**
- Modify: `.github/workflows/ci.yml`

- [x] add `lint` job before the `molecule` job:
  - `runs-on: ubuntu-24.04`
  - steps: checkout, python 3.12, `pip install ansible ansible-lint` (PyYAML comes with ansible, needed by path validator), `ansible-galaxy collection install -r requirements.yml` (needed so ansible-lint can resolve FQCNs from collections), `python scripts/check_molecule_roles_path.py`, `ansible-lint`
- [x] add `needs: lint` to the `molecule` job so it only runs after lint passes
- [x] verify: YAML is valid (`python -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"`)

### Task 5: Verify acceptance criteria

- [ ] run `python scripts/check_molecule_roles_path.py` — exits 0
- [ ] run `ansible-lint` — no `LOCAL001` violations
- [ ] confirm CI YAML parses cleanly
- [ ] confirm `molecule` job has `needs: lint`

### Task 6: [Final] Wrap up

- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification:**
- Push branch and confirm the new `lint` job appears and passes in GitHub Actions before `molecule` jobs start
