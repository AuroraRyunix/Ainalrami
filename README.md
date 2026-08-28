# Ainalrami

A FIDE Dutch-system Swiss pairing engine, written in Elixir. No JVM, no
external binary, no runtime dependencies.

> **Ainalrami** - ν¹ Sagittarii A, from the Arabic *Ain al Rami*, "the eye
> of the archer". A pairing engine's whole value is aiming exactly where
> the regulations point, rather than somewhere reasonable nearby.

Ainalrami implements **C.04.3, the FIDE (Dutch) System, effective
1 February 2026** - the current rules, not the 2022 edition most engines
still ship. It reads and writes TRF16, mirrors JaVaFo's command-line
shape, and is verified against two independent reference implementations.

**Status: beta.** The engine is functionally complete and reproduces
bbpPairings 6.0.0 exactly across 2.5 billion compared pairings, in six
separate corpora that between them vary every input the harness can vary.
Article 4's candidate ordering is verified against the regulations
directly. One point of Article 5 was settled *against this engine* on
2026-08-27 by the FIDE Systems of Pairings and Programs Commission, and
the engine now conforms. Both are documented rather than hidden - see
[What is not settled](#what-is-not-settled) and
[A dispute this engine lost](#a-dispute-this-engine-lost).

---

## Where it stands

Measured against **bbpPairings 6.0.0**, which implements the same 2026
rules.

**Cumulative to 2026-08-24: 2,536,328,265 individual pairings compared,
across 217,470,056 rounds, in 6 corpora over 99 axis-runs - 82 of them
distinct. Two disagreements, both a defect in bbpPairings that Gacrux
resolves this engine's way. Zero illegal rounds.**

| run | axes | rounds | individual pairings | disagreements |
|---|---|---|---|---|
| Round sweep, R=1..20 (08-23) | 20 | 59,966,505 | **684,901,202** | 0 |
| Cross-axis (08-23) | 25 | 35,436,044 | **474,685,328** | 0 |
| Rating shape / withdrawals / tiny fields (08-24) | 16 | 25,209,754 | **285,118,044** | 0 |
| Randomised corpus (08-23) | 4 | 7,898,024 | **116,251,032** | 0 |
| Six-million run (08-20) | 17 | 44,486,465 | 488,033,862 | 2 |
| Same axes, disjoint seeds (08-21) | 17 | 44,473,264 | 487,338,797 | 0 |
| **total** | **99** | **217,470,056** | **2,536,328,265** | **2** |

The four runs above the 08-20 corpus exist because size alone proves
little, and the last row is a replication rather than new coverage: the
same seventeen axes on a different build of this engine, which is why 99
axis-runs are only 82 distinct ones. It is evidence about the
optimisation, not about the rules. Every corpus
before 2026-08-17 held the round count at 9, and that one fixed parameter
hid a real defect that 2.55M tournaments could not produce and 2,000 at
eight rounds found immediately. The round sweep therefore varies rounds
from 1 to 20; the cross-axis run then crosses every parameter that sweep
held still - forfeits, forbidden pairs, acceleration, initial colour,
numeric extensions and field size - against short, classical and deep round
counts, including axes with all of them firing at once.

The randomised and rating runs go after the INPUT rather than the run
parameters. The randomised corpus draws rounds, colour, acceleration and
extension format per tournament instead of per axis, so it explores
combinations nobody wrote down. The rating run attacks the oldest assumption of all: every
corpus before it drew ratings uniformly from 1000..2800, making every
player rated and ties incidental - the inverse of real chess, where a
junior event is entirely unrated and a club field sits on a handful of
rounded numbers. Equal ratings put the initial ranking on a different
tiebreak path, and that ranking is the foundation of every bracket in every
round. It also covers withdrawals mid-event and fields as small as two
players, neither of which any corpus had ever generated.

The 2026-08-20 run's own table follows, seventeen axes:

| axis | tournaments | exact rounds | individual pairs | illegal |
|---|---|---|---|---|
| 300-500 players | 3,000 | **100.00%** | **100.00%** | 0 |
| 150-250 players | 40,000 | **100.00%** | **100.00%** | 0 |
| 60-120 players | 300,000 | **100.00%** | **100.00%** | 0 |
| plain | 800,000 | **100.00%** | **100.00%** | 0 |
| arbiter byes (15%) | 2,600,000 | **100.00%** (1 dispute) | **100.00%** | 0 |
| forfeits (10%) | 300,000 | **100.00%** | **100.00%** | 0 |
| forbidden pairs (`XXP`, 20%) | 300,000 | **100.00%** | **100.00%** | 0 |
| acceleration (`XXA`, Baku + random) | 300,000 | **100.00%** (1 dispute) | **100.00%** | 0 |
| all four combined | 510,000 | **100.00%** | **100.00%** | 0 |
| round counts 8, 10, 13 | 650,000 | **100.00%** | **100.00%** | 0 |
| Black drawn first | 300,000 | **100.00%** | **100.00%** | 0 |

FIDE's FE1 endorsement allows one difference per 500 tournaments. This is
one per 3 million - nearly four orders of magnitude inside the bar.

**What 2.5 billion pairings do not buy.** Almost all of them are measured
against ONE oracle, and agreement with a single reference cannot detect a
rule both engines read the same wrong way. The check on that is the
three-way harness, where Gacrux gives a genuinely independent third
opinion - and it has run 649,207 rounds, not 217 million, because it
is a Python implementation roughly 35x the cost per round. Those 649,207
bound the two references' mutual disagreement far more tightly than the
3,352 this sentence used to quote, which is
the real precision of the ruler every other number here is measured with.
Raising that bound is worth more now than another billion two-way
pairings.

The same seventeen axes were re-run on **2026-08-21** with disjoint seeds,
against the newer matching-layer optimisation (`finalize_pair` as a pure
edge removal): **5,993,000 tournaments, 487,338,797 individual pairings,
zero disagreements, zero illegal rounds.** Two independent corpora of
~488M pairings each, then - and the optimisation is correctness-neutral at
that scale, which is the whole reason for re-running it.

Zero disagreements the second time does not retire the two below: both
were bbpPairings defects on particular seeds, and fresh seeds simply did
not land on that configuration again. bbpPairings is unchanged and still
wrong there, so all three known disputes stay pinned as regression tests.

Both disagreements are **not defects here**: bbpPairings awards a second
pairing-allocated bye to a player who already has one, which absolute
criterion C2 forbids. Gacrux - a third, independent implementation -
pairs both the way this engine does. In one of them the round has exactly
one legal shape, reached by pure elimination, so there is no scoring
argument to be had. Written up in
[docs/dispute-seed735265.md](docs/dispute-seed735265.md) and
[test/fixtures/fe1_disputes/](test/fixtures/fe1_disputes/), with a
submittable report in
[docs/bbppairings-c2-bug-report.md](docs/bbppairings-c2-bug-report.md).

Against **JaVaFo** the engine measures 96.26%, and it *should not* be
100%: JaVaFo implements the superseded 2022 rules and differs from both
2026 references by roughly the same margin. That gap is the control. An
engine agreeing with all three at once would mean the harness was
measuring nothing.

Full methodology, per-axis detail and the reasoning behind each number:
[docs/validation.md](docs/validation.md).

**Speed**, re-measured 2026-08-21 on freshly generated fields, all three
engines on the same input, best of three, cold process - and all three
returning **identical boards** at every size. Discounting each engine's
own start-up floor (6 ms for the C++ reference, 252 ms for the Python
one, 604 ms for the BEAM), the pairing work is:

| players | bbpPairings | Ainalrami | Gacrux |
|---|---|---|---|
| 209 | 411 ms | **356 ms** | 335 ms |
| 400 | 2,088 ms | **963 ms** | 1,094 ms |
| 1,000 | 43,754 ms | **7,695 ms** | 7,669 ms |

**Those sizes are 209, 400 and 1,000 - one odd and two even, and the
parity matters.** An odd field runs a whole-field bootstrap matching that
an even one skips entirely, and on 2026-08-27 it was measured at **46.2% of
a 1,001-player round**: 1,000 players takes 6.0 s and 1,001 takes 13.3 s.
So the two large numbers above are the cheap half of the picture, and half
of any real tournament is an odd field. See
[docs/engineering-log.md](docs/engineering-log.md) under 2026-08-27.

So **1.15x to 5.7x quicker than the C++ reference**, and **level with the
Python one** - quicker at 400, within 0.3% at 1,000. At 209 players 63% of
the BEAM's wall clock is VM start-up, which is why it trails end-to-end
there and why that does not apply inside a host application already
running. A
bracket is solved on its own graph when that is provably the whole-field
answer, and on the whole field otherwise; the full table, and how it got
here from 90 s and 498 s, is in
[docs/validation.md](docs/validation.md) and
[docs/engineering-log.md](docs/engineering-log.md).

## Install

```bash
git clone https://github.com/AuroraRyunix/Ainalrami
```

Then `mix deps.get && mix escript.build`, which produces a standalone
`ainalrami` executable. Requires Elixir `~> 1.17`.

As a dependency:

```elixir
{:ainalrami, github: "AuroraRyunix/Ainalrami"}
```

## Command-line interface

Deliberately mirrors JaVaFo's invocation shape, so a caller that already
drives JaVaFo only has to swap the executable name:

```bash
ainalrami input.trf -p output.trf
```

| invocation | mode |
|---|---|
| `ainalrami input.trf -p output.trf` | pair the next round |
| `ainalrami input.trf -p` | same, printed to stdout |
| `ainalrami -g output.trf` | Random Tournament Generator |
| `ainalrami input.trf -c` | Pairings Checker: replay and diff every round |

`-g` and `-c` mirror JaVaFo's own RTG/FPC modes, used for FIDE's FE1
endorsement auto-test.

**`-g`** generates a random tournament and plays it forward, pairing every
round with this engine. Every run is reproducible from its seed, and the
seed is written into the generated file's tournament name, so a file
always reproduces itself:

```bash
ainalrami -g out.trf --seed=42 --players=30 --rounds=9 --forfeit-pct=10 --bye-pct=5 --forbidden-pct=10 --acceleration=baku --initial-colour=b
```

`--initial-colour` is Article 5.1's drawing of lots, and it is written into
the file as `152`. It defaults to White - which is what the generator
always used, implicitly, before the option existed.

`--rounds` is capped at `players - 1`, past which a Swiss has no legal
opponents left. It can stop earlier still if some round turns out to have
no legal pairing at all - a real, if rare, possibility for a small field
deep into a Swiss (`Ainalrami.Pairing.NoValidPairingError`).

**`-c`** replays a completed tournament round by round, re-pairing each
from the state that preceded it and diffing against what the file records.
Exits 0 when every round matches, 1 otherwise. Colour differences are
reported but never counted as errors: Article 5.1 leaves the first colour
to a drawing of lots, so this engine's convention is its own.

> **A checker is not an independent verifier of the rules.** It re-runs the
> same engine and calls that the correct answer - exactly as bbpPairings'
> own `-c` does. A reported difference means "this engine would have paired
> it differently", not "the file is illegal".

The two modes are each other's test: `-g` output fed to `-c` checks clean
by construction.

### Verbose by default

Unlike JaVaFo, which prints almost nothing beyond the result, Ainalrami
traces each step it takes. Pass `-q`/`--quiet` to suppress it. The intent
is that *"why did board 3 downfloat instead of board 5"* should be
answerable by reading the run's own output.

## TRF extension lines

Beyond TRF16 proper, Ainalrami reads and writes three of JaVaFo's `XX`
extension codes:

| line | meaning |
|---|---|
| `XXR n` | number of rounds - JaVaFo's spelling of TRF16's `142` |
| `XXP a b [c …]` | a mutually-forbidden **group**: no two of these players may ever meet |
| `XXA` | per-player acceleration ("virtual points"), round by round |
| `260` | forbidden pairs, limited to a range of rounds |
| `250` | acceleration for a range of players over a range of rounds |

`XXR` and `142` are the same field: a file may carry both, but they must
**agree**, and two different counts are refused rather than silently
resolved. Every implementation resolves them differently, and the loser of
that choice is a final round paired under the wrong rules.

`260` and `250` are bbpPairings' fixed-column, round-limited siblings of
`XXP` and `XXA`. They were unimplemented until 2026-08-18, which meant
*silently discarded* - a file saying two players must never meet produced
a complete, legal-looking round that seated them together.

`XXP` carries exactly the standing of the no-rematch rule, which is how
bbpPairings expresses it too - one `forbiddenPairs` set, with no-rematch
inserted into it. One line names a group, not a pair, so `XXP 4 9 17`
forbids all three of 4-9, 4-17 and 9-17.

`XXA` is **fixed-column** and the columns are load-bearing: `XXA` at
column 1, starting rank right-aligned in columns 5-8, each round's `pp.p`
right-aligned at column `10 + 5*(r-1)`. A line one column off is rejected
outright by real bbpPairings (`Invalid line`, exit 3), and free-form `XXA`
crashes real JaVaFo with a bare `NullPointerException`.

A malformed `XXP` or `XXA` raises rather than being skipped. `XXR` is the
exception and can afford to be: a missing round count has a fallback,
while a dropped exclusion produces a complete, perfectly legal-*looking*
pairing that seats two players an arbiter said must never meet, with
nothing downstream able to detect it.

Both are validated by the same oracle as everything else: **1,789,554
rounds carrying at least one extension line, 100.00% agreement, zero
illegal rounds** across eleven axes.

## What is not settled

Documented rather than hidden, because an engine claiming 100% owes an
account of where it could still be wrong:

- **Article 4 for a bracket in the middle of a round.** The regulations
  pair a bracket by generating candidates in a defined sequence and taking
  the best, with "generated earlier" as the final tie-break. This engine
  solves a maximum-weight matching instead, reaching the same optimum
  without enumerating.

  Most of this is now settled. 4.2's transposition order is proven
  identical to the engine's tie-break key; 4.3's exchange order is tested
  on a position where exchanges are the only route to a legal pairing and
  over forty random brackets enumerated in full Article 4 order; and 3.7's
  two-stage **heterogeneous** case - MDP-Pairing outside, remainder inside
  - is tested too. The engine returns the earliest-generated best candidate
  every time.

  Each of those holds the bracket fixed by making it the **last** one, so
  no candidate reaches an edge into a lower group and the scores stay
  comparable. A bracket that both inherits moved-down players *and* floats
  players onward is therefore still checked only through the corpus. That
  is a limit of the method, not a known divergence: comparing candidates
  that float different players needs an ordering the rules do not define.

This has never produced a measured disagreement. "Not observed" is not
"cannot happen", and it is the only place left in the pairing itself where
one could come from.

## A dispute this engine lost

Promoted out of "what is not settled" on 2026-08-27, because it is settled
now - against us.

**Article 5.2.5 - which number the parity is taken on.** This engine took
it on the TPN exactly as the file gives it. Both references take it on a
numbering that skips players who have never been paired. On 2026-08-27 the
FIDE Systems of Pairings and Programs Commission answered the question:
the references are right and Ainalrami was wrong. The engine has been
changed to match.

The crux is worth stating plainly, because both sides argued from the
**same sentence**. C.04.2:2.4 says a late entry is *"given an appropriate
TPN and paired only when they actually arrive."* This engine read that as:
the TPN exists before the arrival, and it is the pairing that waits. The
SPP reads the identical clause as *"players who have yet to arrive don't
have a TPN."* We read it the wrong way round.

The superseded argument, kept because it is why the engine behaved this
way for months: C.04.2 Article 2 fixes a TPN for the tournament, moving it
only for a ranking-data correction (barred after round four) or the
closing of the participant list, and nothing in either article renumbers
around players sitting a round out. That reading was rejected.

**There is a second retraction, and it is the worse one.** The other named
reason for not complying was a claim, published in
docs/dispute-initial-colour.md, that the two references renumber
differently *from each other* - "so agreeing with the references is not
even a well-defined target". They do not differ; they agree, as the next
paragraph says. That claim was false when written: a pre-probe hypothesis
printed as a finding, refuted by this project's own `tools/rip_probe.exs`
in the same document's own evidence section, and re-confirmed against the
local binary on 2026-08-27. It was load-bearing in three places - the
decision not to fix, this README, and a test harness's classifier, which it
weakened.

What was measured stands. The two references agree with each other -
Gacrux does not break this tie the way it breaks the other one - and they
skip players who have never participated, not players who have played and
are merely absent this round. On a full field all three engines always
agreed; they diverged only once somebody had been registered without ever
being paired. Colour is allocated *after* the pairing, so none of it ever
moved a player to a different board: every axis reports 100.00% pairing
agreement and zero illegal rounds.

Measured over 200 seven-round tournaments, **before the fix**. These are
boards where this engine was wrong, not boards where it was different:

| axis | boards differing (old engine) |
|---|---|
| plain, forfeits, `XXP`, Baku | **0** |
| 15% arbiter byes, `152 W` | 670 |
| 15% arbiter byes, `152 B` | 1175 |

The corpus has **not** been re-run on the corrected engine. Both bye rows
are expected to become 0; that is an expectation, not a measurement, and
nothing in this repo should be read as claiming otherwise until the run
happens. The full account, with the handbook text, the ruling and a
reproducible probe, is in
[docs/dispute-initial-colour.md](docs/dispute-initial-colour.md).

## Documentation

| document | what it is |
|---|---|
| [docs/architecture.md](docs/architecture.md) | how the engine is put together, module by module |
| [docs/validation.md](docs/validation.md) | the measurement record and how it was produced |
| [docs/conformance-c0403-2026.md](docs/conformance-c0403-2026.md) | article-by-article verification against the 2026 rules text |
| [docs/fide-criteria.md](docs/fide-criteria.md) | the maintained rules-to-code map (C1-C21) |
| [docs/dispute-seed735265.md](docs/dispute-seed735265.md) | the one disagreement, argued from the regulations |
| [docs/bbppairings-c2-bug-report.md](docs/bbppairings-c2-bug-report.md) | that dispute as a submittable upstream report |
| [docs/dispute-initial-colour.md](docs/dispute-initial-colour.md) | the Article 5.2.5 dispute this engine lost, and the SPP ruling that closed it |
| [docs/engineering-log.md](docs/engineering-log.md) | the dated build history, including what measured worse |
| [TODO.md](TODO.md) | open work |

## Development

```bash
mix test
```

133 tests. Comparison tests against JaVaFo and Gacrux are tagged and
excluded by default - neither is vendored, and both must be supplied
locally. See [docs/validation.md](docs/validation.md) for how to point the
harness at them and how to run the large fuzz axes.

## Relationship to OpenPairings

Ainalrami is the sibling project to
[OpenPairings](https://github.com/AuroraRyunix/openpairings), an
Elixir/Phoenix tournament manager, where it is available as an **optional
second pairing engine**. JaVaFo stays the default there, particularly for
FIDE-rated tournaments, whose endorsement story rests on the same "uses
JaVaFo, thru JaVaFo" pattern Vega, Swiss Manager and TournamentService
already use.

Ainalrami is for everything else: tournaments that need no such precedent,
experimentation with pairing variants JaVaFo doesn't expose, and an
independent data point for cross-checking pairing correctness.

## License

[Apache License 2.0](LICENSE) - deliberately the same licence as
[bbpPairings](https://github.com/BieremaBoyzProgramming/bbpPairings),
because parts of this engine are derived from it. `Ainalrami.Pairing`'s
bracket cascade is a stage-for-stage port of `dutch.cpp`, and
`Ainalrami.WeightedMatching`'s control flow was read directly from
bbpPairings' matching sources while writing the Elixir equivalent.

No bbpPairings code is reproduced here - it is C++ and this is Elixir -
but the algorithm and structure are theirs, originating file and line
numbers are cited inline throughout, and matching their licence is the
cleanest way to honour that rather than leaving it ambiguous.
[NOTICE](NOTICE) spells out exactly which files are derived and what
changed.

JaVaFo is © Roberto Ricca, is not open source, and is not bundled here.
