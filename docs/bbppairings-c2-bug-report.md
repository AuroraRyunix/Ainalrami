# bbpPairings 6.0.0 allocates a second pairing-allocated bye, violating C.04.3 [C2]

*Three independent positions. In two of them the round has only one legal
pairing at all.*

**Reporter:** OpenPairings / Ainalrami project
**Program:** BBP Pairings v6.0.0 (Built Feb 1 2026 17:39:15) —
<https://github.com/BieremaBoyzProgramming/bbpPairings>
**Rules:** FIDE Handbook C.04.3, FIDE (Dutch) System, effective 1 February
2026 — <https://handbook.fide.com/chapter/C0403202602>
**Severity:** produces a pairing that violates an absolute criterion, where
a legal pairing exists.

---

## Summary

For the attached tournament files, bbpPairings allocates the
pairing-allocated bye to a player who has already received one. C.04.3 art.
2.1.2 [C2] forbids this absolutely, and a legal alternative exists — two
other implementations produce it.

Three independent positions are attached, found across three different
generator axes and two separate seed ranges. In the second and third the
legal pairing is not merely better, it is FORCED: a player who already
holds a bye has a single remaining opponent, so there is exactly one legal
shape for the round, and bbpPairings does not return it. The third reaches
that shape through a chain of four such players and needs no scoring
argument whatsoever.

## The rule

> **2.1     Absolute Criteria**
> No pairing shall violate the following absolute criteria:
> …
> **2.1.2 [C2]** See the Basic Rules for Swiss, Article 4 (A participant who
> has already received a pairing-allocated bye, or has already scored in one
> single round, without playing, as many points as rewarded for a win, shall
> not receive the pairing-allocated bye).

FIDE TEC's worked companion (*Mastering the Dutch*, version 2026) states the
consequence: "A candidate that is not legal can only be immediately
discarded", and calls this exact situation illegal twice while working its
fifth round.

## Input file

TRF16. Lines are CRLF-terminated. 10 players, 6 rounds played, pairing round
7 of 9.

```
012 Fuzz
062 10
082 0
092 Individual: Swiss System
001    1      P1                                1387                             2.5    1     6 w 0    10 b =  0000 - U  0000 - H     7 w 0  0000 - H
001    2      P10                               2384                             2.0    2     7 b =     5 w 0    10 w 0  0000 - Z     3 b =  0000 - U
001    3      P4                                2542                             1.5    3     8 w 0  0000 - U     5 b 0  0000 - Z     2 w =     6 b 0
001    4      P8                                2376                             3.5    4     9 b 1  0000 - Z     7 w 1  0000 - H     5 b =     8 w 0  0000 - H
001    5      P6                                1060                             4.5    5    10 w =     2 b 1     3 w 1     8 b 1     4 w =     9 b =
001    6      P2                                2277                             3.5    6     1 b 1     8 w 0  0000 - Z    10 b 1  0000 - Z     3 w 1  0000 - H
001    7      P7                                1512                             3.0    7     2 w =  0000 - H     4 b 0     9 w 0     1 b 1    10 b 1
001    8      P5                                1146                             4.0    8     3 b 1     6 b 1  0000 - H     5 w 0  0000 - H     4 b 1
001    9      P3                                2558                             3.5    9     4 w 0  0000 - H  0000 - H     7 b 1    10 w 1     5 w =
001   10      P9                                2271                             2.5   10     5 b =     1 w =     2 b 1     6 w 0     9 b 0     7 w 0  0000 - H
152 W
XXR 9
```

## Position

Players 4, 6 and 10 hold arbiter-assigned half-point byes for round 7
(their histories carry a seventh entry), so seven players are active and one
must take the PAB.

| TPN | pts | prior PAB / unplayed win? | eligible for PAB under [C2] |
|---|---|---|---|
| 1 | 2.5 | `U` in round 3 | **no** |
| 2 | 2.0 | `U` in round 6 | **no** |
| 3 | 1.5 | `U` in round 2 | **no** |
| 5 | 4.5 | — | yes |
| 7 | 3.0 | — | yes |
| 8 | 4.0 | — | yes |
| 9 | 3.5 | — | yes |

Players 1, 2 and 3 each already received a pairing-allocated bye. Under
[C2] the PAB must go to one of 5, 7, 8 or 9.

## Observed behaviour

```
$ bbpPairings.exe --dutch seed735265-r7-p10.trf -p out.txt
$ echo $?
0
$ cat out.txt
4
7 5
8 1
2 9
3 0
```

`3 0` allocates the pairing-allocated bye to TPN 3 — who received one in
round 2. Exit code 0; no diagnostic.

## Expected behaviour

A pairing that allocates the PAB to an eligible player. One exists, and two
independent implementations produce the same one:

**Gacrux** (Otto Milvang's `pairingchecker.py`, from the FIDE Tie-Break
Server; `pairingdutch.py` hardcodes `DUTCH_RULES[1] = "2026-02-01"`):

```
$ python3 pairingchecker.py -p -m dutch -i seed735265-r7-p10.trf -f TRF -n 7
  "pairs": [[5,1],[8,2],[3,9],[7,0]]
```

**Ainalrami** (github.com/AuroraRyunix/ainalrami): `{5,1} {8,2} {3,9}`, bye to
7 — identical, board for board.

That pairing seats all seven active players, contains no rematch, and gives
the PAB to TPN 7, who has not had one.

## Note on the mechanism

bbpPairings enforces this rule correctly in general. A minimal case — three
players, TPN 1 already holding a `U`, TPNs 2 and 3 both eligible — produces
the bye for TPN 3, avoiding the second bye, exactly as expected. Its
`eligibleForBye` (`swisssystems/common.h:104-118`) tests
`!match.gameWasPlayed && (getPoints(...) >= pointsForWin || ...)`, which a
pairing-allocated bye satisfies at default point values, and
`swisssystems/dutch.cpp:88` rejects a matching whose unmatched player fails
that test.

Nothing in the attached file alters the point system: its only settings line
is `152 W`, which sets the initial colour (`fileformats/trf.cpp:1179-1198`).

So the rule is implemented and is not being reached on this path.

**What the three cases together suggest.** `eligibleForBye` is applied to
the player who ends up unmatched, but it does not appear to constrain the
*choice of matching* that decides who that is. In the first case the
engine picks an illegal assignee where a legal one is merely worse on a
lower-ranked criterion. In the second and third it picks a pairing that
consumes the last available opponent of a player who already holds a bye,
and only then discovers that player has nowhere to go — by which point
the bye is forced on someone the rule forbids.

The distinguishing feature of all three is that the ineligible player is
*short of opponents*: a nearly-exhausted pairing graph late in a small
event, which is where a bye is most likely to be needed twice and least
likely to have an alternative. That would also explain why the defect is
rare enough to survive a large corpus — it needs both an already-byed
player and that player to be down to their last legal opponent.

## A second, independent case

Found on 2026-08-20, 11.6 million rounds into a fresh run on a different
seed range, and it needs no argument about scoring at all: **the position
has exactly one legal shape and bbpPairings does not return it.**

`test/fixtures/fe1_disputes/seed8848759-r9-p10.trf`, round 9 of 9, 10
players. TPNs 6, 8 and 9 carry arbiter byes for the round, so seven players
are active and one pairing-allocated bye is to be given. Four of the seven
already hold one, and TPN 4 has met every active player but TPN 1:

| TPN | pts | already holds a PAB | unplayed, among active |
|---|---|---|---|
| 1 | 5.5 | no | 2, 4 |
| 2 | 3.5 | **yes** (R6) | 1, 3, 5, 10 |
| 3 | 4.0 | no | 2, 5, 7 |
| 4 | 2.5 | **yes** (R4) | **1** |
| 5 | 2.0 | **yes** (R5) | 2, 3, 7, 10 |
| 7 | 5.0 | no | 3, 5, 10 |
| 10 | 3.0 | **yes** (R1) | 2, 5, 7 |

TPN 4 cannot take the bye — [C2] — and has one available opponent. So
**1–4 is forced**, and every candidate without it strands TPN 4 into a
second bye. The bye then falls to one of the three eligible players, and
[C5] puts it on the lowest-scoring of them, TPN 3 on 4.0.

```
Ainalrami:    1-4, 5-2, 7-10, bye 3
Gacrux:       1-4, 5-2, 7-10, bye 3
bbpPairings:  1-2, 3-5, 7-10, bye 4      <- second bye for TPN 4
```

bbpPairings pairs 1–2, which removes TPN 4's only opponent, and then has
nowhere to put TPN 4 except the bye. This is the same defect as the case
above seen from a different angle: there, the illegal assignee was chosen
where a legal one scored worse; here, it is chosen because an earlier
choice in the same matching left no alternative. Both are cases of the
eligibility test not constraining the matching that produces the leftover.

## A third case, forced by elimination

Found on 2026-08-20 on a different axis again (random acceleration), and
it is the cleanest of the three: the round has exactly **one** legal shape,
it falls out by pure elimination, and no scoring criterion is ever
consulted.

`test/fixtures/fe1_disputes/seed7073463-r8-p9.trf`, round 8 of 9, 9
players. TPNs 3 and 5 carry arbiter byes for the round, leaving seven
active. Four of those seven already hold a pairing-allocated bye, so [C2]
requires every one of them to be paired:

| TPN | pts | already holds a PAB | unplayed, among active |
|---|---|---|---|
| 1 | 3.5 | **yes** | 2, 6, 9 |
| 2 | 4.0 | **yes** | 1, 4 |
| 4 | 3.5 | no | 2, 8 |
| 6 | 5.0 | no | 1, 7 |
| 7 | 4.5 | no | 6, 9 |
| 8 | 2.5 | **yes** | **4** |
| 9 | 2.5 | **yes** | 1, 7 |

The chain is deterministic:

1. TPN 8 holds a bye and has a single opponent left → **4–8**
2. TPN 2 holds a bye and now has a single one left → **2–1**
3. TPN 9 holds a bye and now has a single one left → **9–7**
4. TPN 6 is all that remains, and is the one still eligible → **bye**

```
Ainalrami:    2-1, 4-8, 9-7, bye 6
Gacrux:       2-1, 4-8, 9-7, bye 6
bbpPairings:  4-2, 6-1, 9-7, bye 8      <- second bye for TPN 8
```

bbpPairings pairs 4–2, which consumes TPN 8's only remaining opponent and
leaves it nowhere to go but a second pairing-allocated bye.

Note also what the correct answer does NOT optimise: TPN 6 on 5.0 is the
highest-scoring active player, and [C5] asks for the assignee's score to be
minimised. It goes to TPN 6 regardless, because [C2] is absolute and has
eliminated every other candidate — the criteria are lexicographic, and an
absolute one is not tradeable against a lower-ranked preference.

## Reproduction

Save the file above with CRLF line endings and run the command in "Observed
behaviour". The engine that found it is at
<https://github.com/AuroraRyunix/ainalrami>; this position is
`test/fixtures/fe1_disputes/seed735265-r7-p10.trf` there, with
`tools/dispute_dump.exs` printing the decoded position and eligibility, and
`tools/bye_probe.exs` building the minimal control case.

All three were found by differential testing: several million synthetic
tournaments and hundreds of millions of individual pairings compared
board-for-board against bbpPairings across field sizes 4–500, round counts
6–13, arbiter byes, forfeits, `XXP` exclusions and `XXA` acceleration.
These three positions are the only ones in that corpus where the engines
disagree, and Gacrux -- a third, independent implementation of the same
2026 rules -- returns Ainalrami's answer board-for-board on all three.

The other two are
`test/fixtures/fe1_disputes/seed8848759-r9-p10.trf` and
`test/fixtures/fe1_disputes/seed7073463-r8-p9.trf`; all three are pinned by
`test/ainalrami/c2_second_bye_test.exs`, and
`test/fixtures/fe1_disputes/README.md` decodes each position in full.

That every disagreement in a corpus this size is the SAME rule, in the
same direction, is itself part of the report: this is one defect with a
narrow trigger, not a scattering of edge cases.
