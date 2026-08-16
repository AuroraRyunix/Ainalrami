# FE1 rules-interpretation disputes

Positions where OpenPair disagrees with bbpPairings and the disagreement is
**not** believed to be an OpenPair defect. FE1 category 3 — the endorsement
process explicitly provides for escalating these to the SPPC rather than
"fixing" them, so they are kept as files rather than as a paragraph.

Anything in here needs a written position before it can be escalated. Being
in this directory is a claim, not a conclusion; the bar is a second
independent engine agreeing with us.

## `seed735265-r7-p10`

Round 7, 10 players, from the 1,000,000-tournament small-field run
(4-10 players, 15% arbiter byes). **The only case in this project's history
where Gacrux sides with OpenPair against bbpPairings**, and the last
survivor of the 40 catalogued disagreements — the other 39 were one missing
field in the bootstrap matching and are gone.

    OpenPair:     [{3, 9}, {5, 1}, {7, nil}, {8, 2}]
    bbpPairings:  [{2, 9}, {3, nil}, {7, 5}, {8, 1}]

The engines disagree about who takes the pairing-allocated bye: ours and
Gacrux's give it to rank 7, bbpPairings' to rank 3.

**It is also the only case the adjudicator scores `theirs_scores_better`**,
which is the interesting part — our own C1-C21 ladder prefers bbpPairings'
answer while our engine (and Gacrux) produce the other one. Either the
ladder or the search is wrong about this position even though the OUTPUT
may be right, so "Gacrux agrees with us" is not on its own enough to file.

Re-checked after `explain_round/3` was fixed to stamp float history (it
previously scored C14-C21 blank on both sides of every verdict): the
classification is **unchanged**, `theirs_scores_better` on `C2/C4/C5
bye-eligibility`. That rung sits above C14-C21, so the fix could not have
reached it — worth recording so nobody re-runs it expecting a change.

Reproduce from scratch, ~1 second:

    PAIRING_FUZZ_SEED_FROM=735265 PAIRING_FUZZ_COUNT=1 \
      PAIRING_FUZZ_MIN_PLAYERS=4 PAIRING_FUZZ_MAX_PLAYERS=10 \
      PAIRING_FUZZ_BYE_PCT=15 PAIRING_FUZZ_ROUNDS=9 \
      PAIRING_FUZZ_DUMP=repro mix test --only bbppairings

Then `mix run tools/adjudicate.exs repro`.
