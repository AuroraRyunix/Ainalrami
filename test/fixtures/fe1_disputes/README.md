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

## `seed8848759-r9-p10`

Round 9, 10 players, found 11.6 million rounds into the 2026-08-19 run
(4-10 players, 15% arbiter byes, seeds from 7,000,001 — a different range
from the one above). Gacrux again sides with Ainalrami.

    Ainalrami:     [{1, 4}, {3, nil}, {5, 2}, {7, 10}]
    bbpPairings:  [{1, 2}, {3, 5}, {4, nil}, {7, 10}]
    Gacrux:        [{1, 4}, {3, nil}, {5, 2}, {7, 10}]

**This one needs no adjudication.** Ranks 6, 8 and 9 carry arbiter byes for
the round, leaving seven active players and one pairing-allocated bye to
give. Four of the seven — 2, 4, 5 and 10 — already hold one, so C2 leaves
three eligible: 1, 3 and 7. And rank 4 has met every active player except
rank 1:

| rank | pts | already had a PAB | unplayed, among active |
|---|---|---|---|
| 1 | 5.5 | no | 2, 4 |
| 2 | 3.5 | **yes** | 1, 3, 5, 10 |
| 3 | 4.0 | no | 2, 5, 7 |
| 4 | 2.5 | **yes** | **1** |
| 5 | 2.0 | **yes** | 2, 3, 7, 10 |
| 7 | 5.0 | no | 3, 5, 10 |
| 10 | 3.0 | **yes** | 2, 5, 7 |

So rank 4 must be paired — C2 bars the alternative — and 1-4 is the only
pairing they have. Every candidate that does not contain 1-4 strands rank 4
into a second bye. bbpPairings pairs 1-2, and byes rank 4.

The bye then goes to one of 1, 3, 7, and C5 (minimise the assignee's score)
picks rank 3 on 4.0. That is what both other engines return.

Pinned by `test/ainalrami/c2_second_bye_test.exs`, which asserts the forced
pair and that the assignee had no earlier bye — a test rather than a file,
because a change that made this engine agree with bbpPairings here would
show up in the corpus as an improvement.

## `seed7073463-r8-p9`

Round 8, 9 players, from the random-acceleration axis of the 2026-08-20
run (seeds from 7,000,001). Gacrux sides with Ainalrami again.

    Ainalrami:     [{2, 1}, {4, 8}, {6, nil}, {9, 7}]
    bbpPairings:  [{4, 2}, {6, 1}, {8, nil}, {9, 7}]
    Gacrux:        [{2, 1}, {4, 8}, {6, nil}, {9, 7}]

**The strongest of the three.** The round has exactly one legal shape and
it falls out by pure elimination — there is no scoring step to argue
about, and C5 never gets a say.

Ranks 3 and 5 sit the round out on arbiter byes, leaving seven active.
Four of those seven already hold a pairing-allocated bye, so [C2] requires
each of them to be paired:

| rank | pts | already has a PAB | unplayed, among active |
|---|---|---|---|
| 1 | 3.5 | **yes** | 2, 6, 9 |
| 2 | 4.0 | **yes** | 1, 4 |
| 4 | 3.5 | no | 2, 8 |
| 6 | 5.0 | no | 1, 7 |
| 7 | 4.5 | no | 6, 9 |
| 8 | 2.5 | **yes** | **4** |
| 9 | 2.5 | **yes** | 1, 7 |

Then, one forced step at a time:

1. rank 8 holds a bye and has one opponent left → **4–8**
2. rank 2 holds a bye and now has one left → **2–1**
3. rank 9 holds a bye and now has one left → **9–7**
4. rank 6 is all that remains, and is eligible → **bye**

bbpPairings pairs 4–2, which consumes rank 8's only opponent and leaves it
nowhere to go but a second bye.

Worth noting what this case is NOT: rank 6 on 5.0 is the HIGHEST-scoring
active player, and C5 asks for the bye to go to the lowest. It goes to 6
anyway because C2 is absolute and eliminates everyone else — a good
reminder that the criteria are lexicographic, not a weighted blend.

Pinned by `test/ainalrami/c2_second_bye_test.exs`, which asserts all three
forced pairs, not just the bye.
