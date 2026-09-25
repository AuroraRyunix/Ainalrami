# C.07 tie-breaks: an independent reference

Written 2026-09-25. Code: `test/support/tiebreak_reference/reference.ex`
(`Ainalrami.TiebreakReference`) and `test/support/tiebreak_reference/proof.ex`
(`Ainalrami.TiebreakReference.Proof`, the events and the comparison); test:
`test/ainalrami/tiebreak_reference_test.exs`.

## Why

`Ainalrami.Tiebreaks` was cross-checked against FIDE's TieBreakServer on
100,000+ tournaments (`docs/validation.md`). Where TieBreakServer is wrong
(findings A-D in `docs/finding-tiebreakserver-2026-09.md`) or reads the rules
differently (reading 8, STD), the comparison tools classify the difference
as "known" and set it aside. On those points our answer was backed by our
own reading only: STD, SB/C1 with voluntary unplayed rounds, FB before
other codes, direct encounter after repeated meetings, EDEBT/EDEBB and Board
Count after EDE, the Koya maximum and limit, the 16.4.2 cap, "over the
board" against 15.2, Article 16's categories, the dummy and 16.5's cut.

This is the second opinion for those points, built the way the team-pairing
proof was (`docs/team-proof-large-fields.md`): a deliberately naive second
implementation written from the text, compared value for value.

## Independence

- It shares no code with `lib/ainalrami/tiebreaks*`: no calls, no helpers.
  It has its own code parser, its own event model, its own Article 16, its
  own direct encounter and its own copy of the two FIDE rating tables,
  transcribed again from the Rating Regulations (8.1.1 as a list from
  p = 1.00 down, 8.1.2 as the lower edge of each band - not the engine's
  shapes).
- Individual events are read from `Ainalrami.Trf.parse/1`'s map, not from
  `Ainalrami.Tiebreaks.Event.from_trf/2`: the classification of every round
  (game, forfeit, which bye) and its points are the reference's own, so a
  mistake in the engine's TRF reading would show too.
- Team events are read from the fields of the `%Ainalrami.Tiebreaks.Team{}`
  the engine is given (its teams, matches, match and game points, boards).
  `Team.from_trf/2`'s reading of board-level TRFs is therefore NOT checked.
- Clarity over speed: every score is recomputed where it is used, a
  participant's rounds are rescanned for every category, PTP is a linear
  search from 800 below the lowest opponent, and Article 6.3's "whatever the
  outcome of the missing games" is checked by enumerating every
  win/draw/loss assignment when there are at most eight missing games
  (3^8 outcomes), reading 6's closed form above that.

## Readings

The reference takes every reading in `docs/conformance-c07-tiebreaks.md`
(1-11, T1-T4) and cites them where they apply. Agreement proves that the
engine computes those readings; it says nothing about whether they are
FIDE's. Writing the reference from the text turned up four points the
conformance document does not record, where both implementations made the
same choice and the text leaves room:

**Q1 - SSSC's normalising factor can round to zero (13.4.2 b).** "The
highest achievable primary score in the tournament divided by the highest
secondary score achievable in a single match, rounded to the nearest
integer towards zero": with match points primary, 2 rounds and 6 boards
that is 4 / 6, which rounds to 0 and leaves the division undefined. The
engine uses 1 (`max(..., 1)` in `Team`); the reference does the same. Only
events with more boards than twice the rounds reach it. 16.6-style
competition rules could set "a different value", which the text allows.

**Q2 - "in the last round of a tournament" (16.2.5) in part-way
standings.** After round 5 of 9, a requested bye in round 5 is taken as
category 16.2.5 (evaluated as a draw for the opponents), because it is the
last round counted. That is reading 11's choice for 16.4.2 applied to 16.2.5
as well; the alternative reads "the last round of a tournament" as round 9,
under which the round-5 bye is not yet in any category. Final standings are
the same either way.

**Q3 - a team match won by forfeit in Article 12.** Article 12 gives a
pairing-allocated bye "the game points ... assigned to a standard win" on
every board. A whole match won by forfeit, with no boards recorded, is
given the same (a win on every board); a full-point bye, half-point bye or
zero-point bye gives no board points. The text names only the
pairing-allocated bye; `Team.from_trf/2` never produces a forfeited match
(forfeits in a TRF are per board), so this matters only for events built
directly.

**Q4 - 6.3's outcomes are win, draw or loss.** "Whatever the outcome of the
missing games" is enumerated over the three standard results. An unplayed
game cannot end in a double forfeit or 0-0 in the future the rule imagines;
with those allowed, a candidate's worst case would be unchanged and a
rival's best case too, so the answer is the same - noted only because the
enumeration is where it was decided.

## What is compared

For every event, every value of every code below, per participant, and the
final ranks under four or five tie-break lists (score first; ties left
after the list share a rank).

| events | codes | lists |
|---|---|---|
| Swiss, `Ainalrami.Generator` | PTS WIN WON BPG BWG PS (C1, C2) REP STD TPN, BH and FB (C1, C2, M1, M2), AOB (and /F), SB (C1, C2), KS (L1, L-1, L2, L-2), ARO (C1, C2, M1, M2), TPR PTP APRO APPO RTNG (and /R), and `/U1400` versions when a player is unrated | `BH/C1 BH SB DE`, `DE BH/C1 SB`, `DE/P WIN STD`, one random list with DE or DE/P |
| round robins | the same without the Buchholz family (Article 8), plus the `/U1400` codes | `DE SB KS`, `DE/P SB WIN`, `SB DE KS/L1`, one random |
| team events, board-level TRF | MPTS GPTS MPVGP, BH FB AOB SB PS KS WIN WON STD on MP and GP with cuts, limits and /F, EMMSB EMGSB EGMSB EGGSB (and /C1), REP TPN SSSC (and /F) | five of: `MPTS GPTS EDE BH:MP EMGSB`, `MPTS EDEBT`, `MPTS GPTS EDEBB`, `MPTS EDET`, `GPTS EDEB`, `MPTS BC TBR BBE`, `MPTS TBR`, `MPTS BBE BC`, `MPTS DE:GP SSSC`, `MPTS EDE/P TPN`, `EDE MPVGP`, `PTS DE SB:MP/C1 EDEBT` |
| team events, match by match | as above | as above |

The events, by `rem(seed, 10)`:

- **0-4, Swiss:** 4-24 players, 2-9 rounds, with the generator's checklist
  options drawn per event: forfeits (5-12%), requested byes (up to 25%),
  full-, half- and zero-point byes, forfeit wins, double forfeits, odd
  over-the-board results (½-0, 0-0), results from the FIDE table or
  uniform, and ratings stepped, in equal blocks (ties in the rating
  tie-breaks), random, or partly unrated (0). One event in four is rescored
  3/1/0, one in four gives the pairing-allocated bye a draw's value (its
  outcome becomes a draw, and it stops being a "win" for 7.1). One in three
  is compared again on the standings after an earlier round, where 8.3's
  final round is not yet played and 16.4.2 counts the rounds played.
- **5-6, round robins:** 3-12 players, single or double, odd fields with a
  free round, 4% forfeits and 3% double forfeits, and in three events of
  ten a withdrawal whose remaining games are forfeited; one in five cut off
  part-way.
- **7, board-level team events:** the generator of
  `tools/team_tiebreak_compare.exs` (4 boards, reserves who move the boards
  below up, individual forfeits, a pairing-allocated bye in an odd field,
  greedy pairing with rematches only when forced), read through
  `Team.from_trf/2`; primary score GP in a third of them.
- **8-9, team events built match by match:** 3-10 teams, 2-7 rounds, 2-6
  boards, 2/1/0 or 3/1/0 match points, MP or GP primary; teams absent on a
  half- or zero-point bye, pairing-allocated and full-point byes, whole
  matches forfeited or double-forfeited, and in a third of the events
  rematches on purpose.

## Hand-built events

Each of these asserts the value the text gives, in both implementations,
and that they agree on every other code:

| test | the point |
|---|---|
| STD with a double forfeit and a ½-0 | reading 8: 0.5 to each for 0-0, a full point for ½ against 0 |
| a player with a half-point bye (dummy 2.0), a forfeit loss (dummy 2.5, contribution 0) and a win over the lowest scorer | finding B: SB/C1 cuts the least significant value 0.5, not the VUR chosen by dummy score (2.5, not 2.0); BH/C1 cuts the lowest VUR contribution 2.0, not the least value |
| the same event, `FB` listed first | finding A: SB and BH do not change; ranks under `FB SB` agree |
| three players tied, two of them meeting twice | finding C / 6.1.2: encounter points 1.5, 1 (the average of two wins), 0.5 - summed, the second would be first |
| a 5-player round robin, all draws | reading 10: the maximum is 4, not 5, so 2.0 is on the line; KS/L1 and KS/L-1 |
| a round robin with a forfeit | reading 9: not a game won for WON; a win for WIN; unplayed for REP; a game for SB (15.2) |
| a pairing-allocated bye to a player on 4/4, and a trailing zero-point bye | 16.4.2 caps the dummy at 2.0; 16.3.2 counts the trailing bye as a draw for the opponents |
| the same after round 2 of 4 | reading 11 (cap 1.0, not 2.0) and 8.3 (FB is BH before the final round) |
| a zero-point bye followed by a forfeit loss, and one followed by a forfeit win | 16.2.5 against 16.2.3: a forfeit win is not a VUR |
| two teams level on MP and GP that never met | finding D and reading T4: EDEBT, EDEBB and BC rank the lower Board Count first, over the whole tournament |
| two teams level after a 2-2 match | 13.3.2: EDET and EDEB separate them by the boards, plain EDE does not |
| the first five match-by-match team events with both a rematch and a forfeited match | 6.1.2 and Article 16 in team events |

## Results

| run | seeds | events | values | disagreements |
|---|---|---|---|---|
| default (`mix test`) | 1..300 | 300 | ~165,000 | 0 |
| scale | 1..5000 | 5,000 | 2,754,192 | 0 |
| scale | 100001..110000 | 10,000 | 5,516,127 | 0 |

"Values" counts every per-participant value and every per-participant final
rank. No engine bug was found, and no reference bug survived to the scale
runs: the first run of the reference agreed with the engine everywhere,
which is why the sensitivity check below matters.

## Sensitivity

To show the comparison is not vacuous, five deliberate mutations were made
one at a time in a copy of the reference (not committed) and run on seeds
1..1000; each was caught. (Mutations 1-3 were run on the final generators;
4 and 5 before the pairing-allocated-bye scoring variant was added, which
does not change seeds 2 and 6.)

| mutation | disagreements | first seeds caught |
|---|---|---|
| 1. 16.5 ignored - cuts always remove the least significant value | 596 | seed 1 (BH/C1, BH/C2, BH/M1, FB/C1) |
| 2. a requested bye in the last round taken as 16.2.3, not 16.2.5 | 342 | seed 1 (BH, FB and their cuts) |
| 3. 6.1.2 ignored - repeated meetings summed, not averaged | 5 | seeds 122 (Swiss, `DE/P`), 228 (team, `DE:GP`), 573, 847 (team, EDE), 851 |
| 4. one band of the expected-score table moved by a point (329 -> 330) | 115 | seed 2 (PTP, APPO), seed 6 (round robin, PTP/U1400) |
| 5. STD against a draw's value (TieBreakServer's reading) | 495 | seed 2 (STD, and the ranks under `DE/P WIN STD`) |

Mutation 3 is the hardest to see: only events where a pair met more than
once, with DE deciding a group, can show it, and a double round robin
cannot (every pair met twice, so summing scales every total alike). Seeds
122 and 228 are in the default run.

## Limits

Not covered by the reference:

- `Team.from_trf/2`'s reading of board-level TRFs (teams, boards, reserves);
  the reference starts from the team data the engine is given.
- Team events with pairings fixed in advance, and the rating tie-breaks for
  teams.
- `?` results with a declared `X` value, and TRF26 `299` values that make a
  forfeit win or a bye worth something other than a win or a draw.
- `cap_rounds: :announced` (16.6's alternative for 16.4.2, used by
  OpenPairings' old standings), and `rank/3`'s `score:` override.
- `working/2` (the per-round parts shown to arbiters) - only the values it
  adds up to.
- The code parser's refusals, and Article 8's refusal of Buchholz in round
  robins (the reference is never given one).

## Running it

    mix test test/ainalrami/tiebreak_reference_test.exs          # default, 300 events
    TIEBREAK_REF_SEEDS="1..5000" mix test test/ainalrami/tiebreak_reference_test.exs --only tiebreak_reference_scale

The scale mode prints `TBREF seeds=N events=N values=N disagreements=N`; a
failure lists the first twenty differences, each starting with its seed.
