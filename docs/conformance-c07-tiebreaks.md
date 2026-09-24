# C.07 tie-breaks: reading notes and design

Written before the code, the way `conformance-c0406-teams.md` was: the
reading is checked against the regulation (`c07-regulation-text.md`), not
against an implementation. Article numbers below are C.07's, effective
1 March 2026.

## Why this lives in Ainalrami

FIDE's checklist for tournament programs (VCL4THP v13) asks for a free
checker that reports, from a TRF26 file, both the pairings that break the
rules and **the standings positions that do not follow the tie-breaks**
(Q21), and a generator whose tournaments are ranked by the tie-break list
they carry (Q31). Ainalrami's `-c` and `-g` are that checker and generator,
so the tie-breaks have to be here. OpenPairings then calls this code for its
standings instead of keeping its own, so the code FIDE checks is the code
arbiters run.

This is a fresh implementation from the text. OpenPairings' existing
tie-breaks (`PairingsEngine.Standings`) are a second, independent
implementation of the thirteen codes they cover; before OpenPairings
switches over, the two must agree on every test and on a generated corpus.
FIDE's own TieBreakServer (Otto Milvang, MIT, © FIDE) is the third opinion,
used for validation only - never called by the app.

## Scope

- **Individual tie-breaks (Articles 6-10):** DE, WIN, WON, BPG, BWG, PS, REP,
  STD, TPN, BH, AOB, FB, SB, KS, ARO, TPR, PTP, APRO, APPO, RTNG, and PTS
  (the score itself, as the first element of a TRF26 `212` list).
- **Modifiers (Article 14):** Cut-1, Cut-2, Median-1, Median-2, the Koya
  limit; plus the switches the checklist and TRF26 spell as modifiers: `R`
  (reverse order, 7.8 and 10.6), `P` (DE including forfeits, 6.1.1), `F`
  (AOB over Fore Buchholz, 8.2).
- **Unplayed rounds (Articles 15-16).**
- **Team tie-breaks (Articles 11-13):** MP/GP scores, MPvGP, ESB (EMMSB,
  EMGSB, EGMSB, EGGSB), EDE and its knockout follow-ups, BC, TBR, BBE,
  SSSC. Second phase, after the individual set.
- **Out of scope:** play-offs (Article 3) and drawing of lots (4.2) are
  decisions made outside the program. Ties left after the list is
  exhausted are reported as ties.

## Code syntax

`NAME[:MP|:GP][/modifier...]`, the form FIDE's checklist uses (`BH/C1`,
`ARO/M2`, `KS/L-1`, `RTNG/R`, `DE/P`, `AOB/F`) and TieBreakServer reads.

| Modifier | Meaning | Article |
|---|---|---|
| `C1`, `C2` | cut the one / two least significant values | 14.1, 14.2 |
| `M1`, `M2` | cut one / two least and most significant values | 14.3, 14.4 |
| `L1`, `L2`, `L-1`, `L-2` | Koya limit moved by +½, +1, -½, -1 point | 14.5 |
| `R` | reverse order (TPN, RTNG) | 7.8, 10.6 |
| `P` | DE counts forfeits as games | 6.1.1 |
| `F` | AOB over the opponents' Fore Buchholz | 8.2 |
| `U<rating>` | rating used for unrated players in Article 10 tie-breaks | 10 |

**Reading 1 - the Koya limit.** The checklist (Q104) spells "limit 50% + ½"
as `KS/L1` and "+1" as `KS/L2`, so `Ln` moves the limit by n half-points.
TieBreakServer reads a bare `L50` as a percentage and needs a sign
(`L+1`) for a point offset. We follow the checklist's spelling and
translate when calling TieBreakServer. `L+1` and `L-1` are accepted on
input as the same thing.

**Reading 2 - the TRF26 `202` validator.** Ainalrami's `Trf.validate!/1`
accepted only `[A-Z][A-Z0-9]*`, so every modified code (`BH/C1`) was
refused - a file listing FIDE's most common tie-break could not be written
or checked. It now accepts the syntax above.

## The data model

`Ainalrami.Tiebreaks` works on a plain event, not on TRF text, so
OpenPairings can hand it its own data directly; `from_trf/2` builds one
from `Trf.parse/1`.

Per participant: id, TPN, rating (nil when unrated), and per round one of:

| kind | meaning | Article 16.2 category |
|---|---|---|
| `:played` | a game over the board, rated or not (TRF `1 = 0 W D L`, and `?`) | - |
| `:forfeit_win` | forfeit won against a scheduled opponent | 16.2.2 |
| `:forfeit_loss` | forfeit lost (both sides of a double forfeit) | 16.2.4 |
| `:pab` | pairing-allocated bye | 16.2.1 |
| `:full_bye` | full-point bye | 16.2.1 |
| `:half_bye` | half-point bye (requested) | 16.2.3 / 16.2.5 |
| `:zero_bye` | zero-point bye, also every round after a withdrawal and before a late entry | 16.2.3 / 16.2.5 |

plus the points the round was worth under the event's scoring. The outcome
of an unplayed round - win, draw or loss - is "the result corresponding to
the awarded number of points" (16.3.1, 16.4): points equal to a win are a
win, equal to a draw a draw, anything else a loss.

**Reading 3 - games under one move.** TRF `W`/`D`/`L` are games that
started but are not rated. They were played over the board, so they count
for WON, BWG, BPG, AOB and the Article 10 averages. TieBreakServer
(`trf2json.py`) reads them the same way.

**Reading 4 - rounds a participant was not in the event.** 16.1.1 makes
every round after a withdrawal a zero-point bye. A late entrant's rounds
before arrival are treated the same way: the participant was not available
to play, which is what a voluntary unplayed round is (16.1.2).

## Type B (Article 7)

- **WIN (7.1):** rounds with at least a win's points, played or not. Under
  15.2 (predetermined pairings) forfeit losses stay unplayed and forfeit
  wins count.
- **WON (7.2):** games won over the board.
- **BPG / BWG (7.3, 7.4):** games played / won over the board with black.

**Reading 9 - "over the board" wins over 15.2.** 15.2 treats a round robin's
forfeits as regular games except forfeit losses in Type B tie-breaks; read
alone, that would make a forfeit win a game won for WON and BWG. But 7.2-7.4
each define themselves as games "over the board", and the specific wording
wins: a forfeit win is not a game won over the board in any event. (First
written the other way; TieBreakServer counts only games played, and on a
second reading the text agrees with it.)
- **PS (7.5):** sum of the running score after each round. Cut-1 removes the
  score after round 1 (14.1.2 c); Cut-n removes the first n.
- **REP (7.6):** rounds minus half-point byes, zero-point byes and forfeit
  losses.
- **STD (7.7):** 1 per round scoring more than the scheduled opponent (or,
  unpaired, more than a draw), ½ per round scoring the same (or exactly a
  draw). A forfeit win against a scheduled opponent is a round scoring more.
- **TPN (7.8):** ascending; `R` descending.
- **RTNG (10.6):** descending; `R` ascending.

**Reading 8 - STD compares with the opponent, as written.** "The number of
rounds in which a participant scores more points than their scheduled
opponent ... plus half the number of rounds in which the participant scores
the same number of points as their scheduled opponent." So a double
forfeit, or a 0-0 where both lose, is half a point to each; ½-0 is a full
point to the player with ½. **TieBreakServer differs**: it compares every
round with a draw's value (`compute_std`, commented "std from 2026 rules"),
which gives 0, 0 and ½ in those three cases. Found on a real file
(`S_FIDE_469284`, Clubkampioenschap B-reeks: players 6 and 8 have a double
forfeit in round 9). We follow the text; this is a reading difference to
report to TEC (VCL4THP Q38-Q39), and the comparison tool counts it
separately rather than as an error.

## Buchholz family (Articles 8, 16)

**Adjusted score (16.3)**, used when a participant appears as somebody's
opponent: their score, except that requested byes followed only by
voluntary unplayed rounds, or in the last round (16.2.5), count as draws.
Forfeit losses count as awarded even at the end (16.2.4 is not in 16.3.2).

**Own unplayed rounds (16.4):** each is a game against a dummy whose score
is the participant's own score, capped at the scheduled opponent's adjusted
score for forfeits (16.4.1) and at a draw's points times the number of
rounds for everything else (16.4.2).

**Reading 11 - "the number of rounds in the tournament" in 16.4.2**, for
standings part-way through an event: the rounds the standings are for. The
cap is meant as the score of a player who drew every game; after round 5
of 9 that is five draws, and nine would make the cap meaningless until the
end. The two readings agree on final standings. TieBreakServer reads it
this way (its cap uses the rounds it is asked to count); OpenPairings' own
standings read it as the announced rounds, found by the comparison gate
before OpenPairings switched to this code. 16.6 lets a competition's rules
choose, so `Event.new/3` takes `cap_rounds: :announced` for that.

**Reading 5 - "the participant's own score" in 16.4** is their actual final
score, the same number the standings show. (The adjusted score of 16.3 is
defined "for the sole purpose of calculating the tie-break of their
opponents", which the participant's own tie-break is not.)

- **BH (8.1):** sum of opponents' adjusted scores and dummy scores.
- **FB (8.3):** BH after replacing every result of the final round's paired
  games with a draw, for everyone - scores and adjusted scores are
  recomputed from that assumption. **"The final round" is the event's last
  round**, not the last one played so far: standings after round 1 of 9
  have no final round to draw yet, so FB is plain BH there. The event
  carries its announced round count for this (`total_rounds`); nothing else
  reads it. First written the other way, and caught by the comparison with
  TieBreakServer on two files saved after round 1 - TieBreakServer's
  `isfore` needs the participant's last pairing to be in the event's final
  round.
- **AOB (8.2):** average of the Buchholz (or, with `F`, Fore Buchholz) of
  the opponents played over the board; no dummies, since a dummy has no
  Buchholz.
- **SB (9.1):** sum over rounds of the opponent's (or dummy's) score times
  the points scored against them. A draw scores a draw's points, so under
  1/½/0 the familiar "½ × opponent".
- **Cuts (14, 16.5):** the least significant value of BH is the lowest
  contribution. 16.5 adds: when the participant has voluntary unplayed
  rounds, cut the lowest contribution coming from one of them instead, as
  long as it is not lower than the least significant value. For SB, the
  least significant value is the contribution of the opponent with the
  lowest score (the lowest contribution among several such, 14.1.2 d), and
  16.5.2 cuts the higher of that and the lowest VUR contribution. Each
  further cut (C2, M2) reapplies the rule to what is left. Medians cut the
  least first, then the most (14.3).
- **Round robins (15.2):** a round without an opponent - the free round of
  an odd field - is not an element of the sum at all, so Cut-1 removes the
  weakest real game, not the free round. There is no dummy outside Article
  16.
- **Round robins:** Article 8 says Buchholz-type tie-breaks must not be
  used in round robins. `from_trf/2` and `compute/3` refuse them for a
  predetermined event (the VCL's Q105 counts allowing them as a failure).

## Koya (9.2)

Points scored against opponents who finished with at least 50% of the
maximum possible score; `Ln` moves the threshold by n half-points (14.5) -
half a point each, as 14.5 says, whatever the scoring system.

**Reading 10 - the maximum possible score, and which rounds count.** The
maximum is a win's points for every round a participant could have been
scheduled against somebody. In an odd round robin the free round cannot
score, so 13 players over 13 rounds have a maximum of 12 and the 50% line
is 6, not 6.5; in a Swiss event every round can score (a pairing-allocated
bye does). Points count in every round with a scheduled opponent, forfeits
included: a forfeit win against a qualifying player is points "achieved
against" them. First written with 13 x 1 and games only, and caught on a
13-player club round robin (`S_FIDE_469281`) by TieBreakServer, whose
`compute_koya` does both.

## Direct encounter (Article 6)

Applied inside a tied group during ranking, not as a per-participant
number. Separate standings from the games among the tied participants,
forfeits excluded unless `P` (6.1.1), repeated pairings averaged (6.1.2).
If every pair has met, those standings rank the group, and 6.2 reapplies
to each subset still tied. In Swiss events (6.3), when not every pair has
met, a participant who stays alone at the top whatever the missing games'
results is ranked first, then the same for the next place; whoever is left
is ranked by Article 6 again.

**Reading 6 - "whatever the outcome of the missing games".** A candidate is
alone at the top for every outcome exactly when their worst case (losing
all of their own missing games) is strictly above every rival's best case
(that rival winning all of theirs, the one against the candidate
included). A rival's best case depends only on that rival's own games, so
checking each rival separately covers every combination of outcomes. A win
here is worth a win's points in the separate standings.

## Ratings (Article 10)

Over games played over the board against rated opponents. When unrated
participants are present the tie-breaks are dropped, unless the event
supplies a rating for them (`U<rating>`) - the "detailed rules" Article 10
allows.

- **ARO (10.1):** average opponent rating, rounded half up. Cuts remove the
  lowest (and for medians the highest) ratings.
- **TPR (10.2):** ARO + dp(p), p the score over those games as a percentage
  rounded half up, dp from the FIDE Rating Regulations' table (the same
  table as B.01 1.4.9).
- **PTP (10.3):** the lowest whole rating whose expected score against those
  opponents, with the full rating scale (no 400 cut), is at least the score
  in those games; 800 below the lowest opponent for a zero score.
- **APRO / APPO (10.4, 10.5):** average of the opponents' TPR / PTP, over
  opponents played over the board, rounded half up.

**Reading 7 - "tournament score" in 10.3** is the score in the games the
performance is over (games played over the board against rated opponents).
Using the full tournament score would make a player's PTP rise with a
forfeit win they did not play for. TieBreakServer reads it the same way.

## Output and ranking

`rank/2` orders the participants by the list, ties sharing a rank once the
list is exhausted, and returns every value it computed, so the checker can
report which positions disagree with a file's own ranks and why.

## Validation

1. Unit tests per tie-break, including the worked examples in C.07 where it
   gives them.
2. Agreement with OpenPairings' implementation on the thirteen shared codes.
3. Agreement with TieBreakServer on every code both implement, on real
   tournament files and on generated tournaments, both directions:
   Ainalrami's generator checked by TieBreakServer, and TieBreakServer's
   generator checked by Ainalrami.

## Teams (Articles 11-13)

`Ainalrami.Tiebreaks.Team`. A team event is two views of the same matches:
one scored in match points, one in game points. Each is an ordinary
`Ainalrami.Tiebreaks.Event` - teams as participants, a round's points the
match points (or game points) the team took from it - so every individual
tie-break applies to teams with `:MP` or `:GP` (`BH:MP`, `SB:GP`), and
Article 16 does too: C.07 applies it to "Individual or Team Swiss
tournaments", with "points" meaning match points and game points.

**Reading T1 - a round's outcome is the match's.** A drawn match with
2-2 is a draw in both views; an unplayed round's outcome is the one its
awarded match points correspond to. In the game-point view a win's points
are a win on every board, a draw's are half of that - "points awarded for a
draw" in 16.4.2, for game points, is a drawn match's game points.

**Reading T2 - the reference score.** A code without `:MP`/`:GP` uses the
primary score (Article 13, "the primary score being the default").

- **MPTS, GPTS (11.1), MPvGP (13.1):** the match points, the game points,
  and the secondary score.
- **ESB (13.2):** `EMMSB`, `EMGSB`, `EGMSB`, `EGGSB` - the opponent's final
  total in the first score times the points scored against them in the
  second. Unplayed rounds per Article 16 in both scores. Cut-1 (14.1, team
  paragraph) removes the contribution of the opponent lowest in the FIRST
  score, the lowest such contribution among several, with 16.5's VUR rule.
  `ESB:MG` and friends are read as `EMGSB` (TieBreakServer's spelling).
- **EDE (13.3):** Article 6 on the primary score; when that breaks no tie,
  on the secondary; restarting from the primary for every new subset.

**Reading T3 - the EDE variants.** The PDF text of 13.3.2 lost its layout:
four names and four right-hand sides landed on the wrong lines. The mapping
used, which TieBreakServer's `compute_ext_direct_encounter` also implies
(it computes Board Count for EDEBT and EDEBB only): **EDEBT** = EDE, then
BC, then TBR; **EDEBB** = EDE, then BC, then BBE; **EDET** = EDE, then TBR;
**EDEB** = EDE, then BBE. The knockout tie-breaks apply only when exactly
two teams are still tied in both scores.

**Reading T4 - Article 12 after EDE counts the whole tournament.** Article
12 is written for knockouts, where the two tied teams have just played each
other. Inside EDEBT, EDEBB, EDET and EDEB it is applied as written: BC
counts "all games played by the team in the tournament", and TBR and BBE
count every match, so two tied teams that never met are still separated.
TieBreakServer counts only the games between the two teams, and leaves
teams that never met tied (its handling of the BC step also has a defect:
finding D in `finding-tiebreakserver-2026-09.md`).

- **BC (12.1):** board number times game points on that board, over every
  match, lower better; a pairing-allocated bye scores a win on every board,
  individual forfeits count as games (Article 12). Only when all the tied
  teams have the same game points - otherwise it leaves the group alone.
- **TBR (12.2):** game points on board 1; for teams still level, board 2,
  and so on.
- **BBE (12.3):** game points on all boards but the bottom; for teams still
  level, all but the bottom two, and so on.
- **SSSC (13.4):** the secondary score plus the Buchholz of the primary
  score (Fore Buchholz with `/F`) divided by the highest primary score
  achievable in the event over the highest secondary score achievable in
  one match, rounded towards zero.
