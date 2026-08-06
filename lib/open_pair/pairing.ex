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

  alias OpenPair.{Blossom, Matching}

  # Bounds on the bracket cascade's backtracking search (see
  # `cascade_brackets/4`): how many alternative matchings of a single
  # bracket to consider, and how much total work to spend before giving up
  # and returning a best-effort answer.
  @budget_key :openpair_cascade_budget
  @expected_rounds_key :openpair_expected_rounds
  @cascade_budget 2000
  @alternatives_per_bracket 15
  @alternatives_per_count 6

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
    # one. Anything else isn't a legal round, so it's a hard requirement on
    # the cascade rather than something to score. Counted over the ACTIVE
    # players — a field of even size with one player sitting out needs a
    # bye, and one of odd size with one sitting out does not.
    allowed_byes = rem(length(active), 2)

    Process.put(@budget_key, @cascade_budget)

    try do
      case cascade_brackets(brackets, [], [], allowed_byes) do
        {:ok, pairs, leftover} ->
          pairs ++ Enum.map(leftover, &{&1.rank, nil})

        :infeasible ->
          brackets
          |> greedy_cascade()
          |> repair_bye_count(active, allowed_byes)
      end
    after
      Process.delete(@budget_key)
    end
  end

  # Last resort, and only ever reached after the cascade has already given
  # up: take whatever pairing greedy produced and try to reduce its bye
  # count to something legal via `OpenPair.Blossom`'s general-graph
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
  defp repair_bye_count(result, active, allowed_byes) do
    byes = Enum.count(result, fn {_white, black} -> is_nil(black) end)

    if byes <= allowed_byes do
      result
    else
      # Colour stats are normally stamped inside `bracket_options/2`;
      # this path never went through it.
      by_rank = Map.new(active, &{&1.rank, Map.put(&1, :colour_stats, colour_stats(&1))})
      matching = Map.new(result, fn {w, b} -> {w, b} end) |> add_reverse_edges()

      neighbours_fun = fn rank ->
        player = Map.fetch!(by_rank, rank)

        by_rank
        |> Map.values()
        |> Enum.filter(
          &(&1.rank != rank and legal_pair?(player, &1) and colour_compatible?(player, &1))
        )
        |> Enum.map(& &1.rank)
      end

      by_rank
      |> Map.keys()
      |> Blossom.augment(matching, neighbours_fun)
      |> to_pairs(active)
    end
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

  # Used only when no legal completion was found within the search budget:
  # take each bracket's own best matching and accept whatever falls out,
  # which is what this engine did unconditionally before. It can emit an
  # illegal number of byes, but returning a wrong pairing beats returning
  # none, and the harness reports it either way.
  defp greedy_cascade(brackets) do
    {pairs, leftover} =
      Enum.reduce(brackets, {[], []}, fn residents, {pairs, floaters} ->
        bracket = Enum.sort_by(floaters ++ residents, &{-&1.points, &1.rank})
        [{new_pairs, unpaired} | _] = bracket_options(bracket, residents == List.last(brackets))
        {pairs ++ new_pairs, Enum.map(unpaired, &Map.put(&1, :already_floated, true))}
      end)

    pairs ++ Enum.map(leftover, &{&1.rank, nil})
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

  # Depth-first over the brackets, taking each bracket's own best matching
  # first and only reconsidering it when everything downstream turns out to
  # have no legal completion. Pairing each bracket greedily is what stranded
  # a final bracket of two players who had already met (seed 14) — the
  # bracket above had a slightly worse matching that floated two more
  # players down, which is exactly what javafo picks.
  #
  # @alternatives_per_bracket caps the branching and @cascade_budget the
  # total work, because this is a search and a pathological history should
  # degrade to a wrong answer rather than to no answer.
  defp cascade_brackets([], floaters, pairs, allowed_byes) do
    if length(floaters) <= allowed_byes and Enum.all?(floaters, &eligible_for_bye?/1) do
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

      bracket
      |> bracket_options(rest == [])
      |> Enum.take(@alternatives_per_bracket)
      |> Enum.reduce_while(:infeasible, fn {new_pairs, unpaired}, _acc ->
        # Stamped on the way OUT, not the way in: `unpaired` mixes players
        # who already carried the flag (floated into THIS bracket from
        # above) with ones floating for the first time — both must enter
        # the NEXT bracket already marked, so `float_weight/2` can tell
        # "floated already" from "floating for the first time" at every
        # level, not just the first.
        marked = Enum.map(unpaired, &Map.put(&1, :already_floated, true))

        case cascade_brackets(rest, marked, pairs ++ new_pairs, allowed_byes) do
          {:ok, final_pairs, final_floaters} -> {:halt, {:ok, final_pairs, final_floaters}}
          :infeasible -> {:cont, :infeasible}
        end
      end)
    end
  end

  # Every matching this bracket admits, best first — one per achievable
  # number of floaters. The cascade takes the head unless the rest of the
  # round can't be completed from it.
  defp bracket_options(ranked, bye_bracket?) do
    natural = natural_partner_map(ranked)

    indexed =
      ranked
      |> Enum.with_index()
      |> Enum.map(fn {p, i} ->
        p |> Map.put(:bracket_pos, i) |> Map.put(:colour_stats, colour_stats(p))
      end)

    bracket_spans = spans(indexed)

    indexed
    |> Matching.max_weight_matchings(
      &pair_weight(&1, &2, natural, bracket_spans),
      &float_weight(&1, bracket_spans, bye_bracket?)
    )
    |> Enum.sort_by(fn {count, _candidates} -> count end)
    |> Enum.flat_map(fn {_count, candidates} ->
      candidates
      |> Enum.uniq_by(fn {_weight, _pairs, floaters} ->
        Enum.sort(Enum.map(floaters, & &1.rank))
      end)
      |> Enum.take(@alternatives_per_count)
    end)
    |> Enum.map(fn {_weight, pairs, floaters} ->
      {Enum.map(pairs, &assign_colour_with_history/1), floaters}
    end)
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

    spans = %{
      slots: slots,
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
    unit_f4 = unit_deviation * spans.deviation
    unit_f3 = unit_f4 * spans.float_single
    unit_f2 = unit_f3 * spans.float_pair
    unit_f1 = unit_f2 * spans.float_single
    unit_c4 = unit_f1 * spans.float_pair

    spans
    |> Map.put(:unplayed_unit, unit_f4)
    |> Map.put(:max_pair, unit_c4 * spans.colour * spans.colour * spans.colour * spans.colour)
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
  defp pair_weight(a, b, %{mdp_count: mdp_count} = natural, spans) do
    if legal_pair?(a, b) and colour_compatible?(a, b) do
      # bbpPairings passes (higherPlayer, lowerPlayer) by bracket order, and
      # the absolute-preference tie-break in `colour_criteria/2` is not
      # symmetric in the two, so the roles have to be assigned the same way
      # here rather than taking `a`/`b` as the matcher happens to give them.
      {higher, lower} = if a.bracket_pos <= b.bracket_pos, do: {a, b}, else: {b, a}
      {c1, c2, c3, c4} = colour_criteria(higher, lower)
      {f1, f2, f3, f4} = float_criteria(higher, lower)
      deviation = mdp_deviation(a, b, natural, mdp_count)

      ranked([
        {bit(c1), spans.colour},
        {bit(c2), spans.colour},
        {bit(c3), spans.colour},
        {bit(c4), spans.colour},
        {f1, spans.float_pair},
        {f2, spans.float_single},
        {f3, spans.float_pair},
        {f4, spans.float_single},
        {spans.deviation - 1 - deviation, spans.deviation},
        {abs(a.rank - b.rank), spans.spread}
      ])
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
  defp mdp_deviation(_a, _b, _natural, 0), do: 0

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
  defp float_weight(player, spans, bye_bracket?) do
    # No number of floats can ever buy a pair, and a solution with more
    # pairs always wins: `slots` floats together stay below one pair.
    base = -spans.max_pair * spans.slots

    # Re-floating a player who already floated into this bracket outranks
    # every pairing criterion. Measured, not assumed: demoting this to a
    # tie-break below the pair criteria cost seven points of pair
    # agreement (90.33% -> 83.53%) and most of round 2.
    repeat = if Map.get(player, :already_floated, false), do: -spans.max_pair, else: 0

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
    base + repeat - unplayed + player.rank
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
