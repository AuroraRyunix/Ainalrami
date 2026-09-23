# Findings in FIDE's TieBreakServer (September 2026)

Two places where TieBreakServer (Otto Milvang, MIT, © FIDE; checked at
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

## A reading difference, not a defect

C.07 7.7 scores STD against the scheduled opponent; TieBreakServer against
a draw's value. That is a choice of reading, recorded as reading 8 in
`conformance-c07-tiebreaks.md`, not listed here.
