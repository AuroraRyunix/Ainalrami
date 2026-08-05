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
  shape (`input.trf -p [output.trf]`, `-g`, `-c`). `-p` calls the real
  pairing engine now (round 1 or the bracket cascade, whichever applies),
  writing the same shape JaVaFo's own output file uses (count line, then
  `white black`/CRLF per pair, `0` for a bye).

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
   100% match at 5,000 random rosters; a 100,000-roster run's result
   belongs here once it finishes (was still running when this was last
   updated — check the test output / re-run to confirm current status).
2. ~~**Bracket cascade for later rounds.**~~ **Mostly done, with real,
   documented gaps** — `OpenPair.Pairing.pair_later_round/1`. Forms score
   brackets (Art. 1.2: score desc, TPN asc). Within a bracket, splits into
   S1 (better half by rank) vs S2 (worse half) — the same structural
   pairing shape round 1 uses, confirmed against bbpPairings' own source
   to be the real one (see below), not a guess — and solves it as a
   maximum-weight *bipartite* perfect matching (`OpenPair.Matching`,
   bitmask DP), rather than an unrestricted search over the whole bracket.
   An unpairable bracket floats players down into the next one, trying
   the worst-ranked combination first but searching other floater choices
   when that specific one has no legal completion (see
   `try_float_count/2`'s doc for why a *fixed* worst-N floater set isn't
   always enough).

   **This went through two real, evidence-driven revisions before landing
   here — worth reading in order if this section goes stale, since each
   fixed a genuine bug the previous version's own test/fuzz run caught:**

   - *Revision 1 (exhaustive, unrestricted, no colour scoring)*: a round-2
     comparison harness (`test/open_pair/javafo_comparison_round2_test.exs`
     — pairs round 1 for real, simulates results, asks both engines to
     pair round 2 from identical history) failed consistently (0/10).
     Root-caused with a hand-traced 18-player case (seed 3): a same-score
     bracket with *zero* rematch conflicts still didn't match javafo.jar's
     composition — javafo picked the pairing where every pair had
     complementary colour preferences (one wants white, one black, from
     round-1 colours) over an equally rematch-legal one that didn't.
     Colour preference is a criterion that decides pairing composition,
     not a separate step applied after composition is fixed.
   - *Revision 2 (exhaustive + colour scoring, still unrestricted)*: added
     colour preference as a real scoring criterion and confirmed the
     seed-3 case now matches exactly. But this revision's search
     considered ANY two players in a bracket as a valid pair (not
     respecting an S1-vs-S2 split), and — separately — a real `javafo.jar`
     comparison run hung: the search re-explored the same subsets
     repeatedly with no bound, confirmed empirically to take 194ms at 12
     players and not finish within 60 seconds at 16.
   - *Revision 3 (current)*: cloned bbpPairings locally (an independent,
     open, Apache-2.0 FIDE Dutch-system implementation —
     `AuroraRyunix/bbpPairings-source`) and read `swisssystems/dutch.cpp`
     rather than keep guessing. It models an entire round as one global
     maximum-weight matching over all players (Edmonds' Blossom
     algorithm), every criterion bit-packed into one priority-ordered edge
     weight, including colour preference (`insertColorBits`) — confirming
     colour genuinely belongs in the weight function, and that real
     implementations don't restrict pairing to a literal per-bracket
     S1-vs-S2 split in general (heterogeneous/MDP handling can cross it).
     Porting that whole architecture (general graph max-weight matching +
     the full bit-packed criteria list) is a much bigger undertaking than
     this project has done so far, so the fix taken is narrower and
     restricted to the common (homogeneous, non-MDP) case: reformulate
     each bracket's pairing as *bipartite* S1-vs-S2 matching, which turns
     the same search into a polynomial problem (`OpenPair.Matching`,
     O(k · 2^k) in HALF the bracket size, not the whole thing) instead of
     an unbounded one. Confirmed this didn't just move the bug: a test
     that legitimately requires floating a *specific* single player
     (not simply "the worst-ranked N") caught the first version of this
     fix being too rigid (it only ever tried the literal worst-N floaters)
     — `try_float_count/2` now searches floater combinations, worst-first,
     until one yields a legal S1-vs-S2 matching.

   Also fixed a real pre-existing bug the seed-3 investigation surfaced:
   `colour_preference/1` and `assign_colour_with_history/1` were matching
   atoms (`:white`/`:black`) against `OpenPair.Trf`'s actual `"w"`/`"b"`
   string convention — colour history was *silently never applied*
   before this, every decision quietly falling through to the round-1
   fixed convention.

   **Re-verified**: the seed-3 case matches javafo.jar exactly,
   composition and colour; performance at a fully-tied 40-player single
   bracket (the worst realistic case) dropped from "doesn't finish in 60s"
   to ~13.5s, and smaller/more realistic brackets are sub-second. Re-run
   the harness at real scale (`PAIRING_FUZZ_COUNT=...`) and record the
   actual match rate here — not done yet as of this writing. This still
   isn't bbpPairings'/JaVaFo's real algorithm (bipartite per-bracket, not
   a single global weighted matching over the whole field with the full
   FIDE criteria list encoded) — expect more gaps to surface at scale,
   most likely around heterogeneous/MDP brackets (where a real
   implementation's pairing can cross the S1/S2 split this version
   assumes) and float-history criteria (not implemented at all). Do not
   claim round-2+ matches `javafo.jar` at scale until re-run and confirmed.
3. **Absolute criteria [C1]-[C5] not yet fully covered.** No-repeat
   pairing is enforced (`legal_pair?/2`); no-second-bye, topscorer-colour
   clash, and bye-assignee-score-minimisation are not.
4. **MDP-vs-resident pairing in heterogeneous brackets.** This project's
   bipartite S1-vs-S2 reformulation doesn't special-case a bracket formed
   from floaters + a new score group the way bbpPairings'/JaVaFo's global
   matching can (Articles 3.3.1/3.3.3) — see item 2 above.
5. **Colour allocation & floater history refinement** — Article 5.2's
   full preference-strength computation (currently a simple
   alternate-from-last-game rule, see `assign_colour_with_history/1`'s
   doc) and Art. 1.9's absolute colour-difference rules aren't implemented.
6. **RTG (`-g`) and Checker (`-c`) modes** — JaVaFo's own two auxiliary
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
