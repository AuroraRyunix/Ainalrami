# C.04.6 Swiss Team Pairing System — conformance notes

Working notes on the FIDE Swiss Team Pairing System **effective 1 February
2026** ([handbook](https://handbook.fide.com/chapter/SwissTeamPairingSystem202602)),
written before any code exists so the reading can be checked against the
regulation rather than against an implementation.

Checking the effective date first is deliberate. The individual rules were
rewritten in the same February 2026 wave, and every reference
implementation still carries the pre-2026 reading of Article 5.2.5 — see
[dispute-initial-colour.md](dispute-initial-colour.md). The version-till
page for this chapter exists too; this document is about the current one.

## The short version

**It is not the Dutch system applied to teams.** The preface says the
Basic Rules apply *mutatis mutandis*, but C.04.6 defines its own criteria
set, its own bye rule, and — most importantly — its own *procedure*.

Three structural differences from C.04.3, each of which changes the
implementation:

| | individual (C.04.3) | teams (C.04.6) |
|---|---|---|
| criteria | C1–C21 | C1–C3 absolute/completion, C4–C10 quality |
| bracket procedure | best candidate under a lexicographic weight ladder | **first** candidate in a defined enumeration order |
| score | one score | **two** — primary and secondary |

## Article 2 — the criteria

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

## Article 3 — the procedure

**3.3 Round-pairing outlook.** Assign the bye (3.4); combine the
top scoregroup with upfloaters into a bracket and pair it (3.6); repeat
until every team is paired; then allocate colours (Article 4).

**3.4 The bye** goes to the team with, in order: the lowest score (3.4.2),
then the highest number of matches played (3.4.3), then the largest TPN
(3.4.4) — subject to 3.4.1, that the remaining teams can still be legally
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
problem to solve — which means `Ainalrami.WeightedMatching` is not
involved in team pairing at all.

## Article 4 — colours

* **4.1** The initial-colour is drawn by lot before round one.
* **4.2** The *first-team* of a pair is the one with the higher primary
  score, else the higher secondary score, else the smaller TPN.
* **4.3** Descending priority. **4.3.1**: when both teams have yet to play
  a match, if the first-team has an **odd TPN** it takes the
  initial-colour, otherwise the opposite. 4.3.2–4.3.9 then apply colour
  preferences, strong preferences (Type B), colour difference, historical
  alternation, and the first-team's preference.

The board-one colour cascades to the remaining boards.

> **4.3.1 is the same TPN-parity rule as the individual 5.2.5**, and that
> rule is currently the subject of an open question to the SPP (see
> [spp-question-initial-colour.md](spp-question-initial-colour.md)).
> Whatever answer comes back applies here too. Team colour allocation
> should not be finalised before it arrives, or it will be built twice.

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
colours.** Both are needed — a team model carrying only one cannot express
4.2, and the bye pays in both.

## Board order is NOT specified

The regulation never says how a team orders its own boards, nor whether
that order may change between rounds. That is explicitly left to the
competition. It is therefore ours to model, and it should be a stored,
arbiter-editable property rather than anything derived — deriving it would
invent a rule FIDE deliberately declined to write.

## Performance, from the start

Naive enumeration is fatal, and it is worth being explicit about why: a
bracket of 2n teams has (2n−1)!! pairings. Ten teams is 945; twenty is
6.5×10⁸; forty is about 10²². **Round one is a single bracket containing
the entire field**, so the worst case is not exotic — it is the first
round of any ordinary event.

The regulation is not asking for enumeration, though. It defines an order
and asks for the first element satisfying a predicate. The implementation
must therefore:

* **generate lazily in identifier order** and stop at the first hit —
  never materialise the set;
* **prune on prefixes**: a partial pairing that already repeats a pair
  ([C1]) kills the whole subtree below it, and the subtree is enormous;
* **short-circuit the common case**: with no history, round one's first
  candidate is the natural pairing and satisfies everything, so the
  expected cost is a handful of candidates rather than a search;
* **answer [C3] with a completability oracle** rather than by trying —
  this is a matching-feasibility question, and the individual engine
  already has the shape of the answer in `oracle_completable?`.

That last point is the one place a matching algorithm still earns its
keep: not to *choose* a pairing, but to certify that a choice leaves the
rest of the bracket pairable.

Target: a team round should be well inside a millisecond for realistic
field sizes, because the work is a short walk down a generator, not a
search. If it is ever slow, the pruning is wrong, not the approach.

## Verification: there is no reference implementation

Checked, rather than assumed:

| | teams? |
|---|---|
| bbpPairings 6.0.0 | **no** — no team code at all; `--dutch` and `--burstein` are both individual |
| JaVaFo | no |
| Gacrux (`pairingchecker.py`) | no |
| SWAR 6.65 | **no** — its `Pairing*.cpp` has no team pairing; its "team" hits are TRF `013` block handling, same as ours |

This inverts the method that made the individual engine trustworthy.
There is no oracle to run a corpus against, so "we agree with bbpPairings
across millions of tournaments" is simply unavailable.

**The good news is that the regulation hands back something stronger.**
For the individual system, exhaustive verification was impossible in
principle: C.04.3 defines a sequential procedure, not a global optimum, so
"which whole-round pairing scores highest" is a question with no defined
answer (see
[conformance-c0403-2026.md](conformance-c0403-2026.md), "Why that test is
harder than it looks"). Here the opposite holds. Article 3.6 defines the
answer *as* the first element of an enumerable order — so for a bracket
small enough to enumerate exhaustively, a test can BE the definition:
generate every pairing, sort by identifier, filter by the criteria, and
assert the engine returns the head.

That is a proof, not a correlation. It is available for small brackets
today and does not depend on anyone else having implemented the rules.

The corpus still has a role, but a different one: fuzzing for crashes,
[C1]/[C2] legality violations, and [C3] dead ends — properties that hold
regardless of which candidate is chosen.

## Open questions

* **4.3.1 and the TPN-parity dispute.** Blocked on the SPP reply. Build
  the rest first.
* **Board order.** Unspecified by FIDE; needs a product decision, and it
  interacts with whatever the host application stores per player.
* **Forfeited matches.** [C2] mentions winning a match by forfeit, which
  implies a match-level forfeit concept distinct from a board-level one.
  Needs its own pass against Article 1.
