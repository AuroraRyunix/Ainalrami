# Question for the SPP: Article 5.2.5 and the definition of TPN

Ready to send. Keep it this short — one question, one example, one table.
Everything else is available on request and should stay on request.

Suggested addressee: the Systems of Pairings and Programs Commission,
which defines the pairing rules and endorses software implementing them
(`spp.fide.com`); the contact address published for it is
`secretary.tec@fide.com`.

---

**Subject:** C.04.3 Art. 5.2.5 — did the change from "pairing number" to
"TPN" (1 February 2026) change the intended behaviour?

Dear Commission,

I am preparing an FE1 endorsement application for a pairing engine and
have found a behavioural difference between the current text of C.04.3 and
every reference implementation I can test. Before I declare an internal
engine, I would like to know which is intended.

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
allows it to move for exactly two reasons — a correction to the ranking
data, which is barred after the fourth round has been paired (2.3), and
the closing of the List of Participants (2.5). It makes no distinction
between a registered player who has been paired and one who has not.

Read literally, the current text gives **(a)**.

**What implementations do.** All four give **(b)** except mine. Round one
of a ten-player event, initial colour White, with TPNs 1 and 3 sitting the
round out on an arbiter-assigned bye. Every board falls through 5.2.1–
5.2.4 to 5.2.5 alone, since no player yet has a colour preference:

| board | higher TPN | parity | 5.2.5 read literally | JaVaFo | bbpPairings 6.0.0 | Gacrux | mine |
|---|---|---|---|---|---|---|---|
| 2 v 7 | 2 | even | 7 is White | 2 | 2 | 2 | 7 |
| 4 v 8 | 4 | even | 8 is White | 8 | 8 | 8 | 8 |
| 5 v 9 | 5 | odd | 5 is White | 5 | 5 | 5 | 5 |
| 6 v 10 | 6 | even | 10 is White | 10 | 10 | 10 | 10 |

Exactly one board differs, and it is the one board where the TPN's parity
and the player's position-among-those-being-paired disagree.

I note that JaVaFo predates the current wording, and that under the
previous wording — a "pairing number" carrying "subsequent modifications"
in its own definition — behaviour (b) appears well founded. That is why I
am asking whether the February rewrite was intended to change behaviour,
rather than reporting a defect against anyone.

**Why it matters.** This is not a rare position. It decides colours on
every board that reaches 5.2.5 in any tournament where a registered player
has not yet been paired — a bye, a late entry not yet arrived, a
withdrawal before round one.

**What would settle it:** a yes or no on whether the change from "pairing
number" to "TPN" was intended to change the number whose parity is tested.

I am happy to supply the TRF file, the four engines' raw output, and a
script that reproduces the table above.

With thanks,
