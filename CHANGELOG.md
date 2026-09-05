# Changelog

All notable changes to Ainalrami are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Each entry is tagged so a version can be skimmed:

| tag | meaning |
|---|---|
| [Feature] | something new you can do |
| [Fix] | something that was broken |
| [Change] | existing behaviour works differently |
| [Removed] | something is gone |
| [Security] | a vulnerability closed, or judged not to apply |
| [Verified] | checked against a reference, no code change |

Entries are a dated record of what was believed and measured at the time.
Where a later version overturned an earlier entry's conclusion, the earlier
entry is marked in place rather than rewritten or deleted - the reasoning
is why the code was that way, and losing it invites the same ground being
re-derived. Look for **SUPERSEDED** markers.

## What the agreement figures mean

Most entries below carry a rate against bbpPairings 6.0.0, and the rates
are real - they come from running both engines on the same file, round by
round, and diffing the boards. What they do not do is prove the engine
right.

Almost every one of the 2.5 billion cross-checked pairings on record here
was measured against a **single oracle**, and agreement with one reference
cannot detect a rule both engines read the same way wrong. The only
instrument that can is the three-way harness, which stands at 649,207
rounds - that is the real precision of the ruler everything else is
measured with. See `docs/validation.md` for the current bound; it is much
tighter than the 0.09% the 3,352-round run supported.

The headline tournament counts also read as more coverage than they are.
In each of the two ~488M-pairing runs alike, 2,724,198 of 5,993,000
tournaments (45.5%) ended early because the reference ran out of legal
pairings, almost entirely in the 4-10 player axes - 88.2% of the `4-10,
15% byes` axis and 78.2% of the plain one. Those tournaments are excluded
from the rates, so agreement is measured up to exhaustion and not about
it: an engine willing to pair a round bbpPairings declines was the one
behaviour these axes were structurally blind to. Whether the four later
corpora exhaust at the same rate has not been measured. The full
statement is
[what the corpus could not see](docs/validation.md#what-the-corpus-could-not-see).

That blind spot was measured on 2026-08-27 and came back clean:
`tools/exhaustion_probe.exs` put 815,479 positions bbpPairings had refused
to this engine, across six axes and 930,000 tournaments, and it refused
every one. What that does NOT establish is that a legal pairing genuinely
does not exist in those positions - two engines can be wrong together, and
the brute-force check that would settle it has not been run. See
[the exhaustion probe](docs/validation.md#the-exhaustion-probe-2026-08-27).

And a clean corpus is evidence a change broke nothing, not evidence the
change was unnecessary. Of the thirteen bugs closed on 2026-08-26, two are
invisible to any corpus this generator can produce and a third had been
breaking a matcher invariant 734 times per 800 tournaments while agreeing
with the reference on every one of them.

## [0.17.0] - 2026-09-05

### Fixed

- `Trf.parse/1` no longer drops a round that is paired but not yet played.
  `serialize/1` pads a `001` line out to the last round's result column on
  purpose, so that such a round is a whole block - without the pad bbpPairings
  refuses the file outright. `parse_games/1` then measured the line after
  trimming trailing whitespace, which deleted exactly that pad, so the block
  measured short and the round was discarded in silence. A caller that writes
  a round's pairings to a TRF and reads them back - which is how OpenPairings
  talks to this engine - saw the round as still open and PAIRED IT A SECOND
  TIME, publishing one set of boards and then quietly producing another. The
  line is now measured as written, matching bbpPairings' own loop condition
  (`startIndex <= line.size() - 8u`); trailing blocks that carry no opponent,
  no colour and no result are dropped afterwards, so a ragged hand-edited tail
  still costs nothing readable.

- An `XXP` line written with any separator but a space now raises instead of
  being discarded. The token parser was `Integer.parse` with the remainder
  thrown away, so `XXP 12,13` read as the single id `12`, the line then failed
  the "names fewer than two players" test, and the exclusion was dropped on the
  floor - the precise failure this module's moduledoc says it raises to
  prevent, since the engine goes on to return a complete, perfectly legal
  looking pairing that seats the two players an arbiter said must never meet.
  `read_260_ids/3` already refused a leftover remainder, so the two spellings
  of one rule now agree, as does bbpPairings, whose `readPlayerId` throws
  `InvalidLineException` here.

## [0.16.0] - 2026-09-04

### Fixed

- `Trf.serialize/2` with `column_legend: true` now writes the ruler and the
  field legend for a tournament with no rounds yet. It was guarded on there
  being at least one round, on the reasoning that a ruler over a row ending at
  the rank column pointed at nothing - but that row still carries the name,
  rating, federation, FIDE id, birth date, points and rank, and a registration
  list taken before the first pairing is exactly when somebody checks whether
  a name has overrun its 33 characters. The legend stops at the rank column;
  no game blocks are invented for rounds that do not exist.

## [0.15.0] - 2026-09-02

### Fixed

- [Change] **The matcher breaks free-vertex ties on a fixed rule** (`{resistance, vertex}`) instead of whichever entry a map happened to yield first. Same machine, same answer as before; the difference is that a different Erlang release can no longer change a pairing. Checked on 645 tournaments, 4,365 rounds, 72,140 pairings: byte-identical output before and after.
- [Fix] The two tree walks in the matcher have a step budget like their siblings, so a corrupted tree would raise a diagnostic instead of looping forever; the trace level is per process rather than per VM; a field with two players sharing a starting rank is refused with the ranks named; and the comment on `top_blossoms/1` describes the code that exists.

- [Fix] **The command line no longer crashes on a round-limited forbidden-pairing (`260`) line.** The file writer was taught that shape in August; the CLI's own report step was named in that fix and missed. Any unexpected exception now ends as a one-line message and exit 1 rather than a stack trace.
- [Fix] **`-p` and `-g` refuse to write over their own input**, and write through a temporary file renamed into place, so a failed write never leaves half a file. `ainalrami x.trf -p x.trf` used to replace the tournament with a three-line board list at exit 0.
- [Fix] **`--rounds=0` no longer plays two rounds and `--players=-5` is refused** - Elixir ranges count down when the end is below the start; every `1..n` in the generator is now `1..n//1`, and both options are validated.
- [Feature] **The generator can write non-ASCII names** (`names: :unicode` - Đurić, Björn, Nguyễn and friends), off by default so every recorded seed still reproduces byte for byte. This is the axis the corpus never had, and why the byte-column bug went unseen.
- [Fix] **Team pairing has a walk budget** (`:max_steps`, forwarded by `pair_round/2`), returning `{:error, :budget_exhausted}` instead of running for as long as an infeasible bracket takes to disprove; the twenty-team construction that took 12.5 s answers in 370 ms with `max_steps: 200_000`. The default bounds a hang, not latency; a host wanting a latency bound passes its own.
- [Fix] **Three public team-pairing entry points validate their input** - an unknown `:score_mode`, a `:parity_numbers` map missing a team, and `Team.score/2` on an unknown mode - returning or raising a named error instead of a bare crash.
- [Fix] The Gacrux harness validates `GACRUX_TIMEOUT` before it reaches a shell string.
- [Feature] **The repository has CI**: compile with warnings as errors, format check, and the suite, on every push.

- [Fix] **A file padded by bytes with one accented name no longer loses that player's round history.** The TRF16 reader indexed fixed columns by grapheme; Swiss-Manager and bbpPairings pad by byte, so "Björn" shifted every later column one place - the rating read 200 for 2200, the federation "ER", and the round's colour and result read as blank, which downstream is "not yet played". Columns are now read and written by byte; an over-long name is cut on a grapheme boundary, never mid-character. A golden fixture pins the serialised output of every ASCII test file, byte for byte, so the corpus parity is untouched. The generator had only ever written ASCII names, which is why 488 million pairings never asked.
- [Fix] **A UTF-8 byte-order mark no longer swallows the first line.** Notepad's default "UTF-8" writes one; the parser dispatched on the first three characters and dropped whatever line carried it - a player, or the tournament name.
- [Fix] **A line cut off inside a round block no longer reads as a shorter opponent number.** A round counts only when its whole block, through the result column, is present; a partial trailing block is ignored, which is what bbpPairings does.
- [Fix] **`initial_colour` accepts `white`/`black` and their initials in either case, and refuses anything else with a `ValidationError`** instead of a `FunctionClauseError`.
- [Fix] **A blank or unreadable `142` line is no assertion of zero rounds**, matching how `XXR` was already read; it neither sets the count nor argues with `XXR`.
- [Fix] Trailing spaces on an `XXA` line no longer invent a phantom round; a malformed `250` line's error names the `250` field rather than a `260` one.


### Fixed

- [Fix] **The new Article 5.2.5 consistency check reported its own
  arithmetic as a reference defect.** `ColourArticle.white_by_5_2_5/4` and
  `implied_initial_colour/3` took the lower TPN as the higher ranked player.
  "Higher ranked" is Article 1.2 &mdash; **score first, then TPN** &mdash;
  and the two disagree far more often than the docstring claimed.

  Its stated reasoning was that a player inside 5.2.5's reach has never
  played, so there is nothing to compare but the TPN. That is false:
  `no_colour_preference?/1` excludes only *colour-forming* games, and a
  half-point bye is worth half a point while forming no colour. A zero-point
  bye, an absence and a forfeit do the same. So two players reach 5.2.5 on
  different scores routinely, and on every such board the parity rule was
  applied to the wrong player and the implied colour came out inverted.

  Measured on Photon on 2026-08-29, replaying `spp5225`'s seeds with the new
  classifier: it fired **53 times in the first fifteen minutes of one axis**,
  with bbpPairings and Gacrux "breaking the article" identically on the same
  seeds &mdash; which is itself the tell, since two independent engines do
  not fail in lockstep. Two firings were traced by hand to completion and
  both dissolved: seed 32000121 round 2 and seed 32000287 round 2 are
  **consistent** once Article 1.2 is applied correctly.

  This is the same defect the engine already found and fixed in itself one
  article up, at 5.2.4 (`order_by_placement/2`, whose call-site comment says
  it is "reachable wherever a player has no PLAYED games at all, which
  arbiter byes produce routinely") &mdash; and structurally the same defect
  filed against Gacrux in
  [docs/finding-gacrux-5-2-4.md](docs/finding-gacrux-5-2-4.md). The
  instrument reintroduced it in a third place. It now calls
  `order_by_placement/2`'s exact expression rather than spelling the rule a
  second time, and four tests pin a board where score order and rank order
  disagree on *same-parity* arrival numbers &mdash; the case that does not
  cancel, and so the only one that can catch this.

  **No published figure moves.** This code shipped 2026-08-29 and had never
  been run against a reference before this measurement, so nothing in
  [docs/validation.md](docs/validation.md) was computed with it.

- [Fix] **A corpus axis could report a clean colour result over zero
  boards.** `PAIRING_FUZZ_INITIAL_COLOUR=b` - lowercase, which nothing
  documented as different from `B` - was written into the TRF verbatim as
  `152 b`. Every reference rejects that, so every comparison failed, and the
  axis printed *"colours: no unexplained disagreement about who is White"*
  over nothing at all. A vacuous pass that reads exactly like a clean result.

  Found on 2026-08-28 when a 300,000-tournament axis of the 5.2.5
  re-measurement finished in 91 seconds. The only signal was a process-error
  counter, and it blamed resource starvation - which was wrong, and which
  sent the reader looking at the box rather than at the parameter.

  Two changes, because the value and the report failed separately:

  - The knob is normalised and validated. `w`/`b`/`mixed` in any case now
    work; anything unrecognised raises with a message naming the legal
    values. The harness already refused `PAIRING_FUZZ_ACCEL` outright for a
    related reason, so this is the established treatment.
  - **The colour line carries its denominator.** It now reads "no
    disagreement about who is White, over 3,257 board(s) formed by both
    engines", and says so loudly when that number is zero. A count without a
    denominator cannot distinguish "nothing disagreed" from "nothing was
    compared", and the whole value of a colour rate is in that distinction.

## [0.14.0] - 2026-08-28

The FIDE Systems of Pairings and Programs Commission answered this project's
question about Article 5.2.5, and answered it against this engine. Both
reference implementations were right. This version conforms.

### Changed

- [Change] **5.2.5's parity is taken on an arrival numbering, not on the
  fixed TPN.** For the round being paired, players are numbered 1, 2, 3 ...
  by ascending starting rank over exactly those who are in this round's
  pairing pool OR who participated in some earlier round. A player who has
  never been paired receives no number at all. Article 5.2.5's parity is
  then taken on that number.

  This changes which player is allocated White on any board where 5.2.5
  decides and somebody has been registered without ever being paired. It
  does NOT change who plays whom - colour allocation runs after the pairing
  is decided.

  The question, sent to the SPP on 2026-08-21, was whether the parity is
  taken on the TPN as C.04.2 Article 2 defines it, or on a numbering that
  skips never-paired players. The answer:

  > The correct behaviour is (b). Why? Because of C.04.2:2.4 ... LATE
  > ENTRIES ... ARE GIVEN AN APPROPRIATE TPN AND PAIRED ONLY WHEN THEY
  > ACTUALLY ARRIVE. ... players who have yet to arrive don't have a TPN.

  Both sides argued from that same sentence. This engine's case was "the TPN
  exists before the arrival; it is the pairing that waits." The SPP reads the
  identical clause as "no TPN until arrival." The reading was backwards, and
  every other conclusion followed from it. See
  `docs/dispute-initial-colour.md`.

- [Change] **The membership test is the result code, not the score.** Which
  prior-round entries count as having participated was not stated by the
  ruling and was pinned empirically against bbpPairings rather than guessed.
  A played game counts, including the unrated `W`/`D`/`L` codes. `U` (the
  pairing-allocated bye) counts; `F` (an arbiter's full-point bye) does not,
  though both score 1.0. `+` counts with or without an opponent, while `-`
  counts only WITH one - `2 w -` participates, `0000 - -` does not. `H`, `Z`
  and a blank round do not. Probes in `tools/tpn_membership_probe*.exs`.

- [Change] **C.04.6 Article 4.3.1 follows, being the same rule.** The team
  system's colour allocation takes the same numbering. This document had
  said team colour should not be finalised until the answer arrived; it was
  not, and 4.3.1 was rewritten here rather than built once.

### Removed

- [Removed] **The harness's colour dispute bucket.** Both comparison
  harnesses split colour differences into "explained by the known 5.2.5
  dispute" and "unexplained", because the dispute's volume would otherwise
  bury a genuine regression. With the engine conforming, that split would
  have become a tautology - a board where this engine differs from a
  reference would be "explained" by its differing from the reference - so
  the bucket is gone rather than left reporting zero. Colour comparison
  against a reference is now flat equality.

  The three-way harness keeps a weaker `:reach` classification for
  bbpPairings-against-Gacrux boards, where neither side is this engine. It
  can now be strengthened; see TODO.md.

### Fixed

- [Fix] **A claim this project published was false when it was written.**
  `docs/dispute-initial-colour.md` gave two reasons for not complying. The
  second was that the references renumber differently from each other -
  "bbpPairings around anyone not paired this round, Gacrux only around
  players who have never played" - so that agreeing with them was not even a
  well-defined target.

  They do not differ. `tools/rip_probe.exs` was built to test exactly that
  hypothesis and refuted it on its first run: where the absent player has
  already played, all three engines answer alike. The refutation was printed
  in the same document's own evidence section and never propagated to the
  paragraph that used it. Re-confirmed against the local bbpPairings binary
  on 2026-08-27.

  It had spread to four places by then - the decision not to fix, the
  README, this changelog, and the three-way harness, where it justified
  weakening a classifier that is the only instrument ever to catch the two
  references contradicting each other. A hypothesis written in the same
  prose register as a result is indistinguishable from one later.

- [Fix] **A measurement with no instrument, found while fixing the above.**
  The reversion of an "exact inverse" fix to `infer_initial_colour/1` was
  justified by figures - 17 of 17, 0 of 17, "27 times in 106", "81 positions
  in 600 fields" - that no script in the tree produced. The conclusion was
  right and now has an instrument: `tools/inference_numbering_probe.exs`
  measures it entirely inside bbpPairings, with this engine deciding
  nothing. Of 189 readable positions from 200 tournaments, 38 split the two
  readings and bbpPairings followed the coloured player's own arrival number
  on 38 of 38, the exact inverse on 0. The old figures are not preserved.

### Verified

- [Verified] **The inference and the allocation use different numberings on
  purpose, because bbpPairings does.** `assign_colour_round_one/3` takes
  parity on the top of the board; `infer_initial_colour/1` takes it on the
  coloured player's own number. That is not an inverse, and making it one -
  which produces a perfect round trip - disagrees with bbpPairings on every
  position where the two readings split. bbpPairings is asymmetric with
  itself here, and the asymmetry is copied deliberately: Article 5.1 leaves
  the initial colour to a drawing of lots and C.04.3 says nothing about
  recovering a lost one, so the reference is the only rule there is.

- [Verified] **Re-measured 2026-08-28: the 64,131 are zero.** The corpus was
  re-run on the same seeds as the figures it replaces - 750,449 rounds,
  7,392,594 boards, **zero** colour differences against bbpPairings, every
  axis independently 100.0% with nothing unexplained. A second corpus on
  different seeds agrees at larger scale: 1,065,373 rounds, 11,164,952
  boards, also zero.

  The run had to show two other things for the zero to mean anything, and
  did. The no-bye control stayed at zero, as it was before the fix. And the
  two boards where bbpPairings and Gacrux contradict *each other* survived,
  on the same two axes and still outside 5.2.5's reach - if the ruling had
  swallowed those, the instrument would have changed rather than the engine.

  The sharpest control is smaller: on 400 identical bye-heavy tournaments,
  v0.12.0 reports 1,255 differing boards and v0.14.0 reports 0, with pairing
  composition byte-identical across both. The instrument produced a nonzero
  on the old engine minutes before producing zero on the new one, which is
  what makes the zero a result rather than an absence.

## [0.13.0] - 2026-08-27

### Added

- [Feature] **`serialize/2` can write the round count as `XXR`.** TRF16's
  `142` and JaVaFo's `XXR n` are the same field, and this module only ever
  wrote `142` - which JaVaFo does not read. A file written here for JaVaFo
  therefore carried no round count that reader could see, and JaVaFo pairs
  the final round differently without one. `opts[:xxr]` writes
  `tournament[:number_of_rounds]` under JaVaFo's spelling instead;
  bbpPairings reads either prefix into the same `expectedRounds`
  (`trf.cpp:1117-1124`) and does not care.

  One or the other, never both. Two spellings of one field in a file only
  one reader will open is a second thing to keep in step for nobody's
  benefit, and `parse/1` refuses a file whose two spellings disagree - a
  refusal the writer should not be able to provoke.

  Found while retiring the sibling app's own TRF16 implementation onto this
  one: it had been concatenating the `XXR` line onto this module's output
  by hand, because there was no way to ask for it.

### Fixed

- [Fix] **`serialize/1` writes `W`, `D` and `L` instead of refusing them.**
  The three letter spellings of an ordinary win, draw and loss are scored
  by `points_for/2`, called played by `game_was_played?/1` and published in
  `result_codes/0` - but `@playing_codes` left them out, so the writer
  raised `ValidationError` ("unrecognized TRF result code") on codes this
  module documents. The reading direction only looked safe because the
  parser folded the letters into symbols before validation ran; that fold
  is gone now too, and both directions are measured against the one list.

  Not hypothetical. The sibling app's pairing path emits these codes for
  SWAR's `1-0U`, `0-1U` and `1/2-1/2U` result strings and hands the text
  to this module, so every unrated game in an export hit the raise.
  `tools/trf_differential.exs` counted it at 39 serialize cases and at 13
  of 83 round-trip cases this module could not write at all; both are zero
  now, with no new divergence group in their place.

  `W`/`L` and `D`/`D` are the only legal pairings of the letters. Whether
  a game reaches the rating report is a property of the game, not of a
  seat in it, so it cannot be rated for White and unrated for Black:
  `W` against `0` is still refused, as is any letter code with no opponent
  (that is a bye wearing the wrong code, and the four bye codes exist for
  it).

### Changed

- [Change] **`parse/1` returns the result code the file actually wrote,
  `W`, `D` and `L` included.** The reader rewrote those three into `1`, `=`
  and `0` on the way in, on the reasoning that one code should mean one
  thing everywhere downstream. For a pairing engine that costs nothing -
  the letters are the same played, scored result - but it is the one
  rewrite a READER of this format must not do: rated-versus-not is the only
  thing the letters carry over the symbols, TRF16 spells them for exactly
  that, and once folded there is nothing left to recover it from.

  Measured rather than assumed. `tools/trf_differential.exs` in the sibling
  app runs both TRF implementations over one corpus and groups divergences
  by cause; this was the largest group in the run at 108 cases, and it is
  now zero with no new group in its place. The consequence lands there: the
  app's importer maps a mutual pair of codes to a stored result, and its
  `W` -> `1-0U`, `L`/`W` -> `0-1U` and `D`/`D` -> `1/2-1/2U` clauses are
  reachable only while the letter survives the parse. Folded, they were
  dead code and every imported unrated game was filed as a rated one,
  silently.

  Nothing downstream needed the fold: `points_for/2`, `game_was_played?/1`
  and `@playing_codes`/`@legal_result_pairs` all read the letters directly,
  and read them that way because bbpPairings does (`trf.cpp:252-270`,
  `278-286`). A blank column still comes back as `nil`.

- [Change] **A 1,001-player odd round is 37% quicker, and no pairing
  changes.** `tools/parity_bench.exs` had shown that one extra player cost
  up to 2.3x the whole round, because an odd field runs a whole-field
  bootstrap matching an even field skips entirely. `tools/bootstrap_split.exs`
  then showed that 56% of that pass was not the matching at all - it was
  building the graph: 2,407 ms to produce a 500,500-edge list and another
  1,409 ms for `WeightedMatching.new/3` to fold that list into the nested
  map the solver reads.

  Both halves are construction, so both could go without touching a rule.
  Per-pair work that was really per-player (`eligible_for_bye?/1`, the
  score-group lookup, the played-opponent scan) is now computed once per
  position; the edge weight is assembled from per-vertex terms it was
  always a sum of; and the bootstrap emits the solver's nested map
  directly, as `new/3`'s new `:adjacency` option, instead of building a
  list for `new/3` to take apart again. Construction goes 3,743 ms ->
  862 ms, the bootstrap 6,621 ms -> 3,090 ms, and the round
  14,291 ms -> 9,016 ms. The parity ratio against the same field one
  player smaller goes 2.04-2.32x -> 1.31-1.45x; the even field, which
  never ran this code, does not move.

  Not one weight changes, and that is checked rather than argued: the
  matcher state `build_state/5` hands to the search - the weight map, the
  ceiling, the duals and the greedy matching - hashes identically before
  and after on all three whole-field solves of a 1,001-player round. On
  top of that, 460/460 byte-identical matchings on
  `tools/matching_baseline.exs`, and 100.00% against bbpPairings on both
  3,000 tournaments x 9 rounds (25,274 rounds) and a deliberately
  odd-heavy 1,500 x 9 rounds of exactly 41 players with forbidden pairs,
  byes and forfeits (13,500 rounds), where the pre-change tree returns the
  same figures down to the colour-dispute board count. See
  [the engineering log](docs/engineering-log.md#the-odd-field-bootstrap-40-s-of-construction-for-a-graph-that-was-already-known-2026-08-27).

  `solve/1` was not touched. It got 22% quicker anyway, which is the
  garbage the discarded intermediate lists used to leave on the heap.

## [0.12.0] - 2026-08-27

Thirteen bug-severity findings from a deliberate whole-codebase sweep, plus
the first cut of team pairing. Several of these change behaviour, which is
why this is a minor bump and not a patch. The work all landed on
2026-08-26, in the nineteen commits from `eb0d539` to `8ea90ce`; the
release is cut the following day.

### Added

- [Feature] **Team pairing, to the FIDE Swiss Team Pairing System C.04.6
  effective 1 February 2026.** A first cut, in separate files throughout:
  nothing in the individual engine is touched, and the weighted matcher is
  not involved at all, because Article 3.6 orders candidate pairings by an
  identifier and asks for the first one complying with [C1], [C8], [C9] and
  [C10], rather than for an optimum to maximise. C.04.6 carries its own
  criteria - C1 to C3 absolute plus completion, C4 to C10 quality, nine
  rungs against the individual system's twenty-one.

  The test is the unusual part. There is no reference this project can
  automate against: bbpPairings, JaVaFo and Gacrux have no team code, and
  Swiss-Manager, which does pair team Swiss and is FIDE-endorsed, is closed
  source. But 3.6 defines the answer as the first element of an enumerable
  order, so for a bracket small enough to enumerate exhaustively the test
  generates every pairing and asserts the engine returns the head, with the
  brute-force definition deliberately sharing no code with the engine. At
  that size it is a proof rather than a correlation. Above it the engine
  takes the pruned path the brute force cannot check, and nothing else
  covers team pairing at all: no corpus row, no reference implementation,
  no oracle, and [validation.md](docs/validation.md#not-covered) still
  lists team tournaments among the shapes the harness generates none of.
  Treat it as a first cut rather than as validated for a rated event.

  Naive enumeration is fatal at size - a bracket of 2n teams has (2n-1)!!
  pairings, which is 945 at ten teams and 6.5x10^8 at twenty, and round one
  is a single bracket holding the whole field - so candidates are generated
  lazily in identifier order, pruned on prefixes and short-circuited on the
  natural pairing.

  One reading is recorded as open rather than settled.
  [conformance-c0406-teams.md](docs/conformance-c0406-teams.md) notes that
  3.6.4 names [C8], [C9] and [C10] as criteria a pairing "complies with"
  when all three are minimisations, which no single pairing can comply with
  in isolation. The engine minimises the three lexicographically and
  tie-breaks on identifier order, which is that sentence made computable -
  not a reading the SPP has confirmed.

### Fixed

- [Fix] **Every TRF this engine wrote for a tournament with a round in
  progress was rejected outright by the reference.** The writer trimmed
  trailing whitespace, which is right for the header and team lines and
  wrong for a `001` line carrying games: a blank result column took the
  separator beside it down too, and the line stopped two columns short of
  its last round block. bbpPairings does not skip the short block, it
  refuses the whole file with exit 3 and an error naming the line rather
  than the cause - so an arbiter's advance bye, a withdrawal with nothing
  recorded yet, or a round paired but not played made the tournament
  unreadable to the reference. Player lines keep their full width now
  whenever the player has games, while a round-one roster still ends at the
  rank column.

  Confirmed while testing and not a defect here: bbpPairings also rejects a
  blank result against a real opponent, so a round that has been paired but
  not played cannot be expressed in TRF16 at all.

- [Fix] **Two opponentless results were scored by their letter rather than
  by what the game actually was, which cost one player the bye and another
  the right board.** A `0000 - +` has no opponent and pays the
  pairing-allocated bye, where this engine paid a win; a `0000 - -` did not
  participate in the pairing and pays the zero-point bye, where this engine
  paid the forfeit loss. Under standard scoring both are invisible, since a
  win and a pairing bye are both worth 1 and a forfeit loss and a
  zero-point bye both worth 0, and the generator only ever writes a `-`
  against a real opponent - so no fuzzed pairing in 488 million could reach
  either, while the parser accepts both shapes from anybody else's file.
  Bye eligibility gained the reference's second condition at the same time,
  which had been written as a bare check for `U` and coincided only while
  `+` scored as a win. On the new fixture bbpPairings gives `4 1 / 2 3 / 5
  0` where this engine had given `4 1 / 3 5 / 2 0`.

- [Fix] **XXC is read now, and the half of it that cannot be honoured is
  refused rather than ignored.** XXC is JaVaFo's free-form spelling of two
  settings TRF16 gives fixed columns to, and it fell through to the same
  silent discard that used to swallow XXP. `XXC black1` inverted every
  colour of round one on exactly the files that carry the line, the ones
  with no colour history to read the draw back from; `XXC white1` happened
  to coincide with this engine's own fallback and was harmless by accident.
  `XXC rank` makes the rank column the effective pairing number for colour
  and tie-breaking, which this engine cannot currently do, so it raises
  rather than pairing a different tournament than the file describes and
  reporting it with full confidence. Two disagreeing XXC spellings in one
  file are not refused, unlike XXR against 142, because the reference
  assigns as it reads and the later line simply wins.

- [Fix] **Checking a tournament that holds an advance bye no longer fails
  on the round it has not paired yet.** An arbiter's bye is recorded before
  its round is paired - that is how the engine knows to leave the player
  out - so a file waiting to have round N paired already carries a round-N
  entry for everyone sitting it out, and the completed-round count was
  taken from the longest game list. The checker then diffed a round that
  had never been paired: the file's side was empty and the replay duly
  paired the position, so every tournament carrying a bye for its next
  round failed its own check and exited 1, with the report naming the
  pairing the file was about to be given as the thing it had got wrong. A
  round counts as paired when any player took part in its pairing now,
  which is the reference's rule as well.

- [Fix] **Pairing a later round directly left its settings behind for the
  next tournament, and honoured only two of the four options it was
  given.** `pair_later_round/2` is as public as `pair_next_round/2`, set
  three of the same process-dictionary keys and cleared none of them, and
  it falls back to whatever it finds there when an option is absent - so
  the leftovers were not inert. A forbidden-pair map from one tournament
  silently forbade the same starting ranks in the next, and a stale round
  count let the final-round colour exception fire in a mid-tournament
  round; the regression test shows it plainly, with the same four players
  pairing 1-4 and 2-3 on the second call instead of 1-3 and 2-4. It also
  never stamped the initial colour, so a direct caller asking for Black on
  board one got White, with no error and a pairing that looks entirely
  correct. All four options are honoured now and the state is cleared
  afterwards.

- [Fix] **The `-x` explanation was computed under standard scoring even
  when the file said otherwise.** `explain_round/3` stamped four of the
  five settings a pairing runs under and left out the point system, so
  every score-dependent rule in the explanation fell back to 1 / 0.5 / 0
  while the pairing it is meant to explain used the file's own values. The
  CLI builds one keyword list and hands it to both, so `-x` on any file
  carrying `BB*` lines paired under one system and explained under another.

- [Fix] **Two ways a written TRF disagreed with the tournament it was
  written from.** Serializing any tournament parsed from a 260 line raised
  outright, because a group parsed from a 260 is a tuple and the writer
  measured it as a list - the parse side was tested and nothing had ever
  written one back, so parse-then-write was not a round trip at all.
  Round-limited groups now write as 260 rather than XXP, since XXP cannot
  express a round range and emitting one would silently widen the ban to
  the whole event, and the 260 writer had also been discarding each group's
  own range in favour of the full tournament. Separately, the point-system
  writer emitted a `BB*` line only where the value differed from the
  default, which is wrong for exactly one field: reading a `BBW` sets the
  pairing-allocated bye to the same value unless a `BBU` has pinned it, so
  a 3-1-0 system with an ordinary one-point bye omitted `BBU` and any
  reader inferred a three-point bye. That was the file being wrong, not
  just the round trip.

- [Fix] **The matcher was driving blossom duals below zero, 734 times per
  800 tournaments.** The reference's matching prologue evens up the parity
  of every exposed base by adding 1 to each of a blossom's vertices and
  taking 2 back off the blossom's own dual, so no edge's dual sum moves.
  This port took the 2 from whichever top-level blossom was exposed, and a
  top-level blossom need not have it to give: one formed at dual 0 whose
  stage ends on an immediately following zero-delta augmentation finishes
  matched, exposed and still at 0, and the next solve drove it to -2. A
  dual below zero is not a dual solution, and every later delta computation
  reads the value as though it were. The reference instead descends from
  the exposed root to the first blossom that has the 2, dissolving
  zero-dual ancestors on the way, which is what happens now. It was
  reachable and common rather than theoretical, but it agreed with
  bbpPairings on all 734 occurrences, so it was latent rather than silently
  wrong on anything measured.

- [Fix] **A generated tournament that ran out of legal pairings wrote a
  round count into its own file that it had not been paired under.** The
  142 and XXR fields state a tournament's intended length, which is what
  every round of a generated file was actually paired with; when a round
  has no legal completion, generation stops at the last round that finished
  and it was writing that number instead. It feeds exactly one rule, the
  gate that relaxes the colour constraints for the last two rounds, so a
  nine-round generation that deadlocked at seven made anything re-pairing
  round 7 apply the final-round exception to a round paired as an ordinary
  one - and the resulting difference read as an engine defect rather than a
  mislabelled file. Six players over five rounds with 40% of them asking
  for a bye each round deadlocks on 1285 of the first 4000 seeds, so the
  shape is not exotic, and the Pairings Checker replaying its own
  generator's output is the first thing to hit it.

- [Fix] **Two harness instruments that were reporting numbers they had not
  measured.** The JaVaFo harness predates the shared tournament generator
  and never adopted it, reading seven of the sixteen fuzz knobs and
  ignoring the other nine - rating mode, acceleration, forbidden pairs,
  point system, numeric extensions, withdrawals, initial colour, maximum
  rounds and the seed range - so setting one was indistinguishable from not
  setting it and the run reported a rate for the default axis under the
  requested axis's name. It raises and names the reason now. And withdrawal
  byes appended the `Z` game without scoring it while requested byes
  applied the point system, so on a system where a zero-point bye is worth
  half a point the withdrawn player's total came up short and the reference
  refused the file, recording the round as a refusal rather than a
  disagreement.

### Changed

- [Change] **The sibling application pairs with this engine by default, and
  this file had never said so.** The last word here about deployment was
  the 2026-08-07 status block's "nothing is wired into the sibling
  application yet", which stopped being true on 2026-08-16, when the
  sibling's `a02dc18` added this engine as a gated option; it shipped in
  that project's 0.15.0 on 2026-08-20. Corrected here rather than left as
  the record. OpenPairings drives two entry
  points, `Ainalrami.Pairing.pair_next_round/2` for the round and
  `Ainalrami.Pairing.explain_round/3` for the arbiter-facing rationale, and
  hands them the byte-identical TRF it already built for JaVaFo, so the
  engine choice decides only what turns those bytes into pairs. Its own
  changelog dates the three steps: opt-in and beta on 2026-08-20, refused
  outright on a FIDE-homologated tournament; permitted there on 2026-08-21
  with a warning instead of a refusal, since FIDE endorses engines rather
  than pairings and that is paperwork rather than a quality judgement; and
  the default for a new Swiss tournament on 2026-08-26, JaVaFo being the
  one you now have to go and pick. It is pinned there at an exact version
  tag, `v0.11.1` at the time of writing, which is the practical reason the
  tags in this project matter.

- [Change] **The test suite compiles without warnings again.** Two
  ungrouped clause sets and two unused parameters printed on every run of
  every fuzz batch, which is the one place a real warning has to stay
  visible.

### Verified

- [Verified] **A whole-codebase sweep hunting for the same rule written
  down twice, and thirteen bugs closed the same day.** The sweep read both
  repositories looking above all for one shape: a rule stated in two places
  that had drifted apart, which is what produced every real bug in the
  recent history here. Twenty-six findings came back for this repo -
  [sweep-2026-08-26.md](docs/sweep-2026-08-26.md) - six confirmed bugs,
  nine more filed as leads and the rest below bug severity, and every
  bug-severity claim was handed to a second reader whose only job was to
  refute it and to default to not-real when uncertain. 18 of the 21
  bug-severity claims survived that pass across both repositories, and a
  later batch of leads went through the same pass with one more refuted.

  The engine's pairing logic came back clean of confirmed defects. The
  leaked process-dictionary state, the dropped options, the two TRF
  writers, the matcher's negative dual and two drifted harness instruments
  did not. Three of the thirteen turned out worse than the sweep document
  had them. What is left open is three real items: the CLI's
  silently-ignored options, the three-way harness's missing colour
  instrument, and two measured optimizations.

- [Verified] **The rate against JaVaFo is measured per axis now instead of
  quoted as one number.** The validation record carried a bare 96.26%
  attached to no axis at all - and the axis is most of the answer. Measured
  with the real jar and zero process errors, as **exact rounds**: round one
  100.00% over 2,000 one-round tournaments, then over 400 five-round
  tournaments per axis, plain 98.82%, 10% arbiter byes 91.22%, 10% forfeits
  89.60%, both together 83.68%. The same five axes as **individual pairs**:
  100.00%, 99.62%, 97.68%, 97.38%, 95.19%. Which of the two is meant moves
  the worst axis by more than eleven points, so neither is quotable on its
  own. The same axes measure 100.00% against bbpPairings, which turns the
  choice of bbpPairings as the primary oracle from a stated preference into
  a measurement: JaVaFo 2.2 implements the superseded 2022 rules, and the
  gap opens exactly where byes and forfeits enter. The table is in
  [validation.md](docs/validation.md#the-references).

- [Verified] **The corpus re-run after the sweep's thirteen fixes came back
  at 100.00%.** 321,105 rounds and 1,561,865 pairings against bbpPairings,
  zero refused and zero illegal, across every axis the harness has at once
  plus a 40,000-tournament small-field batch and a 16-round deep batch.
  What the run does not prove is recorded beside it, because that matters
  more here than the number - the caveats at the top of this file, and in
  full under [what the corpus could not
  see](docs/validation.md#what-the-corpus-could-not-see).

- [Verified] **A fourth case of the bbpPairings C2 defect, from an axis
  that had never been run before.** One disagreement in 476,150 rounds, on
  mixed point systems crossed with withdrawals - a combination no corpus
  had generated, because the withdrawal branch of the generator was writing
  an unscored points column until this week. Rank 6 holds a
  pairing-allocated bye from round 3 and bbpPairings gives it a second one
  in round 9: same defect and same direction as the three cases already
  filed in
  [bbppairings-c2-bug-report.md](docs/bbppairings-c2-bug-report.md). Where
  this one differs is noted rather than glossed - the system
  is football 3-1-0 with the bye worth 3.0, so a bye is worth exactly a win
  and the reference's eligibility test asks for an unplayed game worth at
  least a win, which may be a second mechanism rather than the same one.
  The same file fed to the engine at the commit before this week's fixes
  produces the identical pairing, so it is pre-existing and was surfaced by
  the new axis rather than caused by a change.

- [Verified] **Where the team regulation contradicts its own worked
  example, the article wins and both readings carry a test.** 2.3.2 says to
  maximise the upfloaters' scores, but the example under 3.5.4 assumes
  three players all on 3 points and then states that [C5] picks two of them
  plus a 2.5-pointer, which is a larger score difference, asserted without
  derivation and forced by nothing else in the chapter. The engine follows
  the article; the example's ordering is implemented exactly as written and
  tested on a position that genuinely produces its profile, so whichever
  way it resolves, the failure names the decision.

## [0.11.1] - 2026-08-25

Two conformance fixes taken from the reference source rather than inferred,
and one private copy of a shared predicate deleted.

### Fixed

- [Fix] **The final-round topscorer threshold uses whichever is larger of a
  win and a draw, as the reference does.** It used the value of a win
  alone. `BBW` and `BBD` are free-form numbers in the file, so a system
  where a draw outscores a win parses even though FIDE would never publish
  one, and the reference guards for exactly that case. Measured on a new
  draw-heavy axis added for the purpose, in two arms over identical seeds:
  3,775,174 rounds at 100.00% with the fix against 8,181 wrong rounds
  without it, and zero illegal rounds in either arm - the control does not
  fail loudly, it pairs a different tournament.

- [Fix] **A played but unrated game read as unplayed to anyone using the
  public API's side door.** `played?/1` recognised only `1`, `=` and `0`,
  which is correct for anything the TRF parser produced, because it
  normalises the letter spellings `W`, `D` and `L` on the way in, and wrong
  for a caller building player maps directly - which the public API
  invites. A played game read as unplayed carries no colour and no float.
  It is defined by the same table the reference uses now, and the second
  private copy of a shared predicate was deleted alongside it. Neither
  changes a pairing reachable through the TRF path.

## [0.11.0] - 2026-08-25

The version stood at 0.10.0 from 22 August, set inside the commit that
added per-edge rungs (`e3ae30a`) and tagged `v0.10.0` the same day rather
than released on its own; 0.11.0 (`6c2694b`) is the first commit in this
project whose only content is a version bump. It covers everything from 22
August up to that release commit on 25 August - the downfloat
classification fix, the point system, the harness corrections, and four
corpus runs, one of them the largest this project has done. The two fixes
made after it that same day are in 0.11.1, above.

### Added

- [Feature] **The point system is read from `BBW`/`BBD`/`BBL`/`BBZ`/`BBF`/
  `BBU` and the 162 line, and it is a fuzz axis.** What a result is worth
  was the deepest constant this project had left: every corpus ever run
  here scored a win at 1, a draw at 0.5 and a pairing-allocated bye at 1,
  and never said so in a file. Points decide a player's score, score
  decides the bracket and the bracket decides everything after it, so an
  engine reading these differently does not report different totals, it
  pairs a different tournament and reports it confidently. The engine read
  none of those lines - they fell through to the header parser and were
  silently discarded, the same failure mode 250 and 260 had - and FIDE
  permits valuing the pairing-allocated bye at half a point, so this is a
  configuration a real arbiter can produce today.

  Every code is now split the way the reference splits it, with `F` and `+`
  unplayed but paying a win, only `U` paying the bye, `H` a draw, `-` the
  forfeit loss and `Z` the zero-point bye. Two places that had standard
  scoring baked in went with it: the final-round topscorer threshold was
  missing the points-for-a-win factor, and C2 bye eligibility was a fixed
  list of result codes that is right only while a win is worth 1.0.

  The axis found something on its first run. Five of six named systems are
  clean at 100%, doubling everything included, which cannot reorder anybody
  and so passes as an invariance check - while a loss worth half a point
  sat at 95.10%, with byes as the trigger: without byes it is 100%, and
  with forfeits alone it is 100%. That 95.10% is recorded in its own commit
  with no unit against it, so it is repeated here as it stands rather than
  reconciled with the 88.62% of exact rounds the downfloat fix below
  reports for the same point system later the same day, on a run whose size
  its own commit does not state.

- [Feature] **The explanation says which board carries each criterion's
  cost, not just what the bracket paid in total.** The per-edge rung
  vectors had always been computed and were collapsed to a bracket sum and
  dropped on the next line. `explain_round/3` now reports one entry per
  edge, in board order followed by the cross edges. The bracket's own rungs
  are exactly the column-wise sum of those vectors, which is asserted
  rather than assumed. Worth knowing when rendering one: the top rung
  counts one per edge, so it separates nothing per board and only the
  bracket total means anything there.

- [Feature] **Rating shape and withdrawals are fuzz axes, so the harness
  can generate an unrated junior event and a player who leaves after round
  3.** Ratings had always been drawn uniformly from 1000 to 2800, so every
  player was rated and ties were incidental, which is roughly the inverse
  of real chess - and equal ratings put the initial ranking on a different
  path, which is the foundation of every bracket in every round.
  Withdrawals never happened either, though a player leaving after round 3
  is ordinary. Both were verified to change the corpus rather than pass
  silently, since a mode gone inert would report 100% agreement while
  testing nothing.

### Fixed

- [Fix] **A downfloat is a player scoring better than a loss, not better
  than nothing.** The engine classified any unplayed round worth more than
  zero as a downfloat, where the reference asks whether the points exceed
  whatever the file's `BBL` or `162 L` says a loss is worth - and C.04.3
  article 1.4.3 defines a downfloat the same way. The two readings are the
  same expression whenever a loss pays zero, which is every FIDE-legal
  configuration, and that is why a hardcoded comparison against zero
  survived 2.5 billion cross-checked pairings and then dropped to 88.62% of
  rounds the moment a half-point loss became an axis: with a loss worth
  half a point a half-point bye stops being better than losing, so it is
  not a downfloat, and C14 to C21 were reading a float history the
  reference does not have for every player who had ever sat a round out.

  On the same seeds, 2266 of 2557 rounds before and 2557 of 2557 after,
  with all 200 dumped disagreements replaying clean. The explain ladder had
  scored this engine's own answer as better on C14 in 108 of them and C16
  in 76, which is what a fabricated float history does to a ladder. Not
  reachable under standard scoring, and that is a proof rather than a
  sample, since a loss is worth zero there and the new expression is the
  old one.

- [Fix] **Half of the initial-colour axis had never reached the file, so
  the colour instrument was counting disagreements the harness had
  manufactured.** The harness wrote `152 W` unconditionally: the drawn
  colour reached the engine through its options and never reached the TRF,
  so every Black tournament told the reference White and this engine Black.
  Pairing rates were unaffected, because the comparison sorts colour out,
  but on a fixed seed range the colour instrument drops from 387 disputed
  boards to 210.

- [Fix] **Five ways the Gacrux adapter turned a crashed reference into
  data.** Error 510 is Gacrux's catch-all for an exception escaping the
  checker and the adapter mapped it to a no-valid-pairing result, which
  also truncated the tournament there and so biased the corpus toward short
  tournaments at exactly the point the topscorer rules begin to apply; a
  crash now gets its own outcome, is counted and dumped, is kept out of
  every rate, and the tournament continues on the reference's pairing.
  Gacrux also reports failure inside its output file and exits 0, so the
  adapter read an error page as pairs and killed the run. Roughly 600
  crashes in one run arrived with no traceback at all because
  `pairing.py:216` calls `breakpoint()` and re-raises, and with stdin at
  `/dev/null` pdb takes EOF and dies without raising. Nothing bounded a
  single invocation either, so one stuck child stalled a whole axis
  silently for two hours; a timeout caps it now and reports its exit code,
  which fails the run loudly rather than hanging it.

  Split by whether they actually cost a comparison, the honest crash figure
  moves from 1.1006% to 0.02%: sampled without the biased filter over a
  21,079-round run, 196 of just over 200 are a bare re-raise meaning no
  pairable edges in the bracket, and bbpPairings independently found no
  legal pairing on 196 of 196.

### Changed

- [Change] **The harness draws round count, initial colour, acceleration
  and extension format per tournament instead of fixing them for a whole
  run.** A grid of fixed-value axes only tests the combinations somebody
  thought to write down, and a bug needing a forfeit and an upfloat and a
  short tournament together lives in the ones nobody listed. Each value is
  resolved once per tournament and stashed privately to that tournament's
  own task, so a tournament cannot be built as White and scored as Black.

- [Change] **The three-way harness generates the same tournaments the
  two-way one does.** It is the only instrument that can tell "Ainalrami is
  wrong" from "the reference is wrong", and it had its own generator, which
  produced plain tournaments: uniform ratings, no byes, no forfeits, no
  acceleration, a fixed round count. Both known disputes in 2.5 billion
  pairings are about byes, the one construct it never generated, so running
  it as it stood would have bounded the references' agreement precisely
  where nobody doubted it. Generation was moved verbatim, comments
  included, because the order of the random draws is what makes seed n
  reproduce the same tournament and every dumped dispute in the docs
  depends on it. Two axes raise here instead of running, since Gacrux
  implements no forbidden-pairs concept and reads neither 250 nor 260, so a
  file carrying them is not refused, it is paired as a different
  tournament. Acceleration was refused for the same reason after the run
  delivered 42.23% between the two references over 98,323 accelerated
  rounds against 100.00% everywhere else.

- [Change] **Dumped examples stop at 200 per kind, and the harness says how
  many it dropped.** An axis that disagrees on a few per cent of two
  million rounds writes tens of thousands of files, and a silent truncation
  reads as "that is all of them".

### Verified

- [Verified] **The round-count sweep: R = 1 to 20, 684,901,202 pairings,
  zero disagreements.** 10,793,215 tournaments, 59,966,505 rounds, 20 axes
  and 12.5 hours, with zero illegal rounds - the largest run this project
  has done. It closes the axis that caused the most expensive bug here:
  every corpus before 2026-08-17 held the round count at 9, which is
  exactly the value at which the final-round topscorer floor cannot bite,
  so 2.55M tournaments could not produce a single instance of a defect that
  2,000 tournaments at 8 rounds found at once. Nothing had ever compared 1
  to 5 or gone past 13, so a four-round weekend Swiss sat outside the
  corpus entirely. Written up with what it does not establish, which
  matters more: it holds byes, forfeits, forbidden pairs, acceleration and
  field size constant.

- [Verified] **The cross-axis run: 25 axes, 475M pairings, zero
  disagreements.** Every parameter the round sweep held constant, crossed
  with round counts of 4, 9 and 16: forfeits, forbidden pairs, Baku and
  random acceleration, Black drawn first, numeric 250 and 260 extensions,
  and fields up to 500. Three of the axes run all of it at once, because a
  bug needing three conditions together shows on no single axis. The
  black-first axes are the ones worth naming, since Article 5.2.5 is the
  only place this engine parts from JaVaFo, it turns on the initial colour,
  and every corpus before this had drawn White.

- [Verified] **The randomised and rating corpora, both clean.** The
  randomised corpus, 4 axes and 116M pairings, draws round count, colour,
  acceleration and extension format per tournament rather than per axis, so
  it explores combinations nobody wrote down. The rating run, 16 axes and
  285M pairings, goes after the oldest assumption in the harness: all four
  rating shapes are clean - equal, clustered, half-unrated, entirely
  unrated - as are withdrawals at 8% and 20% and fields of two to eight
  players, none of which had ever been generated.

- [Verified] **Every corpus is counted in one place, with the ceiling on
  all of it stated on the same page.** The total to 2026-08-24 is
  2,536,328,265 individual pairings across 217,470,056 rounds, six corpora,
  82 axes and two disagreements - both the bbpPairings C2 defect that
  Gacrux answers this engine's way. The 2026-08-21 replication is a row now
  rather than an omission, labelled as replication rather than new
  coverage: 487,338,797 pairings genuinely compared against a different
  build on disjoint seeds, which says the matching optimisation is
  correctness-neutral, not that another rule was checked. The "not covered"
  list in [validation.md](docs/validation.md#not-covered) was corrected
  too: unrated players are tested as of the rating run, and non-default
  point configuration came off the list in this same release, since the new
  `BB*` axis is what covers it. What is genuinely left is late entrants, files
  whose `142` and `XXR` disagree, fields above 500, rounds above 20, and
  team events - which 0.12.0 implements but does not fuzz, so they stay on
  the list.

- [Verified] **Articles 3 and 4 are audited against the handbook text,
  article by article, rather than only against the code**, in
  [conformance-c0403-2026.md](docs/conformance-c0403-2026.md). How a bracket is
  built and how candidates are generated had appeared only as a prose
  section about a known divergence, which left the impression of a gap
  where there mostly is not one and hid the place where there genuinely is.
  The honest summary is that every requirement about *which pairing is
  best* is met exactly, while the requirements about *the order candidates
  are generated in* are met by an equivalence argument plus measurement
  rather than by doing what the article literally describes.

## Development history

Everything below is dated rather than numbered, and it runs newest first
like the rest of the file. These were development days, not releases: the
version in `mix.exs` was set three times in passing - 0.1.0 at the
scaffold, 0.9.0 inside the rename commit `16d8abe`, 0.10.0 inside the
feature commit `e3ae30a` - never by a commit that existed to cut one. A
`v0.10.0` tag was cut on 2026-08-22 over that third commit, so the release
tags do start there, and `git for-each-ref refs/tags` shows it alongside
`pre-rewrite-baseline`, `v0.11.0` and `v0.11.1`. What 0.11.0 (`6c2694b`) is
first at is narrower: it is the first commit in this project whose only
content is a version bump.

Rates in this section are against real `javafo.jar` up to 2026-08-07 and
against bbpPairings 6.0.0 after it. That change of reference is itself one
of the findings.

### 2026-08-18 to 2026-08-21 - the reference's own files, speed, and the SPP letter

A 209-player round went from 90 seconds to 0.23 and a 1,000-player round
from 85 to 6.45, and the corpus reached 488,033,862 individual pairings
against bbpPairings 6.0.0 with two disagreements, both of them the
reference's own second-bye defect.

#### Added

- [Feature] **`ainalrami input.trf -x` asks the engine why it paired the
  round that way.** The rationale has been computable since the adjudicator
  needed it, but only as a library function, so a host application had to
  reconstruct the reasoning from the finished boards. `-x` pairs the next
  round and reports, per bracket: who moved down, who lives there, what got
  paired, who floats on, and which of the eighteen criteria actually
  scored. Only the criteria that scored are listed, because a zero means
  the rung separated nothing in that bracket - but the header still gives
  "N of 18 scored, over M edges", so the omission is visible rather than
  silent, and M is there because rung values are sums over a bracket's
  edges and are only comparable across answers when the edge counts match.
  It also fixes the usage text, which still described `-g` and `-c` as "not
  yet implemented" long after both were.

- [Feature] **`-d` prints the bracket loop's own internals, for somebody
  who thinks the engine is wrong rather than the pairing.** Verbose has
  been the default since the start, but it was binary - on, or `-q`. That
  is the right default for an arbiter reading a pairing they disagree with
  and the wrong one for anybody questioning the engine, because the trace
  describes decisions in the regulation's vocabulary and says nothing about
  how they were reached. `--debug` adds a third level: score group, bracket
  size, moved-down count, window, which of the three solve paths it took,
  and a timing. It costs nothing when off.

#### Fixed

- [Fix] **The engine could not read the reference implementation's own
  output, and said so by answering with an empty pairing.** Real
  bbpPairings writes its generated TRFs with a bare carriage return and no
  line feed at all - 212 of them in a 209-player file, zero newlines. The
  parser split on CRLF or LF, which matches neither, so the entire 29 KB
  file parsed as a single line and returned zero players, with no error and
  no warning. No test could have caught it: the comparison harness only
  ever fed this project's files to them, and nothing here had ever read a
  TRF written by anything other than this engine. With the fix that file
  parses to its 209 players and the two engines agree on all 105 boards
  including colour. It is kept byte for byte as a fixture, with
  `.gitattributes` stopping the carriage returns being normalised, since
  normalising them would leave a fixture that passes for the wrong reason.

- [Fix] **A TRF line forbidding two players from ever meeting was thrown
  away, and the round paired them anyway.** TRF 250 and 260 - the
  reference's fixed-column, round-limited siblings of XXA and XXP - were on
  the "explicitly not covered" list, which in practice meant the lines fell
  through to the header parser and were silently discarded. A file saying
  players 1 and 3 must never meet produced a complete, perfectly
  legal-looking round that seated 1 against 3, and that was verified
  happening before any of the fix was written. Every case was checked
  against real bbpPairings on identical bytes, including the ones a
  careless implementation gets wrong in the safe-looking direction: a 260
  whose round range excludes the round being paired must do nothing, and
  one whose last round *is* the round being paired must still bite.

- [Fix] **The 250 lines this engine wrote were rejected by bbpPairings, and
  the 260 lines it wrote could expire early.** 250 and 260 had been
  implemented from the reference's source and covered by unit tests written
  from that same source, so nothing had ever handed the real binary a 250
  written here. The writer right-aligned each field one column wider than
  the C++ reads it, which puts the digit in the separator, so the binary
  reads a blank round and answers "Invalid line". The second was silent and
  only a differential run could have caught it: XXP means "never pair
  these" and has no round limit, and bounding the 260 it becomes at the
  declared number of rounds lets the ban expire on the round actually being
  paired whenever that count is behind, so the two spellings of the same
  tournament pair differently while both files parse without complaint.
  Verified end to end at 150 tournaments and 7,338 pairings, 100.00% exact.

- [Fix] **A file carrying both acceleration forms for the same player
  paired a different first round than bbpPairings did.** The reference
  appends an `XXA` line onto whatever a 250 already filled in; this engine
  overwrote instead, which changed the brackets from identical bytes. Found
  by probing an edge case against the binary rather than waiting for the
  corpus to reach it - the fuzz harness emits `XXA` or nothing, so no axis
  can generate a file with both.

- [Fix] **An arbiter who drew Black, recorded it in the file and asked for
  round one got White pairings.** The TRF's `152` field had been read since
  the previous day, but the CLI never passed it to the engine, so `-p` and
  `-c` fell back to reconstructing the draw from round one's own colours.
  That is right for a file that has a round one and simply wrong for a
  fresh roster - and round one is exactly when it matters most, since
  nobody holds a colour preference yet and every board falls through to
  Article 5.2.5. Before the fix, `152 W` and `152 B` produced byte-identical
  output. `-g` now also takes `--initial-colour=w|b` and writes the `152`
  line.

- [Fix] **A player with one game or none was treated as never having an
  absolute colour clash.** The check required the two latest colours to
  differ, which is false for anybody who has not yet played twice. It says
  what Article 1.7.1 actually says now: a colour difference outside plus or
  minus one, or the same colour twice running, over played games only. Two
  bugs in the validation harness's colour classifier went with it, neither
  in the engine, which had been reporting seven boards as unexplained
  Article 5 disagreements when the engine had them right.

#### Changed

- [Change] **A round of 209 players pairs in 0.23 seconds instead of 90, a
  400-player round in 0.72 instead of 498, and 1,000 players in 6.45
  instead of 85.** Four passes over the weighted matcher first: the code
  was rebuilding a nine-field state map once per neighbour visited, four
  times the work it wrapped; the incremental least-resistance caches that
  [NOTICE](NOTICE) had recorded as deliberately traded away were built; and
  edge weights are divided by their common factor before solving, which was
  worth more than the caches, because one real solve had 21,221 edges
  carrying five distinct weights with a ninety-digit common factor, so the
  innermost operation of the algorithm was arbitrary-precision arithmetic.

  Each pass was held to the same optimum rather than to the same output,
  which is the honest form of the claim: total weight and matched count on
  460 of 460 random graphs, with 38 of those 460 returning a different
  matching of equal weight. Byte identity is deliberately not required,
  because 86% of delta steps have a tied minimum. That the choice among
  tied optima does not move a pairing was measured before the caches were
  written - inverting the tie-break of the old linear scans left the engine
  agreeing with bbpPairings on 1358 of 1358 rounds.

  Then the matcher gained the persistent API the reference's own Computer
  has, and one is carried across a whole round rather than one per bracket.
  The single biggest step there was one misread argument: the reference
  prepares only the modified end of a changed edge, and preparing both ends
  unmatched every vertex in the graph on every finalisation, so each
  "resumed" solve ran as many stages as a cold one. Finally, a bracket is
  paired on its own graph wherever that is provably the same answer as
  pairing the field, with the conditions checked first and a miss falling
  back to the field graph rather than to a wrong answer. One condition is
  not certified term by term and is named in the code rather than assumed.

  Recorded honestly: the work was undertaken to change the growth rate and
  mostly did not, and the unbounded peek is load-bearing - restricting the
  graph to the reference's literal window drops the bye axis to 94.52%, so
  the reference does not *see* less than this engine does, it simply does
  not rewrite the far edges.

- [Change] **The 5.2.5 question is now a one-page letter to the SPP, and
  this engine is not in it.** The full argument is far too long to send, so
  the letter is one page, one question and one table. It asks about
  intent - was the change from pairing number to TPN meant to change
  behaviour - rather than who is right, because a commission can answer
  the first in
  one word while the second invites a debate in which four implementations
  disagree with one, and the one is this engine. It concedes the strongest
  point against that reading up front: JaVaFo predates the current wording.
  The letter is
  [spp-question-initial-colour.md](docs/spp-question-initial-colour.md) and
  the full argument behind it is
  [dispute-initial-colour.md](docs/dispute-initial-colour.md). Removing this
  engine's own column from the comparison table earns its keep twice over:
  with it, the table reads as one newcomer disagreeing with four
  established programs; without it, the same fact reads as the published
  text disagreeing with every program anyone can name.

#### Verified

- [Verified] **5,993,000 tournaments, 44,486,465 rounds and 488,033,862
  individual pairings against bbpPairings, with two disagreements and zero
  illegal rounds.** Seventeen axes, on the engine as it stands with the
  local bracket graph. Both disagreements are the bbpPairings C2 second-bye
  defect, adjudicated incomparable and answered this engine's way by
  Gacrux, so neither is a defect here - one per 22 million rounds against
  an FE1 bar of one per 500. What the run buys is coverage the old corpus
  could not afford: 60-120 players went from 600 tournaments to 300,000,
  and 150-250 and 300-500 had never been run at any scale, which is the
  dimension that mattered because the local graph only engages on brackets
  large enough to meet its preconditions.

- [Verified] **The whole corpus was re-run on disjoint seeds against the
  optimised matcher: 487,338,797 pairings, zero disagreements.** The same
  seventeen axes, seeds from 9,000,001, in about 14.7 hours. The point was
  not another big number: a matching-layer optimisation is exactly the kind
  of change that passes every unit test and is still wrong on the millionth
  bracket. Recorded with two caveats rather than as a clean win - zero
  disagreements does not retire the C2 disputes, since fresh seeds simply
  did not land on that configuration again and bbpPairings is unchanged and
  still wrong there; and 2,724,198 tournaments (45.5%) ended early because
  the reference ran out of legal pairings, so the headline count reads as
  more coverage than it is.

- [Verified] **Two more positions where bbpPairings 6.0.0 hands a player a
  second pairing-allocated bye, one of them with only one legal shape.**
  The bug report against the reference,
  [bbppairings-c2-bug-report.md](docs/bbppairings-c2-bug-report.md), now
  rests on three positions, from three generator axes and two seed ranges.
  The second, found 11.6 million rounds into a fresh run, needs no argument
  about scoring at all: rank 4
  already held a bye and had met every active player but rank 1, so 1-4 is
  forced and every candidate without it strands rank 4 into a second bye -
  and bbpPairings pairs 1-2 and byes rank 4. What distinguishes all three
  is that the ineligible player is short of opponents, which also explains
  the rarity. Gacrux returns this engine's answer board for board on all
  three, and all three are pinned as tests rather than fixtures, because a
  change that made this engine agree with bbpPairings here would show up in
  the corpus as an improvement.

- [Verified] **Article 5.2.5 was rewritten on 1 February 2026, and no
  reference implementation followed the change.** The old Article E.5
  tested the parity of a "pairing number", which A.2 defined as the initial
  ranking "and subsequent modifications depending on possible late entries
  or rating adjustments". The new 5.2.5 tests a TPN, and Article 1.1
  delegates that wholly to C.04.2 Article 2, which permits exactly two
  modifications and draws no distinction between a registered player who
  has played and one who has not. A loose term carrying "subsequent
  modifications" in its own definition was replaced by a tightly pinned
  one, so renumbering is defensible under the old wording and baseless
  under the new. And JaVaFo, the pre-2026 reference, returns byte-identical
  output to bbpPairings on the probe file - all three references renumber,
  including the one that predates the rule. That inverts the strongest
  argument against this engine's reading: three implementations agreeing
  was evidence against it, but shared lineage is not.

  > **SUPERSEDED in 0.14.0.** The SPP ruled on 2026-08-27 that the
  > references were right and this engine was not. The shared-lineage move
  > above is exactly the error: three implementations agreed because they
  > were correct, and this entry explained the agreement away rather than
  > weighing it. The byte-identical JaVaFo output is still a real
  > measurement; only the inference drawn from it fails.

- [Verified] **The gap to bbpPairings was measured rather than guessed, and
  then closed.** Same tournament, same round, same machine, on a file the
  reference's own generator produced so neither side is favoured: 56x
  slower at 209 players and 166x at 400 when the campaign started. The
  published comparison was also flattering this engine by a BEAM start-up,
  measuring the other two cold and this one warm, which was corrected by
  measuring each engine's own floor and subtracting it. Re-measured at the
  end: level with the Python reference and 1.15x to 5.7x quicker than the
  C++ one on pairing work, with identical boards throughout - 200 of 200 at
  400 players and 500 of 500 at 1,000. Four levers were then closed with
  measurements rather than opinion so nobody re-derives them: the natural
  pairing is not the answer, the weights cannot usefully be narrowed,
  parallelism does not help either, and a cheaper feasible dual makes it
  twice as slow. An earlier experiment sits beside them in the same log,
  tried and reverted - mutable arrays for the matcher's bookkeeping, which
  an isolated micro-benchmark had promised at 2.96x and which came out 2.5x
  *slower* in the real module, 1015ms against 395ms on the real 209-player
  solve. All of it is written up in
  [engineering-log.md](docs/engineering-log.md).

- [Verified] **A bracket in the middle of a round is checked against the
  sequence Article 4 generates, not only against bbpPairings.** This was
  the last part of the conformance story standing on corpus agreement
  alone, and the 5.2.5 finding sharpened why that mattered: agreement with
  a reference is only as good as the reference. The strong claim stays
  unavailable and is stated as such - candidates that float different
  players produce incommensurable rung vectors. What is checkable is
  reachability, and 25 or more real middle brackets per run are now checked
  against the generated sequence. The oracle was wrong twice first, both
  times by being weaker than the engine, which is the third time in this
  project a weak oracle has "found" a bug in a stronger implementation.
  Article 4.3's heterogeneous case was closed the same way, by making the
  heterogeneous bracket the last one in the round so no candidate can reach
  an edge into a lower group and the vectors are comparable after all.

- [Verified] **The Swiss Team Pairing System (C.04.6) is written up before
  any of it is built, and it is not the Dutch engine applied to teams**, in
  [conformance-c0406-teams.md](docs/conformance-c0406-teams.md). C.04.6
  carries its own criteria and its own procedure: Article 3.6 gives
  a pairing an identifier, orders pairings lexicographically by it, and
  takes the first one satisfying C1, C8, C9 and C10. That is an order and a
  predicate, not a scoring function. The regulation hands back something
  stronger in exchange: for individuals, exhaustive verification is
  impossible in principle because C.04.3 defines a sequential procedure
  rather than a global optimum, but here 3.6 defines the answer as the head
  of an enumerable order, so for a small bracket a test can be the
  definition rather than a correlation. Two corrections followed the next
  day: Swiss-Manager does pair team Swiss and is FIDE-endorsed, so what is
  missing is not a reference implementation but an oracle this project can
  automate against; and C.04.A grants endorsement "for the specific pairing
  systems (one or more)", so team support blocks nothing about filing FE1
  on the Dutch system.

- [Verified] **The field shapes an arbiter reaches first - an empty
  tournament, one player, two, three - are now covered.** The fuzz harness
  bottoms out at four players and every generated tournament has a complete
  round-one history, so none of these had ever been measured, and an engine
  that raises when somebody adds one player and asks for a pairing is
  unusable long before its bracket cascade matters. All of them already
  behaved correctly, so this is cover rather than a fix. Two are pinned for
  their reasoning rather than their result: a round where every player's
  only history is a bye still pairs, and one player with no history among
  three who each hold a round-one bye pairs only that player, which looks
  wrong at a glance and is precisely right.

- [Verified] **The docs stopped presenting a corpus figure measured before
  the day's changes as if it were current.** The 4.3M-tournament headline
  predated the engine changes and had not been re-run at that scale, and
  "should not have changed anything" is an argument rather than a
  measurement. What was actually re-validated is stated instead: 11,000
  tournaments, 69,038 rounds and 680,022 individual pairings across seven
  axes, all at 100.00%. Two of those axes are new rather than repeats, and
  the round counts deliberately span 6, 7, 8 and 10, because every axis
  measured before 2026-08-17 held rounds at 9.

### 2026-08-16 to 2026-08-17 - conformance, the disputes, and the rename

Two days in which the engine stopped being checked only against another
program and started being read against the regulations themselves.

#### Added

- [Feature] **An arbiter's forbidden pairings and acceleration are read
  instead of thrown away.** The TRF parser understood exactly one extension
  line, `XXR`. Every other `XX` line was dropped without a word, which for
  two of them is not a tidiness problem: an arbiter's "these two must never
  meet" was ignored and the engine then returned a complete, perfectly
  legal-looking round that seated them together, and an accelerated
  tournament formed its brackets on the wrong scores. Measured on the same
  corpus with the engine told nothing, `XXP` at a 20% forbidden rate had
  2281 of 8230 rounds differ from bbpPairings and the same 2281 rounds seat
  a forbidden pair, and Baku acceleration put 5568 of 8421 rounds (66.12%)
  on the wrong scores. Both are validated across eleven new axes at
  100.00%: 1,789,554 rounds and 8,536,147 individual pairings carrying at
  least one extension line, zero disagreements, zero illegal rounds. A
  malformed `XXP` or `XXA` raises rather than being skipped, because a
  missing round count has a fallback and a contradicted exclusion does not.

#### Fixed

- [Fix] **39 of the 40 catalogued disagreements with bbpPairings are gone,
  and one named case is all that is left.** The bootstrap whole-field
  matching that picks the first bracket's bye packs three fields into each
  edge weight and this port had two. The missing one counts how many pairs
  a matching forms inside the top score group, and it is the only one of
  the three that speaks to the matching's *shape* rather than to its single
  leftover player - which is exactly what the C9 gate reads back out of it.
  Without it the gate could be cleared by a tentative match nobody was
  looking at, killing C9 for a whole first bracket while the adjudicator
  reported that rung as 0 against 0. A re-run of the 1,000,000-tournament
  corpus that produced the catalogued cases gives 5822425/5822426 exact
  rounds and 20416198/20416202 pairs.

- [Fix] **In the last round of an even-numbered tournament, a player on
  exactly half the available points was treated as a top scorer.** Who
  qualifies is *more than* half the points played for, an exact half with a
  strict comparison; this engine floored the half instead, so at 7 played
  the threshold was 3 rather than 3.5. It also read the player's own game
  count rather than the tournament's, which a pre-recorded bye makes bite.
  2,510,600 tournaments could not see it, because every axis ever measured
  here ran nine rounds, whose final round is paired with 8 played - and the
  floored half only differs when the played count is odd. Re-measured at 8
  rounds over 2,000 tournaments with 12% byes: 15051/15060 rounds before,
  15060/15060 after. The lesson written into the harness doc is to ask what
  the existing axes hold *constant*, not what they vary.

- [Fix] **Article 5.2.4 was missing from the colour rules entirely, and no
  measurement had ever looked at who got White.** The colour ladder
  implemented 5.2.1 through 5.2.3 and then fell straight to 5.2.5's
  odd-TPN rule, skipping the article that grants the preference of the
  higher ranked player. The larger finding is why it survived: the harness
  sorted each pair's two ranks before comparing, so all 4.3 million
  tournaments and 195 million pairings validated who plays whom and never
  once checked Article 5. On 300 tournaments at 8 rounds with a 15% bye
  rate, colour mismatches out of 22,345 pairs fall from 1708 before 5.2.4
  existed, to 1350 with it added, to 1023 once its higher-ranked test ranks
  by Article 1.2 - score first, then TPN - rather than by TPN alone, which
  handed the preference to the wrong player whenever a pair straddled a
  score group. 5.2.5 had the same defect one article down. Pairing
  agreement stayed at 100.00% throughout, which is the point.

- [Fix] **A tournament whose drawing of lots gave Black was paired as
  though it had given White.** The engine never read TRF's `152` field at
  all - it assumed White unconditionally, so every no-preference colour in
  such a file came out inverted, and no test could see it because the
  harness hardcoded `152 W` and the engine's assumption agreed with that by
  accident rather than by reading anything. The serializer never wrote the
  field either, so a generated file silently lost the drawing of lots and
  real bbpPairings refused it outright. A file that omits `152` has not
  lost the draw: 5.2.5 wrote it into round one, so it is inferred back off
  the first coloured round.

- [Fix] **A win recorded with TRF16's letter code `W` cost the player their
  bye eligibility and scored them nothing.** `W` had been added to the list
  of results that disqualify from a pairing-allocated bye, on the reading
  that it is an unplayed win. It is not one: the reference gates bye
  eligibility on whether the game was *played*, and `W`, `D` and `L` score
  through the same win, draw and loss branch as `1`, `=` and `0`. The
  points table also returned 0.0 for a `W`, which corrupted the
  reconstructed historic scores and with them every float criterion for
  that player. Unreachable through the TRF parser, which normalises `W`
  away - and reachable from a caller that builds player maps directly,
  which the public API invites. The sibling application is not such a
  caller: it hands its TRF to `Ainalrami.Trf.parse/1` first, so this was
  never reachable through it. A
  perfectly legal TRF spelling its results with letters was also being
  rejected outright; the letters are normalised on the way in now.

- [Fix] **Historic scores were wound back from the arbiter's recorded total
  rather than from the games themselves.** TRF columns 81-84 hold a total
  the arbiter typed; where it disagrees with the games on the same line,
  every reconstructed historic score was wrong by the difference, and with
  it every float criterion C14 to C21, silently. The reference does not
  trust that field either. The first attempt at porting it regressed the
  corpus to 88.19% of rounds, which is how the other half was found:
  reconciling the base without also narrowing the fold subtracted a
  pre-recorded future round twice. The old code was self-consistent because
  the two errors cancelled.

- [Fix] **Pairing a later round through the public entry point ignored
  every forbidden pair and never fired the final-round colour exception.**
  `pair_later_round/1` is public and documented, and it set none of the
  process state the rules read. Its docstring made five false claims along
  the way, naming three functions that do not exist and describing a second
  engine that was deleted.

- [Fix] **Every "zero illegal rounds" claim had been resting on a checker
  that shared its central assumption with the engine it was checking.** The
  independent legality oracle opened by declaring that it deliberately
  re-implements the active-field rule rather than calling the engine's own,
  so that a disagreement between them would be a finding. They could not
  disagree: the two functions were character-for-character identical, one
  person's port of one C++ function written twice. The bbpPairings harness
  takes the active set from bbpPairings' own pairing of the same file now.
  An earlier pass had already caught the same oracle reporting 62 phantom
  illegal rounds on a 100k run, because it computed the active field from
  its own loop counter.

- [Fix] **The adjudicator was scoring every float criterion against a blank
  history, and its verdict on the disputed case was an accounting
  artifact.** The real pairing path stamps float history over the whole
  roster; the diagnostic stamped acceleration and colour statistics only,
  so C14 through C21 scored a constant on both sides of every comparison
  ever recorded - it could not manufacture a disagreement but it could
  misattribute one. Separately, each bracket's rungs are a sum over the
  pairs it keeps and the top rung's leading term is one per edge, so where
  one answer contributes one edge and the other two, *every* rung in that
  bracket differs by that arithmetic alone and whichever sorts highest gets
  reported as the deciding criterion. The diagnostic reports an edge count
  per bracket now and declines to name a deciding rung when the two do not
  match. Every adjudication recorded before this is flagged rather than
  trusted, and the fixture README that twice asserted the old verdict - the
  single strongest argument against escalating the dispute - is rewritten,
  because it was not true.

- [Fix] **An MDP could be frozen against a partner in the next score group,
  on a count taken before the matching moved.** The stage that commits a
  moved-down player as matched checked a count captured once when the score
  group was entered, but the step that nudges edges re-solves the matching
  mid-loop. The invariant survived only because a downstream filter this
  port added itself happened to catch it. In the same module, the bye
  legality test restated two of the completion check's three conditions and
  omitted the C5 one; it delegates now. Two of the three bugs found in that
  module came from one rule written twice and the copies drifting.

- [Fix] **Smaller instrument and matcher corrections.** When several
  maximum-weight matchings tied, which one came back was decided by Erlang
  map internals, so the answer could change shape at the 32-key
  flatmap-to-hashmap transition; it is sorted now, as is the vertex order
  of the augmenting search. A latent crash in the matcher's grow step is
  guarded rather than reproduced - no matching this engine is known to
  produce reaches it, and that is stated rather than claimed as a fix for
  an observed failure.

#### Changed

- [Change] **OpenPair is now Ainalrami, at version 0.9.0.** Ainalrami is
  nu-1 Sagittarii A, from the Arabic for the eye of the archer - a name for
  an engine whose whole value is aiming exactly where the regulations point
  rather than somewhere reasonable nearby. It was the one candidate with no
  software, package or company already using it. The rename is mechanical
  throughout, and the sibling project OpenPairings is deliberately
  untouched, which is the whole difficulty of it: OpenPair is a strict
  prefix of OpenPairings, so the obvious search and replace turns 29
  references to the sibling into nonsense. Behaviour is unchanged, with the
  same 133 tests passing as before.

  The documentation was split by audience at the same time: a 318-line
  README doing four jobs at once becomes a README,
  [architecture.md](docs/architecture.md), a validation record that says
  what the corpus could *not* see
  ([validation.md](docs/validation.md)), and
  [engineering-log.md](docs/engineering-log.md), leaving
  [TODO.md](TODO.md) as 60 lines of actually open work instead of 2,493.

- [Change] **Apache-2.0, matching bbpPairings, with a [NOTICE](NOTICE)
  naming exactly what is derived.** Parts of this engine are derived work:
  the bracket
  cascade is a stage-for-stage port of `dutch.cpp`, and the weighted
  matching's control flow was read directly from the reference's sources
  while writing the Elixir equivalent, with originating line numbers cited
  inline. No bbpPairings source is reproduced - it is C++ and this is
  Elixir - but the algorithm and the structure are theirs. NOTICE is
  equally explicit about what is *not* derived: the TRF reader implements
  FIDE's published spec, and the CLI, generator and logging are original.

- [Change] **A TRF that states two different round counts is now refused
  instead of quietly picking one.** A file that has been through both
  toolchains can carry `142` and `XXR`, and two copies of the same number
  are ordinary. Two *different* numbers were being resolved silently, and
  every implementation resolves them differently: this engine preferred
  `142` wherever it appeared, while bbpPairings takes whichever line comes
  last. Given `142 9` followed by `XXR 5`, one reads 9 and the other reads
  5 from identical bytes - and the round count feeds the final-round colour
  exception and the top-scorer threshold, so the loser of that silent
  choice is a complete, perfectly legal-looking final round paired under
  the wrong rules.

#### Removed

- [Removed] **The dead completion-repair pass and the Blossom module behind
  it are gone - keeping them would have been worse than nothing.** Once the
  bye legality test delegated to the completion check, the repair pass's
  guard became the same call that had already returned `:ok` on exactly
  those pairs, so its repair branch was unreachable by construction. That
  path assigned colours by *rank* alone, bypassing Article 5.2 entirely, so
  had the check upstream ever been relaxed the safety net would have
  emitted an illegal round. About 152 lines from the pairing module,
  `blossom.ex` at 233 lines and its test file went with it. The real
  completion fallback is untouched: it is reached, tested, and
  fault-injected. The project's own standard - insurance nothing has
  exercised is a guess - had been applied to that one and not to this one.

- [Removed] **The tool that measured how often the ladder leaves a tie at
  the optimum is gone, because the question it asked is ill-posed.** The
  regulations define no global optimum over whole-round pairings; they
  define a sequential procedure. Two symptoms arrived immediately: two
  round-pairings have incommensurable rung vectors because bracket
  composition depends on which players each one floats, and the enumerator
  checked C1 while checking neither C2 nor C3, so it duly reported legal
  pairings the engine had refused after admitting illegal ones. A weaker
  oracle accusing a stronger implementation is the expected result of that,
  not a finding, and its numbers are not reported anywhere because they
  mean nothing.

#### Verified

- [Verified] **4.3 million tournaments and about 195 million individual
  pairings against bbpPairings, with exactly one disagreement.** This run
  varies the one parameter every earlier axis had held constant. Rounds 6,
  8 and 10 are the new ground across 1.8 million tournaments with zero
  disagreements; 7 and 9 are controls, and they are the point, because had
  they moved the top-scorer fix would have been wrong in a way a
  2,000-tournament local run could never have shown. In FE1's units - its
  bar is one difference per 500 tournaments - the engine stands at one per
  4.3 million.

- [Verified] **The last disagreement is not this engine's bug: bbpPairings
  hands out a second bye to a player the rules bar from one.** Round 7 of
  9, ten players, six of them playing. Ranks 4, 6 and 10 hold arbiter
  half-point byes, and ranks 1, 2 and 3 have each already taken a
  pairing-allocated bye - so the absolute no-second-bye criterion leaves
  four candidates. This engine and Gacrux both bye rank 7 and pair the
  three ineligible players; bbpPairings byes rank 3, who took one in round
  2, and exits 0. It is not implementing a different rule - a minimal probe
  of the same situation shows bbpPairings avoiding the second bye exactly
  as this engine does. With FIDE TEC's 72-page worked companion to C.04.3
  in hand, C2 is confirmed absolute, breaching an absolute is a legality
  failure rather than a quality one, and the document works this exact
  situation twice in its own fifth round and calls it illegal both times.
  [bbppairings-c2-bug-report.md](docs/bbppairings-c2-bug-report.md)
  reproduces every claim in one command without this repository, and
  [dispute-seed735265.md](docs/dispute-seed735265.md) is the FE1 category-3
  position paper for the same round.

- [Verified] **Conformance recorded against C.04.3 (2026) article by
  article, from the regulations rather than from bbpPairings**, in
  [conformance-c0403-2026.md](docs/conformance-c0403-2026.md). Until this
  point the engine's rules had been derived from the reference's source and
  confirmed by measurement but never read off the text. Everything that can
  be checked directly matches, including the two rules fixed that same
  morning. Two divergences are recorded rather than glossed: C5 is enforced
  as a constraint where the articles treat it as the highest-priority
  comparison, equivalent only because the bye assignee's score is
  precomputed as an achievable minimum; and Articles 3.5 to 3.8 pair a
  bracket by generating candidates in a defined sequence where this engine
  solves a weighted matching that reaches the same optimum without
  enumerating.

- [Verified] **The tie-break is Article 4.2 exactly, and Article 4.3's
  order holds on every position tested.** The largest claimed gap between
  this engine and the letter of the regulations was that 3.8.1 breaks a tie
  by which candidate was generated earlier, while the engine breaks it with
  a lexicographic key. For transpositions the two orders are provably
  identical: the key is the S2 index of each S1 member's opponent, S2 is
  sorted by Article 1.2, and board numbers are assigned in that same order.
  A new Sequence module implements Article 4's generation order from the
  text alone - it knows nothing about criteria, weights or legality - and
  serves as the oracle the tie-break claim never had. For 4.3, the sharp
  case is a bracket where no transposition can reach a legal candidate at
  all and the engine returns exactly the size-2 exchange Article 4
  generates first. One finding in the published text: the 11-player
  transposition example's third entry cannot be reconciled with a strict
  reading of 4.2.2 or with its own other five anchors. The honest residue
  is the heterogeneous bracket, whose candidates float different players
  and so cannot simply be compared this way.

- [Verified] **The remaining colour differences are both references
  renumbering a player's tournament number, and this engine is not going to
  follow them.** 5.2.5 gives the initial colour to the higher ranked player
  when their tournament pairing number is odd, and C.04.3 defers that
  number to C.04.2 Article 2, which moves it for exactly two reasons.
  Nothing renumbers it around players who are not paired in a given round,
  yet both references do: bbpPairings by position among those being paired
  this round, Gacrux by position among those paired now or previously. On a
  full field all three agree; they diverge the moment anyone sits out,
  which is why the plain, forfeit, XXP and Baku axes show zero colour
  differences and only the bye axes show any. That control is what makes
  this a diagnosis rather than a story. The mismatch count is deliberately
  not a target: closing it toward bbpPairings would trade a conformant
  implementation for an agreeing one.

  > **SUPERSEDED in 0.14.0**, twice over. The SPP ruled on 2026-08-27 that
  > the arrival numbering is correct, so closing the count toward the
  > references bought conformance rather than trading it away. And the
  > sentence "bbpPairings by position among those being paired this round,
  > Gacrux by position among those paired now or previously" was false when
  > written: `tools/rip_probe.exs` had already measured both references
  > drawing the SAME line. The diagnosis and its control were sound; the
  > claim that the references differ from each other was not.

- [Verified] **The residue is small enough to name case by case, and byes
  turn out to be necessary for every one of them.** 43 disagreements in
  2,527,000 tournaments, about one per 59,000 and roughly 120 times inside
  the FE1 bar, with zero illegal rounds across some 26 million pairings.
  The sharpest result is a controlled pair of 1,000,000-tournament runs
  over identical 4-10 player fields differing only in whether arbiter byes
  were generated: 36 disagreements with byes, 0 without, across 6.0 million
  rounds.

- [Verified] **Late entrants are not a distinct shape, and unrated players
  are not one either.** A late entrant's blank early round is
  indistinguishable from a zero-point bye everywhere the engine looks, so a
  generated late-entrant axis would re-run the arbiter-bye axis under
  another name; it is pinned as tests, because the equivalence is a
  consequence of four separate rules agreeing and a change to any one would
  break it silently. Ratings never reach the pairing module at all. What is
  genuinely not modelled is Art. 2.5 - a real late entry can renumber the
  field while the participant list is open - and this engine takes those
  numbers as given.

### 2026-08-11 to 2026-08-15 - the bye and forfeit axes, adjudicated

The measured gap stopped being a list of unexplained disagreements and
became one bug.

#### Fixed

- [Fix] **Assigning the bye crashed instead of pairing when exactly one
  candidate was left.** When every other player in a round was already
  resolved and a single genuine bye candidate remained, the bye scorer
  walked its range backwards past zero and raised, so the round produced
  nothing at all. It surfaced only at scale: a 100,000-tournament overnight
  run at a 15% bye rate raised 95 times and left 102 illegal rounds
  (0.012%), where every smaller sample up to about 5,500 rounds had shown
  none. Re-running the identical batch after the fix gave 0 raised
  exceptions and 7 illegal rounds, with exact-round matches up by exactly
  95. The standing claim of zero illegal rounds was corrected rather than
  left to stand.

- [Fix] **A tournament whose last recorded round was already complete for
  every player produced no pairings at all.** The rule that decides which
  round is the one to pair had only half of what the reference does. The
  half it had is real and stays - one player's pre-recorded bye must not
  drag the round number forward and strand everyone else - but the second
  half was missing: when *every* player already holds a game for the
  trailing column, that round is fully decided and the round to pair is the
  one after it. Without it the engine tried to pair a round in which nobody
  was active and returned an empty list. Five of the seven illegal rounds
  left from the overnight run were this one rule. Four of those five had
  been filed as degenerate fuzz artifacts precisely because their whole
  field was pre-byed - which is exactly the input this rule exists to
  handle - and the fifth was recorded as the one confirmed-genuine bug on a
  claim that is false of its own fixture; both records are corrected.

- [Fix] **Every measured axis now matches bbpPairings 6.0.0 exactly, and
  all 29 catalogued disagreements are gone.** Brackets were solved one at a
  time, each from scratch, so a decision that turns on where a player ends
  up *outside* the bracket being paired could not be priced at all. The
  matching runs over the whole unfinalised field now, with weights still
  graded by distance so a pair two or more score groups down scores only
  the completion rung and C9 - exactly what the reference leaves on its own
  out-of-window edges - and the comparison bands become graph-sized rather
  than bracket-sized, which is not optional once one solve mixes
  bracket-scored and completability-scored edges.

  Over 4,000 tournaments per axis at 9 rounds, exact rounds and individual
  pairs: plain 98.69% / 99.59% becomes 33708/33708 rounds and 400021 pairs,
  both 100.00%; 15% byes becomes 33601/33601 and 340942 pairs, both
  100.00%; 10% forfeits becomes 33544/33544 and 399201 pairs, both 100.00%;
  and a 90-120 player field becomes 72/72 and 3834 pairs, both 100.00%.
  Zero illegal rounds and zero refusals everywhere. It costs about 2x on
  large fields and nothing on the field sizes that matter. No deterministic
  tie-break was added, deliberately: 100.00% across about 101,000 rounds is
  not compatible with a from-scratch solve picking different maximum-weight
  matchings than an incremental one, but that is an argument from
  measurement, not a proof.

- [Fix] **Two instruments that had been quietly mis-scoring the evidence.**
  The explain output reported C9's single-bye flag as a hardcoded false, so
  C9 came out unscored on every disagreement the adjudication tool had ever
  examined - including the ones being used to decide which rung a
  divergence sat on. And the bye scorer's bootstrap matching left
  incompatible pairs out of its graph entirely, where the reference builds
  a complete graph and gives those pairs weight 1; on a heavily constrained
  field that changes which player the matching leaves over and therefore
  which player takes the bye.

#### Changed

- [Change] **The C9 bye gate is read from the matching now, instead of
  being guessed from the parity of the field.** Both halves of the gate
  were stand-ins invented because the real condition could not be
  evaluated. The first bracket's flag comes off the same whole-field
  bootstrap matching that produces the bye-assignee score, where the "odd
  field, even number of players below" heuristic it replaces fired
  constantly. A related bound was corrected alongside it: the
  partner-scores scan is limited to the next score group rather than
  however far the peek window reached, which is why an earlier experiment
  that widened it regressed.

#### Verified

- [Verified] **The residual gap is one root cause, adjudicated rather than
  counted.** A 4,000-tournament, 33,601-round batch at a 15% bye rate left
  exactly four disagreeing rounds, and scoring the forfeit axis's 25 gave
  the same signature: 23 of 29 (79%) are C9 being applied where bbpPairings
  suppresses it. Two plausible explanations for the rest were tested and
  disproven - not the forfeit-rematch rule, and not colour-history
  contamination. Rebuilding bbpPairings with instrumentation settled it: on
  the traced case the gate was cleared by a floater's tentative match to a
  player who is not in the disputed bracket at all, visible only inside the
  reference's single persistent matcher, which a stateless per-bracket
  solve cannot see. The useful generalisation is that the rung a
  disagreement surfaces on is not the rung that caused it.

- [Verified] **All 25 forfeit-axis disagreements were shown to a second
  reference: Gacrux backs bbpPairings 25 out of 25.** At 99.93% the
  residual sits inside the roughly 0.3% bound on how far the references
  themselves were then known to agree, which is the point at which a
  two-way comparison can no longer distinguish "we are wrong" from "the
  reference is wrong". Gacrux agrees with bbpPairings on all 25, with this
  engine on none, and produces no third answer. It also reclassifies the
  two cases recorded as ties on every rung: this ladder cannot separate
  those answers, but two independent engines picking the same one means a
  deterministic rule decides it that this engine does not implement. "The
  criteria genuinely tie" was a claim about the ladder's resolution, not
  about the rules.

### 2026-08-08 to 2026-08-10 - the right rulebook, and exact agreement on plain rounds

Exact rounds against bbpPairings 6.0.0 went from 87.15% to 98.69% on the
4-40 player axis over three days, and plain tournaments reached 100.00% on
both measures - 4197 of 4197 rounds and 49802 of 49802 individual pairs. It
opens badly: every measurement recorded on this project until then had been
taken against the superseded rulebook.

#### Added

- [Feature] **Four more of the handbook's criteria, C18 to C21, are now
  graded.** C.04.3 effective 1 February 2026 introduced a unified C1-C21
  numbering that the 2022 text did not have, so until now the ladder was
  legible only as the reference's anonymous bit-shifts and its ordering was
  being inferred rather than read. The criteria are written down verbatim
  with this engine's implementation beside each one, and the audit that
  produced them found four absent. Against bbpPairings that took exact
  rounds from 87.15% to 88.57%. A first attempt was inert, and the reason
  is worth keeping: it weighted the score difference by the lower player,
  who in a moved-down bracket is always a resident sharing one score, so
  the term was the same constant for every candidate and cancelled.

- [Feature] **The eight positions where the 2022 and 2026 rulebooks
  disagree are fixtures in the default test suite.** These are the only
  rounds out of 324 where JaVaFo 2.2 disagrees with both bbpPairings 6.0.0
  and Gacrux, which agree with each other on all 324. Both answers are
  frozen into a manifest, so checking which rulebook this engine follows
  takes milliseconds and needs no JVM, no `.exe` and no Python. It is a
  ratchet rather than a pass/fail: how many fixtures pair the 2026 way is
  recorded and the test fails if that drops. The floor started at 2 of 8 -
  the target was not met yet, and pretending otherwise with a skipped test
  would hide the one number worth watching.

- [Feature] **Every disagreement is classified by where the two engines
  part company, and then adjudicated against this engine's own ladder.** At
  around 90% of exact rounds the aggregate rate had stopped being
  actionable and every remaining idea was a blind architecture bet. Of 164
  disagreements: 70 (42.7%) float the same players and hand them to a
  different opponent below, 62 (37.8%) float a different set out, 25
  (15.2%) leave a different player unpaired, and 7 (4.3%) are the same
  floats paired differently inside the bracket. That last bucket overturns
  what the docs had been calling the largest remaining gap - FIDE section
  3's transposition and exchange procedure is 4.3% of failures. The
  adjudicator then scores each case rung by labelled rung, so a case reads
  as "our search failed to reach a pairing our own ladder prefers", "our
  ladder is wrong", or "the criteria genuinely tie".

#### Fixed

- [Fix] **The pairing-allocated bye now always goes to the lowest-scoring
  player eligible for it.** C5 is absolute in the 2026 handbook, and this
  engine satisfied it only by accident - the bye fell out of whichever
  player the lowest bracket happened to leave over. Diffing the references
  isolated the 8 rounds where the two rulebooks genuinely disagree, and
  this engine sided with the old book on 6 of them. The smallest case is
  decisive: 5 players, round 2, where keeping the top bracket intact
  satisfies C6 and strands the bye on a 0.5 player, while the 2026 answer
  splits the top bracket so a 0.0 player can take it, because C5 outranks
  C6 absolutely. One matching over the whole field now runs before any
  bracket is looked at. Exact rounds 88.57% -> 89.93%.

- [Fix] **C7 is stated directly on the candidate pairing instead of being
  summed one pair at a time: 89.93% -> 90.29%.** "Minimise the scores,
  taken in descending order, of the downfloaters" was encoded as a per-pair
  term folded into the packed weight. A sum and a descending lexicographic
  comparison genuinely disagree about which candidate wins, and the
  handbook asks for the latter. Measuring it together with a C8 attempt had
  been misleading; separating the two is what found this at all.

- [Fix] **On a field with an even number of players, a player who had
  already taken a bye was preferred for pairing above every criterion.**
  The reference only computes a bye-assignee score when the field is odd,
  so on an even field the top rung collapses to a constant per edge. This
  engine read a missing bye score as "no score test", so an edge touching a
  player who had already had a bye outscored one that did not, at the very
  top of the ladder. It was inert at the harness's default rate of zero
  arbiter byes, which is why nothing had caught it.

- [Fix] **C9's gate is ported in full, and half of it was worse than not
  having the criterion at all.** The rung was gated on the reference's
  first two conditions only, leaving out the refinement that clears the
  flag when a carried player is already tentatively matched below the next
  group. At an 8% arbiter-bye rate the over-inclusive gate measured 83.14%
  of exact rounds, switching the rung off entirely measured 83.73%, and the
  full gate measures 86.70%: a gate is part of a rule, not a detail of it.
  This also withdrew a deliberate divergence taken earlier the same day -
  dropping the leading term from the completion rung was worth +0.18 exact
  rounds before the visibility fix and exactly nothing after it, so the
  literal reading is the default again and the port carries one fewer
  divergence rather than one more.

- [Fix] **C8 counts only the immediately following bracket, and plain
  tournaments now reproduce bbpPairings exactly.** Letting a bracket see
  further down the field is what made C8 evaluable at all, and it quietly
  broke what C8's own bit means: the reference's graph stops at the next
  group, so its "lower player in the next bracket" can only denote that one
  group, and with several groups visible, pairs formed three groups down
  were still scoring on C8 and swamped the rung until it stopped
  discriminating. Grading the rung by how far a downfloat actually falls
  softened that (95.97% -> 97.51% of exact rounds); restricting it to the
  immediate next group fixed it. Deeper groups stay visible, since removing
  that costs 5.7 points.

  Against bbpPairings 6.0.0 with zero illegal pairings: 4-40 players at
  500x9 is 100.00% of exact rounds and 100.00% of individual pairs, 4197
  rounds of 4197 and 49802 pairs of 49802; 60-80 and 90-120 players are
  also 100.00% and 100.00%. Checked two ways rather than assumed: the
  three-way harness is an independent code path and has this engine
  matching both references on 1261 of 1261 rounds, and JaVaFo stays at
  96.26%, which is the control - it implements the 2022 rules, so an engine
  agreeing with all three at once would mean the harness was measuring
  nothing.

- [Fix] **A player holding a pre-recorded bye had their float history read
  from the wrong round: arbiter-bye tournaments went from 87.65% to 98.15%
  of exact rounds.** The reference indexes float history by the
  tournament's played-round count; this engine indexed it by that player's
  own number of games. Those agree only while every player has exactly one
  entry per played round, which is precisely what an arbiter-assigned bye
  breaks - the lookup landed on that future bye instead of the player's
  last real round, so every criterion from C14 to C21 was reading a
  fabricated history. Byes went from the weakest axis to the strongest.
  Worth noting how long this hid: without arbiter byes the two indexings
  coincide and the harness defaults to none.

- [Fix] **The bracket loop was ending rounds one iteration early, and
  fixing it took exact agreement from 90.29% to 98.69%.** The cascade was
  handing about one round in ten to the older engine, always reporting
  players stranded. That was a one-line bug, not an architectural limit -
  the loop stopped when no score groups were left, which is the state after
  popping the final group, so the round ended on the very iteration that
  first brought that group into the graph. Against bbpPairings with zero
  illegal rounds throughout: 4-40 players 90.29% -> 98.69% of exact rounds,
  60-80 players 82.22% -> 100.00%, 90-120 players 86.11% -> 98.61%, an 8%
  bye rate 81.95% -> 98.99%, a 10% forfeit rate 88.70% -> 98.57%.

- [Fix] **C9 no longer fires in brackets that float two players, taking
  forfeit-heavy events from 99.52% to 99.98% of exact rounds.** The
  handbook scopes C9 to brackets downfloating exactly one player who
  receives the bye, and the gate enforced only the first half of that. A
  bracket that floats two has no single assignee to talk about, and since
  C9 sits above every colour rung, wherever it fires spuriously it decides
  the bracket outright: in one traced case it chose a pairing satisfying
  neither player's colour preference over one satisfying both. Two stricter
  readings were measured and rejected, including gating on the next
  bracket's own size being odd, which was far worse.

- [Fix] **Long events no longer contain rounds this engine refuses to pair:
  142 refusals in 2126 rounds became none.** Running the harness at 39
  rounds filled the illegal column, and nothing illegal was ever emitted -
  all 142 were the engine declining to pair the round at all, which the
  harness reported into the same column as a corrupt pairing. They were not
  impossible rounds: bbpPairings paired all 142 and independent checking
  found no rematch, no repeat bye and no colour clash in any of them. The
  completion repair ranked cardinality above everything else, which finds
  *a* maximum matching but not a particular one, so whenever the one it
  returned stranded a player who may not take the bye, the result was
  rightly rejected and the round refused. Bye eligibility and the bye's
  score are bands of their own directly under cardinality now. The smallest
  of the 142 is pinned as a fixture, and the harness splits refused from
  illegal.

#### Changed

- [Change] **Brackets can see far enough down the field to evaluate C8, and
  the whole-field path becomes the default at 95.97% of exact rounds
  against 90.29%.** C8 asks that downfloaters be chosen so the following
  bracket complies with C1 to C7, and a bracket cannot check that against
  players it cannot see. Extra score groups are visible to the matcher and
  to C8 now - never consumed, nothing in them finalisable. The budget is
  counted in players rather than groups, because a small field has groups
  of one to three where depth genuinely buys accuracy while a large field
  has groups big enough that one supplies the same context. The gain lands
  where it matters: a 60-80 player open goes from four rounds in five to
  179 of 180, and round 9 goes 69.46% to 86.83%. Seeing further and
  finalising further remain different things: a pair is kept only when both
  ends are inside the current bracket.

- [Change] **A whole-field pairing architecture replaces the per-bracket
  cascade, going from 60.51% to 90.11% of exact rounds as it was
  completed.** C8 cannot be expressed in a one-bracket window, which two
  failed attempts established, so this adopts the architecture both
  references actually use. Solving each score level once and taking
  whatever the matcher returned was the entire 30-point gap: the reference
  answers exactly one question per solve and freezes the answer before the
  next is asked, and six of the eight stages were missing - everything from
  the remainder split through exchange minimisation, which is C.04.3
  section 3's transposition-and-exchange procedure in executable form. The
  bracket loop also did not terminate, which is what two tests timing out
  at 120 seconds had been reporting. One result worth keeping: the
  canonical lexicographic tie-break, worth about 40 points on the
  per-bracket path, is completely inert under staged refinement - removing
  it and even inverting it both reproduce the identical answer set, because
  after eight staged solves there is nothing left to choose.

- [Change] **A 90-player open pairs a round in 52ms instead of 7.4
  seconds.** Profiling rather than guessing cleared both prime suspects -
  the lexicographic tie-break's roughly 600-bit integers cost 9%, and C5's
  new pre-pass cost nothing measurable. The cause was the float-lookahead
  beam, which issues beam x depth x n matcher calls on a bracket the
  lookahead has already doubled: 40ms at depth 0, 818ms at depth 1 and
  7371ms at depth 2, a 183x cost for a step measured at +0.30 exact rounds.
  Depth scales to bracket size now, and measured where it engages it is
  free and marginally better.

#### Removed

- [Removed] **The second pairing engine is gone, along with the flag that
  selected between the two.** With fallbacks down from about one per
  hundred tournaments to zero, byes and forfeits included, keeping a whole
  second engine warm for a path nothing takes is worse than not having it.
  Around 950 lines went. The safety net is part of the remaining engine
  now: when the cascade cannot complete a round, one whole-field matching
  runs in three strictly ordered bands - cardinality, then how much of the
  cascade's own answer it preserves, then the criteria as a tie-break - so
  it breaks exactly as many pairs as completion demands. Only when that
  also fails does the engine refuse the round, which at that point is the
  truth.

#### Verified

- [Verified] **A third reference engine settled which rulebook this one
  should be following, and it was not the one being measured against.**
  Gacrux, the pairing half of the FIDE Tie Break Server, now runs alongside
  JaVaFo 2.2 and bbpPairings 6.0.0 on identical positions. Over 324
  comparable rounds bbpPairings and Gacrux agreed on 100.00% of rounds
  while JaVaFo differed from both on the same 2.47%, which is the
  2022-to-2026 rule change showing through rather than engine variance. The
  number worth steering by is the one only a third engine can produce:
  where all three agree there is no rulebook ambiguity, and this engine
  matched on 89.87% of those rounds. No pairing behaviour changed here, so
  that retargeting is a deliberate decision rather than a side effect.

- [Verified] **All three references now run at whatever scale is asked,
  because 324 rounds was not enough to trust the ruler.** Zero observed
  failures in n trials bounds the true rate at roughly 3/n with 95%
  confidence, so 324 clean rounds established only that the references
  disagree on less than about 0.9% of rounds - fine while this engine sat
  at 90%, useless at 98.6% where "we are wrong" stops being
  distinguishable from "the reference is wrong". At 3352 rounds the
  references still agree on 100.00%, which tightens the bound to 0.09%. It
  also settles what the remaining failures are: of the 47 rounds where this
  engine differed, all 47 had the two references agreeing with each other.
  Corrected while checking this: bbpPairings 6.0.0 does implement the 2026
  Dutch rules - its own README calls them the 2025 rules with the effective
  date delayed.

- [Verified] **C8 was implemented properly twice, measured worse both
  times, and reverted both times.** Scoring the largest number of pairs the
  following bracket could form cost 89.93% down to 89.46% of exact rounds
  when ranked above the packed weight, was inert below it, and cost three
  times the runtime on a 90-player field. Scoring the pair count and the
  descending scores together measured 89.88% below the packed weight and
  88.28% above it. The blocker is lookahead depth rather than the measure:
  choosing between one double float and two single floats needs three
  brackets in view.

- [Verified] **Three hypotheses about the remaining error, refuted with
  numbers.** The transposition tie-break is not what the arbiter-bye
  failures are about - it is inert, and promoting it so FIDE's order
  outranks a refinement stage's nudge is much worse, 86.70% down to 79.93%
  with byes; the model is wrong, because stages five through seven exchange
  players between the halves of a bracket, so the key scores transpositions
  against a reference the bracket has already moved away from. bbpPairings
  does not ignore a mild colour preference: requiring both sides of a clash
  to hold a strong or absolute preference took exact rounds from 99.91% to
  57.88% at a 15% bye rate. And a recorded divergence over C10 and C11 was
  withdrawn before it was implemented - the reference does not guard them
  either, and C3 reconciles the two, so a topscorer gate would be redundant
  at best.

- [Verified] **The completion repair is tested, and it is not a compliance
  advantage over the references.** It never fires - measured zero times
  across plain fields, 8% and 15% arbiter-bye rates and 10% forfeits - and
  a safety net nothing has ever exercised is a guess, so a switch now
  restores the old wrong stop condition on purpose and each round is paired
  twice, faulted and clean. On the empirical half, over 118 rounds
  bbpPairings refused, this engine refused all 118, never pairing a round
  the reference could not and never emitting something illegal instead.

- [Verified] **A player credited with an unplayed win could be handed the
  pairing-allocated bye on top of it.** The fuzz harness only ever
  generates half-point and zero-point byes and forfeit wins and losses, so
  no measurement would have caught it, but a real TRF can carry the code.
  (This reading was itself corrected on 2026-08-17 - see above.)

### 2026-08-06 to 2026-08-07 - depth, forfeits, and legality as its own metric

The same question asked at depth - nine rounds instead of two - found that
almost everything the engine believed about colour, floats and forfeits was
a round-2 simplification. Pair agreement across a nine-round sweep went
75.68% -> 97.19%, and whole rounds 38.15% -> 88.93%. The most valuable
finding was not a disagreement at all but illegal output.

#### Added

- [Feature] **A round is now checked for legality on its own terms, not by
  comparing it to JaVaFo.** Agreement and legality are different questions
  and only one of them has a right answer - the largest defect this work
  found was the engine emitting two pairing-allocated byes in an even
  field, which "JaVaFo would have done it differently" does not describe
  properly. The check confirms that a round pairs every player exactly
  once, never repeats a pairing, and hands out exactly one bye in an odd
  field and none in an even one. 2699 of 2700 rounds legal at the time it
  landed; for comparison, when the depth work started, 65 of 104 sampled
  disagreements were illegal output.

- [Feature] **`-c` checks a finished tournament's pairings, round by
  round.** Both the README and the CLI's own help had been advertising the
  flag while the code returned `not_implemented`. It reconstructs the state
  that preceded each round, re-pairs it, and diffs against what the file
  records. Colour differences are reported but never counted as errors,
  since Article 5.1 leaves the first colour to a drawing of lots. It also
  corrects a claim this project had been carrying: a checker is not an
  independent verifier of the criteria, because bbpPairings' own checker
  re-runs its engine and so defines correct as whatever that engine
  produces.

- [Feature] **`-g` generates a random tournament and plays it forward.**
  The other half of FIDE's FE1 auto-test apparatus. The generator pairing
  with the engine under test is deliberate and matches bbpPairings' own:
  the point is to produce tournaments whose pairings a *reference* checker
  then verifies. The seed goes into the tournament name rather than a bare
  first line, which would not be valid TRF, and is chosen before any work
  happens so a crash leaves it recoverable. `-g` output fed to `-c` checks
  clean by construction.

- [Feature] **A weighted blossom matcher is in the tree, verified, and not
  yet used for pairing.** A from-source translation of the primal-dual
  algorithm bbpPairings actually runs, including blossom expansion, whose
  dissolution logic had to be re-derived line by line from the C++ after
  two crashes traced back to a stale model of entry and exit. Checked
  against the existing subset-search matcher as an independent oracle
  across more than 900 random graphs, kept as a permanent regression suite.

#### Fixed

- [Fix] **Colour preference was "the opposite of your last colour", which
  is only true in round two: 75.68% -> 80.64% of pairs.** After two games a
  player can be two colours out of balance, or have had the same colour
  twice running, and both create an absolute preference the old rule had no
  way to express - which is exactly where the measured cliff was, from
  round 3 on. The engine now carries the full model: imbalance, repeated
  colour, the absolute/strong/mild ladder, and four separately ranked
  colour criteria in place of a single "preferences compatible" boolean.
  The gain sits almost entirely in even rounds - round 4 +13.6, round 6
  +14.8, round 8 +11.8 points, against about +1.4 on odd rounds - which is
  what made colour the suspect, since nothing but colour balance has a
  reason to care about round parity.

- [Fix] **The engine now knows who floated up or down in earlier rounds:
  80.64% -> 90.33% of pairs.** Float history was not a criterion at all. A
  float is not written in a TRF - it is derived by comparing what two
  players' scores were at the moment they were paired - so it needs the
  whole roster rather than the pair being scored, and is stamped once per
  round. Four criteria rank directly below every colour criterion. Round 3
  was the cliff the whole investigation started from, at 66.00% of exact
  rounds; it is 99.39% of pairs after.

- [Fix] **A high-priority criterion could be outvoted by the sum of
  lower-priority ones on other boards.** Hand-traced from an 11-player
  round 3 where both engines produced fully colour-legal pairings and
  differed only in who took the bye: JaVaFo's answer had the smaller
  floater displacement and should have won on that criterion, but one step
  of displacement worth 10 was beaten by a rank tie-break worth 8 plus a
  spread difference worth 4 on two other pairs. Every span is multiplied by
  the bracket size now. The harness also gained a dump mode that writes
  each disagreement's exact TRF next to both engines' answers, because a
  rate says there is a problem and a replayable input is what locates it.

- [Fix] **The engine handed out two pairing-allocated byes in an even
  field.** Not a legal pairing under any reading of the rules, and the
  single largest failure mode at depth: 65 of 104 dumped disagreements had
  two or more byes. Maximising one bracket in isolation does not maximise
  the round - a bracket paired everything it could, which left a final
  bracket of exactly two players who had already met, so both floated and
  both became byes, where JaVaFo takes a slightly worse matching one
  bracket up and floats two extra players down so the last bracket can
  finish. The cascade keeps the best matching for each achievable number of
  floaters, walks them best-first, and treats the legal bye count as a hard
  requirement rather than something scored. Pairs 90.44% -> 92.92%, whole
  rounds 63.70% -> 73.04%; on a deliberately harder 10-12 player, 7-round
  configuration, pairs 80.13% -> 87.05%.

- [Fix] **A player can no longer be given a second pairing-allocated bye.**
  C2 is the absolute criterion this engine had never implemented, listed as
  a known simplification in its own documentation, and the backtracking
  cascade is what made it enforceable: the search now has to *find* a legal
  bye assignee rather than merely prefer one. A forfeit win also
  disqualifies, since it is an unplayed game already worth at least a win,
  while a half-point bye does not. The two metrics disagree about the
  change - whole rounds 73.04% -> 73.85% while individual pairs 92.92% ->
  92.62%, because satisfying the rule forces backtracking that moves other
  pairs. Kept regardless: a pairing that gives somebody a second bye is
  wrong even when it agrees with JaVaFo on more boards.

- [Fix] **Having once had a bye no longer protects a player from being
  floated down: 92.62% -> 93.61%.** Traced from a 15-player round 4 where
  the "do not downfloat a player with an unplayed round" term outweighed
  the whole pairing difference, 5300 against 3. That term came from round-2
  tuning and had been generalised further than the rule supports: the
  equivalent criterion applies only to players on the bye assignee's score,
  so it means "minimise the unplayed games of the bye assignee", not a
  standing protection for anybody who has ever sat out.

- [Fix] **When a bracket's best arrangement leaves the round unfinishable,
  the engine tries a different arrangement rather than a worse one: 93.61%
  -> 96.11% of pairs, 76.93% -> 85.63% of rounds.** With one candidate per
  floater count, the only fallback was a strictly worse matching, while
  JaVaFo simply takes a different two-pair matching that floats somebody
  else. What the cascade needs to vary is *which* players float; the count
  is incidental. Two costs are worth recording: alternatives have to be
  enumerated by floater count first, because a global sort by weight fills
  the list with one-floater variants and loses the ability to float more
  players when that is the only way to finish; and a new candidate must be
  appended before the stable sort, never prepended, because that
  one-character difference cost round 2 forty points (99.89% -> 60.71%)
  while every reported weight stayed identical. Raising the number of
  alternatives kept then bought a further 96.11% -> 96.47% of pairs, while
  raising the search budget from 400 to 5000 nodes moved the number by 0.01
  points, so the budget was never the constraint.

- [Fix] **A forfeited game was counted as played, which inverted colour
  preferences and hid unplayed rounds: 69.86% -> 88.67% of pairs on
  forfeit-carrying data.** The comparison harness had only ever produced
  wins, losses, draws and pairing-allocated byes, leaving whole branches of
  the engine with zero coverage; generating forfeits found four real bugs
  of one family on the first run. A forfeit is the awkward case on
  purpose - it occupies a pairing slot and carries both an opponent and a
  colour in the TRF, so it looks like a played game to anything that tests
  for the presence of one, while FIDE Art. 16 treats it as unplayed.
  Colour balance counted it and could extend a repeated-colour run,
  inverting a player's preference outright; float direction scored it as
  though a game had
  happened; and the bye-assignee criterion and the colour-alignment check
  could not see it at all. Whole rounds went 30.05% -> 60.04% at 10%
  forfeits, and the clean-data measurement was unchanged, so this is
  strictly new coverage rather than a trade.

- [Fix] **Two players whose game was forfeited may be paired again: 88.67%
  -> 93.76% of pairs.** The most serious of the forfeit family, because
  no-rematch is absolute rather than scored: two players who were paired
  and forfeited have not met over the board, and the engine had been
  forbidding the rematch anyway. Confirmed against real JaVaFo before the
  change rather than inferred from source - on an 11-player round 2, two
  players who double-forfeited round 1 were paired with each other again by
  JaVaFo in preference to two rematch-free alternatives. The harness's own
  legality check had the stricter rule baked in too, and reported 443 false
  rematch violations once the engine was fixed.

- [Fix] **Two players who both must have the same colour cannot be paired
  at all - except in the last round, between the leaders.** The engine had
  this only as scored criteria, so a bad enough position elsewhere could
  buy a pairing the rules do not allow. Making it a bar took pairs 96.48%
  -> 96.97% and whole rounds 86.78% -> 88.41%, and moved round 9 the other
  way, which was the predicted sign of the missing half: the clash is
  allowed in the final round when either player is above half the maximum
  possible score, rather than leave a tournament's decisive game unplayed.
  That needed the expected round count, which the engine was never told and
  now takes from the file's own `142`/`XXR` line. Only round 9 then moved,
  89.91% -> 91.54%, with every other round identical to the digit; overall
  97.15% of pairs and 88.93% of rounds.

- [Fix] **A player who had already been given a result for the round was
  paired anyway.** There is no TRF flag meaning "this player is not playing
  this round" - the mechanism real tournaments use is that the arbiter
  records the result in advance and the engine leaves that player out.
  Confirmed against real JaVaFo on a six-player case where somebody holding
  a half-point bye was given a game as well. Working out how many rounds
  have been played needed care, and both obvious answers are wrong: the
  minimum games count breaks on a late entrant and emptied the pairing
  entirely when measured, while the maximum breaks on the pre-recorded bye
  that is the thing being detected. Only games the player took part in the
  pairing for advance the count.

- [Fix] **A file that states its round count only as JaVaFo's `XXR` line
  was paired as though the round count were unknown.** `XXR` is what JaVaFo
  itself consumes, so plenty of files carry it instead of TRF16's `142`.
  Found by fuzzing generated tournaments through the checker across 250
  configurations: 246 clean, and all four failures were in the final round
  and no other, which is diagnostic, since the last round is the only round
  the top-scorer colour exception can fire in. Re-run: 250/250 clean.

- [Fix] **An unfinishable round is repaired into a legal one instead of
  being emitted with the wrong number of byes: 1477 of 2997 rounds illegal,
  then 65, then 1.** A legal round that differs from JaVaFo is worth more
  than an illegal one that happens to share some boards with it, so when
  the cascade gives up, its best-effort answer is now augmented along
  alternating paths. That alone left 65, and those were not noise: they
  were exactly the cases a blossom-blind search cannot reach, where the
  augmenting path exists only through an odd cycle. A direct translation of
  Edmonds' 1965 algorithm closed them, checked against an independent
  brute-force maximum-matching oracle before it was wired into the repair.
  Pair agreement moved 62.89% -> 60.93% -> 61.09% at depth, and the drop is
  the trade being made deliberately, because those rounds were illegal
  before.

- [Fix] **The last-round exception for the leaders admitted players a point
  short of qualifying: the final illegal round went to zero.** The
  threshold is half the points available from the rounds *actually played*,
  not half the tournament's eventual length, and the two differ whenever
  the round count is even. One line. At 9 rounds, 97.15% -> 97.19% of pairs
  with illegal rounds 2 -> 0; at 30 rounds and 32-40 players, 2997/2997
  legal, the hardest configuration measured in this project. It also means
  the earlier guess that the last illegal round was the search-budget cap
  was wrong, which is worth recording because it was stated with more
  confidence than the evidence supported.

- [Fix] **When no legal round exists, the engine says so instead of quietly
  printing an illegal one.** The last-resort repair is proven to reach the
  true maximum matching regardless of where it starts, so if its result
  still leaves too many players unpaired, that is proof no legal completion
  exists rather than a search that ran out of room - and it had been
  returning that still-illegal pairing anyway. Found by re-measuring
  legality on the arbiter-bye configuration: 3 of 2119 rounds had a bad bye
  count, and an independent exhaustive search confirmed all three were
  genuine deadlocks. Re-verified across 800 generated tournaments and about
  5,500 rounds at bye rates of 0, 5, 8 and 15%: zero illegal rounds.

- [Fix] **The bar on a second pairing-allocated bye was only ever checked
  by one of the paths that can assign one.** C2 was enforced as the
  backtracking search's own success condition and nowhere else - not by the
  greedy fallback, not by the bye-count repair, and not tested for by
  either harness's legality check. The repair pass checks eligibility
  rather than just count now, and orders the blossom search so ineligible
  floaters get first claim on any augmenting path, since a
  maximum-matching guarantee does not say *which* vertex is left unmatched.
  Byte-identical at an 8% arbiter-bye rate, which suggests backtracking had
  been finding these by trial and error most of the time.

#### Changed

- [Change] **One comparison harness for every round, reporting agreement
  per pair as well as per round.** Rounds 1 and 2 had their own
  near-identical test files. The pair-level number matters because one bad
  pair in a 20-player field previously scored the same as ten. Process
  errors are reported separately, so a resource-starved run cannot be
  misread as a pairing failure. Every figure after this point is pair
  agreement over a multi-round sweep, not the round-2-only number that came
  before it.

#### Verified

- [Verified] **First measurement against bbpPairings itself: 86.32% of
  rounds and 95.92% of pairs exact, 0 illegal.** Everything until now was
  against `javafo.jar` only; bbpPairings had been read as source but never
  run against this engine's own pairings. Two integration findings,
  established by invocation rather than assumption: its output is
  byte-identical in shape to JaVaFo's, and it requires an explicit
  initial-piece-colour field for round 1 and signals "no valid pairing"
  through exit code 1 with no output file. The 0 illegal rounds
  independently confirm the legality work, because bbpPairings agreed the
  structural-deadlock cases really are unpairable.

- [Verified] **The engine is sound to about round 10 to 12 and breaks past
  15, and what governs that is how many opponents are left, not how many
  rounds have been played.** Measured over 30 rounds at 32-40 players,
  agreement does not decay gently: 100% through round 3, 92.70% at round
  10, 80.97% at 13, 64.07% at 15, 47.89% at 17, 37.14% at 20. Holding the
  round count at 15 and varying only the field size separates the causes:
  18-20 players scores 79.45% with 26 of 150 rounds illegal, 34-36 players
  90.62%, and 60-70 players 97.76% with one illegal round. So a 9-round
  Swiss in 40 players and a 15-round blitz in 60 both sit near 97%, while a
  20-round event in a 30-player field does not work. Raising the search
  budget from 2000 to 50000 does not help and makes the run intractable. An
  earlier claim that a 60-70 player field is intractable is withdrawn - it
  is only slow.

- [Verified] **Three changes that looked cleaner than what they replaced
  measured worse, and are recorded with the numbers that killed them.** The
  score-weighted float criteria, ported faithfully from the reference,
  measured 93.40% against the current 97.15%, and disabling half the family
  gave 93.27%, so it is structural rather than a porting slip: the
  reference matches two brackets together, so only some edges receive the
  term, while pairing one bracket at a time gives it to every edge with a
  bracket-local index. Merging the current bracket with the next one into a
  single matching measured 97.19% -> 58.48%, because the
  natural-correspondence machinery is defined against one score tier.
  Replacing the cascade's backtracking with a single direct weighted match
  per bracket dropped pairs 97.19% -> 81.99% with 302 rounds newly
  reporting no valid pairing.

- [Verified] **bbpPairings' matcher is Galil/Micali/Gabow 1986 weighted
  blossom, and there is no simpler variant hiding inside it.** Settled from
  its own source. Bracket sizes were measured to find out whether this
  engine needs it at all: over 2504 brackets from 40 generated tournaments,
  a single bracket runs a median of 4 players and a 90th percentile of 11,
  with 91.4% of combined pairs inside the reach of the exact subset search
  already in use.

- [Verified] **The status block says what is not proven.** It had been
  stale, reporting only round-1 and round-2 figures from before the depth
  work existed. It reports round 1, round 2 and later, depth over rounds 1
  to 9, and legality together now, and states plainly that no
  cross-validation against bbpPairings has been run and nothing is wired
  into the sibling application yet.

### 2026-08-05 - the scaffold, round one, and the bracket cascade

Scaffold to 99.75% of round-2 pairings against real `javafo.jar` on the
2,000-history tuning set, in one day; 99.85% on a 6,000-case
re-measurement.

#### Added

- [Feature] **The engine exists: TRF16/06 in and out, a JaVaFo-shaped
  command line, and no pairing algorithm yet.** The scaffold reads and
  writes FIDE's TRF16 and TRF06 files and mirrors JaVaFo's actual
  invocation shape, confirmed against the call the sibling project really
  makes rather than guessed from documentation. Asked to pair, it loads,
  validates and reports the roster and then says plainly that the Dutch
  algorithm is not written, exiting 2, rather than producing output that
  looks like a pairing.

- [Feature] **Round one pairs, and matches real JaVaFo on 20,000 random
  rosters.** Rank-order top half against bottom half, with the odd field's
  lowest rank taking the pairing-allocated bye, checked against real
  `javafo.jar` output for 7- to 13-player fields rather than read off the
  spec text. Colours follow a fixed, documented convention of the engine's
  own instead of copying JaVaFo: Article 5.1 leaves the first colour to a
  drawing of lots, and the identical roster under two different tournament
  names produced opposite colours from JaVaFo, which is strong evidence of
  a hash-seeded choice nobody can reverse.

  An earlier 100,000-roster run reported 6.29% and was worthless - every
  one of its disagreements turned out to be a `javafo.jar` process that
  failed to launch under load - so it was repeated alone and reported
  honestly in both forms: 20000/20000, 100%.

- [Feature] **Rounds two and later pair, by cascading score brackets and
  floating what will not fit.** Brackets form by score then rank, a bracket
  that cannot pair floats its own worst-ranked players down into the next
  one, and each bracket is matched by a real backtracking search. The
  comparison harness built alongside it immediately found something that
  was not a flaky mismatch: on an 18-player case with zero rematch
  conflicts, JaVaFo still chose the legal pairing where every pair had
  complementary colour preferences. Colour preference is therefore one of
  the criteria that decides *who plays whom*, not a separate step applied
  after composition is fixed.

#### Fixed

- [Fix] **Colour history from previous rounds was silently ignored in every
  round after the first.** The two functions that read a player's past
  colours compared against `:white` and `:black` while the TRF parser
  stores `"w"` and `"b"`, so every decision fell through to the round-1
  convention and no player's colour balance ever mattered. Colour
  preference is now scored inside the bracket search, and the fast path
  that skipped the search whenever the naive split happened to be
  rematch-legal is gone, since that shortcut was precisely the failing case.

- [Fix] **A bracket of 16 players never finished pairing.** The exhaustive
  per-bracket search ran close to double-factorial in bracket size: 194ms
  at 12 players, and no answer within 60 seconds at 16 during a real
  comparison run. Each bracket is matched by a memoised bitmask search now,
  and a fully-tied 40-player bracket finishes in about 13.5 seconds. The
  rewrite exposed a gap of its own: floating the literal worst-ranked N
  players is not always enough, because a different single floater can
  legalise a bracket the worst-ranked one cannot.

- [Fix] **Restricting a bracket to better-half-against-worse-half was
  wrong, and re-floating the same player twice was worse: 10.7% ->
  66.24%.** The first attempt at making brackets tractable hard-restricted
  matching to a top/bottom split, which measured 10.7% and regressed a case
  that had matched exactly before. Real FIDE-family engines treat that
  membership as a weighted bonus, never a structural exclusion, and
  restoring general matching brought the same comparison to 51.7%. What
  remained pointed at one thing: both engines agree somebody must float
  down two bracket levels but disagree who, and JaVaFo strongly prefers
  floating a bracket's own fresh resident over re-floating a player already
  floated once. That took it to 66.24%.

- [Fix] **A bracket that floaters dropped into no longer splits down the
  middle: 66.24% -> 69.1%.** Article 3.3.1 says that where players have
  moved down from a higher score group, those players alone form the top
  half and every resident forms the bottom half, so a moved-down player
  pairs against the best-ranked resident it can rather than against whoever
  a naive half-split puts opposite it.

- [Fix] **A player with no colour preference at all was treated as
  violating colour in every possible pairing: 69.1% -> 82.25%.** Somebody
  whose only previous round was a bye, or who entered late, has no
  preference to satisfy and constrains nothing, but the scoring counted
  them as a violation whichever way they were paired. That corrupted the
  dominant term of the weight function, and it affected every odd-sized
  tournament, because an odd roster always produces a round-1 bye.

- [Fix] **A player who already sat out a round is no longer the one floated
  down: 82.25% -> 88.4%.** Traced from a three-player top bracket where the
  third player had taken round 1's bye. Colour satisfaction was identical
  either way, so the unplayed round is the only thing separating the two
  answers.

- [Fix] **A floater took a distant opponent instead of the nearest one it
  could play: 88.4% -> 99.75%.** Displacement was summed over both members
  of a pair, so the resident's own half-split partner distance drowned out
  the floater's and genuinely different options tied. Article 3.3.1 is
  about which resident the moved-down player takes; the resident's own
  natural partner has nothing to do with that choice, so displacement is
  measured from the floater's side only.

#### Verified

- [Verified] **99.85% of round-2 pairings at 6,000 cases, and round 1 still
  100%.** The round-2 scoring was tuned against 2,000 histories, so it was
  re-measured on three times that case set: 5991/6000, slightly above the
  99.75% tuning-set rate, which is evidence the scoring terms are not
  overfitted to the cases that produced them. Zero `javafo.jar` process
  errors, checked explicitly.

- [Verified] **A cleaner-looking rule for how far a pairing may stray from
  the natural correspondence measured worse, twice.** Replacing the
  rank-spread tie-break with a whole-bracket deviation metric explained the
  traced cases but scored 33.9% against 66.24% when first tried, and 64.95%
  against 99.75% when retried after the colour, bye-float and floater fixes
  had all landed. It stays scoped to moved-down players' pairs, where it is
  confirmed. Both measurements are on record, not only the successful one.
