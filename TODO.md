# TODO

Open work only. The history — including everything closed, and the changes
that looked obviously correct and measured *worse* — is in
[docs/engineering-log.md](docs/engineering-log.md).

## Conformance

Two gaps against C.04.3 (2026). Neither has produced a measured pairing
disagreement in 4.3M tournaments, and both are real anyway: "not observed"
is not "cannot happen", and these are the only two places left where a
disagreement could come from.

- [ ] **Article 4.3 — exchange ordering.** 4.2's transposition order is
      proven identical to `transposition_key/3` and tested. 4.3's exchange
      order has no equivalent ranking: those candidates are all considered
      by the matcher, but tied ones are not ordered by generation.

      `Ainalrami.Sequence` already implements Article 4's ordering and is
      checked against the article's own worked examples, so the oracle
      exists. What does not exist is the differential test using it.

      **It has to run per bracket.** The round-level version was built and
      thrown away: the ladder is defined per bracket, bracket composition
      depends on which players a pairing floats, so two round-pairings
      produce different bracket structures whose rung vectors are not
      commensurable. That means wiring `Sequence` into the bracket loop,
      not around the round — real work, not a script. Reasoning in full in
      [docs/conformance-c0403-2026.md](docs/conformance-c0403-2026.md).

- [x] ~~**Article 5.2.5 — which number the parity applies to.**~~
      **Settled 2026-08-17, in this engine's favour, from the handbook.**
      C.04.2 Article 2 fixes a TPN for the tournament; nothing renumbers
      it around players sitting a round out. Both references renumber
      anyway, and differently from each other, so there was never a
      single "agreeing" behaviour to adopt.

      Now a filed dispute rather than an open question:
      [docs/dispute-initial-colour.md](docs/dispute-initial-colour.md).
      Gacrux did not break the tie — it renumbers too. What broke it was
      reading C.04.2, which nobody had done.

## Harness

The corpus is large but not wide. Each of these is a dimension it holds
constant — which is the failure mode that let a real bug survive 2.5
million tournaments (see [docs/validation.md](docs/validation.md)).

- [ ] TRF `260` / `250` — round-limited forbidden pairs and acceleration
- [ ] Team tournaments
- [ ] Unrated players
- [ ] Late entrants
- [ ] Files where `rounds_count` disagrees with `XXR`

## Diagnostics

- [ ] **Re-run the adjudication tables.** Those in the engineering log were
      produced while `explain_round/3` stamped no float history, so C14–C21
      scored a constant on both sides. The bug is fixed and covered by
      `explain_round_test.exs`; the tables are not re-run.

      They are not wrong about *whether* the engines differed — that comes
      from the harness, not the scorer — but the "first differing rung"
      column is only trustworthy where the winning rung outranks C14.
      Needs a fresh large fuzz, since the original dumps were never kept.

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
