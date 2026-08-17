# Conformance record: C.04.3 FIDE (Dutch) System, effective 1 February 2026

Article-by-article verification of this engine against the rules text
(<https://handbook.fide.com/chapter/C0403202602>, approved by the FIDE
Council 28/10/2025), checked 2026-08-17.

This exists because until that date the engine's rules had been derived from
**bbpPairings' source code** and confirmed by **measurement** — 4.3 million
tournaments, 195 million pairings — but not read off the regulations. Two
bugs fixed the same day (the top-scorer threshold, and `W` in the
bye-disqualifying list) were found that way and are confirmed below by the
text, independently.

Where a row says "exact", the code's condition and the article's condition
were compared term by term, not merely observed to agree.

## Definitions

| article | rule | implementation | verdict |
|---|---|---|---|
| 1.2 | Order: score, then TPN ascending | `Enum.sort_by(&{-&1.points, &1.rank})` | exact |
| 1.4.3 | A downfloat is given to a PAB recipient, or to anyone who without playing scores more than a loss | `float_direction/4`: an unplayed round is `:down` when `result_points > 0.0` | exact |
| 1.7.1 | Absolute preference: CD > +1 or < −1, **or** same colour in the two latest rounds played | `absolute? = imbalance > 1 or not is_nil(repeated)`, `repeated` set when `consecutive > 1` | exact |
| 1.7.2 | Strong preference: CD = ±1 | `strong? = not absolute? and imbalance > 0` | exact |
| 1.7.3 | Mild preference: CD = 0, alternate from the previous game | `preference` ladder falls through to `invert(last)` | exact |
| 1.7.4 | A player with no games has no preference | `preference` is `nil` only for a never-played player | exact |
| 1.8 | Topscorer: **over** 50% of the maximum possible score, final round only | `points > played_rounds / 2`, gated on `played_rounds >= expected_rounds - 1` | exact — see note 1 |

## Absolute criteria (2.1)

| article | rule | implementation | verdict |
|---|---|---|---|
| C1 | Two participants shall not play each other more than once | `legal_pair?/2`, gated on `played?/1` | exact |
| C2 | A participant who has already received a PAB, **or has already scored in one single round, without playing, as many points as rewarded for a win**, shall not receive the PAB | `@bye_disqualifying_results ~w(U F +)` | exact — see note 2 |
| C3 | **Non-topscorers** with the same absolute colour preference shall not meet | `colour_compatible?/2` refuses the pair unless `final_round_topscorers?/2` | exact |

## Completion, PAB, and quality criteria

| article | rule | implementation |
|---|---|---|
| C4 | A pairing complying with the absolute criteria shall always exist for all players not yet paired | `check_completion/3`, with `repair_completion/3` as the whole-field fallback; `NoValidPairingError` when genuinely impossible |
| C5 | Minimise the score of the PAB assignee | `bye_assignee_score/2` computes the minimum achievable over the whole field, then `bye_score_ok?/1` enforces it — see note 3 |
| C6 | Minimise downfloaters (maximise pairs) | `"C6 pairs in bracket"` rung |
| C7 | Minimise the scores of the downfloaters | `"C7 scores paired"`, graded by score group |
| C8 | Choose downfloaters so the following bracket complies with C1–C7 | the two `"C8 … next bracket"` rungs, over edges reaching the immediately following score group (`reach == 1`) |
| C9 | Minimise the unplayed games of the PAB assignee. *Applies to brackets that downfloat exactly one player, who will receive the PAB* | `"C9 bye unplayed games"`, gated on `single_bye?` — the gate is the article's own restriction, not an optimisation |
| C10, C11 | Minimise topscorers/their opponents with \|CD\| > 2, or the same colour three times running | `"C10"`/`"C11"` rungs, reachable only through the final-round path |
| C12, C13 | Minimise disregarded colour preferences / strong preferences | `"C12"`, `"C13"` rungs |
| C14–C17 | Minimise repeated downfloats (residents) and upfloats (MDP opponents), at r−1 and r−2 | `float_criteria/2` |
| C18–C21 | The same four, by score difference rather than count | `float_score_criteria/3` |

## Notes

**1 — the topscorer threshold.** "Over 50% of the maximum possible score"
means the maximum available *so far*, not the tournament's eventual total.
FIDE TEC's worked companion (*Mastering the Dutch*, 2026, footnote 27) is
explicit: "in a nine-round tournament the maximum score before the last
round is eight points. So, a topscorer is a player who has 4.5 points or
more." That is `points > played_rounds / 2`, an exact half with a strict
comparison, against the tournament's played rounds. This engine used
`div(played_rounds, 2)` — a floored half — and the player's own game count,
until 2026-08-17. Both errors are invisible whenever the played-round count
is even, which every fuzz axis before that date happened to be.

**2 — C2's second limb is "without playing".** So `U` (PAB), `F`
(full-point bye) and `+` (forfeit win) disqualify; `H` and `Z` do not,
because neither scores a win's worth; and an ordinary win never does,
however it is spelled. TRF16 allows the letter form `W` for a played win,
and this engine had `W` in the disqualifying list until 2026-08-17 on the
reading that it meant an *unplayed* win. The article settles it.

**3 — C5 is enforced as a constraint, which the rules do not require.**
2.3 places C5 outside the absolute criteria, and 3.8.1 treats it as the
highest-priority *comparison* — "a candidate is better than another if it
better satisfies the PAB Criterion … or a quality criterion of higher
priority". This engine instead precomputes the minimum achievable PAB score
over the whole field and then refuses any candidate that misses it. The two
are equivalent **provided the precomputed minimum is genuinely achievable**,
which is what `bye_assignee_score/2`'s bootstrap matching establishes. It is
the same shape bbpPairings uses. Recorded here because it is a deliberate
divergence in mechanism, not in outcome.

## Known structural divergence

Articles 3.5–3.8 and 4 describe pairing a bracket by **generating candidates
in a defined sequence** — transpositions of S2, then exchanges between S1 and
S2, in a specified order — and taking the first perfect one, or the best
under 3.8.1 with "generated earlier in the sequence" as the final tie-break.

This engine instead solves each bracket as a maximum-weight matching whose
edge weights pack C1–C21 in priority order, which reaches the same optimum
without enumerating candidates. The two agree on which pairing is *best*;
they differ in how ties below every criterion are broken, since 3.8.1's last
resort is generation order and this engine's is `transposition_key/3`'s
lexicographic key over S2 indices.

That approximation is the largest remaining gap between this implementation
and the letter of the regulations. It has never produced a measured
disagreement with bbpPairings — 4.3M tournaments, one disagreement, and that
one is a case where bbpPairings breaches C2 (see
`docs/dispute-seed735265.md`) — but "not observed" is not "cannot happen",
and this is the place it would come from.

`OpenPair.Sequence` implements Article 4's ordering itself, checked against
every worked example the article gives, so the oracle for closing this now
exists. What does not exist is the differential test that would use it.

### Why that test is harder than it looks

The obvious version — enumerate every legal round-pairing, score each with
the ladder, check the engine picks an optimal one — was built and thrown
away, because the question it asks is not one the regulations answer.

**The rules define no global optimum over whole-round pairings.** They
define a sequential procedure: brackets are paired in order, each bracket's
candidate chosen as best given the downfloats it inherits (3.3-3.8), and the
result carried forward. "The best pairing of the round" is whatever that
procedure produces. It is not the argmax of a function over complete
round-pairings, and asking which round-pairing scores highest is a question
with no defined answer.

Two symptoms of asking it anyway, both hit immediately:

* the ladder is defined **per bracket**, and bracket composition depends on
  which players a pairing floats — so two round-pairings produce different
  bracket structures and their rung vectors are not commensurable. That is
  the same defect `explain_round/3`'s `edge_count` guard exists to catch,
  one level up.
* an enumerator is only as good as its legality test. The discarded one
  checked C1 and neither C2 nor C3, so it reported "legal pairings the
  engine refused" — it had admitted illegal ones. A weaker oracle accusing a
  stronger implementation is the expected result, not a finding.

**A valid test has to run per bracket**, comparing candidates within one
bracket against a fixed set of incoming MDPs, which is where the regulations
actually define an ordering. That means wiring `OpenPair.Sequence` into the
bracket loop rather than around the round. That is the remaining work on
this gap, and it is real work rather than a script.
