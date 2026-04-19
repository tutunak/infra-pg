#!/usr/bin/env bash
# Restore the WAL-G base backup appropriate for RESTORE_TIME into $PGDATA.
# Called by restore.yml as the postgres OS user.
# Required environment variables:
#   PGDATA        — PostgreSQL data directory (not required in --check mode)
#   RESTORE_TIME  — Target recovery time (UTC), format: "YYYY-MM-DD HH:MM:SS"
#
# Usage:
#   walg-restore.sh           — select eligible backup and fetch it into PGDATA
#   walg-restore.sh --check   — preflight only: validate RESTORE_TIME is a real
#                               calendar date and that an eligible base backup exists
#                               in storage; prints selected backup name and exits 0,
#                               or exits non-zero without touching PGDATA
set -euo pipefail

CHECK_ONLY=false
if [[ "${1:-}" == "--check" ]]; then
  CHECK_ONLY=true
fi

: "${RESTORE_TIME:?RESTORE_TIME environment variable must be set}"

if [[ "$CHECK_ONLY" == "false" ]]; then
  : "${PGDATA:?PGDATA environment variable must be set}"
fi

set -a
. /etc/wal-g/env
set +a

# Fetch the backup list once and cache it — avoid a second round-trip to S3 that
# could observe a different state (new backups pushed, expiry run) between calls.
#
# Find the latest base backup whose finish_time is at or before RESTORE_TIME.
# finish_time (available via --detail) marks when the backup completed — a backup
# that started before RESTORE_TIME but finished after it cannot be used as a PITR
# base because PostgreSQL requires WAL continuity from the backup's end, not start.
# Using start time ("time" field) could select a backup that was still in progress
# at RESTORE_TIME, producing an unrecoverable restore.
#
# datetime.strptime is strict: invalid calendar dates (e.g. 2026-02-31) raise
# ValueError and the script exits non-zero before touching PGDATA.
#
# python3 -c is used (not "python3 - <<'HEREDOC'") so that stdin remains
# connected to the wal-g pipe; with "python3 -", Python consumes stdin to
# read the script source and json.load(sys.stdin) then sees EOF.
_BACKUP_LIST_JSON=$(/usr/local/bin/wal-g backup-list --detail --json 2>/dev/null) \
  || { echo "ERROR: wal-g backup-list failed — cannot reach S3 or credentials are invalid" >&2; exit 1; }

BACKUP_NAME=$(
  echo "${_BACKUP_LIST_JSON}" | python3 -c '
import os, json, sys
from datetime import datetime, timezone

try:
    target = datetime.strptime(os.environ["RESTORE_TIME"], "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
except ValueError as e:
    sys.stderr.write(
        "Invalid RESTORE_TIME=%s: %s\n"
        % (os.environ["RESTORE_TIME"], e)
    )
    sys.exit(1)

# Reject future targets: WAL archive cannot cover time points that have not yet occurred.
now = datetime.now(timezone.utc)
if target > now:
    sys.stderr.write(
        "RESTORE_TIME=%s is in the future (current UTC: %s). "
        "WAL archive cannot cover a future target — refusing to proceed.\n"
        % (os.environ["RESTORE_TIME"], now.strftime("%Y-%m-%d %H:%M:%S"))
    )
    sys.exit(1)

backups = json.load(sys.stdin)
eligible = []
for b in backups:
    t_str = b.get("finish_time", "")
    if not t_str:
        continue
    try:
        t = datetime.fromisoformat(t_str.replace("Z", "+00:00"))
        if t <= target:
            eligible.append((t, b["backup_name"]))
    except ValueError:
        pass

if eligible:
    eligible.sort(key=lambda x: x[0])
    print(eligible[-1][1])
else:
    sys.stderr.write(
        "No base backup found at or before RESTORE_TIME=%s. "
        "Refusing to fall back to LATEST — that backup may post-date the "
        "target time and would produce an incorrect PITR result.\n"
        % os.environ["RESTORE_TIME"]
    )
    sys.exit(1)
'
) || { echo "ERROR: failed to select an eligible base backup for RESTORE_TIME=${RESTORE_TIME}" >&2; exit 1; }

if [[ "$CHECK_ONLY" == "true" ]]; then
  # Extract the selected backup's first WAL segment name from the cached backup-list
  # output — reusing the same JSON avoids a second S3 round-trip that could observe
  # a different backup catalogue (new backups pushed, expiry run between calls).
  BACKUP_WAL_FILE=$(
    echo "${_BACKUP_LIST_JSON}" | BACKUP_NAME="${BACKUP_NAME}" python3 -c '
import json, os, sys
backups = json.load(sys.stdin)
target = os.environ["BACKUP_NAME"]
for b in backups:
    if b.get("backup_name") == target:
        print(b.get("wal_file_name", ""))
        sys.exit(0)
sys.stderr.write("backup %s not found in backup-list output\n" % target)
sys.exit(1)
' ) || BACKUP_WAL_FILE=""

  # Verify WAL archive integrity to detect gaps that would cause replay failure
  # after PGDATA is wiped. wal-g wal-verify integrity scans WAL segments from
  # the oldest stored backup's start LSN to the current cluster segment — it is
  # NOT scoped to the selected backup's window.
  #
  # Status meanings:
  #   OK      — all segments present; safe to proceed
  #   WARNING — some segments are MISSING_DELAYED or MISSING_UPLOADING (in-flight).
  #             These are NOT yet confirmed in storage. If the primary is down
  #             (the common disaster-recovery scenario), those uploads will never
  #             complete and recovery will fail after PGDATA is wiped. Fail here
  #             to preserve the local copies until uploads are verified complete.
  #   FAILURE — one or more MISSING_LOST segments. Scoped against BACKUP_WAL_FILE:
  #             gaps before the backup's first WAL segment are in historical WAL
  #             outside the restore window and do not affect recovery. Only gaps
  #             at or after BACKUP_WAL_FILE cause this check to fail.
  _walg_verify_stderr=$(mktemp)
  trap 'rm -f "${_walg_verify_stderr}"' EXIT
  WAL_VERIFY_JSON=$(/usr/local/bin/wal-g wal-verify integrity --json 2>"${_walg_verify_stderr}") || {
    echo "ERROR: wal-g wal-verify integrity failed — archive may be corrupt or inaccessible." >&2
    cat "${_walg_verify_stderr}" >&2
    exit 1
  }
  rm -f "${_walg_verify_stderr}"
  trap - EXIT
  BACKUP_NAME="${BACKUP_NAME}" BACKUP_WAL_FILE="${BACKUP_WAL_FILE}" python3 -c '
import json, os, sys
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except json.JSONDecodeError as e:
    sys.stderr.write("Failed to parse wal-verify --json output: %s\n" % e)
    sys.exit(1)
# WAL-G wal-verify --json returns a map keyed by check type:
#   { "integrity": { "status": "OK|WARNING|FAILURE",
#                    "details": [
#                      { "timeline_id": N, "start_segment": "...", "end_segment": "...",
#                        "segments_count": N, "status": "FOUND|MISSING_DELAYED|MISSING_UPLOADING|MISSING_LOST" }
#                    ] },
#     "timeline": { "status": "...", "details": [...] } }
integrity = data.get("integrity", {})
storage_status = integrity.get("status", "")

if storage_status == "WARNING":
    in_flight = [
        d for d in integrity.get("details", [])
        if d.get("status") in ("MISSING_DELAYED", "MISSING_UPLOADING")
    ]
    sys.stderr.write(
        "WAL archive integrity check returned WARNING: "
        "%d range(s) with in-flight segments (MISSING_DELAYED/MISSING_UPLOADING). "
        "These segments are not yet confirmed in storage. "
        "In a disaster-recovery scenario the primary may be down and these uploads "
        "will never complete, causing recovery to fail after PGDATA is wiped. "
        "Refusing to proceed — verify WAL uploads are complete before retrying.\n"
        % len(in_flight)
    )
    sys.exit(1)

if storage_status == "FAILURE":
    backup_name = os.environ.get("BACKUP_NAME", "?")
    backup_wal_file = os.environ.get("BACKUP_WAL_FILE", "")
    lost = [
        d for d in integrity.get("details", [])
        if d.get("status") == "MISSING_LOST"
    ]
    if backup_wal_file:
        # WAL segment names encode timeline+LSN as fixed-width hex and sort
        # lexicographically in LSN order. A range whose end_segment is
        # strictly before the backup start segment is entirely in historical
        # WAL and cannot affect the selected restore window.
        lost_in_window = [
            d for d in lost
            if d.get("end_segment", "") >= backup_wal_file
        ]
        if not lost_in_window:
            sys.stderr.write(
                "WAL archive integrity check returned FAILURE, but all %d "
                "MISSING_LOST range(s) end before the selected backup start "
                "segment (%s) and are outside the restore window. "
                "Proceeding.\n" % (len(lost), backup_wal_file)
            )
            sys.exit(0)
        lost = lost_in_window
    sys.stderr.write(
        "WAL archive integrity check failed (integrity.status=FAILURE): "
        "%d range(s) with MISSING_LOST segments within the restore window "
        "(backup %s → RESTORE_TIME). Replay would fail when PostgreSQL "
        "reaches these gaps during recovery.\n"
        % (len(lost), backup_name)
    )
    sys.exit(1)
' <<< "${WAL_VERIFY_JSON}" || exit 1
  echo "Preflight OK: eligible base backup found: ${BACKUP_NAME}, WAL archive integrity verified"
  exit 0
fi

exec /usr/local/bin/wal-g backup-fetch "$PGDATA" "$BACKUP_NAME"
