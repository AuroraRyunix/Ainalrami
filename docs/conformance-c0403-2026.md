# Conformance record: C.04.3 FIDE (Dutch) System, effective 1 February 2026

Article-by-article verification of this engine against the rules text
(<https://handbook.fide.com/chapter/C0403202602>, approved by the FIDE
Council 28/10/2025), checked 2026-08-17, and extended to Articles 3 and 4 on 2026-08-25.

This exists because until that date the engine's rules had been derived from
**bbpPairings' source code** and confirmed by **measurement** - 4.3 million
tournaments, 195 million pairings - but not read off the regulations. Two
bugs fixed the same day (the top-scorer threshold, and `W` in the
bye-disqualifying list) were found that way and are confirmed below by the
text, independently.

Where a row says "exact", the code's condition and the article's condition
were compared term by term, not merely observed to agree.

## Definitions

| article | rule | implementation | verdict |
|---|---|---|---|
| 1.2 | Order: score, then TPN ascending | `Enum.sort_by(&{-&1.points, &1.rank})` | exact |
| 1.4.3 | A downfloat is given to a PAB recipient, or to anyone who without playing scores more than a loss | `float_direction/4`: an unplayed round is `:down` when `result_points > point_system().loss` | exact - see note 6 |
| 1.7.1 | Absolute preference: CD > +1 or < −1, **or** same colour in the two latest rounds played | `absolute? = imbalance > 1 or not is_nil(repeated)`, `repeated` set when `consecutive > 1` | exact |
| 1.7.2 | Strong preference: CD = ±1 | `strong? = not absolute? and imbalance > 0` | exact |
| 1.7.3 | Mild preference: CD = 0, alternate from the previous game | `preference` ladder falls through to `invert(last)` | exact |
| 1.7.4 | A player with no games has no preference | `preference` is `nil` only for a never-played player | exact |
| 1.8 | Topscorer: **over** 50% of the maximum possible score, final round only | `points > played_rounds * point_system().win / 2`, gated on `played_rounds >= expected_rounds - 1` | exact - see notes 1 and 6 |

## Absolute criteria (2.1)

| article | rule | implementation | verdict |
|---|---|---|---|
| C1 | Two participants shall not play each other more than once | `legal_pair?/2`, gated on `played?/1` | exact |
| C2 | A participant who has already received a PAB, **or has already scored in one single round, without playing, as many points as rewarded for a win**, shall not receive the PAB | `bye_disqualifying?/1`: unplayed **and** (`U`, or `result_points >= point_system().win`) | exact - see notes 2 and 6 |
| C3 | **Non-topscorers** with the same absolute colour preference shall not meet | `colour_compatible?/2` refuses the pair unless `final_round_topscorers?/2` | exact |

## Completion, PAB, and quality criteria

| article | rule | implementation |
|---|---|---|
| C4 | A pairing complying with the absolute criteria shall always exist for all players not yet paired | `check_completion/3`, with `repair_completion/3` as the whole-field fallback; `NoValidPairingError` when genuinely impossible |
| C5 | Minimise the score of the PAB assignee | `bye_assignee_score/2` computes the minimum achievable over the whole field, then `bye_score_ok?/1` enforces it - see note 3 |
| C6 | Minimise downfloaters (maximise pairs) | `"C6 pairs in bracket"` rung |
| C7 | Minimise the scores of the downfloaters | `"C7 scores paired"`, graded by score group |
| C8 | Choose downfloaters so the following bracket complies with C1-C7 | the two `"C8 … next bracket"` rungs, over edges reaching the immediately following score group (`reach == 1`) |
| C9 | Minimise the unplayed games of the PAB assignee. *Applies to brackets that downfloat exactly one player, who will receive the PAB* | `"C9 bye unplayed games"`, gated on `single_bye?` - the gate is the article's own restriction, not an optimisation |
| C10, C11 | Minimise topscorers/their opponents with \|CD\| > 2, or the same colour three times running | `"C10"`/`"C11"` rungs, reachable only through the final-round path |
| C12, C13 | Minimise disregarded colour preferences / strong preferences | `"C12"`, `"C13"` rungs |
| C14-C17 | Minimise repeated downfloats (residents) and upfloats (MDP opponents), at r−1 and r−2 | `float_criteria/2` |
| C18-C21 | The same four, by score difference rather than count | `float_score_criteria/3` |

## Notes

**1 - the topscorer threshold.** "Over 50% of the maximum possible score"
means the maximum available *so far*, not the tournament's eventual total.
FIDE TEC's worked companion (*Mastering the Dutch*, 2026, footnote 27) is
explicit: "in a nine-round tournament the maximum score before the last
round is eight points. So, a topscorer is a player who has 4.5 points or
more." That is `points > played_rounds / 2`, an exact half with a strict
comparison, against the tournament's played rounds. This engine used
`div(played_rounds, 2)` - a floored half - and the player's own game count,
until 2026-08-17. Both errors are invisible whenever the played-round count
is even, which every fuzz axis before that date happened to be.

**2 - C2's second limb is "without playing".** So `U` (PAB), `F`
(full-point bye) and `+` (forfeit win) disqualify; `H` and `Z` do not,
because neither scores a win's worth; and an ordinary win never does,
however it is spelled. TRF16 allows the letter form `W` for a played win,
and this engine had `W` in the disqualifying list until 2026-08-17 on the
reading that it meant an *unplayed* win. The article settles it.

**3 - C5 is enforced as a constraint, which the rules do not require.**
2.3 places C5 outside the absolute criteria, and 3.8.1 treats it as the
highest-priority *comparison* - "a candidate is better than another if it
better satisfies the PAB Criterion … or a quality criterion of higher
priority". This engine instead precomputes the minimum achievable PAB score
over the whole field and then refuses any candidate that misses it. The two
are equivalent **provided the precomputed minimum is genuinely achievable**,
which is what `bye_assignee_score/2`'s bootstrap matching establishes. It is
the same shape bbpPairings uses. Recorded here because it is a deliberate
divergence in mechanism, not in outcome.

**6 - three articles quote a POINT VALUE, and the file sets it.** 1.4.3
says "more than a loss", 1.8 says "the maximum possible score", and C2 says
"as many points as rewarded for a win". Under the standard 1 / ½ / 0 system
those read 0, half the rounds played, and 1 - and an implementation that
writes the number rather than the setting is right, silently, for as long
as nobody changes the system. bbpPairings does not write the numbers: its
three conditions are `> pointsForLoss` (dutch.cpp:118), `(playedRounds *
max(pointsForWin, pointsForDraw)) >> 1` (dutch.cpp:52-56) and `>=
pointsForWin` (common.h:112), all read from `BBW`/`BBD`/`BBL`/`BBZ`/`BBF`/
`BBU` or TRF16's `162`.

All three were baked in here. 1.8 and C2 were fixed on 2026-08-24 with the
directives themselves; 1.4.3 was missed and fixed on 2026-08-25, after a
`BBL 0.5` corpus put round agreement at 88.62% and the adjudicator
(`explain_round/3`) reported this engine's own answer scoring BETTER than
the reference's on C14 in 108 of 200 dumped positions and on C16 in 76 more
- the signature of a criterion the ladder is computing wrongly rather than
a search that failed to reach the right answer. With a loss worth half a
point, a half-point bye is no longer better than losing, so it is not a
downfloat; reading it as one gave every player who had ever sat a round out
a float history the reference does not have, and C14-C21 then priced their
pairings wrongly. 100.00% after the fix, on the same corpus.

One term is still narrower than the reference's: 1.8's threshold uses
`point_system().win` where bbpPairings uses `max(pointsForWin,
pointsForDraw)`. The two differ only in a system where a draw outscores a
win, which no named system does and no sane file would.

## Colour allocation (Article 5)

| article | rule | implementation | verdict |
|---|---|---|---|
| 5.1 | The initial colour is decided by lot, then alternates down the initial ranking | TRF header `152`, read by `Ainalrami.Trf`; `assign_colour_round_one/2` alternates on parity of rank | exact |
| 5.2.1 | Grant both preferences where they differ | first clause of the `preference` ladder | exact |
| 5.2.2 | Grant the stronger preference; if both absolute, the wider colour difference | `absolute?`/`strong?` comparison | exact |
| 5.2.3 | Alternate to the most recent round in which one had White and the other Black | walks both colour histories back in step | exact |
| 5.2.4 | Grant the higher-ranked player's preference | ranked per Article 1.2: `{-points, rank}` | exact - see note 4 |
| 5.2.5 | Otherwise: the higher-ranked player takes the initial colour if their TPN is odd, the opposite if even | `assign_colour_round_one/2` on `rem(top.rank, 2)` against the `152` header | exact - see note 5 |

**4 - 5.2.4 ranks by Article 1.2, not by starting rank.** "Higher ranked"
throughout C.04.3 means the 1.2 order - score first, then TPN ascending -
not the initial seeding. The comparison is on the tuple `{-points, rank}`
so a higher score outranks a lower TPN, which is the article's order and
not the file's.

**5 - 5.2.5's parity is taken on the TPN, and the TPN is fixed.** The
article defers the term to C.04.2 Article 2, which assigns a TPN from the
initial ranking and moves it for exactly two reasons: a correction to the
ranking data (barred after round four) and the closing of the participant
list after late entries. Nothing renumbers TPNs around players who are not
paired in a given round.

Both reference implementations renumber anyway, and - measured both ways
round with `tools/rip_probe.exs` - they draw the same line: they skip
players who have **never participated**, and not players who have played
and are merely absent this round. On a complete field all three engines
agree, because the two numberings coincide; they diverge once somebody has
been registered without ever being paired.

This engine follows the article, and **that is deliberate and is not going
to be changed to match**. Gacrux does not break the tie here, as it does
in `dispute-seed735265.md`: it renumbers with bbpPairings.

The references' reading is not unreasonable - 2.5 makes TPNs provisional
until the participant list closes, and a player who never turned up is
arguably not on it. What decides it the other way is 2.4: a late entry is
*"given an appropriate TPN and paired only when they actually arrive"*, so
the TPN exists before the arrival and it is the pairing that waits. The
full argument, the handbook text and the measured scale are in
[dispute-initial-colour.md](dispute-initial-colour.md).

Note that colour never affects *who plays whom*: it is decided after the
pairing, so a divergence here cannot produce a different set of boards,
only a different side allocation on one of them. Every axis measured for
this dispute reports 100.00% pairing agreement and zero illegal rounds.

## Bracket construction and the candidate sequence (Articles 3 and 4)

Checked against the article text 2026-08-25. Each row says what the article
requires and where the engine satisfies it. Where it satisfies it by a
different mechanism the row says so and points at the measured section that
follows, rather than asserting equivalence.

| article | rule | implementation | verdict |
|---|---|---|---|
| 3.1 | `M0` MDPs arriving, `MaxPairs` the most pairs the bracket can make, `M1` the MDPs actually paired | the bracket state carries all three; `MaxPairs` is the matcher's cardinality bound | exact |
| 3.2 | S1 is the first `MaxPairs` residents by Article 1.2 (homogeneous), or the first pairable `M1` MDPs (heterogeneous); S2 is the remaining residents | subgroup split, sorting on `{-points, rank}` | exact |
| 3.2 | MDPs beyond `M1` sit in a **Limbo** and are bound to double-float | `limbo` in the bracket state, excluded from this bracket's edges | exact |
| 3.3 | The first candidate pairs S1[i] with S2[i] | asserted directly - `tiebreak_order_test.exs` checks the identity pairing sorts first | exact |
| 3.4 | A candidate meeting C1-C5 and C6-C21 is "perfect" and is accepted immediately | the matcher's optimum over weights packing C1-C21 in priority order | equivalent, not identical - see below |
| 3.5-3.7 | When no candidate is perfect, alter S1/Limbo/S2: transpose S2, then exchange between S1 and S2; heterogeneous brackets work the remainder first, then the MDP-Pairing, then the Limbo | the matcher searches every matching, so every candidate those alterations can reach is considered | equivalent, not identical - see below |
| 3.8 | Choose the best candidate: better on [C5], then [C6]-[C21], then **generated earlier** | rung comparison, with `transposition_key/3` standing in for generation order | see "Known structural divergence" |
| 4.1 | Tag players with consecutive BSNs in bracket order before any alteration | S1 and S2 are already in Article 1.2 order, so index and BSN rank rise together | exact |
| 4.2 | Sort transpositions by the lexicographic value of their first `N1` BSNs | `transposition_key/3` **is** this ordering, not an approximation - argued and measured | exact - see below |
| 4.3 | Sort exchanges by: fewest BSNs exchanged; smallest difference of the moved sums; largest differing BSN out of S1; smallest differing BSN into S1 | measured against `Ainalrami.Sequence` | see "Article 4.3, measured 2026-08-17" |
| 4.4 | A set of pairable MDPs is valid if its Limbo complies with [C7]; valid sets sort by smallest differing BSN | heterogeneous handling | see "Heterogeneous brackets, added 2026-08-18" |
| 4.5 | Each application picks the next element of the established order | not enumerated - the matcher does not step a sequence | by construction - see below |

The honest summary: **every requirement about WHICH pairing is best is met
exactly. The requirements about the ORDER candidates are generated in are met
by an equivalence argument plus measurement, not by doing what the article
literally describes.** That is the subject of the next section, and it is the
one place in this document where the engine does not simply follow the text.

## Known structural divergence

Articles 3.5-3.8 and 4 describe pairing a bracket by **generating candidates
in a defined sequence** - transpositions of S2, then exchanges between S1 and
S2, in a specified order - and taking the first perfect one, or the best
under 3.8.1 with "generated earlier in the sequence" as the final tie-break.

This engine instead solves each bracket as a maximum-weight matching whose
edge weights pack C1-C21 in priority order, which reaches the same optimum
without enumerating candidates. The two agree on which pairing is *best*;
the question has been how they break a tie below every criterion, since
3.8.1's last resort is generation order and this engine's is
`transposition_key/3`.

**Measured 2026-08-17, and the gap is far narrower than it was carried as.**

`transposition_key/3` is **not an approximation of 4.2 - it is 4.2**. The
article sorts transpositions by "the lexicographic value of their first N1
BSN(s)"; the key is the S2 *index* of each S1 member's opponent. S2 is sorted
by Article 1.2 and BSNs are assigned in that same order (4.1.1), so index and
BSN rank within S2 increase together, and the two lexicographic orders are
identical.

That is checked rather than argued. `tiebreak_order_test.exs` generates
candidates with `Ainalrami.Sequence` - which knows nothing about the engine -
and asserts the key increases strictly along Article 4.2's order, over a
homogeneous bracket (all 24 orderings), an odd bracket where one player
downfloats, and a heterogeneous bracket ordered on its MDPs (all 20). It also
checks the identity pairing S1[i]-vs-S2[i], the candidate 3.3.1 builds before
any alteration, sorts first.

### Article 4.3, measured 2026-08-17

Once every transposition of a given S1/S2 is exhausted, the regulations
*exchange* players between the subgroups and restart the sequence, reaching
candidates no transposition can - with S1 fixed, no transposition can ever
pair two S1 members with each other, and an exchange can.

Those candidates were always *considered* here, since the matcher searches
every matching. What had never been checked is whether the engine picks the
same one **among candidates that tie**, where 3.8.1's last resort is
generation order.

It does, on every position tested. `exchange_order_test.exs`:

- **A position where 4.3 is the sole decider.** Eight players on one score,
  every one of the sixteen S1×S2 pairs already played and no intra-half pair
  played - so no transposition can produce a legal candidate at all, and
  only an exchange reaches one. The engine returns exactly the first
  candidate Article 4's sequence generates: the size-2 exchange
  `{1,2,5,6}/{3,4,7,8}`, whose identity pairing is already legal. The
  sixteen size-1 exchanges that precede it are pinned as correctly passed
  over - none can yield a legal candidate, because only intra-half pairs are
  legal and that needs S1 and S2 to hold equal numbers from each half.
- **Forty randomly generated single-score brackets**, each enumerated in
  full Article 4 order (up to ~1680 candidates for eight players), scored
  with the engine's own ladder. In every one the engine's answer is the
  earliest-generated candidate among those tying for the best rung vector,
  which is 3.8.1 stated literally.

The scoring half is the engine's own ladder and is not independent; it is
not meant to be. What is independent is the **order**, which comes from
`Ainalrami.Sequence` - a module that knows nothing about criteria, weights
or legality - and the order is the entire question 4.3 raises.

### Heterogeneous brackets, added 2026-08-18

A bracket carrying moved-down players pairs in two stages (3.4): the
MDP-Pairing seats the MDPs against residents, and the leftover residents
form a remainder paired as a homogeneous bracket of its own. 3.7 exhausts
the remainder's sequence **before** altering the MDP-Pairing, so the
MDP-Pairing is the outer loop.

That was carried as the uncovered residue of this gap. It is covered now,
and the trick is simply to make the heterogeneous bracket the **last**
one: nothing below it means no candidate can reach an edge into a lower
group, every candidate contributes the same edges, and the rung vectors
are commensurable after all.

The position is one MDP plus seven residents, with round one arranged so
the remainder's *natural* pairing is illegal - two of its three identity
pairs are rematches. The engine returns the first candidate the sequence
reaches: the MDP keeps the first resident 4.2 offers, and it is the
remainder that moves, to its own first legal transposition. Had the two
loops been nested the other way round, the engine would have changed the
MDP's opponent instead, and the test says so explicitly rather than
leaving it to be inferred from the result.

### What remains of it

Nothing structural that has been identified. The comparison holds the
bracket fixed and requires it to be last, so a bracket in the MIDDLE of a
round - one that both inherits MDPs and floats players onward - cannot be
asked the same question: closing it fully needs a way to compare
candidates that float different players, which the rules do not define
(see below).

**Narrowed 2026-08-21.** That bracket now has an enumeration check of its
own in `mid_round_bracket_test.exs`, where it previously had only the
corpus. The claim is deliberately weaker than the last-bracket one, and it
is the strongest one available: **reachability** - that the engine's
answer for a middle bracket is a candidate Article 4's sequence actually
generates. The engine solves a matching rather than walking 4.2/4.3, so
nothing structurally prevents it returning a pairing outside the
enumeration, and nothing had checked that here.

Worth recording that the oracle was wrong twice before it was right, both
times by being WEAKER than the engine - the exact failure mode this
section warns about further down:

* it generated only the MDP-Pairing and not the remainder, so a
  heterogeneous bracket's two-stage answer (3.4) looked unreachable;
* it then generated the remainder by transposition alone, so a remainder
  answer pairing two S2 members together - reachable only after an
  exchange (4.3) - looked unreachable too.

The engine was right both times. That is why the reachability result is
worth more than it sounds: the oracle had to be made genuinely complete
before it would pass at all.

4.3 has never produced a measured disagreement with bbpPairings - 4.3M
tournaments, one disagreement, and that one is a case where bbpPairings
breaches C2 (see `dispute-seed735265.md`).

### Why that test is harder than it looks

The obvious version - enumerate every legal round-pairing, score each with
the ladder, check the engine picks an optimal one - was built and thrown
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
  which players a pairing floats - so two round-pairings produce different
  bracket structures and their rung vectors are not commensurable. That is
  the same defect `explain_round/3`'s `edge_count` guard exists to catch,
  one level up.
* an enumerator is only as good as its legality test. The discarded one
  checked C1 and neither C2 nor C3, so it reported "legal pairings the
  engine refused" - it had admitted illegal ones. A weaker oracle accusing a
  stronger implementation is the expected result, not a finding.

**A valid test has to run per bracket**, comparing candidates within one
bracket against a fixed set of incoming MDPs, which is where the regulations
actually define an ordering. That means wiring `Ainalrami.Sequence` into the
bracket loop rather than around the round. That is the remaining work on
this gap, and it is real work rather than a script.
