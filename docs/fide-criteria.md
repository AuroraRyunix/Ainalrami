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
| C7 | Minimise the scores (taken in descending order) of the downfloaters. | `spans.score_paired` / `spans.score_place` |
| C8 | Choose the set of downfloaters so that in the following bracket every criterion from C1 to C7 is complied with. | `placeable_below/1` — a weak approximation, see gaps |
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

1. **C8 is only approximated, and the obvious strengthening does not
   work.** The handbook requires the chosen downfloater set to leave the
   *following* bracket able to satisfy C1-C7. This engine only asks whether
   each candidate downfloater has at least one legal, colour-compatible
   opponent waiting below (`placeable_below/1`) — strictly weaker: C1/C3
   feasibility for one player, not C1-C7 compliance for a bracket.

   The natural fix was tried and reverted. Scoring each candidate by the
   largest number of pairs the following bracket could form with those
   downfloaters added — C6 evaluated one bracket ahead, and genuinely
   stronger than `placeable_below/1`, which cannot tell two players sharing
   a single possible opponent from two who each have their own — measured:

   * ranked above the packed criterion weight: 89.93% -> 89.46% of rounds
   * ranked below it: 89.93% -> 89.93%, i.e. inert
   * either way it fixed none of the eight rule-delta fixtures, and cost
     3x the runtime on a 90-player field

   Reverted: a costly no-op is worse than an acknowledged gap. The position
   problem is real but not the whole story — C8 belongs between C7 and C9,
   and this engine bundles C6, C7 and C9-C21 into one packed integer per
   PAIR while C8 is a property of the whole downfloater SET, so there is no
   position in the sort that is faithful.

   The deeper reason it cannot work in the current shape is visible in
   fixture 6 (seed 22, round 9, 21 players). JaVaFo drops player 19 from
   the 3.5 group TWO brackets to meet player 1 in the 2.5 group; the 2026
   answer instead drops 11 one bracket and 2 one bracket, two single steps
   rather than one double. Choosing between those requires seeing three
   brackets at once, and `bracket_options/3` peeks exactly one ahead. C8 is
   therefore blocked on the lookahead depth, not on the scoring — worth
   knowing before anyone attempts it again from the weight side.

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
