# Rules-interpretation dispute: `seed735265-r7-p10`

Position paper for FE1 category 3 — a disagreement between endorsed
implementations that the candidate program believes is a reading of the
rules rather than a defect. FE1 provides for escalating these to the SPPC
rather than requiring the candidate to change.

Status: **not yet submitted.** This is the argument as it stands, written so
it can be checked rather than taken on trust.

## The position

Round 7 of a 10-player Swiss, 15% arbiter-bye rate, from the generated
corpus. The file is
`test/fixtures/fe1_disputes/seed735265-r7-p10.trf`; reproduce it in about a
second with:

    PAIRING_FUZZ_SEED_FROM=735265 PAIRING_FUZZ_COUNT=1 \
      PAIRING_FUZZ_MIN_PLAYERS=4 PAIRING_FUZZ_MAX_PLAYERS=10 \
      PAIRING_FUZZ_BYE_PCT=15 PAIRING_FUZZ_ROUNDS=9 \
      PAIRING_FUZZ_DUMP=repro mix test --only bbppairings

## The position

Ten players, six rounds played, pairing round 7 of 9. Ranks 4, 6 and 10 hold
arbiter-assigned half-point byes for this round, so seven players are active
and one of them must take the pairing-allocated bye.

| rank | pts | bye-eligible | history |
|---|---|---|---|
| 1 | 2.5 | **no** (`U` r3) | 6w0 10b= –U –H 7w0 –H |
| 2 | 2.0 | **no** (`U` r6) | 7b= 5w0 10w0 –Z 3b= –U |
| 3 | 1.5 | **no** (`U` r2) | 8w0 –U 5b0 –Z 2w= 6b0 |
| 5 | 4.5 | yes | 10w= 2b1 3w1 8b1 4w= 9b= |
| 7 | 3.0 | yes | 2w= –H 4b0 9w0 1b1 10b1 |
| 8 | 4.0 | yes | 3b1 6b1 –H 5w0 –H 4b1 |
| 9 | 3.5 | yes | 4w0 –H –H 7b1 10w1 5w= |

Three of the seven — ranks 1, 2 and 3 — have **already taken a
pairing-allocated bye**, so C.04's absolute criterion barring a second one
leaves exactly four candidates: 5, 7, 8 and 9.

## What each engine produces

| engine | pairing | bye to |
|---|---|---|
| OpenPair | `{5,1} {8,2} {3,9}` | **7** — eligible |
| Gacrux (`pairingchecker.py -m dutch`, 2026 rules) | same as OpenPair | **7** |
| bbpPairings 6.0.0 | `{7,5} {8,1} {2,9}` | **3** — *already byed in round 2* |

Both readings seat all seven players, and neither contains a rematch. The
substantive difference is who takes the bye — and bbpPairings' choice gives
a **second** pairing-allocated bye to rank 3.

Run directly against the binary rather than taken from the harness:

    bbpPairings.exe --dutch seed735265-r7-p10.trf -p out.txt   # exit 0
    4
    7 5
    8 1
    2 9
    3 0

## bbpPairings honours this rule in general

Which is what makes the case worth filing rather than dismissing as a
misreading of its intent. `tools/bye_probe.exs` builds the minimal version —
three players, rank 1 already holding a `U`, ranks 2 and 3 both eligible —
and bbpPairings pairs rank 1 and byes rank 3, exactly as OpenPair does. Its
`eligibleForBye` (`common.h:104-118`) disqualifies any unplayed game worth at
least a win, which a pairing-allocated bye is at default point values, and
nothing in this file changes those: the only configuration line present is
`152 W`, which sets the round-one colour convention (`trf.cpp:1179-1198`) and
has no bearing on points.

So this is not bbpPairings implementing a different rule. It is bbpPairings
implementing the same rule and, in this position, reaching a pairing that
breaks it while a fully legal alternative exists — the one OpenPair and
Gacrux both produce.

## Why it is worth escalating

1. **The reference's own answer appears to violate an absolute criterion**,
   in a position where a legal alternative exists and two other engines find
   it. That is a stronger claim than a tie-break preference, and it is
   checkable in one command by anyone assessing the case.
2. **A second independent implementation agrees with the candidate.** Gacrux
   is Otto Milvang's pairing checker, the tool FIDE/TEC itself uses, and it
   is not derived from this project or from bbpPairings. In every other
   disagreement this project has catalogued — 40 of them, across millions of
   tournaments — Gacrux has sided with bbpPairings. This is the only case
   where it has not.
3. **It is the sole survivor.** Across ~4.3 million tournaments and ~195
   million individual pairings spanning field sizes 4–120, round counts
   6–10, arbiter byes, forfeits, `XXP` exclusions and `XXA` acceleration,
   this is the only round on which OpenPair and bbpPairings differ at all.
   It is not a symptom of a general weakness.

## Why it is NOT simply "we are right"

Stated plainly because the FE1 process deserves it, and because omitting it
would be the kind of argument that gets found out.

This section previously read "our own criteria ladder prefers bbpPairings'
answer", on the strength of an adjudicator verdict of `theirs_scores_better`
at the rung labelled `C2/C4/C5 bye-eligibility`. **That verdict was an
artifact and has been withdrawn.**

Each bracket's rungs are a SUM over the pairs it keeps plus the pairs
reaching into the next score group, and the top rung's leading term is one
per edge. In the first bracket where these two answers differ, OpenPair
contributes one edge and bbpPairings two — OpenPair floats rank 7 onward
where bbpPairings pairs 5 with 7. So every rung in that bracket differs by
that accounting alone, including the top one, whose label names bye
eligibility and whose difference here has nothing to do with bye
eligibility.

`explain_round/3` now reports an `edge_count` per bracket and the
adjudicator refuses to name a deciding rung when the two do not match. The
same case re-adjudicated returns `incomparable: 1 vs 2 edges in this
bracket`, which is the honest answer.

So there is no longer a known inconsistency between this engine and its own
ladder on this position. What there is instead is a diagnostic that could
not compare these two answers at all, and said something confident anyway.
Every verdict in TODO.md produced by that path deserves the same scepticism
until re-run — see the note there.

## What has to happen before submission

1. ~~**Resolve the internal inconsistency.**~~ **Done** — it was the
   diagnostic, not the engine. See above.
2. **Hand-trace the bye decision against C.04 §C**, from the Handbook text,
   naming the criterion each engine is applying and where they diverge. The
   adjudicator's rung label is a lead, not a citation.
3. **Confirm Gacrux's rules edition.** It selects the 2026 rules by
   default; the run that produced this agreement should be re-done with the
   edition pinned explicitly and recorded.

Only then is this a position paper. Right now it is a well-evidenced
observation with one loose thread, and the loose thread is ours.
