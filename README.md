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

**Status: round 1 works and is verified against real JaVaFo output**
(`OpenPair.Pairing.pair_round_one/1`, cross-checked colour-blind against
`javafo.jar` on thousands of random rosters — see
`test/open_pair/javafo_comparison_test.exs`). Later rounds — the actual
hard part of the Dutch system, bracket formation with floaters and
backtracking — don't exist yet. See [TODO.md](TODO.md) for the staged
plan. The CLI's `-p` mode doesn't call the pairing engine yet either (still
loads/validates/reports the roster and says so); that wiring is next.

## Command-line interface

Deliberately mirrors JaVaFo's own invocation shape — confirmed against
OpenPairings' real `System.cmd` call
(`java -jar javafo.jar input.trf -p output.txt`), not guessed — so a caller
that already knows how to drive JaVaFo only has to swap the executable name:

```bash
openpair input.trf -p output.trf   # pair the next round
openpair input.trf -p              # same, but the pairing prints to stdout
openpair input.trf -g              # Random Tournament Generator (not yet implemented)
openpair input.trf -c              # Pairings Checker (not yet implemented)
```

`-g` and `-c` mirror JaVaFo's own RTG/FPC modes (used for FIDE's FE1
endorsement auto-test — see OpenPairings' `docs/fide-endorsement.md`) — the
flags exist and give a clear "not built yet" answer today, rather than an
unknown-flag error, so the CLI's shape is already stable for whoever
implements them.

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
