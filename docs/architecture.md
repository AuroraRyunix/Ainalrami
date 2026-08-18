# Architecture

How Ainalrami is put together, and why it is put together that way. For
the rules themselves see [conformance-c0403-2026.md](conformance-c0403-2026.md);
for how the engine was verified see [validation.md](validation.md).

## The shape of the thing

```
  TRF16 file
      │
      ▼
  Ainalrami.Trf ──────────── parse: players, games, XXR/XXP/XXA
      │
      ▼
  Ainalrami.Pairing ──────── the Dutch system itself
      │                       • pair_round_one/1
      │                       • pair_later_round/1 → global_cascade/2
      │
      ├──► Ainalrami.Matching ────────── bitmask DP, small brackets
      └──► Ainalrami.WeightedMatching ── Galil/Micali/Gabow, whole field
      │
      ▼
  Ainalrami.Trf ──────────── serialize
```

`Ainalrami.CLI` wraps that for the command line, `Ainalrami.Generator`
drives it in reverse to build test tournaments, and `Ainalrami.Log` traces
every step by default.

## Modules

| module | lines | role |
|---|---|---|
| `Ainalrami.Pairing` | 3144 | the Dutch system: brackets, criteria, colours |
| `Ainalrami.WeightedMatching` | 966 | maximum-weight matching in a general graph |
| `Ainalrami.Trf` | 946 | TRF16 parse and serialize, plus `XX` extensions |
| `Ainalrami.CLI` | 432 | `-p` / `-g` / `-c`, mirroring JaVaFo's shape |
| `Ainalrami.Generator` | 273 | Random Tournament Generator |
| `Ainalrami.Matching` | 220 | bitmask DP matching over one bracket |
| `Ainalrami.Sequence` | 134 | Article 4's candidate generation order |
| `Ainalrami.Log` | 55 | trace output, verbose by default |

### `Ainalrami.Trf`

FIDE's published TRF16 specification (C.04 Annex 2), plus the three
JaVaFo `XX` extension lines. Not derived from bbpPairings — adapted from
the author's own OpenPairings project.

Two things here are load-bearing beyond ordinary parsing:

- **`points_for/1`** is the single source of truth for what a result code
  is worth, across five spellings of a win (`1 + F U W`) and three of a
  draw (`= H D`). Several bugs in this engine's history came from a second
  place deciding the same question differently.
- **`parse/1` raises** on an inconsistent result — both sides claiming a
  win, both marked forfeit-win — rather than accepting it. A tournament
  file that disagrees with itself has no correct pairing.

### `Ainalrami.Pairing`

The bulk of the engine. Round one is its own path (`pair_round_one/1`);
everything after goes through `pair_later_round/1` into `global_cascade/2`,
a stage-for-stage port of bbpPairings' bracket algorithm — eight matchings
per bracket, not one.

**There is no second pairing path.** The per-bracket cascade that used to
back this up was deleted once it stopped being reached at all, as was the
bye-count repair and the `Blossom` matcher it called
([engineering-log.md](engineering-log.md) records why, at length: the
repair's guard was a predicate implied by its own parent, so the branch
could not execute, and the dead path would itself have produced illegal
colours had it ever run).

The criteria ladder C1–C21 is encoded as **packed edge weights** in
priority order, so one matching solves the whole ordering rather than
filtering candidates criterion by criterion.

`explain_round/3` is the diagnostic counterpart: it scores both a given
pairing and the engine's own with the same ladder and reports the first
rung where they part. It carries an `edge_count` guard and an
`incomparable` verdict because rungs sum over edges, so two answers
contributing different numbers of edges cannot be compared rung by rung —
an accounting artifact that produced a wrong verdict before the guard
existed.

### `Ainalrami.Matching` and `Ainalrami.WeightedMatching`

Two matchers, for two different jobs.

`Matching` is memoized bitmask dynamic programming over a whole bracket,
allowing some players to go unmatched as floaters. It is not restricted to
a bipartite S1/S2 split — which matters, because Article 4.3's exchanges
reach pairings no bipartite split can express.

`WeightedMatching` is the Galil/Micali/Gabow (1986) primal-dual algorithm,
confirmed from bbpPairings' own source as what it uses, and needed when
the problem is the whole field at once rather than one bracket.

It originally **omitted** bbpPairings' incremental caches
(`minOuterEdges`, per-blossom `minOuterEdgeResistance`) and rescanned
instead, trading the O(n³) bound for a smaller and more directly
verifiable translation. That was fine while brackets were small and became
the engine's binding constraint once a 209-player field took ninety
seconds a round.

It now maintains equivalent caches — per vertex rather than per blossom —
and divides every edge weight by the greatest common divisor of all of
them before solving, which matters because `Ainalrami.Pairing`'s packed
criteria produce weights of about a hundred digits and made the innermost
operation in the algorithm arbitrary-precision arithmetic. Both are stated
in [NOTICE](../NOTICE) as §4(b) changes, and the measurements, the
reasoning that makes the caches sound, and what the work did *not* achieve
are in [validation.md](validation.md#performance).

### `Ainalrami.Sequence`

Article 4's candidate generation order — transpositions of S2, then
exchanges between S1 and S2 — implemented independently of the engine, and
checked against every worked example the article gives.

It exists as an **oracle, not a code path.** The engine does not enumerate
candidates; this module knows how the regulations say to, so the two can
be compared. `tiebreak_order_test.exs` uses it to prove the engine's
`transposition_key/3` is not an approximation of Article 4.2 but is 4.2:
the article sorts by "the lexicographic value of their first N1 BSN(s)",
the key sorts by S2 index, and since S2 is sorted by Article 1.2 and BSNs
are assigned in that order, the two lexicographic orders are identical.

Wiring it in for **4.3** — where no such proof exists yet — is the
remaining conformance work. See [TODO.md](../TODO.md).

### `Ainalrami.Generator`

Builds a random roster and plays it forward, pairing each round with
`Ainalrami.Pairing` itself. That the generator uses the engine under test
is deliberate and is what makes `-g` into `-c` a closed round trip; it
also means the generator cannot be used to find pairing bugs on its own,
which is why every real measurement runs against an external reference
instead.

Seeded and fully reproducible, with the seed written into the generated
tournament's own name so a file always reproduces itself.

### `Ainalrami.Log`

Verbose by default, `-q` to suppress. The reasoning is in its moduledoc:
an arbiter asked to justify a pairing should be able to answer from the
run's own output, and an engine that explains itself only under a debug
flag will not be trusted at the board.

## Two design decisions worth knowing

### Matching, not enumeration

The regulations describe pairing a bracket by *generating candidates in a
defined sequence* (Articles 3.5–3.8 and 4) and taking the first perfect
one, or the best under 3.8.1.

This engine solves a maximum-weight matching whose edge weights pack
C1–C21 in priority order. It reaches the same optimum without ever
enumerating a candidate. The two agree on which pairing is *best*; the
only question has ever been how they break a tie below every criterion,
since 3.8.1's last resort is generation order.

That question is now settled for transpositions (proven identical) and
open only for exchanges.

### The reference is bbpPairings, not JaVaFo

JaVaFo is FIDE's own reference implementation, and this engine is
deliberately **not** measured primarily against it, because JaVaFo
implements the superseded 2022 rules. bbpPairings and Gacrux both
implement the 2026 edition and agree with each other on every one of 3352
rounds tested, which is what makes them usable as a ruler.

The ~4% gap against JaVaFo is a control, not a defect: it is the size of
the rules change. An engine agreeing with all three at once would mean the
harness was measuring nothing.

## Environment variables

Diagnostic only; none affects a normal run.

| variable | effect |
|---|---|
| `AINALRAMI_TRACE` | trace the bracket cascade |
| `AINALRAMI_TRACE_FALLBACK` | trace only the completion fallback |
| `AINALRAMI_FORCE_STRAND` | fault-inject a stranded player, exercising `repair_completion/3` |
| `AINALRAMI_PEEK` | override the lookahead budget |
| `AINALRAMI_TRANS_ABOVE` | trace transposition keys above a threshold |
| `AINALRAMI_NO_TRANS` | disable the transposition tie-break |
| `AINALRAMI_COMPLETION` | trace completion checking |

`AINALRAMI_FORCE_STRAND` is the one worth singling out: it exists because
this project's standing rule is that **insurance nothing has exercised is
a guess**. `repair_completion/3` is the engine's real completion fallback,
it is reached in normal operation, and it is fault-injected here so its
behaviour is measured rather than assumed. The bye-count repair that was
deleted had no such injection — which is part of why it was deleted.
