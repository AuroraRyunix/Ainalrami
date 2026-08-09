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

  # Bounds on the bracket cascade's backtracking search (see
  # `cascade_brackets/4`): how many alternative matchings of a single
  # bracket to consider, and how much total work to spend before giving up
  # and returning a best-effort answer.
  #
  # A genuinely direct, no-backtracking version of this cascade (single
  # best `bracket_options/2` result per bracket, committed immediately)
  # was tried and measured: 97.19% -> 81.99% of pairs against javafo at
  # depth (300 tournaments x 9 rounds), with 302/2521 rounds newly hitting
  # `NoValidPairingError`. That confirms backtracking is doing real work
  # THIS weight formula still needs — bbpPairings' own equivalent step
  # doesn't need it because its weights are richer (bracket-locality as a
  # graded bonus rather than a hard partition, an exchange-minimization
  # refinement pass), not because backtracking is unnecessary in
  # principle. Revisit removing this once the weight formula itself is
  # closer to that, not before.
  @budget_key :openpair_cascade_budget
  @bye_score_key :openpair_bye_score
  @expected_rounds_key :openpair_expected_rounds
  @cascade_budget 2000
  @alternatives_per_bracket 15
  @alternatives_per_count 6

  # How many extra players `bracket_candidates/3` will force to float
  # beyond the bracket's own optimum, and how many candidates it carries
  # forward at each step. See `deeper_floats/5`.
  @max_bracket_for_alternatives 16
  @forced_float_depth 2
  @forced_float_beam 8

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

      field
      |> Enum.chunk_by(& &1.points)
      |> Enum.reduce({[], []}, fn group, {acc, mdps} ->
        {report, floated} = explain_bracket(mdps ++ group, group, partner, ctx)
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

  defp explain_bracket(bracket, group, partner, ctx) do
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

    {places, place_span} = score_places(bracket)
    count_span = length(bracket) + 1

    bands = %{
      places: places,
      place_span: place_span,
      count_span: count_span,
      reserve: 2 * count_span * count_span * count_span
    }

    rungs =
      edges
      |> Enum.map(fn {x, y} ->
        {a, b} = order_by_placement(Map.fetch!(by_rank, x), Map.fetch!(by_rank, y))
        edge_rungs(a, b, true, ctx, bands, false)
      end)
      |> sum_rungs()

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
      |> with_float_history()
      |> Enum.filter(&active_this_round?(&1, played))
      |> Enum.group_by(& &1.points)
      |> Enum.sort_by(fn {score, _} -> -score end)
      |> Enum.map(fn {_score, members} -> members end)

    # Exactly one pairing-allocated bye in an odd field, none in an even
    # one. Counted over the ACTIVE players — a field of even size with one
    # player sitting out needs a bye, and one of odd size with one sitting
    # out does not.
    allowed_byes = rem(length(active), 2)

    Process.put(@budget_key, @cascade_budget)
    Process.put(@bye_score_key, bye_assignee_score(brackets, allowed_byes))

    try do
      case maybe_global_cascade(brackets, allowed_byes) do
        {:ok, pairs, leftover} ->
          pairs ++ Enum.map(leftover, &{&1.rank, nil})

        :infeasible ->
          case cascade_brackets(brackets, [], [], allowed_byes) do
            {:ok, pairs, leftover} -> pairs ++ Enum.map(leftover, &{&1.rank, nil})
            :infeasible -> brackets |> greedy_cascade() |> repair_bye_count(active, allowed_byes)
          end
      end
      # Runs even on the backtracking search's own success path, not just
      # the greedy fallback: cheap when everything's already legal
      # (`bye_legal?/3`'s check is the only work done), and a real safety
      # net if `cascade_brackets/4`'s own eligibility check ever has a gap
      # `repair_bye_count/3` doesn't.
      |> repair_bye_count(active, allowed_byes)
    after
      Process.delete(@budget_key)
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
  defp with_float_history(players) do
    by_rank = Map.new(players, &{&1.rank, &1})

    Enum.map(players, fn player ->
      Map.put(player, :floats, %{
        1 => float_direction(player, 1, by_rank),
        2 => float_direction(player, 2, by_rank)
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
  defp float_direction(player, rounds_back, by_rank) do
    index = length(player.games) - rounds_back

    if index < 0 do
      :none
    else
      game = Enum.at(player.games, index)

      cond do
        not played?(game) ->
          if result_points(game.result) > 0.0, do: :down, else: :none

        not is_map_key(by_rank, game.opponent_rank) ->
          :none

        true ->
          mine = score_before(player, rounds_back)
          theirs = score_before(Map.fetch!(by_rank, game.opponent_rank), rounds_back)

          cond do
            mine > theirs -> :down
            mine < theirs -> :up
            true -> :none
          end
      end
    end
  end

  # A player's score as it stood before the last `rounds_back` rounds —
  # current score minus what those rounds paid out. bbpPairings keeps the
  # same thing as `scoreWithAcceleration(tournament, roundsBack)`.
  defp score_before(player, rounds_back) do
    player.games
    |> Enum.take(-rounds_back)
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
  # C9's rung measures inert too (identical numbers with it forced off),
  # but it is a genuine handbook criterion and its ABSENCE was a
  # documented gap, so it stays. It simply never fires in this fixture
  # set — see `single_downfloater_is_bye_assignee?/4` for the gate, which
  # is deliberately over-inclusive rather than under.

  # OFF by default. Set OPENPAIR_GLOBAL=1 to select it over the
  # per-bracket cascade; `global_cascade/2` still falls back on
  # `:infeasible` rather than emitting an illegal round.
  defp maybe_global_cascade(brackets, allowed_byes) do
    if System.get_env("OPENPAIR_GLOBAL"),
      do: global_cascade(brackets, allowed_byes),
      else: :infeasible
  end

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
    if length(leftover) <= allowed_byes and Enum.all?(leftover, &eligible_for_bye?/1) and
         Enum.all?(leftover, &bye_score_ok?/1) do
      {:ok, pairs, leftover}
    else
      :infeasible
    end
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

  defp bracket_loop(by_index, sgb, rest_groups, ctx, pairs) do
    nsgb = length(by_index)

    {next_group, rest} =
      case rest_groups do
        [] -> {[], []}
        [group | tail] -> {group, tail}
      end

    {new_pairs, carried, new_sgb} = pair_bracket(by_index ++ next_group, sgb, nsgb, ctx)

    # bbpPairings loops unconditionally because by this point it has
    # already PROVED a complete legal matching exists — its whole-field
    # pre-pass throws `NoValidPairingException` otherwise (dutch.cpp:828).
    # This engine deliberately carries on when that pre-pass finds nothing
    # (`bye_assignee_score/2` returns nil rather than aborting), so a last
    # bracket whose players simply cannot play each other would spin here
    # forever: no pairs made, nothing consumed, same arguments next time.
    # Give up instead and let `global_cascade/2` report `:infeasible`.
    if rest == [] and new_pairs == [] do
      {pairs, carried}
    else
      bracket_loop(carried, new_sgb, rest, ctx, pairs ++ new_pairs)
    end
  end

  defp pair_bracket(combined, sgb, nsgb, ctx) do
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

    base = base_edge_weights(arr, m, sgb, nsgb, ctx, bands)

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

    edges =
      Enum.reduce(st.live, [], fn {{i, j}, w}, acc ->
        if w > 0,
          do: [{i, j, w * scale + Map.get(st.transposition.terms, {i, j}, 0)} | acc],
          else: acc
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
  # look large and an adjacent pairing (0 vs 1) look smallest — and it
  # measured completely inert here, removal and inversion alike. This is
  # the handbook's actual rule.
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
    %{terms: terms, scale: Map.fetch!(pow, k + 1)}
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

  defp base_edge_weights(_arr, m, _sgb, _nsgb, _ctx, _bands) when m < 2, do: %{}

  defp base_edge_weights(arr, m, sgb, nsgb, ctx, bands) do
    single_bye? = single_downfloater_is_bye_assignee?(arr, m, nsgb, ctx)

    Enum.reduce(0..(m - 2), %{}, fn i, acc ->
      a = elem(arr, i)

      Enum.reduce((i + 1)..(m - 1), acc, fn j, inner ->
        case bracket_edge_weight(a, elem(arr, j), j, sgb, nsgb, ctx, bands, single_bye?) do
          nil -> inner
          w -> Map.put(inner, {i, j}, w)
        end
      end)
    end)
  end

  # C9 applies only to "brackets downfloating exactly one player, who
  # receives the bye" (dutch.cpp:1607). The gate here is bbpPairings' own
  # first two conditions — an odd field, and a bye whose score is at or
  # above the next group's. NOT ported is the refinement at 1636-1643,
  # which additionally clears the flag once a downfloater turns out to be
  # matched below; this is therefore over-inclusive, and C9 can fire in a
  # bracket bbpPairings would have excluded. The previous port had no C9
  # rung at all.
  defp single_downfloater_is_bye_assignee?(arr, m, nsgb, ctx) do
    ctx.odd_field? and not is_nil(ctx.bye_score) and nsgb < m and
      ctx.bye_score >= elem(arr, nsgb).points
  end

  defp bracket_edge_weight(a, b, j, sgb, nsgb, ctx, bands, single_bye?) do
    # dutch.cpp:607 — no edge unless the LARGER index is a resident or
    # lower, which is what stops two MDPs being paired with each other.
    if j >= sgb and legal_pair?(a, b) and colour_compatible?(a, b) do
      a
      |> edge_rungs(b, j < nsgb, ctx, bands, single_bye?)
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
  defp edge_rungs(a, b, in_current, ctx, bands, single_bye?) do
    in_next = not in_current
    s = bands.count_span
    place = Map.fetch!(bands.places, a.points)

    {c1, c2, c3, c4} = colour_criteria(a, b)
    {f1, f2, f3, f4} = float_criteria(a, b)
    {s18, s19, s20, s21} = float_score_criteria(a, b, %{score_place: bands.places})

    gate = fn value, on? -> if on?, do: value, else: 0 end

    [
      # C4 completion + C2/C5 bye eligibility. `isByeCandidate` is
      # `eligibleForBye AND score <= byeAssigneeScore` — pairing someone
      # who may NOT take the bye is preferred, so whoever is left over
      # is someone the absolute criteria allow.
      {"C2/C4/C5 bye-eligibility",
       1 + bit(not bye_candidate?(a, ctx.bye_score)) + bit(not bye_candidate?(b, ctx.bye_score)),
       3 * s},
      # C6, then C7 graded by which score group got paired.
      {"C6 pairs in bracket", bit(in_current), s},
      {"C7 scores paired", gate.(place, in_current), bands.place_span},
      # C8, the same two rungs one bracket down.
      {"C8 pairs next bracket", bit(in_next), s},
      {"C8 scores next bracket", gate.(place, in_next), bands.place_span},
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

    {Enum.reverse(pairs), Enum.reverse(carried), sgb}
  end

  # A current-bracket player who was not paired here IS a downfloater.
  defp mark_float(player, true), do: Map.put(player, :already_floated, true)
  defp mark_float(player, false), do: player

  # Depth-first over the brackets, taking each bracket's own best matching
  # first and only reconsidering it when everything downstream turns out to
  # have no legal completion. Pairing each bracket greedily is what stranded
  # a final bracket of two players who had already met (seed 14) — the
  # bracket above had a slightly worse matching that floated two more
  # players down, which is exactly what javafo picks.
  #
  # @alternatives_per_bracket caps the branching and @cascade_budget the
  # total work, because this is a search and a pathological history should
  # degrade to a wrong answer rather than to no answer. Confirmed necessary
  # (not just cautious) by measurement: a direct, no-backtracking version
  # of this — take each bracket's single best `bracket_options/2` result
  # and never revisit it — was tried and dropped 97.19% -> 81.99% of pairs
  # against javafo at depth, with 302/2521 rounds newly reaching
  # `NoValidPairingError` that this search finds a legal answer for. See
  # `@budget_key`'s own doc for the full account.
  defp cascade_brackets([], floaters, pairs, allowed_byes) do
    if length(floaters) <= allowed_byes and Enum.all?(floaters, &eligible_for_bye?/1) and
         Enum.all?(floaters, &bye_score_ok?/1) do
      {:ok, pairs, floaters}
    else
      :infeasible
    end
  end

  defp cascade_brackets([residents | rest], floaters, pairs, allowed_byes) do
    budget = Process.get(@budget_key, 0)

    if budget <= 0 do
      :infeasible
    else
      Process.put(@budget_key, budget - 1)
      bracket = Enum.sort_by(floaters ++ residents, &{-&1.points, &1.rank})

      # ONE bracket of lookahead, not a recursive merge. bbpPairings scores
      # exactly this current-and-next slice too (`computeBaseEdgeWeights`
      # is handed `playersByIndex`, built from the current bracket plus the
      # next score group and nothing beyond it).
      lookahead =
        case rest do
          [next | _] -> next
          [] -> []
        end

      bracket
      |> bracket_options(lookahead, rest == [])
      |> Enum.reduce_while(:infeasible, fn {new_pairs, unpaired}, _acc ->
        # Stamped on the way OUT, not the way in: `unpaired` mixes players
        # who already carried the flag (floated into THIS bracket from
        # above) with ones floating for the first time — both must enter
        # the NEXT bracket already marked, so `float_weight/2` can tell
        # "floated already" from "floating for the first time" at every
        # level, not just the first.
        marked = Enum.map(unpaired, &Map.put(&1, :already_floated, true))

        # `rest` is passed through untouched: a peeked-ahead player is only
        # ever consulted, never taken, so the next bracket still holds
        # everyone it started with (see `resolve_lookahead/1`).
        case cascade_brackets(rest, marked, pairs ++ new_pairs, allowed_byes) do
          {:ok, final_pairs, final_floaters} -> {:halt, {:ok, final_pairs, final_floaters}}
          :infeasible -> {:cont, :infeasible}
        end
      end)
    end
  end

  # The score the pairing-allocated bye MUST land on, or `nil` when the
  # field is even and there is no bye.
  #
  # C5 is an absolute criterion in the 2026 handbook, and this engine used
  # to satisfy it only by accident: the bye fell out of whichever player
  # was left over by the lowest bracket, which is usually the lowest score
  # but need not be. A 5-player round-2 case found by diffing JaVaFo
  # against bbpPairings/Gacrux shows the difference exactly — the 0.5
  # bracket held two players who had already met, so somebody had to move,
  # and keeping the top bracket whole (C6, a QUALITY criterion) left the
  # bye on a 0.5 player when a 0.0 player was reachable. The 2026 answer
  # breaks the top bracket up instead, because C5 outranks C6 absolutely.
  #
  # Answered the way bbpPairings answers it: ONE matching over the entire
  # remaining field, before any bracket is looked at, whose weights
  # (`dutch.cpp`, the block guarded by `sortedPlayers.size() & 1u`)
  # maximise pair count first, then prefer pairing bye-INELIGIBLE players
  # so the leftover is someone C2 allows, then maximise the score groups
  # actually paired — which leaves the lowest-scoring eligible player
  # unmatched. That player's score is the answer.
  #
  # This is affordable only because the bracket matcher is polynomial now;
  # a whole-field match was out of reach for the subset DP this replaced.
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
            eligibility = 1 + bit(not eligible_for_bye?(a)) + bit(not eligible_for_bye?(b))
            score = Map.fetch!(places, a.points) + Map.fetch!(places, b.points)
            [{i, j, cardinality_unit + eligibility * eligibility_unit + score}]
          else
            []
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

  # Used only when no legal completion was found within the search budget:
  # take each bracket's own best matching and accept whatever falls out,
  # which is what this engine did unconditionally before. It can emit an
  # illegal number of byes, but returning a wrong pairing beats returning
  # none, and the harness reports it either way.
  defp greedy_cascade(brackets) do
    {pairs, leftover} =
      Enum.reduce(brackets, {[], []}, fn residents, {pairs, floaters} ->
        bracket = Enum.sort_by(floaters ++ residents, &{-&1.points, &1.rank})

        # No lookahead in the fallback. It exists to produce SOMETHING
        # when the real search has already given up, and `repair_bye_count/3`
        # cleans up after it either way; threading consumed next-bracket
        # players through a fold that has no backtracking would add a way
        # to pair someone twice for no benefit.
        [{new_pairs, unpaired} | _] =
          bracket_options(bracket, [], residents == List.last(brackets))

        {pairs ++ new_pairs, Enum.map(unpaired, &Map.put(&1, :already_floated, true))}
      end)

    pairs ++ Enum.map(leftover, &{&1.rank, nil})
  end

  # Every matching this bracket admits, best first — one per achievable
  # number of floaters. The cascade takes the head unless the rest of the
  # round can't be completed from it.
  defp bracket_options(ranked, lookahead, bye_bracket?) do
    # Built from the CURRENT bracket alone, and never consulted for a pair
    # that reaches into `lookahead` — see `cross_bracket_weight/3` for why
    # feeding it a merged list is the exact mistake that sank the previous
    # attempt at this.
    natural = natural_partner_map(ranked)

    indexed =
      (Enum.map(ranked, &Map.put(&1, :bracket_zone, :current)) ++
         Enum.map(lookahead, &Map.put(&1, :bracket_zone, :lookahead)))
      |> Enum.with_index()
      |> Enum.map(fn {p, i} ->
        p |> Map.put(:bracket_pos, i) |> Map.put(:colour_stats, colour_stats(p))
      end)

    bracket_spans = spans(indexed)
    placeable = placeable_below(indexed)
    pair_fun = &pair_weight(&1, &2, natural, bracket_spans)
    float_fun = &float_weight(&1, bracket_spans, bye_bracket?, placeable)

    indexed
    |> bracket_candidates(pair_fun, float_fun)
    |> Enum.map(fn {_weight, pairs, floaters} ->
      {Enum.map(pairs, &assign_colour_with_history/1), floaters}
    end)
  end

  # The bracket's own optimum, plus one alternative per player who could
  # have floated instead — `{weight, pairs, floaters}`, best first.
  #
  # The alternatives are the whole reason this isn't a single matcher
  # call. A bracket's optimum can strand a later one, and what the
  # cascade needs to vary is WHICH players float, not how many: traced on
  # seed 73 round 4, where the 1.0 bracket's best two-pair matching floats
  # player 12, who has already played the only player below them, and the
  # round cannot finish. javafo takes a different two-pair matching that
  # floats player 10.
  #
  # `OpenPair.Matching`'s subset DP used to produce these for free — it
  # enumerates every subset anyway, so keeping the best few per floater
  # count cost nothing. A blossom matcher returns one optimum, so each
  # alternative has to be asked for explicitly: re-solve with one player
  # removed, which forces that player to float and lets the matcher find
  # the best arrangement of everyone else around that. Still polynomial,
  # where the DP was O(2^n) — see `solve_bracket/3`.
  #
  # Players already floating in a candidate are skipped when extending it:
  # forcing a player to float who is ALREADY floating just reproduces it.
  #
  # One forced float is NOT enough, and the reason is the seed 14 case in
  # `OpenPair.Matching`'s own doc: the cascade sometimes has to float an
  # extra PAIR of players down so a later bracket can complete. Forcing a
  # single player only ever reaches the next float count up, so a
  # depth-one version left 6 rounds per 421 with no legal completion at
  # all, against the DP's 0 — the DP got every float count for free,
  # because enumerating subsets is what it does. Extending the best few
  # candidates by one more forced float, `@forced_float_depth` times over,
  # buys those deeper counts back at `@forced_float_beam * n` solves
  # instead of `2^n` states.
  defp bracket_candidates(indexed, pair_fun, float_fun) do
    # Two independent axes, and the cascade needs both. `spine` is the
    # best matching at every achievable float COUNT, exactly (see
    # `solve_bracket_all/3`). `deeper_floats/5` then varies WHO floats
    # within a count, which no single solve can express.
    spine = solve_bracket_all(indexed, pair_fun, float_fun)
    optimum = Enum.max_by(spine, &elem(&1, 0))

    (spine ++
       deeper_floats(indexed, [{[], optimum}], pair_fun, float_fun, depth_for(length(indexed))))
    # An unused peeked-ahead player is NOT a floater — they never left
    # their own bracket. Dropping them here rather than at the call site
    # matters, because every ordering and de-duplication decision below
    # keys on the floater set, and the cascade's whole contract is
    # "fewest floaters first". Counting untouched next-bracket players as
    # floaters would make a candidate that simply declined the lookahead
    # look far worse than one that happened to use it.
    |> Enum.map(&resolve_lookahead/1)
    |> Enum.sort_by(fn {weight, _pairs, floaters} ->
      # The handbook's own order, explicitly rather than via the packed
      # weight: C6 how many float, C7 which scores float, C8 what that
      # leaves the following bracket able to do. Only then the packed
      # per-pair criteria, and last the lexicographic tie-break.
      {length(floaters), downfloater_scores(floaters), -weight, floater_order(floaters)}
    end)
    |> Enum.uniq_by(fn {_weight, _pairs, floaters} ->
      Enum.sort(Enum.map(floaters, & &1.rank))
    end)
    |> Enum.chunk_by(fn {_weight, _pairs, floaters} -> length(floaters) end)
    |> Enum.flat_map(&Enum.take(&1, per_count_limit(length(indexed))))
    |> Enum.take(@alternatives_per_bracket)
  end

  # Deterministic ordering for candidates that tie on BOTH float count and
  # weight but float different players. Ties are common here and the
  # choice is not free: leaving it to list order leaves it to whatever
  # sequence `deeper_floats/5` happened to generate, which is exactly the
  # kind of accidental tie-break that cost this engine 40 points when the
  # matcher changed underneath it.
  defp floater_order(floaters) do
    floaters |> Enum.map(&(-&1.bracket_pos)) |> Enum.sort()
  end

  # Extend the best candidates so far by one more forced float, `depth`
  # times over, collecting every level. Breadth is capped because the
  # point is to REACH the deeper float counts, not to enumerate them: the
  # cascade only ever looks past the first candidate when a later bracket
  # has already failed, and it sorts by float count first regardless.
  # Ranks of this bracket's players who have at least one legal,
  # colour-compatible opponent waiting in the peeked-ahead bracket — i.e.
  # who can actually BE placed if they float down.
  defp placeable_below(indexed) do
    {current, lookahead} = Enum.split_with(indexed, &(zone(&1) == :current))

    for player <- current,
        Enum.any?(lookahead, &(legal_pair?(player, &1) and colour_compatible?(player, &1))),
        into: MapSet.new(),
        do: player.rank
  end

  # C7: "Minimise the scores (taken in descending order) of the
  # downfloaters."
  #
  # Compared as a descending list, so the highest floating score dominates
  # and only an exact tie there defers to the next — which is what "taken
  # in descending order" asks for, and is NOT what summing a per-pair term
  # produces. The packed weight already carries `score_paired`, the same
  # criterion seen from the paired side; measured, stating it explicitly at
  # candidate level on top of that is worth +0.36 exact rounds against
  # bbpPairings at 200x9 (89.93% -> 90.29%), because the lexicographic
  # comparison and the sum genuinely disagree about which candidate wins.
  defp downfloater_scores(floaters) do
    floaters |> Enum.map(& &1.points) |> Enum.sort(:desc)
  end

  # Drop the peeked-ahead players from a candidate's floater list.
  #
  # They were never this bracket's to place: they contribute no edges (see
  # `pair_weight/4`), so they are always unmatched, and counting them as
  # floaters would wreck every ordering decision downstream — the cascade's
  # contract is "fewest floaters first", and a candidate that simply
  # declined to disturb the next bracket would look like the worst one.
  defp resolve_lookahead({weight, pairs, floaters}) do
    {weight, pairs, Enum.reject(floaters, &(zone(&1) == :lookahead))}
  end

  # How many extra players to force down, scaled to the bracket.
  #
  # `deeper_floats/5` costs `beam * depth * n` matcher calls on a bracket
  # of `n`, and the matcher is superlinear in `n`, so the product runs away
  # fast. Measured on a 90-player field, one round: depth 0 takes 40ms,
  # depth 1 takes 818ms, depth 2 takes 7371ms -- 183x for the last step. At
  # 200x9 against javafo that same step is worth +0.30 exact rounds
  # (88.06% -> 88.36%): a fine trade on a club field, a terrible one on an
  # open, and 90 players is an ordinary open.
  #
  # Scaled by the reasoning `per_count_limit/1` already uses, and
  # `OpenPair.Matching`'s `@max_bracket_for_alternatives` before it: a large
  # bracket has far more ways to pair, so it is the least likely to strand a
  # later one and the least in need of alternatives at all.
  #
  # Confirmed to cost nothing where it actually engages, which the ordinary
  # 4-40 fuzz range never reaches -- that range almost never builds a
  # bracket past 16, so the runs showing "byte-identical accuracy" never
  # exercised this at all. Measured on rosters of 60-80 against javafo:
  # capped scores 81.48% of rounds and 98.05% of pairs, uncapped 79.63% and
  # 97.84%. Free, and marginally better, since a longer candidate list
  # mostly gives the cascade more chances to settle somewhere javafo did
  # not.
  defp depth_for(bracket_size) do
    cond do
      bracket_size <= @max_bracket_for_alternatives -> @forced_float_depth
      bracket_size <= 2 * @max_bracket_for_alternatives -> 1
      true -> 0
    end
  end

  # Big brackets get ONE candidate per float count, not `n`.
  #
  # This mirrors `OpenPair.Matching`'s own `@max_bracket_for_alternatives`
  # and adopts its reasoning: a large bracket has far more ways to pair,
  # so it is the least likely to strand a later one and the least in need
  # of alternatives. Carrying the full set there is not merely wasteful,
  # it is worse — measured against javafo at 200x9, offering every
  # alternative on big brackets let the cascade satisfy itself with a
  # legal completion from deep in ONE bracket's list where javafo instead
  # backtracks and re-pairs an earlier bracket. Keeping the cap costs
  # nothing on the small brackets that actually strand.
  defp per_count_limit(bracket_size) do
    if bracket_size > @max_bracket_for_alternatives, do: 1, else: @alternatives_per_count
  end

  # A seed carries its FORCED set alongside the candidate it produced, and
  # extending it forces only that set plus one more player. Carrying the
  # candidate's whole floater list instead is wrong, and quietly so: an
  # odd bracket's optimum already floats somebody, so re-forcing them
  # jumped straight from one floater to three and never generated a
  # single-floater alternative at all — which is precisely the case seed
  # 73 needs (same float COUNT, different player floating). Measured
  # against the DP's own candidate list, that omission left 52.6% of
  # brackets with a shorter list, the misses concentrated at the shallow
  # float counts the cascade actually reaches.
  defp deeper_floats(_indexed, _seeds, _pair_fun, _float_fun, 0), do: []

  defp deeper_floats(indexed, seeds, pair_fun, float_fun, depth) do
    level =
      seeds
      |> Enum.take(@forced_float_beam)
      |> Enum.flat_map(fn {forced, {_weight, _pairs, floaters}} ->
        # Forcing a player who is already unpaired in this candidate just
        # reproduces it.
        floating = MapSet.new(floaters, & &1.bracket_pos)

        # Only this bracket's OWN players are worth forcing out. A
        # lookahead player is already free to go unpaired at no cost, so
        # forcing one changes nothing except to hide a cross-bracket
        # option the matcher might have wanted.
        indexed
        |> Enum.reject(&(MapSet.member?(floating, &1.bracket_pos) or zone(&1) == :lookahead))
        |> Enum.map(fn player ->
          next = [player | forced]
          {next, force_floats(indexed, next, pair_fun, float_fun)}
        end)
      end)
      |> Enum.uniq_by(fn {_forced, {_weight, _pairs, floaters}} ->
        Enum.sort(Enum.map(floaters, & &1.bracket_pos))
      end)
      |> Enum.sort_by(fn {_forced, {weight, _pairs, _floaters}} -> -weight end)

    Enum.map(level, fn {_forced, candidate} -> candidate end) ++
      deeper_floats(indexed, level, pair_fun, float_fun, depth - 1)
  end

  # The best matching of the bracket with every player in `forced` left
  # unpaired. Their float cost is added back explicitly, because
  # `solve_bracket/3` never sees them and so never charges for them.
  defp force_floats(indexed, forced, pair_fun, float_fun) do
    forced_positions = MapSet.new(forced, & &1.bracket_pos)

    {weight, pairs, floaters} =
      indexed
      |> Enum.reject(&MapSet.member?(forced_positions, &1.bracket_pos))
      |> solve_bracket(pair_fun, float_fun)

    charged = Enum.reduce(forced, 0, fn player, acc -> acc + float_fun.(player) end)
    {weight + charged, pairs, forced ++ floaters}
  end

  # One maximum-weight matching over `players`, as
  # `{total_weight, pairs, floaters}`.
  #
  # Floating is folded into the EDGE weights rather than modelled as a
  # per-vertex cost, because `WeightedMatching` has no notion of a vertex
  # weight — it simply leaves a vertex unmatched for free. The objective
  #
  #     sum(pair_weight over matched) + sum(float_weight over unmatched)
  #
  # is rewritten by adding the constant `sum(float_weight)` over EVERY
  # player and subtracting it back per edge:
  #
  #     sum(pair_weight(a,b) - float_weight(a) - float_weight(b)) + C
  #
  # `C` is fixed for a given player set, so the two have the same argmax.
  # Every transformed weight is comfortably positive — `float_weight/3`'s
  # base alone is `-max_pair * slots` — which matters because
  # `WeightedMatching.solve/2` treats a non-positive weight as "no edge".
  #
  # `players` may be a strict subset of the bracket (see
  # `bracket_candidates/3`), so the graph's vertex indices are positions
  # in THIS list and are deliberately not the same thing as
  # `:bracket_pos`. The criterion functions keep reading `:bracket_pos`,
  # which stays fixed to the player's place in the full bracket — that is
  # what makes an alternative's weights comparable with the optimum's.
  defp solve_bracket(players, pair_fun, float_fun) do
    players |> solve_bracket_all(pair_fun, float_fun) |> Enum.max_by(&elem(&1, 0))
  end

  # The best matching at EVERY achievable float count, best-weight first —
  # the same guarantee `OpenPair.Matching`'s subset DP gave the cascade,
  # and for the same reason it is needed: a bracket's own optimum can
  # strand a later one, and recovering means floating a DIFFERENT number
  # of players down (seed 14, where javafo floats an extra pair so the
  # last bracket can complete).
  #
  # This costs one solve, not one per count. A primal-dual matcher reaches
  # its optimum by augmenting a single pair at a time, and the matching
  # after k augmentations is already maximum-weight among all k-pair
  # matchings, so `solve_by_cardinality/2` just observes the run that was
  # happening anyway. Verified against the DP as an independent oracle
  # over 360 random graphs: every snapshot valid, and optimal for its own
  # cardinality.
  #
  # Approximating this by re-solving with players forcibly removed was
  # measurably worse and is now only used for the other axis — several
  # candidates at the SAME count, differing in WHO floats.
  # FIDE section 3 orders transpositions lexicographically over S2 — which
  # member of S2 faces S1[0], then S1[1], and so on. Only the S1 side
  # indexes the sequence.
  #
  # The original form here summed BOTH endpoints, minimising the partner
  # position of every player rather than of the S1 members alone. That is
  # a different (and stricter) order: it lets an S2 member's own partner
  # position outvote an earlier S1 member's, which the handbook's rule
  # never does. Adjudicating the 164 disagreements against this engine's
  # own ladder found 119 that tie on every criterion C1-C21, and among
  # those the handbook's order prefers bbpPairings' answer 73 times to
  # ours 17 — so the tie-break, not the criteria, is what is deciding
  # them.
  #
  # `i < j` always, and `spread` has already forced the S1-vs-S2 halving
  # by the time this is consulted, so `i` is the S1 endpoint.
  defp lex_term(i, j, n, lex_pow) do
    case System.get_env("OPENPAIR_LEX") do
      "both" -> elem(lex_pow, n - i) * (n - j) + elem(lex_pow, n - j) * (n - i)
      _ -> elem(lex_pow, n - i) * (n - j)
    end
  end

  defp solve_bracket_all([], _pair_fun, _float_fun), do: [{0, [], []}]

  defp solve_bracket_all([only], _pair_fun, float_fun), do: [{float_fun.(only), [], [only]}]

  defp solve_bracket_all(players, pair_fun, float_fun) do
    n = length(players)
    arr = List.to_tuple(players)

    {lex_span, lex_pow} = lex_scale(n)

    edges =
      Enum.flat_map(0..(n - 2), fn i ->
        a = elem(arr, i)

        Enum.flat_map((i + 1)..(n - 1), fn j ->
          b = elem(arr, j)

          case pair_fun.(a, b) do
            nil ->
              []

            weight ->
              real = weight - float_fun.(a) - float_fun.(b)
              [{i, j, real * lex_span + lex_term(i, j, n, lex_pow)}]
          end
        end)
      end)

    n
    |> WeightedMatching.solve_by_cardinality(edges)
    |> Enum.map(fn {_pair_count, matching} ->
      pairs = for {i, j} <- matching, i < j, do: {elem(arr, i), elem(arr, j)}
      floaters = for i <- 0..(n - 1), not is_map_key(matching, i), do: elem(arr, i)

      # Mirrors the edge weights exactly: a cross-bracket match still costs
      # its current-bracket player a float, because that is what it means.
      weight =
        Enum.reduce(pairs, 0, fn {a, b}, acc -> acc + pair_fun.(a, b) end) +
          Enum.reduce(floaters, 0, fn player, acc -> acc + float_fun.(player) end)

      {weight, pairs, floaters}
    end)
  end

  # One positional digit per score group present, lowest group least
  # significant, each digit wide enough to count its own members. Returns
  # `{score -> place value, total span}`.
  #
  # Shared by `spans/1` (C7/C18-C21, grading which scores got paired) and
  # `bye_assignee_score/2` (C5, leaving the lowest score unpaired). Both
  # need the same "a higher score group outranks any number of lower ones"
  # ordering, and both rely on the span bounding the total across a whole
  # bracket — a player belongs to one pair, so the sum of every player's
  # place value stays below the product.
  defp score_places(players) do
    players
    |> Enum.group_by(& &1.points)
    |> Enum.map(fn {score, members} -> {score, length(members)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({%{}, 1}, fn {score, size}, {places, place} ->
      {Map.put(places, score, place), place * (size + 1)}
    end)
  end

  # The scale factor and power table that force the matcher to a single,
  # CANONICAL choice among equally-optimal matchings.
  #
  # A maximum-weight matcher may return any optimum, and this weight
  # function leaves a great many: measured over a 20x9 javafo run,
  # `WeightedMatching` and `OpenPair.Matching`'s subset DP reach an
  # identical optimal weight in every one of 28,614 brackets, but return a
  # DIFFERENT matching in 4.9% of them. A round holds ~15 brackets, so
  # about half of all rounds caught at least one, which is exactly the
  # 85% -> 45% of exact rounds the move to `WeightedMatching` cost before
  # this existed.
  #
  # The DP's choice was worth ~40 points of round agreement, because its
  # enumeration order — lowest-indexed player first, lowest-indexed
  # partner wins a tie — approximates FIDE's real rule: the SMALLEST
  # transposition of the natural order (Articles 3.3-3.5). That rule is
  # LEXICOGRAPHIC. Two cheaper things were tried first and both failed on
  # exactly that point: a "minimise total distance from the natural
  # partner" weight term measured 87.89% -> 49.41%, because minimising a
  # SUM genuinely disagrees with minimising position-by-position; and an
  # equal-weight two-pair local search got 95.1% -> 99.6% of brackets
  # agreeing but stalled on large ones, where the tied optima differ by
  # alternating cycles longer than a two-pair swap can cross.
  #
  # So the rule is encoded exactly, in the weights, where the matcher
  # cannot get stuck. Writing `c(p)` for the position p is matched to (or
  # `n` when unmatched), lexicographic comparison of the whole sequence
  # `c(0), c(1), ...` is what `lex_key` used to compare. Maximising
  #
  #     S = sum over p of B^(n-p) * (n - c(p))
  #
  # minimises that sequence, and S splits over edges: an edge `{i, j}`
  # contributes `B^(n-i) * (n-j) + B^(n-j) * (n-i)`, with the unmatched
  # positions folding into a constant. `B = n + 2` is the smallest base
  # that works, and it is exactly sufficient rather than merely large: two
  # matchings first differing at position p0 differ there by at least
  # `B^(n-p0)`, while every later position together can differ by at most
  # `n * B^(n-p0) / (B-1)`, so the leading term wins as soon as
  # `B - 1 > n`.
  #
  # `lex_span` then lifts the real criteria above the whole tie-break, the
  # same discipline `spans/1` uses internally: `S < B^(n+1)`, so
  # multiplying the real weight by `B^(n+1)` leaves the tie-break strictly
  # below every documented criterion, unable to buy a single one.
  defp lex_scale(n) do
    base = n + 2
    powers = for k <- 0..(n + 1), do: Integer.pow(base, k)
    table = List.to_tuple(powers)
    {elem(table, n + 1), table}
  end

  # Upper bounds for the two non-boolean criteria, so `ranked/1` can pack
  # them without one bleeding into the next. Computed per bracket rather
  # than as global constants because both are bounded by the bracket, and
  # a fixed constant that's too small silently corrupts the ordering.
  # A criterion's span has to exceed the largest TOTAL every
  # lower-priority criterion can reach across the whole bracket — every
  # pair and every float — not merely the largest value a single pair can
  # contribute. Otherwise a high-priority criterion can lose to the SUM of
  # low-priority ones spread over several pairs, which is precisely what
  # an 11-player round-3 disagreement (seed 12) turned out to be: one step
  # of MDP displacement, correctly the more important term, was outvoted
  # by a rank tie-break plus a spread difference on two other pairs.
  #
  # bbpPairings avoids this by shifting each criterion left by
  # `playerCountBits` instead of by a single bit. Multiplying every span
  # by the bracket size is the same guarantee, arithmetic instead of bits.
  defp spans(indexed) do
    slots = length(indexed)
    max_rank = Enum.max(Enum.map(indexed, & &1.rank))

    # bbpPairings does not merely ask WHETHER a pair stays inside the
    # bracket, it grades WHICH SCORES got paired there — `computeEdgeWeight`
    # sets a bit at `scoreGroupShifts[higherPlayer.score]`, one field per
    # score group, the lowest score group at shift 0 and each higher group
    # further left by enough bits to count its own members.
    #
    # Reproduced here as positional arithmetic rather than bit shifts, the
    # same substitution `spans/1` already makes everywhere else: each score
    # group is a digit whose radix is its own size + 1, so a group's pair
    # count can never carry into the next group's digit, and a higher score
    # group's digit is more significant. Maximising the resulting number
    # therefore means "pair the highest score group as fully as possible,
    # then the next", which is exactly what the bit layout buys.
    {score_place, score_paired} = score_places(indexed)

    spans = %{
      slots: slots,
      # A single boolean: is this pair fully within the CURRENT bracket
      # (both `:current`), or does it reach into the peeked-ahead next
      # bracket (`:lookahead`)? Placed ABOVE colour, matching
      # `computeEdgeWeight`'s own order (`lowerPlayerInCurrentBracket` is
      # scored before any colour bit) — bbpPairings maximizes pairs
      # WITHIN a bracket first, and only lets a cross-bracket pair win on
      # colour/float/spread when the bracket itself can't do better
      # alone. See `pair_weight/4`'s doc for why the deviation term is
      # simply absent (not merely low-priority) for a cross-bracket pair.
      locality: 2,
      # The graded companions of `locality`, in bbpPairings' own order:
      # current-bracket pair COUNT (that is `locality`), then current
      # -bracket SCORES paired, then next-bracket pair count, then
      # next-bracket scores paired — all four above any colour bit.
      #
      # Porting `locality` alone and stopping was measured, and it is worse
      # than not doing it at all: 86.40% -> 43.82% of rounds against javafo.
      # A lone boolean says a cross-bracket pair is merely second-best
      # without saying anything about HOW far it reaches, so the matcher
      # spends cross-bracket pairs freely across large score gaps.
      score_paired: score_paired,
      score_place: score_place,
      colour: slots + 1,
      float_pair: 2 * slots + 1,
      float_single: slots + 1,
      deviation: slots * slots + 1,
      spread: slots * max_rank + 1
    }

    # The unit value of each criterion is the product of every span below
    # it, so `float_weight/2` can place its own terms at the right height
    # relative to the pair criteria rather than guessing a magnitude.
    unit_deviation = spans.spread
    # C18-C21 sit directly below C14-C17: same four float-history questions,
    # asked about the score DIFFERENCE rather than the count. Each is
    # bounded by `score_paired` for the same reason C7 is — a player belongs
    # to one pair, so the total over a bracket cannot exceed the sum of
    # every player's own place value.
    unit_s21 = unit_deviation * spans.deviation
    unit_s20 = unit_s21 * spans.score_paired
    unit_s19 = unit_s20 * spans.score_paired
    unit_s18 = unit_s19 * spans.score_paired
    unit_f4 = unit_s18 * spans.score_paired
    unit_f3 = unit_f4 * spans.float_single
    unit_f2 = unit_f3 * spans.float_pair
    unit_f1 = unit_f2 * spans.float_single
    unit_c4 = unit_f1 * spans.float_pair
    unit_score_paired = unit_c4 * spans.colour * spans.colour * spans.colour * spans.colour
    unit_locality = unit_score_paired * spans.score_paired

    spans
    |> Map.put(:unplayed_unit, unit_f4)
    |> Map.put(:max_pair, unit_locality * spans.locality)
  end

  # The pairing each bracket would get with no constraints at all, as a
  # position -> position involution — what Articles 3.2/3.3 call pairing
  # S1[i] against S2[i]. Everything else is scored as deviation from this
  # (see `pair_weight/3`), so getting the S1/S2 split itself right matters
  # more than any tie-break on top of it.
  #
  # The split is NOT simply "top half vs bottom half" in general. That's
  # only the homogeneous case (every player on the same score). A
  # HETEROGENEOUS bracket — one that floaters (moved-down players, MDPs)
  # joined from a higher score group — puts the MDPs alone in S1 and ALL
  # the residents in S2 (Article 3.3.1): the MDPs pair against the
  # best-ranked residents first, and only the residents left over
  # ("the remainder", Article 3.3.3) then split into halves among
  # themselves. Confirmed against real `javafo.jar`: an 8-player bracket
  # of one MDP + seven residents paired the MDP with the FIRST resident
  # whose colour preference was compatible, not with the resident a
  # half-split would have given it.
  defp natural_partner_map(ranked) do
    n = length(ranked)
    resident_score = ranked |> Enum.map(& &1.points) |> Enum.min()
    mdp_count = Enum.count(ranked, &(&1.points > resident_score))

    if mdp_count > 0 and 2 * mdp_count <= n do
      mdp_map = for i <- 0..(mdp_count - 1), into: %{}, do: {i, mdp_count + i}
      inverse = for {k, v} <- mdp_map, into: %{}, do: {v, k}

      mdp_map
      |> Map.merge(inverse)
      |> Map.merge(half_split_map(2 * mdp_count, n - 2 * mdp_count))
      |> Map.put(:mdp_count, mdp_count)
    else
      Map.put(half_split_map(0, n), :mdp_count, 0)
    end
  end

  defp half_split_map(_offset, count) when count < 2, do: %{}

  defp half_split_map(offset, count) do
    half = div(count, 2)

    Enum.reduce(0..(half - 1), %{}, fn i, acc ->
      a = offset + i
      b = offset + half + i
      acc |> Map.put(a, b) |> Map.put(b, a)
    end)
  end

  # `nil` (infeasible) for a rematch — the absolute criterion `Matching`
  # can never violate. Otherwise: colour-preference satisfaction first
  # (see `pair_later_round/1`'s doc for why), then the SMALLEST deviation
  # from the bracket's natural S1[i]-vs-S2[i] correspondence (see
  # `natural_partner_map/1`).
  #
  # That deviation term replaced an earlier "prefer the widest rank
  # spread" tie-break, which was a guess extrapolated from round 1's own
  # top-half-vs-bottom-half shape and produced real disagreements with
  # `javafo.jar`. FIDE's actual procedure (Articles 3.3-3.5) works by
  # applying the SMALLEST transposition of the natural order that
  # satisfies the criteria — so when several pairings all satisfy colour
  # equally, the one closest to the natural correspondence wins, which is
  # not the same thing as the widest-spread one. Both cases that
  # originally exposed this (a clean 4-player bracket, and an 8-player
  # heterogeneous one) are explained by this rule and were not explained
  # by the spread rule.
  defp pair_weight(a, b, natural, spans) do
    if legal_pair?(a, b) and colour_compatible?(a, b) do
      # A pair with any peeked-ahead player in it — one or both — is scored
      # but never emitted (`resolve_lookahead/1` discards it). Two
      # peeked-ahead players are deliberately INCLUDED rather than refused:
      # bbpPairings passes `lowerPlayerInNextBracket` for those edges too,
      # and its rung 4 is literally "maximize the number of pairs in the
      # next bracket". Refusing them throws away the only signal saying
      # whether the next bracket can pair ITSELF up, which is exactly the
      # question that should decide how many players to float into it.
      # The peeked-ahead bracket contributes NO edges. Modelling a downfloat
      # as a matched cross-bracket edge was tried and measured at 73.40% of
      # rounds against javafo, against 86.40% with no lookahead at all, and
      # it breaks something load-bearing: `solve_bracket_all/3` guarantees
      # the best matching at each PAIR COUNT, but a cross edge counts as a
      # pair while meaning a float, so that guarantee stops lining up with
      # real floater counts and the spine silently stops being exact.
      #
      # What the lookahead is actually for survives as a per-player signal
      # in `float_weight/4` instead — see `placeable_below/2`.
      if zone(a) == :current and zone(b) == :current do
        within_bracket_weight(a, b, natural, spans)
      end
    end
  end

  defp zone(player), do: Map.get(player, :bracket_zone, :current)

  defp within_bracket_weight(a, b, %{mdp_count: mdp_count} = natural, spans) do
    # bbpPairings passes (higherPlayer, lowerPlayer) by bracket order, and
    # the absolute-preference tie-break in `colour_criteria/2` is not
    # symmetric in the two, so the roles have to be assigned the same way
    # here rather than taking `a`/`b` as the matcher happens to give them.
    {higher, lower} = if a.bracket_pos <= b.bracket_pos, do: {a, b}, else: {b, a}
    {c1, c2, c3, c4} = colour_criteria(higher, lower)
    {f1, f2, f3, f4} = float_criteria(higher, lower)
    {s18, s19, s20, s21} = float_score_criteria(higher, lower, spans)

    deviation = mdp_deviation(a, b, natural, mdp_count)

    ranked(
      [
        {1, spans.locality},
        {Map.fetch!(spans.score_place, higher.points), spans.score_paired},
        {bit(c1), spans.colour},
        {bit(c2), spans.colour},
        {bit(c3), spans.colour},
        {bit(c4), spans.colour},
        {f1, spans.float_pair},
        {f2, spans.float_single},
        {f3, spans.float_pair},
        {f4, spans.float_single},
        {s18, spans.score_paired},
        {s19, spans.score_paired},
        {s20, spans.score_paired},
        {s21, spans.score_paired}
      ] ++ ordering_rungs(a, b, deviation, spans)
    )
  end

  # `deviation` and `spread` are NOT FIDE criteria. They stand in for
  # section 3's transposition-and-exchange procedure, and they sit above
  # the lexicographic tie-break in `bracket_options/3` — which is an
  # actual encoding of that procedure ("the smallest transposition of the
  # natural order"). So the stand-in currently outranks the real thing.
  #
  # Adjudicating all 164 disagreements against this engine's own ladder
  # (`explain_round/3`) says that is where the failures are: 119 of them
  # tie on every criterion C1-C21, and in 90 of those the lexicographic
  # order picks bbpPairings' answer over ours. Something below the
  # criteria is overriding the tie-break, and these two are what is there.
  #
  # Kept switchable while that is measured rather than deleted outright.
  defp ordering_rungs(a, b, deviation, spans) do
    case System.get_env("OPENPAIR_ORDERING") do
      "lex" ->
        []

      "no_spread" ->
        [{spans.deviation - 1 - deviation, spans.deviation}]

      _ ->
        [{spans.deviation - 1 - deviation, spans.deviation}, {abs(a.rank - b.rank), spans.spread}]
    end
  end

  # C18-C21: the same four float-history questions `float_criteria/2` asks,
  # weighted by the SCORE DIFFERENCE rather than counted.
  #
  #   [C18] Minimise the score differences (taken in descending order) of
  #         MDPs who received a downfloat the previous round.
  #
  # and C19/C20/C21 likewise for upfloats, and for two rounds before. Each
  # is graded by `spans.score_place`, one digit per score group with the
  # higher group more significant, which is exactly what "taken in
  # descending order" asks for: the largest score difference dominates, and
  # only a tie there defers to the next.
  #
  # Same inversion as `float_criteria/2` and for the same reason (see
  # `docs/fide-criteria.md`): the handbook minimises over the players left
  # floating, `ranked/1` maximises over the pairs formed, and PAIRING a
  # player is precisely how you keep them out of the minimised set. So a
  # player whose float history triggers the criterion contributes their own
  # place value when this pair rescues them.
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

  # Deviation from the natural correspondence, applied ONLY to pairs that
  # involve a moved-down player in a heterogeneous bracket (Article 3.3.1's
  # "M1 MDPs from S1 against M1 residents from S2"). Measured and weighted
  # separately from the general rank-spread tie-break below it because the
  # two genuinely disagree, and only this one is confirmed: replacing the
  # spread tie-break with a whole-bracket version of this deviation metric
  # was measured at 33.9% against real `javafo.jar` versus the spread
  # rule's 66.24% on the identical 2,000-history comparison set, so the
  # general case keeps spread. Restricting the deviation term to MDP pairs
  # is what actually fixed the traced heterogeneous-bracket cases (seeds 1
  # and 5) without giving that back.
  defp mdp_deviation(a, b, natural, mdp_count) do
    i = a.bracket_pos
    j = b.bracket_pos

    # Measured from the MDP's side ONLY, not summed symmetrically over
    # both. Summing both sides made genuinely different options tie: for a
    # single MDP at position 0 whose natural partner is position 1,
    # pairing it with position 2 scored |2-1| + |0-natural[2]| and pairing
    # it with position 5 scored |5-1| + |0-natural[5]| — both 6, because
    # the resident's own half-split partner distance drowned out the MDP's.
    # The resident's natural partner is irrelevant here: Article 3.3.1's
    # rule is about which resident the MDP takes, so only the MDP's own
    # displacement counts.
    cond do
      i < mdp_count -> abs(j - Map.get(natural, i, j))
      j < mdp_count -> abs(i - Map.get(natural, j, i))
      true -> 0
    end
  end

  # Deeply negative so any legal pairing (see `pair_weight/2`, always >= 0)
  # is preferred over floating anyone — floating only ever happens when a
  # player has no legal partner left in the bracket at all. `player.rank`
  # is added (not subtracted) so a WORSE-ranked (higher-numbered) player's
  # float weight is less negative, i.e. preferred, whenever the matcher
  # has an actual choice of who floats.
  #
  # A player who already floated into this bracket from a higher one
  # (`:already_floated`, stamped by `cascade_brackets/3`) gets a much more
  # negative base — confirmed against a real `javafo.jar` disagreement
  # (two bracket levels down, both engines agreed exactly one player had
  # to float twice, but picked a different one): javafo strongly prefers
  # floating a bracket's own fresh resident over floating the same player
  # down two levels in a row when a choice exists, matching bbpPairings'
  # own "minimise downfloaters" quality criterion (`dutch.cpp`).
  #
  # A player who already has an unplayed round in their history (a bye, or
  # a forfeit) is also strongly protected from downfloating — traced from a
  # real `javafo.jar` disagreement on a 3-player top bracket
  # {1, 2, 7} where 7 had taken round 1's bye: the natural S1/S2 split
  # pairs 1-2 and floats the worst-ranked player (7), which is what this
  # engine did, but javafo paired 1-7 and floated 2 instead. Colour
  # satisfaction was identical either way, so the bye history is the only
  # thing distinguishing the two players.
  # Every float is worth less than every pair, by an offset larger than any
  # possible pair weight — the matcher must never buy a float with pairing
  # quality. Because a bracket of a given parity always floats the same
  # NUMBER of players, those offsets cancel when two candidate solutions
  # are compared, leaving the ranked remainder below to decide only WHO
  # floats, and only once the pairs themselves are equally good.
  #
  # That subordination is the point. Hand-tracing an 11-player round-3
  # disagreement (seed 12) showed both engines producing fully
  # colour-legal pairings that differed solely in which player took the
  # bye — and this engine picking the one javafo rejected, because the old
  # `+ player.rank` tie-break was numerically worth more than a whole step
  # of MDP displacement. A float preference must never outvote a pairing
  # criterion; it can only break a tie between them.
  # A peeked-ahead player costs NOTHING to leave unpaired — they are not
  # this bracket's responsibility and their own bracket will place them.
  # A neutral cost is what keeps the lookahead optional: the matcher
  # reaches into the next bracket only when a cross-bracket pair is
  # genuinely worth more than the alternatives, never because leaving
  # someone there is penalised.
  defp float_weight(%{bracket_zone: :lookahead}, _spans, _bye_bracket?, _placeable), do: 0

  defp float_weight(player, spans, bye_bracket?, placeable) do
    # The whole value of peeking at the next bracket, expressed as a
    # property of the player rather than as an edge: floating someone who
    # has NO legal, colour-compatible partner waiting below strands them,
    # and the cascade then has to backtrack to discover it. Penalised at
    # the same near-absolute magnitude as the other structural bars.
    #
    # In the final bracket there is nothing below, so every player is
    # equally unplaceable and the term cancels — it can only ever choose
    # BETWEEN floaters, never add a bye.
    stranded = if MapSet.member?(placeable, player.rank), do: 0, else: -spans.max_pair
    # No number of floats can ever buy a pair, and a solution with more
    # pairs always wins: `slots` floats together stay below one pair.
    base = -spans.max_pair * spans.slots

    # Re-floating a player who already floated into this bracket outranks
    # every pairing criterion. Measured, not assumed: demoting this to a
    # tie-break below the pair criteria cost seven points of pair
    # agreement (90.33% -> 83.53%) and most of round 2.
    repeat = if Map.get(player, :already_floated, false), do: -spans.max_pair, else: 0

    # C2 (nobody receives a SECOND pairing-allocated bye) is an ABSOLUTE
    # criterion — bbpPairings' own `matchingIsComplete` requires
    # `eligibleForBye` for the designated bye and fails the WHOLE round
    # rather than accept anything else (`swisssystems/dutch.cpp`). Distinct
    # from `unplayed` below (a deliberately SOFT, magnitude-scaled
    # preference for ANY unplayed round, restricted after seed 15 showed a
    # hard version of THAT specific protection was wrong): this targets
    # only actual C2 eligibility, which really is meant to be near-absolute,
    # not a tie-break.
    #
    # Was previously enforced only by `repair_bye_count/3`'s last-resort
    # Blossom pass, never by the cascade that produces the FIRST answer —
    # found while tracing why that pass ever needed to run at all: the
    # primary cascade had no reason not to float an ineligible player
    # whenever nothing else distinguished the choice.
    ineligible =
      if bye_bracket? and not eligible_for_bye?(player), do: -spans.max_pair, else: 0

    # Protecting a player who already holds an unplayed round applies ONLY
    # in the bracket that actually assigns the bye. bbpPairings guards the
    # equivalent criterion with `isSingleDownfloaterTheByeAssignee` and
    # restricts it to players on the bye assignee's score: it is
    # "minimise the unplayed games of the BYE ASSIGNEE", not a standing
    # protection against downfloating anyone who once had a bye.
    #
    # Applying it everywhere was measurably wrong. Seed 15, round 4: the
    # 1.5 bracket had to float one of players 6, 12 and 15, and 6-12 is
    # the natural correspondence — which javafo took, floating 15. This
    # engine floated 6 instead, purely because 15 held a round-1 bye, and
    # that protection outweighed the whole pairing difference.
    unplayed =
      if bye_bracket?, do: unplayed_rounds(player) * spans.unplayed_unit, else: 0

    # The plain "float the worse-ranked player" convention sits at the
    # very bottom with rank spread — low enough that it can only ever
    # break a tie, which is what seed 12 showed it must be.
    base + repeat + ineligible + stranded - unplayed + player.rank
  end

  defp unplayed_rounds(player) do
    Enum.count(player.games, &(not played?(&1)))
  end

  # bbpPairings' `gameWasPlayed`. Only an actually contested game counts:
  # a forfeit carries both an opponent and a colour in the TRF, which is
  # exactly what makes it dangerous — it LOOKS like a played game to any
  # check that tests for the presence of an opponent or a colour, but
  # FIDE Art. 16 treats it as unplayed. It must not affect colour balance,
  # must not extend a repeated-colour run, and counts as an unplayed round
  # for float direction and bye eligibility.
  #
  # Every one of those was wrong here until the harness started generating
  # forfeits: three separate call sites tested for an opponent or a colour
  # instead of asking whether the game happened.
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
  # bbpPairings' `eligibleForBye` phrases it as "no unplayed game already
  # worth at least a win", which also rules out a player who took a forfeit
  # win — a half-point bye leaves them eligible. Enforced as a hard
  # requirement on the cascade's final state rather than scored, so the
  # backtracking search has to find a legal bye assignee or report that
  # none exists.
  defp eligible_for_bye?(player) do
    not Enum.any?(player.games, &(&1.result in ["U", "F", "+"]))
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
