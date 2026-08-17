# Dispute: which number Article 5.2.5's parity is taken on

**Status:** open. This engine follows the regulation as written; both
reference implementations do something the regulation does not describe.
FE1 category 3 (rules interpretation), like
[`dispute-seed735265.md`](dispute-seed735265.md) — but unlike that one,
this is not a rare position. It decides colours on **every board that
reaches 5.2.5 in a tournament where anyone has sat a round out.**

Found 2026-08-17, when the comparison harness was taught to check colours
at all.

## The rule

C.04.3 (2026), Article 5.2, allocates colours in five steps. The first
four grant a preference; the fifth is the last resort, reached only when
neither player holds one:

> **5.2.5** If the higher ranked player has an odd TPN, give them the
> initial-colour; otherwise, give them the opposite colour.

"TPN" is not defined in C.04.3. It is delegated:

> For the definition and management of TPNs, see Article 2 of the General
> Handling Rules for Swiss Tournaments (Initial Order and Late Entries).

And C.04.2 Article 2 defines it as a tournament-level number:

> **2.3** This ranking is used to determine the participant's Tournament
> Pairing Number ("TPN"); the highest ranked participant gets #1 etc. If,
> for any reason, the data used to determine the rankings were not
> correct, they can be adjusted at any time. The TPNs may be reassigned
> accordingly to the corrections. **No modification of a TPN for this
> reason is allowed after the fourth round has been paired.**

> **2.5** Due to late entries, the TPNs given at the start of the
> tournament are provisional. The definitive TPNs are given only when the
> List of Participants is closed, and corrections made accordingly in the
> results charts.

Exactly two things move a TPN: a correction to the ranking data, and the
closing of the participant list after late entries. Both are one-off
administrative events, and one of them is barred outright after round
four. **Nothing in either article renumbers TPNs around players who are
not being paired in a particular round.**

## What the engines do

| | number whose parity decides |
|---|---|
| **Ainalrami** | the TPN, per C.04.2 Art. 2 |
| **bbpPairings 6.0.0** | the player's position among those being paired this round |
| **Gacrux** | the player's position among those paired now or previously (`rfp or rip`) |

Gacrux's variant is the narrower of the two: it renumbers only around
players who have never participated at all, which is at least reaching for
the late-entry case of 2.5. bbpPairings renumbers around anyone not valid
for the current round, which no reading of Article 2 supports.

The three agree whenever the field is complete, because position and TPN
are then the same number. They diverge the moment anyone sits out.

## The evidence

`tools/round_one_colours.exs` puts a clean field and a field with byes
through both engines. Round one is the sharpest possible probe: nobody has
a colour preference yet, so **every** board falls through 5.2.1–5.2.4 to
5.2.5 alone.

Ten players, `152 W`, no byes — the engines agree on every board, and both
produce the alternation down the ranking that Article 5 describes:

```
 board |    ours     |  bbpPairings   | top TPN | parity | agree?
     1 | 1 W, 6 B    | 1 W, 6 B       |       1 |  odd   | yes
     2 | 7 W, 2 B    | 7 W, 2 B       |       2 |  even  | yes
     3 | 3 W, 8 B    | 3 W, 8 B       |       3 |  odd   | yes
     4 | 9 W, 4 B    | 9 W, 4 B       |       4 |  even  | yes
     5 | 5 W, 10 B   | 5 W, 10 B      |       5 |  odd   | yes
```

Now let TPNs 1 and 3 take a bye. The players being paired are
2, 4, 5, 6, 7, 8, 9, 10 — positions 1..8. Position and TPN now disagree
for TPN 2 (position 1) and agree for 4, 5 and 6 (positions 2, 3, 4):

```
 board |    ours     |  bbpPairings   | top TPN | parity | agree?
     1 | 7 W, 2 B    | 2 W, 7 B       |       2 |  even  | NO
     2 | 8 W, 4 B    | 8 W, 4 B       |       4 |  even  | yes
     3 | 5 W, 9 B    | 5 W, 9 B       |       5 |  odd   | yes
     4 | 10 W, 6 B   | 10 W, 6 B      |       6 |  even  | yes
```

**Exactly one board differs, and it is exactly the board whose TPN parity
and position parity disagree.** That is not a coincidence compatible with
several explanations; it is the signature of this one.

Reproduce:

```bash
mix run tools/round_one_colours.exs 10 1,3
```

## Scale

Measured over 200 seven-round tournaments at a 15% bye rate:

| axis | boards differing | unexplained |
|---|---|---|
| plain (no byes) | **0** | 0 |
| 10% forfeits | **0** | 0 |
| 20% forbidden pairs | **0** | 0 |
| Baku acceleration | **0** | 0 |
| 15% arbiter byes, `152 W` | 670 | 0 |
| 15% arbiter byes, `152 B` | 1175 | 0 |

The axes without byes show *zero* colour differences, which is the control
that makes the rest meaningful: this is not a general disagreement about
Article 5, it is precisely and only the renumbering.

## What this does not affect

**Who plays whom.** Colour allocation runs after the pairing is decided,
so a divergence here cannot move a player to a different board. Every axis
above reports 100.00% agreement on pairings and zero illegal rounds
throughout. The engine's headline result is untouched by this dispute.

## Why it is not being "fixed"

Matching the references would take one line. It is not being done, for the
same reason recorded throughout this project: the target is the
regulation, not agreement.

Two further reasons, specific to this case:

- **The renumbering is unstable in a way TPNs are not.** Under it, a
  player's colour parity changes from round to round according to who
  happens to be absent — so the same two players, meeting in the same
  situation, get different colours depending on whether an unrelated third
  player took a bye. Article 2's whole design is that a TPN is fixed after
  the list closes.
- **The two references do not agree with each other either.** bbpPairings
  renumbers around anyone not paired this round; Gacrux only around players
  who have never played. A change made to match one would still not match
  the other, so "agreeing with the references" is not even a well-defined
  target here.

## How the harness handles it

`bbppairings_comparison_test.exs` splits colour differences into two
counts. A board is filed under this dispute when 5.2.5 is what decides it
— neither player holding any colour preference — *and this engine's answer
is the one the article gives*. Everything else is reported as
**unexplained**, loudly, with `COLOUR_DEBUG=1` printing both players' full
histories.

The classification deliberately tests our own conformance rather than
matching a model of bbpPairings' internals. An earlier version did the
latter and mis-filed a genuine case (`seed 2, round 2`, two players who
had each taken a zero-point bye in round one) as unexplained, because
predicting the references' numbering means implementing a rule this
project does not believe in — twice, and in a test.

## Status

Not yet filed. It needs the same treatment as `seed735265`: a written
position and a decision about whether to raise it with the SPPC. This one
has the stronger case of the two, since it rests on a definition quoted
verbatim from the handbook rather than on an argument about a single
position.
