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

## What each engine produces

| engine | pairing |
|---|---|
| OpenPair | `{3,9} {5,1} {7,–} {8,2}` |
| Gacrux (`pairingchecker.py -m dutch`, 2026 rules) | same as OpenPair |
| bbpPairings 6.0.0 | `{2,9} {3,–} {7,5} {8,1}` |

The engines agree on nothing structural except the number of boards. The
substantive difference is **who takes the pairing-allocated bye**: rank 7 on
OpenPair's and Gacrux's reading, rank 3 on bbpPairings'.

## Why it is worth escalating

1. **A second independent implementation agrees with the candidate.** Gacrux
   is Otto Milvang's pairing checker, the tool FIDE/TEC itself uses, and it
   is not derived from this project or from bbpPairings. In every other
   disagreement this project has catalogued — 40 of them, across millions of
   tournaments — Gacrux has sided with bbpPairings. This is the only case
   where it has not.
2. **It is the sole survivor.** Across ~4.3 million tournaments and ~195
   million individual pairings spanning field sizes 4–120, round counts
   6–10, arbiter byes, forfeits, `XXP` exclusions and `XXA` acceleration,
   this is the only round on which OpenPair and bbpPairings differ at all.
   It is not a symptom of a general weakness.

## Why it is NOT simply "we are right"

Stated plainly because the FE1 process deserves it, and because omitting it
would be the kind of argument that gets found out.

**Our own criteria ladder prefers bbpPairings' answer.** Scoring both
pairings with `OpenPair.Pairing.explain_round/3` — the same C1–C21 ladder
the engine pairs by — classifies this case as `theirs_scores_better`, with
the first differing rung `C2/C4/C5 bye-eligibility`. So the engine produces
one answer while its own scoring function prefers the other. That is a real
inconsistency inside this implementation, independent of who is right about
the rules, and it needs an explanation before the case is filed.

Re-checked after `explain_round/3` was corrected to stamp float history
(which had left C14–C21 blank on both sides of every verdict): the
classification is unchanged. The deciding rung sits above C14, so the
correction could not have reached it.

## What has to happen before submission

1. **Resolve the internal inconsistency.** Either the search is not reaching
   the pairing the ladder prefers, or the ladder misprices this position.
   Both are findings; neither is settled. Until it is, "our engine and
   Gacrux agree" is a weaker claim than it looks, because our engine is not
   agreeing with our own criteria.
2. **Hand-trace the bye decision against C.04 §C**, from the Handbook text,
   naming the criterion each engine is applying and where they diverge. The
   adjudicator's rung label is a lead, not a citation.
3. **Confirm Gacrux's rules edition.** It selects the 2026 rules by
   default; the run that produced this agreement should be re-done with the
   edition pinned explicitly and recorded.

Only then is this a position paper. Right now it is a well-evidenced
observation with one loose thread, and the loose thread is ours.
