# infra-pg

Ansible-based idempotent setup of PostgreSQL 17 on Rocky/AlmaLinux 9 (RHEL 9) VMs.

Each app gets its own database and least-privilege user. Apps connect over a private
network via PgBouncer (port 6432). Secrets are stored in Ansible Vault. Continuous
WAL archiving and nightly full backups via WAL-G enable point-in-time recovery.

## Architecture

```
App VM (10.0.0.x) --private network--> PgBouncer :6432 --> PostgreSQL 127.0.0.1:5432
```

Four roles: `postgres`, `pgbouncer`, `walg`, `firewall`.

## Prerequisites

### Control machine

- Python >= 3.9
- Ansible >= 2.15

```
pip install ansible
ansible-galaxy collection install -r requirements.yml
```

### Target hosts

- Rocky Linux 9 or AlmaLinux 9
- A private network interface (default `eth1`) reachable from app VMs
- Internet access to download packages from PGDG and GitHub releases

### Testing (optional)

- Podman >= 4.0
- molecule + molecule-plugins[podman]

```
pip install molecule molecule-plugins[podman] ansible-lint
```

### Linting

`ansible-lint` runs in CI and gates all Molecule jobs. Run it locally before pushing:

```
python scripts/check_molecule_roles_path.py
ansible-lint
```

`check_molecule_roles_path.py` validates that `ANSIBLE_ROLES_PATH` is correct in every
`molecule.yml`. A custom rule (`LOCAL001` in `.ansible-lint-rules/`) enforces that all
`get_url` tasks include `retries` and `until`.

## Vault setup

1. Copy the example host vars for your host:

```
cp -r host_vars/example host_vars/myserver
```

2. Edit `host_vars/myserver/vars.yml` — set the private interface name and your
   database list.

3. Edit `host_vars/myserver/vault.yml` — fill in all `CHANGE_ME` values:
   - `vault_app*_user_password` — passwords for each application database user
   - `vault_walg_s3_*` — S3-compatible storage credentials and bucket name

4. Encrypt the vault file and set a vault password:

```
echo "my-strong-vault-password" > .vault_pass
chmod 600 .vault_pass
ansible-vault encrypt host_vars/myserver/vault.yml
```

The file `.vault_pass` is listed in `.gitignore` and must never be committed.

To edit secrets later: `ansible-vault edit host_vars/myserver/vault.yml`

## Inventory

Edit `inventory/hosts.yml` and add your server(s) under `pg_servers`:

```yaml
all:
  children:
    pg_servers:
      hosts:
        myserver:
          ansible_host: 192.168.1.10
          ansible_user: rocky
```

## Quickstart — full setup

Run the setup playbook to install and configure all four roles (firewall → postgres
→ pgbouncer → walg):

```
ansible-playbook playbooks/setup.yml -i inventory/hosts.yml
```

The playbook is fully idempotent — safe to re-run after config changes.

## Adding a database

To add a new application database and user to a running host, and register it with
PgBouncer:

```
ansible-playbook playbooks/add-database.yml \
  -i inventory/hosts.yml \
  -e "db_name=myapp_db db_owner=myapp_user db_password=s3cr3t"
```

PgBouncer is reloaded automatically. The new database is accessible immediately via
port 6432 without restarting PostgreSQL.

## Point-in-time recovery (PITR)

WARNING: This playbook destroys the current PostgreSQL data directory. It is
destructive and irreversible. You must pass `restore_confirm=yes` explicitly.

```
ansible-playbook playbooks/restore.yml \
  -i inventory/hosts.yml \
  -e "target_host=myserver restore_time='2026-04-18 14:30:00' restore_confirm=yes"
```

The playbook will:
1. Stop PostgreSQL
2. Wipe PGDATA (confirmed by `restore_confirm=yes`)
3. Fetch the latest WAL-G base backup
4. Apply WAL segments up to `restore_time` (UTC)
5. Promote and wait for PostgreSQL to reach normal operating state
6. Clean up recovery settings automatically

Omitting `restore_confirm=yes` causes an immediate assertion failure — no data is
touched.

## Running Molecule tests

Per-role tests (run from the repo root):

```
cd roles/postgres  && molecule test
cd roles/pgbouncer && molecule test
cd roles/walg      && molecule test
cd roles/firewall  && molecule test
```

Integration test (all four roles together):

```
molecule test -s integration
```

Each test run verifies idempotency by running converge twice and asserting zero
changed tasks on the second pass.

## Variable reference

| Variable | Default | Description |
|---|---|---|
| `pg_version` | `17` | PostgreSQL major version |
| `pg_private_subnet` | `10.0.0.0/24` | Subnet allowed to reach PgBouncer |
| `pgbouncer_private_iface` | `eth1` | NIC name for PgBouncer listen address |
| `walg_version` | `v3.0.3` | WAL-G release tag (pinned) |
| `pg_databases` | `[]` | List of `{name, owner, password}` dicts |

Override `pgbouncer_private_iface` per host in `host_vars/<host>/vars.yml` if your
private NIC uses a different name (e.g. `ens4`, `eth0`).
