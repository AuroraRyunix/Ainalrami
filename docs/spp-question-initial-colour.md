# Question for the SPP: Article 5.2.5 and the definition of TPN

**Sent 2026-08-21. Answered 2026-08-27. The answer is (b). We were wrong.**

The letter asked whether 5.2.5's parity is taken on **(a)** the TPN as C.04.2
Article 2 defines it, unaffected by anyone's non-participation, or **(b)** a
numbering that skips players who have never been paired. This engine
implemented (a). Both references implement (b).

The SPP answered **(b)**:

> Because of C.04.2:2.4 which states "A Late Entry is a participant who is
> only taken into account for the pairing of rounds after the first. If
> admitted to the tournament, LATE ENTRIES receive no points for unplayed
> rounds ... and ARE GIVEN AN APPROPRIATE TPN AND PAIRED ONLY WHEN THEY
> ACTUALLY ARRIVE." ... players who have yet to arrive don't have a TPN.

**The crux: both sides argued from that same sentence.** This letter did not
quote 2.4 - it cited 2.3 and 2.5, and made the general claim that C.04.2
Article 2 "makes no distinction between a registered player who has been
paired and one who has not". But 2.4 is where this project's own written
position rested hardest (`docs/dispute-initial-colour.md`, `README.md`), and
it rested on the identical clause the SPP has now quoted back. Our reading of
it was: *the TPN exists before the arrival; it is the pairing that waits, so a
registered player who has not yet played still holds a TPN, and 5.2.5 asks for
the parity of a TPN.* The SPP reads "given an appropriate TPN and paired only
when they actually arrive" as making the TPN itself wait: no arrival, no TPN,
nothing to take a parity of. Same sentence, opposite conclusion, and we had it
the wrong way round.

**What followed.** The engine changed: 5.2.5's parity is now taken on a
numbering that omits players never paired, in both the individual and the team
system, and the harnesses' "known dispute" buckets are gone rather than
zeroed. Both reference implementations are vindicated - they were not carrying
a pre-2026 reading, they were right, and the shared-lineage argument this
project used to explain away their agreement explained away correct evidence.
The corpus has **not** been re-run at scale yet: the expectation is that the
64,131 disputed boards in `docs/validation.md` collapse to zero, and that is an
expectation, not a measurement.

The question text below is left exactly as sent. It is the record of what was
asked and how; the annotations are all at the bottom.

---

Ready to send. Keep it this short - one question, one example, one table.
Everything else is available on request and should stay on request.

Suggested addressee: the Systems of Pairings and Programs Commission,
which defines the pairing rules and endorses software implementing them
(`spp.fide.com`); the contact address published for it is
`secretary.tec@fide.com`.

**Deliberately says nothing about who is asking or why beyond the
comparison itself.** The question is whether the programs match the text,
and that question is strictly stronger without a fifth implementation in
the table: as written, it is the published rule against every program,
rather than one newcomer against three established ones.

**Tone is deliberate too.** It closes expecting to be wrong. That is
partly honest - three programs agreeing usually does mean the reader erred
- and partly practical: a letter that asks to be corrected invites an
explanation, where one asserting an error invites a defence. If the
reading here turns out to be right, that is a better way to find out than
arguing for it.

---

**Subject:** C.04.3 Art. 5.2.5 - did the change from "pairing number" to
"TPN" (1 February 2026) change the intended behaviour?

Dear Commission,

I have been comparing the colour allocation produced by several pairing
programs against the current text of C.04.3, and have found a case where
all of them appear to depart from Article 5.2.5 as written. I would be
grateful to know which behaviour is intended.

**The question, in one sentence:** when Article 5.2.5 tests whether the
higher ranked player has an odd TPN, and some registered player has never
been paired in the tournament so far, is the parity taken on

* **(a)** that player's TPN as defined in C.04.2 Article 2, unaffected by
  anyone's non-participation; or
* **(b)** a numbering that skips players who have never been paired?

**Why the question arises.** The wording changed on 1 February 2026.

Previously, Article E.5 read:

> If the higher ranked player has an odd **pairing number**, give him the
> initial-colour; otherwise give him the opposite colour.

and A.2 defined that number as assigned by the initial ranking list "**and
subsequent modifications** depending on possible late entries or rating
adjustments", with a note directing the reader to C.04.2.B/C for "the
proper management of the pairing numbers".

The current Article 5.2.5 reads:

> If the higher ranked player has an odd **TPN** (see Article 1.1), give
> them the initial-colour; otherwise, give them the opposite colour.

Article 1.1 supplies no definition of its own; it delegates entirely to
C.04.2 Article 2. That article assigns a TPN from the initial ranking and
allows it to move for exactly two reasons - a correction to the ranking
data, which is barred after the fourth round has been paired (2.3), and
the closing of the List of Participants (2.5). It makes no distinction
between a registered player who has been paired and one who has not.

Read literally, the current text gives **(a)**. Every program I tested
gives **(b)**.

**The comparison.** Round one of a ten-player event, initial colour White,
with TPNs 1 and 3 sitting the round out on an arbiter-assigned bye. Every
board falls through 5.2.1-5.2.4 to 5.2.5 alone, since no player yet has a
colour preference:

| board | higher TPN | parity | 5.2.5 read literally | JaVaFo | bbpPairings 6.0.0 | pairing checker |
|---|---|---|---|---|---|---|
| 2 v 7 | 2 | even | 7 is White | 2 | 2 | 2 |
| 4 v 8 | 4 | even | 8 is White | 8 | 8 | 8 |
| 5 v 9 | 5 | odd | 5 is White | 5 | 5 | 5 |
| 6 v 10 | 6 | even | 10 is White | 10 | 10 | 10 |

Exactly one board differs, and it is the one board where the TPN's parity
and the player's position among those actually being paired disagree. On
the other three they coincide, which is why a complete field shows no
difference at all.

I note that JaVaFo predates the current wording, and that under the
previous wording - a "pairing number" carrying "subsequent modifications"
in its own definition - behaviour (b) appears well founded. That is why I
am asking whether the February rewrite was intended to change behaviour,
rather than reporting a defect against any program.

**Why it matters.** This is not a rare position. It decides colours on
every board that reaches 5.2.5 in any tournament where a registered player
has not yet been paired - a bye, a late entry not yet arrived, a
withdrawal before round one.

**What I think is most likely.** Three independent programs agreeing is
usually a sign that the reader has misunderstood the rule rather than that
the programs are wrong, so I expect I am missing something - most probably
a definition or a settled convention that is obvious to those who work
with these rules regularly and simply is not visible from the text on its
own. If that is so, I would be genuinely glad to be told what it is: partly
to stop misreading it, and partly because I have not been able to find it
written down anywhere I could point someone else to.

If instead the February rewrite did narrow the definition, then knowing
that is just as useful.

Either way I would very much appreciate a line explaining which it is. I
am happy to supply the TRF file and each program's raw output if that
helps, and I am grateful for your time.

With many thanks,

---

## Annotations, written after the reply (2026-08-27)

The letter above is unedited. These note where it was right and where it was
wrong, in the order the passages appear.

**"Read literally, the current text gives (a). Every program I tested gives
(b)."** - This is the reading that was submitted and rejected. The SPP holds
that the current text, read together with C.04.2:2.4, gives (b). "Read
literally" was doing more work than it could carry: it meant *read 5.2.5 and
2.3 and 2.5 literally*, and it did not reach the one sub-article that decides
the matter. The second half of the sentence stands and was the warning sign.

**The comparison table.** The measurements are correct and unchanged - board
2 v 7 is still the single board where the two parities disagree, and the
programs still answer 2. What inverts is the column heading. "5.2.5 read
literally" gave 7; the answer 5.2.5 actually gives is 2, so on that board it
was this engine's reading that departed from the article, not the programs'.

**"I note that JaVaFo predates the current wording ... That is why I am asking
whether the February rewrite was intended to change behaviour."** - The premise
was sound and the conclusion was too generous to us. The February rewrite is
beside the point: C.04.2:2.4 sits outside C.04.3 entirely and was untouched by
it, so behaviour (b) is founded on a clause the rewrite never reached. The
argument that renumbering was "defensible under the old wording and baseless
under the new" - which appears in `CHANGELOG.md` and elsewhere - fails on that.

**"Why it matters."** - Unchanged, and the blast radius is now this engine's,
not the programs'. Colour is allocated after the pairing, so nothing here moves
a player to a different board; every affected axis still reports 100.00%
pairing agreement.

**"What I think is most likely."** - This paragraph was right, and it is the
most useful thing in the letter. Three independent programs agreeing did mean
the reader had misunderstood the rule. The thing that was missing was not a
settled convention invisible from the text, as guessed: it was a single
sub-article of C.04.2 that this project had in fact read, quoted, and built its
case on, and had construed backwards. That is a worse failure than the one
predicted, and closer to home.

**The decision to keep this engine out of the table** (see the preamble) was
right for a reason that only became visible with the answer. The question put
was the published rule against every program, so the reply is a ruling on the
rule rather than a defect report about a newcomer, and it is quotable as such
by anyone. Had the letter argued Ainalrami's case, the answer would have read
as a correction of one program instead of a construction of C.04.2:2.4.

**Closing expecting to be wrong** was also right, and cheaply so: a letter that
asks to be corrected got back the reasoning, not just the verdict. The
reasoning is the part worth having - the verdict alone would have said (b)
without saying why, and the *why* is what the rest of the repository now has to
be rewritten around.
