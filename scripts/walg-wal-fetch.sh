#!/usr/bin/env bash
# Wrapper around 'wal-g wal-fetch' for use as PostgreSQL restore_command.
#
# WAL-G exit code semantics:
#   0   — segment fetched successfully
#   74  — segment not found in archive (EX_NOINPUT / ENODATA)
#   other — real error: auth failure, network issue, config problem, etc.
#
# PostgreSQL treats restore_command exits 1-125 as "WAL not in archive" and
# may promote the instance prematurely if a real error is misclassified as
# end-of-archive. Exit codes >125 are treated as fatal by PostgreSQL and abort
# recovery. This wrapper kills postmaster on non-74 failures AND remaps real
# error codes to >=126 so that PostgreSQL treats them as fatal even if the kill
# attempt fails (e.g. PGDATA unset, stale PID, or permission error).

_kill_postmaster() {
    if [ -z "${PGDATA:-}" ] || [ ! -f "${PGDATA}/postmaster.pid" ]; then
        echo "walg-wal-fetch: cannot kill postmaster — PGDATA not set or no postmaster.pid; recovery may not abort" >&2
        return 1
    fi
    local pid
    pid="$(head -1 "${PGDATA}/postmaster.pid")"
    # kill -0 checks existence without sending a signal; if the PID is gone the
    # postmaster already crashed and recovery cannot continue regardless.
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "walg-wal-fetch: postmaster PID $pid is not running (stale postmaster.pid) — no process to kill" >&2
        return 0
    fi
    if ! kill "$pid" 2>/dev/null; then
        echo "walg-wal-fetch: kill $pid failed — recovery may not abort cleanly" >&2
        return 1
    fi
}

set -a
if ! . /etc/wal-g/env 2>/dev/null; then
    echo "walg-wal-fetch: failed to source /etc/wal-g/env — killing postmaster to abort recovery" >&2
    _kill_postmaster
    # Exit >125 so PostgreSQL treats this as a fatal error rather than
    # "WAL segment not in archive", even if the kill attempt above failed.
    exit 126
fi
set +a

/usr/local/bin/wal-g wal-fetch "$1" "$2"
rc=$?

case $rc in
    0)  exit 0 ;;
    74) exit 74 ;;
    *)
        echo "walg-wal-fetch: wal-g wal-fetch exited $rc for segment '$1' — killing postmaster to abort recovery" >&2
        _kill_postmaster
        # Remap exit code to >125 so PostgreSQL treats this as fatal even if
        # the kill above failed. Codes already >125 are passed through directly.
        if [ "$rc" -gt 125 ]; then
            exit "$rc"
        else
            exit 126
        fi
        ;;
esac
