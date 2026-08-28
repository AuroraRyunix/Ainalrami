# Validation

How Ainalrami is measured, what the numbers are, and - the part that
matters most - what the measurements could not have seen.

The headline is in the [README](../README.md). This document is the
methodology behind it and the reasoning that makes it worth anything.

## The references

Three external implementations, used for different purposes.

| engine | rules edition | role |
|---|---|---|
| **bbpPairings 6.0.0** | 2026 | the primary oracle; run directly, not read |
| **Gacrux / TieBreakServer** | 2026 | independent third opinion; Python, literal enumeration |
| **JaVaFo** | 2022 | a *control*, not a target |

None is vendored. Each is located at runtime:

```bash
BBPPAIRINGS_EXE=/path/to/bbpPairings   # required for --only bbppairings
JAVAFO_JAR=/path/to/javafo.jar         # required for --only javafo
GACRUX_DIR=/path/to/TieBreakServer     # required for --only three_way
GACRUX_PYTHON=python3
```

**Why bbpPairings is the primary oracle and JaVaFo is not.** JaVaFo is
FIDE's own reference implementation, which makes it the intuitive target
and the wrong one: it implements the superseded 2022 rules. bbpPairings
and Gacrux both implement the 2026 edition. Over 3352 rounds those two
agreed with each other on **every single one**, which bounds their mutual
disagreement at ~0.09% and is what makes them usable as a ruler at all.

Ainalrami disagrees with JaVaFo, and that is the expected result rather
than a defect - it is the size of the rules change. An engine agreeing
with all three simultaneously would prove the harness was measuring
nothing.

**How much it disagrees depends entirely on the axis**, which one figure
cannot say. This page carried a bare "96.26%" for a while, unattached to
any axis; measured per axis on 2026-08-26, with the real jar and zero
process errors:

| axis | tournaments x rounds | exact rounds | individual pairs |
|---|---|---|---|
| round one only | 2000 x 1 | **100.00%** | 100.00% |
| plain | 400 x 5 | **98.82%** | 99.62% |
| 10% arbiter byes | 400 x 5 | **91.22%** | 97.68% |
| 10% forfeits | 400 x 5 | **89.60%** | 97.38% |
| both | 400 x 5 | **83.68%** | 95.19% |

Round one is identical, which is what you would expect of a rules change
that lives in the bracket cascade rather than the initial split. Every
axis that puts an UNPLAYED game on a scorecard - a bye, a forfeit - is
where the 2022 and 2026 texts part company, and it compounds with the
round count. The same axes measure 100.00% against bbpPairings, which is
the whole reason bbpPairings is the oracle here and JaVaFo is the control.

Note also that this harness reads only seven of the sixteen
`PAIRING_FUZZ_*` knobs (it predates `Ainalrami.Test.FuzzTournament` and
has its own generator); since 2026-08-26 it REFUSES the other nine rather
than reporting the default axis's rate under their name.

## The corpora

Six of them now, run between 2026-08-20 and 2026-08-24. The totals every
other number on this page sits inside:

| run | axes | rounds | individual pairings | disagreements |
|---|---|---|---|---|
| Round sweep, R=1..20 (08-23) | 20 | 59,966,505 | 684,901,202 | 0 |
| Cross-axis (08-23) | 25 | 35,436,044 | 474,685,328 | 0 |
| Rating shape / withdrawals / tiny fields (08-24) | 16 | 25,209,754 | 285,118,044 | 0 |
| Randomised corpus (08-23) | 4 | 7,898,024 | 116,251,032 | 0 |
| Six-million run (08-20) | 17 | 44,486,465 | 488,033,862 | 2 |
| Same axes, disjoint seeds (08-21) | 17 | 44,473,264 | 487,338,797 | 0 |
| **total** | **99** | **217,470,056** | **2,536,328,265** | **2** |

The last row is a replication, not new coverage: the same seventeen axes
on a different build of this engine - so the 99 axis-runs are 82 distinct
ones. It is evidence that the matching optimisation is correctness-neutral,
not evidence about the rules.

The 08-20 corpus is written up in full below. Per-axis detail for the four
later runs is in [engineering-log.md](engineering-log.md), under their own
dates.

**A seventh, on 2026-08-26**, re-measuring after the sweep's thirteen
fixes. Small next to the table above and deliberately so - its job is to
show the fixes cost nothing, not to add coverage:

| axis | rounds | individual pairings | refused | illegal | disagreements |
|---|---|---|---|---|---|
| everything on, 4-40, 6000x9 | 47,882 | 386,562 | 0 | 0 | 0 |
| small fields 4-10, 40000x9 | 245,952 | 863,316 | 0 | 0 | 0 |
| deep rounds 4-40, 2000x16 | 27,271 | 311,987 | 0 | 0 | 0 |
| **total** | **321,105** | **1,561,865** | **0** | **0** | **0** |

"Everything on" is every axis the harness has at once: mixed point
systems, mixed acceleration, mixed initial colour, 12% arbiter byes, 10%
forfeits, 8% withdrawals, 8% forbidden pairs and mixed rating shapes.

Worth saying plainly what that does and does not prove. Two of the thirteen
fixes are invisible to any corpus this generator can produce - the
`0000 - +` / `0000 - -` scoring split (the generator only ever writes `-`
against a real opponent) and the short serialized line (the corpus never
serializes a round in progress). A third, the negative blossom duals, was
happening 734 times per 800 nine-round tournaments while the engine agreed
with bbpPairings on all 800. A clean corpus after a fix is evidence the fix
broke nothing. It is not evidence the fix was unnecessary, and for these
three it could never have been the thing that found them.

**The limit of all of it.** Every one of those 2.5 billion pairings is
measured against a SINGLE oracle, and agreement with one reference cannot
detect a rule both engines read the same wrong way. The only instrument
that can is the three-way harness, and it has run 649,207 rounds - see
[The references](#the-references) for what that does and does not bound.

## The corpus

**5,993,000 tournaments, 44,486,465 rounds, 488,033,862 individual
pairings, two disagreements** - the 2026-08-20 run on a 36-core machine,
seventeen axes, ~15 hours. Neither disagreement is a defect here: both are
the bbpPairings [C2] second-bye defect, and Gacrux returns this engine's
answer on both (see below).

| axis | tournaments | rounds | individual pairs | disagreements |
|---|---|---|---|---|
| 300-500 players, byes | 3,000 | 27,000 | 4,871,001 | 0 |
| 150-250 players, byes | 30,000 | 270,000 | 24,357,105 | 0 |
| 150-250, byes+forfeits+`XXP`+Baku | 10,000 | 90,000 | 8,128,884 | 0 |
| 60-120 players, byes | 200,000 | 1,800,000 | 73,378,553 | 0 |
| 60-120, byes+forfeits+`XXP`+Baku | 100,000 | 900,000 | 36,689,898 | 0 |
| 4-40, byes+forfeits+`XXP`+Baku | 400,000 | 3,334,635 | 35,022,819 | 0 |
| 4-40, 15% byes | 600,000 | 5,037,730 | 50,883,196 | 0 |
| 4-40, 10% forfeits | 300,000 | 2,518,015 | 29,805,864 | 0 |
| 4-40, 20% forbidden (`XXP`) | 300,000 | 2,477,490 | 29,656,258 | 0 |
| 4-40, random acceleration | 300,000 | 2,516,311 | 26,897,840 | **1** |
| 4-40, Black drawn first | 300,000 | 2,526,740 | 25,473,925 | 0 |
| 4-40, plain | 300,000 | 2,529,979 | 29,866,857 | 0 |
| 4-40, 8 rounds | 300,000 | 2,270,382 | 22,727,208 | 0 |
| 4-40, 10 rounds, combined | 200,000 | 1,825,095 | 19,327,331 | 0 |
| 4-40, 13 rounds | 150,000 | 1,721,955 | 17,954,308 | 0 |
| 4-10, 15% byes | 2,000,000 | 11,644,432 | 40,827,511 | **1** |
| 4-10, plain | 500,000 | 2,996,701 | 12,165,304 | 0 |

**Zero illegal rounds across all seventeen.** Legality is checked
independently of agreement - it is the question with a right answer,
where "does bbpPairings pair it the same way" is not.

### Replication on fresh seeds, post-optimisation

**5,993,000 tournaments, 44,473,264 rounds, 487,338,797 individual
pairings, ZERO disagreements** - the 2026-08-21 run, same seventeen axes,
same machine, ~14.7 hours.

Two things differ from the run above, and both are the point of having
done it:

* **Different engine.** This ran on `adae426`, which makes `finalize_pair`
  a pure edge removal and skips `prepare_vertex` - a matching-layer
  optimisation, i.e. exactly the kind of change that can be correct on
  every test and still wrong on the millionth bracket. It is not.
* **Disjoint seeds** (from 9,000,001), so this is an independent corpus
  rather than a re-run of the same tournaments.

The round and pairing counts differ slightly from the first run for the
same reason the seeds do: how early a small field exhausts its legal
opponents is seed-dependent, so the same axis definition yields a
marginally different amount of work each time.

**Zero disagreements does not mean the [C2] defect is gone.** Both
disputes above were bbpPairings defects on specific seeds; fresh seeds
simply did not land on that configuration again. bbpPairings is unchanged
and still wrong there, which is why all three disputes stay pinned as
regression tests rather than being treated as resolved by this run.

One caveat on the headline count, which applies to both runs equally:
2,724,198 tournaments (45.5%) ended early because bbpPairings ran out of
legal pairings - overwhelmingly in the 4-10 player axes, where nine rounds
is arithmetically impossible without repeats (88.2% of `4-10, 15% byes`
and 78.2% of `4-10, plain` terminated early). Those tournaments are
excluded from the rates, so agreement is measured up to exhaustion and
not about it: if this engine were willing to pair a round bbpPairings
declines, these axes could not show it.

**That gap is now measured. See below.**

### The three-way run (2026-08-27)

The weakest number on this page was three-way agreement: 3,352 rounds
against 217 million two-way. Everything else rests on bbpPairings being
right, and this was the only instrument that could catch a rule both
engines read the same way wrong.

Eight axes, 649,207 rounds compared by all three engines - **194 times the
previous coverage**. A ninth axis was void: it was run alongside another
job on the same box and failed on reference processes not launching, which
is the resource-starvation failure this harness's own moduledoc warns
about. It is being re-run alone rather than quoted.

**Composition. Ainalrami agreed with bbpPairings on 649,207 of 649,207
rounds - 100.00% on every axis.** The two disagree nowhere.

The three engines are not unanimous, and the pattern is the point:

| axis | bbpPairings vs Gacrux | Ainalrami vs bbpPairings |
|---|---|---|
| 12% byes | 83,981/83,988 | 83,988/83,988 |
| 10% forfeits | 83,886/83,898 | 83,898/83,898 |
| everything Gacrux allows | 80,561/80,679 | 80,679/80,679 |
| the other five axes | 100% | 100% |

137 rounds where the references disagree with each other, and in every one
of them Ainalrami is on bbpPairings' side. There is no round in 649,207
where Ainalrami is the odd one out.

### Colour, measured three ways for the first time

`same?/2` compares through `normalize/1`, which sorts each pair's ranks, so
every number this harness had ever reported was colour-blind - the same gap
that hid a missing Article 5.2.4 through 195 million pairings in the
two-way harness. It now carries three pairwise colour rates over the boards
each PAIR of engines both formed.

**6,242,974 boards.** Ainalrami against bbpPairings: 6,178,843 agreed,
64,131 differing, every one of them falling under what was then the open
Article 5.2.5 dispute.

#### Those figures describe behaviour that has been removed

**They are the last actual measurement, and they are superseded.** On
2026-08-27 the FIDE Systems of Pairings and Programmes Commission answered
the question this project had put to it, and answered it against this
engine: Article 5.2.5's parity is taken on a numbering that skips players
who have never been paired, not on the TPN as C.04.2 Article 2 defines it.
Both references were right. Ainalrami was wrong.

The crux is that both sides argued from the same sentence. C.04.2:2.4 says
a late entry is *"given an appropriate TPN and paired only when they
actually arrive."* This project read that as: the TPN exists before the
arrival, and it is the PAIRING that waits. The SPP reads the identical
clause as: players who have yet to arrive don't have a TPN. We read it the
wrong way round. The reasoning is kept in full in
[dispute-initial-colour.md](dispute-initial-colour.md), marked as
superseded rather than deleted, because it is why the engine behaved this
way for months.

So the 64,131 are not 64,131 documented divergences. They are 64,131 boards
on which this engine was wrong. The claim that used to stand here - that
this was the strongest statement the project had about Article 5 - is
withdrawn outright.

#### The re-measurement is PENDING, and no zero has been observed

The engine now numbers the way the references do. The corpus has **not**
been re-run. The expectation is that the same 6,242,974 boards come back
6,242,974 agreed and zero differing, since the one documented cause of the
64,131 has been removed - but that is an EXPECTATION, not a measurement,
and this project has been burned by carried-forward numbers before. No zero
appears on this page until one has been observed.

Until the re-run, the honest statement of this engine's colour agreement
with bbpPairings at scale is: **unmeasured on the current engine.** The
figure that stands is the superseded one above.

**And the two references contradict each other.** On the forfeit axis and
on the combined axis, one board each where bbpPairings and Gacrux disagree
about who is White, outside 5.2.5's reach - so on Articles 5.2.1 to 5.2.4,
which nobody disputes. In both, Ainalrami agrees with bbpPairings and
Gacrux is alone.

**The ruling does not touch those two boards and does not resolve them.**
They fall outside 5.2.5 by construction, which is why they were reported
separately in the first place; they are still open, still unadjudicated,
and the re-run above will not close them.

Two boards in 6.2 million is a rate of 3.2e-5%, and it is not zero. Nobody
had measured it before, because measuring it needs an instrument that
compares two references to each other rather than both to the engine under
test. Both positions are worth reading; see the note in TODO.md.

The rule-of-three bound on the references' true colour-disagreement rate is
now about **3e-4%** per axis, computed over boards rather than rounds. That
bound is also unaffected by the ruling: it is measured between the two
references, and neither of them changed.

### The exhaustion probe (2026-08-27)

The corpus halts a tournament the moment bbpPairings answers "no legal
pairing left", records it as exhausted, and never asks this engine. So the
one behaviour it was structurally blind to was this engine being MORE
permissive than the reference - willing to pair a round the reference
refuses.

`tools/exhaustion_probe.exs` asks. Same generator, same axes, same TRF; on
`{:no_valid_pairing, _}` it puts the identical position to
`Pairing.pair_next_round/2` and classifies what comes back.

| axis | tournaments | reached exhaustion | both refused | disagreements |
|---|---|---|---|---|
| 4-10, plain, 9 rounds | 200,000 | 156,290 (78.1%) | 156,290 | 0 |
| 4-10, 15% byes, 9 rounds | 200,000 | 177,608 (88.8%) | 177,608 | 0 |
| 4-10, 12% forfeits, 9 rounds | 150,000 | 136,408 (90.9%) | 136,408 | 0 |
| 4-6, 20 rounds | 150,000 | 150,000 (100%) | 150,000 | 0 |
| 4-10, every axis on, 9 rounds | 150,000 | 149,121 (99.4%) | 149,121 | 0 |
| 11-20, 16 rounds | 80,000 | 46,052 (57.6%) | 46,052 | 0 |
| **total** | **930,000** | **815,479** | **815,479** | **0** |

**815,479 positions where bbpPairings said no legal pairing exists, and
this engine said the same thing every time.** Three bbpPairings process
errors (0.0003%) are excluded.

The exhaustion rates reproduce the corpus's own: 78.1% against the recorded
78.2% for `4-10, plain`, 88.8% against 88.2% for `4-10, 15% byes`. That is
the probe confirming it recreated the same conditions, not a second
measurement of the same thing.

Had the engine returned a pairing, the probe checks it for a rematch, a
second pairing-allocated bye, a forbidden pair, and a correct partition of
the active field. The first three are checked against the recorded game
history alone and share nothing with the engine's own reasoning; the
partition and bye-count checks have to derive the active set from the game
lists, which IS circular, and are reported under their own names for that
reason. None of them fired, so the distinction did not end up mattering.

### The refusals are proved, not corroborated (2026-08-27)

Both engines refusing was not proof that a legal pairing does not exist -
it was the single-oracle limit again, moved from the pairing to the
refusal, and two engines can be wrong together.

`tools/exhaustion_bruteforce.exs` settles it by enumeration. On every
refusal it walks all `(n-1)!!` complete pairings of the active field, times
`n` for the bye on an odd field, and tests each against C1, C2, C3 and the
arbiter's own exclusions - written from the article text, sharing no code
with `Ainalrami.Pairing` and structurally its opposite.

| axis | tournaments | refusals | proved impossible | legal pairing found |
|---|---|---|---|---|
| 4-6, 20 rounds | 200,000 | 200,000 | 200,000 | 0 |
| 4-10, 9 rounds | 200,000 | 156,163 | 156,163 | 0 |
| 4-10, 15% byes | 150,000 | 133,337 | 133,337 | 0 |
| 4-10, 12% forfeits | 150,000 | 136,307 | 136,307 | 0 |
| 4-12, 14 rounds, every axis on | 100,000 | 100,000 | 100,000 | 0 |
| 7-12, 16 rounds | 80,000 | 80,000 | 80,000 | 0 |
| **total** | **880,000** | **805,807** | **805,807** | **0** |

**Every one of the 805,807 refusals is proved.** Not "the two engines
agree" - no complete pairing of that field satisfies the absolute criteria,
established by exhaustion.

**4,876,836 positive controls passed.** On every round bbpPairings DID
pair, the same oracle was asked whether a legal pairing exists and had to
answer yes. An oracle too strict would fail there and then "prove" every
refusal impossible for the same wrong reason, so without this the negative
result would be worth nothing. It also checked the ACTIVE SET against the
reference's own pairing, which names exactly who was in the round: zero
mismatches over all 4.8 million.

**The control earned its place immediately.** The first run of this tool
reported 11,013 false verdicts against the engine, and four separate
defects in the tool caused them - not one in the engine:

* The active set came from the loop counter. When the whole field holds a
  pre-recorded bye the round is entirely byes and the reference advances to
  pair the next one, so the counter and the reference disagreed about which
  round was being paired. Now derived from the data.
* An empty active field made `perfect_matching?([])` vacuously true, which
  reported an empty field as a legal pairing against the reference.
* C2 valued a half-point bye at `win / 2`, which is only right while a draw
  is worth half a win. `BBD 2.0` makes it worth MORE than a win, which
  disqualifies its holder from the bye - the tool said the opposite. This
  is the same defect, in the same shape, as the one fixed in the engine
  itself the previous day: a result scored from its code without the system
  that says what the code is worth.
* C3's topscorer exemption was written as AND where the article, and three
  independent implementations, have OR. Every one of those 11,013 landed in
  the final round, which is the only round where topscorer status exists -
  that signature is what identified it.

The `max(win, draw)` term in 1.8's threshold was wrong here because
`docs/conformance-c0403-2026.md` still documented the `win`-only form that
0.11.1 had already fixed. A conformance record is read as the
specification; when it lags the code it does not go quiet, it propagates.

**What is still not proved.** The enumeration is capped at 14 active
players, so it says nothing about refusals on larger fields - though those
are rarer, since a bigger field has more ways to be pairable. And it tests
the three ABSOLUTE criteria; a refusal driven by something else would not
be caught. Nothing in the corpus suggests one exists.

### What this run added over its predecessors

It is the first corpus measured on the local-graph engine (see
`docs/engineering-log.md`), and the speed is what bought the coverage:
60-120 players ran at ~22 tournaments/s against 0.36 before, so the large
axes stopped being unaffordable.

- **300-500 players had never been validated at any scale.** Neither had
  150-250 with forfeits and forbidden pairs on top.
- **The large-field axes are 3.1 million rounds** between them, against
  600 tournaments in the previous corpus - the dimension that was
  thinnest is now among the thickest, which matters because the local
  graph only engages on brackets big enough to qualify.
- **A Black-drawn-first axis**, exercising the half of Article 5.2.5 that
  hands out the *opposite* colour. (This bullet used to say the axis
  exercised "the 5.2.5 reading this engine settles against both
  references". There is no such reading: the SPP ruled on 2026-08-27 that
  the references were right. The axis is worth exactly as much as it always
  was - it is about which colour the draw hands out, not about which number
  the parity is taken on - but the justification was wrong.)

### The two disagreements

Both are the same bbpPairings defect, on different axes and seed ranges:
it allocates a second pairing-allocated bye to a player who already holds
one, which [C2] forbids absolutely. The adjudicator scores both
`incomparable` - neither is a case where bbpPairings' answer is better on
this engine's own ladder - and Gacrux, a third independent implementation,
returns this engine's answer board-for-board on both.

In `seed7073463-r8-p9` the round has exactly one legal shape, reached by
eliminating four players who each already hold a bye and are down to a
single legal opponent. There is no scoring argument to make about it.

Written up in `docs/bbppairings-c2-bug-report.md`, decoded position by
position in `test/fixtures/fe1_disputes/README.md`, and pinned by
`test/ainalrami/c2_second_bye_test.exs`.

## Re-validation after the 2026-08-18 changes

**11,000 tournaments / 69,038 rounds / 680,022 individual pairings, at
100.00% with zero illegal rounds, zero refusals and zero unexplained
colour differences.**

**Read "zero unexplained" with the 2026-08-27 ruling in mind.** That figure
was computed with a colour split that filed every Article 5.2.5 board under
a known dispute and counted only the remainder. The SPP has since ruled
that dispute against this engine, so boards the split absorbed as
*explained* are now known to have been defects. The pairing figure -
100.00%, zero illegal, zero refusals - is untouched; colour on this axis is
pending re-measurement like every other colour figure on this page.

| axis | rounds | individual pairs |
|---|---|---|
| byes + forfeits + `XXP` + `XXA`, 7 rounds | 16,605 | 165,629 |
| 15% byes, **8** rounds | 18,920 | 189,175 |
| plain, 4-10 players | 6,586 | 26,032 |
| **60-120 players** | 840 | 38,717 |
| 15% byes, **6** rounds | 6,990 | 68,567 |
| 15% byes, **10** rounds | 11,015 | 112,155 |
| **`152 B`** + byes + forfeits | 8,082 | 79,747 |

Two of those axes are new rather than repeats. The **Black draw** row
exercises the half of Article 5.2.5 that hands out the *opposite* colour,
which no axis ran until the `152` field was read at all; and the round
counts deliberately span 6, 7, 8 and 10, for the reason the next section
gives.

Re-running the full 4.3M corpus is a machine-hours job rather than a code
change, and is worth doing before any endorsement submission.

| axis | tournaments | exact rounds | individual pairs | illegal |
|---|---|---|---|---|
| plain, 4-40 players | 120,000 | 100.00% | 100.00% | 0 |
| plain, 4-10 players | 500,000 | 100.00% | 100.00% | 0 |
| 15% arbiter byes, 4-40 | 250,000 | 100.00% | 100.00% | 0 |
| 15% arbiter byes, 4-10 | 1,200,000 | 100.00% (1 dispute) | 100.00% | 0 |
| 10% forfeits, 4-40 | 120,000 | 100.00% | 100.00% | 0 |
| 20% forbidden (`XXP`) | 120,000 | 100.00% | 100.00% | 0 |
| Baku acceleration (`XXA`) | 120,000 | 100.00% | 100.00% | 0 |
| byes + forfeits + `XXP` + `XXA` | 120,000 | 100.00% | 100.00% | 0 |
| 60-120 players | 600 | 100.00% | 100.00% | 0 |
| **even round counts** (6, 8, 10) | 850,000 | 100.00% | 100.00% | 0 |
| odd-round controls (7, 9) | 350,000 | 100.00% | 100.00% | 0 |

FIDE's FE1 endorsement bar is one difference per 500 tournaments. This is
one per 3.0 million.

That one is `seed735265-r7-p10`, kept as a fixture at
`test/fixtures/fe1_disputes/`. It is a rules-interpretation dispute, not a
defect: bbpPairings awards a second pairing-allocated bye to a player who
already holds one, which absolute criterion C2 forbids, and Gacrux pairs
it as this engine does. Argued in full in
[dispute-seed735265.md](dispute-seed735265.md).

## Running it

The comparison suites are tagged and excluded from `mix test`:

```bash
mix test --only bbppairings
```

| tag | what it runs |
|---|---|
| `bbppairings` | the main fuzz harness against bbpPairings |
| `javafo` | composition against real JaVaFo, every round (seven axes only - see above) |
| `three_way` | Ainalrami vs bbpPairings vs Gacrux on identical positions |
| `taxonomy` | classify disagreements by first differing bracket |
| `rule_delta` | pinned cases where the 2022 and 2026 rules differ |

Every axis is a set of environment variables:

| variable | default | meaning |
|---|---|---|
| `PAIRING_FUZZ_COUNT` | small | tournaments to generate |
| `PAIRING_FUZZ_ROUNDS` | 9 | rounds per tournament - **vary this** |
| `PAIRING_FUZZ_ROUNDS_MAX` | unset | makes rounds a RANGE drawn per tournament, `ROUNDS..ROUNDS_MAX` |
| `PAIRING_FUZZ_ACCEL=mixed` | - | draws none/baku/random per tournament |
| `PAIRING_FUZZ_INITIAL_COLOUR=mixed` | - | draws W/B per tournament |
| `PAIRING_FUZZ_NUMERIC_EXT=mixed` | - | draws XXA/XXP vs 250/260 per tournament |
| `PAIRING_FUZZ_RATING_MODE` | `spread` | `spread`/`clustered`/`equal`/`unrated`/`all_unrated`/`mixed` - see below |
| `PAIRING_FUZZ_WITHDRAW_PCT` | 0 | chance per player per round of dropping out for good, from round 2 |
| `PAIRING_FUZZ_MIN_PLAYERS` / `MAX_PLAYERS` | 4 / 40 | field size range |
| `PAIRING_FUZZ_SEED_FROM` | 1 | start of the seed range |
| `PAIRING_FUZZ_BYE_PCT` | 0 | arbiter-assigned bye rate |
| `PAIRING_FUZZ_FORFEIT_PCT` | 0 | forfeit rate |
| `PAIRING_FUZZ_FORBIDDEN_PCT` | 0 | `XXP` density |
| `PAIRING_FUZZ_ACCEL` | none | `baku` or random `XXA` |
| `PAIRING_FUZZ_INITIAL_COLOUR` | `w` | TRF `152` header |
| `PAIRING_FUZZ_DUMP` | - | directory for failing cases |
| `COLOUR_DEBUG` | - | report colour mismatches per pair |

`overnight_run/run.sh` drives the long batches.

**Seeds are independent**, and `PAIRING_FUZZ_SEED_FROM` starts the range
anywhere - so any catalogued case regenerates in about a second rather
than requiring the 735,264 tournaments before it. That knob not existing
is a large part of why early catalogued cases were adjudicated once and
never revisited.

## What the corpus could not see

This is the section worth reading.

### 2.5 million tournaments held one parameter constant

**Rating shape** was held constant until 2026-08-23 at "uniform
1000..2800", which makes every player rated and rating ties incidental -
close to the opposite of real chess, where a junior event is entirely
unrated and a club field sits on a handful of rounded numbers. Equal
ratings put the INITIAL RANKING on a different path: not "sort by rating"
but whatever breaks the tie. That ranking is the foundation of every
bracket in every round, so two engines breaking it differently disagree
about everything afterwards. `PAIRING_FUZZ_RATING_MODE` varies it, and
`bbppairings_comparison_test.exs` carries a test asserting each mode really
does reshape the roster - a mode that went inert would still report 100%
agreement while testing nothing.

**Withdrawals** likewise: no corpus before that date ever generated one,
so the TRF construct expressing "this player has left" had never been read
by bbpPairings from a file this project produced.

**Closed as of 2026-08-23**: the round count has now been swept end to end,
R=1 through R=20, at ~3M rounds per axis - 10,793,215 tournaments,
684,901,202 pairings, zero disagreements, zero illegal rounds. See "The
round-count sweep" in docs/engineering-log.md. Round count is no longer an
untested dimension; what remains untested is that dimension CROSSED with the
others (forfeits, forbidden pairs, acceleration, large fields).

Every axis measured before 2026-08-17 ran `PAIRING_FUZZ_ROUNDS=9`. A
nine-round tournament pairs its final round with **eight** played, and
`div(8, 2) == 8 / 2`.

So a topscorer threshold that *floors* the half-point is invisible. It can
only differ when the played-round count is odd - that is, when the
tournament has an **even** number of rounds. `final_round_topscorers?/2`
had exactly that bug. Re-measured at 8 rounds, 2,000 tournaments:

| | exact rounds | individual pairs |
|---|---|---|
| before | 15051/15060 = 99.94% | 155831/155862 = 99.98% |
| after | **15060/15060 = 100.00%** | **155862/155862 = 100.00%** |

Nine wrong rounds that 2.5 million tournaments could not produce. Six-,
eight- and ten-round Swisses are ordinary events; this was never an exotic
corner.

**The same expression was wrong a second time, and the same lesson caught
it (2026-08-25).** The threshold reads
`playedRounds * std::max(pointsForWin, pointsForDraw) >> 1` in the
reference (`dutch.cpp:55`); this engine read `pointsForWin` alone. Every
point system the harness could generate had the win worth at least as much
as the draw, so the two factors were the same number and no axis could tell
them apart - the same shape as the floor bug above, one line lower.

`BBW` and `BBD` are free-form in the file, so a draw worth more than a win
parses even though FIDE would never publish one. A `draw_heavy` axis
(win 1.0, draw 2.0) was added and run in TWO ARMS over identical seeds -
one with the fix, one with that single line reverted - because a fix that
cannot be measured is a fix that has not been tested:

| axis | with `max` | with `pointsForWin` alone |
|---|---|---|
| 4-10, 9 rounds | 1,163,034/1,163,034 = **100.00%** | 1,162,583 = 99.96% |
| 4-40, 9 rounds | 1,006,012/1,006,012 = **100.00%** | 1,002,565 = 99.66% |
| 4-40, 8 rounds | 907,227/907,227 = **100.00%** | 904,339 = 99.68% |
| 4-40, 6 rounds | 698,901/698,901 = **100.00%** | 697,506 = 99.80% |
| **total** | **3,775,174 rounds / 31,184,698 pairings, 100.00%** | 8,181 wrong rounds |

Zero illegal rounds in either arm, which is the point: the control arm does
not crash or refuse, it quietly pairs 8,181 rounds differently from the
reference. Without the second arm the first arm's 100% would have been
indistinguishable from an axis that never reaches the exception at all.

The axis was also checked for inertness before being trusted - a generated
file carries a real `BBD 2.0` line, and bbpPairings reads it. An axis that
goes quietly inert reports 100% while testing nothing, which this project
has been bitten by before.

**Corpus size bought nothing here.** The axes varied field size, bye rate,
forfeit rate and extension lines - and held constant the one parameter the
bug was a function of.

> When adding an axis, ask what the existing ones hold **constant**, not
> what they vary.

The even-round axis is now first-class: 1,800,000 tournaments across
rounds 6/7/8/9/10, zero disagreements. The odd controls are the point -
had 7 and 9 also moved, the fix would have been wrong in a way the small
local run could not have shown.

### "Zero illegal rounds" was true until it was tested 100× harder

Legality is checked independently of any reference: every player paired
exactly once, no rematches, exactly one pairing-allocated bye in an odd
active field and none in an even one.

That held at every sample size up to ~5,500 rounds. At 839,776 rounds it
did not: the first 100,000-tournament bye-rate run found **102 illegal
rounds (0.012%)**. Ninety-five raised `ArgumentError` from a range
`0..-1` - Elixir's default step for a descending range walks `0, -1`, and
`elem(arr, -1)` is an invalid index - reachable only when exactly one
player was left needing a bye. Five returned the wrong bye count, two a
non-partition.

All are closed, each with a regression test that fails on the pre-fix
code. Re-running the identical configuration over 250,000 tournaments /
2,099,071 rounds now gives zero.

**The standing bar is the 100× sample, not the one that passed.**

### Four instruments were broken or blind

Found while chasing the above, and worth listing because three engine bugs
were found *by* fixing the instrument rather than by the instrument:

- **`explain_round/3` never stamped float history**, so C14-C21 scored a
  constant on both sides of every verdict the adjudicator ever printed. It
  could not invent a disagreement - both sides were scored blank, so a tie
  stayed a tie - but it could *misattribute* one. It had no test of any
  kind until `explain_round_test.exs`.
- **The legality oracle was a copy of the engine.** An enumerator that
  checks C1 but neither C2 nor C3 reports "legal pairings the engine
  refused" - it has admitted illegal ones. A weaker oracle accusing a
  stronger implementation is the expected result, not a finding.
- **Every axis pinned `ROUNDS=9`**, as above.
- **The harness never compared colours.** Colour agreement was simply not
  measured until `colour_mismatches/5` was added - 4.3 million tournaments
  and 195 million pairings had validated who plays whom and never once
  checked Article 5. Turning it on immediately found a missing 5.2.4 and
  then the 5.2.5 divergence below - which was argued as a dispute for ten
  days and then ruled a defect in this engine.

### Colour is measured separately, and is no longer split by cause

Colour differences are counted apart from pairing differences, because
they fail for different reasons: a colour difference on an otherwise
identical round is not the same finding as a different round. That part
stands.

**What has been removed is the second split**, wherever one of the two
answers being compared is this engine's. In the two-way harness
`colour_mismatches/5` no longer returns a `colour_disputed` count and
`report/4` no longer prints one; comparison against bbpPairings is flat
equality, and a board where this engine names a different White is a
mismatch, counted as one, with no bucket to fall into. In the three-way
harness the `:conformance` classification is gone from both comparisons
that have this engine on one side, so their report line reads
`expected (none are)` - the count is structurally zero rather than
observed to be zero.

**Why the split existed.** Until 2026-08-27 this engine took Article
5.2.5's parity on the TPN and both references took it on a numbering that
skips players who have never been paired, so every board 5.2.5 decided on
a field where somebody had sat out differed by construction - hundreds of
boards per few hundred bye-heavy tournaments, 64,131 across the six-million
run. That volume would have buried a real colour regression completely, so
boards were sorted into the known
[Article 5.2.5 divergence](dispute-initial-colour.md) and **unexplained**,
and only the second number was watched.

The predicate did the sorting by asking whether 5.2.5 was what decided the
board (neither player holds a colour preference) **and this engine's answer
was the one the article gives**. That was deliberately a conformance test
rather than a model of bbpPairings' internals - an earlier version did the
latter and mis-filed a genuine case.

**Why it no longer does.** The SPP ruled the numbering question against
this engine, the allocation now uses the references' numbering, and the
predicate inverts with it: "the answer the article gives" is now the
references' answer, so the old test would file correct boards as divergent
and incorrect ones as unexplained. Worse, once we implement the same rule the
bucket degenerates into "a board where we differ from the reference is
explained by our differing from the reference" - a tautology that would
swallow real regressions. A bucket labelled *expected* that nothing may
legitimately land in is a hiding place, so it is deleted rather than
zeroed.

**What survives, and only where neither side is this engine.** The
three-way harness still classifies one of its three comparisons -
bbpPairings against Gacrux - under a mode named `:reach`, and the claim it
makes is deliberately the weaker half of the old one. `:conformance` asked
whether 5.2.5 decided the board **and** this engine's answer was the
article's. `:reach` asks only the first: that neither player held a colour
preference, so 5.2.5 is what the board turned on. No conformance claim is
available on a board this engine formed neither answer to, and the report
prints the weaker word for it - those boards are "within 5.2.5's reach",
not a confirmed anything. That is the only surviving classification of a
colour difference anywhere in the harnesses.

**`:reach` was kept for the wrong reason for ten days, and that is worth
recording.** The justification in the harness used to be that the two
references renumber differently from each other, so a field where somebody
who HAS played sits out could still split them - which would have made
`:reach` a real distinction. That claim was false when it was written. It
came from `docs/dispute-initial-colour.md`, where it was the pre-probe
hypothesis stated as a finding, and `tools/rip_probe.exs` refuted it in
that same document's own evidence section: when the absent player has
already played, all three engines answer alike and nobody renumbers.
Re-confirmed 2026-08-27 against the local binary. `:reach` survives on the
correct and much smaller ground above - that a reference-against-reference
board admits no claim about this engine's conformance - and not on a
difference between the references that does not exist.

**What that costs and what it buys.** It costs the historical figures on
this page their meaning: any "zero unexplained" computed with the bucket in
place excluded boards now known to be defects, and is annotated as such
wherever it appears above. It buys a colour number with nothing subtracted
from it. That number has not been measured yet - see "The re-measurement is
PENDING" above.

The axes without byes were the control that made the rest meaningful:
plain, forfeit, `XXP` and Baku runs report **zero** colour differences, so
the divergence was never a general disagreement about Article 5. That
measurement holds, and the control's job is over: if the fix is right, the
bye-heavy axes join the control at zero and it stops separating anything.
Whether they do is exactly what the pending re-run answers.

The adjudication tables in [engineering-log.md](engineering-log.md) were
produced with the blank float history and have **not** been re-run. They
are not wrong about *whether* the engines differed - that comes from the
harness, not the scorer - but their "first differing rung" column is only
trustworthy where the winning rung outranks C14.

## Legality, independent of any reference

When no legal pairing can exist at all - a genuine structural deadlock,
not a search failure - the engine raises
`Ainalrami.Pairing.NoValidPairingError` rather than emitting a
best-effort illegal result, matching bbpPairings' own
`NoValidPairingException`. bbpPairings has independently confirmed these
cases really are unpairable, via its own exit code 1 on byte-identical
input.

## Extension lines

`XXP` and `XXA` are validated by the same oracle as everything else,
because bbpPairings implements both and reads the same file: **1,789,554
rounds and 8,536,147 individual pairs carrying at least one extension
line, 100.00% agreement, zero illegal rounds**, across eleven axes.

Every previously-measured axis was byte-identical after that change - the
same numerators and denominators, not merely the same percentages.

What the old line-dropping behaviour actually cost, before they were
implemented: at 20% forbidden-pair density it seated a forbidden pair in
**27.72%** of rounds, and Baku acceleration paired **66.12%** of rounds on
the wrong scores.

## Not covered

Stated so the claim's boundary is explicit:

- ~~**`260` and `250`**~~ - **implemented 2026-08-18.** These are
  bbpPairings' round-limited siblings of `XXP` and `XXA`, and they were
  listed here as "deliberately absent rather than stubbed". That was wrong
  in a specific way: absent meant the lines fell through to the header
  parser and were *silently discarded*, so a file saying "1 and 3 must
  never meet in rounds 1-3" produced a complete, legal-looking round that
  seated 1 against 3. Verified happening before the fix. Both are now read,
  both raise on a malformed line, and every case was checked against the
  real binary - including a `260` whose range excludes the round being
  paired, which must do nothing.
- **bbpPairings' own Baku flag**, which sizes Group A as `ceil(n/2)` where
  FIDE C.04.7 uses `2 * ceil(n/4)`. Reached only through its own flag,
  never through `XXA`, so it cannot make the two engines disagree here -
  both read identical `XXA` lines from an identical file.
- ~~**Unrated players**~~ - **covered 2026-08-24.** The rating run varies
  the shape of the field's ratings across five modes, two of which put some
  or all players at 0. 285 million pairings, zero disagreements.
- **Team tournaments and late entrants**, and files where `rounds_count`
  disagrees with `XXR`. The harness generates none of these; see
  [TODO.md](../TODO.md). Late entrants are the one of the three that a
  normal club event actually produces - and since 2026-08-27 they are a
  priority rather than a footnote, because the late entrant is exactly the
  construct the SPP's ruling turns on. C.04.2:2.4 is a rule *about* late
  entries, the numbering it settles only moves when somebody is registered
  and not yet paired, and no corpus on this page has ever generated one.
  The engine's new numbering is pinned by unit tests and by a small
  bye-heavy probe against the real binary; it is not pinned by any axis
  that produces the construct the rule is written for.
- ~~**Non-default point configuration**~~ - **covered, and it was worth
  it.** `PAIRING_FUZZ_POINT_SYSTEM` now generates `BB*` lines across seven
  named systems (half-point bye, doubled, football 3-1-0, paid loss, paid
  forfeit, draw-heavy). It found two real engine bugs that every
  standard-scored corpus was structurally incapable of seeing:

  * a **half-point loss** scored 87.46% on its first run, because
    `float_direction/4` treated "scored anything at all" as having
    downfloated - correct only when a loss is worth zero;
  * the final-round **topscorer threshold** read `pointsForWin` where
    `dutch.cpp:55` reads `max(pointsForWin, pointsForDraw)`, which no axis
    could see while every system had the win worth at least the draw.

  The second was measured rather than argued: a `draw_heavy` axis run in
  two arms over identical seeds gave **3,775,174 rounds at 100.00%** with
  the fix and **8,181 wrong rounds** without it, with zero illegal rounds
  either way. See "The same expression was wrong a second time" above.
- **Fields above 500 players and round counts above 20.** Both are
  boundaries of the harness rather than of the engine, but nothing has
  measured past them. This is now the most reachable gap on the list: the
  matcher rebuild took 60-120 players from 0.36 to ~12 tournaments/s, so
  the axis that was once unaffordable is affordable.
- ~~**Three-way agreement at scale**~~ - **raised 2026-08-27, from 3,352
  rounds to 649,207**, and given a colour instrument it never had. See
  "The three-way run" below. It is no longer the weakest number here.

## Performance

Correctness has never been the constraint here; field size is. One round
of a real 209-player tournament, cut down to size:

| players | one round | before 2026-08-18 |
|---|---|---|
| 40 | 0.15 s | 0.19 s |
| 80 | 1.2 s | 2.1 s |
| 120 | 4.4 s | 8.3 s |
| 160 | 13 s | 24 s |
| 209 | **38 s** | 90 s |

**2.4× overall, and the growth rate barely moved** - still somewhere
between n³ and n⁴. That is worth saying plainly, because the work was
undertaken to change the exponent and mostly did not. What it bought was
a large constant factor, three times over.

### What was done

**The delta scans are maintained rather than recomputed.** Finding the
least-resistance edge from the tree to a free vertex, and between two
outer blossoms, were 84% of a solve between them and rescanned every
relevant vertex pair on every step. They are now two per-vertex caches,
updated when the tree grows, when a blossom forms and when one expands.
`Ainalrami.WeightedMatching`'s "delta-scan caches" section sets out what
makes that sound: **within a stage the outer set only ever grows**, so a
cached entry can never go stale by pointing at something that stopped
being outer.

**Edge weights are divided by their greatest common divisor first.** This
turned out to matter more than the caches. `Ainalrami.Pairing` packs
C1-C21 into a single integer by giving each criterion its own band, and on
a 209-player field that produces weights of **103 digits** - so every
`dual + dual − weight`, the innermost operation in the algorithm, was
arbitrary-precision arithmetic. In one real solve, 21,221 edges carried
just **five distinct weights sharing a ninety-digit common factor**.
Dividing it out leaves values that fit in 64 bits. Exact rather than
approximate: every matching's total scales by 1/g, so the argmax cannot
move, and `solve/2` returns pairs rather than any weight.

**Two hoisting passes** removed repeated work from the scans while they
still existed: a recursive blossom walk running once per *pair* of
blossoms instead of once per blossom, and a flat `{u, v}` weight map
replaced by adjacency, so the innermost lookup stopped allocating a tuple.

### Why it is not more

Profiling the finished version on a real solve: the scans that were the
whole problem are down to 10% of the time, and cache *maintenance* is the
other 90% - 46% rebuilding at stage boundaries, 44% refreshing after
structural changes. The work moved rather than vanished. Getting past that
needs the maintenance itself to be incremental across stages, which the
labels being recomputed wholesale by `init_labels/1` currently prevents.

### How it is verified

This is the most delicate module in the engine, and the one place a subtle
error yields a wrong pairing rather than an obvious failure. Three
independent checks:

- **`tools/matching_baseline.exs`** replays `solve/2` over 460 random
  graphs - 400 small, where blossoms are easy to hit by chance, and 60 at
  40-90 vertices - across three densities and both weight scales. Every
  one is checked for **total weight** and matched count, not byte
  identity: 460/460 optimal.
- **Byte identity is deliberately not required.** 86% of delta steps have
  a *tied* minimum, so a cache that finds any minimum takes a different
  path through the search almost every step; 38 of the 460 land on a
  different matching of the same weight, which is correct when the optimum
  is not unique.
- **That this is safe was measured before the caches were written.**
  Inverting the tie-break of the old linear scans left the engine agreeing
  with bbpPairings on 1358/1358 rounds - so the pairing is determined by
  the weights, not by the order equal-slack edges happen to be visited in.
- **The corpus**, which is the check that actually matters. With the
  caches in place, **39,371 rounds and 435,294 individual pairings at
  100.00%**, zero illegal and zero refusals:

  | axis | rounds | individual pairs |
  |---|---|---|
  | byes + forfeits + `XXP` + Baku, 2,000 tournaments | 13,252 | 132,065 |
  | 15% byes, **10** rounds, 2,000 tournaments | 18,332 | 186,645 |
  | **60-120 players** | 1,050 | 48,132 |
  | plain / byes / combined / 8-round, 250 each | 6,737 | 68,452 |

  The large-field row is the one to look at. It is where a matcher change
  would show first, and where the differential corpus is thinnest.

### Against bbpPairings and Gacrux, on the same files

The reference is not instant either, which is worth knowing before
treating any target as obvious. Same tournaments, same machine -
bbpPairings' own generator produced every file, so no side is favoured.

**Cold process, start to finish**, which is how an arbiter's tool
actually invokes any of the three:

| players | bbpPairings (C++) | Gacrux (Python) | Ainalrami |
|---|---|---|---|
| 10 (start-up floor) | 0.18 s | 0.68 s | 0.63 s |
| 209 | **0.72 s** | 0.88 s | 0.86 s |
| 400 | 3.05 s | 1.22 s | **1.35 s** |
| 1,000 | 50.1 s | **5.14 s** | 7.12 s |

Each engine pays a fixed start-up it cannot avoid - a C++ binary 0.18 s,
CPython plus networkx 0.68 s, the BEAM 0.63 s. Subtracting each one's own
floor leaves the **pairing work**:

| players | bbpPairings | Gacrux | Ainalrami |
|---|---|---|---|
| 209 | 0.54 s | **0.20 s** | 0.23 s |
| 400 | 2.87 s | **0.54 s** | 0.72 s |
| 1,000 | 49.9 s | **4.46 s** | 6.45 s |

On every one of these rounds all three engines return the **identical
boards** - 105 of 105, 200 of 200, 500 of 500, colours included.

**Read honestly: this engine is faster than the C++ reference and a
little slower than the Python one.** Against bbpPairings the pairing work
is 2.3×, 4× and 7.7× quicker, though a cold 209-player invocation is
still within a rounding error of it, on start-up alone. Against Gacrux it
is 1.15×, 1.3× and 1.45× slower -- close enough at 209 players that the
difference is smaller than the run-to-run spread, and never more than
half again as slow.

That ordering is not about the languages, and the morning's numbers show
why: 209 players took 9.5 s here yesterday evening and 85 s at 1,000
players this morning, which is 24× and 11× behind Gacrux. What changed
was how much of the whole-field matcher each bracket has to run.
bbpPairings runs all of it, every bracket, eight refinement stages deep -
~n³ a round, and that is the 50 s. Gacrux runs almost none of it: its
`BI` path walks Article 3's transposition procedure directly and accepts
the first candidate that is legal and meets a counting bound on the
colour criteria, falling back to a bracket-sized networkx matching only
where that fails. This engine now solves a bracket on **its own graph**
whenever that is provably the whole-field answer (`Pairing.pair_bracket/6`:
every window member a non-candidate for the bye, a perfect internal
matching, and the rest of the field pairable without it, certified by a
sparse cardinality oracle), with a one-vertex stand-in for the next score
group on odd brackets, and on the whole field otherwise. Same destination
as Gacrux's, reached from the matcher side rather than the procedure
side - so the eight stages, and the 100.00% they carry, are unchanged.

**Correctness is not what degrades.** Every step was held to 100.00% on
seven corpus axes - 4-10, 4-40, 60-120 and 150-250 players, with byes,
forfeits, forbidden pairs, acceleration and round counts of 7, 8 and 13 -
and both differential nets before it was committed, and the large-field
axes are where the local graph does its work. The 5-million-tournament
run on the Photon box was restarted on the final engine and is the judge
of the one condition not certified term by term: that an odd bracket's
float choice does not depend on which member of a dense next group it
lands on (`@local_min_next_group`).

### What it means in practice

Club and national events - up to ~150 players - pair in well under a
second including start-up. A 200-player open is about a second, a
400-player open two, and a Moscow-Open-sized event of 1,000 players
seven - against the C++ reference's fifty. Inside a long-lived process
(the sibling OpenPairings app, or any server) the 0.63 s BEAM start-up is
paid once rather than per round, which is most of the small-field cost.
