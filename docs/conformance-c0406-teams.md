# C.04.6 Swiss Team Pairing System - conformance notes

Working notes on the FIDE Swiss Team Pairing System **effective 1 February
2026** ([handbook](https://handbook.fide.com/chapter/SwissTeamPairingSystem202602)),
written before any code exists so the reading can be checked against the
regulation rather than against an implementation.

Checking the effective date first is deliberate: the individual rules were
rewritten in the same February 2026 wave.

This paragraph used to continue "and every reference implementation still
carries the pre-2026 reading of Article 5.2.5", and offered that as part of
the case for reading the regulation before reading an implementation. **The
claim was false.** The FIDE Systems of Pairings and Programs Commission
ruled on 2026-08-27 that the references' behaviour is what the current text
requires and that this engine's reading was the wrong one - see
[dispute-initial-colour.md](dispute-initial-colour.md) and Article 4 below.
Reading the regulation first is still the right method for this chapter,
where no reference exists to read at all; it was never a licence to
discount an implementation that disagreed. The version-till page for this
chapter exists too; this document is about the current one.

## The short version

**It is not the Dutch system applied to teams.** The preface says the
Basic Rules apply *mutatis mutandis*, but C.04.6 defines its own criteria
set, its own bye rule, and - most importantly - its own *procedure*.

Three structural differences from C.04.3, each of which changes the
implementation:

| | individual (C.04.3) | teams (C.04.6) |
|---|---|---|
| criteria | C1-C21 | C1-C3 absolute/completion, C4-C10 quality |
| bracket procedure | best candidate under a lexicographic weight ladder | **first** candidate in a defined enumeration order |
| score | one score | **two** - primary and secondary |

## Article 2 - the criteria

**Absolute (2.1)**

* **[C1]** Two participants shall not play against each other more than
  once.
* **[C2]** A team that has already received a pairing-allocated bye or won
  a match by forfeit (or been given a FIDE-deprecated full-point bye)
  shall not receive the pairing-allocated bye.

**Completion (2.2)**

* **[C3]** A pairing complying with all the absolute criteria shall always
  exist for all teams not yet paired.

**Quality (2.3), in descending priority**

* **[C4]** Minimize the count of upfloaters.
* **[C5]** Minimize score differences in pairs involving upfloaters.
* **[C6]** Unless the following scoregroup has been emptied by upfloating,
  choose the upfloaters so that [C1], [C3] and [C4] can still be complied
  with in the bracket where that scoregroup is paired.
* **[C7]** Minimize upfloaters who were floaters in the previous round
  (except in the last two rounds).
* **[C8]** Minimize teams whose colour preference is not fulfilled.
* **[C9]** Minimize teams whose STRONG colour preference is not fulfilled
  (Type B only).
* **[C10]** Minimize upfloaters' opponents who were floaters in the
  previous round (except in the last two rounds).

Nine rungs against the individual system's twenty-one, and [C6] is the
only one that reaches forward into a later bracket.

## Article 3 - the procedure

**3.3 Round-pairing outlook.** Assign the bye (3.4); combine the
top scoregroup with upfloaters into a bracket and pair it (3.6); repeat
until every team is paired; then allocate colours (Article 4).

**3.4 The bye** goes to the team with, in order: the lowest score (3.4.2),
then the highest number of matches played (3.4.3), then the largest TPN
(3.4.4) - subject to 3.4.1, that the remaining teams can still be legally
paired. It is worth as many match points **and** game points as a draw.

**3.6 Bracket pairing.** This is the part that decides the architecture.

> A pairing is a sequence of pairs that includes all teams in the bracket.
> For each pair, the team with the smaller TPN is the top member; the team
> with the larger TPN is the bottom member.

The pairing's *identifier* is the top members' TPNs in ascending order,
followed by their corresponding bottom members' TPNs. Pairings are ordered
**lexicographically by that identifier**, and the procedure takes the
**first** one complying with [C1], [C8], [C9] and [C10].

So the regulation defines an ORDER and a PREDICATE, not a scoring
function. There is no weight ladder to maximise here and no matching
problem to solve - which means `Ainalrami.WeightedMatching` is not
involved in team pairing at all.

## Article 4 - colours

* **4.1** The initial-colour is drawn by lot before round one.
* **4.2** The *first-team* of a pair is the one with the higher primary
  score, else the higher secondary score, else the smaller TPN.
* **4.3** Descending priority. **4.3.1**: when both teams have yet to play
  a match, if the first-team has an **odd TPN** it takes the
  initial-colour, otherwise the opposite. "Odd TPN" is the article's own
  wording and is quoted here as such; which number that parity is actually
  taken on is the point the SPP settled, immediately below.
  4.3.2-4.3.9 then apply colour
  preferences, strong preferences (Type B), colour difference, historical
  alternation, and the first-team's preference.

The board-one colour cascades to the remaining boards.

> **4.3.1 is the same TPN-parity rule as the individual 5.2.5**, and that
> rule was put to the SPP (see
> [spp-question-initial-colour.md](spp-question-initial-colour.md)) and
> **answered on 2026-08-27, against this engine.**
>
> The parity is *not* taken on the TPN as the file gives it. It is taken on
> a numbering that counts only the participants who have arrived,
> recomputed each round. The SPP's reasoning is C.04.2 Article 2.4: a late
> entry is "given an appropriate TPN and paired only when they actually
> arrive", so a participant who has not arrived holds no TPN at all. Both
> reference implementations already did this and were right to.
>
> The crux is worth carrying here rather than only in the dispute
> document, because it is the part a future reader can use. **Both sides
> argued from that same sentence.** This project's case was "the TPN
> exists before the arrival; it is the *pairing* that waits". The SPP
> reads the identical clause as "no TPN until arrival". We read it the
> wrong way round.

It applies here unchanged, and the team side implements it now:
`TeamPairing.pair_round/2` builds the round's numbering once via
`Colour.parity_numbers/1` and threads it through `Colour.allocate/3`'s
`:parity_numbers` option to `initial_colour_by_parity/2`.

This document warned that team colour allocation should not be finalised
before the answer arrived, or it would be built twice. **The warning was
written and then ignored.** Article 4.3.1 was implemented on the reading
the SPP overturned - `initial_colour_by_parity(first.tpn, initial)`, under
a moduledoc asserting that line was "the single line that would change" -
and the ruling rewrote it. The change was four functions, not one line:
`Colour.parity_numbers/1` is new, `decide/5` became `decide/6`,
`allocate/3` grew the `:parity_numbers` option, and
`TeamPairing.pair_round/2` with `allocate_colours/5` (now `/6`) changed to
build the numbering and carry it down. Article 4 was built twice, exactly
as predicted, by the project that predicted it. Writing the warning down
was not the same as acting on it, and this paragraph exists so the next
reader does not mistake a recorded risk for a managed one.

What the individual ruling does **not** settle is what "arrived" means for
a TEAM. C.04.6 has no Article 2.4 of its own, and `%Team{}` carries no
per-round history, so a team's arrival is not reconstructible from the
struct the way a player's is from their TRF game list. The engine's
numbering is therefore position in ascending TPN over exactly the list
`pair_round/2` is handed: roster membership, nothing else.

For a team that has NEVER arrived that is the right answer - a host that
omits it gets the renumbering for free, and a host that keeps it in the
list would have it paired.

For a team that arrived and is then **absent** - sitting a round out, or
withdrawn after playing - it is the wrong one, and it is a defect rather
than a licensed difference between the two chapters. The individual rule
keeps such a player numbered forever (`Pairing.arrived_for?/2`'s second
clause: participated in any earlier round). Nothing in C.04.6 says teams
should behave differently; the team side loses the number only because the
absent team is not in the list, and everyone below it silently shifts. It
is reachable inside 4.3.1's own window: a team that takes the
pairing-allocated bye in round 1 has arrived with zero played matches, and
if it sits round 2 out it can still meet 4.3.1 in round 3 with the wrong
parity for every team below it.

`Colour` cannot fix that - the absent team is not in its scope at all - so
the fix belongs on `TeamPairing.pair_round/2`, as an explicit roster or
absentee argument distinct from "the teams to pair this round". Until then
the divergence is stated in `Colour`'s moduledoc and pinned by a test
rather than left for a reader to discover. **Not measured, because there is
nothing to measure it against**: C.04.6 has no automatable oracle (below).

## Type A and Type B

A per-competition setting, defined in Article 1.7. Type A is used unless
the competition's own rules say otherwise (or say colour preferences are
not used at all). Type A grades preference on a coarser threshold; Type B
distinguishes STRONG from mild preferences, and **[C9] exists only under
Type B**. Both must be selectable per tournament; neither is a default we
get to choose for the arbiter.

## Scores

Article 1.2: the competition states which of *match points* and *game
points* is the primary score, and whether the other is used for colour
allocation. **The default is match points primary, game points for
colours.** Both are needed - a team model carrying only one cannot express
4.2, and the bye pays in both.

## Board order is NOT specified

The regulation never says how a team orders its own boards, nor whether
that order may change between rounds. That is explicitly left to the
competition. It is therefore ours to model, and it should be a stored,
arbiter-editable property rather than anything derived - deriving it would
invent a rule FIDE deliberately declined to write.

## Performance, from the start

Naive enumeration is fatal, and it is worth being explicit about why: a
bracket of 2n teams has (2n−1)!! pairings. Ten teams is 945; twenty is
6.5×10⁸; forty is about 10²². **Round one is a single bracket containing
the entire field**, so the worst case is not exotic - it is the first
round of any ordinary event.

The regulation is not asking for enumeration, though. It defines an order
and asks for the first element satisfying a predicate. The implementation
must therefore:

* **generate lazily in identifier order** and stop at the first hit -
  never materialise the set;
* **prune on prefixes**: a partial pairing that already repeats a pair
  ([C1]) kills the whole subtree below it, and the subtree is enormous;
* **short-circuit the common case**: with no history, round one's first
  candidate is the natural pairing and satisfies everything, so the
  expected cost is a handful of candidates rather than a search;
* **answer [C3] with a completability oracle** rather than by trying -
  this is a matching-feasibility question, and the individual engine
  already has the shape of the answer in `oracle_completable?`.

That last point is the one place a matching algorithm still earns its
keep: not to *choose* a pairing, but to certify that a choice leaves the
rest of the bracket pairable.

Target: a team round should be well inside a millisecond for realistic
field sizes, because the work is a short walk down a generator, not a
search. If it is ever slow, the pruning is wrong, not the approach.

## Is any of this required?

**No.** Endorsement is granted per pairing system, not per program:
C.04.A says "the endorsement is given for the specific pairing systems
(one or more)", and the bar is being able to manage Swiss tournaments
using the FIDE (Dutch) System *or any other approved system* - at least
one. So C.04.6 is a separate, optional endorsement, and team support is a
product decision rather than a prerequisite for FE1 on the Dutch system.

Worth knowing before spending the effort, and worth re-reading before
starting: nothing below is blocking anything.

## Verification: no reference we can automate against

Team pairing is not unsolved - **Swiss-Manager** does team Swiss and team
round-robin, is FIDE-endorsed, is used by 180+ federations, and is what
pairs the Olympiad and most national leagues. It is also closed-source
Windows software, so it cannot be read, run headless, or diffed against a
generated corpus.

What that leaves is no *automatable* oracle. Checked, rather than
assumed:

| | teams? |
|---|---|
| bbpPairings 6.0.0 | **no** - no team code at all; `--dutch` and `--burstein` are both individual |
| JaVaFo | no |
| Gacrux (`pairingchecker.py`) | no |
| SWAR 6.65 | **no** - searched for `Team` AND the French `Equipe`; neither appears anywhere, and there is no team tournament type. It is an individual-tournament program, which is a surprise for the Belgian tool given the interclub is team-based |

This inverts the method that made the individual engine trustworthy: there
is no oracle to run a corpus against, so "we agree with bbpPairings across
millions of tournaments" is unavailable here.

**The good news is that the regulation hands back something stronger.**
For the individual system, exhaustive verification was impossible in
principle: C.04.3 defines a sequential procedure, not a global optimum, so
"which whole-round pairing scores highest" is a question with no defined
answer (see
[conformance-c0403-2026.md](conformance-c0403-2026.md), "Why that test is
harder than it looks"). Here the opposite holds. Article 3.6 defines the
answer *as* the first element of an enumerable order - so for a bracket
small enough to enumerate exhaustively, a test can BE the definition:
generate every pairing, sort by identifier, filter by the criteria, and
assert the engine returns the head.

That is a proof, not a correlation. It is available for small brackets
today and does not depend on anyone else having implemented the rules.

The corpus still has a role, but a different one: fuzzing for crashes,
[C1]/[C2] legality violations, and [C3] dead ends - properties that hold
regardless of which candidate is chosen.

## Reading decisions the implementation had to make

Written while building `lib/ainalrami/team_pairing.ex`, so these are the
places the text ran out rather than places nobody looked.

### [C5]'s score profile, and the 3.5.4 example that contradicts it

2.3.2 reads: "Minimise the score differences (taken in descending order) in
the pairs involving upfloaters, i.e. maximise the scores (taken in ascending
order) of the upfloaters." Taken at face value, a set of three upfloaters
should take the three highest-scoring candidates available.

The example under 3.5.4 says otherwise. It assumes 2, 6 and 8 have 3 points
and 1, 3 and 5 have 2.5, states that three upfloaters are needed, and then
says "[C5] determines that two upfloaters must have 3 points and the other
2.5" - dropping one of the three available 3-pointers for a 2.5-pointer,
which is a *larger* score difference. It asserts that step rather than
deriving it, and no other article visible in the chapter forces it.

**The implementation follows the article, not the example**: [C5] takes the
highest-scoring candidates, so the same position produces {2,6,8}. The
example's own ORDERING - `{2,6,1} < {2,6,3} < {2,6,5} < {2,8,1} < ...` - is
unambiguous and is implemented and tested exactly as written; only the
profile it starts from is in question.

Both readings are pinned by tests in `team_pairing_test.exs` ("3.5.4 orders
candidate sets lexicographically by TPN" and "[C5] takes every top-scoring
candidate when it can"), so whichever way this is resolved, the test that
fails names the decision.

One possibility worth checking with the SPP: the example may be carrying an
unstated [C6] constraint, since taking all three 3-pointers empties that
scoregroup and [C6]'s "unless ... this scoregroup is now empty" clause turns
off exactly when it does.

### 3.6.4 names minimisation criteria as if they were predicates

"Choose the first pairing that also complies with criteria [C1], [C8], [C9]
and [C10]." [C1] is a predicate. The other three are minimisations, and no
single pairing complies with a minimisation in isolation - it complies by
achieving the minimum attainable over the bracket's legal pairings.

So `Bracket.pair/2` minimises `{c8, c9, c10}` lexicographically and
tie-breaks by identifier order. That is the same statement made computable:
the first compliant pairing in identifier order IS the lex-smallest
identifier among those achieving the minima. The practical consequence is
that the walk cannot always stop at the first legal candidate - though it
stops immediately on `{0,0,0}`, which cannot be beaten and which round one
and most ordinary brackets hit on the first try.

### [C7] is a minimisation applied to a choice between sets

2.3.4 minimises upfloaters that were floaters in the previous round, and
3.5.5 asks for "the first set that ... complies with [C6] and [C7]". The
implementation takes 3.5.4's order and applies legality plus [C6] as a gate,
which means [C7] currently acts as part of the ordering rather than as a
separate ranking pass. A stricter reading would rank surviving sets by their
[C7] count before applying 3.5.4's tie-break. Recorded rather than guessed;
it changes behaviour only when a lexicographically earlier set carries more
previous-round floaters than a later one.

## Open questions

* ~~**4.3.1 and the TPN-parity dispute.** Blocked on the SPP reply. Build
  the rest first.~~ **Closed 2026-08-27**: answered against this engine,
  and implemented on the team side (Article 4 above). This was the only
  item on the team system whose *correct answer* was unknown rather than
  merely unwritten, so team-pairing validation no longer has a colour
  question hanging over it - the small-bracket exhaustive proof covers who
  plays whom, and colour now has a settled rule to test against instead of
  a pending one.

  Nothing measured in this document moves as a result, for the plain
  reason that nothing here was ever measured: C.04.6 has no automatable
  oracle (see above), so there is no team corpus to re-run. The individual
  side's disputed-board counts do move, and re-measuring them is that
  side's work, not recorded here.
* **The absent team's number (4.3.1).** Open, and a defect rather than an
  unwritten rule: a team that arrived and is then absent for a round loses
  its number here, where the individual side keeps it. `pair_round/2` needs
  an absentee or full-roster argument to tell "never arrived" from "arrived,
  not playing today"; `Colour` cannot see the difference. See Article 4
  above and `Colour`'s moduledoc.
* **Board order.** Unspecified by FIDE; needs a product decision, and it
  interacts with whatever the host application stores per player.
* **Forfeited matches.** [C2] mentions winning a match by forfeit, which
  implies a match-level forfeit concept distinct from a board-level one.
  Needs its own pass against Article 1.
