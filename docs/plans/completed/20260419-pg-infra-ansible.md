# PostgreSQL 17 Idempotent Infrastructure (Ansible)

## Overview
- Idempotent Ansible-based setup of PostgreSQL 17 on Rocky/AlmaLinux RHEL 9 VMs
- Multi-app database hosting: each app gets its own database and least-privilege user
- Apps connect from separate VMs over a private network via PgBouncer (no direct PG exposure)
- Point-in-time recovery (PITR) via WAL-G to S3-compatible storage, restorable by a single command
- Secure by default: scram-sha-256 auth, firewalld restricting access to private subnet only, Ansible Vault for secrets

## Context (from discovery)
- Repository: `/home/tutunak/projects/infra-pg/` — currently empty (just README)
- No existing Ansible roles or patterns to follow; greenfield setup
- Target OS: Rocky Linux / AlmaLinux 9 (RHEL 9)
- PostgreSQL: v17 (from PGDG repo)
- WAL-G: latest binary from GitHub releases (version pinned in vars)
- PgBouncer: >= 1.21 required (SCRAM-SHA-256 support in auth_type)

## Development Approach
- **Testing approach**: Regular (implement role, then write Molecule tests)
- Complete each task fully before moving to the next
- Make small, focused changes per role
- **CRITICAL: every task MUST include Molecule verify.yml tests**
- **CRITICAL: all tests must pass before starting next task**
- Run `molecule test` after each role is complete
- Idempotency verified automatically by Molecule (runs converge twice, checks zero changes)

## Testing Strategy
- **Per-role**: each role has `molecule/default/` with podman driver + `rockylinux:9` systemd container
  - All Molecule containers require `privileged: true`, `command: /usr/sbin/init`, and `tmpfs: [/run, /tmp]` for systemd services to function
  - `prepare.yml`: configure systemd in container, install dnf prerequisites
  - `converge.yml`: apply the role
  - `verify.yml`: assert services running, ports bound correctly, config values set
  - Idempotency: Molecule re-runs converge and asserts 0 changed tasks
- **Integration**: `molecule/integration/` runs all roles together (full `setup.yml`)
  - `prepare.yml` creates a dummy private network interface (`dummy0` at `10.0.0.1/24`) to simulate private NIC
  - Verifies: PG listening on localhost, PgBouncer accepting connections, WAL-G config valid, firewall rules active
- **CI**: GitHub Actions workflow runs `molecule test` for each role on PR and push to master; requires Podman installed on runner

## Solution Overview
- Four Ansible roles (`postgres`, `pgbouncer`, `walg`, `firewall`) composed by three playbooks (`setup.yml`, `add-database.yml`, `restore.yml`)
- Inventory + group_vars/host_vars define all per-host configuration declaratively
- Secrets in Ansible Vault-encrypted `host_vars/<host>/vault.yml`
- WAL-G archives WAL continuously; nightly full backup via systemd timer
- `postgresql.conf` is owned exclusively by the `postgres` role; `archive_command` and other role-injected settings are controlled via variables (`pg_archive_command`) set in `group_vars/all.yml`
- Restore playbook handles PITR: confirm → stop PG → fetch backup → write recovery settings to `postgresql.auto.conf` → start PG → cleanup auto.conf after promotion

## Technical Details

### Variable structure
```yaml
# group_vars/all.yml
pg_version: 17
pg_private_subnet: "10.0.0.0/24"
pgbouncer_private_iface: "eth1"   # private NIC interface name (override per host if needed)
walg_version: "v3.0.3"            # pinned WAL-G release tag
pg_archive_command: ""            # set to wal-g push command by walg role via group_vars
walg_s3_bucket: "{{ vault_walg_s3_bucket }}"
walg_s3_endpoint: "{{ vault_walg_s3_endpoint }}"
walg_s3_region: "{{ vault_walg_s3_region }}"
walg_s3_access_key: "{{ vault_walg_s3_access_key }}"
walg_s3_secret_key: "{{ vault_walg_s3_secret_key }}"

# host_vars/<host>/vars.yml
pgbouncer_private_iface: "eth1"   # override if NIC name differs
pg_databases:
  - name: app1_db
    owner: app1_user
    password: "{{ vault_app1_user_password }}"
  - name: app2_db
    owner: app2_user
    password: "{{ vault_app2_user_password }}"

# host_vars/<host>/vault.yml  (ansible-vault encrypted)
vault_app1_user_password: "..."
vault_app2_user_password: "..."
vault_walg_s3_bucket: "..."
vault_walg_s3_endpoint: "..."
vault_walg_s3_region: "..."
vault_walg_s3_access_key: "..."
vault_walg_s3_secret_key: "..."
```

### PgBouncer authentication chain
PgBouncer >= 1.21 supports `auth_type = scram-sha-256`. Authentication flow:
1. App connects to PgBouncer with plaintext password
2. PgBouncer looks up user in `userlist.txt` (stores plaintext passwords, file mode 0600)
3. PgBouncer authenticates to PostgreSQL using SCRAM-SHA-256 (server-side hash in pg_shadow)
4. `pg_hba.conf` only accepts connections from `127.0.0.1` (PgBouncer's outbound address)

`userlist.txt` stores plaintext passwords (the only format PgBouncer can use for SCRAM passthrough). File is owned by `pgbouncer` user, mode 0600, not world-readable.

### Network topology
```
App VM (10.0.0.x) → private network → PgBouncer (private_ip:6432) → localhost → PG (127.0.0.1:5432)
```

### Restore command (requires explicit confirmation)
```bash
ansible-playbook playbooks/restore.yml \
  -i inventory/hosts.yml \
  -e "target_host=myserver restore_time='2026-04-18 14:30:00' restore_confirm=yes"
```

## What Goes Where
- **Implementation Steps**: all Ansible roles, playbooks, tests, CI config — done in this repo
- **Post-Completion**: manual smoke test on a real VM, S3 bucket creation, vault password distribution

## Implementation Steps

### Task 1: Repository scaffold and inventory

**Files:**
- Create: `ansible.cfg`
- Create: `inventory/hosts.yml`
- Create: `group_vars/all.yml`
- Create: `host_vars/example/vars.yml`
- Create: `host_vars/example/vault.yml` (example, not encrypted)
- Create: `.gitignore`
- Create: `requirements.yml` (Ansible collections)

- [x] create `ansible.cfg` with `roles_path`, `inventory`, `collections_paths`, `vault_password_file` settings
- [x] create `inventory/hosts.yml` with example host grouped by `pg_servers`
- [x] create `group_vars/all.yml` with all shared variables including `walg_version`, `pgbouncer_private_iface`, `pg_archive_command`
- [x] create `host_vars/example/vars.yml` with `pg_databases` list example (including password references)
- [x] create `host_vars/example/vault.yml` with placeholder vault vars and comment explaining `ansible-vault encrypt`
- [x] create `.gitignore` (exclude `*.retry`, `.vault_pass`, `*.log`, `__pycache__`)
- [x] create `requirements.yml` listing collections: `community.postgresql`, `community.general`
- [x] verify scaffold: `ansible-inventory -i inventory/hosts.yml --list`

### Task 2: `postgres` role

**Files:**
- Create: `roles/postgres/tasks/main.yml`
- Create: `roles/postgres/templates/pg_hba.conf.j2`
- Create: `roles/postgres/templates/postgresql.conf.j2`
- Create: `roles/postgres/defaults/main.yml`
- Create: `roles/postgres/handlers/main.yml`
- Create: `roles/postgres/molecule/default/molecule.yml`
- Create: `roles/postgres/molecule/default/prepare.yml`
- Create: `roles/postgres/molecule/default/converge.yml`
- Create: `roles/postgres/molecule/default/verify.yml`

- [x] add PGDG repo and install `postgresql17-server`, `postgresql17` packages
- [x] run `postgresql-17-setup initdb` (idempotent: skip if data dir exists)
- [x] template `postgresql.conf`: `listen_addresses = 'localhost'`, `archive_mode = on`, `archive_command = '{{ pg_archive_command }}'` (defaults to empty string — set by walg role via vars)
- [x] template `pg_hba.conf`: `scram-sha-256` for local socket and `127.0.0.1/32`, deny all else; `postgres` superuser via peer on local socket
- [x] enable and start `postgresql-17` service via handler
- [x] create per-app databases and users from `pg_databases` var using `community.postgresql` modules (idempotent)
- [x] write `molecule.yml`: podman driver, `geerlingguy/docker-rockylinux9-ansible`, `command: /usr/lib/systemd/systemd`, `privileged: true`, `tmpfs: {/run, /tmp}`
- [x] write `prepare.yml`: install `python3-psycopg2`, `postgresql17-server` prereqs; configure systemd in container
- [x] write `converge.yml`: apply `postgres` role with test `pg_databases`
- [x] write `verify.yml`: service running, port 5432 bound to 127.0.0.1 only (not 0.0.0.0), PG17 version, `scram-sha-256` in `pg_hba.conf`, test databases and users exist
- [x] run `molecule test` — must pass including idempotency check

### Task 3: `pgbouncer` role

**Files:**
- Create: `roles/pgbouncer/tasks/main.yml`
- Create: `roles/pgbouncer/templates/pgbouncer.ini.j2`
- Create: `roles/pgbouncer/templates/userlist.txt.j2`
- Create: `roles/pgbouncer/defaults/main.yml`
- Create: `roles/pgbouncer/handlers/main.yml`
- Create: `roles/pgbouncer/molecule/default/` (full scenario)

- [x] install `pgbouncer` >= 1.21 from PGDG repo (pin minimum version in defaults)
- [x] template `pgbouncer.ini`: `listen_addr = {{ ansible_facts[pgbouncer_private_iface].ipv4.address }}`, `listen_port = 6432`, `pool_mode = transaction`, `auth_type = scram-sha-256`, per-database `[databases]` entries from `pg_databases`
- [x] template `userlist.txt`: one line per app user with plaintext password from vault (`"username" "password"` format); file mode 0600, owner pgbouncer
- [x] enable and start `pgbouncer` service via handler
- [x] write full Molecule scenario with `privileged: true`, `tmpfs: [/run, /tmp]`; `prepare.yml` creates dummy private interface (`ip link add dummy0 type dummy && ip addr add 10.0.0.1/24 dev dummy0`)
- [x] `verify.yml`: pgbouncer running, port 6432 bound, `pool_mode = transaction` in config, `auth_type = scram-sha-256` in config, userlist.txt mode is 0600
- [x] run `molecule test` — must pass including idempotency

### Task 4: `walg` role

**Files:**
- Create: `roles/walg/tasks/main.yml`
- Create: `roles/walg/templates/walg-env.j2`
- Create: `roles/walg/templates/walg-backup.service.j2`
- Create: `roles/walg/templates/walg-backup.timer.j2`
- Create: `roles/walg/defaults/main.yml`
- Create: `roles/walg/molecule/default/` (full scenario)

- [x] download WAL-G binary from GitHub releases using `walg_version` var, install to `/usr/local/bin/wal-g` (idempotent: skip if version matches)
- [x] create `/etc/wal-g/` directory, template `env` file with S3 credentials (mode 0600, owner postgres group)
- [x] set `pg_archive_command` fact to `'source /etc/wal-g/env && /usr/local/bin/wal-g wal-push %p'` and notify `Reload postgresql` handler — **do NOT edit postgresql.conf directly; the postgres role template reads `pg_archive_command` variable**
- [x] create systemd `walg-backup.service` (runs `wal-g backup-push $PGDATA`, `EnvironmentFile=/etc/wal-g/env`) and `walg-backup.timer` (nightly 02:00 UTC)
- [x] enable `walg-backup.timer`
- [x] write full Molecule scenario with `privileged: true`, `tmpfs: [/run, /tmp]`
- [x] `verify.yml`: wal-g binary exists and is executable, `/etc/wal-g/env` present with mode 0600, timer unit enabled, `archive_command` in `postgresql.conf` contains `wal-g`
- [x] run `molecule test` — must pass including idempotency

### Task 5: `firewall` role

**Files:**
- Create: `roles/firewall/tasks/main.yml`
- Create: `roles/firewall/defaults/main.yml`
- Create: `roles/firewall/molecule/default/` (full scenario)

- [x] ensure `firewalld` installed and running
- [x] add rich rule: allow TCP 6432 from `pg_private_subnet` in internal zone (permanent + runtime)
- [x] ensure ports 5432 and 6432 are NOT in public zone services/ports
- [x] ensure SSH (22) remains open on public zone
- [x] write full Molecule scenario with `privileged: true`, `tmpfs: [/run, /tmp]` (required for firewalld + dbus in container)
- [x] `verify.yml`: firewalld running, rich rule for 6432 present, port 5432 absent from public zone, SSH present in public zone
- [x] run `molecule test` — must pass including idempotency

### Task 6: Playbooks

**Files:**
- Create: `playbooks/setup.yml`
- Create: `playbooks/add-database.yml`
- Create: `playbooks/restore.yml`
- Create: `scripts/walg-restore.sh`

- [x] write `setup.yml`: applies all four roles in order (firewall → postgres → pgbouncer → walg) against `pg_servers` group
- [x] write `add-database.yml`: idempotent — create DB, create user with password, grant privileges, update pgbouncer `userlist.txt` and `pgbouncer.ini`, reload pgbouncer; takes `db_name`, `db_owner`, `db_password` as extra vars
- [x] write `restore.yml`:
  - pre-task: assert `restore_confirm == 'yes'` and `restore_time` is defined (fail with clear message if not)
  - stop `postgresql-17` service
  - wipe `PGDATA` (with warning comment in task name)
  - run `wal-g backup-fetch LATEST` via `scripts/walg-restore.sh`
  - write `recovery.signal` (empty file)
  - write `recovery_target_time` to `postgresql.auto.conf` (not `postgresql.conf`)
  - start `postgresql-17` service
  - post-task: wait for PG to reach normal state (poll `pg_is_in_recovery()` until false), then remove `recovery_target_time` from `postgresql.auto.conf` via `ALTER SYSTEM RESET recovery_target_time`
- [x] write `scripts/walg-restore.sh`: `source /etc/wal-g/env && wal-g backup-fetch $PGDATA LATEST`
- [x] syntax-check all playbooks: `ansible-playbook --syntax-check playbooks/*.yml`

### Task 7: Integration Molecule scenario

**Files:**
- Create: `molecule/integration/molecule.yml`
- Create: `molecule/integration/prepare.yml`
- Create: `molecule/integration/converge.yml`
- Create: `molecule/integration/verify.yml`

- [x] write `molecule.yml`: podman driver, `rockylinux/rockylinux:9`, `privileged: true`, `command: /usr/sbin/init`, `tmpfs: [/run, /tmp]`
- [x] write `prepare.yml`: install all prerequisites + create dummy private interface (`ip link add dummy0 type dummy && ip addr add 10.0.0.1/24 dev dummy0 && ip link set dummy0 up`); set `pgbouncer_private_iface: dummy0`
- [x] write `converge.yml`: runs `setup.yml` against the container
- [x] write `verify.yml`: PG running on `127.0.0.1:5432`, PgBouncer listening on `10.0.0.1:6432`, WAL-G binary + timer present, firewalld rules active, can connect through PgBouncer with test user credentials
- [x] run `molecule test -s integration` — must pass

### Task 8: GitHub Actions CI

**Files:**
- Create: `.github/workflows/ci.yml`

- [x] write CI workflow triggered on push and PR to master
- [x] add Podman installation and cgroupv2 setup step for Ubuntu runners
- [x] matrix strategy: one job per role (`postgres`, `pgbouncer`, `walg`, `firewall`) + `integration`
- [x] each job: checkout, install Python + Ansible + Molecule + `molecule-plugins[podman]` + `ansible-lint`, run `molecule test`
- [x] cache pip dependencies for speed
- [x] verify workflow YAML is valid (`yamllint .github/workflows/ci.yml`)

### Task 9: Verify acceptance criteria
- [x] `ansible-inventory -i inventory/hosts.yml --list` succeeds
- [x] `ansible-playbook --syntax-check playbooks/setup.yml` passes
- [x] `ansible-playbook --syntax-check playbooks/add-database.yml` passes
- [x] `ansible-playbook --syntax-check playbooks/restore.yml` passes (requires -e "target_host=example ...")
- [x] `molecule test` passes for all four roles (idempotency verified in each)
- [x] `molecule test -s integration` passes
- [x] GitHub Actions workflow YAML passes yamllint
- [x] README documents: prerequisites, vault setup, setup.yml quickstart, add-database usage, restore usage with confirmation flag

### Task 10: [Final] Documentation and cleanup

**Files:**
- Modify: `README.md`
- Create: `docs/plans/completed/`

- [x] update `README.md`: prerequisites (Ansible, collections, Podman for testing), vault setup instructions, quickstart, add-database usage, restore usage (emphasize `restore_confirm=yes`)
- [x] move this plan to `docs/plans/completed/20260419-pg-infra-ansible.md`

## Post-Completion

**Manual verification on a real VM:**
- Provision a fresh Rocky 9 VM (DO/Hetzner/EC2) with private networking enabled
- Run `ansible-playbook playbooks/setup.yml -i inventory/hosts.yml`
- Verify PG running, PgBouncer reachable from a second VM on the private subnet
- Trigger a manual WAL-G backup: `sudo -u postgres wal-g backup-push $PGDATA`
- Run restore playbook with `restore_confirm=yes` and confirm PITR works on a separate VM

**External prerequisites:**
- Create S3 bucket (or DO Spaces / Hetzner Object Storage) before running setup
- Distribute Ansible Vault password securely to operators (e.g. 1Password, Bitwarden)
- Ensure private networking enabled on all VMs at the provider level
- PgBouncer >= 1.21 must be available in the target repo (PGDG provides it)
