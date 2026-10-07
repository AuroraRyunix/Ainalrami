# bbpPairings 6.0.0 hands out a second pairing-allocated bye because a bit field is too narrow

**Status:** root cause located and the fix verified on five positions, 2026-10-07.
**Verdict:** (a), a bbpPairings bug. Not the harness, not Ainalrami.
**Case:** `/root/w-indiv25/dumps/00193/seed2120538796-r6-p8.trf` (job log `jobs/00193.log`), round 6 of 9, 8 players, one of them pre-recorded `Z` for the round, so 7 are paired.

```
Ainalrami:    {4,2} {6,3} {7,5} {8, PAB}
bbpPairings:  {4,2} {5, PAB} {6,3} {8,7}
```

All numbers are pairing numbers (the rank column), not the `P<n>` names. The names are shuffled against the ranks in this file, which is a fine way to lose twenty minutes.

## What is true about the position

| Rank | Pts | PAB eligible [C2] | Absolute colour pref | Played |
|---|---|---|---|---|
| 4 | 4.0 | yes | no | 7 8 - 1 5 |
| 7 | 3.5 | yes | no (strong W) | 4 2 1 6 3 |
| 3 | 3.0 | yes | **B** | - 5 8 - 7 |
| 8 | 2.5 | yes | no | - 4 3 2 - |
| 2 | 2.0 | **no (U in R3)** | **B** | 6 7 U 8 1 |
| 6 | 1.5 | yes | no (strong B) | 2 1 - 7 - |
| 5 | 1.0 | **no (U in R4)** | **B** | 1 3 - U 4 |

(Rank 1 carries the round-6 `Z` and is not paired.)

Hand analysis, checked against the engines rather than trusted:

- 2 can only meet 4 (it has played 6, 7, 8, 1, and 3 and 5 are absolute-B like it). 3 can then only meet 6 (it has played 5, 8, 7, and 4 is taken). That fixes {4,2} and {6,3}.
- Of 5, 7, 8 one gets the bye and two are paired. 5 is barred by [C2] (it holds `0000 - U` in round 4). That leaves 7 (3.5) or 8 (2.5). The lower score takes the bye: **8**. This is Ainalrami's answer.
- The brief's note that 6 is the lowest eligible scorer but cannot take the bye is right (3 and 2 would then both need 4), and so is its conclusion. One correction: the "P5 / P1" labels in the brief are names; the player with the round-4 `U` is rank 5, name `P1`.
- bbpPairings itself knows rank 5 is ineligible: its own checklist (`-l`) prints `C2 = N` for rank 5 and then prints `(bye)` in the same row.

## It is not the harness

Checked seriously, since it was a fair suspicion.

- The file is well formed and both programs read it. bbpPairings parses `U` as a pairing-allocated bye (`src/fileformats/trf.cpp:261` scores it as a win, `:283` marks it as not played, `:305` marks it as participating in pairing), counts it as 1.0 against the 001 total, and its eligibility test (`src/swisssystems/common.h:104-120`) correctly returns "not eligible" for a player holding one. The 001 totals, the `Z` for round 6, `142`, `152 W` and `XXR` are all consistent. Removing `152` or `XXR` changes nothing in bbp's answer.
- bbpPairings is told the truth and answers wrongly anyway. A first matching computed by the same program, before the per-bracket machinery starts, is correct: `4-2, 7-5, 3-6`, rank 8 unmatched (debug trace below).
- Ainalrami's own `-c` accepts the file's five history rounds, and `-p` returns the pairing above, which is legal and optimal.
- One cosmetic wart on our side, not related: with a pre-recorded `Z` in the round being paired, the CLI logs "pairing round 7" because `report_roster` takes the longest history including the `Z` (`lib/ainalrami/cli.ex:910`, `:306`). The pairing is unaffected. I did not check whether anything else reads that count.

## Root cause

`src/swisssystems/dutch.cpp:714-716`:

```cpp
const unsigned int scoreGroupSizeBits =
  utility::typesizes::bitsToRepresent<unsigned int>(maxScoreGroupSize);
```

(`maxScoreGroupSize` is set at `:707`.) `scoreGroupSizeBits` is the width of every "how many" field in the packed edge weight built by `computeEdgeWeight` (`:234-`): "completion requirement and bye eligibility" at `:275-281`, then "maximize the number of pairs in the current pairing bracket" at `:283-286`, whose value is `lowerPlayerInCurrentBracket`, summed over the pairs of a matching.

The field is sized for the largest score group. A pairing bracket is the score group plus every player floated down into it, and it can be larger than any score group. Here all 7 paired players have different scores, so `maxScoreGroupSize = 1` and the field is 1 bit wide. By the fourth bracket (rank 8) the bracket holds {4, 7, 3, 8}, and a matching can contain two pairs inside it. The count 2 does not fit in 1 bit and carries into the field above, which is the completion/eligibility one. That carry is worth exactly one eligibility unit, which is what separates the legal matching from an illegal one.

Instrumented run (my own build with debug prints in `dutch.cpp` only, in `/root/w-bbp-case/src2/`; nothing under the validation workers touched):

```
first matching (whole field)      4>2 7>5 3>6 8>8 2>4 6>3 5>7     rank 8 unmatched    correct
bracket {4,7,3 | 8} (+ rank 2)    4>3 7>8 3>4 8>7 2>2 6>5 5>6     rank 2 unmatched    wrong
later, after backtracking         ...                             rank 5 unmatched    ineligible
```

In the second line the program prefers {4,3} {7,8} {6,5} and leaves rank 2 out. By completion that matching scores 7 against the correct one's 8, and the carry closes that gap, after which a lower-priority field decides. The program then repairs the rest of the round around that and ends with rank 5 on the bye.

Caveat, stated plainly: I inferred the carry from the evidence rather than dumping the multi-word weights. The evidence is the trace above plus both fixes below: widening the field makes the program right in every case I have, and nothing else I changed does.

The check that should have stopped this, `matchingIsComplete` (`:75-96`), only runs on the first matching, which is the correct one. Later brackets never re-check bye eligibility.

## Fix, verified

Both change line 716 only.

| Change | This case | The four earlier C2 positions |
|---|---|---|
| `bitsToRepresent(maxScoreGroupSize) + 3` | matches Ainalrami | not run |
| `bitsToRepresent(std::max<player_index>(maxScoreGroupSize, sortedPlayers.size()))` | matches Ainalrami: `{4,2} {7,5} {6,3} {8,PAB}` | all four now give the bye to a rank whose checklist shows `C2 = Y` (was `N` in all four) |

The second form is the principled one: a bracket never holds more than all the players. I did not run bbpPairings' own test suite against it.

**This is almost certainly the same bug as `docs/bbppairings-c2-bug-report.md`.** The four fixtures there (`test/fixtures/c2_seed8112174-r9-p18.trf`, `fe1_disputes/seed8848759-r9-p10.trf`, `seed7073463-r8-p9.trf`, `seed735265-r7-p10.trf`) all change output under the fix, and in all four the bye goes from a `C2 = N` player to a `C2 = Y` one. The earlier report describes the symptom and argues the rule; this finding is the mechanism. The report should get a paragraph pointing here, and the draft below can replace or supplement it.

## Reproducer

The 8-player file as dumped is the smallest I have. I tried dropping each of the five history rounds, and removing the absent player with each of its games turned into a `Z`, `H` or `U` instead (3^5 combinations); none keeps the disagreement. A random search over 5-7 players with 3-5 rounds found nothing in several thousand tries, which fits the cause: it needs every score group tiny, plenty of floaters, and a bye that matters, all at once. That is also why it showed up in the fuzzer and not in anything a human would pair.

Round 6 of 9. Check with `bbpPairings.exe --dutch case.trf -p out.txt`.

```
012 Fuzz
062 8
082 0
092 Individual: Swiss System
142 9
001    1      P6                                1151                             2.0    1     5 w 1     6 b 1     7 w 0     4 b 0     2 b 0  0000 - Z
001    2      P3                                1449                             2.0    2     6 b 0     7 b 0  0000 - U     8 w 0     1 w 1
001    3      P8                                2295                             3.0    3  0000 - Z     5 b 1     8 w =  0000 - H     7 w 1
001    4      P2                                1565                             4.0    4     7 w =     8 b 1  0000 - H     1 w 1     5 b 1
001    5      P1                                2042                             1.0    5     1 b 0     3 w 0  0000 - Z  0000 - U     4 w 0
001    6      P5                                2163                             1.5    6     2 w 1     1 w 0  0000 - Z     7 b 0  0000 - H
001    7      P4                                2713                             3.5    7     4 b =     2 w 1     1 b 1     6 w 1     3 b 0
001    8      P7                                1805                             2.5    8  0000 - H     4 w 0     3 b =     2 b 1  0000 - H
152 W
XXR 9
```

Expected (what Ainalrami and the fixed build return):

```
4
4 2
7 5
6 3
8 0
```

bbpPairings 6.0.0 returns `4 / 4 2 / 8 7 / 6 3 / 5 0`.

## Draft report for the bbpPairings author

> **Title:** Dutch: second pairing-allocated bye given when every score group is small (scoreGroupSizeBits too narrow)
>
> **Version:** BBP Pairings 6.0.0, `--dutch`, FIDE C.04.3 as of 1 February 2026.
>
> **Symptom.** For the attached TRF (8 players, round 6 of 9, one player already recorded as `0000 - Z` for round 6) the program gives the pairing-allocated bye to player 5, who already received one in round 4 (`0000 - U`). C.04.3 2.1.2 [C2] forbids this absolutely. The checklist from `-l` itself shows `C2 = N` for player 5 in the row that also says `(bye)`. A legal pairing exists and is the only one that fits the remaining criteria: 4-2, 7-5, 6-3, bye to 8.
>
> **Why it happens.** In `dutch.cpp`, `scoreGroupSizeBits` (line 714) is `bitsToRepresent(maxScoreGroupSize)`. Every score in this file is different, so the value is 1. That is the width used for the counting fields of the edge weight in `computeEdgeWeight`, among them "maximize the number of pairs in the current pairing bracket" (line 283), which is summed over the pairs of a matching. A pairing bracket contains the moved-down players as well as the score group, so by the fourth bracket it holds four players and a matching can contain two pairs in it. That sum does not fit in one bit and carries into the field above it (completion and bye eligibility), so a matching with an ineligible bye ties with, and is then preferred over, the correct one. The initial `matchingIsComplete` check sees only the first, correct, matching.
>
> **Fix that works here.** Size the field by the number of players instead:
> `bitsToRepresent(std::max<tournament::player_index>(maxScoreGroupSize, sortedPlayers.size()))`. With that change the attached file gives `4 2 / 7 5 / 6 3 / 8 0`, and four other position files that previously gave a second bye now give the bye to a player with `C2 = Y`. I have not run your test suite against it.
>
> **Reproduce.** `bbpPairings.exe --dutch case.trf -p out.txt`. The file is attached. The mechanism above is inferred from the behaviour (a debug trace shows the first matching correct and a later bracket choosing a different bye) and from the fix, not from a dump of the weights.

## Method

On the VM, all in `/root/w-bbp-case/`: the dump copied to `c.trf`; `bbpPairings.exe` from `/root/bbpsrc` run with `-p`, `-c` and `-l`; Ainalrami's CLI run from a private copy of the engine with `+S 2:2`; a private copy of the bbpPairings source (commit 8f9e3c5) built with debug prints and then with each fix. The validation workers in `w-indiv25` were not touched.
