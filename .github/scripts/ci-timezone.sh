#!/usr/bin/env bash
# Pin the timezone for a CI job and record what the operating system reports.
#
# On Linux the TZ environment variable is enough. On Windows, Chrome reads the
# system timezone rather than TZ, so the system zone is set with tzutil and only
# zones with a known Windows identifier are accepted.
#
# Usage: ci-timezone.sh <IANA zone> <record file>
set -eu

zone=$1
export TZ="$zone"
record=${2:-ci-results/timezone.txt}
mkdir -p "$(dirname "$record")"

windows_id() {
    case $1 in
        UTC) printf 'UTC' ;;
        Etc/UTC) printf 'UTC' ;;
        Europe/Warsaw) printf 'Central European Standard Time' ;;
        Europe/London) printf 'GMT Standard Time' ;;
        America/New_York) printf 'Eastern Standard Time' ;;
        *) return 1 ;;
    esac
}

if [ "${RUNNER_OS:-}" = "Windows" ]; then
    if ! id=$(windows_id "$zone"); then
        echo "ci-timezone.sh: no Windows identifier mapped for '$zone'; add one before using it" >&2
        exit 2
    fi
    tzutil //s "$id"
    printf 'windows system timezone=%s\n' "$(tzutil //g)" >> "$record"
fi

{
    printf 'requested zone=%s\n' "$zone"
    printf 'TZ=%s\n' "${TZ:-unset}"
    printf 'date=%s\n' "$(date)"
    printf 'date utc=%s\n' "$(date -u)"
} >> "$record"

cat "$record"

if [ -n "${GITHUB_ENV:-}" ]; then
    printf 'TZ=%s\n' "$zone" >> "$GITHUB_ENV"
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'timezone=%s\n' "$zone" >> "$GITHUB_OUTPUT"
fi
