defmodule Ainalrami.TeamPairing.Bracket do
  @moduledoc """
  Article 3.6 - pairing one bracket.

  This is the module where team pairing stops resembling the individual
  system. C.04.3 defines a lexicographic weight ladder and asks for the best
  candidate under it; 3.6 defines an ORDER over pairings and asks for the
  first one satisfying a predicate. There is no objective function to
  maximise and no matching to solve, so `Ainalrami.WeightedMatching` is not
  involved at all.

  ## The order (3.6.1-3.6.3)

  A pairing is a set of pairs covering the bracket. In each pair the smaller
  TPN is the *top member*, the larger the *bottom member*. The identifier is
  the top members ascending, followed by their corresponding bottom members;
  pairings sort by that identifier lexicographically. The regulation's own
  example: `11-24  16-6  10-9  8-4` has identifier `4 6 9 11 8 16 10 24`.

  Since the top-half of every identifier has the same length, comparing
  identifiers is: compare the sorted top-member sets, and only on a tie
  compare the bottom sequence. So the enumeration is two nested walks -
  candidate top-sets in lexicographic order, and within each, assignments of
  bottoms in lexicographic order.

  ## The predicate (3.6.4), and why it is not simply a filter

  3.6.4 says to take the first pairing "that also complies with criteria
  [C1], [C8], [C9] and [C10]". [C1] is a genuine predicate - no rematches.
  The other three are *minimisation* criteria ("minimise the number of teams
  whose colour preference is not fulfilled"), and a pairing cannot comply
  with a minimisation in isolation: it complies by achieving the minimum
  attainable over the bracket's legal pairings.

  So the answer is the pairing that minimises `{c8, c9, c10}`
  lexicographically, tie-broken by identifier order. That is exactly "the
  first compliant pairing in identifier order", restated so it can be
  computed - and it is why this walks candidates rather than stopping at the
  first legal one.

  **It stops early when it can prove it is done.** `{0, 0, 0}` cannot be
  beaten, so the first candidate scoring it is the answer and the walk ends
  there. In a round-one bracket, or any bracket where preferences happen to
  be satisfiable, that is the very first candidate - which is the case the
  regulation is shaped for.

  ## Cost, honestly

  A bracket of 2n teams has (2n-1)!! pairings: 945 at ten teams, 6.5x10^8 at
  twenty. Round one is a single bracket containing the whole field, so the
  bad case is not exotic - it is every event's first round.

  What keeps it tractable is that the walk is lazy, prunes on prefixes ([C1]
  kills a subtree the moment a pair repeats), and stops at `{0, 0, 0}`. Where
  it cannot stop early, `:max_candidates` bounds the search and the result
  says so rather than hanging: `exhaustive?: false` means "best found within
  the budget", not "proven optimal". A caller that must have the proof can
  raise the budget; a caller pairing a real round gets an answer.
  """

  alias Ainalrami.TeamPairing.{Matching, Team}

  import Bitwise

  @default_max_candidates 200_000

  @doc """
  Pairs `teams` (a bracket - an even-sized list) and returns

      {:ok, %{pairs: [{top_tpn, bottom_tpn}], scores: {c8, c9, c10},
              candidates: n, exhaustive?: bool}}

  or `{:error, :no_legal_pairing}` when [C1] admits none.

  Options:

    * `:type` / `:last_round?` - colour-preference type (1.7), for [C8]/[C9].
    * `:upfloater_tpns` - the TPNs in this bracket that are upfloaters, for
      [C10] (which counts upfloaters' OPPONENTS that were floaters in the
      previous round). Empty for a bracket of residents only.
    * `:last_two_rounds?` - [C7] and [C10] "with the exception of the last
      two rounds". When true, [C10] contributes nothing.
    * `:max_candidates` - search budget, default #{@default_max_candidates}.
  """
  def pair(teams, opts \\ [])

  def pair([], _opts),
    do: {:ok, %{pairs: [], scores: {0, 0, 0}, candidates: 0, exhaustive?: true}}

  def pair(teams, opts) when is_list(teams) do
    if rem(length(teams), 2) == 1 do
      # 1.3.2: a bracket is "an even numbered group of teams all to be
      # paired". An odd one is a caller bug, not a pairing outcome - the odd
      # team should have become the PAB (3.4) or an upfloater target.
      raise ArgumentError,
            "a bracket must have an even number of teams (Article 1.3.2), got #{length(teams)}"
    end

    sorted = Enum.sort_by(teams, & &1.tpn)
    by_tpn = Map.new(sorted, &{&1.tpn, &1})
    tpns = Enum.map(sorted, & &1.tpn)

    ctx = %{
      tpns: List.to_tuple(tpns),
      by_tpn: by_tpn,
      n: length(tpns),
      type: Keyword.get(opts, :type, :a),
      last_round?: Keyword.get(opts, :last_round?, false),
      upfloaters: MapSet.new(Keyword.get(opts, :upfloater_tpns, [])),
      last_two_rounds?: Keyword.get(opts, :last_two_rounds?, false),
      max_candidates: Keyword.get(opts, :max_candidates, @default_max_candidates)
    }

    search(ctx)
  end

  # Walk top-sets in lexicographic order; for each, walk bottom assignments
  # in lexicographic order. Track the best {c8,c9,c10}; stop dead on {0,0,0}.
  defp search(ctx) do
    half = div(ctx.n, 2)
    all_indices = Enum.to_list(0..(ctx.n - 1))

    state = %{best: nil, best_scores: nil, candidates: 0, exhausted: false}

    state = walk_top_sets(all_indices, half, [], 0, ctx, state)

    case state.best do
      nil -> {:error, :no_legal_pairing}
      pairs ->
        {:ok,
         %{
           pairs: pairs,
           scores: state.best_scores,
           candidates: state.candidates,
           exhaustive?: not state.exhausted
         }}
    end
  end

  # Choose which indices are top members, in ascending (hence lexicographic)
  # order. `chosen` accumulates reversed.
  defp walk_top_sets(_avail, 0, chosen, _from, ctx, state) do
    tops = Enum.reverse(chosen)
    bottoms = Enum.to_list(0..(ctx.n - 1)) -- tops
    walk_bottoms(tops, bottoms, [], ctx, state)
  end

  defp walk_top_sets(avail, need, chosen, from, ctx, state) do
    candidates = Enum.filter(avail, &(&1 >= from))

    Enum.reduce_while(candidates, state, fn idx, state ->
      if done?(state) do
        {:halt, state}
      else
        # A top member must have SOMETHING larger left to pair with; the
        # largest index can never be a top. Cheap prefix prune.
        if idx == ctx.n - 1 do
          {:cont, state}
        else
          state =
            walk_top_sets(avail -- [idx], need - 1, [idx | chosen], idx + 1, ctx, state)

          {:cont, state}
        end
      end
    end)
  end

  # Assign each top (in ascending order) its bottom, trying bottoms in
  # ascending order so the bottom sequence comes out lexicographically.
  defp walk_bottoms([], [], acc, ctx, state) do
    pairs =
      acc
      |> Enum.reverse()
      |> Enum.map(fn {t, b} -> {elem(ctx.tpns, t), elem(ctx.tpns, b)} end)

    score_candidate(pairs, ctx, state)
  end

  defp walk_bottoms([t | tops], bottoms, acc, ctx, state) do
    top_tpn = elem(ctx.tpns, t)
    top_team = Map.fetch!(ctx.by_tpn, top_tpn)

    Enum.reduce_while(bottoms, state, fn b, state ->
      cond do
        done?(state) ->
          {:halt, state}

        # The top member is by definition the smaller TPN of its pair.
        b < t ->
          {:cont, state}

        # [C1] (2.1.1) - prefix prune. Everything below this choice is dead,
        # and "everything below" is most of the tree.
        Team.met?(top_team, elem(ctx.tpns, b)) ->
          {:cont, state}

        true ->
          rest = bottoms -- [b]

          if completable?(tops, rest, ctx) do
            {:cont, walk_bottoms(tops, rest, [{t, b} | acc], ctx, state)}
          else
            {:cont, state}
          end
      end
    end)
  end

  # [C3]-flavoured prune inside the bracket: can the remaining tops still be
  # given distinct legal bottoms at all? Answering it here turns a doomed
  # subtree into one feasibility query instead of a full descent.
  #
  # Skipped for tiny remainders, where descending is cheaper than building
  # the adjacency.
  defp completable?(tops, bottoms, _ctx) when length(tops) <= 1,
    do: length(tops) == length(bottoms)

  defp completable?(tops, bottoms, ctx) do
    indices = tops ++ bottoms
    position = indices |> Enum.with_index() |> Map.new()

    adj =
      Map.new(indices, fn i ->
        tpn = elem(ctx.tpns, i)
        team = Map.fetch!(ctx.by_tpn, tpn)

        partners =
          Enum.reduce(indices, 0, fn j, mask ->
            cond do
              j == i -> mask
              # Only top-bottom pairs exist in this sub-problem.
              (i in tops) == (j in tops) -> mask
              Team.met?(team, elem(ctx.tpns, j)) -> mask
              true -> mask ||| 1 <<< Map.fetch!(position, j)
            end
          end)

        {Map.fetch!(position, i), partners}
      end)

    full = (1 <<< length(indices)) - 1
    Matching.feasible?(full, adj)
  end

  # 3.6.4's three minimisation criteria, computed for a complete candidate.
  defp score_candidate(pairs, ctx, state) do
    state = %{state | candidates: state.candidates + 1}

    if state.candidates > ctx.max_candidates do
      %{state | exhausted: true}
    else
      scores = criteria(pairs, ctx)

      state =
        if is_nil(state.best_scores) or scores < state.best_scores do
          %{state | best: pairs, best_scores: scores}
        else
          state
        end

      state
    end
  end

  @doc """
  `{c8, c9, c10}` for a complete candidate pairing.

  * [C8] (2.3.5) - teams whose colour preference is not fulfilled. A pair
    where both want the same colour leaves exactly one unfulfilled; a pair
    with opposite or absent preferences leaves none. This counts what
    Article 4 will be forced to refuse, without running Article 4 - and it
    does not need to, because the only pairs that cost anything are the ones
    wanting the same colour.
  * [C9] (2.3.6) - the same count restricted to STRONG preferences, Type B
    only. Zero under Type A, where no preference is mild and 4.3.4 never
    fires.
  * [C10] (2.3.7) - upfloaters' opponents that were floaters in the previous
    round. Nothing in the last two rounds.
  """
  def criteria(pairs, ctx) do
    c8 =
      Enum.count(pairs, fn {a, b} ->
        clash?(
          Team.preference(Map.fetch!(ctx.by_tpn, a), ctx.type, ctx.last_round?),
          Team.preference(Map.fetch!(ctx.by_tpn, b), ctx.type, ctx.last_round?)
        )
      end)

    c9 =
      if ctx.type == :b do
        Enum.count(pairs, fn {a, b} ->
          pa = Team.preference(Map.fetch!(ctx.by_tpn, a), ctx.type, ctx.last_round?)
          pb = Team.preference(Map.fetch!(ctx.by_tpn, b), ctx.type, ctx.last_round?)
          clash?(pa, pb) and Team.strong?(pa) and Team.strong?(pb)
        end)
      else
        0
      end

    c10 =
      if ctx.last_two_rounds? or MapSet.size(ctx.upfloaters) == 0 do
        0
      else
        Enum.count(pairs, fn {a, b} ->
          opponent_of_upfloater_floated?(a, b, ctx) or
            opponent_of_upfloater_floated?(b, a, ctx)
        end)
      end

    {c8, c9, c10}
  end

  # Both teams wanting the same colour is the only shape that costs a team
  # its preference: one of them must be refused.
  defp clash?(:none, _), do: false
  defp clash?(_, :none), do: false
  defp clash?({c, _}, {c, _}), do: true
  defp clash?(_, _), do: false

  defp opponent_of_upfloater_floated?(upfloater_tpn, opponent_tpn, ctx) do
    MapSet.member?(ctx.upfloaters, upfloater_tpn) and
      Map.fetch!(ctx.by_tpn, opponent_tpn).floated_last_round?
  end

  defp done?(%{best_scores: {0, 0, 0}}), do: true
  defp done?(%{exhausted: true}), do: true
  defp done?(_), do: false
end
