# Resolved: which number Article 5.2.5's parity is taken on

**Status: CLOSED, 2026-08-27, decided against this engine.** The FIDE
Systems of Pairings and Programs Commission answered the question raised in
[`spp-question-initial-colour.md`](spp-question-initial-colour.md), and the
answer is (b): the parity is taken on a numbering that skips players who
have never been paired. bbpPairings and Gacrux were right. Ainalrami was
wrong, and had been wrong since colours were implemented.

The SPP's reasoning, quoted:

> Because of C.04.2:2.4 which states "A Late Entry is a participant who is
> only taken into account for the pairing of rounds after the first. If
> admitted to the tournament, LATE ENTRIES receive no points for unplayed
> rounds … and ARE GIVEN AN APPROPRIATE TPN AND PAIRED ONLY WHEN THEY
> ACTUALLY ARRIVE." … players who have yet to arrive don't have a TPN.

This document is kept as the record of an argument that lost. The argument
is not deleted — it explains why the engine behaved this way for months,
and why the question was worth asking — but every conclusion in it is
marked wrong where it is wrong.

## The crux: both sides argued from the same sentence

This is the single most useful thing to take from the episode, and it is
not "we didn't read the handbook". We did. We quoted C.04.2:2.4 as the
clause that decided the question, and so did the SPP.

|  | reading of C.04.2:2.4 |
|---|---|
| **Ainalrami** | "given an appropriate TPN **and** paired only when they actually arrive" — the TPN exists before the arrival; it is the PAIRING that waits. A registered player who has not yet played holds a TPN. |
| **SPP** | "are given an appropriate TPN and paired only when they actually arrive" — both halves wait. **No TPN until arrival.** |

Same sentence, opposite conclusions, and ours was the wrong one. The
grammar carries both readings; the SPP is the body that says which one the
regulation means, and it has said.

The practical consequence: a player who is registered but has never been
paired holds no TPN yet, so they are not merely skipped in the numbering —
they are not in it at all. Everyone below them moves up one, and the parity
5.2.5 asks for moves with them.

## The second retraction, which is the worse one

The ruling overturned this document's conclusion. That is ordinary: a
question was asked, and it was answered the other way.

What is not ordinary is that **one of the arguments propping up the
decision not to fix was already false when it was written, and it was
refuted by evidence in this same file.**

The old "Why it is not being 'fixed'" section carried this bullet:

> **The two references do not agree with each other either.** bbpPairings
> renumbers around anyone not paired this round; Gacrux only around players
> who have never played. A change made to match one would still not match
> the other, so "agreeing with the references" is not even a well-defined
> target here.

That is the **pre-probe hypothesis**, written up as a finding. It is what
`tools/rip_probe.exs` was built to test, and the probe refuted it: when the
absent player has already played, ours, bbpPairings and Gacrux all answer
7, and nobody renumbers. Both references draw the line in exactly the same
place — between "has participated" and "has not" — which is stated
correctly in this document's own evidence section, forty lines above the
bullet claiming the opposite, and stated correctly again in note 5 of
[`conformance-c0403-2026.md`](conformance-c0403-2026.md). Only this file
carried the refuted version, and it carried it as one of the two named
reasons for not complying.

Re-confirmed 2026-08-27 against the local Windows bbpPairings binary:
`rip_probe.exs` answers 7 on board `[2, 7]` — the unrenumbered answer —
on a position where the absent player had played in round one. bbpPairings
does not renumber around a player who has participated. The claim was
false on the day it was written and is false now.

The process failure is worth naming, because it is repeatable: a hypothesis
and the measurement that killed it were written into the same file, at
different times, and never reconciled. Nothing flagged it. The bullet
survived because nobody re-read the top of the document while editing the
bottom of it, and it went on to serve as an argument against making a
change that turned out to be required.

It repeated the next day, in this same file, and the repeat is recorded in
[the third instrument failure](#the-third-instrument-failure-found-2026-08-28)
below: a table of counts written up as measured fact with no committed
script that could produce it. The shape is identical — a claim and its
evidence separated, and nothing in the tree noticing.

## The rule

C.04.3 (2026), Article 5.2, allocates colours in five steps. The first four
grant a preference; the fifth is the last resort, reached only when neither
player holds one:

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

> **2.4** A Late Entry is a participant who is only taken into account for
> the pairing of rounds after the first. If admitted to the tournament,
> Late Entries receive no points for unplayed rounds … and are given an
> appropriate TPN and paired only when they actually arrive.

> **2.5** Due to late entries, the TPNs given at the start of the
> tournament are provisional. The definitive TPNs are given only when the
> List of Participants is closed, and corrections made accordingly in the
> results charts.

**Superseded reading (ours, rejected).** Exactly two things move a TPN: a
correction to the ranking data, and the closing of the participant list
after late entries. Both are one-off administrative events, and one of them
is barred outright after round four. Nothing in either article renumbers
TPNs around players who are not being paired in a particular round.

**Why it fails.** The paragraph's premise is that everyone registered holds
a TPN, so the only question is what moves it. Under 2.4 as the SPP
construes it, a player who has never arrived holds no TPN yet, so the
question of what moves theirs never arises. Nothing is renumbered; a number
is issued on arrival, and the ones already issued sit above it. Our
argument was answering a question the ruling does not ask.

## What the engines do

| | number whose parity decides | |
|---|---|---|
| **Ainalrami**, before the fix | the TPN, exactly as the file gives it | **wrong** |
| **bbpPairings 6.0.0** | a numbering that skips players who have never participated | correct |
| **Gacrux** | the same | correct |

After the fix all three rows say the same thing. The Ainalrami row records
behaviour that has been removed, not a variant that is still supported.

The two references agree with each other. That was not obvious - Gacrux's
condition is written `rfp or rip` (ready for pairing now, **or** paired at
some point before) while bbpPairings has no such clause in sight - so it
was measured both ways round with `tools/rip_probe.exs`:

- when the absent player **has already played**, all three engines agree,
  and nobody renumbers;
- when the absent player has **never played**, both references renumber
  and this engine did not.

The three therefore agree whenever the field is complete, because the two
numberings coincide, and diverged only once somebody had been registered
without ever being paired.

This measurement stands, and the ruling endorses the line the references
draw. It is also the measurement that refutes the retracted bullet above.

### The rule did change on 1 February 2026

This section is kept because the fact is real and interesting. Its
conclusion is not.

**Before** - C.04.3 Article E.5, effective till 31 January 2026:

> If the higher ranked player has an odd **pairing number**, give him the
> initial-colour; otherwise give him the opposite colour.

and A.2 defined that number as assigned by the initial ranking list **"and
subsequent modifications depending on possible late entries or rating
adjustments"**, with a note directing the reader to C.04.2.B/C "for the
proper management of the pairing numbers".

**After** - C.04.3 Article 5.2.5, effective 1 February 2026:

> If the higher ranked player has an odd **TPN** (see Article 1.1), give
> them the initial-colour; otherwise, give them the opposite colour.

Article 1.1 defines nothing; it delegates wholly to C.04.2 Article 2. So a
loosely-worded "pairing number" carrying "subsequent modifications" in its
own definition was replaced by a delegation to a tightly pinned TPN. That
much is accurate and was worth finding.

**Superseded conclusion:** *"Under the OLD wording, renumbering is
defensible. Under the new one it has no basis."*

**Why it fails.** The basis is C.04.2:2.4, which is not part of the C.04.3
rewrite at all and did not change with it. The narrowing of 5.2.5's wording
never reached the clause the ruling turns on, so tightening the delegation
tightened nothing. The engines that "carried pre-2026 behaviour forward"
were carrying behaviour that is correct under both wordings.

**And JaVaFo does it too.** Run on the same file as the table below, the
pre-2026 reference returns byte-identical output to bbpPairings:

```
4
2 7      <- White = TPN 2, which is EVEN, with initial-colour White
8 4
5 9
10 6
```

**Superseded conclusion:** that this reframed the dispute — that the
references' agreement was shared lineage rather than independent
derivation, and so "no longer counts against the reading here."

**Why it fails.** It was the load-bearing rebuttal to "three
implementations agree, and that is evidence against you", and it is now
moot: the authority that defines the rule has sided with the
implementations. Three engines agreed because they were right. The lineage
argument was a way of explaining away evidence that was correct — which is
what an argument constructed to preserve a conclusion looks like from the
inside.

### The references' reading was the right one

Kept in place, inverted. The old heading was "The references' reading is
not unreasonable", and the section conceded C.04.2:2.5 as a defensible
basis for skipping a player who never turned up:

> Due to late entries, the TPNs given at the start of the tournament are
> provisional. The definitive TPNs are given only when the List of
> Participants is closed…

The section then went on:

> What decides it the other way is 2.4, which says a late entry is *"given
> an appropriate TPN and paired only when they actually arrive."* The TPN
> exists before the arrival; it is the pairing that waits. A registered
> player who has not yet played therefore holds a TPN, and 5.2.5 asks for
> the parity of a TPN.

**That is the exact sentence the SPP ruled on, and it ruled the opposite
way.** See [the crux](#the-crux-both-sides-argued-from-the-same-sentence)
above. 2.4 does not decide it the other way; 2.4 is the reason the
references are right.

The closing line — *"that is why this is filed as a rules-interpretation
dispute rather than as a defect report against two engines"* — inverts too.
It is a defect report against one engine, and the engine is this one.

## The evidence

Kept in full. The measurements were always right; only the verdict column
was wrong.

`tools/round_one_colours.exs` puts a clean field and a field with byes
through both engines. Round one is the sharpest possible probe: nobody has
a colour preference yet, so **every** board falls through 5.2.1-5.2.4 to
5.2.5 alone.

Ten players, `152 W`, no byes - the engines agree on every board, and both
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
2, 4, 5, 6, 7, 8, 9, 10 - positions 1..8. Position and TPN now disagree
for TPN 2 (position 1) and agree for 4, 5 and 6 (positions 2, 3, 4).

All three engines on that field, with Gacrux run rather than read. The
final column is recomputed under the ruling — the number whose parity
decides is the position, not the TPN:

```
 board  | top TPN | position | parity | ours  | bbp   | gacrux | correct
 2v7    |       2 |        1 |  odd   |     7 |     2 |      2 | 2  (bbp, gacrux)
 4v8    |       4 |        2 |  even  |     8 |     8 |      8 | 8  (all three)
 5v9    |       5 |        3 |  odd   |     5 |     5 |      5 | 5  (all three)
 6v10   |       6 |        4 |  even  |    10 |    10 |     10 | 10 (all three)
```

**Exactly one board differs, and it is exactly the board whose TPN parity
and position parity disagree.** That is not a coincidence compatible with
several explanations; it is the signature of this one. The diagnosis of the
mechanism was always right; only the verdict on which side it favours has
changed.

It also settles the Gacrux question empirically. Gacrux is normally the
tiebreaker in this project - it is the third implementation of the same
2026 rules, and it is what backs this engine against bbpPairings in
[`dispute-seed735265.md`](dispute-seed735265.md). Here it did not: it
answers 2, with bbpPairings. Both references number by position, and the
ruling says that is the number 5.2.5 asks for. The engine answering 7 was
the one in the wrong.

`tools/rip_probe.exs` isolates the same split in round TWO, where it is
sharper still, because there the two candidate rules can be told apart:

```
absent player has already played   ->  ours 7, bbp 7, gacrux 7   (agree)
absent player has never played     ->  ours 3, bbp 2, gacrux 2   (differ)
```

Two positions, not one run: `rip_probe.exs` emits the first row, and the
second comes from the round-one field above. The `ours 3` is the PRE-FIX
engine; running the probe today gives `ours 2, bbp 2` on that position,
because this engine now numbers the way both references do.

Both references draw the line in the same place, and it is the line
between "has participated" and "has not", not between "is playing this
round" and "is not". Keep this block: it is the evidence that refuted the
retracted bullet, and the ruling confirms the line it measures.

Reproduce:

```bash
mix run tools/round_one_colours.exs 10 1,3

BBPPAIRINGS_EXE=../openpairings/priv/bbppairings/bbpPairings-windows.exe \
  MIX_ENV=test mix run tools/rip_probe.exs
```

(with `GACRUX_DIR` set, and under `MIX_ENV=test` so the reference adapters
are compiled - without it the Gacrux column is simply blank.)

`tools/round_one_colours.exs` used to hard-code the overturned rule in its
"who follows 5.2.5?" column, so it printed `NOBODY` on precisely the boards
where bbpPairings and Gacrux were right. It was corrected in the same change
that adopted the ruling: it now takes parity on the arrival number, prints
the arrival number alongside the TPN, and credits the engines that follow
the article.

## Scale

Measured over 200 seven-round tournaments at a 15% bye rate, **before the
fix**:

| axis | boards differing | after the fix |
|---|---|---|
| plain (no byes) | **0** | 0 - unchanged |
| 10% forfeits | **0** | 0 - unchanged |
| 20% forbidden pairs | **0** | 0 - unchanged |
| Baku acceleration | **0** | 0 - unchanged |
| 15% arbiter byes, `152 W` | 670 | **0** |
| 15% arbiter byes, `152 B` | 1175 | **0** |

The 670 and 1175 were previously counted as boards where this engine was
right and the references wrong. They are boards where this engine was
wrong.

**Measured 2026-08-28**, and the right-hand column is no longer an
expectation. The corpus was re-run on the corrected engine at scale, on the
same seeds as the figures it replaces: 750,449 rounds and 7,392,594 boards,
**zero** colour differences against bbpPairings, every axis independently
100.0% with nothing unexplained. A second run on different seeds
(1,065,373 rounds, 11,164,952 boards) says the same. See
[validation.md](validation.md#re-measured-2026-08-28-the-64131-are-zero).

What has been measured, at small scale on the bye-heavy axis, is that the
fix moves the disagreement to zero:

| corpus | before the fix | after |
|---|---|---|
| 60 tournaments, 5 rounds, 50% byes, 6-16 players | 27 colour disagreements vs bbpPairings | 0 |
| 60 tournaments, 5 rounds, 40% byes, 25% forfeits | — | 0 (1096/1096 pairs, 299/299 rounds) |

Neither row is reproducible from the tree as it stands, and that is worth
saying rather than leaving to be discovered: the "before" arm required code
that is deliberately not committed. Treat the 27 as a record of what was
observed on the day, not as a figure a reader can re-derive. The corpus
re-run is what will produce a quotable number.

The "before" figure was produced by deliberately reinstating the overturned
numbering and re-running, because a zero on its own is unfalsifiable: the
same corpus at a 15% bye rate reports zero under *both* readings, so a
smaller run would have "confirmed" the fix while measuring nothing.

The axes without byes showed *zero* colour differences, which is the
control that made the rest meaningful: this was never a general
disagreement about Article 5, it was precisely and only the numbering.
After the fix the bye axes are expected to join the control at zero, at
which point the control stops distinguishing anything.

## What this does not affect

**Who plays whom.** Colour allocation runs after the pairing is decided, so
a divergence here cannot move a player to a different board. Every axis
above reports 100.00% agreement on pairings and zero illegal rounds
throughout. The engine's headline result is untouched by the ruling — which
is what bounds the damage: a colour was wrong on a bounded set of boards,
and no pairing ever was.

## Why it was not being fixed, and why that is retracted

The old section read: *"Matching the references would take one line. It is
not being done, for the same reason recorded throughout this project: the
target is the regulation, not agreement."*

The stated principle survives and now compels the opposite action. The
target is the regulation; the regulation's meaning is settled; and it is
the references' meaning. The one line is now the required change, and it
has been made.

Two supporting reasons were given, and they are retracted differently:

- **"The renumbering is unstable in a way TPNs are not."** Descriptively
  accurate and *overruled*. It was offered as a reason not to comply, and
  the SPP's reading blunts it besides: the numbering is stable once a
  player has arrived, and moves only for players who have never arrived at
  all. It is recorded here as an objection that was raised and rejected,
  not as a live concern.
- **"The two references do not agree with each other either."** *False when
  written*, refuted by this document's own evidence, and re-confirmed false
  on 2026-08-27. See [the second
  retraction](#the-second-retraction-which-is-the-worse-one). It is deleted
  rather than softened; it must not survive as a hedge, because it was the
  only sentence claiming that "match the references" is not a well-defined
  target, and the fix has to match them exactly.

## How the harness handled it

`bbppairings_comparison_test.exs` used to split colour differences into two
counts. A board was filed under this dispute when 5.2.5 decided it -
neither player holding any colour preference - *and this engine's answer was
the one the article gives*. Everything else was reported as **unexplained**,
loudly.

Under the ruling that predicate is inverted: "the answer the article gives"
is now the references' answer, so the classifier filed correct boards as
disputed and incorrect ones as unexplained.

The bucket is therefore **deleted, not zeroed**, in both the bbpPairings
harness and the three-way one. Once this engine adopts the references'
reading, the bucket degenerates to "a board where we differ from the
reference is explained by our differing from it" — a tautology that would
swallow real regressions. A bucket labelled *expected* that nothing may
legitimately land in is a hiding place. Those boards now count as plain
colour mismatches and fail loudly.

Two consequences to keep in view:

- The three-way harness's moduledoc predicted a non-zero bbpPairings-vs-
  Gacrux split *inside* 5.2.5's reach, on the strength of the refuted
  claim above. Its own run found zero. The prediction went with the claim.
- "Zero unexplained" figures published while the bucket existed excluded
  boards now known to be defects. They are historical, not current, until
  re-measured.

## One live remnant: bbpPairings' own deduction

Where a file carries no `152` header, the initial colour has to be deduced
from the recorded round. bbpPairings does this on **the parity of the
coloured player's own arrival number**, not on the number at the top of
their board.

### The third instrument failure, found 2026-08-28

This section previously reported that finding as `17 / 17 / 0`, plus "27
times in 106" and a conformance figure of "81/81". **No script in the tree
produced any of those numbers.** They were stated as measured fact here and
in a comment in `pairing.ex`, and they could not be reproduced, because the
thing that produced them was never committed.

That is the same failure this document already records twice — a claim
written down without the evidence that would let anyone check it — and it
is worse for being the third one, in the file whose subject is the first
two. Every other measurement in this project has a committed instrument.
This one did not.

The instrument now exists: **`tools/inference_numbering_probe.exs`**. It
serialises the identical roster three times — no `152`, `152 W`, `152 B` —
and hands all three to the real binary. The two stated runs are the
alternatives; whichever one the silent run reproduces *is* bbpPairings'
deduction, read off bbpPairings' own output with this engine nowhere in the
loop. It re-derives both candidate readings itself rather than calling into
`Ainalrami.Pairing`, whose versions are private and are the thing under
test.

The old numbers are not preserved. The measurement below replaces them.

### What it actually measures

Run 2026-08-28, `INP_COUNT=200 INP_ROUNDS=7`, seeds 1–200, round one all
byes so the first coloured round is round two — which is the only place the
two readings can differ at all. Four quantities, kept apart because they
have four different denominators and the retracted figures had collapsed
three of them onto one number:

| quantity | count |
|---|---|
| **readable positions** — `152 W` and `152 B` paired differently and the silent run reproduced exactly one of them | **189**, from 142 distinct tournaments |
| of those, bbpPairings read as deducing White / Black | 87 / 102 |
| **split positions** — the two readings predict OPPOSITE draws | **38**, from 26 tournaments |
| **raw-TPN splits** — the arrival numbering and the overturned raw-TPN reading predict opposite draws | **52** |
| **conformance positions** — this engine's whole pairing vs bbpPairings' silent run | **189** |

And the verdicts on them:

| candidate rule | split positions | bbp followed |
|---|---|---|
| the coloured player's own arrival number | 38 | **38** |
| the top-of-board arrival number (the exact inverse) | 38 | **0** |

| candidate numbering | raw-TPN splits | bbp followed |
|---|---|---|
| the arrival number | 52 | **52** |
| the raw TPN (the overturned reading) | 52 | **0** |

Over all 189 readable positions the implemented reading predicted
bbpPairings' deduction 189 times and missed none. Conformance: 189 of 189
positions identical, colours included, zero differing, zero raised.

Two controls, because a table of flat zeroes is exactly what a dead
instrument prints:

- bbpPairings was read as deducing **Black on 102** of the 189 positions.
  It is deducing, not defaulting to White.
- `INP_SELFTEST=1` swaps the two candidate readings before the classifier
  sees them and changes nothing else. The same run then reports 0 and 38.
  The losing column is a live tally.

The conclusion the retracted numbers were offered for survives: the exact
inverse written on 2026-08-28 and reverted the same day was correctly
reverted. But it survives on this measurement, not on the old one, and the
old one should never have been quotable.

### The asymmetry itself

The interesting part is the forward control: with `152` present,
bbpPairings' *allocation* hands the initial colour to the top of the board.
So **bbpPairings is asymmetric with itself** — a file it paired under
`152 B` does not round-trip through its own deduction with the `152`
stripped.

This engine matches bbpPairings in both directions, deliberately. Article
5.1 leaves the initial colour to a drawing of lots and `152` is the record
of it; where the record is missing, C.04.3 says nothing whatsoever, so the
reference's behaviour is the only rule there is. Preferring our own
derivation to the measured reference on a point the text does not cover is
precisely the mistake this document records one article up.

Reproduce:

```bash
BBPPAIRINGS_EXE=../openpairings/priv/bbppairings/bbpPairings-windows.exe \
  INP_COUNT=200 INP_ROUNDS=7 mix run tools/inference_numbering_probe.exs

# and the falsifiability control
BBPPAIRINGS_EXE=... INP_COUNT=200 INP_ROUNDS=7 INP_SELFTEST=1 \
  mix run tools/inference_numbering_probe.exs
```

Gacrux is unverified here — networkx is absent on the machine this was
measured on. If the three-way harness ever splits from bbpPairings on a
no-`152` file, this asymmetry is the first place to look.

## Status

Filed 2026-08-21, answered 2026-08-27, decided against this engine. The
letter as sent is [`spp-question-initial-colour.md`](spp-question-initial-colour.md);
the answer and its reasoning are quoted at the top of this file.

The prediction in that letter — *"three independent programs agreeing is
usually a sign that the reader has misunderstood the rule … so I expect I
am missing something"* — was correct. What was missing was not a hidden
convention. It was C.04.2:2.4, read the other way round, and it was already
quoted in the letter.

This was described here as "the stronger of the two cases", against
[`dispute-seed735265.md`](dispute-seed735265.md). That is backwards.
seed735265 still stands, with Gacrux backing this engine board for board.
This one fell.
