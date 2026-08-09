# Open questions, as minimal reproducers

Not regression fixtures. Each of these is a live question about what
bbpPairings actually does, reduced to the smallest input that shows it.

## `c6-vs-completion-{6,8}.trf`

**Does the completion rung outrank C6, or not?**

`computeEdgeWeight` (dutch.cpp:276-286) puts the completion/bye-eligibility
rung ABOVE "maximise the number of pairs in the current pairing bracket":

```c++
result |= 1u + !isByeCandidate(higherPlayer, …) + !isByeCandidate(lowerPlayer, …);
shiftEdgeWeight<max>(result, scoreGroupSizeBits);
result |= lowerPlayerInCurrentBracket;                 // C6, strictly below
```

On an EVEN field `byeAssigneeScore` stays at its zero initialiser
(dutch.cpp:822), so `isByeCandidate` is false for anyone who has scored
and that rung is a constant `3` per edge. A constant per edge means the
top rung is just three times the edge count — so a matching with more
edges should always win, whatever C6 says.

It does not. Both files have score groups `{1} 5.0`, `{2,3,4} 4.5`,
`{5,6} 4.0`, and 5-6 already played each other, so the bracket that
matters is MDP `[1]` + residents `[2,3,4]` + next group `[5,6]` — the
same shape as seed102 round 7's 4.5 bracket. The two files differ only in
whether a `{7,8} 3.5` group exists after it. The bracket graph is
identical in both.

| | bbpPairings 6.0.0 | edges | internal (C6) |
|---|---|---|---|
| `-6.trf` (nothing below) | `1-2, 3-5, 6-4` | 3 | 1 |
| `-8.trf` (3.5 group below) | `1-2, 3-4, 7-5, 6-8` | 2 | 2 |

So the cross edges `3-5` and `4-6` exist and are usable — bbpPairings
takes them in the 6-player file, where the 2-internal answer would strand
5 and 6. Given anywhere for 5 and 6 to go, it prefers 2 internal pairs
over 3 edges, i.e. **C6 beats edge count**, which is the opposite of what
the shift order above says.

Same bracket graph, different answer, so the decision is not a property
of that graph alone. Either the completion rung is not summed over
cross-bracket edges the way this port assumes, or something outside the
bracket constrains it.

This matters: 47 of the global cascade's 167 disagreements are flagged on
exactly this rung by `tools/adjudicate.exs`, and `OPENPAIR_TRACE=1` shows
the initial solve already producing the answer, so it is the ladder
deciding and not a refinement stage.

**Caveat on these two files.** OpenPair returns no pairing at all for
them, which is a defect of the fixture rather than a second finding: the
scores are built from arbiter-assigned `H`/`Z` byes, which do not count
as participation, so every player's game count exceeds their played
rounds and the engine reads the whole field as sitting the round out.
bbpPairings uses a tournament-wide `playedRounds` and pairs them anyway.
A cleaner fixture would build the same scores from real games — note that
an odd number of half-integer scores is unreachable that way, since every
draw creates two of them, so the score groups need re-choosing to suit.
