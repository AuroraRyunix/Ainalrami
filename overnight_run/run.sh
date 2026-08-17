#!/usr/bin/bash
# Long-running validation batches against bbpPairings.
#
# Run from anywhere; paths are resolved relative to the repo, not to
# whoever's home directory this was last run from.
#
#   ./overnight_run/run.sh
#
# See docs/validation.md for the full axis list and what each knob does.
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

LOG="overnight_run/summary.log"
echo "=== started $(date) ===" > "$LOG"

run_axis() {
  local name="$1"
  shift
  echo "--- $name ---" | tee -a "$LOG"
  env PAIRING_FUZZ_DUMP="$ROOT/overnight_run/$name" "$@" \
    mix test --only bbppairings > "overnight_run/$name.log" 2>&1
  echo "$name finished $(date), exit=$?" | tee -a "$LOG"
  tail -30 "overnight_run/$name.log" >> "$LOG"
}

run_axis bye     PAIRING_FUZZ_COUNT=100000 PAIRING_FUZZ_ROUNDS=9 PAIRING_FUZZ_BYE_PCT=15
run_axis forfeit PAIRING_FUZZ_COUNT=100000 PAIRING_FUZZ_ROUNDS=9 PAIRING_FUZZ_FORFEIT_PCT=10

echo "=== all done $(date) ===" | tee -a "$LOG"
