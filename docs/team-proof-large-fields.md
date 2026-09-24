# C.04.6 whole rounds on large fields: an exact reference

Written 2026-09-23. Code: `test/support/team_proof/exact_reference.ex`
(`Ainalrami.TeamProof.ExactReference`), `test/support/team_proof/blossom.ex`
(`Ainalrami.TeamProof.Blossom`); tests: `test/ainalrami/team_proof_large_test.exs`,
`test/ainalrami/team_proof_blossom_test.exs`.

## Why

The whole-round proof in `test/ainalrami/team_pairing_validation_test.exs`
checks the engine against a deliberately naive second implementation of
Articles 3.4-3.6 and 4 (`Ainalrami.TeamProof.NaiveReference`, moved to
`test/support` unchanged). It enumerates every upfloater subset and every
bracket pairing, so it stops at about ten teams. Fields of 12-60 teams were
checked only on the absolute criteria ([C1]-[C3] and Article 4), which says
a round is legal, not that it is the round C.04.6 defines.

The exact reference computes the SAME definition as the naive one - same
readings, same output, same recorded reasons - in polynomial time, so the
engine can be compared with it round for round up to 80 teams.

## Independence

- It shares no code with `Ainalrami.TeamPairing.*`, `Ainalrami.WeightedMatching`
  or `Ainalrami.Matching`.
- Its one algorithmic tool is `Ainalrami.TeamProof.Blossom`, a minimum-cost
  perfect matching written for it: an Edmonds primal-dual blossom algorithm
  following the structure of van Rantwijk's public-domain `mwmatching.py`
  (Galil 1986, O(n^3)). The engine's weighted matcher is a port of
  bbpPairings' Galil/Micali/Gabow code, and its feasibility checks are a
  greedy pass plus memoised search - a different lineage and a different
  method.
- It reuses the naive reference's Article 4 (`ref_colours/4`,
  `ref_numbers/2`, `ref_preference/1`): per pair, already polynomial, and
  itself written from the text. So Article 4 at 11-80 teams is checked
  against the same reading as at 4-10 teams, not against a third one.
- Events are still PLAYED by the engine (each round's result applied, then
  the next round paired from it), exactly as in the whole-round test. That
  only chooses which reachable histories get checked; it decides nothing
  about the round being checked.

## Readings (the naive reference's, unchanged)

- [C1]: two teams have met when either lists the other.
- 3.4: [C2] first, then lowest score, most matches played (played colours),
  largest TPN; the first that leaves the rest pairable (3.4.1).
- [C4] then [C5] judged over LEGAL sets: the bracket pairable and the teams
  left behind pairable ([C1], [C3]).
- [C5] maximises the upfloaters' scores taken in ascending order (open
  question 5: the article, not the 3.5.4 example).
- [C6] minimises how many more upfloaters than the parity minimum the
  following scoregroup (the highest score among the lower teams) would
  need; 0 when every team of that score floated.
- [C7] minimises upfloaters that floated last round, before 3.5.4's order
  (open question 7); off in the last two rounds, as is [C10].
- 3.6: least {C8, C10} (C8 first), then the smallest identifier. [C10]
  counts per team (each floated team facing an upfloater).
- Type A colour preferences only; primary score = match points; 4.2.2 on.

Agreement with the engine therefore proves the engine computes THESE
readings. It says nothing about whether the readings are FIDE's - that is
what `docs/conformance-c0406-teams.md` argues.

## The method, and why it is exact

### 1. Lexicographic counts are one integer

Every comparison the naive reference sorts by is lexicographic over
non-negative counts. Give each count a digit in a mixed-radix integer whose
base for that digit exceeds the largest total the count can reach in any
perfect matching, and integer order IS lexicographic order - no digit can
carry into the next. The bound used (`solve/4`): for each digit, the sum
over vertices of the largest value on an edge at that vertex; every edge of
a perfect matching is counted at least once. When every count is a sum over
a matching's edges, "least in the order" is "cheapest perfect matching".

### 2. Upfloater sets are matchings of the whole remaining field (3.5)

Let R be the residents, L the lower teams. S is legal when R+S and L-S both
pair without rematches.

*Claim.* If S is legal and no legal set is smaller, then in every pairing
of R+S every member of S faces a resident.

*Proof.* If two members of S were paired together, removing both from S
leaves S' with R+S' still pairable (drop that pair) and L-S' pairable (add
that pair to L-S's pairing). S' is legal and smaller. Contradiction.

So the legal sets of minimal size are exactly "the lower teams matched to a
resident" in the perfect matchings of R+L that use fewest resident-lower
edges. On those matchings:

| digit | per resident-lower edge (lower team l) | per lower-lower edge |
|---|---|---|
| `k` - [C4] | 1 | 0 |
| `{c5, i}` - [C5], one digit per score level, lowest level first | 1 if l is on level i | 0 |
| `u` - [C6] | 0 | 1 if exactly one end has the following score |
| `c7` - [C7] | 1 if l floated last round (0 in the last two rounds) | 0 |
| `pos` - 3.5.4 | 2^\|L\| - 2^(\|L\| - p), p = l's place in (score desc, TPN) | 0 |

- [C5]: all candidate sets have the same size, and "maximise the ascending
  score list" is then "fewest on the lowest level, then the next" - a
  lexicographic count vector.
- [C6]: for a fixed S the fewest upfloaters into the following scoregroup
  is, by the same claim one level down, the fewest edges between that
  scoregroup and the teams below it in a perfect matching of L-S; the
  matching of R+L carries both at once, so minimising `u` jointly
  minimises [C6] over S. The naive value is (|U| - parity) / 2, and the
  parity (how many of the following score stay behind) is the same for
  every set with [C5]'s optimum, so minimising |U| is minimising [C6].
- 3.5.4: within a [C5] class every set has the same number from each
  score, so the sets' TPN lists sorted by (score desc, TPN) compare
  lexicographically exactly as the sets compare by "smallest differing
  element by place" - which is the largest sum of 2^(\|L\| - place).

One matching therefore returns the chosen set. The recorded reason ([C4],
[C5], [C6], [C7] or 3.5.4 - what decided between the chosen set and the
best other legal set) takes at most three more: add a last digit `other`,
1 on a resident-lower edge to a member of the chosen set S*, and ask
whether another set with the named digits at their optimum exists (its
`other` total is then below |S*|). Another set in the {C4, C5} class with
equal {C6, C7} -> 3.5.4; else one with equal [C6] -> C7; else any other in
the class -> C6; else another legal set of the same size -> C5; else C4.

### 3. Identifier order is a sum too (3.6)

3.6.2's identifier is the top members sorted, then the bottoms in the tops'
order. Every pairing of a bracket has the same number of tops, so:

1. **Tops.** Among equal-sized sets, the one whose sorted list is
   lexicographically first contains the smallest element of the symmetric
   difference - the larger sum of 2^(m - index). One matching with digits
   `c8`, `c10`, `tops` (2^m - 2^(m - index of the smaller TPN)) returns
   least {C8, C10} and, among those, the first top set.
2. **Bottoms.** Confined to edges from that top set to the rest (smaller
   TPN on top), one more matching with digits `c8`, `c10`, `bottoms`
   (bottom's rank x h^(h - 1 - top's rank)) returns the lexicographically
   first bottom sequence. The reference asserts the second matching
   reaches the same {C8, C10} as the first.

### 4. The bye (3.4)

The naive order, with pairability decided by a perfect matching instead of
by trying every partner.

### Cost

A round is: one matching per bye candidate tried (almost always one), then
per bracket one matching for the upfloaters, at most three for its reason,
and two for 3.6. The naive reference enumerates every subset and every
pairing.

## How the reference itself was validated

1. **The matcher** against an exhaustive bitmask DP: 3,000 random graphs,
   0-16 vertices, densities 0.15-1.0, costs {0,1}, 0-3, 0-1000 and up to
   2^300 (`team_proof_blossom_test.exs`), plus 80-vertex graphs with a
   planted zero-cost matching. Every answer is also checked on the way out
   to be a perfect matching of the given edges with the claimed cost.
2. **The reference against the naive reference** on every round the
   whole-round generator plays: 2,000 seeds of 4-10 teams, 8,273 rounds,
   reasons included - no disagreement (2026-09-24,
   `TEAM_PROOF_NAIVE_SEEDS="1..2000"`).
3. **Sensitivity.** Three deliberate mutations of the reference were each
   caught by step 2: [C6] and [C7] swapped (first caught at seed 817), the
   3.6 top-set digit removed (seed 39), and [C7]'s reason query dropping
   [C6] (seed 8). The comparison is not vacuous.

## Results: the engine against the exact reference, 11-80 teams

Measured 2026-09-24 (scale mode, 11-80 teams):

| engine 3.6 budget | seeds | rounds | result |
|---|---|---|---|
| default | 1-125 | - | every round agrees; seed 126 is the first disagreement (below) |
| raised (`TEAM_PROOF_ENGINE_MAX_CANDIDATES=10000000`) | 1-300 | 1,825 | every round agrees, reasons included |
| raised | 1-479 | - | every round agrees; seed 480 is the first disagreement |

Every disagreement found is the one below. None was a different reading
or a wrong criterion: with the search exhaustive, the engine's round was
the exact reference's.

## The disagreement: 3.6's candidate budget

The engine's 3.6 search (choosing among a bracket's pairings by [C8],
[C10] and the identifier) stops after a candidate budget and keeps the best
pairing found. When the budget runs out before the first compliant pairing
in 3.6's order is reached, the engine's round is a legal round that C.04.6
does not choose. The test reports it as "engine 3.6 search NOT exhaustive
(candidate budget)" rather than as a wrong answer, because the engine
itself says it did not finish.

- **Default budget:** seed 126, round 3, 55 teams (8 absent), the 2-point
  bracket.
- **Budget raised to 10,000,000 candidates:** seed 480, round 3, 68 teams
  (10 absent), the 2-point bracket. Raising the budget moves the first
  occurrence but does not remove it: a large bracket in an early round
  (many teams on the same score) has more candidate pairings than any
  fixed budget.

What would remove it is a 3.6 search that is exact by construction, as the
reference's is (two minimum-cost matchings per bracket, section 3 above),
instead of an enumeration with a budget. That is an engine change, not
made here.

## Running it

    # default suite: 300 seeds against the naive reference, 12 events of 11-80
    mix test test/ainalrami/team_proof_large_test.exs

    # scale mode (the long run's large-field axis)
    TEAM_PROOF_SEEDS="1..500" mix test test/ainalrami/team_proof_large_test.exs --only whole_rounds_large
    #  -> TEAMPROOF seeds=500 rounds=M ; a failure message starts "seed N,"

    # knobs: TEAM_PROOF_SIZES="20,40" (field sizes drawn), TEAM_PROOF_TIMINGS=1
    # (rounds and reference ms per ten-team band, outside scale mode),
    # TEAM_PROOF_ENGINE_MAX_CANDIDATES=N (raise the engine's 3.6 budget, to
    # look past the known disagreement), TEAM_PROOF_NAIVE_SEEDS / _SIZES.

On this machine every `mix` run here used `ELIXIR_ERL_OPTIONS="+S 2:2"`.

## Limits - what is NOT proven

- Everything above is SAMPLED: seeded, played events. "Agrees on N rounds"
  is the claim; not "agrees on every round of every event".
- Type A only; match points as primary score; the secondary score used by
  4.2.2; the default `matches_played` (played colours). Type B's [C9],
  game points as primary score and `use_secondary?: false` are not covered
  here (Type B is proven at bracket level in `team_pairing_test.exs`).
- The histories come from one generator: 4 boards, 2/1/0 match points,
  about one team in twelve sitting a round out from round 2, one match in
  fifteen forfeited as a whole, 3-9 rounds.
- The readings are shared with the naive reference and the engine by
  design; this proves the computation, not the reading.
- The matcher is trusted by comparison (with the DP up to 16 vertices, and
  through the naive agreement), not by a formal proof of the code.
