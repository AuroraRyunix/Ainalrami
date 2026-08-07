# OpenPair

A FIDE Dutch-system Swiss pairing engine, written in Elixir.

OpenPair is the sibling project to
[OpenPairings](https://github.com/AuroraRyunix/openpairings) (the Elixir/
Phoenix tournament manager), which today wraps FIDE's own reference
implementation, [JaVaFo](https://www.rrweb.org/javafo/), for every Swiss
pairing decision. OpenPair's goal is to become an **optional second pairing
engine** inside that app — JaVaFo stays the default, especially for
FIDE-rated/homologated tournaments, where OpenPairings' whole endorsement
story rests on the same "uses JaVaFo, thru JaVaFo" pattern Vega, Swiss
Manager and TournamentService already use. OpenPair is for everything else:
tournaments that don't need that precedent, experimentation with pairing
variants JaVaFo doesn't expose (acceleration systems beyond Baku, alternate
tiebreak orderings), and a third independent data point for cross-checking
pairing correctness alongside JaVaFo and
[bbpPairings](https://github.com/BieremaBoyzProgramming/bbpPairings).

**Status: beta — the Dutch-system engine is functionally complete and
ready to test, measured at depth against both real JaVaFo output and real
bbpPairings output, not just our own unit tests. Not yet wired into
OpenPairings as a selectable engine.**

- **Round 1**: 100% match against `javafo.jar` on a clean 20,000-random-roster
  run (`OpenPair.Pairing.pair_round_one/1`, colour-blind composition diff —
  see `test/open_pair/javafo_comparison_test.exs`).
- **Round 2+**: **99.85%** composition match (5991/6000 random round-1
  outcomes) — `OpenPair.Pairing.pair_later_round/1`, general
  maximum-weight matching over each score bracket via `OpenPair.Matching`.
  Every scoring term in it was measured against real `javafo.jar` rather
  than derived from the spec; [TODO.md](TODO.md) has the full table,
  including changes that looked obviously correct and measured *worse*
  (a bipartite bracket restriction at 10.7%, a natural-correspondence
  tie-break at 64.95%), all reverted rather than kept for elegance.
- **Depth (rounds 1-9, 300 tournaments, 10-40 players)**: **97.19%** of
  individual pairs match javafo, **88.93%** of whole rounds match exactly
  — round 1 is exact, round 9 (the hardest, most opponent-exhausted round
  measured) is 91.54%. What actually governs accuracy is not the round
  number but how much of the field a player has already met — a 60-70
  player field at 15 rounds is still 97.76%. See TODO.md's "Depth" and
  "How close to javafo" sections for the full round-by-round table and
  every fix that got it there.
- **Legality, independent of javafo**: every player paired exactly once,
  no rematches, and exactly one pairing-allocated bye in an odd active
  field (none in an even one) — **0 illegal rounds** across every
  configuration currently measured, including the hardest stress test
  (30 rounds, 32-40 players) and arbiter-assigned-bye-heavy tournaments
  (800 generated tournaments, ~5500 rounds, mixed bye rates). When no
  legal pairing can exist at all — a genuine structural deadlock, not a
  search failure — the engine raises
  `OpenPair.Pairing.NoValidPairingError` rather than emitting a
  best-effort illegal result, matching bbpPairings' own
  `NoValidPairingException`.
- **bbpPairings depth (rounds 1-9, 200 tournaments, 4-40 players)**:
  **95.92%** of individual pairs and **86.32%** of whole rounds match
  Bierema Boyz Programming's independent reference implementation, run
  directly (not just read as source) — `test/support/bbppairings.ex` +
  `bbppairings_comparison_test.exs`. **0 illegal rounds** here too, and
  bbpPairings independently confirmed OpenPair's structural-deadlock
  cases really are unpairable (its own exit code 1 on byte-identical
  input). See TODO.md's "Cross-validation against bbpPairings" for the
  full round-by-round table.

The CLI's `-p` mode calls the real pairing engine for both cases now,
writing output in JaVaFo's own text shape.

## Command-line interface

Deliberately mirrors JaVaFo's own invocation shape — confirmed against
OpenPairings' real `System.cmd` call
(`java -jar javafo.jar input.trf -p output.txt`), not guessed — so a caller
that already knows how to drive JaVaFo only has to swap the executable name:

```bash
openpair input.trf -p output.trf   # pair the next round
openpair input.trf -p              # same, but the pairing prints to stdout
openpair -g output.trf             # Random Tournament Generator
openpair input.trf -c              # Pairings Checker: replay and diff every round
```

`-g` and `-c` mirror JaVaFo's own RTG/FPC modes (used for FIDE's FE1
endorsement auto-test — see OpenPairings' `docs/fide-endorsement.md`).

`-c` replays a completed tournament round by round, re-pairing each round
from the state that preceded it and diffing against the pairing the file
records. It exits 0 when every round matches and 1 otherwise. Differences
in COLOUR are reported but never counted as errors — Article 5.1 leaves
the first colour to a drawing of lots, so this engine's convention is its
own and legitimately differs from JaVaFo's.

**A checker is not an independent verifier of the rules.** It re-runs the
same engine and calls that the correct answer, exactly as bbpPairings'
own `-c` does (`tournament/checker.cpp` clears the matches, replays, and
calls `computeMatching`). A reported difference means "this engine would
have paired it differently", not "the file is illegal" — the file may
hold a perfectly legal pairing this engine simply wouldn't choose.

`-g` generates a random tournament and plays it forward, pairing each
round with this engine. It takes no input file — it creates a tournament
rather than reading one — and writes to stdout when given no output path:

```
openpair -g out.trf --seed=42 --players=30 --rounds=9 --forfeit-pct=10 --bye-pct=5
```

Every run is reproducible from its seed, and the seed is written into the
generated file's own tournament name, so a file always reproduces itself.
`--rounds` is capped at `players - 1`, past which a Swiss has no legal
opponents left; it can also stop earlier still, if some round along the
way turns out to have no legal pairing at all (a real, if rare,
possibility for a small field deep into a Swiss — see
`OpenPair.Pairing.NoValidPairingError`).

The two modes are each other's test: `-g` output fed to `-c` checks clean
by construction, since the generator pairs with the same engine the
checker replays. That round-trip is covered for plain tournaments and for
ones carrying forfeits and arbiter-assigned byes.

### Verbose by default

Unlike JaVaFo, which prints almost nothing beyond the paired result,
OpenPair prints a step-by-step trace of what it's doing by default. Pass
`-q`/`--quiet` to suppress it. See `OpenPair.Log`'s moduledoc for the
reasoning — the intent is that "why did board 3 downfloat instead of board
5" should be answerable by reading the run's own output.

## Development

```bash
mix deps.get
mix test
mix format
mix escript.build   # produces a standalone `openpair` executable
```

Requires Elixir `~> 1.17`, no runtime dependencies (no JVM, no external
binary) — matches OpenPairings' own standalone-binary story
(`docs/binaries.md` there), just without needing Burrito to get there.

## License

Not yet decided/declared. Don't treat this as open-source-licensed for reuse
until a `LICENSE` file is added.
