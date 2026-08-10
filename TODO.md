# TODO / Roadmap

## Done

- ~~Project scaffold~~ — mix.exs (escript config), `.formatter.exs`,
  `.gitignore`.
- ~~TRF16/TRF06 file I/O~~ — `OpenPair.Trf`, ported from OpenPairings'
  `PairingsEngine.Trf` (same author, pure module, no Phoenix/Ecto
  dependency to strip). Carries over two real bugs that project found and
  fixed against FIDE's actual archived specs (Annexure-B/2006,
  Annexure-C/2016): the `allow_dangling_playing_code` TRF06 tolerance, and
  `parse_games/1` not stopping at a genuinely blank round. 27 ported tests,
  all passing here too.
- ~~Verbose logging infrastructure~~ — `OpenPair.Log`. Verbose is the
  default (not opt-in), `-q`/`--quiet` suppresses it. `step/1`/`detail/1`
  to stdout, `warn/1`/`error/1` always to stderr regardless of quiet mode.
- ~~CLI skeleton~~ — `OpenPair.CLI`, mirroring JaVaFo's real invocation
  shape (`input.trf -p [output.trf]`, `-g`, `-c`). `-p` calls the real
  pairing engine now (round 1 or the bracket cascade, whichever applies),
  writing the same shape JaVaFo's own output file uses (count line, then
  `white black`/CRLF per pair, `0` for a bye).

## Next: the actual Dutch-system pairing algorithm

This is the real work — everything above is plumbing. Staged so each piece
is independently correct and tested before the next depends on it, rather
than attempting the whole engine in one pass. **Every stage that touches an
actual FIDE rule needs the primary-source handbook text in hand before
writing it** — not memory, not a paraphrase. OpenPairings hit two real bugs
this exact way (Art. 16.4's dummy-score formula, the TRF06 bye convention)
specifically from trusting a plausible-sounding but unverified rule
description; don't repeat that here for something as central as the pairing
logic itself.

1. ~~**Roster split & round 1.**~~ **Done** — `OpenPair.Pairing.pair_round_one/1`.
   Rank order, top-half-vs-bottom-half pairing, odd field's lowest rank
   gets the bye. Colour: Article 5.1's "drawing of lots" has no
   deterministic rule to replicate — confirmed empirically (not assumed)
   that JaVaFo's own initial-colour choice isn't a function of roster/round
   count alone (identical roster + round count under two different
   tournament *names* produced opposite colours from JaVaFo, strong
   evidence of a hash-seeded, non-reproducible-by-us choice) — so this uses
   its own fixed, documented, spec-legal convention instead.

   **Verified against real `javafo.jar`, not just unit-tested against our
   own expectations**: `test/open_pair/javafo_comparison_test.exs`
   (`OpenPair.Test.Javafo`, gated `:javafo`, jar not vendored — see that
   module's doc) generates random rosters (2-60 players) and diffs pairing
   *composition* (colour-blind) against real JaVaFo output, in parallel.
   **20,000/20,000 (100%) matched in a clean run** (`PAIRING_FUZZ_COUNT=20000`,
   run alone — no other JVM-spawning background job competing for the
   machine at the same time). A separate 100,000-roster attempt run
   *while several other fuzz batches were also active* looked like 6.29%
   — that number is meaningless, not a real finding: every one of its
   reported "disagreements" was actually a javafo.jar process failing to
   even launch (Windows exit code `-1073741502` / `0xC0000142`, a
   resource-exhaustion signature) under sustained heavy concurrent load,
   not a genuine pairing mismatch. Confirmed by checking that all 20
   disagreement examples the failure message printed were
   `{:error, code, ""}` tuples, zero real mismatches among them. Lesson
   for next time this needs re-running at even larger scale: run it
   alone, not alongside other `--only javafo` batches.
2. ~~**Bracket cascade for later rounds.**~~ **99.85% match against real
   `javafo.jar`** (5991/6000 random round-1 outcomes; 99.75% on the 2,000
   the scoring was actually tuned against, so the larger set rules out
   overfitting) —
   `OpenPair.Pairing.pair_later_round/1`. Forms score brackets (Art. 1.2:
   score desc, TPN asc) and pairs each via `OpenPair.Matching`'s general
   (non-bipartite) maximum-weight matching-with-floats (memoized bitmask
   DP), scored by `pair_weight/3` and `float_weight/1`.

   **Every scoring term is empirical — measured on the identical
   2,000-history set, not derived from the spec.** The trajectory, in
   order:

   | change | result |
   |---|---|
   | unrestricted exhaustive search, no colour scoring | 0%, and hung past 12 players |
   | + colour preference as a composition criterion | traced case fixed, still hung |
   | bipartite S1-vs-S2 restriction (to fix the hang) | **10.7% — reverted** |
   | general matching + memoization instead | 51.7% |
   | + penalise re-floating an already-floated MDP | 66.24% |
   | + heterogeneous bracket split (Art. 3.3.1, MDPs alone in S1) | 69.1% |
   | + fix: no-colour-preference players were scored as violating | 82.25% |
   | + don't downfloat a player holding an unplayed round | 88.4% |
   | + measure MDP displacement one-sided, not summed | **99.75%** |
   | whole-bracket natural-correspondence deviation vs. rank spread | **64.95% — reverted** |

   Two of those are worth remembering, because both looked obviously
   right and were not:

   - **The bipartite restriction.** Round 1 genuinely does pair "top half
     vs bottom half", so restricting later brackets to the same shape
     seemed safe. It isn't: bbpPairings (`swisssystems/dutch.cpp`)
     computes a weight for ANY two compatible players and uses bracket
     membership as a weighted *bonus*, never a structural exclusion.
   - **Natural-correspondence deviation.** FIDE's procedure really does
     work by minimal transposition of the natural order, and this metric
     explained every hand-traced case — but as a *replacement* for the
     rank-spread tie-break it measured 33.9%, and still only 64.95% when
     retested after every other fix had landed. Scoped to MDP pairs only,
     where Art. 3.3.1 actually applies, the same idea is worth +30
     points. Being "right in principle" decided nothing; scope did.

   The remaining 9/6000 are unexplained. Most likely candidate: the
   float-history criteria that look two rounds back (bbpPairings has four
   such levels, this engine has none), which can only begin to matter
   from round 3 — so a round-3 harness is the honest next measurement
   rather than more round-2 tuning.

   **That measurement happened — see "Depth" below. The hypothesis was
   right, and it was not the only thing wrong.**

## Depth: rounds 3-9

The comparison harnesses were unified into one parameterized file
(`PAIRING_FUZZ_ROUNDS`), because rounds never needed per-round code:
bbpPairings' own generator (`src/tournament/generator.cpp`) is a single
loop over `roundsNumber` calling the identical `computeMatching`. The
harness plays a tournament forward, advancing on JAVAFO's pairing rather
than its own, so every round is an independent measurement against a real
reference history and a disagreement in round 3 can't corrupt round 4.

It also reports **pair-level agreement alongside whole-round agreement**.
At depth the round-level number is nearly useless on its own: one bad
pair in a 20-player field scores exactly as badly as ten.

Starting point, and where it stands now (300 tournaments x 9 rounds,
10-40 players, individual pairs):

| round | start | now |
|---|---|---|
| 1 | 100% | 100% |
| 2 | 99.89% | 99.89% |
| 3 | 91.36% | 99.47% |
| 4 | 68.51% | 99.31% |
| 5 | 74.55% | 98.42% |
| 6 | 60.90% | 97.60% |
| 7 | 66.48% | 94.62% |
| 8 | 56.50% | 93.49% |
| 9 | 62.95% | 91.54% |
| **overall** | **75.68%** | **97.15%** |

Whole rounds: 38.15% → 88.93%. With 10% of games forfeited (a separate,
harder configuration): 94.05% of pairs, 76.96% of rounds.

The harness also checks **legality independently of javafo** — every
player paired exactly once, no rematch, and exactly one bye in an odd
field and none in an even one. That is a different question from
agreement, and it has a right answer. **2699/2700 rounds are legal**; the
one failure is the bounded search giving up and falling back to
best-effort. At the start of this work, 65 of 104 sampled disagreements
were illegal output.

What was actually wrong, in the order it was found. Every step was
measured, and two were reverted on measurement despite being more
elegant:

| change | pairs |
|---|---|
| starting point (HEAD of round-2 work) | 75.68% |
| + full colour model (`computePlayerData` + `insertColorBits`) | 80.64% |
| + float-history criteria (`getFloat`, four levels) | **90.33%** |
| + sum-safe criterion spans | 90.44% |
| + backtracking cascade instead of stranding | **92.92%** |
| + C2 (no second bye) enforced | 92.62% |
| + unplayed-round protection restricted to the bye bracket | 93.61% |
| + several matchings per floater count | **96.11%** |
| + widen the alternative search | 96.47% |
| + forfeit coverage, and the four played/unplayed bugs it found | 96.48% clean |
| + same absolute colour preference made incompatible | 96.97% |
| + final-round exception for top scorers | **97.15%** |

Two bye-eligibility fixes later moved that baseline to 96.36-96.41% pairs
/ 87.50-87.66% rounds on the same 300x9 configuration, which is what the
rows below are measured against:

| change | pairs | rounds |
|---|---|---|
| baseline after the bye-eligibility fixes | 96.36-96.41% | 87.50-87.66% |
| + polynomial matcher, lexicographic tie-break encoded in the weights | 95.92% | 86.40% |
| + next-bracket lookahead as a placeability signal | **96.79%** | **88.97%** |

Also improved on the other two configurations: 8% arbiter-assigned byes
went 92.85% -> 93.50% of pairs and 75.67% -> 77.73% of rounds, and
bbpPairings at 200x9 went 95.92% -> 96.26% and 86.32% -> 87.15%. Zero
illegal rounds throughout.

### A third reference, and which rulebook this engine is actually chasing

`OpenPair.Test.Gacrux` wraps Otto Milvang's `pairingchecker.py` (the
pairing half of the FIDE Tie Break Server, gacrux.no) — a third
independent Dutch implementation, actively maintained, and the tool
FIDE/TEC itself uses to check pairing programs.

Adding it settled something the other two could not. Over 324 comparable
rounds, four engines on identical positions:

| | agreement |
|---|---|
| bbpPairings 6.0.0 vs Gacrux | **100.00%** |
| JaVaFo 2.2 vs bbpPairings | 97.53% |
| JaVaFo 2.2 vs Gacrux | 97.53% |
| OpenPair vs JaVaFo | 89.51% |
| OpenPair vs bbpPairings | 87.96% |
| OpenPair vs Gacrux | 87.96% |

**There are two Dutch rulebooks in play, and this engine is chasing the
older one.** Gacrux states them outright:

    DUTCH_RULES = { 0: "2022-01-01",
                    1: "2026-02-01" }  # Approved by FIDE Council on 01/02/2026

and selects the 2026 one; bbpPairings 6.0.0 likewise implements the
revised rules. They agree with each other PERFECTLY — two independent
implementations, 324 rounds, zero disagreements — while JaVaFo 2.2
differs from both on the same 2.47%. That 2.47% is not engine variance,
it is the 2022 -> 2026 rule change, and every comparison in this file
above was measured against JaVaFo, i.e. against the superseded rules.

The number to steer by from here is the last one: **when all three
references agree, OpenPair matches 89.87%** (284/316). Where they are
unanimous there is no tie to break and no rulebook ambiguity, so that
~10% is genuinely this engine's own gap, and it is the honest measure of
what is left to fix. Everything outside it is a choice about which
rulebook to target, not a bug.

### Two things not to redo

**Do not build a k-best matcher for the cascade's alternatives.** Before
the lookahead, substituting `OpenPair.Matching`'s exhaustive candidate
list for `bracket_candidates/3`'s was worth ~2.9 points of exact rounds,
and the plan was to close that with Chegireddy-Hamacher / Murty
partitioning. It is now worth 0.59 points at 200x9 — 10 rounds in 1684,
about 0.8 sigma — because the placeability signal stops the cascade
stranding a bracket, so it backtracks far less and which alternatives it
holds matters far less. Every knob on that axis is flat: the forced-float
beam at 8, 64 and unbounded all score identically, and so do depths 2, 4
and 6. An unbounded beam at depth 2 already enumerates every floater
pair, so the exact same-count coverage Murty would buy is present and
changes nothing.

**Do not read the next-bracket lookahead as a licence to pair across
brackets.** bbpPairings never finalizes a cross-bracket pair — after its
combined current+next matching it rebuilds the score group's "remainder"
and re-pairs those players within the bracket, and `finalizePair` is only
ever reached for a match inside the group. Emitting cross edges as real
pairings measured 86.40% -> 43.82% of rounds, and porting the rest of
`computeEdgeWeight`'s ladder on top moved it to 42.28%, because the
weights were never the problem. Cross edges also quietly void
`solve_by_cardinality/2`'s guarantee, which is per PAIR COUNT: a cross
edge counts as a pair while meaning a float. The lookahead belongs in
`float_weight/4` as one bit per player — can this player be placed below
if they float — and nowhere else.

**Both of the above still stand, and both are about the DEFAULT
(per-bracket) path. A third entry that used to live here — "the global
cascade cannot be landed incrementally, do it in one piece or not at
all" — has now been acted on and is resolved; see below.**

### The global cascade is now the default, at 95.97%

**Read this first — much of what follows was written while it was still
losing, and is kept because the negative results are worth keeping.**

`global_cascade/2` replaced the per-bracket cascade as the default path.
Against bbpPairings 6.0.0, exact rounds / individual pairs, zero illegal
rounds everywhere:

| field | global (now default) | per-bracket (now fallback) |
|---|---|---|
| 4-40, 200x9 | **95.97% / 98.64%** | 90.29% / 97.21% |
| 60-80, 20x9 | **99.44% / 99.97%** | 82.22% / 97.99% |
| 90-120, 8x9 | **98.61% / 99.87%** | 86.11% / 99.03% |

Against javafo at 4-40 the same swap is 89.31% -> 94.18%, and javafo is
on the superseded 2022 rules, so full agreement there is not the goal.

The gain is largest exactly where it matters: a 60-80 player open is the
ordinary case, and the engine went from getting four rounds in five right
to getting 179 of 180. By round on the 4-40 sweep, r9 went 69.46% ->
86.83% and r8 82.04% -> 91.62%.

`OPENPAIR_GLOBAL=0` selects the per-bracket cascade. It also stays the
automatic fallback — `global_cascade/2` verifies its own result and
returns `:infeasible` rather than emit an illegal round, and the
backtracking search runs then. That matters, because the global path has
no backtracking of its own.

**What actually fixed it: brackets could not see far enough.** The port
followed `dutch.cpp` literally in appending exactly one score group to
the bracket graph. But C8 is "choose the set of downfloaters so that in
the FOLLOWING bracket every criterion from C1 to C7 is complied with",
and a bracket cannot check that against players it cannot see. Peeking
further — the extra groups are visible to the matcher and to C8, never
consumed, and nothing in them can be finalised — is worth:

| peek | 4-40 rounds / pairs |
|---|---|
| 0 groups (the literal reading) | 90.29% / 96.89% |
| 1 | 94.14% / 98.17% |
| 2 | 95.62% / 98.52% |
| 3 | 95.91% / 98.63% |
| 4, 6, unbounded | 95.97% / 98.64% |

Budgeted in PLAYERS (`@peek_budget`, 8) rather than groups, because
groups are the wrong unit: a small field has score groups of one to
three, so four of them is a handful of players; a 60-120 field has groups
big enough that one already supplies the same context, and paying for
four costs 2.6x the time for identical output.

This does NOT contradict "do not read the lookahead as a licence to pair
across brackets" below — that still holds and is still enforced.
`collect_bracket/1` keeps a pair only when both ends are inside the
current bracket. Seeing further and finalising further are different
things, and only the second one ever measured badly.

**How it was found**, since the method mattered more than the fix: the
failure classifier and then `tools/adjudicate.exs`, which scores both
engines' answers with this engine's own ladder. That flagged 47 of 167
failures on one rung, and reducing those to
`test/fixtures/open_questions/` produced two files with an IDENTICAL
bracket graph that bbpPairings answers differently depending on what lies
below. "The bracket's own graph does not determine the answer" is a
statement about visibility, and C8 is the criterion that is supposed to
provide it.

**Remaining: 68 failures at 4-40** (was 164). By cause: float_partner 37,
float_set 28, bye_assignee 2 (was 25), internal_pairing 1 (was 7).
Adjudicated: 41 tie on every rung with the transposition order now split
almost evenly (17/14/10, i.e. noise rather than a systematic tie-break
error), 22 where our ladder prefers our own answer, 5 the reverse. 26 of
the 68 involve C12 — but see `explain_round/3`'s "what it cannot see":
that scorer cannot measure the C8 rungs, which outrank colour, so a C12
verdict is a lead and not a conclusion. `colour_stats/1` was checked
against `computePlayerData` rung for rung and is faithful.

### Historical: the global cascade before the peek fix

`global_cascade/2` is now bbpPairings' bracket algorithm ported stage for
stage (`dutch.cpp` 1011-1649) rather than one matching per score level.
Three things were wrong with the earlier attempt, in descending order of
how much they cost:

  * the graph spanned the **whole remaining field**, so pairs three
    brackets down carried weight and distorted the optimum before being
    discarded. bbpPairings' graph is the current bracket plus the next
    score group and nothing else, and it never gives two moved-down
    players an edge at all (`dutch.cpp:607`).
  * **six of the eight refinement stages were missing** — everything from
    the remainder split through exchange minimisation, which is FIDE §3's
    transposition-and-exchange procedure in executable form.
  * a **non-terminating bracket loop**: bbpPairings can loop
    unconditionally because it has already proved a complete legal
    matching exists, and this engine deliberately carries on when its own
    pre-pass finds none. A final bracket that cannot pair internally span
    forever. Two tests were timing out on this, not on slowness.

| 200x9 vs bbpPairings | rounds | pairs |
|---|---|---|
| global cascade, before | 60.51% | 93.6% |
| global cascade, after | **90.11%** | 96.82% |
| per-bracket cascade (default) | **90.29%** | 97.21% |

+29.6 points, and a dead heat — three rounds in 1689, still behind on
pairs. It stays behind `OPENPAIR_GLOBAL=1` because "level with" is not a
reason to swap out the path every other measurement in this file was
taken against.

**Where to look next, if this is picked up again.** The global cascade
wins mid-event (r3 97.00 vs 93.50, r4 97.40 vs 95.83, r5 94.79 vs 92.19)
and loses late (r7 83.15 vs 84.24, r8 80.24 vs 82.04, r9 66.47 vs 69.46).
Late rounds are where legal pairings get scarce and the per-bracket
cascade's backtracking earns its 15 points of pairs. The global path has
no backtracking by design, because bbpPairings has none — it does not
need any, having proved feasibility up front (`dutch.cpp:825-837`). That
pre-pass is the last structural difference between the two designs and
the obvious next thing to port.

**One finding worth keeping regardless of which path wins.** The
canonical lexicographic tie-break (`lex_scale/1`), worth ~40 points on
the per-bracket path, is completely **inert** under the staged
refinement: removing it and even inverting it both reproduce 1522/1689
and the identical disagreement set. The switch was confirmed live before
this was believed — a bad value raises from inside the run. A tie-break
exists to choose among equally-optimal matchings; after eight staged
solves there is nothing left to choose, which is exactly what
bbpPairings' design claims for itself. It is deleted from that path (and
deleting it is what keeps the bignums small enough to solve a bracket
eight times without paying for it).

C9's rung measures inert too, but it is a real handbook criterion whose
absence was a documented gap, so it stays; it simply never fires in this
fixture set.

### What the 164 remaining failures actually are

`failure_taxonomy_test.exs` classifies every disagreement the comparison
harness counts, by walking the score groups top-down and reporting the
FIRST one where the two engines part company. It replays the harness's
own tournaments and asserts its count against them
(`EXPECTED_DISAGREEMENTS`), so the buckets provably describe the same
population the rates are measured over.

    PAIRING_FUZZ_COUNT=200 PAIRING_FUZZ_ROUNDS=9 \
      EXPECTED_DISAGREEMENTS=164 mix test --only taxonomy

Default path, 200x9, 164 disagreements:

| cause | count | share |
|---|---|---|
| `float_partner` — same players float, different opponent receives them | 70 | 42.7% |
| `float_set` — a different SET of players floats out (C6/C7/C8) | 62 | 37.8% |
| `bye_assignee` — a different player is left unpaired (C5/C2) | 25 | 15.2% |
| `internal_pairing` — same floats, bracket pairs its own members differently | 7 | 4.3% |

**This overturns what this file and docs/fide-criteria.md have both been
calling the largest remaining gap.** That gap is FIDE section 3's
transposition/exchange procedure, which `deviation` and `spread` stand in
for — and pure "same floats, different internal pairing" is
`internal_pairing`, **4.3% of failures**. The global-cascade rewrite was
substantially motivated by implementing that procedure properly. It did,
and it tied, which is exactly what a correct fix to a 4% cause looks
like. The effort was aimed at the wrong target, and only measuring the
aggregate hid that.

**80.5% of failures are float decisions** — who leaves a bracket (62) and
who receives them below (70). `float_partner` being the single largest is
the surprise: the two engines agree on which players downfloat and then
hand them to different opponents. That is MDP-opponent selection, which
on the global path is stage 2 (`stage_mdp_opponents/1`, dutch.cpp
1207-1255) and on the default path is however `float_weight/4` and the
bracket matcher settle an MDP against residents.

**Start with the top bracket.** 24 of the 164 diverge in the FIRST score
group, which inherits no floats and no earlier decision — a divergence
there is an isolated wrong answer, not the downstream consequence of one,
so it should reproduce standalone. **20 of those 24 (83%) are
`float_partner`**, so the largest cause is also the one with the cleanest
available reproductions. First eight: seeds 3/22/32/32/32/53/74/93 at
rounds 8/8/7/8/9/7/9/7.

Ranked by size, the work is: MDP-opponent selection (70), downfloater
choice (62), bye assignment among equal-lowest-score candidates (25),
and transposition/exchange LAST (7).

### Adjudicating those failures against our own ladder

Classifying says WHAT differs; it does not say who is right. So
`Pairing.explain_round/3` reconstructs the brackets any complete pairing
implies and scores it with this engine's own C1-C21 ladder, rung by
labelled rung. Scoring BOTH engines' answers and comparing the first
bracket where they differ splits every disagreement three ways: the
reference scores better (our search failed to reach a pairing our own
ladder prefers), we score better (then the LADDER is wrong, since the
reference would not violate a criterion it implements), or they tie (the
criteria cannot separate them at all and something below decides).

It self-tests: the reconstruction must account for every pair exactly
once, checked on all 167 cases for both engines' answers, so the buckets
cannot be describing a decomposition the engine never used.

|  | default path (164) | global path (167) |
|---|---|---|
| tie on every rung | 119 (72.6%) | 83 (49.7%) |
| reference scores better | 35 (21.3%) | 75 (44.9%) |
| we score better | 10 (6.1%) | 9 (5.4%) |

`OPENPAIR_GLOBAL=1 mix run adjudicate.exs <dump-dir>` (script in the
scratchpad; dumps come from `PAIRING_FUZZ_DUMP`).

### Four things this settled, three of them negative

**1. `deviation` and `spread` are NOT replaceable stand-ins.** This file
and docs/fide-criteria.md both describe them as non-FIDE terms doing the
work of section 3's transposition/exchange procedure, and call replacing
them the largest remaining gap. Removing them measured **90.29% ->
42.21%** of rounds (dropping `spread` alone accounts for essentially all
of it). `spread` maximises rank distance, which is what produces the
S1-vs-S2 halving in the first place — it is load-bearing, not
decorative. Kept, and `ordering_rungs/4` leaves the switch in place.

**2. The canonical tie-break was keyed on the wrong thing, and fixing it
changes nothing.** `lex_scale/1` keys on ABSOLUTE bracket position, which
makes the natural pairing (S1[0] vs S2[0], positions 0 and k) look large
and an adjacent pairing (0 vs 1) look smallest — the opposite of the
Dutch structure. FIDE's rule is lexicographic over S2: which S2 member
faces S1[0], then S1[1]. Both are now implemented
(`transposition_terms/3`, `transposition_key/3`). Measured: **inert on
both paths**, in every variant tried — removed, inverted, and replaced
with the handbook key. On the default path the two forms are provably
equivalent once `spread` has fixed S1/S2 (the tail of the sequence is
determined by its head); on the global path the eight refinement stages
leave no ties for any tie-break to settle.

**3. `isByeCandidate` was wrong on even fields.** bbpPairings only
computes a real `byeAssigneeScore` for an ODD field; for an even one it
stays at its zero initialiser, so `score <= byeAssigneeScore` is false
for anyone who has scored and the top rung collapses to a constant 3 per
edge — pure "maximise pairs". This engine treated a nil bye score as "no
score test", so the rung VARIED on even fields: an edge touching a player
who had already taken a bye outscored one that did not, at the very top
of the ladder, above C6. Fixed. Inert at the harness's default 0% bye
rate, which is why nothing caught it; it should matter with
`PAIRING_FUZZ_BYE_PCT` set.

**4. The remaining failures are NOT the stages dropping pairs.**
`OPENPAIR_TRACE=1` prints the kept-pair count after each of the eight
stages. On the traced cases the count never falls — the initial solve
already produces the answer the round ends with, so the ladder is
choosing it, not a refinement stage losing it.

### The one fully-isolated open case

`seed102-r7-p28`, bracket at score 4.5. Graph is MDP [7] + residents
[5, 9, 27] + next group [1, 14].

  * ours: `{7,5}` internal, `{9,1}` and `{27,14}` crossing — **3 edges**,
    C6 = 1, and 9/27 are finalised one bracket lower instead.
  * bbpPairings: `{7,5}` and `{9,27}` internal — **2 edges**, C6 = 2.

Every legality question is settled: `{1,14}` is a rematch (round 3), so
the 2-internal option genuinely cannot reach 3 edges; `{9,1}` and
`{27,14}` are both legal and colour-compatible for either engine (all
four players are colour-neutral, imbalance 0).

So bbpPairings took strictly FEWER pairs in the bracket graph than it
could have. Our top rung — the completion criterion, `1 + !isByeCandidate
+ !isByeCandidate`, constant per edge on an even field — is maximised by
the 3-edge answer, and it sits above C6 in `computeEdgeWeight` exactly as
it does here. On the reading of dutch.cpp used for this port, bbpPairings
should have chosen ours. It did not, and 47 of the global path's 167
failures are flagged on precisely this rung.

That is the next thing to resolve, and it is a question about what the
completion rung actually maximises, not about the stages: either it is
not summed over cross-bracket edges the way this port assumes, or
something constrains the bracket graph that this port does not model.

**Reduced to a minimal reproducer, and the answer is now measured rather
than inferred** — see `test/fixtures/open_questions/`. Two files with the
identical bracket graph (`{1} 5.0`, `{2,3,4} 4.5`, `{5,6} 4.0` with 5-6
already played), differing only in whether a `{7,8} 3.5` group exists
below it:

| | bbpPairings 6.0.0 | edges | internal (C6) |
|---|---|---|---|
| nothing below | `1-2, 3-5, 6-4` | 3 | 1 |
| a 3.5 group below | `1-2, 3-4, 7-5, 6-8` | 2 | 2 |

The cross edges exist and bbpPairings uses them when the 2-internal
answer would strand 5 and 6. Given anywhere for 5 and 6 to go, it takes
2 internal pairs over 3 edges — **C6 beats edge count**, the opposite of
what `computeEdgeWeight`'s shift order says, and the same bracket graph
yields different answers depending on what lies beyond it.

So the completion rung is not "maximise edges in this graph". Whatever it
is, it is not a property of the bracket graph alone, and that is the
thing to work out next. Everything needed is in the fixture directory's
README, including why OpenPair itself returns nothing for those two files
(an artefact of building scores from arbiter byes, not a second finding).

**Acted on, and it is worth a small win.** `completion_rung/4` now drops
the leading `1` from that term, so it expresses only the bye preference
and stops counting edges, leaving C6 — which it outranks — to decide how
many pairs a bracket keeps. Global cascade, 200x9:

| | rounds | pairs | illegal |
|---|---|---|---|
| `OPENPAIR_COMPLETION=edges` (the literal C++) | 90.11% | 96.82% | 0 |
| eligibility only (now the default) | **90.29%** | 96.89% | 0 |

Zero illegal rounds either way, so removing the explicit edge-count
pressure does not cost completion in practice — the cascade still checks
its own result and falls back rather than emitting an illegal round. That
puts the global cascade level with the per-bracket cascade on exact
rounds (90.29% both) and still 0.3 behind on pairs.

This is the first deliberate divergence from a literal reading of
`dutch.cpp` in this port, taken because bbpPairings' observed behaviour
contradicts the literal reading and the measurement agrees with the
behaviour. The verbatim form stays one env var away.

45 of the global path's disagreements are still flagged on this rung by
the adjudicator, but the term now varies only where bye ELIGIBILITY
genuinely differs rather than wherever the edge count does, so those are
a real C2/C5 signal and the next thing to pull on.

  1. **The colour model was only ever right for round 2.** "Preference is
     the opposite of your last colour" is exactly correct when every
     player has played exactly one game, and wrong from round 3 on, where
     a player can be two colours out of balance or have had the same
     colour twice. Both produce an ABSOLUTE preference the old rule could
     not represent. The tell was that the deficit oscillated with round
     PARITY — only colour balance has a reason to care whether the round
     number is even — and fixing it moved even rounds 12-15 points and odd
     rounds 1.5.
  2. **The float-history criteria were the predicted round-3 cliff**, and
     they behaved exactly as item 4 below predicted: round 3 went 91.36%
     → 99.39%. A float is not recorded in a TRF, it is derived by
     comparing what two players' scores were when they were paired.
  3. **Greedy per-bracket pairing is not globally optimal, and produced
     ILLEGAL output** — two pairing-allocated byes in an even field, in 65
     of 104 sampled disagreements. A bracket that pairs as many of its own
     players as possible can strand a later one holding nothing but a
     rematch. This is the largest single defect the depth work found, and
     it is a correctness bug, not a disagreement.
  4. **"Don't downfloat a player holding an unplayed round" was
     over-generalised.** It came from round-2 tuning, where it was worth
     six points. bbpPairings guards the equivalent criterion with
     `isSingleDownfloaterTheByeAssignee`: it is "minimise the unplayed
     games of the BYE ASSIGNEE", not a standing protection for anyone who
     once had a bye.

Two reverted on measurement, both of which looked cleaner than what they
replaced:

  - **Subordinating the float protections to the pair criteria.** Cost
    seven points and most of round 2. Re-floating protection genuinely
    outranks every pairing criterion, matching bbpPairings placing bye
    eligibility above colour. Only the plain rank tie-break belongs at the
    bottom.
  - **Ordering the cascade's alternatives by weight.** Fewer floats almost
    always outweighs more, so a global sort fills the list with
    one-floater variants and the cascade loses the ability to float MORE
    players when that is the only way to finish the round.

And one bug worth remembering because it was invisible: in
`OpenPair.Matching`, prepending rather than appending a candidate before a
**stable** sort lets it overtake an equal-weight incumbent and silently
inverts a tie-break. Ties are everywhere in this weight scheme. That
one-character difference cost round 2 forty points while leaving every
reported weight identical, and was only localised by setting the
candidate count back to 1 — which should have been behaviourally
identical to the previous commit, and was.

### How close to javafo, and under what conditions

Measured, not estimated. The variable that decides accuracy is NOT the
round number — it is **how much of the field a player has already met**,
i.e. rounds as a fraction of roster size. Opponent exhaustion, not depth.

At 15 rounds, varying only the field (10 tournaments each):

| field | rounds as % of field | pairs | illegal rounds |
|---|---|---|---|
| 18-20 | ~83% | 79.45% | 26/150 |
| 26-28 | ~57% | 86.03% | 17/150 |
| 34-36 | ~44% | 90.62% | 8/150 |
| 44-46 | ~34% | 95.80% | 1/150 |
| 60-70 | ~22% | 97.76% | 1/150 |

A 60-70 player field over 15 rounds is 97.76% — as good as the 9-round
number. A 32-40 player field over 30 rounds collapses to 62.89% with
1477/2997 rounds illegal. Same engine, same depth of history; the
difference is entirely how many legal opponents remain.

So for real events: a 9-round Swiss in a 40-player field, or a 15-round
blitz in a 60+ field, both sit near 97%. A 20-round event in a 30-player
field does not work at all.

**Fixed by augmenting-path repair, then closed almost the rest of the
way by adding blossom contraction to it.** When the cascade gives up, the
greedy fallback's result now gets a general-graph maximum-matching pass
applied to it (`OpenPair.Blossom`), which pairs up players it left over.

First pass — plain alternating-path BFS, no blossom handling — took
illegal rounds at 30 rounds from **1477/2997 to 65/2997**, every round
through 22 legal. The 65 that remained were not random misses: they were
specifically the cases a blossom-blind search structurally cannot reach,
where the only augmenting path runs through an odd cycle. Confirmed by
building `OpenPair.Blossom` (a direct port of the standard O(V^3)
reference algorithm — see that module's doc) and swapping it in with no
other change: **65/2997 -> 1/2997**, every round through 29 legal.
blossom's own correctness was checked against a brute-force
maximum-matching oracle on 25 random small graphs plus a hand-verified
odd-cycle case, all passing, before it was wired in.

Pair agreement moved 62.89% -> 61.09%, the same trade as before: the
rounds that changed were illegal and are now legal, and a legal round
that differs from javafo is worth more than an illegal one that happens
to share boards with it. The nine-round measurement was 97.15% going into
this step, since the repair only ever runs on rounds the cascade failed.

**The one remaining illegal round turned out to be a real bug, not a
search-budget limit** — worth recording since the previous paragraph
guessed budget with more confidence than the evidence supported. Tracing
it (seed 39, 32-player field, round 30) found OpenPair leaving two
players unpaired despite a full pairing existing, confirmed reachable at
all by temporarily disabling colour compatibility entirely, which found
one immediately.

The actual cause: `final_round_topscorers?/2`'s threshold used
`expected_rounds` where bbpPairings' own formula (`dutch.cpp:53-56`,
`topScoreThreshold = playedRounds * pointsForWin >> 1`) uses
`playedRounds` — rounds actually played, not the tournament's eventual
length. Those are genuinely different numbers even in the one round this
exception can ever fire in (the final round, where `playedRounds` is
always `expectedRounds - 1`): `floor((expectedRounds-1)/2)` is one lower
than `floor(expectedRounds/2)` whenever `expectedRounds` is even, so the
old formula silently admitted top-scorer exceptions for players who were
one point short of actually qualifying.

One-line fix (`div(played_rounds, 2)` in place of `expected_rounds / 2`).
Re-measured:

  9 rounds, 10-40 players:    97.15% -> 97.19% of pairs, 2 -> 0 illegal
  30 rounds, 32-40 players:   1 -> 0 illegal, EVERY round legal

**2997/2997 legal rounds** — every round, across the hardest
configuration measured in this project so far.

**The failure mode was legality, not disagreement.** The two rise together
because they are one event: when the bracket cascade cannot find a legal
completion inside its bounded search it falls back to greedy, and greedy
output is both an illegal bye count and unrelated to javafo's. Raising
`@cascade_budget` 25x does not help — it makes the search intractable
instead, because a bounded depth-first search over per-bracket
alternatives is the wrong tool when the constraint is global.

This is the strongest argument yet for the global-matching item below:
bbpPairings runs one matching over the whole field FIRST, specifically to
prove a legal round exists.

### What bbpPairings actually uses, and why the obvious shortcut fails

Settled from its own source rather than inferred. `src/matching/computer.h`
documents itself as "the basic algorithm presented in *'An O(EV log V)
Algorithm for Finding a Maximal Weighted Matching in General Graphs,'* by
Zvi Galil, Silvio Micali, and Harold Gabow, 1986", implemented at O(n^3)
with an incremental-update modification. The `blossomimpl.h` /
`parentblossom.cpp` / `rootblossom.cpp` layout is that paper's blossom-tree
decomposition. So it is genuinely the full primal-dual weighted blossom
algorithm — there is no simpler variant hiding in bbpPairings either.

**Bracket sizes say we may not need it.** Measured over 40 generated
tournaments (2504 brackets, 2136 adjacent pairs):

| | median | p90 | p99 | max | over 20 |
|---|---|---|---|---|---|
| single bracket | 4 | 11 | 30 | 58 | 1.9% |
| current+next combined | 9 | 19 | 34 | 43 | 8.6% |

91.4% of combined bracket-pairs fit inside the exact subset DP that is
already in the tree and already weighted. Weighted blossom is what lets
bbpPairings do this at ANY size; at our sizes it is mostly unnecessary.

**But naively merging the two brackets measured 97.19% -> 58.48%** (150
tournaments, 9 rounds) with 7 unit tests failing, so it is not a drop-in.
The reason is specific: `natural_partner_map/1` and `mdp_deviation/4`
assume ONE score tier with floaters sitting above it. Merge two score
groups and the entire lower group becomes "residents" to a doubled MDP
set, which scrambles the S1/S2 natural correspondence those criteria are
defined against. Reverted.

So the remaining path is real design work, not a patch: redefine the
natural-correspondence machinery for a multi-tier bracket before the
merge can be attempted again. That is the actual blocker — not the
matching algorithm, which the DP already covers at these sizes.

**Update:** the matching algorithm itself is no longer a blocker even for
sizes past the DP's reach. `OpenPair.WeightedMatching` is a from-source
port of the actual Galil/Micali/Gabow primal-dual algorithm described
above (read from bbpPairings' `src/matching/detail/{graph,rootblossom,
parentblossom}.cpp`, not reconstructed from memory), verified against
`OpenPair.Matching`'s independent subset-DP oracle across 900+ random
graphs (`weighted_matching_test.exs`) including cases dense enough to
require both blossom formation and blossom expansion. It is NOT wired
into `Pairing` yet — that still waits on the natural-correspondence
redesign above, since a wider matcher alone doesn't fix the S1/S2
scrambling a merged bracket causes.

### Still open at depth

Rounds 7-9 sit at 89-92% of pairs. Known gaps, in the order most likely
to matter:

  - ~~The four SCORE-WEIGHTED float criteria~~ — **implemented, measured
    WORSE, reverted.** `dutch.cpp` 385-460 weights each float criterion
    by which score group it affects, ranked below the four unweighted
    ones. Ported faithfully (positional weights per score group, lowest
    group at index 0, sum-safe base) it measured **93.40%** against
    97.15%. Disabling just the two "scores of the opponents of
    upfloaters" halves gave 93.27%, so it is the whole family, not one
    bad member.

    The likely reason it does not port: in bbpPairings these criteria are
    guarded by `lowerPlayerInCurrentBracket` and the score groups are
    TOURNAMENT-wide, because its matching spans the current bracket AND
    the next one. Only a subset of edges get the term, and "which score
    group" means something relative to the whole field. In a matcher that
    runs over one bracket at a time, every edge gets it and the group
    index is bracket-local, so the criterion stops discriminating the way
    it does there and just adds noise at high priority.

    Worth retrying only if the cascade is ever replaced by a global
    matching — the two changes are coupled.
  - ~~Half-point byes, zero-point byes and retirements need a protocol
    change~~ — **done, and they were expressible after all.** There is no
    TRF flag for "not playing this round"; the mechanism is that the
    arbiter records the result IN ADVANCE and the engine then leaves that
    player out (`dutch.cpp:658`, `if (player.matches.size() <=
    tournament.playedRounds)`). This engine paired them anyway, so a
    player who had asked for a bye got a game — confirmed against javafo
    on a six-player case. `PAIRING_FUZZ_BYE_PCT` now generates them;
    92.86% of pairs at 8%, with 2/1797 illegal rounds.

    **Update:** those 2/1797 (and a fresh 3/2119 re-measurement) turned
    out to be genuine deadlocks, not search misses — confirmed by an
    independent exhaustive search restricted to the true active player
    set for each case (a small field deep into a Swiss, colour-absolute
    exclusions stacking on top of near-exhausted rematch-free opponents).
    `repair_bye_count/3` was silently returning that still-illegal
    pairing instead of recognising it as unsolvable; it now raises
    `OpenPair.Pairing.NoValidPairingError`, matching bbpPairings'
    own `NoValidPairingException` (`dutch.cpp`'s `compatible`/
    `matchingIsComplete` never accept more byes than
    `rem(active_count, 2)` either — they throw instead).
    `OpenPair.Generator` catches it and truncates the tournament at the
    last round that actually completed. Re-verified end to end via the
    generator itself: **0 illegal rounds across 800 generated
    tournaments (~5500 rounds) at mixed bye rates 0/5/8/15%.**

    The round count needed care: neither the minimum games count (breaks
    on a late entrant, who has none, and empties the pairing) nor the
    maximum (breaks on the pre-recorded bye being detected) works.
    bbpPairings only advances `playedRounds` for games the player
    PARTICIPATED IN THE PAIRING for — a real game or a pairing-allocated
    bye, never an arbiter-assigned one (`trf.cpp:339-342`,
    `opponent != id || resultChar == 'U' || resultChar == '+'`).
  - The cascade approximates a global matching. bbpPairings runs one over
    the whole field first, to prove a legal round exists at all.
  - The bracket-ordering terms (MDP displacement, rank spread) still stand
    in for FIDE's transposition/exchange procedure and bbpPairings' three
    lowest criteria.
  - ~~The harness still generates only wins, losses, draws and byes.~~
    **Done for forfeits** (`PAIRING_FUZZ_FORFEIT_PCT`, default 0). It
    found four bugs of one family immediately, all of them code that had
    never executed: a forfeit carries an opponent AND a colour but is
    legally unplayed, and four call sites asked "is there an opponent /
    a colour" instead of "did this game happen". Worst of them was C1:
    a forfeited pairing does NOT forbid a rematch (`dutch.cpp:664`
    guards forbiddenPairs with `if (match.gameWasPlayed)`), confirmed
    against javafo re-pairing two double-forfeiters in preference to two
    rematch-free alternatives. With 10% of games forfeited, pair
    agreement went 69.86% -> 88.67% -> **93.76%**. Half-point byes,
    zero-point byes and retirements are still open, and need a protocol
    change: they are decided BEFORE pairing, so the harness would have to
    withhold those players from the TRF rather than record a result.
  - The old note, for the record: the harness generated only wins,
    losses, draws and byes.
    bbpPairings' generator also produces forfeits, retirements and
    half-point byes (`generator.h`'s `forfeitRate`, `retiredRate`,
    `halfPointByeRate`) — a real coverage gap, deliberately left out of
    the depth work so a rate change could be attributed to depth alone.

   **Historical detail on how each fix was found** (each caught by the
   previous revision's own comparison run):

   1. *Unrestricted exhaustive search, no colour scoring* — failed
      consistently (0/10). Hand-traced 18-player case (seed 3): a
      same-score bracket with zero rematch conflicts still didn't match
      javafo.jar — javafo picked the pairing where every pair had
      complementary colour preferences (one wants white, one black, from
      round-1 colours), over an equally rematch-legal one that didn't.
      Colour preference decides pairing composition, not a step applied
      after composition is fixed.
   2. *Unrestricted exhaustive + colour scoring* — seed-3 fixed, but the
      search re-explored the same subsets with no bound (confirmed 194ms
      at 12 players, didn't finish in 60s at 16 in a real comparison run).
   3. *Bipartite reformulation* (S1 better-half vs S2 worse-half, solved
      as bipartite matching — same structure round 1 uses) — fixed the
      hang, but was **confirmed WRONG at scale**: only 10.7% matched over
      2000 random histories, including a regression on the seed-3 case
      that matched exactly in revision 2. Cloning bbpPairings locally
      (`AuroraRyunix/bbpPairings-source`, independent/open/Apache-2.0) and
      reading `swisssystems/dutch.cpp` explained why: it computes a
      weight for ANY two compatible players (Edmonds' Blossom algorithm
      over the whole field), using bracket/S1-S2 membership as a WEIGHTED
      BONUS in that computation, never a hard structural exclusion. The
      bipartite restriction was a real modelling mistake, not a
      simplification.
   4. *General (non-bipartite) matching, kept tractable via memoization*
      (current) — restores correctness (2000-history re-run: 51.7%, up
      from 10.7%) without reintroducing the unbounded-search hang, at the
      cost of being exponential in the WHOLE bracket size again (not half,
      unlike revision 3) — see `OpenPair.Matching`'s moduledoc for the
      actual complexity trade-off and where this could still be slow. The
      SAME 2000-history run's remaining disagreements pointed at one more
      concrete gap: two engines can agree a player must float down two
      bracket levels in the same round, yet pick a *different* one to do
      it — javafo strongly prefers floating a bracket's own fresh
      resident over re-floating a player who already floated once this
      round (an MDP), matching bbpPairings' own "minimise downfloaters"
      criterion. `cascade_brackets/3` now stamps `:already_floated` on a
      bracket's own unpaired players before they enter the next bracket,
      and `float_weight/1` penalises that flag heavily. Confirmed fixed on
      the specific case that surfaced it (seed 15), and re-run clean at
      scale: **66.24% at 5,000 random round-1 outcomes** (0 process
      errors — checked directly, see the round-1 100k lesson above about
      not trusting a number without checking for that), up from 51.7%
      before this fix, consistent with the earlier 66.3% at 1,000. A
      real, stable number — not yet 100%, but a genuine three-fix
      trajectory (0% → 51.7% → 66.24%) with each step independently
      confirmed, not a guess.

   Also fixed a real pre-existing bug the seed-3 investigation surfaced
   (revision 1): `colour_preference/1` and `assign_colour_with_history/1`
   were matching atoms (`:white`/`:black`) against `OpenPair.Trf`'s actual
   `"w"`/`"b"` string convention — colour history was *silently never
   applied* before this, every decision quietly falling through to the
   round-1 fixed convention.

   *(The seed-15 case that this section previously flagged as an
   unexplained spread-tie-break mystery was resolved by the one-sided MDP
   displacement fix — it was never a spread problem.)*
3. **Absolute criteria [C1]-[C5] partly covered.** No-repeat pairing
   (`legal_pair?/2`) and ~~no-second-bye~~ **C2 (`eligible_for_bye?/1`,
   done)** are enforced; topscorer-colour clash and
   bye-assignee-score-minimisation are not.
4. ~~**Float-history criteria (two rounds back).**~~ **Done** — see
   "Depth" above. The prediction in this item held exactly: the criteria
   cannot bind before round 3, and round 3 was the measured cliff
   (91.36% → 99.39% of pairs). Four levels ported from `dutch.cpp`'s
   `getFloat`; the four SCORE-WEIGHTED variants are still open.
5. ~~**Colour allocation & floater history refinement**~~ **Done** —
   Article 5.2's full preference-strength computation is ported
   (`colour_stats/1` from `computePlayerData`, `choose_colour/2` from
   `choosePlayerNeutralColor`), including absolute/strong/mild strength
   and the absolute colour-difference rules.
6. **Checker (`-c`)** — ~~JaVaFo's FPC role~~ **done**. Replays a
   completed tournament, re-pairs each round from the state before it, and
   diffs. Exits nonzero on any composition difference; colour differences
   are reported but never errors.

   One belief this corrected: a checker is NOT "a verifier against every
   criterion", as this item used to claim. bbpPairings' own checker
   (`tournament/checker.cpp`) clears the matches, replays, and calls
   `computeMatching` — it re-runs the ENGINE and defines correct as what
   the engine produces. So a checker cannot tell a legal-but-different
   pairing from an illegal one, and building one does not give an
   independent oracle for the residual disagreement rate. The harness's
   own `illegality/2` remains the only independent legality check here.

   ~~**RTG (`-g`)**~~ **done** — `OpenPair.Generator`. Random roster,
   played forward with this engine pairing each round, optional forfeits
   and arbiter-assigned byes. Seeded and reproducible, with the seed
   written into the generated file's own tournament name (bbpPairings
   puts it on line one, which would not be valid TRF).

   The generator pairs with the engine under test on purpose, matching
   bbpPairings' own RTG: the point of an RTG in FE1's auto-test is to
   produce tournaments whose pairings a REFERENCE checker then verifies,
   so they have to be the candidate program's own.

   Both halves of FE1's auto-test apparatus now exist. What does NOT
   exist is a reason to run it: FE1 only asks for FPC/RTG when "Internal
   engine: YES", endorsement for OpenPair is explicitly deferred below,
   and the bar is one difference per 500 tournaments against a current
   rate near 11% of rounds.
7. **Team pairing.** Depends on OpenPairings' own team-tournament work
   landing first (see that project's `TODO.md`) — team-level Swiss/
   round-robin scheduling, then per-board pairing within a scheduled match.
8. **Acceleration variants beyond Baku**, alternate tiebreak orderings —
   the actual point of building a second engine in the first place, per
   the original "too many gimmicks" / "hard pairing variants" discussion in
   OpenPairings.

## Cross-validation against bbpPairings

**Done, and measured** — `OpenPair.Test.Bbppairings` +
`bbppairings_comparison_test.exs`, the same methodology as the javafo
harness (play a tournament forward, diff each round, advance on the
REFERENCE engine's own answer). Uses OpenPairings' already-vendored
`priv/bbppairings/bbpPairings-windows.exe` (v6.0.0, official release),
located the same way `javafo.jar` is (`BBPPAIRINGS_EXE` env var,
defaulting to that sibling path) — not vendored into this repo either.

Two integration details that only showed up by actually running it, not
by reading the source:

- Output format is byte-identical to javafo's own (`count\r\n` then
  `white black\r\n` per pair, `0` for a bye) — no separate parser needed.
- Unlike javafo, bbpPairings does not choose the first round's colour on
  its own; it refuses to pair at all without an explicit `152 W`/`B`
  field whenever no player has a colour recorded yet. And it signals "no
  legal pairing exists" differently too — exit code 1 with no output
  file, versus javafo's empty-pairs-file-at-exit-0 — its own documented
  error code 1, "no valid pairing exists for the current round". Modelled
  as a distinct `{:no_valid_pairing, message}` return, handled the same
  way as javafo's exhaustion case (tournament ends early, round excluded
  from the rates, not counted as a mismatch).

**First real measurement** (200 tournaments × 9 rounds, 4-40 players):

| round | exact rounds | individual pairs |
|---|---|---|
| 1 | 100.00% | 100.00% |
| 2 | 100.00% | 100.00% |
| 3 | 98.00% | 99.28% |
| 4 | 95.83% | 98.87% |
| 5 | 88.54% | 96.80% |
| 6 | 85.03% | 96.00% |
| 7 | 78.26% | 93.60% |
| 8 | 67.66% | 91.50% |
| 9 | 55.09% | 86.45% |
| **overall** | **86.32%** | **95.92%** |

**0 illegal rounds** — independent confirmation of the legality fix two
commits up: bbpPairings agreed OpenPair's structural-deadlock cases really
were unpairable (its own exit code 1, on byte-identical input, for the
exact case that motivated that fix).

Slightly lower than the javafo depth number (97.19% pairs / 88.93% rounds,
albeit a different 300×9 sample) but the same shape — rounds 1-2 exact,
gradual divergence at depth. One representative disagreement (seed 25,
round 4, 5 players) was hand-traced against the bracket/downfloat/
bye-eligibility rules: OpenPair's answer matches a direct reading of
those rules; bbpPairings' differs in a way consistent with its
whole-field weighted matching trading bracket locality for some other
criterion — not an obvious defect, and consistent with the
already-documented gap that the bracket cascade approximates Art
3.3-3.5's exact transposition search rather than replicating it. A full
census of all 231 disagreements from that one run, and which of them
trace to genuine gaps versus legitimate rule variance, has NOT been done
— that's the natural next increment here, the same iterative way the
javafo depth work found float-history, the colour model, and the C1
forfeit-rematch rule.

Once OpenPair is wired back into OpenPairings as a selectable engine, this
harness should run as a *third* comparison arm there too, not just
standalone here.

## Explicitly deferred / not being pursued yet

- Any FIDE endorsement application for OpenPair itself. It's meant to stay
  a non-default, non-homologated-tournament-only option inside
  OpenPairings, at least until (if ever) it's genuinely proven out — see
  the endorsement-risk discussion in OpenPairings' own project history.
- A license file / open-source release. Undecided.
