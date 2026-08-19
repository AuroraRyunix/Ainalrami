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

- [ ] **The last 1.5–2×.** Per-operation cost on work the reference does
      too — tree growth, the per-stage inner–outer rebuild, formation —
      on 450-bit weights. Two things would move it, neither tried:
      narrower weights (six score-place rungs are 300 of the 450 bits —
      a question about the criteria, not the matcher), and carrying the
      alternating forest across stages instead of relabelling, which is a
      different algorithm from the reference's. "Fewer solves per
      bracket" is closed: one of 124 solves changed nothing.

## Harness

The corpus is large but not wide. Each of these is a dimension it holds
constant — which is the failure mode that let a real bug survive 2.5
million tournaments (see [docs/validation.md](docs/validation.md)).

- [x] ~~TRF `260` / `250`~~ **implemented 2026-08-18.** They were listed as
      "deliberately absent rather than stubbed"; absent meant silently
      discarded, so a `260` exclusion produced a legal-looking round that
      seated the excluded pair. Verified happening, then fixed, with every
      case checked against the real binary.

      Still not generated by the fuzz harness — the axis exists only as
      unit tests. Worth adding if `260`/`250` files ever turn up in
      practice; `XXP`/`XXA` remain the forms the sibling project emits.
- [ ] Team tournaments
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

- [ ] **File the bbpPairings C2 report.**
      [docs/bbppairings-c2-bug-report.md](docs/bbppairings-c2-bug-report.md)
      is written and submittable; it has not been submitted.
- [ ] **Decide what to do with the 5.2.5 dispute.**
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
