#!/usr/bin/bash
set -o pipefail
cd "C:/Users/AuraFlight/Desktop/02cloud/VPS projects/openpair"
LOG="overnight_run/summary.log"

echo "=== started $(date) ===" > "$LOG"

echo "--- bye batch: 100000 tournaments, 9 rounds, 15% bye rate ---" | tee -a "$LOG"
PAIRING_FUZZ_DUMP="C:/Users/AuraFlight/Desktop/02cloud/VPS projects/openpair/overnight_run/bye" \
PAIRING_FUZZ_COUNT=100000 PAIRING_FUZZ_ROUNDS=9 PAIRING_FUZZ_BYE_PCT=15 \
  mix test --only bbppairings > overnight_run/bye.log 2>&1
echo "bye batch finished $(date), exit=$?" | tee -a "$LOG"
tail -30 overnight_run/bye.log >> "$LOG"

echo "--- forfeit batch: 100000 tournaments, 9 rounds, 10% forfeit rate ---" | tee -a "$LOG"
PAIRING_FUZZ_DUMP="C:/Users/AuraFlight/Desktop/02cloud/VPS projects/openpair/overnight_run/forfeit" \
PAIRING_FUZZ_COUNT=100000 PAIRING_FUZZ_ROUNDS=9 PAIRING_FUZZ_FORFEIT_PCT=10 \
  mix test --only bbppairings > overnight_run/forfeit.log 2>&1
echo "forfeit batch finished $(date), exit=$?" | tee -a "$LOG"
tail -30 overnight_run/forfeit.log >> "$LOG"

echo "=== all done $(date) ===" | tee -a "$LOG"
