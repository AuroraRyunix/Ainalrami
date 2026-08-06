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
other change: **65/2997 -> 1/2997**, every round through 29 legal. The
one remaining case is very likely the search-budget cap rather than a
matching gap — blossom's own correctness was checked against a brute-force
maximum-matching oracle on 25 random small graphs plus a hand-verified
odd-cycle case, all passing, before it was wired in.

Pair agreement moved 62.89% -> 61.09%, the same trade as before: the
rounds that changed were illegal and are now legal, and a legal round
that differs from javafo is worth more than an illegal one that happens
to share boards with it. The nine-round measurement is untouched at
97.15%, since the repair only ever runs on rounds the cascade failed.

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

Explicit ask, not optional polish: **fully parse and fuzz-test against
bbpPairings** (Bierema Boyz Programming's independent, Apache-2.0-licensed
Dutch-system implementation, already vendored in OpenPairings at
`priv/bbppairings/` for its own `cross_program_test.exs` harness). Port that
same pattern here once stage 1-3 above produce real pairings:

- Generate synthetic rosters/histories (`StreamData` property-style, same
  approach as OpenPairings' `trf_property_test.exs`).
- Pair each one with both OpenPair and bbpPairings on byte-identical TRF16
  input.
- Diff every round's actual pairing, not just final legality — a
  same-score-group-splitting disagreement (the exact class of thing the
  OpenPairings/JaVaFo/bbpPairings harness already found) is the
  interesting signal, not a crash.
- Treat a disagreement as a research question first ("which one, if
  either, is actually right per the current Handbook text"), not an
  automatic bug in OpenPair — bbpPairings and JaVaFo don't always agree
  with each other either.

Once OpenPair is wired back into OpenPairings as a selectable engine, this
harness should run as a *third* comparison arm there too, not just
standalone here.

## Explicitly deferred / not being pursued yet

- Any FIDE endorsement application for OpenPair itself. It's meant to stay
  a non-default, non-homologated-tournament-only option inside
  OpenPairings, at least until (if ever) it's genuinely proven out — see
  the endorsement-risk discussion in OpenPairings' own project history.
- A license file / open-source release. Undecided.
