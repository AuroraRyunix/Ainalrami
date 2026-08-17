# FE1 rules-interpretation disputes

Positions where Ainalrami disagrees with bbpPairings and the disagreement is
**not** believed to be an Ainalrami defect. FE1 category 3 — the endorsement
process explicitly provides for escalating these to the SPPC rather than
"fixing" them, so they are kept as files rather than as a paragraph.

Anything in here needs a written position before it can be escalated. Being
in this directory is a claim, not a conclusion; the bar is a second
independent engine agreeing with us.

## `seed735265-r7-p10`

Round 7, 10 players, from the 1,000,000-tournament small-field run
(4-10 players, 15% arbiter byes). **The only case in this project's history
where Gacrux sides with Ainalrami against bbpPairings**, and the last
survivor of the 40 catalogued disagreements — the other 39 were one missing
field in the bootstrap matching and are gone.

    Ainalrami:     [{3, 9}, {5, 1}, {7, nil}, {8, 2}]
    bbpPairings:  [{2, 9}, {3, nil}, {7, 5}, {8, 1}]

The engines disagree about who takes the pairing-allocated bye: ours and
Gacrux's give it to rank 7, bbpPairings' to rank 3.

The adjudicator scores it **`incomparable: 1 vs 2 edges in this bracket`**.

That verdict has moved twice, and the history is the point:

1. It was first scored `theirs_scores_better` on `C2/C4/C5
   bye-eligibility` — read as our own ladder preferring bbpPairings'
   answer while our engine and Gacrux produced the other one, which would
   have meant the ladder or the search was wrong here even if the output
   was right.
2. Re-checked after `explain_round/3` was fixed to stamp float history
   (it had scored C14-C21 blank on both sides of every verdict it ever
   printed): **unchanged**, as expected — that rung sits above C14-C21,
   so the fix could not reach it.
3. Then the verdict itself turned out to be an accounting artifact. Rungs
   SUM over edges, and the two answers contribute a different number of
   edges to this bracket — one against two. A larger sum was being read
   as a better score when it was really just a longer sum. Fixed by
   adding an `edge_count` to `explain_round/3` and a distinct
   `incomparable` verdict rather than folding the case into either side.

So the ladder does **not** prefer bbpPairings' answer. It declines to
compare them, which is the honest result: the two pairings decompose the
bracket differently, and rung vectors over different decompositions are
not commensurable.

That removes the one piece of evidence against filing this. What is left
is a C2 breach visible in the position itself, argued from the
regulations in [`../../../docs/dispute-seed735265.md`](../../../docs/dispute-seed735265.md).

Reproduce from scratch, ~1 second:

    PAIRING_FUZZ_SEED_FROM=735265 PAIRING_FUZZ_COUNT=1 \
      PAIRING_FUZZ_MIN_PLAYERS=4 PAIRING_FUZZ_MAX_PLAYERS=10 \
      PAIRING_FUZZ_BYE_PCT=15 PAIRING_FUZZ_ROUNDS=9 \
      PAIRING_FUZZ_DUMP=repro mix test --only bbppairings

Then `mix run tools/adjudicate.exs repro`.
