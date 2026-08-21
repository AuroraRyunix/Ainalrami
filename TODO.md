# TODO

Open work only. The history — including everything closed, and the changes
that looked obviously correct and measured *worse* — is in
[docs/engineering-log.md](docs/engineering-log.md).

## Conformance

Both of the gaps carried here are now closed — 4.3 against the article
itself, 5.2.5 against the handbook and AGAINST both reference engines.
What is left is one limit of method rather than a known divergence.

- [x] ~~**Article 4.3, including the heterogeneous case.**~~ **Closed
      2026-08-17/18** by `exchange_order_test.exs`, which walks Article 4's
      sequence with `Ainalrami.Sequence` and confirms the engine returns
      the earliest-generated best candidate: on a position where exchanges
      are the only route to a legal pairing, over forty random single-score
      brackets, and on a heterogeneous bracket where 3.7 alters the
      remainder before the MDP-Pairing.

      The trick for the heterogeneous case was making the bracket the
      **last** one. Nothing below it means no candidate reaches an edge
      into a lower group, so every candidate contributes the same edges and
      the rung vectors are commensurable — which is what the earlier
      "incommensurable structures" objection was really about.

- [ ] **A bracket in the MIDDLE of a round**, inheriting moved-down players
      *and* floating players onward, is still compared only through the
      corpus. Not a known divergence — a limit of the method. Closing it
      needs a way to compare candidates that float different players, and
      the regulations define no ordering over those; see
      [docs/conformance-c0403-2026.md](docs/conformance-c0403-2026.md).

- [x] ~~**Article 5.2.5 — which number the parity applies to.**~~
      **Settled 2026-08-17, in this engine's favour, from the handbook.**
      C.04.2 Article 2 fixes a TPN for the tournament; nothing renumbers
      it around players sitting a round out. Both references renumber
      anyway -- around players who have never participated, measured both
      ways with `tools/rip_probe.exs`, and they agree with each other.

      Now a filed dispute rather than an open question:
      [docs/dispute-initial-colour.md](docs/dispute-initial-colour.md).
      Gacrux did not break the tie — it renumbers too. What broke it was
      reading C.04.2, which nobody had done.

## Performance

- [x] ~~**Implement the incremental caches.**~~ **Done 2026-08-18** — and
      then most of the rest of the reference's bookkeeping with it. One
      round of 209 players went **90 s → 9.5 s** and 400 players
      **498 s → 69.8 s**.

- [x] ~~**The remaining 24× at 400 players.**~~ **Closed 2026-08-19: it
      was structural, not per-operation.** 209 players **9.2 s → 1.24 s**,
      400 players **69.8 s → 4.5 s**; bbpPairings 0.67 s / 2.9 s, so
      **1.9× and 1.5×**, from 14× and 24×. Every step held to 100.00% on all
      six corpus axes and both nets, 200/200 boards identical at 400.

      What it was, in order of effect: the resumed solves prepared the
      lower-indexed end of each changed edge instead of the MODIFIED
      vertex (`computer.cpp:69` — cost is O(k n²) in the number of
      modified vertices, and `finalize_pair` was making k the bracket
      rather than three); cold solves ran a hundred stages where a greedy
      tight start leaves seven exposed vertices; every bracket rescored
      and diffed the whole field where the reference scores
      `playersByIndex` and sets far edges once; the far edges all tied,
      so every stage's alternating forest spanned the field (a nearness
      term below every criterion leaves it local); and blossom formation
      rebuilt a k² cross table that is now merged by rows; and a resumed
      solve now starts, like a fresh one, from a greedy tight matching of
      the prepared vertices, which pairs most of a bracket before a stage
      runs. Full table in
      `docs/engineering-log.md`, "Matcher performance, 2026-08-19".

      Recorded there too: yesterday's note that nested cross rows lose to
      a flat map was locally right and globally wrong; the transposition
      tie-break is off by default (`AINALRAMI_TRANS=1` restores it) after
      measuring inert again; the `:atomics` spike had been committed
      alongside the note reverting it and is now actually reverted (equal
      speed, no mutable-array hazard).

- [x] ~~**A 1,000-player round is 85 s.**~~ **7.3 s as of 2026-08-19
      evening** -- faster than bbpPairings' 50 s, within 2.5 s of
      Gacrux's 5.1 s, identical 500 boards. A bracket is now solved on
      its own graph whenever that is provably the whole-field answer
      (`pair_bracket/6`, with the argument in its comment and in
      docs/engineering-log.md "The local graph"); odd brackets get a
      one-vertex stand-in for the next group. The window-graph attempt
      that preceded it is recorded there too, reverted at 99.34%.

- [ ] **The last 2.5 s at 1,000 players, and the one uncertified
      condition.** What remains is on 200-vertex graphs: the cold solve
      of each bracket's own graph (the greedy start pairs half), the
      stage-4 re-solve (every remainder vertex prepared, matching
      rediscovered), and the stage-8 per-pair solves. A smarter warm
      start for stage 4 -- it almost always returns the stage-3 matching
      -- is the obvious lever. And `@local_min_next_group` (16) is the
      one condition on the local path not certified term by term: that
      an odd bracket's float choice does not depend on which member of a
      dense next group it lands on. The 5M run on the final engine is
      its judge; if it ever disagrees, the fix is to raise the threshold
      or certify the group's matching number directly.

- [x] ~~**The last 1.5–2× at 209-400 players.**~~ **Overtaken 2026-08-19
      evening**: 209 players 0.37 s against the reference's 0.72 s, 400
      players 1.33 s against 3.05 s -- the local graph, above. The
      per-operation levers recorded here are now **measured and mostly
      closed** — see the engineering log, "Where the remaining time goes,
      and three levers that do not move it" (2026-08-21).

      Narrower weights is DEAD: the weights are 512 bits, narrowing the
      spans to bracket size saves ~31 of them (eight limbs either way),
      and a tuple of small integers loses to one bignum add (120 ns vs 21
      machine-word adds plus an allocation). The packed bignum is already
      the right representation, which is the opposite of what this note
      used to assume.

      Parallelism is DEAD too, for the record, since it is the obvious
      idea on the BEAM: the per-pair solves thread the solver state
      through a strict reduce and brackets cascade floats top-down, so
      both are sequentially dependent by construction.

      Carrying the forest across stages remains untried. So does the one
      lever with order-of-magnitude potential, which is not on the matcher
      at all: Article 3's transposition procedure as a fast path, with
      this matcher as fallback. "Fewer solves per bracket" stays closed:
      one of 124 solves changed nothing.

## Harness

The corpus is large but not wide. Each of these is a dimension it holds
constant — which is the failure mode that let a real bug survive 2.5
million tournaments (see [docs/validation.md](docs/validation.md)).

- [x] ~~TRF `260` / `250`~~ **implemented 2026-08-18.** They were listed as
      "deliberately absent rather than stubbed"; absent meant silently
      discarded, so a `260` exclusion produced a legal-looking round that
      seated the excluded pair. Verified happening, then fixed, with every
      case checked against the real binary.

      **Now generated too (2026-08-21)**, behind
      `PAIRING_FUZZ_NUMERIC_EXT=1`, and it was worth it: handing the real
      binary a `250` we wrote found two bugs the unit tests could not.

      Our parser reads every `250` field one column WIDER than
      `readAccelerations250` does — the C++ reads half-open 0-based
      ranges with a blank separator between fields. Harmless reading (the
      separator trims away), fatal writing: the digit lands in the
      separator and the binary rejects the line. Same shape as the `XXA`
      column bug. The parser is left as it is on purpose — correct for
      every well-formed file, and exercised by the whole corpus.

      And `XXP` has no round limit while `260` must state one, so bounding
      it at `number_of_rounds` lets the ban expire on the round being
      paired. Both files parse cleanly; the only symptom is the two
      spellings pairing differently.

      150 tournaments / 7,338 pairings at 100.00% since. `XXP`/`XXA`
      remain the default and the forms the sibling project emits.
- [ ] **Team tournaments (C.04.6).** Spec read and written up in
      [docs/conformance-c0406-teams.md](docs/conformance-c0406-teams.md)
      before any code, 2026-08-21. Three findings that change the shape of
      the work:

      It is NOT the Dutch engine applied to teams. C.04.6 has its own
      criteria (C1-C3 absolute, C4-C10 quality — nine rungs against
      twenty-one) and, crucially, its own procedure: Article 3.6 defines an
      identifier, orders pairings lexicographically by it, and takes the
      FIRST satisfying C1/C8/C9/C10. An order and a predicate, not a
      scoring function — so `WeightedMatching` is not involved in choosing
      a pairing at all, only in certifying [C3] completability.

      NO reference implementation pairs teams. Checked: bbpPairings has no
      team code, JaVaFo and Gacrux are individual-only, and SWAR's own
      `Pairing*.cpp` has none either. The corpus method that made the
      individual engine trustworthy is unavailable. The regulation hands
      back something stronger though: 3.6 defines the answer AS the head of
      an enumerable order, so for small brackets a test can BE the
      definition — enumerate, sort, filter, assert the head. That is a
      proof rather than a correlation, and it is the opposite of the
      individual system, where exhaustive verification is impossible in
      principle.

      Article 4.3.1 is the SAME TPN-parity rule as the individual 5.2.5,
      which is currently an open question to the SPP. Team colour
      allocation should wait for that reply or it gets built twice.
- [x] ~~Late entrants~~ **not a distinct axis either** (2026-08-17). A
      blank early round is indistinguishable from a zero-point bye
      everywhere the engine looks — same points, same
      `participated_in_pairing?/1`, same float direction under 1.4.3, same
      C2 eligibility — so a generated axis would re-run the arbiter-bye
      axis under another name. That is a consequence of four rules
      agreeing, so it is pinned in `late_entrant_test.exs` (with a
      half-point bye as the control) rather than merely concluded.

      What is genuinely not modelled is C.04.2 **2.5**: TPNs are
      provisional until the participant list closes, so a real late entry
      can renumber the field. This engine takes TPNs as given and never
      assigns them, so that belongs to the caller.
- [x] ~~Files where `142` disagrees with `XXR`~~ **done 2026-08-17.** They
      are the same field; disagreement is now refused rather than silently
      resolved, because every implementation resolved it differently and
      the loser is a wrong final round nothing downstream can detect.
- [x] ~~Unrated players~~ **not an axis.** `fide_rating` never reaches
      `Ainalrami.Pairing` at all — the Dutch system runs on TPN, score and
      colour history, and the initial ranking is given in the file rather
      than derived. Checked rather than assumed; recorded so it is not
      re-proposed.

## Diagnostics

- [x] ~~**A CLI explain mode.**~~ **Done 2026-08-21.** `explain_round/3`
      had been library-only since the adjudicator needed it, so a host
      application could pair with this engine and then had to reconstruct
      the reasoning from the finished boards — an inference, when the
      engine had already computed the thing itself. `ainalrami input.trf
      -x` now reports, per bracket, who moved down, who lives there, what
      was paired, who floats on, and which criteria actually scored.

- [x] ~~**Re-run the adjudication tables.**~~ **Cannot be, and no longer
      needs to be** (checked 2026-08-18). They were produced while
      `explain_round/3` stamped no float history, so C14–C21 scored a
      constant on both sides of every verdict — which could misattribute a
      disagreement but never invent one.

      Re-running them is impossible: they catalogue 40 disagreements, 39 of
      which were one missing field in the bootstrap matching and no longer
      occur at all. There is no position left to re-score. The single
      survivor, `seed735265-r7-p10`, IS kept as a fixture and HAS been
      re-adjudicated with the fixed instrument — twice, in fact, since the
      `edge_count` guard later changed its verdict from
      `theirs_scores_better` to `incomparable`.

      So the tables stand as history, with the caveat already recorded
      beside them. Nothing to do beyond not trusting their "first differing
      rung" column below C14.

## Upstream

- [x] ~~**File the bbpPairings C2 report.**~~ **Filed 2026-08-21.**
      [docs/bbppairings-c2-bug-report.md](docs/bbppairings-c2-bug-report.md)
      is written and submittable; it has not been submitted. **Now rests on
      THREE independent positions** (2026-08-20), from three different
      generator axes and two seed ranges, with Gacrux returning our answer
      board-for-board on all three. Two of them need no scoring argument
      at all: the round has exactly one legal shape, because a player who
      already holds a bye is down to a single legal opponent, and
      bbpPairings pairs that opponent elsewhere. `seed7073463-r8-p9`
      reaches it through a chain of four such players. That every
      disagreement in a multi-million-tournament corpus is the same rule
      in the same direction is itself evidence: one defect, narrow
      trigger, not scattered edge cases.
- [x] ~~**Decide what to do with the 5.2.5 dispute.**~~ **Raised with the
      SPP, 2026-08-21**, awaiting a reply.

      The question changed shape first, and for the better. C.04.3 was
      rewritten on 1 February 2026: the old Article E.5 tested the parity
      of a "pairing number", which A.2 defined as the initial ranking "and
      subsequent modifications", while the new 5.2.5 tests a TPN and
      Article 1.1 delegates that wholly to C.04.2 Article 2 — which allows
      exactly two modifications and distinguishes nowhere between a player
      who has played and one who has not.

      And JaVaFo, which PREDATES the rewrite, renumbers exactly as
      bbpPairings and Gacrux do. So this is not two implementations
      independently misreading a 2026 sentence; it is pre-2026 behaviour
      carried forward into engines claiming the 2026 rules, which inverts
      the strongest argument against this engine's reading. Three
      implementations agreeing was evidence; shared lineage is not.

      Letter in [docs/spp-question-initial-colour.md](docs/spp-question-initial-colour.md).

      [docs/dispute-initial-colour.md](docs/dispute-initial-colour.md) is
      written. It is the stronger of the two cases — it rests on a
      definition quoted verbatim from C.04.2 rather than on an argument
      about one position — and it affects two reference implementations at
      once, which is worth weighing before raising it.

## Deferred, deliberately

- **A FIDE endorsement application for Ainalrami itself.** The error ratio
  stopped being the obstacle some time ago. What remains is strategic:
  declaring "Internal engine: YES" on FE1 means owning pairing correctness
  rather than inheriting JaVaFo's endorsement, with two-week and two-month
  mandatory fix windows attached.
