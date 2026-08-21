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
| **Ainalrami** | the TPN, exactly as the file gives it |
| **bbpPairings 6.0.0** | a numbering that skips players who have never participated |
| **Gacrux** | the same |

The two references agree with each other. That was not obvious — Gacrux's
condition is written `rfp or rip` (ready for pairing now, **or** paired at
some point before) while bbpPairings has no such clause in sight — so it
was measured both ways round with `tools/rip_probe.exs`:

- when the absent player **has already played**, all three engines agree,
  and nobody renumbers;
- when the absent player has **never played**, both references renumber
  and this engine does not.

The three therefore agree whenever the field is complete, because the two
numberings coincide, and diverge only once somebody has been registered
without ever being paired.

### The rule CHANGED, and no reference followed it (2026-08-21)

This is the heart of the dispute, and it was missed until someone asked
the obvious question: did the rules change?

They did, on 1 February 2026.

**Before** — C.04.3 Article E.5, effective till 31 January 2026:

> If the higher ranked player has an odd **pairing number**, give him the
> initial-colour; otherwise give him the opposite colour.

and A.2 defined that number as assigned by the initial ranking list **"and
subsequent modifications depending on possible late entries or rating
adjustments"**, with a note directing the reader to C.04.2.B/C "for the
proper management of the pairing numbers".

**After** — C.04.3 Article 5.2.5, effective 1 February 2026:

> If the higher ranked player has an odd **TPN** (see Article 1.1), give
> them the initial-colour; otherwise, give them the opposite colour.

Article 1.1 defines nothing; it delegates wholly to C.04.2 Article 2,
which allows a TPN to move for exactly two reasons — a correction to the
ranking data, barred after the fourth round, and the closing of the
participant list — and draws no distinction whatever between a registered
player who has played and one who has not.

So a loosely-worded "pairing number" carrying "subsequent modifications"
in its own definition was replaced by a tightly pinned TPN. Under the OLD
wording, renumbering is defensible. Under the new one it has no basis.

**And JaVaFo does it too.** Run on the same file as the table below, the
pre-2026 reference returns byte-identical output to bbpPairings:

```
4
2 7      <- White = TPN 2, which is EVEN, with initial-colour White
8 4
5 9
10 6
```

That reframes the whole dispute. It is not "two independent
implementations of the 2026 rules both misread 5.2.5", which was always
the weakest part of this document's case — three implementations agreeing
is evidence, and it was evidence against us. It is:

> The 2026 rewrite narrowed the definition, and no reference
> implementation changed with it. bbpPairings 6.0.0 and Gacrux carry
> pre-2026 behaviour forward into engines that claim the 2026 rules.

Their agreement is shared lineage rather than independent derivation, so
it no longer counts against the reading here. What it does show is that
the change was easy to miss — which is a reason to have it confirmed in
writing rather than to assume either answer.

### The references' reading is not unreasonable

Worth saying plainly, because it changes what this dispute is. Skipping a
player who has never participated is a defensible reading of C.04.2 2.5:

> Due to late entries, the TPNs given at the start of the tournament are
> provisional. The definitive TPNs are given only when the List of
> Participants is closed…

A player who never turned up is arguably not on that list, so arguably
holds no definitive TPN. That is a real argument and this document does
not dismiss it.

What decides it the other way is 2.4, which says a late entry is *"given
an appropriate TPN and paired only when they actually arrive."* The TPN
exists before the arrival; it is the pairing that waits. A registered
player who has not yet played therefore holds a TPN, and 5.2.5 asks for
the parity of a TPN.

That is why this is filed as a rules-interpretation dispute rather than as
a defect report against two engines.

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
for TPN 2 (position 1) and agree for 4, 5 and 6 (positions 2, 3, 4).

All three engines on that field, with Gacrux run rather than read:

```
 board  | top TPN | parity | ours  | bbp   | gacrux | who follows 5.2.5?
 2v7    |       2 |  even  |     7 |     2 |      2 | ours
 4v8    |       4 |  even  |     8 |     8 |      8 | ours bbp gacrux
 5v9    |       5 |  odd   |     5 |     5 |      5 | ours bbp gacrux
 6v10   |       6 |  even  |    10 |    10 |     10 | ours bbp gacrux
```

**Exactly one board differs, and it is exactly the board whose TPN parity
and position parity disagree.** That is not a coincidence compatible with
several explanations; it is the signature of this one.

It also settles the Gacrux question empirically. Gacrux is normally the
tiebreaker in this project — it is the third implementation of the same
2026 rules, and it is what backs this engine against bbpPairings in
[`dispute-seed735265.md`](dispute-seed735265.md). Here it does not: it
answers 2, with bbpPairings. Both references renumber; only the engine
following the handbook's own definition of a TPN answers 7.

`tools/rip_probe.exs` isolates the same split in round TWO, where it is
sharper still, because there the two candidate rules can be told apart:

```
absent player has already played   ->  ours 7, bbp 7, gacrux 7   (agree)
absent player has never played     ->  ours 3, bbp 2, gacrux 2   (differ)
```

Both references draw the line in the same place, and it is the line
between "has participated" and "has not", not between "is playing this
round" and "is not".

Reproduce:

```bash
mix run tools/round_one_colours.exs 10 1,3
```

(with `GACRUX_DIR` set, and under `MIX_ENV=test` so the reference adapters
are compiled — without it the Gacrux column is simply blank.)

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
