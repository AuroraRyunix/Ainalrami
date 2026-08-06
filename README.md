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

**Status: round 1 is solid; later rounds work and are improving, verified
against real JaVaFo output, not just our own unit tests.**

- **Round 1**: 100% match against `javafo.jar` on a clean 20,000-random-roster
  run (`OpenPair.Pairing.pair_round_one/1`, colour-blind composition diff —
  see `test/open_pair/javafo_comparison_test.exs`), re-confirmed at 3,000
  after the round-2 work landed, to rule out a shared-code regression.
- **Round 2+**: **99.85%** composition match (5991/6000 random round-1
  outcomes) — `OpenPair.Pairing.pair_later_round/1`, general
  maximum-weight matching over each score bracket via `OpenPair.Matching`,
  checked by `test/open_pair/javafo_comparison_round2_test.exs`. Every
  scoring term in it was measured against real `javafo.jar` rather than
  derived from the spec; [TODO.md](TODO.md) has the full table, including
  the two changes that looked obviously correct and measured *worse*
  (a bipartite bracket restriction at 10.7%, and a natural-correspondence
  tie-break at 64.95%), both reverted. The 6,000-case rate is measured on
  3× the 2,000 cases the scoring was tuned against and came out slightly
  higher (99.75% → 99.85%), so it isn't overfitted to the tuning set.

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
openpair input.trf -g              # Random Tournament Generator (not yet implemented)
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

`-g` is still not built; the flag answers "not built yet" rather than an
unknown-flag error.

### Verbose by default

Unlike JaVaFo, which prints almost nothing beyond the paired result,
OpenPair prints a step-by-step trace of what it's doing by default. Pass
`-q`/`--quiet` to suppress it. See `OpenPair.Log`'s moduledoc for the
reasoning — the intent is that "why did board 3 downfloat instead of board
5" should be answerable by reading the run's own output, once the real
pairing engine lands.

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
