#!/bin/sh
# Wait for a process to go away, up to a bounded number of attempts. Used by
# `make install` after the polite quit. This script never signals anything:
# a still-running app refuses the replacement instead, so its last answer is
# not lost to an escalation.
#
#   wait-for-exit.sh <attempts> <command> [args...]
#
# The command is the "is it still running" predicate:
#   exit 0  running; keep waiting
#   exit 1  confirmed gone; stop with success
#   other   the check itself failed (2, 3, 126, 127, a signal, ...).
#           The helper fails closed with exit 2; an unknown status is never
#           read as "gone".
#
# Exit status:
#   0  the predicate confirmed the process gone
#   1  the process was still running after every attempt
#   2  usage error, invalid poll interval, missing or failing predicate,
#      or a sleep failure
#
# QUIT_WAIT_POLL_SECONDS (default 1) is the pause between attempts. It must be
# a positive number with at most one dot. An unset value means 1; an empty or
# malformed value is refused. Tests lower it.

set -u

usage() {
    echo "usage: $0 <attempts> <command> [args...]" >&2
    exit 2
}

fail() {
    echo "wait-for-exit: $*" >&2
    exit 2
}

[ "$#" -ge 2 ] || usage

attempts=$1
shift

case "$attempts" in
    ''|*[!0-9]*) fail "attempts must be a whole number" ;;
esac
if [ "$(printf '%s' "$attempts" | tr -d '0')" = "" ]; then
    fail "attempts must be at least 1"
fi

poll=${QUIT_WAIT_POLL_SECONDS-1}
case "$poll" in
    ''|.*|*.|*.*.*|*[!0-9.]*)
        fail "QUIT_WAIT_POLL_SECONDS must be a positive number"
        ;;
esac
if [ "$(printf '%s' "$poll" | tr -d '0.')" = "" ]; then
    fail "QUIT_WAIT_POLL_SECONDS must be greater than zero"
fi

attempt=0
while [ "$attempt" -lt "$attempts" ]; do
    "$@"
    status=$?
    case "$status" in
        0) ;;
        1) exit 0 ;;
        *) fail "the running check failed with status $status" ;;
    esac
    attempt=$((attempt + 1))
    if [ "$attempt" -lt "$attempts" ]; then
        if ! sleep "$poll"; then
            fail "sleep $poll failed"
        fi
    fi
done

exit 1
