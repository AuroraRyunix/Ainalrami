# TODO / Roadmap

## Done

- ~~Project scaffold~~ — mix.exs (escript config), `.formatter.exs`,
  `.gitignore`.
- ~~TRF16/TRF06 file I/O~~ — `OpenPair.Trf`, ported from OpenPairings'
  `PairingsEngine.Trf` (same author, pure module, no Phoenix/Ecto
  dependency to strip). Carries over two real bugs that project found and
  fixed against FIDE's actual archived specs (Annexure-B/2006,
  Annexure-C/2016): the `allow_dangling_playing_code` TRF06 tolerance, and
  `parse_games/1` not stopping at a genuinely blank round. 27 ported tests,
  all passing here too.
- ~~Verbose logging infrastructure~~ — `OpenPair.Log`. Verbose is the
  default (not opt-in), `-q`/`--quiet` suppresses it. `step/1`/`detail/1`
  to stdout, `warn/1`/`error/1` always to stderr regardless of quiet mode.
- ~~CLI skeleton~~ — `OpenPair.CLI`, mirroring JaVaFo's real invocation
  shape (`input.trf -p [output.trf]`, `-g`, `-c`). `-p` on a fresh
  round-1 roster (no game history) actually pairs it now — writes the
  same shape JaVaFo's own output file uses (count line, then
  `white black`/CRLF per pair, `0` for a bye). `-p` on a roster that
  already has history correctly reports "not implemented yet" (exit 2)
  instead of guessing — later-round pairing doesn't exist yet.

## Next: the actual Dutch-system pairing algorithm

This is the real work — everything above is plumbing. Staged so each piece
is independently correct and tested before the next depends on it, rather
than attempting the whole engine in one pass. **Every stage that touches an
actual FIDE rule needs the primary-source handbook text in hand before
writing it** — not memory, not a paraphrase. OpenPairings hit two real bugs
this exact way (Art. 16.4's dummy-score formula, the TRF06 bye convention)
specifically from trusting a plausible-sounding but unverified rule
description; don't repeat that here for something as central as the pairing
logic itself.

1. ~~**Roster split & round 1.**~~ **Done** — `OpenPair.Pairing.pair_round_one/1`.
   Rank order, top-half-vs-bottom-half pairing, odd field's lowest rank
   gets the bye. Colour: Article 5.1's "drawing of lots" has no
   deterministic rule to replicate — confirmed empirically (not assumed)
   that JaVaFo's own initial-colour choice isn't a function of roster/round
   count alone (identical roster + round count under two different
   tournament *names* produced opposite colours from JaVaFo, strong
   evidence of a hash-seeded, non-reproducible-by-us choice) — so this uses
   its own fixed, documented, spec-legal convention instead.

   **Verified against real `javafo.jar`, not just unit-tested against our
   own expectations**: `test/open_pair/javafo_comparison_test.exs`
   (`OpenPair.Test.Javafo`, gated `:javafo`, jar not vendored — see that
   module's doc) generates random rosters (2-60 players) and diffs pairing
   *composition* (colour-blind) against real JaVaFo output, in parallel.
   100% match at 2,000 random rosters; a 100,000-roster run's result
   belongs here once it finishes (was still running when this was last
   updated — check the test output / re-run to confirm current status).
2. **Absolute criteria [C1]-[C5]** (per OpenPairings' own C.04.3 audit —
   see its `docs/fide-endorsement.md`): no-repeat pairing, no-second-bye,
   topscorer-colour-clash, bye-assignee-score-minimisation. These are hard
   constraints — a legal pairing can never violate them.
3. **Quality criteria [C6]-[C21] + the bracket-cascade search.** Downfloat
   minimisation and the rest, applied bracket-by-bracket (Art. 1.9.1,
   3.3.2) with backtracking when a bracket has no legal completion. This is
   where the actual combinatorial search lives, and where OpenPairings'
   fuzz harness already caught JaVaFo and bbpPairings disagreeing on at
   least one real case — expect this stage to surface genuine ambiguity,
   not just bugs.
4. **Colour allocation & floater history** across rounds (not just within
   one bracket) — Art. 1.9's absolute colour-difference/preference rules.
5. **RTG (`-g`) and Checker (`-c`) modes** — JaVaFo's own two auxiliary
   roles, used for FIDE's FE1 endorsement auto-test (a checker doesn't need
   a search at all, "just" a verifier against every criterion above, so
   this could plausibly land before stage 3 finishes if useful sooner).
6. **Team pairing.** Depends on OpenPairings' own team-tournament work
   landing first (see that project's `TODO.md`) — team-level Swiss/
   round-robin scheduling, then per-board pairing within a scheduled match.
7. **Acceleration variants beyond Baku**, alternate tiebreak orderings —
   the actual point of building a second engine in the first place, per
   the original "too many gimmicks" / "hard pairing variants" discussion in
   OpenPairings.

## Cross-validation against bbpPairings

Explicit ask, not optional polish: **fully parse and fuzz-test against
bbpPairings** (Bierema Boyz Programming's independent, Apache-2.0-licensed
Dutch-system implementation, already vendored in OpenPairings at
`priv/bbppairings/` for its own `cross_program_test.exs` harness). Port that
same pattern here once stage 1-3 above produce real pairings:

- Generate synthetic rosters/histories (`StreamData` property-style, same
  approach as OpenPairings' `trf_property_test.exs`).
- Pair each one with both OpenPair and bbpPairings on byte-identical TRF16
  input.
- Diff every round's actual pairing, not just final legality — a
  same-score-group-splitting disagreement (the exact class of thing the
  OpenPairings/JaVaFo/bbpPairings harness already found) is the
  interesting signal, not a crash.
- Treat a disagreement as a research question first ("which one, if
  either, is actually right per the current Handbook text"), not an
  automatic bug in OpenPair — bbpPairings and JaVaFo don't always agree
  with each other either.

Once OpenPair is wired back into OpenPairings as a selectable engine, this
harness should run as a *third* comparison arm there too, not just
standalone here.

## Explicitly deferred / not being pursued yet

- Any FIDE endorsement application for OpenPair itself. It's meant to stay
  a non-default, non-homologated-tournament-only option inside
  OpenPairings, at least until (if ever) it's genuinely proven out — see
  the endorsement-risk discussion in OpenPairings' own project history.
- A license file / open-source release. Undecided.
