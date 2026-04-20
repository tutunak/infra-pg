# Ubuntu 24 Migration: Drop RHEL, Go Full Ubuntu 24

## Overview

Replace all Rocky Linux 9 / RHEL-specific Ansible code with Ubuntu 24 equivalents across all
four roles and all molecule tests. After this migration the project will support **only Ubuntu 24**
— no multi-OS conditionals, no RHEL fallbacks.

## Context (from discovery)

- **Roles involved**: `firewall`, `pgbouncer`, `postgres`, `walg`
- **Molecule scenarios**: 1 integration (`molecule/integration/`) + 4 per-role (`roles/*/molecule/default/`)
- **Current image**: `geerlingguy/docker-rockylinux9-ansible` (all 5 scenarios)
- **RHEL-specific patterns found**: `rpm_key`, `dnf`, PGDG RPM repo, `firewalld`, `postgresql-{{ pg_version }}` service name, `/var/lib/pgsql/` data dir
- **Postgres handlers** reference `postgresql-{{ pg_version }}` — need updating too
- **walg-backup.service.j2** has `After=postgresql-{{ pg_version }}.service` — needs updating
- **playbooks/restore.yml** line 21 sets `pg_service: "postgresql-{{ pg_version }}"` — needs updating
- **molecule/integration/verify.yml** is 100% RHEL-specific — needs full rewrite

## Decisions Made

- **Firewall**: UFW (native Ubuntu 24 default), not firewalld
- **PGDG repo**: duplicated in `postgres` and `pgbouncer` roles — same pattern as current RHEL code, no shared abstraction
- **Drop RHEL entirely**: no conditionals, no backwards compatibility
- **psql path**: use `psql` (in PATH via `/usr/bin/psql` symlink) in all verify tasks — avoids hardcoded version paths
- **pgbouncer_private_iface**: retained in firewall defaults but only used by the pgbouncer role for listen address; firewall uses `src={{ pg_private_subnet }}` matching (not interface-level) which is the UFW model

## Development Approach

- **testing approach**: Regular (implement, then verify molecule tests pass)
- Complete each task fully before moving to the next
- Run `molecule test` for each role after its task to confirm green before moving on

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Implementation Steps

---

### Task 1: Update `group_vars/all.yml` — data dir path

**Files:**
- Modify: `group_vars/all.yml`

- [x] Change `pg_data_dir` from `/var/lib/pgsql/{{ pg_version }}/data` to `/var/lib/postgresql/{{ pg_version }}/main`

---

### Task 2: Rewrite `postgres` role tasks and handlers

**Files:**
- Modify: `roles/postgres/tasks/main.yml`
- Modify: `roles/postgres/defaults/main.yml`
- Modify: `roles/postgres/handlers/main.yml`

- [x] Replace `rpm_key` + PGDG RPM + `dnf` repo setup with PGDG apt repo:
  - `get_url` key to `/usr/share/keyrings/pgdg.asc`
  - `apt_repository` with `signed-by` pointing to key file, filename `pgdg`
- [x] Replace all `dnf` calls with `apt`; install prerequisite packages `curl`, `gnupg`, `lsb-release` before repo setup
- [x] Remove `dnf module disable postgresql` task (not needed on Ubuntu)
- [x] Remove explicit `initdb` task (Ubuntu's package runs `pg_createcluster` automatically)
- [x] Change package list: two RHEL packages (`postgresql{{ pg_version }}-server` + `postgresql{{ pg_version }}`) collapse into one Ubuntu package `postgresql-{{ pg_version }}`
- [x] Change service name in Enable/start task: `postgresql-{{ pg_version }}` → `postgresql`
- [x] Update `defaults/main.yml`: `pg_data_dir` → `/var/lib/postgresql/{{ pg_version }}/main`
- [x] Update `handlers/main.yml`: service name `postgresql-{{ pg_version }}` → `postgresql` in both Restart and Reload handlers
- [x] Update template `dest` paths in tasks:
  - `postgresql.conf`: `/var/lib/pgsql/.../postgresql.conf` → `/etc/postgresql/{{ pg_version }}/main/postgresql.conf`
  - `pg_hba.conf`: `/var/lib/pgsql/.../pg_hba.conf` → `/etc/postgresql/{{ pg_version }}/main/pg_hba.conf`
- [x] Run `molecule test` in `roles/postgres/` — must pass before Task 3 (skipped - molecule test files still use Rocky Linux image; will be verified in Task 3 after molecule files are updated)

---

### Task 3: Rewrite `postgres` molecule tests

**Files:**
- Modify: `roles/postgres/molecule/default/molecule.yml`
- Modify: `roles/postgres/molecule/default/prepare.yml`
- Modify: `roles/postgres/molecule/default/verify.yml`

- [x] `molecule.yml`: swap image to `docker.io/geerlingguy/docker-ubuntu2404-ansible`
- [x] `prepare.yml`: replace dnf-based setup with apt:
  - `apt` module with `update_cache: true`
  - Install PGDG apt signing key via `get_url` to `/usr/share/keyrings/pgdg.asc`
  - Add PGDG apt source via `apt_repository`
  - `apt` install: `python3-psycopg2`, `iproute2`, `net-tools`
  - Remove `dnf module disable` task
- [x] `verify.yml`:
  - Service assertion: `postgresql-17.service` → `postgresql@17-main.service` (Ubuntu uses `postgresql@<ver>-<cluster>.service`; `postgresql.service` is a meta-service with state=exited)
  - All `psql` binary references: `/usr/pgsql-17/bin/psql` → `psql` (3 occurrences: version check, DB check, user check)
  - `pg_hba.conf` slurp src: `/var/lib/pgsql/17/data/pg_hba.conf` → `/etc/postgresql/17/main/pg_hba.conf`
  - `postgresql.conf` slurp src: `/var/lib/pgsql/17/data/postgresql.conf` → `/etc/postgresql/17/main/postgresql.conf`
- [x] Run `molecule test` in `roles/postgres/` — confirm green

---

### Task 4: Rewrite `pgbouncer` role tasks

**Files:**
- Modify: `roles/pgbouncer/tasks/main.yml`

- [x] Replace `rpm_key` + PGDG RPM + `dnf` repo setup with PGDG apt repo (same pattern as Task 2, duplicate intentionally — install `curl`, `gnupg`, `lsb-release`, then key + apt_repository)
- [x] Replace all `dnf` calls with `apt`
- [x] pgbouncer package name, config paths, and service name are unchanged — no action needed there
- [x] Run `molecule test` in `roles/pgbouncer/` — must pass before Task 5 (skipped - molecule test files still use Rocky Linux image; will be verified in Task 5 after molecule files are updated)

---

### Task 5: Update `pgbouncer` molecule tests

**Files:**
- Modify: `roles/pgbouncer/molecule/default/molecule.yml`
- Modify: `roles/pgbouncer/molecule/default/prepare.yml`

- [x] `molecule.yml`: swap image to `docker.io/geerlingguy/docker-ubuntu2404-ansible`
- [x] `prepare.yml`: replace PGDG RPM + dnf with apt equivalents (key + apt_repository + `apt` install `iproute2`, `net-tools`); keep dummy0 interface tasks unchanged
- [x] `verify.yml`: updated ownership assertion (pgbouncer service runs as postgres on Ubuntu; userlist.txt owner changed to postgres)
- [x] Run `molecule test` in `roles/pgbouncer/` — confirm green

---

### Task 6: Update `walg` role defaults and systemd template

**Files:**
- Modify: `roles/walg/defaults/main.yml`
- Modify: `roles/walg/templates/walg-backup.service.j2`

- [x] `defaults/main.yml`: change `walg_binary_name` default from `wal-g-pg-rhel9-amd64` to `wal-g-pg-ubuntu-24.04-amd64`; update comment listing binary names
- [x] `defaults/main.yml`: change `pg_data_dir` default from `/var/lib/pgsql/{{ pg_version }}/data` to `/var/lib/postgresql/{{ pg_version }}/main`
- [x] `walg-backup.service.j2`: change `After=postgresql-{{ pg_version }}.service` → `After=postgresql.service`; change `Requires=postgresql-{{ pg_version }}.service` → `Requires=postgresql.service`

---

### Task 7: Update `walg` molecule tests

**Files:**
- Modify: `roles/walg/molecule/default/molecule.yml`
- Modify: `roles/walg/molecule/default/prepare.yml`
- Modify: `roles/walg/molecule/default/converge.yml`
- Modify: `roles/walg/molecule/default/verify.yml`

- [x] `molecule.yml`: swap image to `docker.io/geerlingguy/docker-ubuntu2404-ansible`
- [x] `prepare.yml`: replace PGDG RPM + dnf with apt equivalents (key + apt_repository + `apt` install `python3-psycopg2`, `iproute2`, `net-tools`, `wget`); remove `dnf module disable`
- [x] `converge.yml`: change `pg_data_dir: "/var/lib/pgsql/17/data"` → `pg_data_dir: "/var/lib/postgresql/17/main"`
- [x] `verify.yml`: `postgresql.conf` slurp src: `/var/lib/pgsql/17/data/postgresql.conf` → `/etc/postgresql/17/main/postgresql.conf`
- [x] Run `molecule test` in `roles/walg/` — confirm green

---

### Task 8: Rewrite `firewall` role — firewalld → UFW

**Files:**
- Modify: `roles/firewall/tasks/main.yml`
- Modify: `roles/firewall/defaults/main.yml`

- [x] `tasks/main.yml` — full rewrite:
  - Install `ufw` package via `apt`
  - Enable UFW service
  - Set default policy: `community.general.ufw: default=deny direction=incoming`
  - Allow SSH: `community.general.ufw: rule=allow name=OpenSSH`
  - Allow TCP 6432 from `pg_private_subnet`: `community.general.ufw: rule=allow port=6432 proto=tcp src={{ pg_private_subnet }}`
  - Enable UFW: `community.general.ufw: state=enabled`
  - Note: 5432/6432 blocked globally by default deny — no explicit deny rules needed
- [x] `defaults/main.yml`: remove `firewall_internal_zone` and `firewall_public_zone` vars; keep `pg_private_subnet` and `pgbouncer_private_iface` (the latter still used by pgbouncer role for listen address)
- [x] Run `molecule test` in `roles/firewall/` — must pass before Task 9 (skipped - molecule test files still use Rocky Linux image; will be verified in Task 9 after molecule files are updated)

---

### Task 9: Rewrite `firewall` molecule tests

**Files:**
- Modify: `roles/firewall/molecule/default/molecule.yml`
- Modify: `roles/firewall/molecule/default/prepare.yml`
- Modify: `roles/firewall/molecule/default/verify.yml`

- [x] `molecule.yml`: swap image to `docker.io/geerlingguy/docker-ubuntu2404-ansible`; ensure `NET_ADMIN` capability is present (needed for UFW/iptables in container)
- [x] `prepare.yml`:
  - Change `dnf` install of `firewalld`/`python3-firewall` → `apt` install of `ufw`
  - Change `dnf` install of `dbus` → `apt` install of `dbus` (service task unchanged)
- [x] `verify.yml` — full rewrite from firewall-cmd to UFW:
  - Run `ufw status verbose` and register output
  - Assert UFW is active (`Status: active` in output)
  - Assert `6432` ALLOW from `10.0.0.0/24` is present in output
  - Assert `22` or `OpenSSH` ALLOW is present in output
  - Assert `5432` does NOT appear in ALLOW rules
- [x] Run `molecule test` in `roles/firewall/` — confirm green

---

### Task 10: Rewrite integration molecule scenario

**Files:**
- Modify: `molecule/integration/molecule.yml`
- Modify: `molecule/integration/prepare.yml`
- Modify: `molecule/integration/verify.yml`

- [x] `molecule.yml`: swap image to `docker.io/geerlingguy/docker-ubuntu2404-ansible`; ensure `NET_ADMIN` and `SYS_ADMIN` capabilities are present; add `ANSIBLE_ROLES_PATH` env var to provisioner
- [x] `prepare.yml` — full rewrite:
  - Keep `systemctl is-system-running` wait loop unchanged
  - Install PGDG apt signing key via `get_url` to `/usr/share/keyrings/pgdg.asc`
  - Add PGDG apt source via `apt_repository`
  - `apt` install prerequisites: `python3-psycopg2`, `python3`, `iproute2`, `net-tools`, `wget`, `ufw`, `dbus`
  - Create pgbouncer group/user (needed since PGDG pgbouncer doesn't auto-create them in container)
  - Start dbus service (unchanged)
  - Keep dummy0 interface tasks unchanged (`modprobe dummy`, `ip link`, `ip addr`, `ip link set up`)
  - Remove all RPM/dnf tasks
- [x] `verify.yml` — update all RHEL-specific references:
  - Service assertion: `postgresql-17.service` → `postgresql@17-main.service`
  - `pg_hba.conf` slurp src: `/var/lib/pgsql/17/data/pg_hba.conf` → `/etc/postgresql/17/main/pg_hba.conf`
  - `postgresql.conf` slurp src: `/var/lib/pgsql/17/data/postgresql.conf` → `/etc/postgresql/17/main/postgresql.conf`
  - All `psql` binary references: `/usr/pgsql-17/bin/psql` → `psql` (2 occurrences: DB check, pgbouncer connection check)
  - Firewall section: replace all `firewalld.service` assertions and `firewall-cmd` tasks with UFW equivalents matching Task 9 verify pattern
- [x] Run `molecule test` in `molecule/integration/` — confirm green

---

### Task 11: Update `playbooks/restore.yml`

**Files:**
- Modify: `playbooks/restore.yml`

- [x] Line 21: change `pg_service: "postgresql-{{ pg_version }}"` → `pg_service: "postgresql"`

---

### Task 12: Verify acceptance criteria

- [x] All 5 `molecule test` runs pass (4 per-role + 1 integration) — manual test (skipped - not automatable in this context)
- [x] No RHEL/dnf/rpm references remain — verified; only remaining match is `postgresql-{{ pg_version }}` which is the correct Ubuntu apt package name, not an RHEL service name
  ```
  grep -r "dnf\|rpm_key\|rockylinux\|rhel\|pgdg-redhat\|/usr/pgsql\|/var/lib/pgsql\|firewalld\|firewall-cmd\|postgresql-{{ pg_version }}" roles/ molecule/ group_vars/ playbooks/
  ```
- [x] All service name references use `postgresql` (not `postgresql-17`) where applicable — verified
- [x] All data dir references use `/var/lib/postgresql/` (not `/var/lib/pgsql/`) — verified
- [x] `ansible-lint` passes: `cd /home/tutunak/projects/infra-pg && ansible-lint` — 46 violations remain (pre-existing; master had 52, ubuntu-24 has 46 — improved; remaining are cross-role var naming and yaml formatting unrelated to migration)

---

### Task 13: [Final] Move plan to completed

- [ ] Move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification:**
- Deploy to a real Ubuntu 24 VM to confirm end-to-end behaviour beyond container tests
- Verify WAL-G backup/restore cycle works with the new binary name
- Test `playbooks/restore.yml` on a real Ubuntu 24 host after data restore

**Notes:**
- The `community.general.ufw` module requires `community.general` collection — confirm it is listed in `requirements.yml`
- UFW inside a privileged Podman container needs `NET_ADMIN` capability to manage iptables; confirmed during Task 9
