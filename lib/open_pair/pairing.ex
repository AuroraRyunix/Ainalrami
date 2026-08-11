defmodule OpenPair.Pairing.NoValidPairingError do
  @moduledoc """
  Raised when the active players cannot be simultaneously paired while
  satisfying the absolute criteria (no rematch, no double colour-absolute
  clash) — not a search failure, a proven structural deadlock.

  Direct analogue of bbpPairings' own `NoValidPairingException`
  (`swisssystems/dutch.cpp`'s `matchingIsComplete`/`compatible`): it
  computes ONE matching over the whole field and throws rather than ever
  emitting more byes than `rem(active_count, 2)`. `OpenPair.Pairing`
  matches that: `repair_bye_count/3`'s last-resort pass
  (`OpenPair.Blossom`, verified to find a TRUE maximum matching
  regardless of starting point) only reaches this if the true maximum
  itself still leaves too many players unmatched — proof no legal
  completion exists, not evidence the search didn't try hard enough. A
  small field deep into a Swiss (colour-absolute exclusions stacking on
  top of near-exhausted rematch-free opponents) is the realistic way to
  hit this, not a bug in the matcher.
  """
  defexception [:message]
end

defmodule OpenPair.Pairing do
  @moduledoc """
  The actual Dutch-system pairing algorithm. Implemented incrementally —
  see TODO.md for the staged plan and its documented simplifications
  (`pair_next_round/1`'s doc lists exactly which parts of the real FIDE
  procedure aren't faithfully implemented yet).

  A pairing is represented as `{white_rank, black_rank | nil}` — `nil` for
  a pairing-allocated bye, the same convention `OpenPair.Trf`'s parsed game
  records use (`opponent_rank: nil`), rather than JaVaFo's own text-output
  convention of a literal `0` (that translation happens only at the
  CLI/output-formatting boundary).

  A player is `%{rank:, points:, games: [%{opponent_rank:, colour:, result:}]}`
  — the shape `OpenPair.Trf.parse/1` returns.
  """

  alias OpenPair.{Blossom, WeightedMatching}

  # This engine used to carry a second pairing path — a per-bracket
  # cascade with a backtracking search over alternative matchings, tuned
  # by five module attributes that lived here. It is gone, along with
  # ~950 lines, because `global_cascade/2` beat it at every field size and
  # then stopped falling back to it at all.
  #
  # The note those attributes carried is still worth keeping, because it
  # predicted this: a no-backtracking version of the OLD cascade measured
  # 97.19% -> 81.99% of pairs, and the reason given was that bbpPairings
  # needs no backtracking only because its weights are richer — locality
  # graded rather than partitioned, plus an exchange-minimisation
  # refinement. That is exactly what the current path implements, and it
  # needs no backtracking either.
  @bye_score_key :openpair_bye_score
  @expected_rounds_key :openpair_expected_rounds

  @doc """
  Pairs the next round, dispatching to `pair_round_one/1` when no game
  history exists yet, or the bracket cascade below otherwise.
  """
  def pair_next_round(players, opts \\ []) do
    # The tournament's total round count, when the caller knows it (a
    # TRF's `XXR`/`142`). Only one rule needs it — the final-round
    # exception in `colour_compatible?/2` — so it is optional rather than
    # a required argument, and stashed rather than threaded through the
    # cascade, matching how the search budget is already carried.
    Process.put(@expected_rounds_key, opts[:expected_rounds])

    try do
      active = Enum.filter(players, &active_this_round?(&1, rounds_played(players)))

      if Enum.all?(active, &(&1.games == [])) do
        pair_round_one(active)
      else
        # The FULL roster, not just the active players — float direction
        # has to look up opponents' scores, and an opponent may be one of
        # the players sitting this round out.
        pair_later_round(players)
      end
    after
      Process.delete(@expected_rounds_key)
    end
  end

  @doc """
  Scores an ALREADY-CHOSEN pairing against this engine's own C1-C21
  ladder, bracket by bracket. A diagnostic, not part of pairing.

  `pairs` is `[{white_rank, black_rank | nil}]` — any complete pairing of
  `players`, including one produced by a different engine. The brackets a
  pairing implies are reconstructed from it: score groups top-down, with
  each bracket's unpaired members carried into the next as its MDPs.

  Returns one map per bracket, `%{group:, mdps:, residents:, floats:,
  rungs: [{label, total}]}`, where each total is that criterion summed
  over the pairs the bracket keeps.

  The point is to adjudicate a disagreement rather than guess at it.
  Score both engines' answers and compare the first bracket where they
  differ:

    * the reference scores BETTER — this engine's search or tie-break
      failed to reach a pairing its own ladder prefers.
    * this engine scores better — then the ladder itself is wrong, since
      the reference would not violate a criterion it implements.
    * identical — the difference is below the criteria entirely, i.e.
      transposition/exchange ordering.

  ## What it cannot see

  It scores only the pairs a bracket KEEPS, so the two C8 rungs — which
  grade what a pairing leaves reachable in the brackets BELOW — are always
  zero here. C8 outranks every colour and float criterion, so a verdict of
  "this engine scores better on C12" may really mean "the reference is
  better on C8, which this cannot measure". Treat a C12 verdict as a lead,
  not a conclusion, and check the bracket below by hand.

  Verified against `colour_stats/1`, which is a faithful port of
  `computePlayerData` (tournament.cpp:43) rung for rung — including that a
  perfectly balanced player still has a MILD preference for the opposite
  of their last colour, and only a player who has never played has none.
  So a C12 verdict is not evidence of a bug in the colour model.
  """
  def explain_round(players, pairs, opts \\ []) do
    Process.put(@expected_rounds_key, opts[:expected_rounds])

    try do
      field =
        players
        |> Enum.filter(&active_this_round?(&1, rounds_played(players)))
        |> Enum.sort_by(&{-&1.points, &1.rank})
        |> Enum.map(&Map.put(&1, :colour_stats, colour_stats(&1)))

      brackets = field |> Enum.group_by(& &1.points) |> Enum.map(fn {_s, m} -> m end)
      Process.put(@bye_score_key, bye_assignee_score(brackets, rem(length(field), 2)))

      partner = partner_map(pairs)
      ctx = global_context(field)

      groups = Enum.chunk_by(field, & &1.points)

      groups
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {group, i}, {acc, mdps} ->
        next_group = Enum.at(groups, i + 1, [])
        players_below = groups |> Enum.drop(i + 1) |> Enum.map(&length/1) |> Enum.sum()

        # Approximates `bracket_loop/6`'s `single_bye?`/`next_single_bye?`
        # gate (see that function's own doc) — NOT a full port: the real
        # gate also requires `ctx.bye_score >= hd(next_group).points` and
        # every carried MDP's partner to score at least that, both of
        # which depend on the live cascade's own mid-solve state
        # (`carried_partner_scores`) that this post-hoc reconstruction
        # from a finished `pairs` list doesn't have. This is still a real
        # fix over what it replaces: `edge_rungs/6` used to be called with
        # a hardcoded `false` here, so C9 (bye unplayed games) never
        # scored ANYTHING in this diagnostic, regardless of whether the
        # real search actually had it active — silently blinding
        # `tools/adjudicate.exs` to C9 on every single case. Confirmed via
        # direct instrumentation of `pair_bracket/5`'s own `single_bye?`
        # argument (seed223-r9-p23's score-3.0 bracket: really `true`,
        # this formula also says `true` for that exact case) that this
        # approximation is at least not a false negative for the cases
        # investigated so far — a false POSITIVE (this says true when the
        # extra conditions above would have said false) is still possible
        # and would show up as C9 over-counting in some other case.
        single_bye? =
          ctx.odd_field? and not is_nil(ctx.bye_score) and rem(players_below, 2) == 0

        {report, floated} =
          explain_bracket(mdps ++ group, group, next_group, partner, ctx, single_bye?)

        {[report | acc], floated}
      end)
      |> elem(0)
      |> Enum.reverse()
    after
      Process.delete(@expected_rounds_key)
      Process.delete(@bye_score_key)
    end
  end

  defp partner_map(pairs) do
    Enum.reduce(pairs, %{}, fn
      {w, nil}, acc -> Map.put(acc, w, nil)
      {w, b}, acc -> acc |> Map.put(w, b) |> Map.put(b, w)
    end)
  end

  defp explain_bracket(bracket, group, next_group, partner, ctx, single_bye?) do
    ranks = MapSet.new(bracket, & &1.rank)
    score = hd(group).points

    # A bracket member is kept here when their partner is also in it;
    # everyone else floats on and becomes the next bracket's MDP.
    {kept, floated} =
      Enum.split_with(bracket, fn p ->
        case Map.get(partner, p.rank) do
          nil -> false
          other -> MapSet.member?(ranks, other)
        end
      end)

    by_rank = Map.new(bracket, &{&1.rank, &1})

    edges =
      kept
      |> Enum.map(fn p -> Enum.min_max([p.rank, Map.fetch!(partner, p.rank)]) end)
      |> Enum.uniq()

    # The C8 rungs grade what a bracket leaves reachable BELOW it, so they
    # are scored over the pairs that reach from this bracket into the next
    # score group — exactly the edges the real matcher sees with
    # `in_current` false. Leaving them out was this diagnostic's blind
    # spot: C8 outranks every colour and float criterion, so two answers
    # differing only there used to come back as "tie on every rung", and
    # the C12 verdict below them was then read as a colour bug.
    next_ranks = MapSet.new(next_group, & &1.rank)
    cross_by_rank = Map.new(bracket ++ next_group, &{&1.rank, &1})

    cross_edges =
      bracket
      |> Enum.flat_map(fn p ->
        case Map.get(partner, p.rank) do
          nil -> []
          other -> if MapSet.member?(next_ranks, other), do: [{p.rank, other}], else: []
        end
      end)
      |> Enum.uniq()

    {places, place_span} = score_places(bracket ++ next_group)
    count_span = length(bracket) + length(next_group) + 1

    bands = %{
      places: places,
      place_span: place_span,
      count_span: count_span,
      reserve: 2 * count_span * count_span * count_span
    }

    kept_rungs =
      Enum.map(edges, fn {x, y} ->
        {a, b} = order_by_placement(Map.fetch!(by_rank, x), Map.fetch!(by_rank, y))
        edge_rungs(a, b, 0, ctx, bands, single_bye?)
      end)

    cross_rungs =
      Enum.map(cross_edges, fn {x, y} ->
        {a, b} = order_by_placement(Map.fetch!(cross_by_rank, x), Map.fetch!(cross_by_rank, y))
        edge_rungs(a, b, 1, ctx, bands, single_bye?)
      end)

    rungs = sum_rungs(kept_rungs ++ cross_rungs)

    {%{
       group: score,
       mdps: bracket |> Enum.filter(&(&1.points > score)) |> Enum.map(& &1.rank),
       residents: Enum.map(group, & &1.rank),
       pairs: edges,
       floats: Enum.map(floated, & &1.rank),
       rungs: rungs,
       order: Enum.map(bracket, & &1.rank),
       lex: transposition_key(bracket, group, partner)
     }, floated}
  end

  # FIDE section 3's transposition order, as a comparable key.
  #
  # Articles 3.3-3.5 pick the SMALLEST transposition of the natural order,
  # and "smallest" is lexicographic over S2 — which member of S2 faces
  # S1[0], then S1[1], and so on, with the identity permutation smallest.
  # So the key is the S2 INDEX of each S1 member's opponent, in S1 order,
  # and a smaller key wins.
  #
  # Getting this wrong is easy and was: a first attempt keyed on absolute
  # bracket position, which makes the natural pairing (0 vs k, 1 vs k+1)
  # look large and the adjacent pairing (0 vs 1) look smallest — the
  # opposite of the Dutch structure. It is also why `spread` in
  # `within_bracket_weight/4` is load-bearing rather than decorative:
  # maximising rank distance is what produces the S1-vs-S2 halving in the
  # first place, and removing it measured 90.29% -> 42.21% of rounds.
  defp transposition_key(bracket, group, partner) do
    score = hd(group).points
    {mdps, residents} = Enum.split_with(bracket, &(&1.points > score))

    {s1, s2} =
      if mdps == [] do
        Enum.split(bracket, div(length(bracket), 2))
      else
        {mdps, residents}
      end

    s2_index = s2 |> Enum.map(& &1.rank) |> Enum.with_index() |> Map.new()
    unpaired = length(s2)

    Enum.map(s1, fn p ->
      case Map.get(partner, p.rank) do
        nil -> unpaired
        other -> Map.get(s2_index, other, unpaired)
      end
    end)
  end

  defp order_by_placement(x, y) do
    if {-x.points, x.rank} <= {-y.points, y.rank}, do: {x, y}, else: {y, x}
  end

  defp sum_rungs([]), do: []

  defp sum_rungs([first | _] = per_edge) do
    Enum.with_index(first)
    |> Enum.map(fn {{label, _v, _span}, i} ->
      {label, Enum.sum(Enum.map(per_edge, fn rungs -> elem(Enum.at(rungs, i), 1) end))}
    end)
  end

  @doc """
  Pairs the very first round.

  Per FIDE C.04.3 Article 1: split the full field into two equal halves by
  rank (S1 = top half, S2 = bottom half — everyone is tied on 0 points, so
  rank order alone determines the split); an odd field first removes the
  lowest-ranked player for the pairing-allocated bye, then splits the
  remaining even field. Pair S1[i] against S2[i].

  Confirmed against real `javafo.jar` output for 7/8/9/10/11/12/13-player
  fields, not assumed from the spec text alone.

  Colours (Article 5.1/5.2.5): FIDE leaves the very first colour to a
  literal "drawing of lots" — there is no deterministic rule to replicate.
  This picks a fixed, documented convention rather than JaVaFo's own
  choice, which is empirically NOT a function of the roster/round-count
  alone: pairing the identical 8-player roster and round count under two
  different tournament *names* produced opposite initial colours from
  JaVaFo — strong evidence it's seeded from something incidental (a hash
  of the input file, most likely), not a reproducible rule. Colour output
  will legitimately not always match JaVaFo's own for this reason; pairing
  *composition* (who plays whom) is the thing that should match, and does
  — see the comparison harness in `test/open_pair/javafo_comparison_test.exs`.
  """
  def pair_round_one(players) do
    sorted = Enum.sort_by(players, & &1.rank)

    {bye, field} =
      if rem(length(sorted), 2) == 1 do
        {List.last(sorted), List.delete_at(sorted, -1)}
      else
        {nil, sorted}
      end

    half = div(length(field), 2)
    {s1, s2} = Enum.split(field, half)

    pairs =
      s1 |> Enum.zip(s2) |> Enum.map(fn {top, bottom} -> assign_colour_round_one(top, bottom) end)

    if bye, do: pairs ++ [{bye.rank, nil}], else: pairs
  end

  # `top` is always the better-ranked (lower rank number) of the pair, since
  # both halves are traversed in ascending rank order before zipping.
  #
  # Our fixed initial-colour convention is White — an odd rank for the
  # better-ranked player gets White (the initial colour), an even rank gets
  # Black (the opposite). If this convention ever needs to be the other way
  # round, flip the branches here directly rather than reintroducing a
  # switchable constant — with only one convention ever in use, that
  # abstraction was dead code the compiler rightly flagged.
  defp assign_colour_round_one(top, bottom) do
    if rem(top.rank, 2) == 1 do
      {top.rank, bottom.rank}
    else
      {bottom.rank, top.rank}
    end
  end

  @doc """
  Pairs a round from existing score/game history.

  Forms score brackets (Article 1.2: ranked by score, then TPN ascending)
  in descending order and pairs bracket by bracket, floating players down
  to merge with the next bracket when a bracket can't be fully paired
  (Articles 1.3.3/3.2/3.3 — a "heterogeneous" bracket, floaters ranked
  ahead of the new bracket's own residents per their higher score, which
  falls out of re-sorting the merged group by Article 1.2 directly).

  Pairing within a bracket is a general (non-bipartite) maximum-weight
  matching over that bracket (`OpenPair.Matching`), scored by
  `pair_weight/4` and `float_weight/3`. The criteria and their priority
  order are ported from bbpPairings' `computeEdgeWeight`
  (`swisssystems/dutch.cpp`): four colour criteria, then four
  float-history criteria, then MDP displacement and rank spread.

  **97.15% of individual pairs and 88.93% of whole rounds match real
  `javafo.jar`** over 300 nine-round tournaments of 10-40 players, and
  94.05% / 76.96% with a tenth of games forfeited — see TODO.md for the
  measured history of how each term got there, and the per-round
  breakdown (round 1 is exact, round 9 is 91.54% of pairs).

  **Known simplifications versus the full FIDE procedure**:

    * The bracket-ordering terms (MDP displacement, rank spread) stand in
      for FIDE's own transposition/exchange search (Articles 3.3-3.5) and
      for the three lowest criteria of bbpPairings' own list.
    * The four SCORE-WEIGHTED float criteria (bbpPairings weights each
      float criterion by which score group it affects) aren't implemented,
      only the four unweighted ones.
    * The cascade approximates a global matching. bbpPairings runs one
      over the whole field before pairing anything, to prove a legal round
      exists; this searches bracket by bracket with backtracking and a
      bounded budget, falling back to a best-effort answer past it.

  **Do not "simplify" the scoring terms without re-measuring.** Five
  separate plausible-sounding changes here have each been measured WORSE
  and reverted (see TODO.md): a bipartite S1-vs-S2 restriction (10.7%), a
  whole-bracket natural-correspondence deviation metric (64.95%),
  subordinating the float protections to the pair criteria (-7 points),
  ordering the cascade's alternatives by weight rather than by floater
  count (-40 points on round 2), and prepending rather than appending in
  `OpenPair.Matching`'s candidate list, which silently inverted a
  tie-break for the same -40. The terms below are empirical, not derived.
  """
  def pair_later_round(players) do
    played = rounds_played(players)
    active = Enum.filter(players, &active_this_round?(&1, played))

    brackets =
      players
      # Float history first, over the WHOLE roster: `float_direction/3`
      # compares against the opponent's score at the time, and that
      # opponent may be sitting this round out.
      |> with_float_history(played)
      |> Enum.filter(&active_this_round?(&1, played))
      |> Enum.group_by(& &1.points)
      |> Enum.sort_by(fn {score, _} -> -score end)
      |> Enum.map(fn {_score, members} -> members end)

    # Exactly one pairing-allocated bye in an odd field, none in an even
    # one. Counted over the ACTIVE players — a field of even size with one
    # player sitting out needs a bye, and one of odd size with one sitting
    # out does not.
    allowed_byes = rem(length(active), 2)

    Process.put(@bye_score_key, bye_assignee_score(brackets, allowed_byes))

    try do
      case global_cascade(brackets, allowed_byes) do
        {:ok, pairs, leftover} ->
          pairs
          |> Kernel.++(Enum.map(leftover, &{&1.rank, nil}))
          # Cheap when everything is already legal (`bye_legal?/3`'s check
          # is the only work done), and a real safety net if the cascade's
          # own eligibility check ever has a gap this does not.
          |> repair_bye_count(active, allowed_byes)

        :infeasible ->
          # `global_cascade/2` only reports this once its own completion
          # repair — a whole-field maximum matching — has also failed to
          # pair everyone, which means no legal round exists at all.
          # bbpPairings answers the same case the same way, with
          # `NoValidPairingException`.
          raise OpenPair.Pairing.NoValidPairingError,
                "no legal pairing exists for #{length(active)} active player(s)"
      end
    after
      Process.delete(@bye_score_key)
    end
  end

  # Last resort: take whatever the deterministic cascade produced and try
  # to fix it into something legal via `OpenPair.Blossom`'s general-graph
  # maximum-weight-free matching (augmenting paths, with contraction for
  # odd cycles — see that module's doc).
  #
  # An earlier version of this ran a plain alternating-path BFS with no
  # blossom handling. Measured at 30 rounds in a 32-40 player field, that
  # closed 1477/2997 illegal rounds to 65 — real progress, but the
  # remaining 65 were specifically the cases a blossom-blind search cannot
  # reach: an odd cycle among the round's OWN unresolved pairing
  # possibilities hiding a legal augmenting path from a naive search.
  #
  # Strictly an improvement regardless of how many byes it closes: it
  # never unpairs anyone, never runs on a round the cascade already
  # solved, and a round that ends up legal is worth more than a
  # better-scored round that is not a legal pairing at all.
  #
  # Checks bye ELIGIBILITY (C2), not just bye COUNT. `eligible_for_bye?/1`
  # was previously enforced only as the backtracking search's own success
  # condition (see `cascade_brackets/1`'s history) — a player who already
  # had a pairing-allocated bye could still end up floated again here
  # without anything catching it, since `Blossom.augment/3` only
  # guarantees MAXIMUM CARDINALITY, not WHICH specific vertex is left
  # unmatched when more than one maximum matching exists. Fixed by
  # processing ineligible floaters FIRST — `Blossom.augment/3` runs one
  # augmenting-path search per vertex in the order given, applying each
  # path it finds before moving to the next, so a vertex searched first
  # gets first claim on a scarce augmenting path an eligible player would
  # otherwise "use up" by sheer iteration order.
  #
  # `Blossom.augment/3` is proven to reach a TRUE maximum matching
  # regardless of starting point (Berge augmenting paths), so if its
  # result STILL exceeds `allowed_byes` or still leaves an ineligible
  # player unmatched despite going first, that is not this pass failing
  # to try hard enough — it is proof no legal completion exists at all.
  # Traced two "still illegal after repair" cases to ground the
  # count-only version of this: one (10 players, round 8) had a player
  # who had already played every active opponent except one that was
  # colour-absolute-blocked — a genuine deadlock, confirmed independently
  # by an exhaustive active-players-only search, not a missed solution.
  # Silently returning the extra-bye pairing anyway was the actual bug —
  # bbpPairings' own `compatible`/`matchingIsComplete` never accepts more
  # than `rem(active_count, 2)` byes either; it throws
  # `NoValidPairingException` instead (`swisssystems/dutch.cpp`).
  defp repair_bye_count(result, active, allowed_byes) do
    by_rank = Map.new(active, &{&1.rank, &1})

    if bye_legal?(result, by_rank, allowed_byes) do
      result
    else
      # Colour stats are normally stamped inside `bracket_options/2`;
      # this path never went through it.
      stamped_by_rank =
        Map.new(by_rank, fn {r, p} -> {r, Map.put(p, :colour_stats, colour_stats(p))} end)

      matching = Map.new(result, fn {w, b} -> {w, b} end) |> add_reverse_edges()

      neighbours_fun = fn rank ->
        player = Map.fetch!(stamped_by_rank, rank)

        stamped_by_rank
        |> Map.values()
        |> Enum.filter(
          &(&1.rank != rank and legal_pair?(player, &1) and colour_compatible?(player, &1))
        )
        |> Enum.map(& &1.rank)
      end

      ineligible = bye_ranks(result) |> Enum.reject(&eligible_for_bye?(Map.fetch!(by_rank, &1)))
      ordered_ranks = Enum.sort_by(Map.keys(stamped_by_rank), &(&1 not in ineligible))

      repaired =
        ordered_ranks
        |> Blossom.augment(matching, neighbours_fun)
        |> to_pairs(active)

      if bye_legal?(repaired, by_rank, allowed_byes) do
        repaired
      else
        raise OpenPair.Pairing.NoValidPairingError,
          message:
            "no legal pairing exists for this round: the maximum matching over " <>
              "#{length(active)} active players still leaves " <>
              "#{length(bye_ranks(repaired))} unmatched (#{allowed_byes} allowed, some " <>
              "possibly bye-ineligible)"
      end
    end
  end

  defp bye_ranks(pairs), do: for({white, nil} <- pairs, do: white)

  defp bye_legal?(pairs, by_rank, allowed_byes) do
    byes = bye_ranks(pairs)
    length(byes) <= allowed_byes and Enum.all?(byes, &eligible_for_bye?(Map.fetch!(by_rank, &1)))
  end

  defp add_reverse_edges(matching) do
    Enum.reduce(matching, %{}, fn
      {_white, nil}, acc -> acc
      {white, black}, acc -> acc |> Map.put(white, black) |> Map.put(black, white)
    end)
  end

  defp to_pairs(matching, active) do
    {pairs, _seen} =
      Enum.reduce(Enum.sort_by(active, & &1.rank), {[], MapSet.new()}, fn player, {acc, seen} ->
        cond do
          MapSet.member?(seen, player.rank) ->
            {acc, seen}

          partner = Map.get(matching, player.rank) ->
            {acc ++ [{player.rank, partner}],
             seen |> MapSet.put(player.rank) |> MapSet.put(partner)}

          true ->
            {acc ++ [{player.rank, nil}], MapSet.put(seen, player.rank)}
        end
      end)

    pairs
  end

  # How many rounds the tournament has actually completed.
  #
  # Neither the minimum nor the maximum games count works. The minimum
  # breaks on a late entrant, who has no games at all and would make
  # everyone else look like they'd already been paired — measured, it
  # emptied the pairing entirely. The maximum breaks on a pre-recorded
  # bye, which is the very thing being detected.
  #
  # bbpPairings resolves it by only advancing `playedRounds` for games the
  # player PARTICIPATED IN THE PAIRING for (`trf.cpp:339-342`): a real
  # game, or a pairing-allocated bye, but not an arbiter-assigned one. So
  # the round number is the furthest any player has been genuinely paired
  # to, and a half-point bye recorded in advance doesn't move it.
  defp rounds_played(players) do
    players |> Enum.map(&paired_through/1) |> max_or_zero()
  end

  defp paired_through(player) do
    player.games
    |> Enum.with_index(1)
    |> Enum.filter(fn {game, _round} -> participated_in_pairing?(game) end)
    |> Enum.map(fn {_game, round} -> round end)
    |> max_or_zero()
  end

  # bbpPairings' `opponent != id || resultChar == 'U' || resultChar == '+'`
  # — a bye counts as having been paired only when it's the
  # pairing-allocated one (or a forfeit win, which still occupied a slot).
  defp participated_in_pairing?(game) do
    not is_nil(game.opponent_rank) or game.result in ["U", "+"]
  end

  defp max_or_zero([]), do: 0
  defp max_or_zero(values), do: Enum.max(values)

  # A player is paired this round only if they don't already have a result
  # for it. bbpPairings has exactly this test — `if (player.matches.size()
  # <= tournament.playedRounds)` before pushing onto `sortedPlayers`
  # (`dutch.cpp:658`) — and it's the mechanism by which requested
  # half-point byes, zero-point byes and retirements work at all: the
  # arbiter records the result in advance, and the engine then leaves that
  # player out of the pairing.
  #
  # This engine paired them anyway, which meant a player who had asked for
  # a bye got a game. Confirmed against javafo on a six-player case where
  # player 6 held a pre-recorded half-point bye: javafo paired the other
  # five and gave the odd one out the pairing-allocated bye, while this
  # engine paired player 6 with player 4.
  defp active_this_round?(player, rounds_played), do: length(player.games) <= rounds_played

  # Stamp each player's float direction for the last two rounds, once per
  # round rather than per candidate pair — `float_direction/3` needs every
  # player (it compares against the OPPONENT's score at the time), which
  # `pair_weight/4` doesn't have and shouldn't need.
  defp with_float_history(players, played) do
    by_rank = Map.new(players, &{&1.rank, &1})

    Enum.map(players, fn player ->
      Map.put(player, :floats, %{
        1 => float_direction(player, 1, by_rank, played),
        2 => float_direction(player, 2, by_rank, played)
      })
    end)
  end

  # Which way a player was floated `rounds_back` rounds ago — a port of
  # bbpPairings' `getFloat` (`dutch.cpp`). A float isn't recorded anywhere
  # in a TRF; it's *derived*, by comparing what the two players' scores
  # were when they were paired. Outscoring your opponent that round means
  # you were floated DOWN to meet them.
  #
  # An unplayed round counts as a downfloat whenever it scored better than
  # a loss, so a pairing-allocated bye is a downfloat — which is what makes
  # this criterion bite in odd-sized tournaments.
  # Indexed by the TOURNAMENT's played-round count, not by the player's own
  # game count — bbpPairings reads `player.matches[tournament.playedRounds
  # - roundsBack]`. The two are the same only while every player has an
  # entry per round, which arbiter-assigned byes break: a player carrying a
  # pre-recorded bye for the round about to be paired has one game MORE
  # than the tournament has played, so `length(games) - 1` pointed at that
  # future bye instead of their last real round, and every float criterion
  # C14-C21 then read a fabricated history for them.
  defp float_direction(player, rounds_back, by_rank, played) do
    index = played - rounds_back

    if index < 0 or index >= length(player.games) do
      :none
    else
      game = Enum.at(player.games, index)

      cond do
        not played?(game) ->
          if result_points(game.result) > 0.0, do: :down, else: :none

        not is_map_key(by_rank, game.opponent_rank) ->
          :none

        true ->
          mine = score_before(player, rounds_back, played)
          theirs = score_before(Map.fetch!(by_rank, game.opponent_rank), rounds_back, played)

          cond do
            mine > theirs -> :down
            mine < theirs -> :up
            true -> :none
          end
      end
    end
  end

  # A player's score as it stood after round `played - rounds_back` —
  # current score minus what every later round paid out. bbpPairings keeps
  # the same thing as `scoreWithAcceleration(tournament, roundsBack)`.
  #
  # Counted from the TOURNAMENT's round number for the same reason
  # `float_direction/4` is: a player holding a pre-recorded bye has an
  # extra game, and taking "the last `rounds_back`" off their own list
  # then subtracts the wrong rounds.
  defp score_before(player, rounds_back, played) do
    player.games
    |> Enum.drop(max(played - rounds_back, 0))
    |> Enum.reduce(player.points, fn game, score -> score - result_points(game.result) end)
  end

  defp result_points(result) do
    case result do
      "1" -> 1.0
      "+" -> 1.0
      "F" -> 1.0
      "U" -> 1.0
      "=" -> 0.5
      "H" -> 0.5
      _ -> 0.0
    end
  end

  defp float_of(player, rounds_back) do
    player |> Map.get(:floats, %{}) |> Map.get(rounds_back, :none)
  end

  # bbpPairings' bracket algorithm, ported stage for stage from
  # `dutch.cpp` 1011-1649. This replaces an earlier port that solved each
  # score level once; see "Why one matching is not enough" below.
  #
  # ## The graph is the current bracket plus the next score group
  #
  # `playersByIndex` holds the current bracket followed by the whole of
  # the NEXT score group, and nothing else — every other player has no
  # edge at all. Local indices, in the field's own `(-points, rank)`
  # order:
  #
  #     [0, sgb)      MDPs — moved down from a bracket above
  #     [sgb, nsgb)   residents — this bracket's own score group
  #     [nsgb, m)     the next score group, present only to be pairable
  #
  # `computeBaseEdgeWeights` (dutch.cpp:607) only builds an edge when the
  # LARGER index is at least `sgb`, so two MDPs never have an edge: a
  # moved-down player is paired against a resident or not at all.
  #
  # The first port put the ENTIRE remaining field in one graph and threw
  # the far pairs away afterwards. By then the matcher had already traded
  # a good internal pair for two of them — the discard happens after the
  # optimum is chosen, not before.
  #
  # ## Why one matching is not enough
  #
  # A maximum-weight matching decides everything at once and may return
  # any optimum. bbpPairings does not let it: it calls `computeMatching()`
  # seven times per bracket, each call re-solving the SAME graph after a
  # targeted nudge that forces exactly one decision, which is then frozen
  # with `finalizePair` before the next question is asked. The stages, in
  # order, are `stage_select_mdps/1` (which moved-down players get paired
  # at all), `stage_mdp_opponents/1` (who each one plays),
  # `stage_build_remainder/1` and `stage_exchange_weights/1` (what is left
  # and how it splits), the two exchange-selection loops, the reset pass,
  # and `stage_first_group_partners/1`.
  #
  # Those last five are FIDE C.04.3 §3's transposition and exchange
  # procedure, done properly. The per-bracket cascade approximates it with
  # two invented terms, `deviation` and `spread`, which is the divergence
  # docs/fide-criteria.md calls "the largest remaining gap". They are
  # deliberately absent from this ladder: the exchange stages ARE the
  # mechanism they stand in for, and keeping both would let a stand-in
  # outvote the real thing.
  #
  # ## Arithmetic
  #
  # `computeEdgeWeight` leaves `3 * scoreGroupSizeBits + 1` bits of
  # RESERVED low space (dutch.cpp:462-469) that the stages write into, so
  # a nudge can break a tie without ever outranking a real criterion.
  # `bands.reserve` is that space, and every stage addend lives inside it.
  #
  # `edgeWeightComputer`'s addend goes NEGATIVE (dutch.cpp:1076 subtracts
  # from a value that is zero whenever its guard bit is clear). In C++
  # that is unsigned wraparound; here it is just subtraction, which is
  # what the wraparound computes. It borrows into the criterion above,
  # but can never invert an ordering: the borrow is under `2 * s`, and one
  # unit of the lowest criterion is `reserve = 2 * s^3`.
  #
  # ## What it measures, and why it is still not the default
  #
  # 200 tournaments x 9 rounds against bbpPairings, same harness the other
  # figures in TODO.md come from:
  #
  #     this cascade, before the stages     60.51% rounds / 93.6% pairs
  #     this cascade, stages ported         90.11% rounds / 96.82% pairs
  #     the per-bracket cascade (default)   90.29% rounds / 97.21% pairs
  #
  # So the architecture is vindicated — the missing 30 points really were
  # the refinement, exactly as predicted — but it lands on PARITY, three
  # rounds in 1689 behind the thing it was meant to beat, and it is still
  # behind on pairs. It stays off until it actually wins.
  #
  # Where the two differ is informative. This cascade is BETTER in the
  # middle rounds (3: 97.00 vs 93.50, 4: 97.40 vs 95.83, 5: 94.79 vs
  # 92.19) and worse in the late ones (7: 83.15 vs 84.24, 8: 80.24 vs
  # 82.04, 9: 66.47 vs 69.46). Late rounds are where legal pairings get
  # scarce, which is where the per-bracket cascade's backtracking earns
  # its keep — measured at 15 points of pairs on its own. This cascade has
  # no backtracking at all, by design, because bbpPairings has none.
  # Closing the remaining gap most likely means the whole-field
  # feasibility pre-pass bbpPairings runs first (dutch.cpp:825-837), which
  # is what lets it commit to a bracket decision without ever needing to
  # revisit one.
  #
  # ## Two things measured as INERT, and one of them removed
  #
  # The canonical lexicographic tie-break this engine relies on everywhere
  # else (`lex_scale/1`) was carried here too at first, below the reserved
  # space. It makes no difference whatever: removing it, and even
  # INVERTING it, both reproduce 1522/1689 and the same disagreement set,
  # byte for byte. The switch was verified to be live before believing
  # that — a bad value raises `CaseClauseError` from inside the run. So it
  # is gone from this path, which is also what makes the bignums small
  # enough to solve a bracket eight times over without cost.
  #
  # That is a real result, not a null one: a tie-break exists to choose
  # among equally-optimal matchings, and having nothing left to choose is
  # the claim bbpPairings' design makes for its own staged refinement.
  #
  # C9's rung measured inert on THIS fixture set, which runs at a 0% bye
  # rate and so barely exercises it. With byes it matters a great deal,
  # and its gate has to be ported in full to help rather than hurt: see
  # `bracket_loop/6`, where the dutch.cpp:1636-1643 clearing step lives.
  # Half-ported it measured WORSE than having no C9 rung at all.

  # THE pairing path. There is no longer a second one.
  #
  # A per-bracket cascade with backtracking used to sit behind this as a
  # fallback, and for a while it was the default. It is gone: this beat it
  # on every field size measured, and once the bracket loop stopped ending
  # a round early (see `bracket_loop/6`) the fallback stopped being
  # reached at all — zero times in ~1700 rounds, with byes and forfeits
  # on. Keeping ~950 lines of a second engine warm for a path nothing
  # takes is worse than not having it.
  #
  # What replaced it as the safety net is `repair_completion/3`, which is
  # part of THIS engine rather than a different one: if the staged
  # refinement leaves anyone unpairable, one whole-field matching fixes
  # the completion while keeping as much of the cascade's answer as it
  # can. Only when that also fails does `pair_later_round/1` raise
  # `NoValidPairingError`, which at that point is the truth — a
  # whole-field maximum matching could not pair everyone either.
  defp global_cascade(brackets, allowed_byes) do
    field =
      brackets
      |> List.flatten()
      |> Enum.sort_by(&{-&1.points, &1.rank})
      |> Enum.map(&Map.put(&1, :colour_stats, colour_stats(&1)))

    ctx = global_context(field)
    {pairs, leftover} = run_brackets(field, ctx)

    # The staged refinement is not told how many byes are legal, so the
    # result is checked rather than assumed. Falling back to the
    # backtracking cascade beats emitting an illegal round.
    case check_completion(pairs, leftover, allowed_byes) do
      :ok ->
        {:ok, pairs, leftover}

      {:incomplete, reason} ->
        # The staged refinement finalises pairs one at a time and locks
        # them, so a bracket can in principle commit a pair that leaves
        # someone further down unpairable.
        #
        # The three engines guard this differently. bbpPairings proves a
        # complete matching exists before it starts and throws if not
        # (dutch.cpp:828 — a CHECK, with no repair anywhere), then trusts
        # its incremental matcher to preserve completeness. Gacrux
        # precomputes per-level feasibility ("hamilton") and uses it to
        # reject a bracket choice that would strand the rest. This one
        # repairs after the fact instead.
        if System.get_env("OPENPAIR_TRACE_FALLBACK"), do: IO.puts("[repair] #{reason}")

        case repair_completion(field, pairs, allowed_byes) do
          {:ok, repaired, repaired_leftover} = ok ->
            case check_completion(repaired, repaired_leftover, allowed_byes) do
              :ok -> ok
              {:incomplete, r} -> trace_fallback("repair failed: #{r} (was #{reason})")
            end

          :infeasible ->
            trace_fallback("no complete matching exists (#{reason})")
        end
    end
  end

  defp check_completion(_pairs, leftover, allowed_byes) do
    cond do
      length(leftover) > allowed_byes ->
        {:incomplete, "stranded #{length(leftover)}, allowed #{allowed_byes}"}

      not Enum.all?(leftover, &eligible_for_bye?/1) ->
        {:incomplete, "bye assignee is C2-ineligible"}

      not Enum.all?(leftover, &bye_score_ok?/1) ->
        {:incomplete, "bye assignee's score is above the C5 minimum"}

      true ->
        :ok
    end
  end

  # One whole-field matching that must (a) pair as many players as
  # possible, then (b) keep as much of the cascade's own answer as it can,
  # then (c) prefer pairing equal scores where it has to choose.
  #
  # (a) strictly above (b) is the point: the cascade's answer is already
  # the criteria-best one it could find, so the ONLY reason to overrule it
  # is that it left someone unpairable. Ranking cardinality first means
  # this breaks exactly as many of its pairs as completion requires and no
  # more — usually one, since the shortfall is usually a single pair.
  defp repair_completion(field, pairs, allowed_byes) do
    n = length(field)

    if n < 2 do
      :infeasible
    else
      arr = List.to_tuple(field)
      chosen = MapSet.new(pairs, fn {w, b} -> Enum.min_max([w, b]) end)

      # Five strictly-ordered bands. Cardinality first, so the repair
      # breaks exactly as many of the cascade's pairs as completion
      # demands — usually one, since the shortfall is usually one pair.
      #
      # Then the two ABSOLUTE criteria that constrain who may be left
      # over, both phrased the way `bye_assignee_score/2` phrases them:
      # pairing a player who may NOT take the bye is preferred, so
      # whoever ends up unmatched is someone C2 and C5 allow. Cardinality
      # alone does not pin this down — several maximum matchings usually
      # exist and they do not leave the same vertex out — so without
      # these bands the repair would hand `check_completion/3` a complete
      # matching whose leftover is a player who has already had a bye,
      # and the whole round was then refused as impossible. That was the
      # entire "illegal" column at high round counts: 142 rounds out of
      # 2126 at 39 rounds, every one of which bbpPairings paired legally.
      #
      # Preservation fourth, so among the completions that satisfy all of
      # the above it keeps as much as it can of the criteria-best answer
      # the cascade already found. The criteria themselves last, to
      # settle WHICH of several equally preserving completions to take:
      # without that the choice falls to the matcher's arbitrary
      # tie-break, and an arbitrary choice measurably loses rounds the
      # cascade had right.
      s = n + 1
      criteria_span = Integer.pow(s, 9)
      preserve = criteria_span * s
      bye_score_band = preserve * s
      eligibility_band = bye_score_band * s
      cardinality = eligibility_band * s

      edges =
        Enum.flat_map(0..(n - 2), fn i ->
          a = elem(arr, i)

          Enum.flat_map((i + 1)..(n - 1), fn j ->
            b = elem(arr, j)

            if legal_pair?(a, b) and colour_compatible?(a, b) do
              keep =
                if MapSet.member?(chosen, Enum.min_max([a.rank, b.rank])), do: preserve, else: 0

              eligibility = bit(not eligible_for_bye?(a)) + bit(not eligible_for_bye?(b))
              bye_score = bit(not bye_score_ok?(a)) + bit(not bye_score_ok?(b))

              weight =
                cardinality + eligibility * eligibility_band + bye_score * bye_score_band +
                  keep + repair_criteria(a, b, s)

              [{i, j, weight}]
            else
              []
            end
          end)
        end)

      matching = WeightedMatching.solve(n, edges)
      leftover = for i <- 0..(n - 1), not is_map_key(matching, i), do: elem(arr, i)

      if length(leftover) > allowed_byes do
        :infeasible
      else
        repaired =
          for {i, j} <- matching,
              i < j,
              do: assign_colour_with_history({elem(arr, i), elem(arr, j)})

        {:ok, repaired, leftover}
      end
    end
  end

  # The subset of the ladder that still means something with no brackets
  # to speak of: keep equal scores together (C6/C7's whole purpose),
  # satisfy colour (C10-C13), and respect float history (C14-C17). The
  # bracket-relative rungs — C8's reach, C9's bye gate — have no referent
  # in a whole-field matching and are left out rather than faked.
  defp repair_criteria(a, b, s) do
    {higher, lower} = order_by_placement(a, b)
    {c1, c2, c3, c4} = colour_criteria(higher, lower)
    {f1, f2, f3, f4} = float_criteria(higher, lower)

    ranked([
      {bit(a.points == b.points), s},
      {bit(c1), s},
      {bit(c2), s},
      {bit(c3), s},
      {bit(c4), s},
      {f1, s},
      {f2, s},
      {f3, s},
      {f4, s}
    ])
  end

  defp trace_fallback(reason) do
    if System.get_env("OPENPAIR_TRACE_FALLBACK"), do: IO.puts("[fallback] #{reason}")
    :infeasible
  end

  # Everything the ladder needs that is genuinely round-wide. The spans
  # themselves are per bracket — see `pair_bracket/4`.
  defp global_context(field) do
    bye_score = Process.get(@bye_score_key)

    %{
      bye_score: bye_score,
      unplayed_ranks: unplayed_ranks(field, bye_score),
      odd_field?: rem(length(field), 2) == 1
    }
  end

  # dutch.cpp:879-892. Rank the played-game counts of everyone who could
  # take the bye, most games played first, so a rung that MAXIMISES weight
  # prefers PAIRING the player with the most unplayed games — which is how
  # you leave the bye to someone with the fewest. Equal counts collapse
  # onto the last rank written, exactly as the C++ map assignment does.
  defp unplayed_ranks(_field, nil), do: %{}

  defp unplayed_ranks(field, bye_score) do
    field
    |> Enum.filter(&(&1.points == bye_score))
    |> Enum.map(&played_games/1)
    |> Enum.sort(:desc)
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {played, rank}, acc -> Map.put(acc, played, rank) end)
  end

  defp played_games(player), do: Enum.count(player.games, &played?/1)

  # dutch.cpp:981 — keep going while a bracket still has two players to
  # pair OR there is another score group to bring in.
  defp run_brackets(field, ctx) do
    case Enum.chunk_by(field, & &1.points) do
      [] -> {[], []}
      [first | rest] -> bracket_loop(first, 0, rest, ctx, [])
    end
  end

  defp bracket_loop(by_index, _sgb, [], _ctx, pairs) when length(by_index) <= 1 do
    {pairs, by_index}
  end

  # The FIRST bracket's C9 flag was hardcoded `true`, which is only right
  # for a field that is a single score group. C9 is about the bye
  # assignee, and the bye comes from the BOTTOM of the field, so in a
  # multi-group field the top bracket is the one place it certainly does
  # not apply. Same test as `next_single_bye?` below, minus the parts that
  # need a previous bracket's tentative matching.
  defp bracket_loop(by_index, sgb, rest_groups, ctx, pairs) do
    players_below = Enum.sum(Enum.map(rest_groups, &length/1))

    single_bye? =
      ctx.odd_field? and not is_nil(ctx.bye_score) and rem(players_below, 2) == 0

    bracket_loop(by_index, sgb, rest_groups, ctx, pairs, single_bye?)
  end

  defp bracket_loop(by_index, _sgb, [], _ctx, pairs, _single_bye?) when length(by_index) <= 1 do
    {pairs, by_index}
  end

  defp bracket_loop(by_index, sgb, rest_groups, ctx, pairs, single_bye?) do
    nsgb = length(by_index)

    {next_group, rest} =
      case rest_groups do
        [] -> {[], []}
        [group | tail] -> {group, tail}
      end

    # Both confirmed anomalies (see `test/fixtures/open_questions/`) have
    # the same signature: the bracket's own current+next graph does not
    # explain bbpPairings' choice, and in the fixtures an IDENTICAL graph
    # answers differently depending on what lies below it. C8 is the
    # criterion that is supposed to reach down — "choose the downfloaters
    # so the FOLLOWING bracket complies with C1-C7" — so the obvious test
    # is whether the graph needs to see one group further than the C8
    # rungs currently do.
    #
    # Only the group after next is ADDED to the graph; it is not consumed,
    # and nothing in it can be finalised (a pair is kept only when both
    # ends are below `nsgb`). It goes back to `rest` untouched.
    peek = peek_groups(rest, peek_budget(), [])

    {new_pairs, carried_all, new_sgb, carried_partner_scores} =
      pair_bracket(by_index ++ next_group ++ peek, sgb, nsgb, ctx, single_bye?)

    peeked = MapSet.new(peek, & &1.rank)
    carried = Enum.reject(carried_all, &MapSet.member?(peeked, &1.rank))

    # dutch.cpp:1607-1643, computed at the END of a bracket for the NEXT
    # one. C9 applies only where a bracket downfloats exactly one player
    # and that player takes the bye, so the preliminary test (odd field, a
    # next group exists, and the bye's score is at or above it) is then
    # CLEARED if any carried player is already tentatively matched below
    # that group — because then the float runs deeper than one bracket and
    # the criterion does not apply.
    #
    # Leaving that clearing step out is not harmless. With it missing the
    # rung fired in brackets bbpPairings excludes, and measured WORSE than
    # having no C9 rung at all: 83.14% against 83.73% of exact rounds at
    # an 8% bye rate.
    # How many players sit BELOW the next bracket is the missing half of
    # "downfloating exactly ONE player RECEIVING THE BYE". The clearing
    # step above only asks whether THIS bracket's floats run deeper than
    # one group; it cannot see how many players the next bracket will
    # itself float, and a bracket that floats two — one to pair below, one
    # to take the bye — is not a C9 bracket at all.
    #
    # An EVEN number below can pair among itself, so the next bracket's
    # lone floater has nobody left to meet and the bye is theirs. An odd
    # number cannot: one of them needs a partner from above, so the
    # bracket must float two and C9 has no single assignee to talk about.
    #
    # Both traced cases turn on exactly this count:
    #
    #   seed260-r7-p9   one player (2, at 1.5) below bracket 3.0. Odd, so
    #                   the bracket floated 7 to play them AND 5 to the
    #                   bye. C9 fired anyway and, sitting above the colour
    #                   rungs, outscored bbpPairings' pairing — which
    #                   satisfied a colour preference ours did not
    #                   (C12 1 vs 0).
    #
    #   seed335-r8-p13  two players (10 at 2.5, 11 at 2.0) below bracket
    #                   3.0. Even, and they paired with each other, so the
    #                   bracket's single floater took the bye exactly as
    #                   C9 describes.
    #
    # Two stricter readings were measured and rejected. `rest == []` ("no
    # group below at all") silences seed335 and cost 0.02-0.24 points
    # across the bye and forfeit profiles. Gating on the next bracket's
    # own SIZE being odd — the same parity argument applied one level up —
    # was far worse (97.57% against 99.94% at a 15% bye rate), because a
    # bracket of odd size does not reliably float exactly one: whoever is
    # left over depends on who can legally pair inside it at all.
    players_below = Enum.sum(Enum.map(rest, &length/1))

    next_single_bye? =
      ctx.odd_field? and not is_nil(ctx.bye_score) and next_group != [] and
        rem(players_below, 2) == 0 and
        ctx.bye_score >= hd(next_group).points and
        Enum.all?(carried_partner_scores, &(&1 >= hd(next_group).points))

    # bbpPairings loops unconditionally because by this point it has
    # already PROVED a complete legal matching exists — its whole-field
    # pre-pass throws `NoValidPairingException` otherwise (dutch.cpp:828).
    # This engine deliberately carries on when that pre-pass finds nothing
    # (`bye_assignee_score/2` returns nil rather than aborting), so a last
    # bracket whose players simply cannot play each other would spin here
    # forever: no pairs made, nothing consumed, same arguments next time.
    #
    # The test is whether a group was CONSUMED, not whether any are left.
    # An earlier version stopped on `rest == []`, which is the state after
    # popping the final group — so the round ended on the very iteration
    # that first brought that group in, before the players it carried had
    # any chance to pair with it. They were reported stranded and the
    # round was handed to the fallback engine. That single wrong condition
    # was most of the fallbacks.
    # `OPENPAIR_FORCE_STRAND=1` restores the old, wrong condition on
    # purpose. `repair_completion/3` is the engine's only completion
    # safety net and it never fires in normal running — measured zero
    # times across every configuration — which would leave it as untested
    # emergency code. This is the fault injection that tests it: with the
    # flag on, roughly a tenth of rounds strand, and the suite asserts
    # every one of them still comes out legal.
    stop? =
      if System.get_env("OPENPAIR_FORCE_STRAND"),
        do: rest == [] and new_pairs == [],
        else: next_group == [] and new_pairs == []

    if stop? do
      {pairs, carried}
    else
      bracket_loop(carried, new_sgb, rest, ctx, pairs ++ new_pairs, next_single_bye?)
    end
  end

  # How many score groups BEYOND the next one to put in the bracket's
  # graph. They are visible to the matcher and to C8, never consumed, and
  # nothing in them can be finalised.
  #
  # This is the single largest correction in the port. `dutch.cpp` appends
  # exactly one score group, and read literally that is what the C8 rungs
  # score — but C8 is "choose the set of downfloaters so that in the
  # FOLLOWING bracket every criterion from C1 to C7 is complied with", and
  # a bracket cannot check that against players it cannot see. Both
  # confirmed anomalies in `test/fixtures/open_questions/` have exactly
  # that signature: an identical current+next graph answering differently
  # depending on what lies below it.
  #
  # Global cascade, 200x9 against bbpPairings:
  #
  #     depth 0 (one group, the literal reading)  90.29% / 96.89%
  #     depth 1                                   94.14% / 98.17%
  #     depth 2                                   95.62% / 98.52%
  #     depth 3                                   95.91% / 98.63%
  #     depth 4                                   95.97% / 98.64%
  #     depth 6 and unbounded                     95.97% / 98.64%
  #
  # Zero illegal rounds at every depth, and it saturates at 4 (unbounded
  # measures identically, for more time).
  #
  # Budgeted in PLAYERS rather than groups, because groups are the wrong
  # unit: a 4-40 field has score groups of one to three, so four of them
  # is a handful of players and depth genuinely buys accuracy; a 60-120
  # field has groups big enough that ONE already supplies the same
  # context. Measured — 60-80 and 90-120 both score identically at depth
  # 1 and depth 4, while depth 4 costs 2.7x and 2.6x the time:
  #
  #     60-80 players    depth 1  99.44% / 99.97%   21s
  #                      depth 4  99.44% / 99.97%   57s
  #     90-120 players   depth 1  98.61% / 99.87%   64s
  #                      depth 4  98.61% / 99.87%  166s
  #
  # A player budget gets the small field's depth and the large field's
  # speed from one rule, and it is the same reasoning `depth_for/1` and
  # `per_count_limit/1` already use: a big bracket has more ways to pair,
  # so it needs less help.
  #
  # Note what this does NOT contradict: TODO.md's "do not read the
  # lookahead as a licence to pair across brackets" still holds, and is
  # still enforced — `collect_bracket/1` keeps a pair only when both ends
  # are below `nsgb`. Seeing further and finalising further are different
  # things, and it was only ever the second one that measured badly.
  @peek_budget 8

  defp peek_budget do
    case System.get_env("OPENPAIR_PEEK") do
      nil -> @peek_budget
      n -> String.to_integer(n)
    end
  end

  # Whole score groups, never a partial one — a bracket that could see
  # half of a group would score C8 against a fiction.
  defp peek_groups([], _budget, acc), do: List.flatten(Enum.reverse(acc))
  defp peek_groups(_rest, budget, acc) when budget <= 0, do: List.flatten(Enum.reverse(acc))

  defp peek_groups([group | rest], budget, acc) do
    peek_groups(rest, budget - length(group), [group | acc])
  end

  defp pair_bracket(combined, sgb, nsgb, ctx, single_bye?) do
    m = length(combined)
    arr = List.to_tuple(combined)

    # Sized to THIS bracket, not the field. Every sum the ladder takes is
    # over one bracket's matching, so a field-wide span only inflates the
    # bignums the matcher then compares — and it re-solves the same graph
    # up to eight times per bracket, so that cost lands eight times over.
    #
    # `places` stays a positional radix over score groups, just restricted
    # to the groups this bracket actually holds. The ORDER is what "taken
    # in descending order" compares, and restricting preserves it exactly;
    # weights are never compared between brackets.
    {places, place_span} = score_places(combined)
    count_span = m + 1

    bands = %{
      places: places,
      place_span: place_span,
      count_span: count_span,
      # dutch.cpp:462-469's reserved low space, as a multiplier.
      reserve: 2 * count_span * count_span * count_span
    }

    base = base_edge_weights(arr, m, sgb, nsgb, ctx, bands, single_bye?)

    %{
      arr: arr,
      m: m,
      sgb: sgb,
      nsgb: nsgb,
      ctx: ctx,
      bands: bands,
      base: base,
      live: base,
      transposition: transposition_terms(m, sgb, nsgb),
      # Any value above every real weight will do: `finalize_pair/3`
      # leaves the two vertices exactly one usable edge each, so the pair
      # is forced regardless of magnitude.
      max_w: 1 + (base |> Map.values() |> Enum.max(fn -> 0 end)),
      matched: MapSet.new(),
      matching: %{},
      remainder: [],
      remainder_pairs: 0,
      exchange_count: 0
    }
    |> solve()
    |> trace_stage("initial solve")
    |> stage_select_mdps()
    |> trace_stage("1 select MDPs")
    |> stage_mdp_opponents()
    |> trace_stage("2 MDP opponents")
    |> stage_build_remainder()
    |> trace_stage("3 remainder")
    |> stage_exchange_weights()
    |> trace_stage("4 exchange weights")
    |> stage_exchange_lower_from_higher()
    |> trace_stage("5 lower-from-higher")
    |> stage_exchange_higher_from_lower()
    |> trace_stage("6 higher-from-lower")
    |> stage_reset_exchange_bits()
    |> trace_stage("7 reset bits")
    |> stage_first_group_partners()
    |> trace_stage("8 first-group partners")
    |> collect_bracket()
  end

  # How many pairs the bracket would KEEP if it stopped here. Set
  # OPENPAIR_TRACE=1 to watch it across the eight stages: the count should
  # never fall, and a stage where it does is dropping a pair the criteria
  # say it should have kept.
  defp trace_stage(st, label) do
    if System.get_env("OPENPAIR_TRACE") do
      kept =
        Enum.count(0..(st.m - 1)//1, fn i ->
          p = partner(st, i)
          i < st.nsgb and p != i and p < st.nsgb and i < p
        end)

      ranks = st.arr |> Tuple.to_list() |> Enum.map(& &1.rank)

      matched =
        for i <- 0..(st.m - 1)//1,
            p = partner(st, i),
            p != i and i < p,
            do: {Enum.at(ranks, i), Enum.at(ranks, p)}

      IO.puts(
        "    [trace] m=#{st.m} sgb=#{st.sgb} nsgb=#{st.nsgb} #{label}: #{kept} internal" <>
          " | #{inspect(ranks, charlists: :as_lists)} -> #{inspect(matched, charlists: :as_lists)}"
      )
    end

    st
  end

  ## ---------- the graph ----------

  defp put_w(weights, i, j, w) when i < j, do: Map.put(weights, {i, j}, w)
  defp put_w(weights, i, j, w), do: Map.put(weights, {j, i}, w)

  defp get_w(weights, i, j) when i < j, do: Map.get(weights, {i, j}, 0)
  defp get_w(weights, i, j), do: Map.get(weights, {j, i}, 0)

  defp solve(st) do
    scale = st.transposition.scale
    terms = st.transposition.terms
    reserve = st.bands.reserve
    above? = System.get_env("OPENPAIR_TRANS_ABOVE") != nil

    edges =
      Enum.reduce(st.live, [], fn {{i, j}, w}, acc ->
        if w > 0 do
          term = Map.get(terms, {i, j}, 0)

          weight =
            if above? do
              # Split `w` back into its criteria part and the refinement
              # stages' reserved addend, and slot the transposition order
              # BETWEEN them: criteria still win, but FIDE's order now
              # outranks a stage nudge instead of the other way round.
              div(w, reserve) * scale * reserve + term * reserve + rem(w, reserve)
            else
              w * scale + term
            end

          [{i, j, weight} | acc]
        else
          acc
        end
      end)

    %{st | matching: WeightedMatching.solve(st.m, edges)}
  end

  # FIDE section 3's transposition order as an edge-additive tie-break,
  # strictly below every criterion AND below the reserved space the
  # refinement stages write into, so it can only settle what they leave
  # open.
  #
  # Articles 3.3-3.5 take the SMALLEST transposition of the natural order,
  # and "smallest" is lexicographic over S2: which S2 member faces S1[0],
  # then S1[1], and so on. Maximising `B^(k-p) * (|S2| - q)` for an edge
  # from S1[p] to S2[q] minimises exactly that sequence, and it splits
  # over edges because each pair contributes one (p, q).
  #
  # An earlier version of this carried the engine's general-purpose
  # canonical tie-break instead (`lex_scale/1`), which keys on ABSOLUTE
  # bracket position rather than S2 index. That is a different order — it
  # makes the natural pairing (S1[0] vs S2[0], i.e. positions 0 and k)
  # look large and an adjacent pairing (0 vs 1) look smallest.
  #
  # ## It is inert, and promoting it is actively worse
  #
  # Every variant measures identically: removed, inverted, and replaced
  # with this handbook key, with byes and without. The eight refinement
  # stages settle every tie before it is consulted.
  #
  # `OPENPAIR_TRANS_ABOVE=1` slots it between the criteria and the stages'
  # reserved addends, so FIDE's order outranks a stage nudge rather than
  # the reverse. That is much worse — 95.97% -> 87.57% without byes and
  # 86.70% -> 79.93% with them.
  #
  # Which says the key is the wrong model, not the priority. Stages 5-7
  # EXCHANGE players between the two halves, so by the time partners are
  # chosen "S1" and "S2" are no longer the naive first-half/second-half
  # split this function assumes; it is measuring transpositions against a
  # reference the bracket has already moved away from. The stages are the
  # transposition procedure, and they are right. Kept, off the critical
  # path, because a correct key would be worth having if anyone works out
  # what the post-exchange split actually is.
  defp transposition_terms(_m, sgb, nsgb) do
    {s1, s2} =
      cond do
        # A heterogeneous bracket pairs its moved-down players against the
        # residents: MDPs are S1 (Article 3.3.1).
        sgb > 0 and sgb < nsgb -> {0..(sgb - 1)//1, sgb..(nsgb - 1)//1}
        nsgb >= 2 -> {0..(div(nsgb, 2) - 1)//1, div(nsgb, 2)..(nsgb - 1)//1}
        true -> {1..0//1, 1..0//1}
      end

    s1 = Enum.to_list(s1)
    s2 = Enum.to_list(s2)
    k = length(s1)
    n2 = length(s2)
    base = n2 + 2
    pow = for e <- 0..(k + 1), into: %{}, do: {e, Integer.pow(base, e)}

    terms =
      for {p, pi} <- Enum.with_index(s1),
          {q, qi} <- Enum.with_index(s2),
          into: %{} do
        {Enum.min_max([p, q]), Map.fetch!(pow, k - pi) * (n2 - qi)}
      end

    # One unit above anything the terms can reach, so the whole tie-break
    # sits under the criteria rather than beside them.
    if System.get_env("OPENPAIR_NO_TRANS"),
      do: %{terms: %{}, scale: 1},
      else: %{terms: terms, scale: Map.fetch!(pow, k + 1)}
  end

  # bbpPairings reads an unmatched vertex as matched to ITSELF, and three
  # of the stage tests below (`< playerVertex`, `<= playerVertex`) depend
  # on that convention rather than on a nil check.
  defp partner(st, i), do: Map.get(st.matching, i, i)

  # Matched to a resident of this bracket's own score group.
  defp internal?(st, i) do
    p = partner(st, i)
    p >= st.sgb and p < st.nsgb
  end

  # Paired with someone LATER in the bracket — the "higher group" role in
  # an exchange.
  defp paired_down?(st, i) do
    p = partner(st, i)
    p > i and p < st.nsgb
  end

  defp exchange_needed?(st, i) do
    p = partner(st, i)
    p <= i or p >= st.nsgb
  end

  # `common.h:164`. Lock the pair by leaving each vertex exactly one
  # usable edge — the one to the other.
  defp finalize_pair(st, i, j) do
    live =
      Enum.reduce(0..(st.m - 1)//1, st.live, fn k, acc ->
        acc = if k == i, do: acc, else: put_w(acc, i, k, if(k == j, do: st.max_w, else: 0))
        if k == j, do: acc, else: put_w(acc, j, k, if(k == i, do: st.max_w, else: 0))
      end)

    %{st | live: live}
  end

  ## ---------- the ladder ----------

  defp base_edge_weights(_arr, m, _sgb, _nsgb, _ctx, _bands, _single_bye?) when m < 2, do: %{}

  defp base_edge_weights(arr, m, sgb, nsgb, ctx, bands, single_bye?) do
    reach = reach_table(arr, m, nsgb)
    bands = Map.put(bands, :max_reach, reach |> Map.values() |> Enum.max(fn -> 0 end))

    Enum.reduce(0..(m - 2), %{}, fn i, acc ->
      a = elem(arr, i)

      Enum.reduce((i + 1)..(m - 1), acc, fn j, inner ->
        r = Map.get(reach, j, 0)

        case bracket_edge_weight(a, elem(arr, j), j, sgb, r, ctx, bands, single_bye?) do
          nil -> inner
          w -> Map.put(inner, {i, j}, w)
        end
      end)
    end)
  end

  # How far BELOW the current bracket each position sits, counted in score
  # groups: 0 for the bracket itself, 1 for the next group, 2 for the one
  # after it, and so on.
  #
  # bbpPairings needs no such thing, because its graph stops at the next
  # group and `lowerPlayerInNextBracket` can only mean that one group. The
  # peek budget broke that equivalence: with several groups visible, a
  # plain "is the partner below?" bit scores a float that lands in the
  # very next group exactly the same as one that falls three groups. C8 is
  # about the FOLLOWING bracket specifically, so distance has to be graded.
  defp reach_table(_arr, m, nsgb) when nsgb >= m, do: %{}

  defp reach_table(arr, m, nsgb) do
    nsgb..(m - 1)//1
    |> Enum.reduce({%{}, 1, nil}, fn j, {acc, d, prev} ->
      points = elem(arr, j).points
      d = if prev != nil and points != prev, do: d + 1, else: d
      {Map.put(acc, j, d), d, points}
    end)
    |> elem(0)
  end

  defp bracket_edge_weight(a, b, j, sgb, reach, ctx, bands, single_bye?) do
    # dutch.cpp:607 — no edge unless the LARGER index is a resident or
    # lower, which is what stops two MDPs being paired with each other.
    if j >= sgb and legal_pair?(a, b) and colour_compatible?(a, b) do
      a
      |> edge_rungs(b, reach, ctx, bands, single_bye?)
      |> Enum.map(fn {_label, value, span} -> {value, span} end)
      |> ranked()
      |> Kernel.*(bands.reserve)
    end
  end

  # The ladder itself, as LABELLED rungs highest-priority first, so the
  # same definition serves both the matcher (packed by `ranked/1`) and
  # `explain_round/3`, which needs to say WHICH criterion two pairings
  # part company on. Keeping one definition is the point: a diagnostic
  # that scored a reimplementation of the criteria would only ever tell
  # you whether the two implementations agreed.
  #
  # `a` is the higher-placed player of the pair, `b` the lower.
  defp edge_rungs(a, b, reach, ctx, bands, single_bye?) do
    in_current = reach == 0
    s = bands.count_span

    place = Map.fetch!(bands.places, a.points)

    # C8 is about the FOLLOWING bracket, singular. bbpPairings' graph
    # stops at the next score group, so its `lowerPlayerInNextBracket`
    # can only ever mean that one group — including for pairs formed
    # wholly inside it, which genuinely are "pairs in the next bracket".
    #
    # The peek budget broke that equivalence in a way grading by distance
    # did not fix. With several groups visible, pairs formed THREE groups
    # down were still scoring on C8, and there are many more of those than
    # there are real downfloat placements, so they swamped the signal:
    # nearly every candidate matching carried the same large C8 total and
    # the rung stopped discriminating. Traced on seed127-r5-p13, where the
    # engine floated a player who then had to fall two groups while
    # bbpPairings floated one who landed in the next.
    #
    # So the deeper groups stay VISIBLE — the matcher still needs to know
    # those players exist, which is what the peek was for — but only the
    # immediate next group counts toward C8. Anything further is re-decided
    # in a later bracket anyway, and C8 has nothing to say about it.
    scores_c8? = reach == 1
    nearness = bit(scores_c8?)

    {c1, c2, c3, c4} = colour_criteria(a, b)
    {f1, f2, f3, f4} = float_criteria(a, b)
    {s18, s19, s20, s21} = float_score_criteria(a, b, %{score_place: bands.places})

    gate = fn value, on? -> if on?, do: value, else: 0 end

    [
      # C4 completion + C2/C5 bye eligibility. `isByeCandidate` is
      # `eligibleForBye AND score <= byeAssigneeScore` — pairing someone
      # who may NOT take the bye is preferred, so whoever is left over
      # is someone the absolute criteria allow.
      #
      # The leading `1` is what makes this rung count EDGES, and on an
      # even field (where the rest is constant) that is all it does. Since
      # it outranks C6, it makes the matcher trade an internal pair for
      # two cross-bracket ones whenever that yields more edges — and
      # `test/fixtures/open_questions/` shows bbpPairings does NOT do
      # that. `completion_rung/3` is where that is measured.
      completion_rung(a, b, ctx, s),
      # C6, then C7 graded by which score group got paired.
      {"C6 pairs in bracket", bit(in_current), s},
      {"C7 scores paired", gate.(place, in_current), bands.place_span},
      # C8, the same two rungs one bracket down — but graded by how far
      # down, since the peek budget makes several groups visible at once.
      {"C8 pairs next bracket", nearness, s},
      {"C8 scores next bracket", gate.(place, scores_c8?), bands.place_span},
      {"C9 bye unplayed games", gate.(c9_rank(a, b, ctx), single_bye?), s * s},
      # C10-C13, `insertColorBits`.
      {"C10 topscorer colour diff", gate.(bit(c1), in_current), s},
      {"C11 topscorer same colour x3", gate.(bit(c2), in_current), s},
      {"C12 colour preference", gate.(bit(c3), in_current), s},
      {"C13 strong colour preference", gate.(bit(c4), in_current), s},
      # C14-C17.
      {"C14 downfloat repeat r-1", gate.(f1, in_current), 2 * s},
      {"C15 upfloat repeat r-1", gate.(f2, in_current), s},
      {"C16 downfloat repeat r-2", gate.(f3, in_current), 2 * s},
      {"C17 upfloat repeat r-2", gate.(f4, in_current), s},
      # C18-C21.
      {"C18 downfloat scores r-1", gate.(s18, in_current), bands.place_span},
      {"C19 upfloat scores r-1", gate.(s19, in_current), bands.place_span},
      {"C20 downfloat scores r-2", gate.(s20, in_current), bands.place_span},
      {"C21 upfloat scores r-2", gate.(s21, in_current), bands.place_span}
    ]
  end

  # dutch.cpp:276 reads `1u + !isByeCandidate(higher) + !isByeCandidate(lower)`.
  #
  #   default        the C++ verbatim — the leading 1 makes it count edges
  #   "eligibility"  drop the leading 1, so the rung expresses only the
  #                  bye preference and leaves C6 to decide pair counts
  #
  # This briefly diverged from the literal text. On an even field the
  # bye-eligibility part is constant, so the leading 1 makes the rung
  # purely an edge count — and since it outranks C6 it will trade an
  # internal pair for two cross-bracket ones to gain an edge, which
  # `test/fixtures/open_questions/` catches bbpPairings NOT doing.
  # Dropping the 1 was worth +0.18 exact rounds at the time.
  #
  # The peek-budget fix then superseded it. Once brackets can see far
  # enough to evaluate C8 (see `peek_budget/0`), the two forms measure
  # IDENTICALLY — 95.97% / 98.64% without byes and 86.70% / 96.48% at an
  # 8% bye rate, byte for byte — so the divergence bought nothing and the
  # verbatim reading is back. The anomaly was never about this rung; it
  # was about what the bracket could see.
  defp completion_rung(a, b, ctx, s) do
    eligibility =
      bit(not bye_candidate?(a, ctx.bye_score)) + bit(not bye_candidate?(b, ctx.bye_score))

    case System.get_env("OPENPAIR_COMPLETION") do
      "eligibility" -> {"C2/C5 bye-eligibility", eligibility, 3 * s}
      _ -> {"C2/C4/C5 bye-eligibility", 1 + eligibility, 3 * s}
    end
  end

  # `isByeCandidate` (dutch.cpp:213) is `eligibleForBye AND score <=
  # byeAssigneeScore`, and bbpPairings only ever computes a real
  # `byeAssigneeScore` for an ODD field — for an even one it stays at its
  # zero initialiser (dutch.cpp:822). So on an even field the test is
  # `score <= 0`, false for anyone who has scored at all, and the rung
  # collapses to a constant 3 per edge: pure "maximise the number of
  # pairs", which is what the completion criterion wants.
  #
  # Treating a nil bye score as "no score test" instead made the rung VARY
  # on even fields — an edge touching someone who had already taken a bye
  # outscored one that did not — so the top rung of the whole ladder was
  # quietly expressing a preference bbpPairings does not have, above C6.
  defp bye_candidate?(player, nil), do: eligible_for_bye?(player) and player.points <= 0

  defp bye_candidate?(player, bye_score) do
    eligible_for_bye?(player) and player.points <= bye_score
  end

  defp c9_rank(a, b, ctx) do
    unplayed_rank(a, ctx) + unplayed_rank(b, ctx)
  end

  defp unplayed_rank(player, ctx) do
    if player.points == ctx.bye_score,
      do: Map.get(ctx.unplayed_ranks, played_games(player), 0),
      else: 0
  end

  ## ---------- stage 1: which MDPs get paired (dutch.cpp 1091-1205) ----------

  # Walks the moved-down players in rank order and, for each one the
  # current matching has NOT placed inside the bracket, nudges its edges
  # to residents and RE-SOLVES, keeping the result only if the MDP is now
  # paired. That is the ordering guarantee a lone matching cannot give:
  # among equally-optimal matchings, the better-ranked MDPs are the ones
  # that get paired.
  #
  # The two early exits are what the previous port was missing. Counting
  # how many of a score group CAN be matched (`matched_left`) lets the
  # loop skip the expensive re-solve entirely when the answer is already
  # forced — either none of them can be paired, or all of the ones left
  # will be.
  defp stage_select_mdps(%{sgb: 0} = st), do: st

  defp stage_select_mdps(st) do
    {st, _, _, _} =
      Enum.reduce(0..(st.sgb - 1), {st, nil, 0, 0}, fn i, {st, group, remaining, matched_left} ->
        {group, remaining, matched_left} =
          if is_nil(group) or elem(st.arr, i).points < group,
            do: count_mdp_group(st, i),
            else: {group, remaining, matched_left}

        cond do
          matched_left == 0 ->
            {st, group, remaining, matched_left}

          remaining <= matched_left ->
            {%{st | matched: MapSet.put(st.matched, i)}, group, remaining, matched_left}

          true ->
            st = if internal?(st, i), do: st, else: nudge_mdp_edges(st, i)

            if internal?(st, i) do
              {st |> Map.update!(:matched, &MapSet.put(&1, i)) |> freeze_mdp_edges(i), group,
               remaining - 1, matched_left - 1}
            else
              {st, group, remaining - 1, matched_left}
            end
        end
      end)

    st
  end

  # How many MDPs share this one's score, and how many of them the current
  # matching already places inside the bracket. The scan stops at the
  # first lower score, which is the first resident — moved-down players
  # are by definition higher-scored than the group they landed in.
  defp count_mdp_group(st, from) do
    score = elem(st.arr, from).points

    Enum.reduce_while(from..(st.m - 1)//1, {score, 0, 0}, fn k, {s, remaining, matched_left} ->
      if elem(st.arr, k).points >= s do
        {:cont, {s, remaining + 1, matched_left + bit(internal?(st, k))}}
      else
        {:halt, {s, remaining, matched_left}}
      end
    end)
  end

  # dutch.cpp:1168 `edgeWeight |= 1u` — the smallest bump there is, enough
  # to break a tie in favour of using this edge and far too small to
  # outrank any criterion.
  defp nudge_mdp_edges(st, mdp) do
    live =
      Enum.reduce(st.sgb..(st.nsgb - 1)//1, st.live, fn opp, acc ->
        case get_w(st.base, mdp, opp) do
          0 -> acc
          w -> put_w(acc, mdp, opp, w + 1)
        end
      end)

    solve(%{st | live: live})
  end

  # dutch.cpp:1196. Once an MDP is committed to being paired here, its
  # resident edges are lifted clear of the plain nudge so a later MDP's
  # re-solve cannot quietly drop it again.
  defp freeze_mdp_edges(st, mdp) do
    bump = st.nsgb - st.sgb + 1

    live =
      Enum.reduce(st.sgb..(st.nsgb - 1)//1, st.live, fn opp, acc ->
        case get_w(st.base, mdp, opp) do
          0 -> acc
          w -> put_w(acc, mdp, opp, w + bump)
        end
      end)

    %{st | live: live}
  end

  ## ---------- stage 2: who each MDP plays (dutch.cpp 1207-1255) ----------

  # Stage 1 settled WHETHER each moved-down player is paired; this settles
  # WITH WHOM, one player at a time, highest-ranked opponent first. The
  # ascending addend runs over the candidate opponents from the bottom up,
  # so the best-ranked available resident carries the largest bump.
  defp stage_mdp_opponents(%{sgb: 0} = st), do: st

  defp stage_mdp_opponents(st) do
    Enum.reduce(0..(st.sgb - 1), st, fn mdp, st ->
      if MapSet.member?(st.matched, mdp) do
        st |> prefer_high_opponents(mdp) |> solve() |> finalize_matched(mdp)
      else
        st
      end
    end)
  end

  defp prefer_high_opponents(st, mdp) do
    {live, _} =
      Enum.reduce((st.nsgb - 1)..st.sgb//-1, {st.live, st.m}, fn opp, {acc, addend} ->
        if MapSet.member?(st.matched, opp) do
          {acc, addend}
        else
          case get_w(st.base, mdp, opp) do
            0 -> {acc, addend}
            w -> {put_w(acc, mdp, opp, w + addend), addend + 1}
          end
        end
      end)

    %{st | live: live}
  end

  defp finalize_matched(st, i) do
    case partner(st, i) do
      ^i -> st
      p -> st |> Map.update!(:matched, &MapSet.put(&1, p)) |> finalize_pair(i, p)
    end
  end

  ## ---------- stages 3-4: the remainder (dutch.cpp 1257-1318) ----------

  # What is left of the score group once the moved-down players and their
  # opponents are settled. `remainder_pairs` splits it into FIDE's S1 and
  # S2: the first `remainder_pairs` entries are the higher half, the rest
  # the lower half, and pairing them is the homogeneous-bracket problem.
  defp stage_build_remainder(st) do
    remainder = Enum.filter(st.sgb..(st.nsgb - 1)//1, &(partner(st, &1) >= st.sgb))

    %{
      st
      | remainder: remainder,
        remainder_pairs: Enum.count(remainder, &(partner(st, &1) < &1))
    }
  end

  defp stage_exchange_weights(%{remainder: []} = st), do: st

  defp stage_exchange_weights(st) do
    live =
      Enum.reduce(st.remainder, st.live, fn opp, acc ->
        st.remainder
        |> Enum.take_while(&(&1 < opp))
        |> Enum.with_index()
        |> Enum.reduce(acc, fn {p, idx}, inner ->
          put_w(inner, p, opp, exchange_weight(st, p, opp, idx))
        end)
      end)

    solve(%{st | live: live})
  end

  # dutch.cpp:1055-1085. Two objectives, lexicographically: first keep the
  # pair inside its own half of the remainder (minimise the number of
  # exchanges), then prefer the smaller position (minimise the difference
  # of the exchanged branch scoring numbers).
  #
  # The `- remainder_index` runs off the end of the guard bit when that
  # bit is clear, which is where the negative addend discussed at the top
  # of this section comes from.
  defp exchange_weight(st, smaller, larger, remainder_index) do
    case get_w(st.base, smaller, larger) do
      0 ->
        0

      w ->
        s = st.bands.count_span
        w + (bit(remainder_index < st.remainder_pairs) * s * s - remainder_index) * 2
    end
  end

  ## ---------- stages 5-7: exchange selection (dutch.cpp 1320-1543) ----------

  defp stage_exchange_lower_from_higher(%{remainder: []} = st), do: st

  defp stage_exchange_lower_from_higher(st) do
    st = %{st | exchange_count: count_exchanges(st)}

    {st, _} =
      Enum.reduce_while(
        (st.remainder_pairs - 1)..0//-1,
        {st, st.exchange_count},
        fn pos, {st, left} ->
          if left == 0 do
            {:halt, {st, left}}
          else
            player = Enum.at(st.remainder, pos)
            opponents = Enum.drop(st.remainder, pos + 1)

            # Make this player's downward edges fractionally worse and ask
            # again: if the matcher now declines to pair them downward,
            # they are the one to exchange.
            st =
              if paired_down?(st, player) do
                live =
                  Enum.reduce(opponents, st.live, fn opp, acc ->
                    case exchange_weight(st, player, opp, pos) do
                      0 -> acc
                      w -> put_w(acc, player, opp, w - 1)
                    end
                  end)

                solve(%{st | live: live})
              else
                st
              end

            exchange = exchange_needed?(st, player)
            {:cont, {settle_exchange(st, player, pos, opponents, exchange), left - bit(exchange)}}
          end
        end
      )

    st
  end

  # How many of the higher half are not currently paired downward — the
  # number of exchanges the bracket has to make.
  defp count_exchanges(st) do
    case Enum.at(st.remainder, st.remainder_pairs) do
      nil ->
        0

      bound ->
        st.remainder
        |> Enum.take_while(&(&1 < bound))
        |> Enum.count(&exchange_needed?(st, &1))
    end
  end

  # Either commit the exchange by cutting the player's edges to everyone
  # after them, or put the untouched weights back.
  defp settle_exchange(st, player, pos, opponents, exchange) do
    {base, live} =
      Enum.reduce(opponents, {st.base, st.live}, fn opp, {b, l} ->
        b = if exchange, do: put_w(b, player, opp, 0), else: b
        {b, put_w(l, player, opp, exchange_weight(%{st | base: b}, player, opp, pos))}
      end)

    %{st | base: base, live: live}
  end

  defp stage_exchange_higher_from_lower(%{remainder: []} = st), do: st

  defp stage_exchange_higher_from_lower(st) do
    {st, _} =
      Enum.reduce_while(
        st.remainder_pairs..(length(st.remainder) - 1)//1,
        {st, st.exchange_count},
        fn pos, {st, left} ->
          # dutch.cpp:1414 stops at one, not zero: the last exchange has
          # no partner left to swap with.
          if left <= 1 do
            {:halt, {st, left}}
          else
            player = Enum.at(st.remainder, pos)
            opponents = Enum.drop(st.remainder, pos + 1)
            already? = paired_down?(st, player)

            st = if already?, do: st, else: probe_upward(st, player, pos, opponents)
            exchange = paired_down?(st, player)
            st = if exchange, do: cut_exchanged(st, player, pos), else: st
            st = if already?, do: st, else: restore_probe(st, player, pos, opponents)

            {:cont, {st, left - bit(exchange)}}
          end
        end
      )

    st
  end

  # The mirror of stage 5's probe: sweeten rather than sour, and ask
  # whether the matcher will now pair this lower-half player downward.
  defp probe_upward(st, player, pos, opponents) do
    live =
      Enum.reduce(opponents, st.live, fn opp, acc ->
        case exchange_weight(st, player, opp, pos) do
          0 -> acc
          w -> put_w(acc, player, opp, w + 1)
        end
      end)

    solve(%{st | live: live})
  end

  defp restore_probe(st, player, pos, opponents) do
    live =
      Enum.reduce(opponents, st.live, fn opp, acc ->
        put_w(acc, player, opp, exchange_weight(st, player, opp, pos))
      end)

    %{st | live: live}
  end

  # A player promoted out of the lower half can no longer play anyone
  # ABOVE them in the remainder, nor anyone in the next score group —
  # dutch.cpp cuts both sets of edges from the base weights, permanently.
  defp cut_exchanged(st, player, pos) do
    cuts = Enum.take(st.remainder, pos) ++ Enum.to_list(st.nsgb..(st.m - 1)//1)

    {base, live} =
      Enum.reduce(cuts, {st.base, st.live}, fn opp, {b, l} ->
        {put_w(b, player, opp, 0), put_w(l, player, opp, 0)}
      end)

    %{st | base: base, live: live}
  end

  # dutch.cpp:1509. Drop every edge inconsistent with the exchange pattern
  # just chosen, and put the live weights back to their (now edited) base
  # so the reserved bits the probes used are clear again.
  defp stage_reset_exchange_bits(%{remainder: []} = st), do: st

  defp stage_reset_exchange_bits(st) do
    {base, live} =
      st.remainder
      |> Enum.with_index()
      |> Enum.reduce({st.base, st.live}, fn {player, pos}, acc ->
        st.remainder
        |> Enum.drop(pos + 1)
        |> Enum.reduce(acc, fn opp, {b, l} ->
          b =
            if exchange_needed?(st, player) or paired_down?(st, opp),
              do: put_w(b, player, opp, 0),
              else: b

          {b, put_w(l, player, opp, get_w(b, player, opp))}
        end)
      end)

    %{st | base: base, live: live}
  end

  ## ---------- stage 8: partners for the higher half (dutch.cpp 1545-1599) ----------

  defp stage_first_group_partners(st) do
    Enum.reduce(st.remainder, st, fn player, st ->
      if paired_down?(st, player) do
        st |> prefer_high_remainder(player) |> solve() |> finalize_both(player)
      else
        st
      end
    end)
  end

  defp prefer_high_remainder(st, player) do
    {live, _} =
      st.remainder
      |> Enum.reverse()
      |> Enum.reduce({st.live, 0}, fn opp, {acc, addend} ->
        if opp <= player or MapSet.member?(st.matched, opp) do
          {acc, addend}
        else
          acc =
            case get_w(st.base, player, opp) do
              0 -> acc
              w -> put_w(acc, player, opp, w + addend)
            end

          # Incremented even when the edge was unusable, so the ordering
          # reflects rank rather than availability (dutch.cpp:1580).
          {acc, addend + 1}
        end
      end)

    %{st | live: live}
  end

  defp finalize_both(st, i) do
    case partner(st, i) do
      ^i ->
        st

      p ->
        st
        |> Map.update!(:matched, &(&1 |> MapSet.put(i) |> MapSet.put(p)))
        |> finalize_pair(i, p)
    end
  end

  ## ---------- carry forward (dutch.cpp 1601-1649) ----------

  defp collect_bracket(st) do
    {pairs, carried, sgb} =
      Enum.reduce(0..(st.m - 1)//1, {[], [], 0}, fn i, {pairs, carried, sgb} ->
        p = partner(st, i)

        # `p < st.nsgb` is this port's own guard, not bbpPairings'. Their
        # recording condition tests only the near end of the pair, which
        # would let an MDP that was flagged matched but ended up paired
        # into the NEXT score group be written out as a finalised pair
        # while its partner also carried forward. bbpPairings never
        # finalises a cross-bracket pair (see TODO.md); this makes that
        # invariant explicit rather than relying on it.
        if i < st.nsgb and p != i and p < st.nsgb and MapSet.member?(st.matched, i) do
          if i < p,
            do:
              {[assign_colour_with_history({elem(st.arr, i), elem(st.arr, p)}) | pairs], carried,
               sgb},
            else: {pairs, carried, sgb}
        else
          {pairs, [mark_float(elem(st.arr, i), i < st.nsgb) | carried], sgb + bit(i < st.nsgb)}
        end
      end)

    # dutch.cpp:1636-1643 needs, for each player carrying forward, the
    # score of whoever the tentative matching had them with — that is what
    # tells the NEXT bracket whether its downfloat runs deeper than one
    # group, and so whether C9 applies there at all. An unmatched carried
    # player constrains nothing, so they report their own score.
    partner_scores =
      for i <- 0..(st.m - 1)//1,
          i < st.nsgb,
          p = partner(st, i),
          not (p != i and p < st.nsgb and MapSet.member?(st.matched, i)),
          do: elem(st.arr, if(p == i, do: i, else: p)).points

    {Enum.reverse(pairs), Enum.reverse(carried), sgb, partner_scores}
  end

  # A current-bracket player who was not paired here IS a downfloater.
  defp mark_float(player, true), do: Map.put(player, :already_floated, true)
  defp mark_float(player, false), do: player
  defp bye_assignee_score(_brackets, 0), do: nil

  defp bye_assignee_score(brackets, _allowed_byes) do
    field =
      brackets
      |> List.flatten()
      |> Enum.sort_by(&{-&1.points, &1.rank})
      |> Enum.with_index()
      |> Enum.map(fn {p, i} ->
        p |> Map.put(:bracket_pos, i) |> Map.put(:colour_stats, colour_stats(p))
      end)

    n = length(field)

    # Found by a 100,000-tournament overnight run (PAIRING_FUZZ_BYE_PCT=15
    # — see TODO.md): with n <= 1 there is at most one candidate, so
    # there's no pair to build an edge list over at all. The general path
    # below builds it as `0..(n - 2)`, which for n == 1 is `0..-1` —
    # Elixir's default step for a descending range walks `0, -1`, and
    # `elem(arr, -1)` raised ArgumentError instead of pairing (n == 1) or
    # doing nothing (n == 0). n == 1 is the reachable case in practice
    # (one genuine bye candidate left after everyone else resolved) —
    # trivially THEIR score, no matching needed. n == 0 shouldn't arise
    # given the `allowed_byes == 0` clause above already short-circuits
    # the no-candidates case, but costs nothing to make safe the same way
    # rather than assume it can't happen.
    if n <= 1 do
      case field do
        [player] -> player.points
        [] -> nil
      end
    else
      bye_assignee_score_from_field(field, n)
    end
  end

  defp bye_assignee_score_from_field(field, n) do
    arr = List.to_tuple(field)
    {places, place_span} = score_places(field)
    max_place = places |> Map.values() |> Enum.max(fn -> 1 end)

    # Room for the eligibility term above the score term, and for a
    # cardinality term above both, so more pairs always wins.
    eligibility_unit = place_span
    edge_ceiling = 3 * eligibility_unit + 2 * max_place
    cardinality_unit = div(n, 2) * edge_ceiling + 1

    edges =
      Enum.flat_map(0..(n - 2), fn i ->
        a = elem(arr, i)

        Enum.flat_map((i + 1)..(n - 1), fn j ->
          b = elem(arr, j)

          if legal_pair?(a, b) and colour_compatible?(a, b) do
            # NOT `bye_candidate?/2` (the eligible-AND-score<=threshold
            # test): checked directly against dutch.cpp:766-786, the
            # bootstrap matching that DETERMINES byeAssigneeScore for an odd
            # field uses its own separate, simpler inline weight —
            # `1u + !eligibleForBye(player) + !eligibleForBye(opponent)` —
            # not the real per-bracket `computeEdgeWeight`/`isByeCandidate`
            # test. That's not an oversight on the C++ side: `isByeCandidate`
            # needs `byeAssigneeScore` as an input, which is exactly what
            # this pass is computing, so testing candidates against it here
            # would be circular. Confirmed by measurement too — swapping
            # this to `bye_candidate?(_, nil)` (tried during the
            # `tools/adjudicate.exs` investigation below) made ~80/2522
            # rounds newly unpairable where bbpPairings still found a legal
            # pairing, a large regression, not the intended fix.
            eligibility = 1 + bit(not eligible_for_bye?(a)) + bit(not eligible_for_bye?(b))
            score = Map.fetch!(places, a.points) + Map.fetch!(places, b.points)
            [{i, j, cardinality_unit + eligibility * eligibility_unit + score}]
          else
            # dutch.cpp:768-791: `compatible/4`-failing pairs still get a
            # real edge here (`edgeWeight` starts at, and for these stays,
            # exactly 0) — the bootstrap matching_computer is built as a
            # COMPLETE graph, so an incompatible pair is only ever a worse
            # choice than a compatible one, never an impossible one.
            # `WeightedMatching.solve/2`'s `build_state/2` silently drops
            # any edge with weight `0` (`if w > 0`), so a literal port of
            # "weight 0" would vanish here exactly like the omitted-edge
            # version this replaces — hence weight `1`, the smallest weight
            # that still registers, still guaranteed below every compatible
            # edge's `cardinality_unit`-or-higher floor. Previously this
            # pair contributed NO edge at all, so a field whose only
            # legal/colour-compatible pairs can't form a near-perfect
            # matching (heavy forfeits/absolute-colour clashes) could leave
            # MORE than one player unmatched here — a case real bbpPairings
            # doesn't hit at this bootstrap step, since it always has a
            # complete graph to fall back on.
            [{i, j, 1}]
          end
        end)
      end)

    matching = WeightedMatching.solve(n, edges)

    case Enum.reject(0..(n - 1), &is_map_key(matching, &1)) do
      # No legal complete round exists; leave C5 unconstrained and let the
      # cascade and `repair_bye_count/3` produce the best answer they can
      # rather than refusing every candidate here.
      [] -> nil
      leftovers -> leftovers |> Enum.map(&elem(arr, &1).points) |> Enum.min()
    end
  end

  # C5, the PAB Criterion: "Minimise the score of the assignee of the
  # pairing-allocated-bye". ABSOLUTE, so it is checked here alongside C2
  # rather than weighted anywhere.
  defp bye_score_ok?(player) do
    case Process.get(@bye_score_key) do
      nil -> true
      score -> player.points <= score
    end
  end

  defp score_places(players) do
    players
    |> Enum.group_by(& &1.points)
    |> Enum.map(fn {score, members} -> {score, length(members)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({%{}, 1}, fn {score, size}, {places, place} ->
      {Map.put(places, score, place), place * (size + 1)}
    end)
  end

  defp float_score_criteria(higher, lower, spans) do
    crossing? = higher.points > lower.points

    # Only a pair that spans two score groups HAS a score difference, and
    # the difference belongs to the MDP — the higher-scored player, who
    # moved down into this bracket. `score_place` already encodes exactly
    # that: one digit per score group, the higher group more significant,
    # so a bigger drop is a bigger number and "taken in descending order"
    # falls out of the positional comparison.
    #
    # Weighting by the LOWER player instead was tried first and is inert:
    # `lower` is decided by bracket position, so in an MDP bracket it is
    # always a resident, every resident shares one score, and the term is
    # then the same constant for every candidate pairing.
    if crossing? do
      psd = Map.fetch!(spans.score_place, higher.points)

      {
        # C18/C20 — the MDP itself downfloated recently. Pairing it here is
        # what stops it floating on, so the reward grows with the drop.
        if(float_of(higher, 1) == :down, do: psd, else: 0),
        # C19/C21 — inverted like `float_criteria/2`'s f2/f4: the reward is
        # for an opponent who did NOT just upfloat.
        if(float_of(lower, 1) == :up, do: 0, else: psd),
        if(float_of(higher, 2) == :down, do: psd, else: 0),
        if(float_of(lower, 2) == :up, do: 0, else: psd)
      }
    else
      {0, 0, 0, 0}
    end
  end

  # Pack ranked criteria, highest priority first, the same way bbpPairings'
  # `computeEdgeWeight` does with successive left-shifts: each criterion is
  # worth more than every lower-priority criterion combined, so a better
  # value on an earlier term can never be outvoted by later ones. Passing
  # explicit spans rather than hard-coded decimal magnitudes is what makes
  # that guarantee hold — the previous `* 1_000_000` / `* 1_000` scheme was
  # only safe as long as nobody looked at a bracket big enough to overflow
  # the gap between two of its terms.
  defp ranked(components) do
    Enum.reduce(components, 0, fn {value, span}, acc -> acc * span + value end)
  end

  defp bit(true), do: 1
  defp bit(false), do: 0
  # Only these three mean a game was actually contested. A forfeit carries
  # an opponent AND a colour but is legally unplayed, which is why every
  # caller has to ask whether the game HAPPENED rather than whether there
  # was an opponent — four separate call sites had that wrong until the
  # harness started generating forfeits.
  @played_results ~w(1 = 0)

  defp played?(game), do: game.result in @played_results

  # A player's full colour state, ported from bbpPairings'
  # `tournament.cpp` `computePlayerData`. This replaces a one-line
  # stand-in ("preference is the opposite of your last colour") that was
  # only ever right for round 2, which is exactly why round 2 measured
  # 99.85% and round 3 fell off a cliff: after two games a player can be
  # two colours out of balance, or have had the same colour twice running,
  # and both produce an ABSOLUTE preference that the old rule couldn't
  # represent at all.
  #
  # Unplayed games (byes, forfeits) are excluded entirely — they carry no
  # colour and must not break a run of repeated colours either.
  defp colour_stats(player) do
    played = Enum.filter(player.games, &played?/1)
    whites = Enum.count(played, &(&1.colour == "w"))
    blacks = Enum.count(played, &(&1.colour == "b"))
    imbalance = abs(whites - blacks)
    consecutive = trailing_run(played)

    last =
      case List.last(played) do
        nil -> nil
        game -> game.colour
      end

    # Ties go to White, matching bbpPairings' own `gamesAsWhite >
    # gamesAsBlack ? BLACK : WHITE` — not a coin flip.
    lower_colour = if whites > blacks, do: "b", else: "w"

    # The ladder's order matters: an imbalance of 2+ outranks a repeated
    # colour, which outranks an imbalance of 1, which outranks plain
    # alternation.
    preference =
      cond do
        imbalance > 1 -> lower_colour
        consecutive > 1 -> invert(last)
        imbalance > 0 -> lower_colour
        consecutive > 0 -> invert(last)
        true -> nil
      end

    repeated = if consecutive > 1, do: last, else: nil
    absolute_imbalance? = imbalance > 1
    absolute? = absolute_imbalance? or not is_nil(repeated)

    %{
      preference: preference,
      imbalance: imbalance,
      repeated: repeated,
      absolute_imbalance?: absolute_imbalance?,
      absolute?: absolute?,
      strong?: not absolute? and imbalance > 0
    }
  end

  # How many games at the END of the list share the same colour.
  defp trailing_run([]), do: 0

  defp trailing_run(played) do
    [last | earlier] = Enum.reverse(played)
    1 + Enum.count(Enum.take_while(earlier, &(&1.colour == last.colour)))
  end

  defp invert("w"), do: "b"
  defp invert("b"), do: "w"
  defp invert(nil), do: nil

  # The four separately-ranked colour criteria of bbpPairings'
  # `insertColorBits`, in its own priority order (highest first). The old
  # engine had only the third of these — a single "are the preferences
  # compatible" boolean — which cannot distinguish a clash between two
  # absolute preferences (near-unpairable) from a clash between two mild
  # ones (a routine tie-break). All four sit ABOVE every float-history
  # criterion in bbpPairings' bit layout, so colour errors dominate float
  # errors whenever the two disagree.
  defp colour_criteria(higher, lower) do
    p = lower.colour_stats
    o = higher.colour_stats
    clash? = not is_nil(p.preference) and p.preference == o.preference

    {
      not (p.absolute_imbalance? and o.absolute_imbalance? and clash?),
      not (p.absolute? and o.absolute? and clash?) or absolute_tiebreak(p, o),
      not clash?,
      (not p.strong? and not p.absolute?) or (not o.strong? and not o.absolute?) or
        (p.absolute? and o.absolute?) or not clash?
    }
  end

  # The four float-history criteria of bbpPairings' `computeEdgeWeight`,
  # ranked immediately below every colour criterion and above the
  # bracket-ordering ones. These are what TODO.md item 4 predicted would
  # first bite in round 3: `float_direction/3` looks one and two rounds
  # back, and two rounds back doesn't exist until round 3.
  #
  # All four are phrased so that HIGHER is better, since the matcher
  # maximises. The two "repeated downfloater" terms reward *pairing* a
  # player who was floated down recently — pairing them here is precisely
  # how you avoid floating them again. The two "repeated upfloater" terms
  # instead withhold their bit from an edge that would upfloat someone who
  # already upfloated, an edge being an upfloat exactly when it crosses
  # score groups.
  defp float_criteria(higher, lower) do
    crossing? = higher.points > lower.points

    {
      bit(float_of(lower, 1) == :down) + bit(not crossing? and float_of(higher, 1) == :down),
      bit(not (crossing? and float_of(lower, 1) == :up)),
      bit(float_of(lower, 2) == :down) + bit(not crossing? and float_of(higher, 2) == :down),
      bit(not (crossing? and float_of(lower, 2) == :up))
    }
  end

  # Reached only when both players hold an absolute preference for the SAME
  # colour, i.e. one of them is definitely going to be denied. It decides
  # which such clash is the least bad: prefer the one where the player who
  # is *less* out of balance isn't the one whose repeated colour would be
  # extended.
  defp absolute_tiebreak(p, o) do
    if p.imbalance == o.imbalance do
      is_nil(p.repeated) or p.repeated != o.repeated
    else
      less_imbalanced = if p.imbalance > o.imbalance, do: o, else: p
      less_imbalanced.repeated != invert(p.preference)
    end
  end

  # C1, no repeat pairings — but only actually-PLAYED games forbid a
  # rematch. bbpPairings builds its `forbiddenPairs` set under an explicit
  # `if (match.gameWasPlayed)` guard (`dutch.cpp:664`), so two players who
  # were paired and forfeited have not "met" and may be paired again.
  #
  # Confirmed against real javafo before changing it: seed 140, an
  # 11-player round 2 where players 5 and 10 were paired in round 1 and
  # double-forfeited. javafo paired them with each other AGAIN, in
  # preference to two rematch-free alternatives it could have taken
  # instead — so this is javafo's actual behaviour, not an artefact of
  # having no other option.
  defp legal_pair?(p1, p2) do
    not Enum.any?(p1.games, &(played?(&1) and &1.opponent_rank == p2.rank))
  end

  # Two players who both hold an ABSOLUTE colour preference for the same
  # colour cannot be paired at all. bbpPairings puts this in `compatible`
  # (`dutch.cpp:57-68`) alongside the no-rematch rule — an absolute
  # criterion, not something weighed against other considerations. This
  # engine had it only as scored criteria c1/c2, which means a bad enough
  # position elsewhere could buy a pairing that is simply not allowed.
  #
  # bbpPairings carries one exception: in the FINAL round, two players
  # above half the maximum possible score may be paired despite the
  # clash, rather than leave a tournament's decisive game unplayed. It
  # needs the expected round count, which reaches here via
  # `pair_next_round/2`'s `:expected_rounds` option; without it the
  # exception simply never fires and the engine stays strict.
  #
  # Leaving it out was measurable: rounds 4-8 all improved when the hard
  # exclusion landed, and round 9 — the final round of the nine-round
  # sweep, and the only round where this exception can apply — was the
  # one round that got worse.
  defp colour_compatible?(a, b) do
    p = a.colour_stats
    o = b.colour_stats

    if p.absolute? and o.absolute? and not is_nil(p.preference) and
         p.preference == o.preference do
      final_round_topscorers?(a, b)
    else
      true
    end
  end

  defp final_round_topscorers?(a, b) do
    case Process.get(@expected_rounds_key) do
      nil ->
        false

      expected_rounds ->
        # `playedRounds >= expectedRounds - 1`: the round being paired is
        # the last one. The threshold is bbpPairings' own
        # `(tournament.playedRounds * pointsForWin) >> 1` — half of what a
        # player could have scored SO FAR (rounds already played), not
        # half the tournament's eventual maximum. Those are genuinely
        # different numbers even in the one round this exception can ever
        # fire in: playedRounds is expectedRounds-1 there, so the correct
        # threshold is floor((expectedRounds-1)/2), one lower than
        # floor(expectedRounds/2) whenever expectedRounds is even. This
        # engine used expectedRounds directly, which was simply the wrong
        # variable — found by tracing a genuine round-30 disagreement
        # (seed 39, 32-player field): OpenPair left two players unpaired
        # despite a full pairing existing, confirmed reachable by
        # disabling colour compatibility entirely first, and this
        # one-line fix alone was enough to reach it (see TODO.md).
        played_rounds = length(a.games)
        threshold = div(played_rounds, 2)

        played_rounds >= expected_rounds - 1 and
          (a.points > threshold or b.points > threshold)
    end
  end

  # Absolute criterion C2: nobody receives a second pairing-allocated bye.
  # bbpPairings' `eligibleForBye` (common.h:104) disqualifies a player who
  # has ANY unplayed game either worth at least a win, or that was a
  # pairing-allocated bye:
  #
  #     U   pairing-allocated bye        both limbs
  #     F   full-point bye (arbiter)     worth a win
  #     +   forfeit win                  worth a win
  #     W   unplayed win                 worth a win
  #
  # and leaves eligible the ones worth less: `H` (half-point bye), `Z`
  # (zero-point bye), `D` (unplayed draw), `L` (unplayed loss).
  #
  # `W` was missing here. The fuzz harness never generates it — it only
  # produces `H`/`Z` byes and `+`/`-` forfeits — so no measurement would
  # have caught it, but a real TRF can carry one and it would have let a
  # player take a second full point without playing.
  #
  # Enforced as a hard requirement on the cascade's final state rather
  # than scored, so the search has to find a legal bye assignee or report
  # that none exists.
  @bye_disqualifying_results ~w(U F + W)

  defp eligible_for_bye?(player) do
    not Enum.any?(player.games, &(&1.result in @bye_disqualifying_results))
  end

  defp assign_colour_with_history({a, b}) do
    case choose_colour(a, b) do
      "w" ->
        {a.rank, b.rank}

      "b" ->
        {b.rank, a.rank}

      nil ->
        # assign_colour_round_one/2 expects {better_ranked, worse_ranked}.
        {top, bottom} = if a.rank < b.rank, do: {a, b}, else: {b, a}
        assign_colour_round_one(top, bottom)
    end
  end

  # The colour `player` gets against `opponent` — a port of bbpPairings'
  # `choosePlayerNeutralColor` (`swisssystems/common.cpp`), which is
  # Article 5.2 in full: grant the preference outright when they don't
  # clash, otherwise let the stronger preference win (absolute over strong
  # over mild, and within absolute, the larger imbalance), and only when
  # they are genuinely equal fall back to alternating from the most recent
  # round in which the two players actually had different colours.
  #
  # `nil` means "still undecided" and leaves the caller on the fixed
  # round-1 convention. Note this affects only which of the two players is
  # printed as White; the comparison harness is colour-blind, so nothing
  # here moves the match rate. It's correctness, not score.
  defp choose_colour(player, opponent) do
    p = player.colour_stats
    o = opponent.colour_stats

    cond do
      is_nil(p.preference) or is_nil(o.preference) or p.preference != o.preference ->
        p.preference || invert(o.preference)

      p.absolute? and (p.imbalance > o.imbalance or not o.absolute?) ->
        p.preference

      o.absolute? and (o.imbalance > p.imbalance or not p.absolute?) ->
        invert(o.preference)

      p.strong? and not o.strong? ->
        p.preference

      o.strong? and not p.strong? ->
        invert(o.preference)

      true ->
        case first_colour_difference(player, opponent) do
          {nil, _} -> nil
          {_, nil} -> nil
          {_players_colour, opponents_colour} -> opponents_colour
        end
    end
  end

  # The colours the two players had in the most recent round where they
  # differed, walking both histories back in step and skipping unplayed
  # games on either side independently.
  defp first_colour_difference(a, b) do
    walk_back(played_colours(a), played_colours(b))
  end

  # bbpPairings' `skipUnplayedGames`: a forfeit is skipped here too, so
  # the two histories stay aligned on rounds that were actually contested.
  defp played_colours(player) do
    player.games |> Enum.filter(&played?/1) |> Enum.map(& &1.colour) |> Enum.reverse()
  end

  defp walk_back([x | xs], [y | ys]) when x == y, do: walk_back(xs, ys)
  defp walk_back([x | _], [y | _]), do: {x, y}
  defp walk_back([], [y | _]), do: {nil, y}
  defp walk_back([x | _], []), do: {x, nil}
  defp walk_back([], []), do: {nil, nil}
end
