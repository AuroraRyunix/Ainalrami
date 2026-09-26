# Findings in FIDE's TieBreakServer (September 2026)

Places where TieBreakServer (Otto Milvang, MIT, © FIDE; checked at
commit `14a34a2`, "Add EDExx Tiebreaks, bug fixes") gives a different value
from C.07 (effective 1 March 2026), found while validating
`Ainalrami.Tiebreaks` against it (`tools/tiebreak_compare.exs`). Written up
to be reported to TEC / the author: VCL4THP v13 Q36-Q37 ask that
discrepancies attributed to the other engine be reported.

Both reproduce from files Ainalrami generates deterministically:

    mix run tools/tiebreak_corpus.exs DIR 60        # writes DIR/g1.trf .. g60.trf

and are run below with Python 3.13 from the TieBreakServer directory.

## A. A value depends on which other tie-breaks are in the list

Computing Fore Buchholz changes per-participant state that later
tie-breaks in the same run read. In `compute_buchholz_sonneborn_berger_ver`:

    if isfb and tbscore[vprefix + "lmp"] == self.rounds:
        tbscore[vprefix + "lna"] = tbscore[vprefix + "lmp"]

`lna` ("last round not absent") is set for the Fore computation and never
restored, so a Sonneborn-Berger or Buchholz computed after an `FB` in the
same list sees the Fore version of it.

**Reproduction** - `g45.trf`, players 10, 11 and 13:

    python tiebreakchecker.py -i g45.trf -o - -s -d T -t SB/V2026
        10  17.75    11  16.50    13  12.25
    python tiebreakchecker.py -i g45.trf -o - -s -d T -t FB/V2026 SB/V2026
        10  17.25    11  16.00    13  12.00

The first set is right (and is what `Ainalrami.Tiebreaks` gives in either
order). A tie-break's value cannot depend on the tie-breaks listed before
it; with `FB` early in a list, the standings of a Swiss event can change.

## B. SB/C1 with voluntary unplayed rounds cuts the wrong element

C.07 16.5.2: "For Sonneborn-Berger, after determining: a. the lowest
contribution coming from a VUR; b. the least significant value (see
14.1.1.d and 14.1.2); cut the higher of these two values."

TieBreakServer picks the VUR by the dummy's **score**, not by the
**contribution** (`sortexp` sorts on `(-vur, score, tbvalue)`), which is
Buchholz's notion reused for Sonneborn-Berger. When a participant has two
VURs whose scores and contributions are in different orders - a half-point
bye (contribution = dummy × ½) and a forfeit loss (contribution 0) - it cuts
the wrong one.

**Reproduction** - `g30.trf`, player 6 (score 6.5, nine rounds):

| round | kind | dummy / opponent score | points | contribution | VUR |
|---|---|---|---|---|---|
| 1 | half-point bye | 4.5 | ½ | 2.25 | yes |
| 5 | forfeit loss | 5.0 | 0 | 0.00 | yes |
| 8 | draw | 3.0 | ½ | 1.50 | - (least significant value) |

SB = 25.75. The lowest VUR contribution is 0.00 (round 5); the least
significant value is 1.50 (round 8, lowest opponent score); the higher is
1.50, so **SB/C1 = 24.25**. TieBreakServer takes round 1 (lowest dummy
score among the VURs, 4.5), compares 2.25 with 1.50, and cuts 2.25:
**23.5**.

    python tiebreakchecker.py -i g30.trf -o - -s -d T -t SB/C1/V2026      # 6 -> 23.5

The same pattern accounts for every SB/C1 difference in the first 60
generated files (g30, g32, g33, g35, g43).

## C. Direct encounter loses count when two participants met more than once

`compute_basic_direct_encounter` (tiebreak.py) implements 6.1.2 - "if two
participants have met more than once, the addend ... is the average score of
these games" - with a running average. The branch for a repeated opponent
ends with

    de["denum"] = 1
    ...
    de["delist"][opponent]["cnt"] = 1

where `denum` counts the DISTINCT tied opponents met and should be left
alone, and `cnt` should become `num`, the games played against this
opponent so far. Two consequences:

1. **A group of three or more stops resolving.** After a rematch `denum` is
   1, below `len(subro) - 1`, so the group is taken as "not all met" and the
   6.3 maximum-possible rule decides instead of 6.2. It usually decides
   nothing, and every team in the group shares one rank.
2. **A third meeting is weighted wrongly.** With `cnt` stuck at 1, each new
   game is averaged with the running value, halving the weight of every game
   before it.

Found on board-level team events (`tools/team_tiebreak_compare.exs`, where
a greedy pairing sometimes rematches), where EDE runs through this code.
The individual DE shares the code path, so a double round robin or any Swiss
rematch is affected too.

**Reproduction** - seeds of `tools/team_tiebreak_compare.exs`, written to a
file with `--keep DIR --first SEED --count 1 --rank "MPTS EDE"`:

- **1073:** teams 3, 8 and 7 are tied on 7 MP. 3 drew with 7 and beat 8,
  and 8 beat 7 twice. The encounter points (6.1.2) are 3, 2 and 1, so the
  ranks are 7, 8 and 9. TieBreakServer ranks all three 7 (consequence 1).
- **1004:** teams 10, 17 and 14 are tied on 6 MP. 10 and 14 met twice (a
  loss and a draw for 10, average ½). The points are 2½, 2 and 1½.
  TieBreakServer ranks all three 17.
- **1066:** teams 20 and 19 are tied on 3 MP and met three times (1-1, 2-0,
  0-2 in MP; averages 1 and 1). Game points decide: 20 averages 2.5 and 19
  1.5, so 20 comes first. TieBreakServer's running values are 0.75 for 20
  and 1.25 for 19, so it puts 19 first (consequence 2).

## D. EDEBT/EDEBB's Board Count step ranks the higher sum first

13.3.2 follows EDE with the knockout tie-breaks of Article 12 when exactly
two teams are still tied. `compute_singlerun_ext_direct_encounter` does
this by weighting each board, `weights = 1..teamsize` for Board Count, and
passing the weighted points (`tpoints`) to `compute_basic_direct_encounter`.
That routine sorts the higher value first (`-deval`). 12.1 says "the lower
the sum of these products, the higher the ranking of the team", and
TieBreakServer's own stand-alone `BC` is marked `"rev": False` and ranks
the lower sum first, as it should. Only the BC step inside EDEBT and
EDEBB is reversed.

**Reproduction** - `tools/team_tiebreak_compare.exs` seed **1006**, `--rank
"MPTS GPTS EDEBT"`: teams 16 and 14 are level on MP and GP and drew their
round-5 match 2-2. Team 16 scored 1, ½, 0, ½ on boards 1-4 and team 14
scored 0, ½, 1, ½. Board Count over the tournament (12.1) is 24 for 16 and
27 for 14. Over the match alone it is 4 for 16 and 6 for 14. Either way 16
ranks first. TieBreakServer ranks 14 first.

It is a separate matter that TieBreakServer counts only the games the two
teams played against each other, where 12.1 counts "all games played by the
team in the tournament". That is recorded as reading T4 in
`conformance-c07-tiebreaks.md`: with the match-only reading, two tied teams
that never met are not separated at all (seed **1002**, teams 3 and 5).

## E. Board Count ranks teams whose game points differ

12.1 ends: "It can only be used when all tied teams have (scored) the same
number of game points." TieBreakServer's `compute_boardcount` gives every
team its sum and the ranking sorts on it (`BC`, `"rev": False`), whatever
the game points of the teams it is sorting. In a list where BC follows the
match points - `MPTS BC ...`, the natural place for it in a match-point
event - teams level on match points but not on game points are ranked by
Board Count, where 12.1 does not allow it to be used at all. Ainalrami
leaves such a group to the next tie-break.

Found by the random-list run of 2026-09-25
(`tools/team_tiebreak_compare.exs --random-lists`), where it accounts for
most rank differences in the team events with BC in the list.

**Reproduction** - `tools/team_tiebreak_compare.exs` seed **20229**,
written with `--keep DIR --first 20229 --count 1 --rank "MPTS BC"`:

    python tiebreakchecker.py -i team20229.trf -o - -s -n 7 -d T -t MPTS/V2026 BC/V2026 GPTS/V2026

- Teams 5 and 7 are level on 9 MP with 16 and 15½ GP. Their Board Counts
  are 37½ and 35. TieBreakServer ranks 7 third and 5 fourth; under 12.1
  BC cannot be applied and the two stay level after `MPTS BC`.
- Teams 2, 3 and 10 are level on 8 MP with 18, 15½ and 14 GP; Board
  Counts 47, 37 and 36. TieBreakServer ranks them 10, 3, 2 - the team
  with the most game points last, because more game points on the same
  boards is a higher sum.

The same rule inside EDEBT and EDEB is not affected in the same way: there
TieBreakServer reaches Board Count only for two teams still tied after EDE
(but see reading T7 in `conformance-c07-tiebreaks.md`).

## F. SSSC stops with a division by zero when the normalising factor rounds to zero

13.4.2 b divides the Buchholz by "the highest achievable primary score in
the tournament divided by the highest secondary score achievable in a
single match, rounded to the nearest integer towards zero". With match
points primary that is zero whenever a team can take more game points in
one match than match points in the whole event - at 2/1/0, more boards
than twice the rounds. `compute_score_strength_combination` divides by it
anyway, and the program ends with `Error 510 Program error`
(`decimal.DivisionByZero`) for every code in the request, not only SSSC.
Ainalrami uses 1 (question Q1 in `docs/tiebreak-reference.md`).

Found by the team comparison of 2026-09-26, where the new generator's
short team round robins with many boards reach it; the tool leaves SSSC out
of such an event's lists and counts it.

**Reproduction** - `tools/team_tiebreak_compare.exs --first 66 --count 1
--keep DIR` (a team round robin of three teams, three rounds, seven boards):

    python tiebreakchecker.py -i team66.trf -o - -p -n 3 -d T -t SSSC/V2026

prints `### Error 510`. The highest primary score is 3 x 2 = 6 MP, the
highest secondary in one match 7 GP; 6 / 7 rounds to 0.

## G. Koya takes a free round in every Scheveningen and Schiller event

9.2's threshold is half the maximum possible score. For round robins,
`compute_koya` removes one game per cycle when `rounds % competitors == 0`
- the test for an odd round robin, where each player sits out once per
cycle (5 players, 5 rounds). But a Scheveningen or Schiller event, where
every pair of teams meets several times, can have a round count that is a
multiple of the field with nobody sitting out: four teams meeting each
other four times play 12 rounds, and 12 % 4 == 0, so TieBreakServer's
maximum is 9 matches, not 12, and its 50% line 13.5 MP (at 3/1/0), not 18.
Teams that did not reach half the maximum are counted as if they had. A
two-team Scheveningen of an even number of rounds is hit the same way.
Ainalrami's maximum counts the rounds a team could have been paired
(reading 10).

**Reproduction** - `tools/team_tiebreak_compare.exs --first 109 --count 1
--random-lists 2026 --keep DIR` (a Schiller-type event, four teams of four
boards, 12 rounds, 3/1/0):

    python tiebreakchecker.py -i team109.trf -o - -p -n 12 -d T -t MPTS/V2026 KS:MP/V2026

Match points 19, 16, 13 and 18. The maximum is 12 x 3 = 36, half of it 18,
so only teams 1 and 4 qualify: KS:MP 7, 7, 10, 4. TieBreakServer's line is
13.5, so team 2 (16) qualifies too: 12, 7, 13, 12. The tool reproduces
TieBreakServer's rule and classifies a value it explains exactly as this
finding.

## H. A board is dropped when every team-round had an individual forfeit

`post_parse_line` sets the team size, for a file with `013` records, from
the games PLAYED over the board (`game["played"]`): the most any team had in
one round. A forfeited game is not played, so when every team had at least
one individual forfeit in every round the count is one short, and
`games2matches.merge_tmatches` then keeps only that many games per team and
match (`[:teamsize]`) - each match loses a board, and with it game points,
possibly the match result and everything computed from them. The TRF
itself says how many boards there were: the forfeits are listed against
their opponents like any game.

Only small events are exposed (every team-round must contain a forfeit).
The tool sets such an event aside as a whole, counted, since the dropped
board changes every value.

**Reproduction** - `tools/team_tiebreak_compare.exs --first 41227 --count 1
--random-lists 2026 --keep DIR` (a team round robin of three teams, three
rounds, seven boards, 3/1/0):

    python tiebreakchecker.py -i team41227.trf -o - -p -n 3 -d T -t GPTS/V2026 MPTS/V2026

Every match has a `+`/`-` game, so TieBreakServer counts six boards. Its
game points are 7.5, 6.5 and 4.0 and its match points 3, 4 and 1; from all
seven boards of each match they are 9, 7.5 and 4.5, and 4, 4 and 0 (team 1
drew 3½-3½ with team 2 and beat team 3 5½-1½).

## A reading difference, not a defect

C.07 7.7 scores STD against the scheduled opponent; TieBreakServer against
a draw's value. That is a choice of reading, recorded as reading 8 in
`conformance-c07-tiebreaks.md`, not listed here.
