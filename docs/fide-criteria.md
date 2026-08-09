# FIDE (Dutch) System criteria — primary source, and what this engine does

Source: **FIDE Handbook C.04.3, "FIDE (Dutch) System", effective 1 February
2026** (<https://handbook.fide.com/chapter/C0403202602>), plus the
definitions it inherits from C.04.1 Basic Rules for Swiss Systems.

Written down here because this project's rule is that anything touching a
FIDE rule needs the handbook text in hand rather than a paraphrase, and
because the numbering itself is new: the February 2026 revision introduced
a **unified criteria numbering** (C1-C21) that the older 2022 text did not
have. Quoting it once, here, means the next person does not re-derive it
from a C++ bit layout.

## Which rulebook this engine targets

**The 2026 one.** There are two live Dutch rulebooks and the references do
not agree about which they implement:

| engine | rulebook |
|---|---|
| JaVaFo 2.2 | 2022-01-01 |
| bbpPairings 6.0.0 | 2026-02-01 |
| Gacrux (FIDE TBS) 1.9.57 | 2026-02-01 (`DUTCH_RULES[1]`, "Approved by FIDE Council on 01/02/2026") |

Measured over 324 comparable rounds, bbpPairings and Gacrux agree with each
other **100%**, while JaVaFo differs from both on the same 2.47%. That
2.47% is the rule change, not engine variance — so "disagrees with JaVaFo"
is no longer evidence of a bug, and the number to steer by is agreement
with the two 2026 implementations.

## Definitions (C.04.1)

- **MDP** (moved-down player) — a player who remained unpaired in a bracket
  and was transferred to the next one.
- **Resident** — a player coming from the current scoregroup being paired.
- **Downfloater** — a player left unpaired in a bracket and moved to the
  next for pairing.
- **Topscorer** (Art. 1.8) — a player scoring over 50% of the maximum
  possible score **when pairing the final tournament round**. Note the
  qualifier: outside the final round there are no topscorers at all.

## Absolute criteria — never violated

| | text | this engine |
|---|---|---|
| C1 | Two participants shall not play against each other more than once. | `legal_pair?/2` |
| C2 | A participant who has already received a pairing-allocated bye, or has already scored in one single round without playing as many points as rewarded for a win, shall not receive the pairing-allocated bye. | `eligible_for_bye?/1`, plus a near-absolute penalty in `float_weight/4` |
| C3 | Non-topscorers with the same absolute colour preference shall not meet. | `colour_compatible?/2` with `final_round_topscorers?/2` as the carve-out |
| C4 | *(Completion Criterion)* A pairing complying with all the absolute criteria shall always exist for all players not yet paired. | the `cascade_brackets/4` backtracking search; `NoValidPairingError` when genuinely impossible |
| C5 | *(PAB Criterion)* Minimise the score of the assignee of the pairing-allocated-bye. | `bye_assignee_score/2` — a whole-field pre-pass fixing the bye's score, enforced in `cascade_brackets/4`'s base case |

## Quality criteria — in descending priority

Verbatim from §2.4, with this engine's implementation beside each.

| | text | this engine |
|---|---|---|
| C6 | Minimise the number of downfloaters *(equivalent to: maximise the number of pairs)*. | `spans.locality` |
| C7 | Minimise the scores (taken in descending order) of the downfloaters. | `downfloater_scores/1` at candidate level, plus `spans.score_paired` per pair |
| C8 | Choose the set of downfloaters so that in the following bracket every criterion from C1 to C7 is complied with. | default path: `placeable_below/1`, a weak approximation, see gaps. `OPENPAIR_GLOBAL=1`: real C8 rungs over real next-bracket edges |
| C9 | Minimise the number of unplayed games of the assignee of the pairing-allocated-bye. *(Applies to brackets downfloating exactly one player receiving the bye.)* | the `unplayed` term in `float_weight/4`, gated on `bye_bracket?` |
| C10 | Minimise the number of topscorers or topscorers' opponents who get a colour difference higher than +2 or lower than -2. | `colour_criteria/2` bit 1 — **not restricted to topscorers** |
| C11 | Minimise the number of topscorers or topscorers' opponents who get the same colour three times in a row. | `colour_criteria/2` bit 2 — **not restricted to topscorers** |
| C12 | Minimise the number of players who do not get their colour preference. | `colour_criteria/2` bit 3 |
| C13 | Minimise the number of players who do not get their strong colour preference. | `colour_criteria/2` bit 4 |
| C14 | Minimise the number of resident downfloaters who received a downfloat the previous round. | `float_criteria/2` f1 |
| C15 | Minimise the number of MDP opponents who received an upfloat the previous round. | `float_criteria/2` f2 |
| C16 | Minimise the number of resident downfloaters who received a downfloat two rounds before. | `float_criteria/2` f3 |
| C17 | Minimise the number of MDP opponents who received an upfloat two rounds before. | `float_criteria/2` f4 |
| C18 | Minimise the score differences (taken in descending order) of MDPs who received a downfloat the previous round. | `float_score_criteria/3` s18 |
| C19 | Minimise the score differences (taken in descending order) of MDP opponents who received an upfloat the previous round. | `float_score_criteria/3` s19 |
| C20 | Minimise the score differences (taken in descending order) of MDPs who received a downfloat two rounds before. | `float_score_criteria/3` s20 |
| C21 | Minimise the score differences (taken in descending order) of MDP opponents who received an upfloat two rounds before. | `float_score_criteria/3` s21 |

### On "minimise" versus this engine's maximising weights

The handbook phrases every quality criterion as a MINIMISATION over the
players left unpaired or mispaired; `ranked/1` maximises over the pairs
actually formed. These are the same statement seen from opposite sides —
pairing a player who downfloated last round is exactly how you avoid
counting them among C14's repeat downfloaters — which is why the criteria
appear here as rewards on an edge rather than penalties on a float.
bbpPairings' `computeEdgeWeight` does the same inversion.

## Known divergences from the handbook

1. **C8 is only approximated on the DEFAULT path. The global cascade
   implements it properly, and now measures level with the default.**
   The handbook requires the chosen downfloater set to leave the
   *following* bracket able to satisfy C1-C7. This engine only asks whether
   each candidate downfloater has at least one legal, colour-compatible
   opponent waiting below (`placeable_below/1`) — strictly weaker: C1/C3
   feasibility for one player, not C1-C7 compliance for a bracket.

   Attempt one scored each candidate by the pair COUNT the following
   bracket could reach. Inert ranked low, a regression ranked high, no
   fixture moved. Fixture 6 explains it: JaVaFo drops one 3.5 player two
   brackets while the 2026 answer drops two players one bracket each, and
   both leave the same NUMBER of pairs available, so a count cannot
   separate them.

   Attempt two therefore scored `{count, scores descending}` — C6 *and* C7
   one bracket ahead, which does separate fixture 6's two options. It still
   loses, and by more the higher it is ranked:

   | candidate ordering | rounds | pairs |
   |---|---|---|
   | baseline (no C8 term) | 89.93% | 97.08% |
   | C8 below the packed weight | 89.88% | 97.07% |
   | C8 above the packed weight | 88.28% | 96.64% |

   So the measure is not the problem either. What the same experiment DID
   find is that C7 stated explicitly at candidate level is worth **+0.36
   exact rounds** on its own (89.93% -> 90.29%) — see the C7 row above.
   Running both together scored 89.34%, C7's gain cancelled by C8's loss,
   which is what sent this apart into separate measurements.

   Reverted, twice. The remaining hypothesis is structural rather than
   about scoring: choosing between one double-float and two single-floats
   needs three brackets in view at once, and `bracket_options/3` peeks
   exactly one ahead by construction. Widening that lookahead is not a
   one-line change either, because the peeked bracket deliberately
   contributes no edges — it survives only as `placeable_below/1`'s
   per-player bit (see `pair_weight/4`), so a second peeked bracket would
   merely make that bit MORE permissive, which is the wrong direction.

   **The structural hypothesis was then tested directly, and it holds.**
   `global_cascade/2` (behind `OPENPAIR_GLOBAL=1`) is bbpPairings'
   architecture ported stage for stage: the graph is the current bracket
   plus the whole next score group, and each bracket is solved up to eight
   times, every solve answering one question and freezing the answer
   before the next is asked. C8 stops being a lookahead in that design —
   it falls out of the C8 rungs being on real edges to real next-bracket
   players, rather than a per-player feasibility bit.

   | 200x9 vs bbpPairings | rounds | pairs |
   |---|---|---|
   | global cascade, single solve per level | 60.51% | 93.6% |
   | global cascade, all stages ported | 90.11% | 96.82% |
   | global cascade, completion rung corrected | **90.29%** | 96.89% |
   | per-bracket cascade (still the default) | **90.29%** | 97.21% |

   So the missing 30 points really were the refinement, as predicted, and
   a further correction to the completion rung (see TODO.md, and
   `test/fixtures/open_questions/`) brings it level with the default on
   exact rounds. It remains 0.3 behind on pairs.

   The split by round says where the rest is: the global cascade is
   *better* mid-event (r3 97.00 vs 93.50, r4 97.40 vs 95.83, r5 94.79 vs
   92.19) and worse late (r7 83.15 vs 84.24, r8 81.44 vs 82.04, r9 67.07
   vs 69.46), which
   is where legal pairings run short and the per-bracket cascade's
   backtracking — measured at 15 points of pairs by itself — pays for
   itself. bbpPairings needs no backtracking because it proves a complete
   legal matching exists before it starts (`dutch.cpp:825-837`, throwing
   `NoValidPairingException` otherwise); that pre-pass is the obvious next
   thing to port, and the last real difference between the two designs.

   One finding from the port is worth recording on its own: **the
   canonical lexicographic tie-break is inert under the staged
   refinement.** Removing it, and even inverting it, reproduce 1522/1689
   and the same disagreement set exactly — verified against a live switch,
   since a bad value raises from inside the run. In the per-bracket
   cascade the same tie-break is worth ~40 points, because a
   maximum-weight matcher may return any optimum and something has to
   choose. After eight staged solves there is nothing left to choose,
   which is precisely the claim bbpPairings' design makes for itself.

2. ~~**C10/C11 are not restricted to topscorers.**~~ **Investigated and
   withdrawn — this is not a divergence.** The reasoning looked sound:
   both criteria are about "topscorers or topscorers' opponents", Art. 1.8
   makes topscorers exist only when pairing the FINAL round, and Gacrux
   guards them explicitly with `if (a["top"] or b["top"])` while this
   engine does not.

   But bbpPairings does not guard them either — `insertColorBits` gates on
   `inCurrentScoreGroup`, never on topscorer status — and bbpPairings
   agrees with Gacrux 100%. The two are reconciled by C3: two
   non-topscorers with the same absolute colour preference may never meet
   at all, so the C10/C11 bits can only ever fire where C3 already permits
   the pairing, which is exactly the topscorer cases. Gacrux gates
   explicitly; bbpPairings lets the absolute criterion do it; the outcome
   is identical.

   This engine takes bbpPairings' route (`colour_compatible?/2` enforces
   C3, with `final_round_topscorers?/2` as its carve-out) and
   `colour_criteria/2` is a faithful port of `insertColorBits`, condition
   for condition. Adding a topscorer gate would be redundant, and would
   risk diverging if the two C3 implementations ever disagreed at the
   edges. Left alone deliberately.

3. **`deviation` and `spread` are not FIDE criteria.** They sit mid-ladder
   in `within_bracket_weight/4` and do the work the handbook assigns to a
   different mechanism entirely — §3's transposition and exchange
   procedure, which picks among pairings that are already equal on every
   criterion by taking the smallest transposition of the natural order.
   Replacing these two with that procedure is the largest remaining gap,
   and the one this project's TODO has long described as "approximate
   bracket-ordering vs FIDE's exact transposition search".

4. ~~**C5 is not enforced explicitly.**~~ **Closed.** The prediction that
   "these coincide in ordinary cases; whether they can diverge has not been
   tested" turned out to be testable and false. Diffing JaVaFo against
   bbpPairings/Gacrux surfaced a 5-player round-2 case where the 0.5
   bracket held two players who had already met: keeping the top bracket
   whole left the bye on a 0.5 player when a 0.0 player was reachable, and
   the 2026 answer breaks the top bracket up because C5 is ABSOLUTE and C6
   is only quality. Now implemented as `bye_assignee_score/2`, a single
   whole-field matching run before any bracket is paired -- affordable only
   because the bracket matcher is polynomial now.
