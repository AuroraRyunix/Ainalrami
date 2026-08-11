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
- **Round 2+**: `OpenPair.Pairing.pair_later_round/1` — `global_cascade/2`,
  a stage-for-stage port of bbpPairings' bracket algorithm (eight
  matchings per bracket, not one). There is no second pairing path: the
  per-bracket cascade that used to back it up was deleted once it stopped
  being reached at all. Every scoring term was measured against real
  reference output rather than derived from the spec; [TODO.md](TODO.md)
  has the full table, including changes that looked obviously correct and
  measured *worse*, kept as negative results rather than quietly dropped.
- **Depth, against bbpPairings 6.0.0** — the current headline, and the
  reference to steer by, since bbpPairings and Gacrux both implement the
  2026 rules and agree with each other 100% over 3352 rounds while JaVaFo
  (2022 rules) differs from both on 2.47%:

  | field | exact rounds | individual pairs | illegal |
  |---|---|---|---|
  | 4-40, 500x9 | **100.00%** (4197/4197) | **100.00%** (49802/49802) | 0 |
  | 60-80, 20x9 | **100.00%** | **100.00%** | 0 |
  | 90-120, 8x9 | **100.00%** | **100.00%** | 0 |
  | 4-40 + 8% arbiter byes | 99.76% | 99.94% | 0 |
  | 4-40 + 15% arbiter byes, 100,000x9 | **99.99%** (839660/839776) | **100.00%** (8484342/8484704) | 7 |
  | 4-40 + 10% forfeits, 100,000x9 | **99.93%** (838793/839417) | **99.98%** (9934140/9936166) | 0 |

  Both the bye and forfeit rows above are 100,000-tournament overnight
  runs, not the earlier 300-tournament samples — same shape in both
  (99.6% -> 99.97%+ byes, 99.5% -> 99.93% forfeits), but at two orders of
  magnitude more rounds the confidence interval on "how rare is the
  remaining gap" is far tighter. The bye row is a second, POST-FIX
  overnight run — see **Legality** below for what the first one at this
  scale found (102 illegal rounds, not the 0 every smaller sample had
  shown) and what fixing it moved: 95 fewer illegal rounds, and exact-
  round matches up by exactly 95, so every one of them now produces
  bbpPairings' own correct answer, not merely a legal one. The forfeit
  run is unchanged between the two passes (99.93%/99.98%/0 both times),
  confirming the fix didn't touch anything it shouldn't have.

  On plain tournaments the engine reproduces bbpPairings **exactly** —
  every board of every round, at every field size tested. Confirmed on a
  second code path: the three-way harness matches both references on
  1261/1261 rounds. Arbiter byes and forfeits are the only axes still
  short of exact, and both are inside half a percent.

  Against JaVaFo the engine measures 96.26%, and it SHOULD not be 100% —
  JaVaFo implements the superseded 2022 rules and differs from both 2026
  references by about the same margin. That gap is the useful control: an
  engine agreeing with all three at once would mean the harness was
  measuring nothing.

  TODO.md has the whole account of how it got here, including the
  measurements that failed.
- **Legality, independent of javafo**: every player paired exactly once,
  no rematches, and exactly one pairing-allocated bye in an odd active
  field (none in an even one) — 0 illegal rounds on every sample up to
  ~5,500 rounds (the hardest stress test, 30 rounds/32-40 players, and
  800 arbiter-assigned-bye-heavy generated tournaments). When no legal
  pairing can exist at all — a genuine structural deadlock, not a search
  failure — the engine is supposed to raise
  `OpenPair.Pairing.NoValidPairingError` rather than emit a best-effort
  illegal result, matching bbpPairings' own `NoValidPairingException`.

  **That held up to ~5,500 rounds; it did not hold at 839,776 — and a
  100x-bigger sample is now the standing bar, not ~5,500.** The first
  100,000-tournament bye-rate run found **102 illegal rounds (0.012%)**:
  95 raised `ArgumentError` instead of either pairing correctly or
  raising the intended `NoValidPairingError`, 5 returned the wrong bye
  count, 2 returned a non-partition. The `ArgumentError` cases all
  reproduced on tiny fields (4-5 players) and shared one cause:
  `bye_assignee_score/2` built its bootstrap-matching edge list over
  `0..(n-2)`, and when exactly one player was left needing a bye
  (`n == 1`) that range was `0..-1` — Elixir's default step for a
  descending range walks `0, -1`, and `elem(arr, -1)` is an invalid
  index. **Fixed** with an `n <= 1` short-circuit, pinned down with a
  real regression test (`test/open_pair/bye_assignee_score_test.exs`,
  fails on pre-fix code, passes on the fix), and confirmed at the same
  scale the bug was found at: re-running the identical 100,000-tournament
  batch now shows **0 raised exceptions and 7 illegal rounds**, down from
  102 — the remaining 7 are the wrong-bye-count/non-partition cases,
  untouched by this fix, still open (see TODO.md; 4 of the 5 dumped
  `[]`-result cases turned out to share one shape — every active player
  in the field already pre-byed for the exact round being paired, a
  fuzz-harness-generated degenerate input rather than confirmed a real
  engine bug — one, `seed4385-r5-p4.trf`, has real prior history and is
  a genuine confirmed-open bug). The moral for this README stands either
  way: "0 illegal rounds" was true at every sample size tested until it
  was tested at 100x the previous scale, which is the actual argument
  for testing at 100x the previous scale — repeatedly, not once.
- **Three engines, not two** — `three_way_comparison_test.exs` runs
  bbpPairings, Gacrux and OpenPair on identical positions. Over 3352
  rounds the two references agreed with each other on **every one**, which
  bounds their true disagreement at ~0.09% and makes them a usable ruler
  for an engine at 98.6%. It also shows there is no ambiguity left to hide
  behind: of the 47 rounds where OpenPair differed, all 47 had the
  references agreeing, so every remaining disagreement is OpenPair being
  wrong rather than a rules-interpretation tie.
- **How the remaining gap is worked on**: diagnostics rather than
  guesswork, all in the repo. `failure_taxonomy_test.exs` classifies
  every disagreement by the first bracket where the engines part company
  and why; `tools/adjudicate.exs` then scores BOTH answers with OpenPair's
  own C1-C21 ladder, so each case comes back as "our search failed", "our
  ladder is wrong", or "the criteria genuinely tie". That pair of tools is
  what found the defects worth 90.29% -> 98.69%.
- **bbpPairings is run directly, not just read as source** —
  `test/support/bbppairings.ex` + `bbppairings_comparison_test.exs`.
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
