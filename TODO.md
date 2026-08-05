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
2. ~~**Bracket cascade for later rounds.**~~ **Real progress, real
   remaining gap, quantified — not "mostly done"** —
   `OpenPair.Pairing.pair_later_round/1`. Forms score brackets (Art. 1.2:
   score desc, TPN asc) and pairs each via `OpenPair.Matching`'s general
   (non-bipartite) maximum-weight matching-with-floats (memoized bitmask
   DP), scored by `pair_weight/2` (legality, colour-preference
   satisfaction, rank spread) and `float_weight/1` (deeply negative so
   pairing always beats floating; strongly penalises re-floating a player
   who already floated into this bracket from a higher one — see below).

   **Four real, evidence-driven revisions got here — read in order if
   this section goes stale, since each fixed a genuine bug a real
   `javafo.jar` comparison run (`test/open_pair/javafo_comparison_round2_test.exs`
   — pairs round 1 for real, simulates results, asks both engines to pair
   round 2 from identical history) caught in the PREVIOUS one:**

   1. *Unrestricted exhaustive search, no colour scoring* — failed
      consistently (0/10). Hand-traced 18-player case (seed 3): a
      same-score bracket with zero rematch conflicts still didn't match
      javafo.jar — javafo picked the pairing where every pair had
      complementary colour preferences (one wants white, one black, from
      round-1 colours), over an equally rematch-legal one that didn't.
      Colour preference decides pairing composition, not a step applied
      after composition is fixed.
   2. *Unrestricted exhaustive + colour scoring* — seed-3 fixed, but the
      search re-explored the same subsets with no bound (confirmed 194ms
      at 12 players, didn't finish in 60s at 16 in a real comparison run).
   3. *Bipartite reformulation* (S1 better-half vs S2 worse-half, solved
      as bipartite matching — same structure round 1 uses) — fixed the
      hang, but was **confirmed WRONG at scale**: only 10.7% matched over
      2000 random histories, including a regression on the seed-3 case
      that matched exactly in revision 2. Cloning bbpPairings locally
      (`AuroraRyunix/bbpPairings-source`, independent/open/Apache-2.0) and
      reading `swisssystems/dutch.cpp` explained why: it computes a
      weight for ANY two compatible players (Edmonds' Blossom algorithm
      over the whole field), using bracket/S1-S2 membership as a WEIGHTED
      BONUS in that computation, never a hard structural exclusion. The
      bipartite restriction was a real modelling mistake, not a
      simplification.
   4. *General (non-bipartite) matching, kept tractable via memoization*
      (current) — restores correctness (2000-history re-run: 51.7%, up
      from 10.7%) without reintroducing the unbounded-search hang, at the
      cost of being exponential in the WHOLE bracket size again (not half,
      unlike revision 3) — see `OpenPair.Matching`'s moduledoc for the
      actual complexity trade-off and where this could still be slow. The
      SAME 2000-history run's remaining disagreements pointed at one more
      concrete gap: two engines can agree a player must float down two
      bracket levels in the same round, yet pick a *different* one to do
      it — javafo strongly prefers floating a bracket's own fresh
      resident over re-floating a player who already floated once this
      round (an MDP), matching bbpPairings' own "minimise downfloaters"
      criterion. `cascade_brackets/3` now stamps `:already_floated` on a
      bracket's own unpaired players before they enter the next bracket,
      and `float_weight/1` penalises that flag heavily. Confirmed fixed on
      the specific case that surfaced it (seed 15); **not yet re-run at
      scale as of this writing** — do that before trusting a match-rate
      number for this revision.

   Also fixed a real pre-existing bug the seed-3 investigation surfaced
   (revision 1): `colour_preference/1` and `assign_colour_with_history/1`
   were matching atoms (`:white`/`:black`) against `OpenPair.Trf`'s actual
   `"w"`/`"b"` string convention — colour history was *silently never
   applied* before this, every decision quietly falling through to the
   round-1 fixed convention.

   **Known remaining gap, found but not fully understood yet**: even
   after the MDP fix, one seed-15 sub-case with TWO fully
   colour-preference-satisfying candidate pairings picked the "wrong"
   one — javafo chose the smaller-total-rank-spread option
   (`|3-8|+|9-12|=8`) where this project's widest-spread tie-break chose
   the larger one (`|3-9|+|8-12|=10`). That looked like evidence the
   "prefer widest spread" rule (extrapolated from round 1's own confirmed
   top-half-vs-bottom-half behaviour, never independently verified for
   later-round tie-breaking) was simply wrong — **but a follow-up,
   deliberately isolated 8-player test (no floaters, no merged bracket,
   just one clean same-score bracket with the exact same "two fully
   colour-satisfying options at different spreads" shape) showed javafo
   choosing the WIDER-spread option, confirming the rule instead of
   refuting it.** So the seed-15 disagreement isn't explained by the
   spread rule being wrong — it's something specific to that case (most
   likely an interaction with the MDP float penalty just added, since
   seed-15's bracket included a floater and the isolated test
   deliberately didn't) that hasn't been isolated yet. Needs its own
   follow-up test (a clean bracket WITH a floater, controlling for
   spread the same way) before touching `pair_weight/2`/`float_weight/1`
   again — don't guess a fix for a cause that hasn't been confirmed.
   Do not claim round-2+ matches `javafo.jar` at scale until re-run and
   confirmed with real numbers, not this section's prose.
3. **Absolute criteria [C1]-[C5] not yet fully covered.** No-repeat
   pairing is enforced (`legal_pair?/2`); no-second-bye, topscorer-colour
   clash, and bye-assignee-score-minimisation are not.
4. **The seed-15-style disagreement above** — see item 2's "known
   remaining gap" note. Needs isolating whether it's an MDP-float
   interaction or something else before attempting a fix.
5. **Colour allocation & floater history refinement** — Article 5.2's
   full preference-strength computation (currently a simple
   alternate-from-last-game rule, see `assign_colour_with_history/1`'s
   doc) and Art. 1.9's absolute colour-difference rules aren't implemented.
6. **RTG (`-g`) and Checker (`-c`) modes** — JaVaFo's own two auxiliary
   roles, used for FIDE's FE1 endorsement auto-test (a checker doesn't need
   a search at all, "just" a verifier against every criterion above, so
   this could plausibly land before stage 3 finishes if useful sooner).
7. **Team pairing.** Depends on OpenPairings' own team-tournament work
   landing first (see that project's `TODO.md`) — team-level Swiss/
   round-robin scheduling, then per-board pairing within a scheduled match.
8. **Acceleration variants beyond Baku**, alternate tiebreak orderings —
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
