# Ainalrami

A FIDE Dutch-system Swiss pairing engine, written in Elixir. No JVM, no
external binary, no runtime dependencies.

> **Ainalrami** — ν¹ Sagittarii A, from the Arabic *Ain al Rami*, "the eye
> of the archer". A pairing engine's whole value is aiming exactly where
> the regulations point, rather than somewhere reasonable nearby.

Ainalrami implements **C.04.3, the FIDE (Dutch) System, effective
1 February 2026** — the current rules, not the 2022 edition most engines
still ship. It reads and writes TRF16, mirrors JaVaFo's command-line
shape, and is verified against two independent reference implementations.

**Status: beta.** The engine is functionally complete and reproduces
bbpPairings 6.0.0 exactly across 4.3 million generated tournaments. One
conformance question remains open (Article 4.3) and one is settled against
both reference engines (Article 5.2.5); both are documented rather than
hidden — see [What is not settled](#what-is-not-settled).

---

## Where it stands

Measured against **bbpPairings 6.0.0**, which implements the same 2026
rules — **4.3 million tournaments, ~195 million individual pairings, one
disagreement in the entire corpus**:

| axis | tournaments | exact rounds | individual pairs | illegal |
|---|---|---|---|---|
| plain | 620,000 | **100.00%** | **100.00%** | 0 |
| arbiter byes (15%) | 1,450,000 | **100.00%** (1 dispute) | **100.00%** | 0 |
| forfeits (10%) | 120,000 | **100.00%** | **100.00%** | 0 |
| forbidden pairs (`XXP`, 20%) | 120,000 | **100.00%** | **100.00%** | 0 |
| Baku acceleration (`XXA`) | 120,000 | **100.00%** | **100.00%** | 0 |
| all four combined | 120,000 | **100.00%** | **100.00%** | 0 |
| even round counts (6, 8, 10) | 850,000 | **100.00%** | **100.00%** | 0 |
| odd-round controls (7, 9) | 350,000 | **100.00%** | **100.00%** | 0 |
| 60–120 players | 600 | **100.00%** | **100.00%** | 0 |

FIDE's FE1 endorsement allows one difference per 500 tournaments. This is
one per 4.3 million — four orders of magnitude inside the bar.

The single disagreement is `seed735265-r7-p10`, and it is **not a defect
here**: bbpPairings awards a second pairing-allocated bye to a player who
already has one, which absolute criterion C2 forbids. Gacrux — a third,
independent implementation — pairs it the way this engine does. Written up
in [docs/dispute-seed735265.md](docs/dispute-seed735265.md), with a
submittable report in
[docs/bbppairings-c2-bug-report.md](docs/bbppairings-c2-bug-report.md).

Against **JaVaFo** the engine measures 96.26%, and it *should not* be
100%: JaVaFo implements the superseded 2022 rules and differs from both
2026 references by roughly the same margin. That gap is the control. An
engine agreeing with all three at once would mean the harness was
measuring nothing.

Full methodology, per-axis detail and the reasoning behind each number:
[docs/validation.md](docs/validation.md).

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
ainalrami -g out.trf --seed=42 --players=30 --rounds=9 --forfeit-pct=10 --bye-pct=5 --forbidden-pct=10 --acceleration=baku
```

`--rounds` is capped at `players - 1`, past which a Swiss has no legal
opponents left. It can stop earlier still if some round turns out to have
no legal pairing at all — a real, if rare, possibility for a small field
deep into a Swiss (`Ainalrami.Pairing.NoValidPairingError`).

**`-c`** replays a completed tournament round by round, re-pairing each
from the state that preceded it and diffing against what the file records.
Exits 0 when every round matches, 1 otherwise. Colour differences are
reported but never counted as errors: Article 5.1 leaves the first colour
to a drawing of lots, so this engine's convention is its own.

> **A checker is not an independent verifier of the rules.** It re-runs the
> same engine and calls that the correct answer — exactly as bbpPairings'
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
| `XXR n` | number of rounds — JaVaFo's spelling of TRF16's `142` |
| `XXP a b [c …]` | a mutually-forbidden **group**: no two of these players may ever meet |
| `XXA` | per-player acceleration ("virtual points"), round by round |

`XXP` carries exactly the standing of the no-rematch rule, which is how
bbpPairings expresses it too — one `forbiddenPairs` set, with no-rematch
inserted into it. One line names a group, not a pair, so `XXP 4 9 17`
forbids all three of 4–9, 4–17 and 9–17.

`XXA` is **fixed-column** and the columns are load-bearing: `XXA` at
column 1, starting rank right-aligned in columns 5–8, each round's `pp.p`
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

- **Article 4.3 in a heterogeneous bracket.** The regulations pair a
  bracket by generating candidates in a defined sequence and taking the
  best, with "generated earlier" as the final tie-break. This engine solves
  a maximum-weight matching instead, reaching the same optimum without
  enumerating.

  4.2's transposition order is proven identical to the engine's tie-break
  key. **4.3's exchange order is now tested too** — on a position built so
  that exchanges are the only route to a legal pairing, and over forty
  random single-score brackets enumerated in full Article 4 order. The
  engine returns the earliest-generated best candidate every time.

  What remains uncovered is a **heterogeneous** bracket, where moved-down
  players are present and 3.7.2 alters the MDP-Pairing. Candidates there
  float different players, which changes the bracket structure and makes
  their scores incommensurable, so the differential test cannot simply be
  pointed at them. `Ainalrami.Sequence.mdp_sets/2` is the oracle for
  closing it.

This has never produced a measured disagreement. "Not observed" is not
"cannot happen", and it is the only place left in the pairing itself where
one could come from.

### A second dispute, settled from the handbook

**Article 5.2.5 — which number the parity is taken on.** The article gives
the initial colour to the higher-ranked player when their **TPN** is odd,
and C.04.2 Article 2 fixes a TPN for the tournament: it moves only for a
ranking-data correction (barred after round four) or the closing of the
participant list. Nothing renumbers it around players sitting a round out.

Both references renumber anyway — bbpPairings around anyone not paired
this round, Gacrux around players who have never played. On a full field
all three agree; they diverge the moment someone takes a bye. This engine
follows the article, and is **not** changing to match: the two references
do not even agree with each other, so there is no single behaviour to
match.

Measured over 200 seven-round tournaments — note the axes without byes,
which are the control:

| axis | boards differing |
|---|---|
| plain, forfeits, `XXP`, Baku | **0** |
| 15% arbiter byes, `152 W` | 670 |
| 15% arbiter byes, `152 B` | 1175 |

Colour is allocated *after* the pairing, so this cannot move a player to a
different board: every axis above still reports 100.00% pairing agreement
and zero illegal rounds. Full argument, with the handbook text and a
reproducible probe, in
[docs/dispute-initial-colour.md](docs/dispute-initial-colour.md).

## Documentation

| document | what it is |
|---|---|
| [docs/architecture.md](docs/architecture.md) | how the engine is put together, module by module |
| [docs/validation.md](docs/validation.md) | the measurement record and how it was produced |
| [docs/conformance-c0403-2026.md](docs/conformance-c0403-2026.md) | article-by-article verification against the 2026 rules text |
| [docs/fide-criteria.md](docs/fide-criteria.md) | the maintained rules-to-code map (C1–C21) |
| [docs/dispute-seed735265.md](docs/dispute-seed735265.md) | the one disagreement, argued from the regulations |
| [docs/bbppairings-c2-bug-report.md](docs/bbppairings-c2-bug-report.md) | that dispute as a submittable upstream report |
| [docs/engineering-log.md](docs/engineering-log.md) | the dated build history, including what measured worse |
| [TODO.md](TODO.md) | open work |

## Development

```bash
mix test
```

133 tests. Comparison tests against JaVaFo and Gacrux are tagged and
excluded by default — neither is vendored, and both must be supplied
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

[Apache License 2.0](LICENSE) — deliberately the same licence as
[bbpPairings](https://github.com/BieremaBoyzProgramming/bbpPairings),
because parts of this engine are derived from it. `Ainalrami.Pairing`'s
bracket cascade is a stage-for-stage port of `dutch.cpp`, and
`Ainalrami.WeightedMatching`'s control flow was read directly from
bbpPairings' matching sources while writing the Elixir equivalent.

No bbpPairings code is reproduced here — it is C++ and this is Elixir —
but the algorithm and structure are theirs, originating file and line
numbers are cited inline throughout, and matching their licence is the
cleanest way to honour that rather than leaving it ambiguous.
[NOTICE](NOTICE) spells out exactly which files are derived and what
changed.

JaVaFo is © Roberto Ricca, is not open source, and is not bundled here.
