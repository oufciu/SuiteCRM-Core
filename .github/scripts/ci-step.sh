#!/usr/bin/env bash
# Run one CI command, keep its full output in a log file and record its exit code
# and wall-clock duration for the job summary.
#
# Usage: ci-step.sh <label> <log-file> [junit-file] -- <command> [args...]
set -u

label=$1
log=$2
shift 2
junit=""
if [ "${1:-}" != "--" ]; then
    junit=$1
    shift
fi
if [ "${1:-}" != "--" ]; then
    echo "ci-step.sh: expected -- before the command" >&2
    exit 2
fi
shift

steps_file=${CI_STEPS_FILE:-ci-results/steps.tsv}
mkdir -p "$(dirname "$log")" "$(dirname "$steps_file")"

start=$(date +%s)
"$@" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
end=$(date +%s)

printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$rc" "$((end - start))" "$log" "$junit" >> "$steps_file"
exit "$rc"
