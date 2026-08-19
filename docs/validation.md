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

> **This corpus predates the 2026-08-18 changes and has not been re-run at
> that scale.** What changed since: `152` is written as well as read, the
> initial colour is inferred when a file omits it, the CLI forwards the
> drawing of lots, `260`/`250` are implemented, and `forbidden_map/2` took
> a round argument.
>
> None of them touches a path this corpus exercises — the harness writes
> its own `152` and passes the colour explicitly, so the inference never
> fires; it emits `XXP`/`XXA` and never `260`/`250`; and `forbidden_map`'s
> behaviour for a plain group list is unchanged. That is an argument
> though, not a measurement, so the *engine* was re-validated even though
> the corpus was not.

### Re-validation after the 2026-08-18 changes

**11,000 tournaments / 69,038 rounds / 680,022 individual pairings, at
100.00% with zero illegal rounds, zero refusals and zero unexplained
colour differences.**

| axis | rounds | individual pairs |
|---|---|---|
| byes + forfeits + `XXP` + `XXA`, 7 rounds | 16,605 | 165,629 |
| 15% byes, **8** rounds | 18,920 | 189,175 |
| plain, 4–10 players | 6,586 | 26,032 |
| **60–120 players** | 840 | 38,717 |
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

- ~~**`260` and `250`**~~ — **implemented 2026-08-18.** These are
  bbpPairings' round-limited siblings of `XXP` and `XXA`, and they were
  listed here as "deliberately absent rather than stubbed". That was wrong
  in a specific way: absent meant the lines fell through to the header
  parser and were *silently discarded*, so a file saying "1 and 3 must
  never meet in rounds 1-3" produced a complete, legal-looking round that
  seated 1 against 3. Verified happening before the fix. Both are now read,
  both raise on a malformed line, and every case was checked against the
  real binary — including a `260` whose range excludes the round being
  paired, which must do nothing.
- **bbpPairings' own Baku flag**, which sizes Group A as `ceil(n/2)` where
  FIDE C.04.7 uses `2 * ceil(n/4)`. Reached only through its own flag,
  never through `XXA`, so it cannot make the two engines disagree here —
  both read identical `XXA` lines from an identical file.
- **Team tournaments, unrated players, late entrants**, and files where
  `rounds_count` disagrees with `XXR`. The harness generates none of
  these; see [TODO.md](../TODO.md).

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

**2.4× overall, and the growth rate barely moved** — still somewhere
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
C1–C21 into a single integer by giving each criterion its own band, and on
a 209-player field that produces weights of **103 digits** — so every
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
other 90% — 46% rebuilding at stage boundaries, 44% refreshing after
structural changes. The work moved rather than vanished. Getting past that
needs the maintenance itself to be incremental across stages, which the
labels being recomputed wholesale by `init_labels/1` currently prevents.

### How it is verified

This is the most delicate module in the engine, and the one place a subtle
error yields a wrong pairing rather than an obvious failure. Three
independent checks:

- **`tools/matching_baseline.exs`** replays `solve/2` over 460 random
  graphs — 400 small, where blossoms are easy to hit by chance, and 60 at
  40–90 vertices — across three densities and both weight scales. Every
  one is checked for **total weight** and matched count, not byte
  identity: 460/460 optimal.
- **Byte identity is deliberately not required.** 86% of delta steps have
  a *tied* minimum, so a cache that finds any minimum takes a different
  path through the search almost every step; 38 of the 460 land on a
  different matching of the same weight, which is correct when the optimum
  is not unique.
- **That this is safe was measured before the caches were written.**
  Inverting the tie-break of the old linear scans left the engine agreeing
  with bbpPairings on 1358/1358 rounds — so the pairing is determined by
  the weights, not by the order equal-slack edges happen to be visited in.
- **The corpus**, which is the check that actually matters. With the
  caches in place, **39,371 rounds and 435,294 individual pairings at
  100.00%**, zero illegal and zero refusals:

  | axis | rounds | individual pairs |
  |---|---|---|
  | byes + forfeits + `XXP` + Baku, 2,000 tournaments | 13,252 | 132,065 |
  | 15% byes, **10** rounds, 2,000 tournaments | 18,332 | 186,645 |
  | **60–120 players** | 1,050 | 48,132 |
  | plain / byes / combined / 8-round, 250 each | 6,737 | 68,452 |

  The large-field row is the one to look at. It is where a matcher change
  would show first, and where the differential corpus is thinnest.

### Against bbpPairings, on the same file

The reference is not instant either, which is worth knowing before
treating any target as obvious. Same tournament, same round, same machine
— bbpPairings generated the file itself, so neither side is favoured.
Warm medians of three:

| players | bbpPairings | Ainalrami 08-18 morning | 08-18 evening | **08-19** | gap now |
|---|---|---|---|---|---|
| 60 | | | | **0.05 s** | |
| 120 | | | | **0.22 s** | |
| 209 | 0.67 s | 38 s | 9.5 s | **1.24 s** | **1.9×** |
| 300 | | | | **1.7 s** | |
| 400 | 2.9 s | 498 s | 69.8 s | **4.5 s** | **1.5×** |

**From 166× to 1.5× at 400 players in two days, all in Elixir.** The
first day made the algorithm and its bookkeeping the reference's, step
for step; the second found that the operation counts were still not the
same, and fixed that. In order of effect: preparing the *modified* vertex
of each changed edge rather than the lower-indexed one (`computer.cpp:69`
— the cost of a resumed solve is proportional to how many distinct
vertices were modified, and a whole-map diff cannot know which one that
was); starting a fresh solve from a greedy tight matching instead of a
hundred stages of one heaviest edge each; scoring only the bracket-and-
next-group window per bracket, with far edges set once per round as
`dutch.cpp:740-816` does; a nearness term below every criterion, which
leaves the optimum nearly unique so that each stage's alternating forest
grows only where it must instead of across the whole field; and the
cross table kept as rows so that blossom formation is a merge, not a
rebuild; and the same greedy tight start applied to a RESUMED solve, so
that at a bracket boundary the residents pair among themselves before a
single stage runs. The full table, with what each step measured and what it
corrected, is in `docs/engineering-log.md`, "Matcher performance,
2026-08-19".

**Two of those are places this engine now does less work than the
reference.** bbpPairings starts every solve cold, and it leaves its far
edges tied, so its forests span the field too; it is simply fast enough
per operation not to mind. The greedy start and the nearness term are
both below every criterion and every refinement-stage addend, and the
corpus is identical with each of them on or off.

**What remains is per-operation cost on work the reference does too**:
tree growth (one O(V) row walk per newly-outer vertex), the per-stage
inner–outer rebuild, blossom formation — all on weights of 450 bits,
which is what six score-place rungs with 50-bit spans come to, and which
bbpPairings carries as well (it sizes `edge_weight` to the field). The
gap on that is 1.5–2× and is the BEAM against C++ on bignums.

**Correctness is not what degrades.** On that 400-player round the two
engines returned **200 of 200 boards identical, colours included** — twice
the largest field the corpus had ever covered — and every step above was
held to 100.00% on all six corpus axes and both differential nets before
it was committed.

### What it means in practice

Club and national events — up to ~150 players — pair in a quarter of a
second. A 200-player open is **about a second a round**. A 400-player
open is four and a half seconds, against the reference's three.

