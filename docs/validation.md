# Validation

How Ainalrami is measured, what the numbers are, and — the part that
matters most — what the measurements could not have seen.

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

Ainalrami measures **96.26%** against JaVaFo, and that is the expected
result rather than a defect — it is the size of the rules change. An
engine agreeing with all three simultaneously would prove the harness was
measuring nothing.

## The corpus

**4.3 million tournaments, ~195 million individual pairings, one
disagreement**, from the 2026-08-17 runs on a 36-core machine.

| axis | tournaments | exact rounds | individual pairs | illegal |
|---|---|---|---|---|
| plain, 4–40 players | 120,000 | 100.00% | 100.00% | 0 |
| plain, 4–10 players | 500,000 | 100.00% | 100.00% | 0 |
| 15% arbiter byes, 4–40 | 250,000 | 100.00% | 100.00% | 0 |
| 15% arbiter byes, 4–10 | 1,200,000 | 100.00% (1 dispute) | 100.00% | 0 |
| 10% forfeits, 4–40 | 120,000 | 100.00% | 100.00% | 0 |
| 20% forbidden (`XXP`) | 120,000 | 100.00% | 100.00% | 0 |
| Baku acceleration (`XXA`) | 120,000 | 100.00% | 100.00% | 0 |
| byes + forfeits + `XXP` + `XXA` | 120,000 | 100.00% | 100.00% | 0 |
| 60–120 players | 600 | 100.00% | 100.00% | 0 |
| **even round counts** (6, 8, 10) | 850,000 | 100.00% | 100.00% | 0 |
| odd-round controls (7, 9) | 350,000 | 100.00% | 100.00% | 0 |

FIDE's FE1 endorsement bar is one difference per 500 tournaments. This is
one per 4.3 million.

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
| `javafo` | round-one composition against real JaVaFo |
| `three_way` | Ainalrami vs bbpPairings vs Gacrux on identical positions |
| `taxonomy` | classify disagreements by first differing bracket |
| `rule_delta` | pinned cases where the 2022 and 2026 rules differ |

Every axis is a set of environment variables:

| variable | default | meaning |
|---|---|---|
| `PAIRING_FUZZ_COUNT` | small | tournaments to generate |
| `PAIRING_FUZZ_ROUNDS` | 9 | rounds per tournament — **vary this** |
| `PAIRING_FUZZ_MIN_PLAYERS` / `MAX_PLAYERS` | 4 / 40 | field size range |
| `PAIRING_FUZZ_SEED_FROM` | 1 | start of the seed range |
| `PAIRING_FUZZ_BYE_PCT` | 0 | arbiter-assigned bye rate |
| `PAIRING_FUZZ_FORFEIT_PCT` | 0 | forfeit rate |
| `PAIRING_FUZZ_FORBIDDEN_PCT` | 0 | `XXP` density |
| `PAIRING_FUZZ_ACCEL` | none | `baku` or random `XXA` |
| `PAIRING_FUZZ_INITIAL_COLOUR` | `w` | TRF `152` header |
| `PAIRING_FUZZ_DUMP` | — | directory for failing cases |
| `COLOUR_DEBUG` | — | report colour mismatches per pair |

`overnight_run/run.sh` drives the long batches.

**Seeds are independent**, and `PAIRING_FUZZ_SEED_FROM` starts the range
anywhere — so any catalogued case regenerates in about a second rather
than requiring the 735,264 tournaments before it. That knob not existing
is a large part of why early catalogued cases were adjudicated once and
never revisited.

## What the corpus could not see

This is the section worth reading.

### 2.5 million tournaments held one parameter constant

Every axis measured before 2026-08-17 ran `PAIRING_FUZZ_ROUNDS=9`. A
nine-round tournament pairs its final round with **eight** played, and
`div(8, 2) == 8 / 2`.

So a topscorer threshold that *floors* the half-point is invisible. It can
only differ when the played-round count is odd — that is, when the
tournament has an **even** number of rounds. `final_round_topscorers?/2`
had exactly that bug. Re-measured at 8 rounds, 2,000 tournaments:

| | exact rounds | individual pairs |
|---|---|---|
| before | 15051/15060 = 99.94% | 155831/155862 = 99.98% |
| after | **15060/15060 = 100.00%** | **155862/155862 = 100.00%** |

Nine wrong rounds that 2.5 million tournaments could not produce. Six-,
eight- and ten-round Swisses are ordinary events; this was never an exotic
corner.

**Corpus size bought nothing here.** The axes varied field size, bye rate,
forfeit rate and extension lines — and held constant the one parameter the
bug was a function of.

> When adding an axis, ask what the existing ones hold **constant**, not
> what they vary.

The even-round axis is now first-class: 1,800,000 tournaments across
rounds 6/7/8/9/10, zero disagreements. The odd controls are the point —
had 7 and 9 also moved, the fix would have been wrong in a way the small
local run could not have shown.

### "Zero illegal rounds" was true until it was tested 100× harder

Legality is checked independently of any reference: every player paired
exactly once, no rematches, exactly one pairing-allocated bye in an odd
active field and none in an even one.

That held at every sample size up to ~5,500 rounds. At 839,776 rounds it
did not: the first 100,000-tournament bye-rate run found **102 illegal
rounds (0.012%)**. Ninety-five raised `ArgumentError` from a range
`0..-1` — Elixir's default step for a descending range walks `0, -1`, and
`elem(arr, -1)` is an invalid index — reachable only when exactly one
player was left needing a bye. Five returned the wrong bye count, two a
non-partition.

All are closed, each with a regression test that fails on the pre-fix
code. Re-running the identical configuration over 250,000 tournaments /
2,099,071 rounds now gives zero.

**The standing bar is the 100× sample, not the one that passed.**

### Four instruments were broken or blind

Found while chasing the above, and worth listing because three engine bugs
were found *by* fixing the instrument rather than by the instrument:

- **`explain_round/3` never stamped float history**, so C14–C21 scored a
  constant on both sides of every verdict the adjudicator ever printed. It
  could not invent a disagreement — both sides were scored blank, so a tie
  stayed a tie — but it could *misattribute* one. It had no test of any
  kind until `explain_round_test.exs`.
- **The legality oracle was a copy of the engine.** An enumerator that
  checks C1 but neither C2 nor C3 reports "legal pairings the engine
  refused" — it has admitted illegal ones. A weaker oracle accusing a
  stronger implementation is the expected result, not a finding.
- **Every axis pinned `ROUNDS=9`**, as above.
- **The harness never compared colours.** Colour agreement was simply not
  measured until `colour_mismatches/5` was added — 4.3 million tournaments
  and 195 million pairings had validated who plays whom and never once
  checked Article 5. Turning it on immediately found a missing 5.2.4 and
  then the 5.2.5 dispute below.

### Colour is measured separately, and split by cause

Colour differences are counted apart from pairing differences, because
they fail for different reasons: a colour difference on an otherwise
identical round is not the same finding as a different round.

They are then split again, into the known
[Article 5.2.5 dispute](dispute-initial-colour.md) and **unexplained**.
Without that split the dispute's volume — hundreds of boards per few
hundred bye-heavy tournaments — would bury a real colour regression
completely.

A board is filed under the dispute when 5.2.5 is what decides it (neither
player holds any colour preference) **and this engine's answer is the one
the article gives**. That deliberately tests our own conformance rather
than matching a model of bbpPairings' internals: an earlier version did
the latter and mis-filed a genuine case, because predicting the
references' numbering means implementing a rule this project rejects —
twice, and in a test.

The axes without byes are the control that makes the rest meaningful:
plain, forfeit, `XXP` and Baku runs report **zero** colour differences,
so this is not a general disagreement about Article 5.

The adjudication tables in [engineering-log.md](engineering-log.md) were
produced with the blank float history and have **not** been re-run. They
are not wrong about *whether* the engines differed — that comes from the
harness, not the scorer — but their "first differing rung" column is only
trustworthy where the winning rung outranks C14.

## Legality, independent of any reference

When no legal pairing can exist at all — a genuine structural deadlock,
not a search failure — the engine raises
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

Every previously-measured axis was byte-identical after that change — the
same numerators and denominators, not merely the same percentages.

What the old line-dropping behaviour actually cost, before they were
implemented: at 20% forbidden-pair density it seated a forbidden pair in
**27.72%** of rounds, and Baku acceleration paired **66.12%** of rounds on
the wrong scores.

## Not covered

Stated so the claim's boundary is explicit:

- **`260` and `250`** — bbpPairings' round-limited siblings of `XXP` and
  `XXA`. Deliberately absent rather than stubbed.
- **bbpPairings' own Baku flag**, which sizes Group A as `ceil(n/2)` where
  FIDE C.04.7 uses `2 * ceil(n/4)`. Reached only through its own flag,
  never through `XXA`, so it cannot make the two engines disagree here —
  both read identical `XXA` lines from an identical file.
- **Team tournaments, unrated players, late entrants**, and files where
  `rounds_count` disagrees with `XXR`. The harness generates none of
  these; see [TODO.md](../TODO.md).
