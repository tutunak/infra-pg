#!/usr/bin/env bash
# Restore the latest WAL-G base backup into $PGDATA.
# Called by restore.yml as the postgres OS user.
# PGDATA must be set in the environment before calling this script.
set -euo pipefail

: "${PGDATA:?PGDATA environment variable must be set}"

set -a
. /etc/wal-g/env
set +a

exec /usr/local/bin/wal-g backup-fetch "$PGDATA" LATEST
