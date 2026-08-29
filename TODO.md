# TODO

Open work only. The history - including everything closed, and the changes
that looked obviously correct and measured *worse* - is in
[docs/engineering-log.md](docs/engineering-log.md).

> **A whole-codebase sweep ran on 2026-08-26**; its findings are in
> [docs/sweep-2026-08-26.md](docs/sweep-2026-08-26.md) - 19 items for this
> repository. The engine core came back clean of confirmed logic bugs.
>
> **All thirteen bug-severity findings are fixed** (that document indexes
> them against their commits), along with two instrument fixes and the
> suite's last four compile warnings. Three turned out worse than the sweep
> had them: `points_for/2`'s two opponentless codes also decide C2 bye
> eligibility; `render/1`'s short line makes bbpPairings refuse the whole
> FILE, not the round; and `even_up_exposed_duals/1` was producing 734
> infeasible blossom duals per 800 nine-round tournaments while agreeing
> with the reference on all of them.
>
> Still open from the sweep's lower sections, and listed under Diagnostics
> and Harness below: the CLI's silently-ignored options, the three-way
> harness's missing colour instrument, and two optimizations.

## Conformance

4.3 is closed against the article itself. 5.2.5 was closed the wrong way:
the SPP ruled against this engine on 2026-08-27 and the engine has been
changed to match both references. What is left is one limit of method.

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
      the rung vectors are commensurable - which is what the earlier
      "incommensurable structures" objection was really about.

- [x] ~~**A bracket in the MIDDLE of a round**~~ - **narrowed 2026-08-21**
      by `mid_round_bracket_test.exs`, which checks REACHABILITY: the
      engine's answer for a middle bracket is a candidate Article 4's
      sequence actually generates. Previously corpus-only.

      Not the full claim, and cannot be: candidates floating different
      players are incommensurable and the rules define no ordering over
      them. But the engine solves a matching rather than walking 4.2/4.3,
      so "does it stay inside the enumeration at all" was an unchecked
      structural question, and it is now checked over 25+ real middle
      brackets per run.

      The oracle was wrong twice first, both times by being weaker than
      the engine - no remainder stage, then no exchanges in the remainder.
      Recorded in the conformance doc, since that is the failure mode this
      whole area keeps producing.

- [x] ~~**Article 5.2.5 - which number the parity applies to.**~~
      **Done 2026-08-27: settled AGAINST this engine by the FIDE SPP, and
      the engine changed.** The parity is taken on a numbering that skips
      players who have never been paired - what bbpPairings and Gacrux
      have always done. Ainalrami took it on the raw TPN, and was wrong.

      The crux is that both sides argued from the same sentence,
      C.04.2:2.4: a late entry is *"given an appropriate TPN and paired
      only when they actually arrive."* This engine read that as "the TPN
      exists before the arrival; it is the PAIRING that waits." The SPP
      reads the identical clause as "players who have yet to arrive don't
      have a TPN." We read it the wrong way round.

      The 2026-08-17 note below is preserved because it explains why the
      engine behaved this way for months, and why the question was worth
      asking. Its conclusion is superseded.

      > **Settled 2026-08-17, in this engine's favour, from the handbook.**
      > C.04.2 Article 2 fixes a TPN for the tournament; nothing renumbers
      > it around players sitting a round out. Both references renumber
      > anyway -- around players who have never participated, measured both
      > ways with `tools/rip_probe.exs`, and they agree with each other.
      >
      > Now a filed dispute rather than an open question:
      > [docs/dispute-initial-colour.md](docs/dispute-initial-colour.md).
      > Gacrux did not break the tie - it renumbers too. What broke it was
      > reading C.04.2, which nobody had done.

      The last sentence is the bitter one: C.04.2 *was* read, and read
      backwards. 2.4 is the clause both sides quoted.

      The corpus has NOT been re-run on the corrected engine. Every
      quoted 5.2.5 divergence count in this repo is expected to collapse
      to zero and none of it is measured yet.

## Performance

- [x] ~~**Implement the incremental caches.**~~ **Done 2026-08-18** - and
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
      vertex (`computer.cpp:69` - cost is O(k n²) in the number of
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

- [x] ~~**The one uncertified condition.**~~ **Judged 2026-08-21.**
      `@local_min_next_group` (16) - that an odd bracket's float choice
      does not depend on which member of a dense next group it lands on -
      was the one condition on the local path not certified term by term,
      and this note said "the 5M run on the final engine is its judge".

      bigrun5 was that run and then some: 5,993,000 tournaments on the
      final engine (`adae426`), 487,338,797 individual pairings, **zero
      disagreements**. The condition has been judged and it held.

- [x] ~~**The last ~7.7 s at 1,000 players.**~~ **Closed 2026-08-21**, with the lever tried and measured NEGATIVE. Optional, and recorded as
      such: the engine is already level with Gacrux and ~6x quicker than
      bbpPairings on pairing work, so nothing here is waiting on it.

      The old text under this heading was wrong in a way worth keeping
      visible. It said the cold solve's greedy start "pairs half"; it
      pairs **one pair** on every local bracket graph (992 of 1,000 on the
      FIELD graph, 2 of 206 on a local one). That is the whole 2.3 s cold
      solve: a local bracket reaches its optimum almost entirely through
      augmenting search, from an almost empty matching.

      The cause is the dual initialisation, not the greedy pass. `y_v`
      starts at `max_u w(v,u)/2`, so an edge is tight only when its
      endpoints are each other's heaviest - and the criteria make nearly
      every vertex in a bracket point at the same few top-ranked
      opponents. A star has one mutually-heaviest pair. Cross-bracket
      edges spread the maxima out, which is why the field graph is fine.

      That lever was then built and measured, and it makes the engine
      **twice as slow** (1,000 players 8.0 s -> 15.9 s). It is correct -
      same total weight and matched count on all 460 baseline graphs - and
      it loses anyway, for a reason worth keeping: the sequential dual
      cascades into an alternating 0/`w2` pattern, so the starting dual
      objective goes from 1.85e12 to ~1.4e170, and walking that down is
      the algorithm's whole job. It also barely buys tight edges (2 -> 4).

      The one-pair greedy start is therefore not a defect. It is what a
      symmetric feasible dual does on a star-shaped weight matrix, and
      being close to optimal matters far more than how many edges are
      tight. Anything better must raise the tight-edge count WITHOUT
      inflating the dual objective; there is no candidate. Reverted, and
      written up as "Dead lever 4" in the engineering log alongside the
      other three.

- [x] ~~**The last 1.5-2× at 209-400 players.**~~ **Overtaken 2026-08-19
      evening**: 209 players 0.37 s against the reference's 0.72 s, 400
      players 1.33 s against 3.05 s -- the local graph, above. The
      per-operation levers recorded here are now **measured and mostly
      closed** - see the engineering log, "Where the remaining time goes,
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

- [x] ~~**Re-run the corpus on the corrected engine.**~~ **Done 2026-08-28.**
      Paired against the figures it replaces - same nine axes, same seeds
      (95,000,001 onward): **750,449 rounds, 7,392,594 boards, zero colour
      differences** against bbpPairings, every axis 100.0% with nothing
      unexplained. The banked 64,131 are gone.

      An independent run on different seeds (32,000,001 onward, seven axes)
      agrees at larger scale: 1,065,373 rounds, 11,164,952 boards, also zero.

      Both controls held: the no-bye axes stayed at zero, and the two
      reference-against-reference boards survived on the same two axes,
      outside 5.2.5's reach. See
      [docs/validation.md](docs/validation.md#re-measured-2026-08-28-the-64131-are-zero).

- [x] ~~**Strengthen the three-way harness's `:reach` classifier.**~~
      **Done 2026-08-29.** The re-read of what it filed is still open and is
      folded into the superseded-count item below, since both want the same
      corpus run.

      `Ainalrami.Pairing.arrival_numbers/2` is public now - it is the article
      as the SPP ruled it, so exposing it is exposing a RULE rather than an
      internal, and it stops the harness keeping a fourth copy of the
      numbering in the test tree.

      The claim the harness makes is deliberately not "this board is right":
      that needs the initial colour, and Article 5.1 leaves it to a literal
      drawing of lots, so there is nothing to look up. It is that **every
      board a round decides by 5.2.5 must imply the SAME initial colour.** An
      engine whose round implies both has broken the article on at least one
      of them, whatever the constant was - which is a real conformance
      finding about a reference, computed from an agreed rule.

      `article_5_2_5_consistency/3` in `test/support/colour_article.ex`, ten
      unit tests in `test/ainalrami/colour_article_5_2_5_test.exs`, and it is
      reported per reference per round in the three-way harness. An
      inconsistent round prints immediately rather than only counting: it is
      the strongest claim this instrument can make, it should never fire, and
      nobody goes looking for the position behind a number in a summary.

      Not yet measured - that needs bbpPairings and Gacrux, so it runs on
      Photon with the next corpus pass.

      The original note:

- [ ] **Re-read what `:reach` filed while it was weakened.** On a bbpPairings-vs-Gacrux board neither side is
      this engine, so `explained_by_article_5_2_5?/4` drops to `:reach` -
      "5.2.5 decided this board" rather than any conformance claim. That was
      the honest ceiling while the article's answer was disputed: computing
      it meant modelling a reference's internals, which this project refuses.

      **The SPP ruling removes the ceiling.** The article's answer is now
      fixed, and all three engines implement it, so computing it is applying
      a rule rather than predicting an internal. `:reach` can become a real
      conformance test OF THE REFERENCES against each other.

      That matters more than a tidier label. This is the only instrument
      that has ever caught bbpPairings and Gacrux contradicting each other,
      and it found two such boards. It ran weakened for its whole life, so
      **boards previously filed as "within 5.2.5's reach" may include real
      reference disagreements nobody looked at** - the weaker word made them
      unremarkable. Re-read them.

      The weakening also had a false justification, which is its own lesson:
      the comment cited "the references renumber differently from each
      other", a claim `tools/rip_probe.exs` had already refuted in this
      repo. A hypothesis stated as a finding propagated from a document into
      an instrument and degraded it. Corrected 2026-08-28.

      Do it alongside the corpus re-run, where the change can be measured
      rather than asserted.

- [x] ~~**Read the boards where the two REFERENCES disagree about colour.**~~
      **Adjudicated 2026-08-28** - see
      [docs/finding-gacrux-5-2-4.md](docs/finding-gacrux-5-2-4.md), ready to
      file upstream.

      The paired corpus run found exactly **two** such boards in 7,392,594,
      one on the forfeit axis and one on the combined axis, and re-running
      those two axes with `COLOUR_DEBUG=1` printed both. They have the same
      structure and one substitution explains both: **Gacrux reads Article
      5.2.4's "higher ranked player" as TPN order, where Article 1.2 defines
      it as score first, then TPN.** On a board where 5.2.4 decides and the
      two players are on different scores, that hands the preference to the
      wrong one.

      Forfeits appear in both because they are what creates the tie: 5.2.4 is
      only reachable when nothing earlier can separate the players, and an
      unplayed round removes a round from both colour histories at once.

      This engine had the same defect and fixed it - same article, same wrong
      reading. That is why the diagnosis took minutes.

      Still to do: send it. It is inference from behaviour rather than a
      reading of their source, and the report says so.

- [ ] **Superseded note - the earlier count of 16 was a different corpus.**

      **Updated 2026-08-28 from `spp5225`**, a 1,065,373-round independent
      run on the post-ruling engine (seeds 32.0M-32.6M, seven axes,
      11,164,952 colour boards). It found **16** boards where bbpPairings
      and Gacrux contradict each other - 13 on the combined axis, 3 on
      forfeits, zero on the other five. Ainalrami agrees with bbpPairings on
      every one, so **Gacrux is alone in all 16**.

      Of those, **7 are boards where Article 5.2.5 itself decided** (the
      harness's `within 5.2.5's reach` label). That number was uninteresting
      while the article's answer was disputed - `:reach` was as much as the
      harness could honestly say. It is not uninteresting now: the SPP has
      fixed what the answer IS, and bbpPairings and this engine both
      implement it, so a board where 5.2.5 decides and Gacrux differs from
      both is **Gacrux failing the ruling**, not an open question. Those
      seven are a filable upstream report.

      The other 9 are outside 5.2.5 entirely - on 5.2.1 to 5.2.4, which
      nobody disputes - and are the same phenomenon as the two found before.

      Note these are DIFFERENT SEEDS from the original two-board finding
      below (32M here, 95M there), so 16-versus-2 is not a like-for-like
      increase; it is a second, larger sample of the same phenomenon. The
      paired re-run on the original seeds is what compares directly.

      Reproduce with `COLOUR_DEBUG=1` on the combined and forfeit axes,
      decide which reference is right on each, and file the seven against
      Gacrux.

      The original note, still accurate for its own corpus:

- [ ] **Read the two boards where the two REFERENCES disagree about
      colour.** The three-way run of 2026-08-27 measured reference-against-
      reference colour agreement for the first time: 6,242,974 boards, and
      two on which bbpPairings and Gacrux contradict each other OUTSIDE
      Article 5.2.5's reach - i.e. on 5.2.1 to 5.2.4, which nobody
      disputes. One on the 10%-forfeit axis, one on the combined axis.
      Ainalrami agrees with bbpPairings in both, so this is not a finding
      against this engine; it is a finding about the ruler. Reproduce with
      `COLOUR_DEBUG=1` on those axes and seeds, decide which reference is
      right, and file it upstream if it is Gacrux. See
      [docs/validation.md](docs/validation.md#colour-measured-three-ways-for-the-first-time).

- [x] ~~**Brute-force the exhaustion refusals on the 4-6 player axis.**~~
      **Done 2026-08-27** (`20c4cb4`). 880,000 tournaments, 805,807 refusals,
      every one PROVED impossible by enumeration against C1/C2/C3, with
      4,876,836 positive controls passing. The oracle found four bugs in
      itself before it found none in the engine. The original note said: The
      2026-08-27 probe established that this engine refuses every position
      bbpPairings refuses - 815,479 of them - but two engines agreeing that
      no legal pairing exists is not proof that none does. On a field of 4
      to 6 the complete-pairing space is small enough to enumerate
      exhaustively against C1/C2 and the absolute colour constraints, which
      would turn the agreement into a proof. See
      [docs/validation.md](docs/validation.md#the-exhaustion-probe-2026-08-27).

The corpus is large but not wide. Each of these is a dimension it holds
constant - which is the failure mode that let a real bug survive 2.5
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
      `readAccelerations250` does - the C++ reads half-open 0-based
      ranges with a blank separator between fields. Harmless reading (the
      separator trims away), fatal writing: the digit lands in the
      separator and the binary rejects the line. Same shape as the `XXA`
      column bug. The parser is left as it is on purpose - correct for
      every well-formed file, and exercised by the whole corpus.

      And `XXP` has no round limit while `260` must state one, so bounding
      it at `number_of_rounds` lets the ban expire on the round being
      paired. Both files parse cleanly; the only symptom is the two
      spellings pairing differently.

      150 tournaments / 7,338 pairings at 100.00% since. `XXP`/`XXA`
      remain the default and the forms the sibling project emits.
- [x] ~~**The three-way harness has full colour data and no colour
      instrument.**~~ **Done 2026-08-27** (`969ba20`). Three pairwise colour
      rates now, including bbpPairings against Gacrux, which nobody had ever
      measured. 750,449 rounds and 7,392,594 boards: Ainalrami's only colour
      differences from either reference are the known 5.2.5 dispute, zero
      unexplained. **Re-read after 2026-08-27:** those "known dispute"
      boards are now known DEFECTS - the SPP ruled against this engine and
      the engine changed. The counts stand as measurements of the old
      engine; they have not been re-run, and are expected, not known, to
      go to zero. The original note said: `same?/2` compares through `normalize/1`, which sorts
      each pair's ranks, so every number it has ever reported is
      colour-blind. That is the exact gap that hid a missing Article 5.2.4
      through 195 million pairings in the two-way harness, which answered
      it with `colour_mismatches/5` and the 5.2.5 dispute split. Port it.
      From the 2026-08-26 sweep.
- [~] **Two measured optimizations.** `legal_pair?/2`'s per-round MapSet
      LANDED on 2026-08-27 (`716b7cb`), inside the odd-field bootstrap where
      it was worth 4x on the edge-list build - but only there; the bracket
      cascade still rescans. `score_before/3` recomputing
      `reconciled_points/2` four times per player per round is untouched and
      was measured at ~0.1% of a large round, so it is a tidy-up rather than
      an optimisation. From the 2026-08-26 sweep.
- [~] **Team tournaments (C.04.6).** **First cut built 2026-08-26** on
      `feature/team-pairing`, in separate files that touch nothing in the
      individual engine: `lib/ainalrami/team_pairing.ex` (the 3.3-3.5
      procedure), `team_pairing/bracket.ex` (3.6), `team_pairing/team.ex`
      (Articles 1.6/1.7), `team_pairing/colour.ex` (Article 4),
      `team_pairing/matching.ex` (the [C3] oracle). 50 tests pass;
      `docs/c0406-regulation-text.md` now holds the regulation verbatim so
      article citations point at a stable local copy.

      **The test is the definition, not a correlation.** 3.6 defines the
      answer as the first element of an enumerable order, so for small
      brackets the test generates every pairing, sorts by identifier,
      filters by the criteria and asserts the engine returns the head. That
      needs no reference implementation - which is the point, since none
      exists.

      Still open before this is usable:

      * **[C5] vs the 3.5.4 example.** Article 2.3.2 says maximise the
        upfloaters' scores; the example under 3.5.4 assumes 2/6/8 all hold
        3 points and then takes only two of them plus a 2.5-pointer, a
        LARGER score difference, without deriving why. The engine follows
        the article. Both readings have a test. Worth asking the SPP -
        the 5.2.5 question was, and came back answered on 2026-08-27, so
        the channel works. See the "Reading decisions" section of the
        conformance doc.
      * **4.3.1 is the 5.2.5 TPN-parity rule again**, so it inherits the
        SPP's 2026-08-27 ruling rather than an open dispute.
        `Colour.initial_colour_by_parity/2` is the line that changed - and
        the "one line" estimate was wrong: `allocate/3` needed a
        `:parity_numbers` option and `decide/5` became `decide/6`. Still
        open on the team side: what "has never been paired" means for a
        TEAM. The individual ruling does not settle it, `%Team{}` carries
        no per-round history, and C.04.6 has no clause of its own
        answering to C.04.2:2.4.
      * **[C7] as a ranking rather than a gate** - currently applied
        through 3.5.4's order rather than as its own pass. Changes
        behaviour only when an earlier set carries more previous-round
        floaters than a later one.
      * **Match-level forfeits.** [C2] names "won a match by forfeit",
        which implies a match-level forfeit concept distinct from a
        board-level one. Modelled as a flag; needs its own pass against
        Article 1.
      * **Fuzzing for legality** - the corpus role that survives having no
        oracle: crashes, [C1]/[C2] violations, [C3] dead ends.
      * **Host integration.** Board order is deliberately unspecified by
        FIDE (Article 0) and so belongs to OpenPairings, not here.

      Original notes, from reading the spec before any code existed
      (2026-08-21):

- [ ] **Team tournaments - the reading.** Written up in
      [docs/conformance-c0406-teams.md](docs/conformance-c0406-teams.md)
      before any code, 2026-08-21. Three findings that change the shape of
      the work:

      It is NOT the Dutch engine applied to teams. C.04.6 has its own
      criteria (C1-C3 absolute, C4-C10 quality - nine rungs against
      twenty-one) and, crucially, its own procedure: Article 3.6 defines an
      identifier, orders pairings lexicographically by it, and takes the
      FIRST satisfying C1/C8/C9/C10. An order and a predicate, not a
      scoring function - so `WeightedMatching` is not involved in choosing
      a pairing at all, only in certifying [C3] completability.

      NO reference implementation pairs teams. Checked: bbpPairings has no
      team code, JaVaFo and Gacrux are individual-only, and SWAR's own
      `Pairing*.cpp` has none either. The corpus method that made the
      individual engine trustworthy is unavailable. The regulation hands
      back something stronger though: 3.6 defines the answer AS the head of
      an enumerable order, so for small brackets a test can BE the
      definition - enumerate, sort, filter, assert the head. That is a
      proof rather than a correlation, and it is the opposite of the
      individual system, where exhaustive verification is impossible in
      principle.

      Article 4.3.1 is the SAME TPN-parity rule as the individual 5.2.5.
      That was an open question to the SPP when this was written; the
      answer arrived 2026-08-27 and went against this engine, so team
      colour allocation is no longer blocked. It takes the parity on the
      numbering that skips teams never paired, and the individual side's
      fix has been carried across.
- [x] ~~Late entrants~~ **not a distinct axis either** (2026-08-17). A
      blank early round is indistinguishable from a zero-point bye
      everywhere the engine looks - same points, same
      `participated_in_pairing?/1`, same float direction under 1.4.3, same
      C2 eligibility - so a generated axis would re-run the arbiter-bye
      axis under another name. That is a consequence of four rules
      agreeing, so it is pinned in `late_entrant_test.exs` (with a
      half-point bye as the control) rather than merely concluded.

      What is genuinely not modelled is C.04.2 **2.5**: TPNs are
      provisional until the participant list closes, so a real late entry
      can renumber the field. This engine takes TPNs as given and never
      assigns them, so that belongs to the caller.

      **Amended 2026-08-27.** Only half of that survives. The SPP ruled on
      **2.4**, not 2.5, and under its reading the engine can no longer
      take the file's numbering as given for 5.2.5: it must itself work
      out which players hold a TPN - which have arrived, or are being
      paired now - and take the parity on that. Assigning TPNs still
      belongs to the caller; deciding who has one does not.
- [x] ~~Files where `142` disagrees with `XXR`~~ **done 2026-08-17.** They
      are the same field; disagreement is now refused rather than silently
      resolved, because every implementation resolved it differently and
      the loser is a wrong final round nothing downstream can detect.
- [x] ~~Unrated players~~ **not an axis.** `fide_rating` never reaches
      `Ainalrami.Pairing` at all - the Dutch system runs on TPN, score and
      colour history, and the initial ranking is given in the file rather
      than derived. Checked rather than assumed; recorded so it is not
      re-proposed.

## Diagnostics

- [x] ~~**The CLI silently ignores a mistyped or space-separated option.**~~
      **Fixed 2026-08-29.** An allowlist of bare and valued flags, checked
      before `--help` so a typo alongside it is not swallowed by usage text
      exiting 0. Values are checked too: `--seed=fourty2`,
      `--acceleration=bakku` and `--initial-colour=x` are refused rather than
      silently defaulted, since defaulting a seed produces exactly the
      unreproducible run the space-separated form did.

      A value-level complaint throws and is caught in `run/1` rather than
      returning `usage_error/1`'s exit code - those parsers are called for
      their VALUE, and there is nowhere in `seed: option(flags, "seed")` for
      an error tuple to go that is not as silent as the bug being fixed.

      Ten tests in `test/ainalrami/cli_options_test.exs`, which capture BOTH
      streams: the complaint goes to stderr and the usage text to stdout, and
      reading one of them proves an exit code while saying nothing about what
      the user was told.

      The original note:

- [ ] **(historic) The CLI silently ignores a mistyped or space-separated option.**
      `split_flags/1` takes a fixed list of bare flags plus anything
      matching `--name=`, and validates no name. `--player=30` runs with a
      random roster size, `--initial-colour=x` silently picks White, and
      `ainalrami -g out.trf --seed 42` (a space instead of `=`) writes the
      file and ignores the seed - so the run is unreproducible, which is
      the RTG's whole argument for existing. Fix is small: a known-option
      allowlist and `usage_error/1`, both of which already exist.
      From the 2026-08-26 sweep.

- [x] ~~**A CLI explain mode.**~~ **Done 2026-08-21.** `explain_round/3`
      had been library-only since the adjudicator needed it, so a host
      application could pair with this engine and then had to reconstruct
      the reasoning from the finished boards - an inference, when the
      engine had already computed the thing itself. `ainalrami input.trf
      -x` now reports, per bracket, who moved down, who lives there, what
      was paired, who floats on, and which criteria actually scored.

- [x] ~~**Re-run the adjudication tables.**~~ **Cannot be, and no longer
      needs to be** (checked 2026-08-18). They were produced while
      `explain_round/3` stamped no float history, so C14-C21 scored a
      constant on both sides of every verdict - which could misattribute a
      disagreement but never invent one.

      Re-running them is impossible: they catalogue 40 disagreements, 39 of
      which were one missing field in the bootstrap matching and no longer
      occur at all. There is no position left to re-score. The single
      survivor, `seed735265-r7-p10`, IS kept as a fixture and HAS been
      re-adjudicated with the fixed instrument - twice, in fact, since the
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
- [x] ~~**Decide what to do with the 5.2.5 dispute.**~~ **Done 2026-08-27:
      the SPP answered, and it answered against us.** The parity is taken
      on a numbering that skips players who have never been paired, not on
      the TPN as C.04.2 Article 2 defines it. Both reference
      implementations were right; Ainalrami was wrong, and has changed.

      The SPP's reasoning, quoted: *"Because of C.04.2:2.4 which states
      'A Late Entry is a participant who is only taken into account for
      the pairing of rounds after the first. If admitted to the
      tournament, late entries receive no points for unplayed rounds ...
      and are given an appropriate TPN and paired only when they actually
      arrive.' ... players who have yet to arrive don't have a TPN."*

      That is the same sentence this engine's case was built on. Our
      reading was "the TPN exists before the arrival; it is the PAIRING
      that waits." The SPP reads it as "no TPN until arrival." One clause,
      two readings, and we took the wrong one. That is the single most
      useful thing to carry out of this episode.

      What follows is the position as it stood when the letter went out.
      It is kept because it is why the question was asked; its conclusion
      is superseded, and the shared-lineage argument in particular is
      falsified - the three implementations agreed because they were
      right, not because they inherited each other.

      > The question changed shape first, and for the better. C.04.3 was
      > rewritten on 1 February 2026: the old Article E.5 tested the parity
      > of a "pairing number", which A.2 defined as the initial ranking "and
      > subsequent modifications", while the new 5.2.5 tests a TPN and
      > Article 1.1 delegates that wholly to C.04.2 Article 2 - which allows
      > exactly two modifications and distinguishes nowhere between a player
      > who has played and one who has not.
      >
      > And JaVaFo, which PREDATES the rewrite, renumbers exactly as
      > bbpPairings and Gacrux do. So this is not two implementations
      > independently misreading a 2026 sentence; it is pre-2026 behaviour
      > carried forward into engines claiming the 2026 rules, which inverts
      > the strongest argument against this engine's reading. Three
      > implementations agreeing was evidence; shared lineage is not.
      >
      > [docs/dispute-initial-colour.md](docs/dispute-initial-colour.md) is
      > written. It is the stronger of the two cases - it rests on a
      > definition quoted verbatim from C.04.2 rather than on an argument
      > about one position - and it affects two reference implementations at
      > once, which is worth weighing before raising it.

      The C.04.3 rewrite argument never reached the answer: the SPP
      decided on C.04.2:2.4, which sits outside the rewrite entirely.
      "The stronger of the two cases" also inverts - `seed735265` still
      stands, with Gacrux backing us board for board, while this one
      falls.

      Letter as sent: [docs/spp-question-initial-colour.md](docs/spp-question-initial-colour.md).
      The dispute write-up, now a record of a closed question:
      [docs/dispute-initial-colour.md](docs/dispute-initial-colour.md).

## Deferred, deliberately

- **A FIDE endorsement application for Ainalrami itself.** The error ratio
  stopped being the obstacle some time ago. What remains is strategic:
  declaring "Internal engine: YES" on FE1 means owning pairing correctness
  rather than inheriting JaVaFo's endorsement, with two-week and two-month
  mandatory fix windows attached.
