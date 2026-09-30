# Performance

Five passes, newest first: the slow tail of the last round, the slow
spots the direct bracket left, the direct bracket on odd fields, the direct
bracket itself, which took the pairing past Gacrux on every benchmark file,
and the large-field pass before it.

## The slow tail (2026-09-30)

A timing study of 3,000 random positions (the fuzz generator at 100, 101,
200, 201, 400, 401, 600, 601, 1,000 and 1,001 players, rounds 2, 5 and 9,
100 seeds each, one scheduler) put the pairing's median at 3-55 ms per size
and round, and found 11 positions above 0.5 s - every one of them round 9,
the last round of a nine-round event. The slowest took 8.26 s at 1,000
players, where the median at that size and round is 0.049 s. On this
machine the 30 slowest took **22.5 s** in all (the worst 5.2 s) and now take
**4.2 s** (the worst 1.04 s), with the same pairing; 100 other positions
drawn at random are unchanged, and every answer on the differential corpus
is unchanged.

### Where the time was

The 30 slowest positions, rebuilt by the study's generator
(`position.(n, round, seed)`), in-VM `Pairing.pair_next_round/2` at
`+S 1:1`, with the per-bracket trace and the certified-mode counters:

| cause | positions | 030bd28 |
|---|---|---|
| the odd field's bye bootstrap went to the whole-field search | 11 (1,001 x4, 601, 401 x5, 201) | 1.6-1.8 s at 1,001 players, 0.48 s at 601, 0.18-0.19 s at 401 |
| the completability oracle's sparse graph missed a matching, and a 127- or 63-player bracket went to the field graph | 2 (1,000, 600) | 5.2 s, 2.4 s |
| blossoms in the cardinality matcher's search: each contraction sorted the whole tree | 7 at 1,001 players | 0.2-0.3 s |
| a top bracket whose MDP can play nobody in it went to the field graph | 1 (600) | 1.0 s |
| a 13-player top bracket that needs an exchange went to the field graph | 1 (401) | 0.75 s |
| left as it was (see "What is left") | 8 | 0.2-1.0 s |

Round 9 is the last round, and in the last round two players due the same
colour absolutely cannot meet unless both are topscorers; a stretch of the
field can then hold more players due one colour than its neighbourhood can
give it. That is what the first two causes have to do with round 9.

* **The bye bootstrap.** On an odd field the bye's score and the first
  bracket's C9 gate come from one whole-field matching (the bootstrap). Its
  two certificates, the greedy pairing and the matched one, each require
  the top group paired inside itself as far as its parity allows, and at
  round 9 the top group was, 11 times of 11, two leaders who had met. What
  remained was the search, a complete-graph matching of the whole field.
* **The sparse oracle.** The completability oracle keeps each player's
  first 12 compatible players below them. At 1,000 players round 9 the
  127-player 5.0 bracket was answered directly, and the rest of the field
  (730 players) was then asked for a perfect matching: the whole compatible
  graph has one, the sparse graph did not find it, and the bracket went to
  the field graph (the 600-player position: a 63-player bracket, the same).
* **The blossoms.** `Ainalrami.CardinalityMatching`'s search found the
  vertices a contraction relabels by walking its whole tree in index order,
  sorted at every contraction. A search whose tree covers most of a
  1,000-player field spent most of a 0.2 s round in those sorts.
* **The MDP who can play nobody.** A leader who had met both players of the
  group below: the bracket of three went to the small bracket, whose
  floater has to be a resident of the pool, and the MDP is the one that
  floats in every matching.
* **The exchange.** A bracket of 13 with one MDP whose walk found no
  exchange-free answer (`:unproven`), past the small bracket's size, at the
  top of a 401-player field.

### What changed

Five changes, each argued in the section comments of `Ainalrami.Pairing`
and `Ainalrami.CardinalityMatching`, and each held to the path it replaces
in check mode:

* **The bootstrap's leftover below the top group**
  (`leftover_bootstrap/5`). The flag the bootstrap returns,
  `first_single_bye?/4`, is false whatever the matching once the bye score
  is below the top score, so of the three things the bootstrap's optimum is
  ranked by only two are read: all but one paired over compatible edges,
  and the leftover's `(ineligible, place)` as small as the field allows.
  With `L` the last player with the least of that term, a perfect matching
  of the field less `L` makes the answer `{score(L), false}`, however few
  pairs the top group can keep inside. The greedy pairing is that matching
  where it covers everyone; otherwise the sparse subgraph's maximum
  matching, grown by augmenting searches over every compatible pair
  (`dense_perfect?/2`), which is exact - so what it misses the search would
  not find either, and it goes to the search as before.
* **The oracle's dense rescue** (`oracle_dense/2`). Where the sparse
  graph's search fails, the same matching is grown by augmenting searches
  over the whole compatible graph - the test the sparse graph is built
  with, plus the bye's stand-in joined to every candidate - its rows built
  only as a search reaches them and kept for the round. A "yes" is a
  matching of the graph the field path pairs on, which is condition (b) as
  a sparse "yes" is; a "no" is exact (a search that finds no augmenting
  path shows some maximum matching leaves its root exposed). Later sparse
  searches run on the sparse graph plus that matching's pairs, still a
  subgraph of the whole one.
* **Blossoms merged by group** (`CardinalityMatching.contract/4`). The
  vertices sharing a base are kept as a group; a contraction merges the
  groups of the cycle's bases, the smaller into the larger, and names the
  cycle's base as the merged group's. The vertices newly outer are the
  cycle's bases not yet outer (every vertex of a group of more than one was
  made outer by the contraction that formed it), queued in index order as
  the scan over the sorted tree queued them: the same search, step for
  step.
* **An MDP with no partner in its bracket** (`stuck_member?/3`, on the odd
  field-graph bracket over a next group of non-candidates). Every perfect
  matching of the small graph puts it on the stand-in, its only edge, whose
  weight is therefore the same across the list; on the field graph every
  optimum floats it too once the rest of the field, the MDP in it,
  completes (the oracle's question after the walk), since the completion
  rung is then at its bound with the rest of the bracket paired inside and
  no matching pairs the MDP inside. The small bracket's answer stands with
  the MDP carried.
* **The small bracket after the walk** (`direct_small_after_walk/10`).
  Where the walk gives up on a bracket of 13-16 vertices, the small
  bracket's list is made anyway: bounded (`enumerate_bounded/6` cuts a
  branch whose weight plus half its vertices' heaviest edges falls short
  of the best, ties kept, so the optima are the same list) and capped at
  200,000 steps. The same stages' decisions over the same list, so the
  same argument.

`AINALRAMI_DIRECT=off` switches off the leftover certificate, the dense
rescue and the small bracket after the walk with the direct brackets, so a
run can be held to the engine without them end to end. The blossom change
is the same search and has no switch.

### Results

In-VM `Pairing.pair_next_round/2`, `+S 1:1`, median of 5 after one warm
call, the two builds (030bd28, the slow spots, and this) run side by side on
the same i7-10700, two positions of each at a time. Every pairing is the
same in both. The study's own timings were on another machine and run
about 1.5-2x slower than these.

| players | round | seed | 030bd28 | after | cause |
|---|---|---|---|---|---|
| 1,000 | 9 | 8,971,000 | 5.241 s | **0.031 s** | sparse oracle |
| 600 | 9 | 8,070,600 | 2.387 s | **0.020 s** | sparse oracle |
| 1,001 | 9 | 8,691,001 | 1.771 s | **0.035 s** | bootstrap |
| 1,001 | 9 | 8,061,001 | 1.751 s | **0.033 s** | bootstrap |
| 1,001 | 9 | 8,011,001 | 1.646 s | **0.055 s** | bootstrap |
| 1,001 | 9 | 8,321,001 | 1.593 s | **0.039 s** | bootstrap |
| 600 | 9 | 8,150,600 | 1.040 s | 1.039 s | left: an even top bracket with no perfect matching |
| 600 | 9 | 8,170,600 | 1.004 s | **0.023 s** | an MDP with no partner |
| 401 | 9 | 8,800,401 | 0.750 s | **0.068 s** | the exchange |
| 400 | 9 | 8,780,400 | 0.516 s | 0.532 s | left: the round sent back to the reference path |
| 601 | 9 | 8,710,601 | 0.482 s | **0.072 s** | bootstrap |
| 600 | 9 | 8,620,600 | 0.317 s | 0.332 s | left: a pruned walk past its budget |
| 600 | 9 | 8,640,600 | 0.296 s | 0.293 s | left: a pruned walk past its budget |
| 1,001 | 9 | 8,581,001 | 0.293 s | **0.129 s** | blossoms |
| 601 | 9 | 8,930,601 | 0.261 s | 0.279 s | left: a pruned walk past its budget |
| 201 | 9 | 8,710,201 | 0.254 s | 0.214 s | bootstrap; left: a bracket of three with two MDPs |
| 1,000 | 9 | 8,381,000 | 0.240 s | 0.240 s | left: a pruned walk (answered) |
| 1,000 | 2 | 8,691,000 | 0.237 s | 0.229 s | left: the 315-player bracket over the zero group |
| 1,001 | 9 | 8,181,001 | 0.216 s | **0.052 s** | blossoms |
| 1,001 | 9 | 8,731,001 | 0.215 s | **0.048 s** | blossoms |
| 1,001 | 9 | 8,501,001 | 0.211 s | **0.046 s** | blossoms |
| 1,001 | 9 | 9,001,001 | 0.208 s | 0.203 s | left: an odd bracket whose rest cannot complete |
| 1,001 | 9 | 8,801,001 | 0.206 s | **0.049 s** | blossoms |
| 1,001 | 9 | 8,371,001 | 0.203 s | **0.048 s** | blossoms |
| 1,001 | 9 | 8,931,001 | 0.201 s | **0.049 s** | blossoms |
| 401 | 9 | 8,390,401 | 0.191 s | **0.013 s** | bootstrap |
| 401 | 9 | 8,320,401 | 0.188 s | **0.019 s** | bootstrap |
| 401 | 9 | 8,070,401 | 0.185 s | **0.015 s** | bootstrap |
| 401 | 9 | 8,060,401 | 0.182 s | **0.021 s** | bootstrap |
| 401 | 9 | 8,310,401 | 0.180 s | **0.011 s** | bootstrap |

| | 030bd28 | after |
|---|---|---|
| the 30, in all | 22.5 s | 4.2 s |
| median of the 30 | 0.261 s | 0.049 s |
| slowest | 5.24 s | 1.04 s |
| 100 others at random (the same sizes and rounds), in all | 1.65 s | 1.59 s |
| their median / p90 / slowest | 13.3 / 33.1 / 80 ms | 12.4 / 33.3 / 65 ms |

Of the 100, one position is more than 20% (and 2 ms) slower (100 players
round 9, 10.3 -> 12.4 ms, within the runs' spread) and three are faster.

### How it was checked

Every check below ran on the committed engine.

* **Differential against v0.33.0** (`tools/perf_diff.exs`, the baseline
  logs of the passes below), default configuration: small 370,777 rounds,
  flags 68,898, large 5,497, early 1,980 - **447,152 rounds, 0 differing,
  0 missing** (89,665 + 16,964 + 477 + 60 of them with the alternatives
  fingerprinted). Its pairing calls took 127,625 leftover bootstraps, 835
  dense rescues (4 of them admitting a local bracket), 732 small brackets
  after the walk and 15 MDPs with no partner.
* **Check mode** (`AINALRAMI_DIRECT=check`, certified mode forced, the
  first 400 tournaments of every axis of the four sets): 44,325 rounds,
  identical to v0.33.0 end to end, with **14,668 new answers checked, 0
  differences** - 11,847 leftover bootstraps held to the search, 1,582
  dense rescues whose matching was checked pair by pair (the 4 local
  brackets they admitted held to the field path, and 778 field-graph
  brackets held to it as every such bracket is), 353 small brackets after
  the walk and 886 MDPs with no partner, each held to the stages or the
  field path - besides 411,578 oracle answers held to the weighted oracle
  and 63,265 pools to per-resident matchings, 0 differences.
* **Generated large fields**, 400-1,001 players, 9 rounds: 20 opens with 3%
  requested byes, 2% forfeits and 1% withdrawals (446-969 players, 11 odd)
  and 20 without (411-993, 10 odd), paired in check mode (1 leftover
  bootstrap, 12 dense rescues, 1 local bracket they admitted, 2 small
  brackets after the walk, 1 MDP with no partner, and 652 field-graph
  brackets, all checked, 0 differences), then again with
  `AINALRAMI_DIRECT=off` and by 030bd28: the 360 rounds identical across
  all three.
* **The study's 30 positions** in check mode, every round leading up to
  each position included (263 rounds): 15 leftover bootstraps, 7 dense
  rescues (2 local brackets), 1 small bracket after the walk and 2 MDPs
  with no partner checked, 0 differences, and each position's pairing the
  same as the timing runs'.
* `mix test`: 816 tests, 0 failures; `direct_bracket_test.exs` requires a
  leftover bootstrap, a dense rescue, a small bracket after the walk and an
  MDP with no partner to have answered (and been checked);
  `cardinality_matching_test.exs` checks the matcher on graphs of 21-140
  vertices against `WeightedMatching` with every weight equal, over a
  neighbour function, and with pairs of its matching outside the graph
  searched.

### What is left

Of the 30, eight positions are as they were, each a shape no argument here
covers:

* **An even top bracket with no perfect matching** (600 players, 1.04 s):
  four leaders, two pairs of whom have met, float two players, and that
  bracket is paired on the whole field graph. A bracket that must float
  more players than its parity is still paid in full.
* **A round sent back to the reference path** (400 players, 0.53 s): a
  tainted round's certified read met a tie (`{:abort, :read}`), and the
  round was paired again without the shortcuts, its 3-player top bracket on
  the field graph.
* **Pruned walks** on 83-93-player brackets (0.28-0.33 s): past their
  budget, so the stages on the local graph; a larger budget answers some of
  them, but the walk then costs what the stages do.
* **A bracket of three with two MDPs** (201 players, 0.21 s): more MDPs
  than residents is outside the direct brackets (`direct_allowed?/2`).
* **An odd bracket whose rest cannot complete** with its window gone
  (1,001 players, 0.20 s): exact now, and a "no".
* 1,000 players round 2's 315-player bracket over the zero group and a
  slow pruned walk at 1,000 players round 9 (0.23-0.24 s), both answered
  directly already.

## The slow spots (2026-09-30)

The Gacrux benchmark's positions had a few rows far off the rest: 600
players round 2 took **2.9 s** where 400 and 1,000 players took 0.02 and
0.05 s, and round 9 took **1.18 s** at 1,000 players and 0.39 s at 600.
Each was one bracket that went to a matcher its answer did not need, or
the completability oracle's matcher itself. Every row is now under 0.07 s
with the same pairing, and every answer on the differential corpus is
unchanged. On 60 generated opens of 158-947 players, rounds 2-9 went from
132 s of pairing in all (worst round 21.7 s) to 7.6 s (worst 88 ms).

### Where the time was

In-VM `Pairing.pair_next_round/2`, `+S 2:2`, the per-bracket trace and the
certified-mode counters, on the benchmark's positions:

| position | in-VM | where |
|---|---|---|
| 600 players, round 2 | 2.93 s | the 0.5 bracket (202 players and one MDP) over the 199 on zero, on the field graph: 2.88 s |
| 600 players, round 9 | 0.39 s | a 108-player bracket whose walk needed 30,709 checks against a budget of 3,968, so the stages on the local graph: 0.33 s |
| 1,000 players, round 9 | 1.18 s | a 169-player bracket, 22,552 checks against 5,920: the stages, 1.02 s; the oracle's first solve, 62 ms; a 19-player odd bracket over a 4-player group with one player below, on the field graph, 28 ms |
| 1,001 players, round 9 | 0.31 s | the oracle's first solve, 0.22 s |
| 200 players, round 9 | 0.08 s | the oracle's re-solve after each bracket, 3-6 ms apiece |

* **The 0.5 bracket of an even round 2.** Odd, over the players on zero:
  on an even field those are bye candidates in the completion rung's
  sense (`1 + !isByeCandidate(a) + !isByeCandidate(b)` with the bye score
  at zero), so the local graph turned it away, and the field-graph odd
  bracket required a window of non-candidates. At 400 and 1,000 players
  the 1.0 group is even, so the 0.5 bracket is too, which is why only 600
  was slow.
* **Two walks past their budget.** The walk is depth-first and discards a
  choice only on the per-edge test and the colour counts, so a conflict
  near the end of S1 (two late S1 players with one S2 partner between
  them) is walked again under every choice above it: 7,424 illegal pairs
  and 12,315 colour-count failures in the 108-player bracket, almost all
  in its last eight levels.
* **The oracle.** A maximum-WEIGHT matching over the sparse field graph,
  solved from cold once a round (0.05-0.22 s at 1,000 players, the odd
  field the slowest) and re-solved after every accepted bracket.
* **The 19-player odd bracket** has an even next group of 4 and one player
  below it, so the floater's `q / 2` pairs leave one of the four to that
  player; the pool required the rest of the field to take ANY of the four,
  and it could take only some.

The generated opens (the fuzz generator at 158-947 players, 3% requested
byes, 2% forfeits, 1% withdrawals, 9 rounds) showed two more, every round
over 0.3 s once the four above were gone:

* **A bracket none of whose members can play each other** - the two
  leaders of a late round who have met - went to the field graph: 2.6 s
  at 926 players round 9, 1.0 s at 494.
* **The odd field's bye bootstrap** (`bye_assignee_score/2`): where the
  greedy certificate fails - a player left without a partner in field
  order, or the top group split - the whole-field complete-graph search:
  0.15-1.8 s.

### What changed

Six changes, each argued in the section comments of `Ainalrami.Pairing`
and each held to the path it replaces in check mode:

* **An odd bracket of an even field over the group on zero**
  (`:odd_zero_group`, certified mode). The players on zero make the
  completion rung's per-edge terms vary, but every optimum is a perfect
  matching (the field is even and one exists: the walk's pairs, the
  floater absorbed, the rest completed), and over perfect matchings those
  terms sum to the same. The completion rung is the only rung that reads
  bye candidacy there (C9 is off with no bye), so the odd bracket's
  argument holds as it stands, with the bracket's own members still
  required to be non-candidates (the walk's per-edge completion test).
* **The odd bracket's pool, all at once, and its takers.** The residents
  the next group `N` absorbs were found by a weighted matching of `N` plus
  the resident, per resident - 202 matchings of a 200-vertex graph at 600
  players round 2. They are the residents who can play some `G` in the
  exposable set of `N` (when `q = |N|` is odd) or of `N` plus a stand-in
  joined to the takers (when it is even) - one Gallai-Edmonds search
  (`absorbed_pool/5`). The takers: with `q` even the floater's `q / 2`
  pairs leave one of `N` to the rest of the field, and the argument needs
  only that the one left over can be taken, not that every player of `N`
  could be - each shown by the oracle, as before.
* **The pruned walk.** A plain walk past its budget runs again with two
  more ways to discard a subtree, both proofs that it holds no leaf:
  Hall's condition on the rest (a maximum matching of the remaining S1
  into the remaining S2 over legal, colour-compatible pairs, kept from
  choice to choice by one augmenting search when a choice takes someone's
  partner), and states that failed once (the S1 position, the S2 players
  used and the two colour counts decide everything below them). It meets
  its leaves in the plain walk's order, so it returns what the plain walk
  would have returned with no budget. The per-edge ladder test is
  remembered per walk. The two brackets: 2,138 and 1,620 checks.
* **The oracle as a cardinality matching.** Every question it answers is
  "is there a matching of the players left, leaving the bye (if any) on a
  candidate", which is a perfect matching of the players plus, on an odd
  count, a stand-in joined to every candidate. A maximum matching is kept
  from question to question: the players taken out leave their partners
  exposed, and an augmenting search from each
  (`Ainalrami.CardinalityMatching.augment_from/4`, which grows only the
  tree it needs - no per-search array over the graph, a blossom
  relabelling only the tree) either matches it or shows some maximum
  matching leaves it exposed. The weighted oracle's answers were the same
  property of the same sparse graph; under `AINALRAMI_DIRECT=check` it
  runs alongside and every answer is held to it.
* **A bracket that cannot pair at all** (`:empty`, certified mode). The
  field graph has no edge between two of its members (an edge is only ever
  made for a legal, colour-compatible pair), so whatever the stages do the
  field path pairs nobody, carries everyone forward in order and counts
  every member as floating. The next bracket's C9 gate, the one reader of
  the tentative partners, must be shut on its own terms; the round matcher
  is left on the certified mode's terms, as the other field-graph shapes
  leave it.
* **The bye bootstrap by matchings.** Where the greedy certificate fails,
  the certificate's existence - all but the leftover `L` paired over
  compatible edges, `L` the last of the least `(ineligible, place)`, the
  top group paired inside itself as far as its parity allows - is shown by
  maximum matchings on sparse subgraphs: the top group less `L` and the
  rest each perfectly matched, or, when the top group less `L` is odd,
  a player its near-perfect matchings can leave over who can play one the
  rest's can (both exposable sets). The answer is read off the bounds:
  the bye score is `L`'s, and the single-downfloater flag holds exactly
  when `L` is in the top group and the rest of that group is paired
  inside it. What the sparse graphs miss goes to the search as before;
  check mode holds every such answer to the search.

### Results

In-VM `Pairing.pair_next_round/2`, `+S 2:2`, medians of 5, the positions
`/root/bench.exs` on the validation VM builds (the fuzz generator at seed
`9,500,000 + players`, earlier rounds paired by this engine), the two
builds run one after the other on the same idle machine (an i7-10700).
Every pairing is the same in both.

| position | before (0a844f7) | after |
|---|---|---|
| 200 players, round 2 | 0.008 s | 0.002 s |
| 200 players, round 9 | 0.082 s | **0.008 s** |
| 400 players, round 2 | 0.019 s | 0.006 s |
| 400 players, round 9 | 0.041 s | 0.011 s |
| 600 players, round 2 | 2.93 s | **0.028 s** |
| 600 players, round 9 | 0.389 s | **0.040 s** |
| 1,000 players, round 2 | 0.046 s | 0.017 s |
| 1,000 players, round 9 | 1.18 s | **0.065 s** |
| 1,001 players, round 2 | 0.125 s | 0.067 s |
| 1,001 players, round 9 | 0.306 s | **0.029 s** |

The generated opens (60 tournaments, seeds 1-60, 158-947 players, 27 of
them odd; four at a time at `+S 4:4`; every round re-paired identically
by both builds), rounds 2-9:

| | before | after |
|---|---|---|
| pairing, all 480 rounds | 132.4 s | 7.6 s |
| median round | 65 ms | 14 ms |
| p95 | 791 ms | 32 ms |
| slowest round | 21.7 s | 88 ms |

### How it was checked

Every check below ran on the committed engine.

* **Differential against v0.33.0** (`tools/perf_diff.exs`, the baseline
  logs of the passes below), default configuration: small 370,777 rounds,
  flags 68,898, large 5,497, early 1,980 - **447,152 rounds, 0 differing,
  0 missing** (89,665 + 16,964 + 477 + 60 of them with the alternatives
  fingerprinted).
* **Check mode** (`AINALRAMI_DIRECT=check`, certified mode forced, the
  first 400 tournaments of every axis of the four sets): 44,325 rounds,
  identical to v0.33.0 end to end, with **20,631 new direct answers
  checked, 0 differences** - 3,244 odd brackets over the group on zero,
  3,339 more odd brackets (54,155 against the previous pass's 50,816: the
  takers), 13,959 brackets that cannot pair and 89 pruned walks - besides
  63,265 pools held to per-resident matchings (a maximum matching per
  resident, and the weighted `absorbed?/3` wherever the pool had its old
  shape and the group is at most 100), **410,485 oracle answers held to
  the weighted oracle** and **19,623 bye bootstraps held to the search**,
  0 differences.
* **Every walk the pruned one** (the same, with
  `AINALRAMI_DIRECT_PLAIN=0`): the 29,843 walk answers of that run all
  came from the pruned walk and were held to the stages, and the 44,325
  rounds are again identical to v0.33.0.
* **Generated large fields**: the 60 opens above, paired in check mode
  (71 odd brackets over the group on zero, 22 more odd brackets, 7
  brackets that cannot pair, 17 pruned walks, 11 bootstraps, 364 pools and
  5,165 oracle answers checked, 0 differences), and again with
  `AINALRAMI_DIRECT=off`: the 540 rounds identical, and identical to the
  previous build's.
* `mix test`: 814 tests, 0 failures; `direct_bracket_test.exs` requires
  the zero group's shape, the bracket that cannot pair and a matched
  bootstrap to have been checked, and runs a pass with every walk pruned;
  `cardinality_matching_test.exs` checks `augment_from/4` against
  exhaustive search on 2,000 random graphs with dead vertices.

### What is left

Over the default corpus the direct brackets still gave up on 198,962
brackets whose local graph has no perfect matching (they go to the field
graph; below 100 players, and above it where some pair is possible), 5,826
whose floater the walk could not
show to be the stages', 1,654 MDP choices whose remainder needs an
exchange, 648 whose bounds no matching met, and 18 pruned walks past their
budget. A bracket that must float more players than its parity - some
pairs possible, not enough - is the shape still paid in full. On the
generated opens the slowest rounds left are 54-88 ms: a matched bootstrap
at 647 players, two pruned walks, a round 2 at 924 players, one such
bracket at 254 players and one pruned walk past its budget.

## The direct bracket on odd fields (2026-09-29)

A 1,001-player round 2 took **31.9 s**, where 1,000 players took 0.05 s:
two brackets of the odd field went to the whole-field matcher. It now
takes **0.12 s**, with the same pairing, and every answer on the
differential corpus is unchanged.

### Where the time was

The fuzz generator's position at 1,001 players (seed 9,501,001, the
position the Gacrux benchmark on the validation VM pairs), round 2: the
1.0 group (319) was already direct; the 0.5 bracket (364 residents and one
MDP, window 683) took 26.6 s and the 0.0 group with its floater (319)
5.3 s, both on the field graph (timed in-VM at `+S 4:4`).

* **The 0.5 bracket.** Its next group is the 0.0 group, the bye
  candidates, so the local graph turned it away (its members' completion
  terms vary), and the field-graph direct bracket did too: it required a
  window of non-candidates.
* **The last group.** The bracket the bye comes out of has the C9 gate on,
  which the field-graph direct bracket excluded by design.

### What changed

Three more shapes of the direct bracket, each argued in the section
comments of `Ainalrami.Pairing` (`attempt_direct_field/7`,
`attempt_direct_last/7`):

* **The last bracket of an odd field** (every mode, since nothing is
  paired after it). The bracket is the whole remaining graph, so once the
  walk finds a matching of all members but one that leaves a bye
  candidate over, every optimum is one; over those, the completion rung
  and C9 are sums of per-vertex terms fixed by the one left over - a bye
  candidate, then the least unplayed-game rank (C9: the assignee with the
  fewest unplayed games) - and C7 keeps every MDP paired. So the walk runs
  with the bye as its floater and the resident candidates of that least
  rank as its pool, and skips the per-edge completion and C9 tests whose
  sums the floater fixes. The stages read an unmatched member exactly as
  one matched to the local graph's stand-in (not paired down, in the
  remainder), which is the walk's model of an odd bracket's floater.
* **An odd bracket over the bye group** (certified mode): every member
  above the bye score, the next group the last one. The existing odd
  bracket's argument goes through with "the rest completed" read as
  "near-perfect, leaving a bye candidate over": a resident F meets the
  completion and C8 bounds exactly when the group and F have `q / 2`
  pairs covering F with a candidate left over, and every such F meets
  them alike. That set is exact and found for all residents at once: F
  qualifies when it can play some G that a maximum matching of the group
  plus a stand-in joined to its candidates can leave exposed - the D of
  the Gallai-Edmonds decomposition, one Edmonds search
  (`Ainalrami.CardinalityMatching`, checked against exhaustive search on
  3,000 random graphs) where the old per-floater question was a matching
  per resident.
* **An even bracket of an odd field** (certified mode), as on an even
  field: the bracket perfectly matched inside, the rest shown completable
  with a candidate over by the oracle, so C6 keeps it inside in every
  optimum.

On an odd field the next bracket's C9 gate reads the tentative partners
of this bracket's window; the new shapes are taken only where that read
is decided without them - the next group scores above the bye (the gate
is shut), or it is the last group (every partner the window can have
scores at least as much, so the gate reads true on both paths).

And one abort that was needlessly conservative: after a field-graph direct
bracket, a later bracket that would build the round matcher with a
different C9 gate from the reference's sent the whole round back to the
reference path. When that bracket's window is the whole remaining field
there is no far edge for the gate to have scored - the reference's
boundary sets every edge to the bracket's own weights - so it now goes on
(`builder_gate_whole_window` in the counters: 21 times in the default
corpus).

### Results

In-VM `Pairing.pair_next_round/2`, `+S 2:2`, medians of 3-7 runs, the
two builds run alternately on the same idle machine (an i7-10700); the
positions are the Gacrux benchmark's (`/root/bench.exs` on the validation
VM: the fuzz generator at seed `9,500,000 + players`, earlier rounds paired
by this engine). Every pairing is the same in both builds.

| position | before (bbcd392) | after |
|---|---|---|
| 1,001 players, round 2 | 31.9 s | **0.12 s** |
| 1,001 players, round 9 | 0.31-0.34 s | 0.31 s |
| 1,000 players, round 2 | 0.049 s | 0.049 s |
| 1,000 players, round 9 | 1.17 s | 1.17 s |

Round 2 at 1,001 players is now its three brackets answered directly:
65 ms for the 1.0 group (as before), 53 ms for the 0.5 bracket over the
bye group (the pool search and the walk) and 2 ms for the last group.
Gacrux takes 4.6 s on that position on the validation VM. Round 9's bye
comes out of an even bracket over a one-player last group, which moves
from the field graph (30 ms) to the direct bracket (2 ms); the rest of
that round is unchanged. The even field is untouched.

### How it was checked

* **Differential against v0.33.0** (`tools/perf_diff.exs`, the baseline
  logs of the passes below), default configuration: small 370,777 rounds,
  flags 68,898, large 5,497, early 1,980 - **447,152 rounds, 0 differing,
  0 missing** (89,665 + 16,964 + 477 + 60 of them with the alternatives
  fingerprinted). Its pairing calls took the new shapes 145,909 times:
  143,792 last brackets (every field size - this one needs no certified
  mode), 925 odd brackets over the bye group, 1,192 even brackets of an
  odd field; the relaxed builder gate went on 21 times.
* **Check mode** (`AINALRAMI_DIRECT=check`, which now also holds the new
  shapes to the field path on the same bracket from the same state -
  pairs, who is carried, how many float, and for the field-graph shapes
  the next bracket's C9 gate - and raises on any difference), certified
  mode forced, the first 400 tournaments of every axis of the four sets:
  44,325 rounds, identical to v0.33.0 end to end, with **33,367 new direct
  answers checked, 0 differences** (14,418 last brackets, 6,905 odd
  brackets over the bye group, 12,044 even brackets of an odd field),
  besides 60,481 of the existing field-graph shapes.
* **Generated odd fields**: 80 tournaments of 107-999 players (odd sizes
  drawn from 101-1,001; 3% requested byes, 2% forfeits, 1% withdrawals),
  9 rounds, paired in check mode - 566 new direct answers checked (250 last
  brackets, 142 odd over the bye group, 174 even of an odd field), 0
  differences - and again with `AINALRAMI_DIRECT=off`: the 720 rounds
  identical.
* `mix test`: 812 tests, 0 failures; `direct_bracket_test.exs` gains an
  axis of 101-151-player fields and requires each new shape to have been
  answered (and checked) at least once;
  `cardinality_matching_test.exs` checks the exposable set against
  exhaustive search on 3,000 random graphs.

### What is left

* **The bye group with a group below it.** An odd bracket, or an even
  one, whose next group holds the bye but is not the last group still
  falls back: the next bracket's C9 gate then depends on whether a window
  player is tentatively matched below, which is a read of the matcher's
  own tie-break.
* **An odd bracket over the bye group whose own members include bye
  candidates** falls back (the walk's per-edge completion test needs its
  members to be non-candidates).
* **A last bracket whose leftover cannot be a least-rank candidate**
  (the walk finds no matching meeting that bound, or runs past its
  budget) goes to the field graph as before.
* **Round 9 at 1,001 players** spends 0.22 s of 0.31 s in the first
  bracket, an existing odd-bracket shape whose pool question solves the
  whole-field completability oracle from cold.

## The direct bracket (2026-09-28)

On the benchmark files `docs/validation.md` compares the three engines
on, the pairing work - a cold run minus the engine's own start-up - is
now **0.08 s at 209 players, 0.11 s at 400, 0.14 s at 1,000, and 0.07 s
and 0.17 s for rounds 2 and 9 of a 600-player open**, from 0.32-7.2 s, and
the output is byte-identical to v0.33.0's. Gacrux (Python + networkx) was
faster than this engine on every file but a fresh round 1; it is now 3x
slower at 209 players and 9-46x slower on the rest.

### Results

Cold process, start to finish, median of 5 runs (3 at 1,000 players; min
within 0.03 s of the median everywhere): the same six files as
`docs/validation.md`'s 2026-09-28 re-run (`Ainalrami.Generator`, seed
`20260827 + players`; 5 rounds played and round 6 paired at 209, 400 and
1,000; rounds 1, 2 and 9 at 600), every file's boards identical across all
four programs, colours included (105/105, 200/200, 500/500, 300/300 x3).
"Before" is perf-certify (v0.34.0 plus the certified shortcuts), which this
builds on. An i7-10700 (8 cores, 16 threads) with one other job running
throughout at ~15% of total CPU.

| file | bbpPairings | Gacrux | before | after |
|---|---|---|---|---|
| 10 players (start-up floor) | **0.05 s** | 1.08 s | 0.75 s | 0.75 s |
| 209, round 6 | **0.59 s** | 1.32 s | 1.07 s | 0.83 s |
| 400, round 6 | 2.81 s | 2.05 s | 1.99 s | **0.86 s** |
| 1,000, round 6 | 51.6 s | 7.47 s | 7.92 s | **0.89 s** |
| 600, round 1 | 9.59 s | 2.22 s | 0.74 s | **0.74 s** |
| 600, round 2 | 8.29 s | 2.37 s | 7.47 s | **0.82 s** |
| 600, round 9 | 10.8 s | 3.63 s | 3.33 s | **0.92 s** |

Pairing work, each program's own floor subtracted:

| file | bbpPairings | Gacrux | before | after | after vs Gacrux |
|---|---|---|---|---|---|
| 209, round 6 | 0.54 s | 0.24 s | 0.32 s | **0.08 s** | 3.0x faster |
| 400, round 6 | 2.76 s | 0.97 s | 1.24 s | **0.11 s** | 8.8x |
| 1,000, round 6 | 51.6 s | 6.39 s | 7.17 s | **0.14 s** | 46x |
| 600, round 1 | 9.54 s | 1.14 s | 0.00 s | **0.00 s** | - |
| 600, round 2 | 8.24 s | 1.29 s | 6.72 s | **0.07 s** | 18x |
| 600, round 9 | 10.8 s | 2.55 s | 2.58 s | **0.17 s** | 15x |

Pinned to two schedulers (`ERL_FLAGS="+S 2:2"`, the production VPS; the
pairing is single-threaded) the after column is 0.80, 0.83, 0.86, 0.72,
0.78 and 0.89 s cold - the same within noise. What is left of a cold run
is the BEAM's start-up and reading the file; a 1,000-player round is now
cheaper to pair than to start the VM for. bbpPairings keeps the smallest
cold total on the 209-player file, on start-up alone (0.05 s against
0.75 s).

### Where the time was

Profiled on the six benchmark files (perf-certify, which this builds on,
timed in-VM with the per-bracket trace and `:tprof`):

| file | round | in-VM | where |
|---|---|---|---|
| 209 players | 6 | 0.30 s | two small top brackets on the whole-field graph 0.20 s, seven local brackets 0.10 s |
| 400 players | 6 | 1.2 s | a 3-player top bracket on the whole field 0.63 s, local brackets 0.6 s |
| 1,000 players | 6 | 7.2 s | local brackets 7.1 s: 213 players 2.8 s, 218 2.1 s, 172 1.4 s |
| 600 players | 2 | 6.8 s | field brackets of 172 (4.1 s) and 214 (2.1 s), a local one of 214 (0.7 s) |
| 600 players | 9 | 2.3 s | a 5-player top bracket on the whole field 1.5 s, local brackets 0.9 s |

Inside a bracket the time was the eight refinement stages' matcher work:
on the 213-player bracket, the initial solve ~0.6 s, stage 4's re-solve
1.4 s (its dual shift refused), stage 8 0.7 s. `:tprof` put 70-80% of a
round in `Ainalrami.WeightedMatching`.

Gacrux, `cProfile` on the same files: its pairing is one `pair_bracket`
per score group, and most brackets are answered by `simple_permute` - a
depth-first walk of Article 3's transposition order that accepts the first
candidate every pair of which is clean on C9-C21 and whose colour clashes
meet a counting bound - with a networkx `min_weight_matching` only where
that walk fails (4-11 small matchings a round on these files). Its time
goes mostly to building the crosstable - one Python object per pair of
players, 500,000 at 1,000 players (`list_edges`, 2.0 s of 7.1 s there) - and
the "hamilton" completability pre-pass (1.3 s); `pair_bracket` itself is
2.5 s at 1,000 players and 0.19 s at 600 players round 2. So Gacrux was
not faster code: it did less matching - a walk per bracket where this
engine ran eight stages of a general weighted matcher, on the whole field
for the top brackets.

### What changed

The same idea, held to a proof: a bracket whose answer can be shown to
be the stages' answer is answered without them. Three pieces, in
`Ainalrami.Pairing`:

* **The direct walk** ("the direct bracket"). For a bracket on the local
  graph, the stages' answer is the first matching, in the order "each MDP's
  partner in turn, then each S1 player's partner in turn", among the
  matchings of maximum criteria weight `C*` - when one of those pairs every
  MDP and pairs S1 into S2 with no exchange. The walk visits that order
  depth first and accepts a matching only when it meets an upper bound on
  every ladder rung at once - per-edge bests for C10, C11, C15, C17, C19
  and C21; counting bounds for C12 and C13 from the members' colour
  preferences; the floater's own downfloat bits for C14 and C16 - which
  makes it a `C*`-optimum outright; every choice it discards breaks a
  necessary condition of meeting those bounds. The derivation of each
  bound, and why each stage returns what the walk returns, is the
  section comment. It gives up (and the stages run as before) when a
  choice for an MDP passes every necessary condition but its remainder
  has no exchange-free answer, when it runs past a budget of `32n + 512`
  edge checks, or on soft pairs and the experimental ladder switches.
* **The small bracket.** A graph of at most 12 vertices has few enough
  maximum-weight matchings to list, and the stages' decisions are then
  filters over that list, applied in their order - stage 1 keeps an MDP
  inside if some optimum does, stage 2 and stage 8 take the best-ranked
  partner some optimum gives, stages 4-6 keep the exchange weights' optima
  and exchange a player if some optimum does. Every value a stage reads
  off the matching is checked to be the same across the optima left at
  that point, and a read that is not ends the attempt. This covers the
  small brackets the walk cannot, exchanges included.
* **Brackets the local graph turned away** (`attempt_direct_field/7`,
  certified mode only). An even bracket of an even field whose window
  holds players on zero - round 2 of every large open - is its own local
  problem once the rest of the field can be completed: with no bye, every
  optimum of the field graph is perfect and C6 then keeps the bracket
  inside. An odd bracket over a next group too small for the stand-in
  (the lone leaders at the top of a round) is the direct walk over the
  floaters the field below can absorb at the completion and C8 rungs'
  bounds: shown by the completability oracle for the rest of the field
  and a small exact matching on the next group plus the floater. Neither
  leaves the round matcher the reference would carry, so a later field
  bracket's reads are certified (the certified mode's own contract), and a
  later bracket that would build the matcher with a different C9 gate
  than the reference's sends the round back to the reference path.

And one cost the direct brackets exposed: the completability oracle was
solved from cold by every question asked of it before the first bracket
was accepted - eight times for the 400-player file's first bracket. It
is now solved once and kept; its answers are properties of its graph, not
of the state it keeps.

### How it was checked

Every check below ran on the committed engine.

#### Differential against v0.33.0: 892,324 rounds, 0 differences

`tools/perf_diff.exs` (described under the large-field pass below), run
on this tree and compared with the v0.33.0 logs of that pass, round by
round - the pairing or refusal, `explain_round/3`, the perturbed pairing's
explanation and `Alternatives.judge/4`, and on a sampled share of rounds
every forced search `Alternatives` runs. Twice: in the default
configuration, where the local-graph direct brackets run on every field
size and the field-graph ones from 100 players up, and with
`AINALRAMI_CERT=force`, which puts the field-graph ones on the small
fields too.

| set | default | `AINALRAMI_CERT=force` |
|---|---|---|
| small (8 axes, 4-40 players) | 370,777 rounds | 370,777 rounds |
| flags (field graph only, strand repair, completion reading) | 68,898 | 68,898 |
| large (60-600 players) | 5,497 | 5,497 |
| early (100-600 players, opening rounds) | 1,980 | - |
| | **447,152 rounds, 0 differing, 0 missing** | **445,172 rounds, 0 differing, 0 missing** |

214,272 of those rounds also fingerprinted the alternatives. The pairing
calls of the two runs (the alternatives' own forced pairings not counted)
were answered directly 2,113,871 times.

#### Each direct answer held to the stages' on the same bracket

`AINALRAMI_DIRECT=check` pairs every bracket the direct brackets answer
with the stages as well, from the same state, and raises on any
difference. Run on the first 400 tournaments of every axis of the four
sets (fewer where an axis has fewer), certified mode forced: 44,325
rounds, 149,356 direct answers checked, 0 differences - and the same
44,325 rounds identical to v0.33.0 end to end. `test/ainalrami/direct_bracket_test.exs`
does the same on 243 generated tournaments of 4-180 players at every
`mix test`, and also pairs every round with `AINALRAMI_DIRECT=off` and
requires the two to agree.

#### Against the references

* **`mix test --timeout 300000`**: 811 tests, 0 failures (5 tags excluded
  by default); `--only interop` 2 of 2.
* **bbpPairings, direction 1** (`mix test --only bbppairings`): 1,000
  tournaments of 4-40 players over 9 rounds (8,402 rounds, 99,305 pairs)
  and 100 of 60-160 players over 8 rounds (800 rounds, 43,888 pairs) -
  **100.00%, 0 refused, 0 illegal**, no disagreement about who is White on
  138,816 boards.
* **bbpPairings, direction 2** (`tools/bbp_generator_reverse.exs`, seeds
  910001-910600): bbpPairings could not generate 5; on the other 595,
  **5,930 rounds, 346,901 pairs, 0 composition mismatches**, 0 colour
  mismatches on 309,481 shared boards.
* The matcher (`Ainalrami.WeightedMatching`) is unchanged, so the
  lockstep was not re-run.

#### Reproducing

    # the corpus, resumably, against a baseline's logs
    DIFF_CHUNK=100 MIX_ENV=test mix run tools/perf_diff.exs corpus small OUT/new/small
    MIX_ENV=test mix run tools/perf_diff.exs compare OUT/base/small OUT/new/small

    # each direct answer against the stages, a slice of every axis
    AINALRAMI_DIRECT=check AINALRAMI_CERT=force DIFF_LIMIT=400 DIFF_CHUNK=50 \
      MIX_ENV=test mix run tools/perf_diff.exs corpus small OUT/check/small

    # the benchmark files
    ainalrami -g f.trf --seed=$((20260827 + N)) --players=N --rounds=5   # then 142 -> 9

### What is left, and what was tried

* **Where the direct brackets give up.** Over the check-mode run above,
  the walk and the small bracket answered 149,356 brackets; the stages
  still paired those with no perfect local matching (17,726 - they go to
  the field graph as before), those whose floater the walk could not show
  to be the stages' (1,405), MDP choices whose remainder needed an
  exchange (319, plus 285 whose bounds no matching met) and 250 walks
  past their budget. A large bracket that needs an exchange is the case
  still paid in full.
* **Odd fields.** An odd 1,001-player round 6 (seed 20261828), measured
  once while the differential corpus was running: Gacrux 11.8 s cold,
  perf-certify 10.7 s, this 2.2 s. Its first bracket asks the
  completability oracle once per member of an even next group (18 there);
  re-adding each member to one solved state instead of removing the rest
  from scratch each time is the next saving.
* **Not re-measured**: the explanation and the alternatives. Both call
  the same pairing, so both inherit the speed-up; the click tables of
  the large-field pass below are v0.34.0's.
* **Tried and fixed before the first commit**: the C13 bound first
  counted two absolute preferences for the same colour as a pair that
  keeps C13, which only the final-round exception allows - an unreachable
  bound, so the walk exhausted its budget on the large brackets of the
  1,000-player file (never a wrong answer, since nothing below a met
  bound is accepted). And the first cut of the field-graph odd brackets
  solved the oracle from cold for every question: 0.43 s of a 0.56 s
  round at 400 players.

## The large-field pass (2026-09-28)

A pass over the engine for fields of 150-600 players. A large field's
whole round - pairing, explanation and alternatives - is now **2.5-2.8x
faster on 2 cores** (the production VPS) and **3.5-5.2x on 12**, and the
output is **byte-identical to v0.33.0**: the same pairings, the same
`explain_round/3` account, the same alternatives, checked over 445,172
rounds. This document says where the time was, what changed, why each
change cannot move an answer, and how that was checked.

### Results

Generated opens of 150, 300, 450 and 600 players (`tools/perf_bench.exs`:
ratings falling with the starting rank, results drawn from FIDE's expected
score, 2% forfeits, 3% requested byes and a few forbidden pairs every
round; 9 rounds, 11 from 450 up; two tournaments per size), every round
re-paired from the state just before it, **v0.33.0 and this tree compiled
into the same VM and timed alternately round by round** (`PERF_REF`), with
their answers compared as they ran - identical on all 160 round-timings.
"Click" is what OpenPairings' "Pair round" asks of the engine: the
pairing, `explain_round/3`, and the float and bye alternatives it stores
with the round.

`+S 2:2` is the production VPS (2 vCPU); `+S 12:12` a desktop. The pairing
itself is single-threaded, so it is the same on both; the alternatives
run one forced search per scheduler and gain more the more cores there
are.

#### The whole click

At `+S 2:2`:

| field | rounds | p50 before | after | p95 before | after | max before | after | total speed-up |
|---|---|---|---|---|---|---|---|---|
| 150 | 18 | 2.84 s | 1.04 s | 4.98 s | 1.78 s | 11.1 s | 3.67 s | 2.7x |
| 300 | 18 | 4.01 s | 1.98 s | 25.0 s | 8.62 s | 29.5 s | 9.10 s | 2.8x |
| 450 | 22 | 12.1 s | 4.77 s | 67.7 s | 20.0 s | 170.8 s | 67.5 s | 2.7x |
| 600 | 22 | 18.2 s | 7.01 s | 52.5 s | 32.3 s | 115.4 s | 36.2 s | 2.5x |

At `+S 12:12`:

| field | rounds | p50 before | after | p95 before | after | max before | after | total speed-up |
|---|---|---|---|---|---|---|---|---|
| 150 | 18 | 2.98 s | 599 ms | 5.10 s | 818 ms | 11.6 s | 1.58 s | 5.2x |
| 300 | 18 | 3.88 s | 1.55 s | 25.3 s | 4.27 s | 29.2 s | 4.56 s | 4.5x |
| 450 | 22 | 12.9 s | 3.44 s | 68.6 s | 16.8 s | 171.4 s | 33.4 s | 4.6x |
| 600 | 22 | 19.5 s | 4.65 s | 57.3 s | 17.2 s | 116.2 s | 37.0 s | 3.5x |

By round, `+S 2:2` (with two tournaments per size, each cell is the
slower of the two):

| round | 150 before | after | 300 before | after | 450 before | after | 600 before | after |
|---|---|---|---|---|---|---|---|---|
| 1 | 496 ms | 370 ms | 2.80 s | 1.98 s | 9.07 s | 6.34 s | 20.6 s | 14.4 s |
| 2 | 1.06 s | 500 ms | 4.01 s | 2.43 s | 170.8 s | 67.5 s | 45.9 s | 36.2 s |
| 3 | 216 ms | 144 ms | 931 ms | 703 ms | 2.58 s | 1.68 s | 6.75 s | 3.52 s |
| 4 | 4.98 s | 1.78 s | 723 ms | 419 ms | 2.07 s | 1.02 s | 2.40 s | 1.91 s |
| 5 | 4.35 s | 1.52 s | 13.3 s | 4.62 s | 61.8 s | 19.9 s | 27.9 s | 11.7 s |
| 6 | 3.93 s | 1.44 s | 5.51 s | 2.56 s | 38.9 s | 13.2 s | 13.7 s | 4.62 s |
| 7 | 4.36 s | 1.57 s | 29.5 s | 9.10 s | 789 ms | 562 ms | 11.2 s | 5.13 s |
| 8 | 4.47 s | 1.54 s | 20.8 s | 6.37 s | 11.5 s | 4.77 s | 52.5 s | 14.1 s |
| 9 | 11.1 s | 3.67 s | 25.0 s | 8.62 s | 46.3 s | 16.3 s | 52.1 s | 18.3 s |
| 10 |  |  |  |  | 13.8 s | 3.84 s | 36.9 s | 12.6 s |
| 11 |  |  |  |  | 67.7 s | 20.0 s | 115.4 s | 32.3 s |

#### Each part, `+S 2:2`

The pairing:

| field | rounds | p50 before | after | p95 before | after | max before | after | total speed-up |
|---|---|---|---|---|---|---|---|---|
| 150 | 18 | 239 ms | 143 ms | 446 ms | 360 ms | 641 ms | 447 ms | 1.5x |
| 300 | 18 | 903 ms | 548 ms | 2.57 s | 1.96 s | 3.99 s | 2.42 s | 1.7x |
| 450 | 22 | 2.04 s | 1.09 s | 13.5 s | 8.22 s | 20.0 s | 15.8 s | 1.6x |
| 600 | 22 | 3.29 s | 1.88 s | 19.3 s | 14.3 s | 45.1 s | 36.1 s | 1.6x |

The explanation:

| field | rounds | p50 before | after | p95 before | after | max before | after | total speed-up |
|---|---|---|---|---|---|---|---|---|
| 150 | 18 | 19 ms | 3 ms | 24 ms | 17 ms | 27 ms | 20 ms | 3.9x |
| 300 | 18 | 52 ms | 6 ms | 111 ms | 9 ms | 116 ms | 80 ms | 4.9x |
| 450 | 22 | 209 ms | 13 ms | 275 ms | 16 ms | 278 ms | 210 ms | 7.9x |
| 600 | 22 | 41 ms | 20 ms | 540 ms | 25 ms | 551 ms | 26 ms | 10.2x |

The alternatives:

| field | rounds | p50 before | after | p95 before | after | max before | after | total speed-up |
|---|---|---|---|---|---|---|---|---|
| 150 | 18 | 2.55 s | 904 ms | 4.73 s | 1.64 s | 10.8 s | 3.52 s | 2.9x |
| 300 | 18 | 2.65 s | 818 ms | 23.9 s | 7.91 s | 28.5 s | 8.58 s | 3.2x |
| 450 | 22 | 10.3 s | 3.26 s | 65.4 s | 18.8 s | 157.2 s | 59.3 s | 3.1x |
| 600 | 22 | 6.73 s | 2.57 s | 50.1 s | 16.3 s | 110.3 s | 29.7 s | 3.3x |

#### Each part, `+S 12:12`

The pairing:

| field | rounds | p50 before | after | p95 before | after | max before | after | total speed-up |
|---|---|---|---|---|---|---|---|---|
| 150 | 18 | 224 ms | 144 ms | 443 ms | 356 ms | 635 ms | 461 ms | 1.5x |
| 300 | 18 | 915 ms | 564 ms | 2.54 s | 1.97 s | 3.86 s | 2.36 s | 1.7x |
| 450 | 22 | 2.21 s | 1.14 s | 13.7 s | 8.30 s | 20.2 s | 16.8 s | 1.6x |
| 600 | 22 | 3.41 s | 2.04 s | 20.2 s | 14.4 s | 46.3 s | 36.9 s | 1.6x |

The explanation:

| field | rounds | p50 before | after | p95 before | after | max before | after | total speed-up |
|---|---|---|---|---|---|---|---|---|
| 150 | 18 | 19 ms | 3 ms | 23 ms | 16 ms | 33 ms | 24 ms | 3.6x |
| 300 | 18 | 61 ms | 6 ms | 115 ms | 9 ms | 122 ms | 84 ms | 4.9x |
| 450 | 22 | 220 ms | 13 ms | 290 ms | 16 ms | 296 ms | 202 ms | 8.2x |
| 600 | 22 | 41 ms | 21 ms | 598 ms | 25 ms | 605 ms | 28 ms | 10.4x |

The alternatives:

| field | rounds | p50 before | after | p95 before | after | max before | after | total speed-up |
|---|---|---|---|---|---|---|---|---|
| 150 | 18 | 2.71 s | 470 ms | 4.85 s | 671 ms | 11.3 s | 1.43 s | 6.8x |
| 300 | 18 | 2.73 s | 509 ms | 24.3 s | 3.78 s | 28.2 s | 3.80 s | 6.6x |
| 450 | 22 | 10.6 s | 1.86 s | 66.1 s | 9.56 s | 157.7 s | 25.1 s | 6.7x |
| 600 | 22 | 6.68 s | 1.97 s | 54.5 s | 9.18 s | 111.0 s | 14.6 s | 6.4x |

#### The pairing by round, `+S 2:2`

| round | 150 before | after | 300 before | after | 450 before | after | 600 before | after |
|---|---|---|---|---|---|---|---|---|
| 1 | 446 ms | 360 ms | 2.57 s | 1.96 s | 8.44 s | 6.30 s | 19.3 s | 14.3 s |
| 2 | 641 ms | 447 ms | 3.99 s | 2.42 s | 20.0 s | 15.8 s | 45.1 s | 36.1 s |
| 3 | 167 ms | 137 ms | 916 ms | 693 ms | 2.55 s | 1.66 s | 5.72 s | 3.48 s |
| 4 | 239 ms | 143 ms | 569 ms | 407 ms | 1.44 s | 987 ms | 2.35 s | 1.88 s |
| 5 | 206 ms | 132 ms | 903 ms | 548 ms | 2.23 s | 1.36 s | 2.08 s | 1.49 s |
| 6 | 246 ms | 163 ms | 706 ms | 459 ms | 2.23 s | 1.36 s | 3.29 s | 2.10 s |
| 7 | 242 ms | 149 ms | 909 ms | 571 ms | 747 ms | 535 ms | 1.57 s | 1.19 s |
| 8 | 179 ms | 114 ms | 1.03 s | 582 ms | 987 ms | 766 ms | 1.94 s | 1.12 s |
| 9 | 267 ms | 170 ms | 997 ms | 629 ms | 2.15 s | 1.23 s | 3.46 s | 1.98 s |
| 10 |  |  |  |  | 937 ms | 568 ms | 3.37 s | 1.84 s |
| 11 |  |  |  |  | 2.10 s | 1.09 s | 4.66 s | 2.54 s |

Round 1 is two different cases, and the table shows the slower. On an
even field the refinement stages now run on dual shifts and round 1 is
**4-7x** faster (`+S 2:2`: 294 players 2.44 s -> 560 ms, 440 players
7.93 s -> 1.41 s, 586 players 18.6 s -> 2.76 s). On an odd field the
initial matching leaves a first-half player unmatched, the stage-4 shift
does not apply, the stage-7 reset is re-solved from cold, and round 1
gains 1.3x (437 players: 8.44 s -> 6.30 s; 581: 19.3 s -> 14.3 s).

**Rounds 1-2 of the largest fields are what is left.** At 600 players
round 2 is 45 s -> 36 s. Profiled on its own, that round's first bracket
(273 players, on the whole-field graph) takes 28 s of 40: 15 s building
and solving the round matcher from cold, 4 s re-solving after stage 4
and 8 s after stage 7. Those are the reference algorithm's cold solves
over the whole remaining field; on an odd field the next bracket's C9
gate reads the tie they settle in the field below, so nothing here may
pick a different optimum there. That is the next target (see "Tried and
reverted").

#### OpenPairings, end to end

OpenPairings' "Pair round" click (`PairingsEngine.Pairing.pair_next_round/2`)
timed span by span on a development copy (SQLite, the dev database), with
the same OpenPairings code against v0.33.0 and against this tree. Each
case imports a generated tournament of that size truncated before the
round, then pairs it; "club" gives every player one of n/8 clubs and
switches on OpenPairings' "keep clubmates apart" soft wish, which is
where a 450-player round 1 used to spend 22 s. OpenPairings' own work -
queries, building and parsing the TRF, writing the round, recording
deviations - is 50-120 ms and did not change; everything else is the
engine.

At `+S 2:2`:

| | 150 r7 plain before | after | 300 r7 plain before | after | 450 r1 club before | after | 450 r2 plain before | after |
|---|---|---|---|---|---|---|---|---|
| OpenPairings' own work | 53 ms | 48 ms | 90 ms | 94 ms | 105 ms | 120 ms | 111 ms | 113 ms |
| engine: pairing | 74 ms | 68 ms | 316 ms | 254 ms | 22.0 s | 1.63 s | 17.4 s | 12.6 s |
| engine: soft-wish re-pair | 0.0 ms | 0.0 ms | 0.0 ms | 0.0 ms | 0.3 ms | 0.2 ms | 0.0 ms | 0.0 ms |
| engine: explanation | 4.0 ms | 3.6 ms | 13 ms | 7.2 ms | 10 ms | 13 ms | 16 ms | 10 ms |
| engine: alternatives | 793 ms | 342 ms | 3.30 s | 1.42 s | 20 ms | 20 ms | 235.7 s | 101.1 s |
| click total | 924 ms | 462 ms | 3.72 s | 1.77 s | 22.1 s | 1.78 s | 253.2 s | 113.9 s |
| speed-up |  | 2.0x |  | 2.1x |  | 12.4x |  | 2.2x |

With all 16 schedulers:

| | 150 r7 plain before | after | 300 r7 plain before | after | 450 r1 club before | after | 450 r2 plain before | after |
|---|---|---|---|---|---|---|---|---|
| OpenPairings' own work | 50 ms | 49 ms | 90 ms | 97 ms | 114 ms | 98 ms | 104 ms | 100 ms |
| engine: pairing | 75 ms | 71 ms | 318 ms | 257 ms | 22.3 s | 1.66 s | 17.5 s | 12.6 s |
| engine: soft-wish re-pair | 0.0 ms | 0.0 ms | 0.0 ms | 0.0 ms | 0.3 ms | 0.2 ms | 0.0 ms | 0.0 ms |
| engine: explanation | 4.0 ms | 2.9 ms | 12 ms | 7.2 ms | 13 ms | 13 ms | 20 ms | 10 ms |
| engine: alternatives | 776 ms | 132 ms | 3.30 s | 551 ms | 24 ms | 23 ms | 235.3 s | 42.5 s |
| click total | 905 ms | 255 ms | 3.72 s | 912 ms | 22.5 s | 1.79 s | 252.9 s | 55.2 s |
| speed-up |  | 3.5x |  | 4.1x |  | 12.5x |  | 4.6x |

No OpenPairings change is needed to get this: the engine's API and every
answer are the same, so it arrives with the next Ainalrami release and
the pin bump that follows it. The dominant remaining cost of a late
round is still the alternatives, one forced re-pairing per candidate; on
the 2-vCPU server they run two at a time.

### Where the time was

Measured on v0.33.0 (`tools/perf_bench.exs`,
and OpenPairings' "Pair round" click instrumented span by span):

* **The click was the engine.** OpenPairings' own work - the queries,
  the TRF it builds, writing the round - is 50-120 ms of any click. At
  300 players, round 7, the pairing was 0.3 s of a 3.7 s click and the
  other 3.3 s were the **alternatives**: the "why him and not me"
  accounts OpenPairings stores with every round, one forced re-pairing of
  the whole round per candidate, run one after the other. At 450 players
  in round 2 they were 235 s of 253.
* **Rounds 1 and 2 were the pairing's worst case**, and round 1 with the
  arbiter's "keep clubmates apart" soft wishes the worst of all: 22 s at
  450 players. Rounds 1-2 put whole score groups of 200+ players on the
  field graph, where the refinement stages re-solve the matching from
  cold: stage 4 (exchange weights) and stage 7 (their reset) rewrite
  every remainder pair, and stage 8 re-solves once per player. In the
  club case stage 4 alone was 75% of the round.
* **Inside the matcher**, a sampling profile of a cold solve put ~45% of
  the time in map folds - the stage-start rescans of every free vertex's
  least edge to the outer set, and the cross table rewritten once per
  offer.
* **Everything else** was per-edge work that did not need to be: the
  played-opponent set and bye eligibility recomputed for every candidate
  edge, `colour_stats` twice a round, eighteen criteria folded for pairs
  where only five can be non-zero, and on an odd field a maximum-weight
  matching over the complete graph of the field to find the bye score
  (100 ms of every 300-player explanation).

### What changed, and why it cannot move an answer

Grouped by the argument that makes each one safe.

#### Same values, computed once

* **Per-round player facts** (`Pairing.with_round_facts/1`): who each
  player has met, whether they may take the bye, and how many games they
  played, computed once per player per round instead of once per edge;
  `colour_stats` once instead of twice.
* **Weights outside the bracket** (`outside_edge_weight/6`): a pair
  outside the bracket is weighted from the five rungs that can be
  non-zero there, at the positions the ladder itself reports, instead of
  folding all eighteen. The skipped rungs are gated to zero by
  `in_current`, so the packed integer is the same.
* **`Trf.game_was_played?/1`** answers the common result codes before
  trimming.
* **One explanation context per call** in `Alternatives`:
  `explain_round/3` is now `explain_context/3` (everything that depends on
  the players and options) composed with `explain_pairs/2` (everything
  that depends on the pairs), and a round's alternatives work the context
  out once instead of once per candidate.

These are refactors: the same functions of the same inputs.

#### The same searches, side by side

* **Alternatives run in parallel** (`Alternatives.attempts/1`), one
  forced search per scheduler. Each search is a complete pairing that
  reads nothing but its arguments - the engine's round state lives in the
  process dictionary of whichever process pairs - so each result is the
  value the sequential loop computed; results are collected in order, and
  a search that raises is re-raised in the caller exactly where the loop
  would have raised it. Tracing keeps the sequential order.

#### The matcher, held to v0.33.0 call by call

`Ainalrami.WeightedMatching` is shared by the individual and the team
engines, and it breaks ties by the order edges are offered - so a faster
matcher that finds a *different* optimum of the same weight would be a
different engine. Every change here keeps each tie-break:

* **A root-edge table** (`roots`, `root_min`): at a stage start every
  free vertex whose least edge to the outer set had gone used to walk its
  row, O(V^2) a stage and half of a cold solve. The table keeps each
  non-root's least edge to the exposed roots under a key that stays valid
  while the root stays outer, and is touched only where the root set
  changes.
* **Cross-table writes batched per settling blossom**: the offers of one
  settle are gathered and each touched entry, the settling blossom's row,
  its minimum and the running best written once instead of once per
  offer. An offer only ever replaces an entry by a strictly smaller one,
  and each of those values is a function of the final entries alone.
* **Row minima by a tight scan**, adjacency built a row at a time,
  `cross_retain/2` recomputing a surviving row's minimum once,
  `min_inner_blossom_dual/1` walking only the non-trivial blossoms.

`tools/matching_lockstep.exs` compiles v0.33.0's matcher beside the
working tree and drives both through the same random sessions - solves,
single and bulk weight changes, finalised pairs, dual shifts, reads, on
packed hundred-digit weights, plain weights, heavy ties and complete
graphs - comparing **every return value and every observable field of the
state** (duals, matching, blossoms, their bases, children and matches)
after every call. It detects a flipped tie-break in a single minimum
(mutation-tested). Result: every call identical, state included, over
46,000 sessions of the final matcher.

#### A certificate instead of a search: the bye bootstrap

On an odd field the bye assignee's score came from a maximum-weight
matching over the complete graph of the field. Its two outputs - the bye
score and the first bracket's C9 flag - depend on the optimum only
through three lexicographic quantities: that all but one player are
paired over compatible edges, the leftover's (eligibility, place), and
the number of pairs inside the top group. `certain_bootstrap/7` builds a
matching greedily and checks that it reaches the bound of all three; one
that does is optimal and gives the same answer. Any field it cannot
certify goes to the search exactly as before. Checked against the search
on 19,142 bootstraps before the self-check was taken out.

#### A dual shift instead of a re-solve: stages 4, 7 and 8

The refinement stages rewrite weights and re-solve: stage 4 adds the
exchange weights to every remainder pair, stage 7 takes them off again,
stage 8 adds a per-opponent addend to one player's edges at a time. Each
rewrite prepared every written vertex, and the solve rediscovered a
matching it usually already had. v0.33.0 already absorbed stage 4 on the
local graph by moving dual variables instead
(`WeightedMatching.shift_and_set/3`); now:

* **stage 4** does the same on the field graph when the bracket is
  everything left of the round - round 1, and every round's last bracket;
* **stage 7** moves each paired-down member's dual by what its own pair
  loses; every edge the reset keeps runs from a paired-down player to one
  who is not, so its slack is unchanged;
* **stage 8** raises the player's dual by the addend its current partner
  got.

`shift_and_set/3` checks the optimality conditions on everything the
shift touches - every dual non-negative, every matched edge tight, every
written edge feasible (and every edge of a vertex whose dual went down)
- and refuses otherwise, in which case the stage re-solves as before. So
the matcher always holds an optimum; the question is whether it could be
a different optimum from the re-solve's, and whether that could show.
What stages 5-8 read from the matching is whether a player is paired
down, and each such read is decided by the weights: stage 4's guard term
fixes the number of exchanges in every optimum; stages 5 and 6 ask each
player's question with a one-unit nudge on even weights, so the answer is
"is there an optimum where this player is (not) paired down" whichever
optimum the matcher holds, and commit it by cutting edges no optimum
still uses; stage 8's addends are distinct per opponent and sit below
every criterion, so every optimum gives the player the same partner. The
one read of a tie is C9's gate for the next bracket, which on an odd
field looks at the carried players' tentative partners in the field below
- which is why the field graph shifts only when there is no field below.
(Tried and measured: allowing it on even fields as well gained nothing on
the bench, so it was left out.)

That is an argument, not a proof by construction like the lockstep; the
differential corpus below is the check, and every one of its rounds that
reaches a last bracket or a local bracket goes through these shifts.

### How it was checked

Every check below ran on the final engine (commit `eb23820`, the
matcher unchanged since `b958b3e`), not on an intermediate one.

#### Differential against v0.33.0: 445,172 rounds, 0 differences

`tools/perf_diff.exs` plays generated tournaments forward
(`Ainalrami.Test.FuzzTournament`, the generator every corpus in this
project uses) and fingerprints, for every round, everything the engine
answers: the pairing - or the refusal, with its reason, excluded ranks,
override and message; `explain_round/3` on it; `explain_round/3` and
`Alternatives.judge/4` on a perturbed pairing (two boards' Black players
swapped, as when an arbiter edits a round); and on a sampled share of
rounds every forced search `Alternatives` runs - float and bye
alternatives at the default cap (and uncapped on small fields),
`force_pair/5` and `no_show/4`. On top of the generator's own knobs, drawn
from a separate random stream, a third of the tournaments carry soft
pairs (either position) and a third of the rounds organiser bye
exclusions. Run once in a v0.33.0 checkout and once on this tree, then
compared line by line:

| set | axis | players | tournaments | rounds | what it adds |
|---|---|---|---|---|---|
| small | s_plain | 4-40 | 6,000 | 51,513 | - |
| | s_byes | 4-40 | 6,000 | 51,136 | 10% byes, 6% forfeits, withdrawals |
| | s_forbid_accel | 4-40 | 6,000 | 51,177 | 10% forbidden pairs, accelerations |
| | s_late | 4-40 | 5,000 | 42,634 | 15% late entrants |
| | s_points | 4-40 | 5,000 | 42,654 | point systems, initial colour, rating modes |
| | s_combined | 4-40 | 8,000 | 67,302 | all of the above, up to 13 rounds |
| | s_tiny_deep | 4-12 | 6,000 | 38,665 | up to 11 rounds on tiny fields |
| | s_late_half | 4-40 | 3,000 | 25,696 | late entrants on half-point byes, Baku |
| flags | f_nofast | 4-60 | 3,000 | 26,119 | every bracket on the field graph |
| | f_strand | 4-40 | 3,000 | 25,619 | completion repair forced |
| | f_completion | 4-40 | 2,000 | 17,160 | the eligibility completion reading |
| large | l_60_120 | 60-120 | 400 | 3,600 | byes, forfeits, forbidden, accelerations |
| | l_150_250 | 150-250 | 150 | 1,501 | point systems, late entrants, up to 11 rounds |
| | l_300_600 | 300-600 | 36 | 396 | 11 rounds, accelerations |
| | | | **70,586** | **445,172** | **0 rounds differing, 0 missing** |

107,106 of those rounds also fingerprinted the alternatives. The rule
readings the engine distinguishes by flag are covered: `AINALRAMI_NOFAST`
(no local graph), `AINALRAMI_FORCE_STRAND`, `AINALRAMI_COMPLETION`.
Before the last engine change three smaller runs held the intermediate
builds to v0.33.0 as well (12,882 + 12,820 rounds at 4-40, 1,080 at
60-200), and 744 round-1 fields of 4-129 players with club soft pairs or
forbidden pairs.

#### The matcher: lockstep with v0.33.0

`tools/matching_lockstep.exs` on the final matcher: 46,000 random
sessions (seeds 700,000-705,999 and 1,000,001-1,040,000) shaped like the
engine's - packed bignum weights with the nearness term, small plain
weights with heavy ties, complete graphs, single-vertex, row and
whole-graph edits, finalised pairs and dual shifts - with every return
value and every observable field of the state equal to v0.33.0's after
every call. Each intermediate matcher commit was held to the same test
before it was committed (up to 30,000 sessions each).

#### Against the references

* **`mix test --timeout 300000`**: 804 tests, 0 failures (5 tags
  excluded by default); `--only interop` (the 209-player real
  tournament, replayed) 2 of 2.
* **bbpPairings, direction 1** (this engine's generated tournaments,
  bbpPairings asked to pair the same history, `mix test --only
  bbppairings`): 3,000 tournaments of 4-40 players over 9 rounds,
  25,255 rounds and 299,216 pairs, and 150 tournaments of 60-160 players
  over 8 rounds, 1,200 rounds and 67,576 pairs - **100.00%, 0 refused, 0
  illegal**, and no disagreement about who is White on 353,711 boards.
* **bbpPairings, direction 2** (`tools/bbp_generator_reverse.exs`: 3,000
  fresh tournaments from bbpPairings' own generator, seeds
  900001-903000, 15-215 players, 5-15 rounds, every round replayed):
  bbpPairings could not generate 10 of them; on the other 2,990,
  **29,854 rounds, 1,730,270 pairs, 0 composition mismatches**, and 0
  colour mismatches on 1,543,847 shared boards.
* **Team Swiss (C.04.6) whole rounds against the brute-force reference**
  (`team_pairing_validation_test.exs`, which shares the matcher):
  909,989 rounds of 4-10 teams (seeds 1-220,000) and 247,976 with no
  colour preferences (seeds 1-60,000), **0 failures**.
* **Bye exclusions against their brute-force reference**
  (`bye_exclusion_validation_test.exs`, seeds 1-10,000): 52,456 rounds,
  **0 disagreements** - the same counts, branch for branch, as the
  release's own run.
* **The bye bootstrap certificate** against the search it replaces:
  19,142 certified bootstraps, all equal, before the self-check was
  removed.


### Tried and reverted

* **A per-solve cache of row lists** in the settle loop, to avoid
  `:maps.to_list/1` per settle: 0.95-1.0x. Reverted.
* **Per-stage vertex views** (tuples for blossom membership and labels):
  2-4% on a cold solve, not worth the second representation. Reverted.
* **The stage-4/7/8 shifts on every bracket of an even field**: safe by
  the argument above (nothing reads the field below's tie on an even
  field), but the first big bracket of round 2 is rarely in the shape the
  shift needs, and the bench showed 1.0x. Left out rather than carried
  for nothing.
* **Not attempted**: skipping the stage-4 re-solve on non-last field
  brackets of odd fields, where C9 reads the tie; certificates of a
  unique optimum for the stage solves; a two-table cross design in the
  matcher. Each would need an argument this pass could not make airtight.

### Reproducing

    # bench, this tree against v0.33.0 in one VM, alternately
    ELIXIR_ERL_OPTIONS="+S 2:2" PERF_REF=v0.33.0 mix run tools/perf_bench.exs

    # matcher lockstep against v0.33.0
    LOCKSTEP_SESSIONS=30000 MIX_ENV=test mix run tools/matching_lockstep.exs

    # differential corpus: the same tool (this tree's copy) run once in a
    # v0.33.0 checkout and once here, for each of small, flags and large
    cd ../v0.33.0-checkout
    MIX_ENV=test mix run ../this-tree/tools/perf_diff.exs corpus small OUT/base/small
    cd ../this-tree
    MIX_ENV=test mix run tools/perf_diff.exs corpus small OUT/new/small
    MIX_ENV=test mix run tools/perf_diff.exs compare OUT/base/small OUT/new/small
