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

  # The candidate budget cannot bound the case that actually runs long.
  # `state.candidates` is incremented only in `score_candidate/4`, which is
  # reached only for a COMPLETE legal pairing - so on a bracket where no
  # legal pairing exists, nothing is ever counted and the only thing bounding
  # the walk is the pruning. The pruning is sound but not tight: a structured
  # infeasible bracket measured 300 ms at sixteen teams and 10.4 s at twenty,
  # a 25% larger bracket for 35x the time, with the candidate budget never
  # engaging once. Round one is one bracket containing the whole field, so
  # this is not an exotic shape.
  #
  # `:max_steps` counts the walk itself - every complete top-set, every
  # `walk_bottoms/8` call and every `completable?/5` feasibility query - and
  # is checked where the candidate budget is, through `done?/1`. Exceeding it
  # is `{:error, :budget_exhausted}` rather than a best-effort answer:
  # unlike the candidate budget, which gives up having already seen a great
  # many complete pairings, this one can give up before seeing a single one,
  # and "no legal pairing exists" and "I stopped looking" are different
  # answers a caller has to be able to tell apart.
  #
  # ## Where the default comes from, and what it does not do
  #
  # Measured on this machine, all with the same construction the sweep used
  # (a clique of teams that have all met each other, larger than the rest of
  # the bracket, so no legal pairing exists):
  #
  #   * a legal forty-team round-one bracket: 402 steps, under a
  #     millisecond. Its first candidate scores {0, 0, 0} and the walk stops.
  #   * the worst LEGAL forty-team bracket found - every team with a played
  #     match, colour preferences that collide across the identifier-first
  #     ordering, and a rematch to route around: 1.63M steps in 1.37 s, and
  #     already stopped by the CANDIDATE budget rather than by exhaustion.
  #   * the infeasible twenty-team bracket: 12.5 s, and more than 10M steps.
  #
  # So 10M is about six times the worst legal bracket measured and twenty-five
  # thousand times the ordinary one. Not the hundredfold headroom that would
  # be natural for a budget, and deliberately not: at roughly 600k steps a
  # second here, a hundredfold budget is a four-minute wall clock, which
  # bounds nothing anybody would sit through. The worst legal bracket costs
  # seconds, so no single number can both spare it and answer quickly - this
  # bounds a HANG, and a caller that needs a latency bound passes its own
  # `:max_steps`. 200_000 turns the twenty-team bracket above from 12.5 s
  # into 370 ms; `Ainalrami.TeamPairing.pair_round/2` forwards the option for
  # exactly that.
  @default_max_steps 10_000_000

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
    * `:max_candidates` - candidate budget, default #{@default_max_candidates}.
    * `:max_steps` - walk budget, default #{@default_max_steps}; exceeding it
      returns `{:error, :budget_exhausted}`.
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
    type = Keyword.get(opts, :type, :a)
    last_round? = Keyword.get(opts, :last_round?, false)
    upfloaters = MapSet.new(Keyword.get(opts, :upfloater_tpns, []))
    last_two_rounds? = Keyword.get(opts, :last_two_rounds?, false)

    ctx = %{
      tpns: List.to_tuple(tpns),
      by_tpn: by_tpn,
      n: length(tpns),
      type: type,
      last_round?: last_round?,
      upfloaters: upfloaters,
      last_two_rounds?: last_two_rounds?,
      max_candidates: Keyword.get(opts, :max_candidates, @default_max_candidates),
      max_steps: Keyword.get(opts, :max_steps, @default_max_steps)
    }

    search(Map.merge(ctx, walk_tables(tpns, by_tpn, ctx)))
  end

  # Everything the walk asks about a team or a pair, worked out once per
  # bracket instead of once per question (2026-09-16). The walk used to call
  # `Team.met?/2` for every bottom it tried, rebuild an adjacency map for
  # every feasibility query, and recompute every team's colour preference -
  # `Team.preference/3` counts the whole colour history - for every pair of
  # every complete candidate. On a 79-team bracket that runs to its 200,000
  # candidate budget, the preference recounting alone was three quarters of
  # the round.
  #
  # Nothing here changes an answer:
  #
  #   * `allowed` is `Team.met?/2` from the TOP member's side, exactly the
  #     question the walk asked (`try_bottoms/4`) and exactly the adjacency
  #     `completable?/5` used to build - from the lowest index, which is
  #     always a top;
  #   * `info` holds, per team, what `criteria/2` reads: the colour and
  #     strength of `Team.preference/3` (a pure function of the team),
  #     whether it is an upfloater here, and whether it floated last round.
  defp walk_tables(tpns, by_tpn, ctx) do
    positions =
      tpns
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {tpn, i}, acc -> Map.update(acc, tpn, [i], &[i | &1]) end)

    full = (1 <<< length(tpns)) - 1

    allowed =
      tpns
      |> Enum.with_index()
      |> Enum.map(fn {tpn, i} ->
        met =
          by_tpn
          |> Map.fetch!(tpn)
          |> Map.fetch!(:opponents)
          |> Enum.reduce(0, fn opp, acc ->
            positions |> Map.get(opp, []) |> Enum.reduce(acc, &(&2 ||| 1 <<< &1))
          end)

        full &&& bnot(met ||| 1 <<< i)
      end)
      |> List.to_tuple()

    info =
      tpns
      |> Enum.map(fn tpn ->
        team = Map.fetch!(by_tpn, tpn)
        preference = Team.preference(team, ctx.type, ctx.last_round?)

        {Team.preferred_colour(preference), Team.strong?(preference),
         MapSet.member?(ctx.upfloaters, tpn), team.floated_last_round?}
      end)
      |> List.to_tuple()

    %{
      allowed: allowed,
      info: info,
      c10?: not (ctx.last_two_rounds? or MapSet.size(ctx.upfloaters) == 0)
    }
  end

  # Walk top-sets in lexicographic order; for each, walk bottom assignments
  # in lexicographic order. Track the best {c8,c9,c10}; stop dead on {0,0,0}.
  defp search(ctx) do
    half = div(ctx.n, 2)

    state = %{
      best: nil,
      best_scores: nil,
      candidates: 0,
      exhausted: false,
      steps: 0,
      out_of_steps: false
    }

    state = walk_top_sets(half, [], 0, ctx, state)

    cond do
      state.out_of_steps ->
        {:error, :budget_exhausted}

      is_nil(state.best) ->
        {:error, :no_legal_pairing}

      true ->
        pairs = state.best

        {:ok,
         %{
           pairs: pairs,
           scores: state.best_scores,
           candidates: state.candidates,
           steps: state.steps,
           exhaustive?: not state.exhausted
         }}
    end
  end

  # One unit of walk. Counted in the three places the walk actually spends
  # itself, so the bound holds whether the cost is in enumerating top-sets,
  # assigning bottoms, or proving a subtree dead.
  defp step(state, ctx, cost \\ 1) do
    steps = state.steps + cost

    if steps > ctx.max_steps do
      %{state | steps: steps, out_of_steps: true}
    else
      %{state | steps: steps}
    end
  end

  # Choose which indices are top members, in ascending (hence lexicographic)
  # order. `chosen` accumulates reversed. Every index already chosen is below
  # `from`, so the indices still available from `from` on are exactly
  # `from..n-1`.
  defp walk_top_sets(0, chosen, _from, ctx, state) do
    state = step(state, ctx)
    tops = Enum.reverse(chosen)
    top_mask = Enum.reduce(tops, 0, &(&2 ||| 1 <<< &1))
    bottoms = for i <- 0..(ctx.n - 1)//1, (top_mask >>> i &&& 1) == 0, do: i
    bottom_mask = (1 <<< ctx.n) - 1 &&& bnot(top_mask)
    walk_bottoms(tops, length(tops), bottoms, bottom_mask, [], {0, 0, 0}, ctx, state)
  end

  defp walk_top_sets(need, chosen, from, ctx, state) do
    Enum.reduce_while(from..(ctx.n - 1)//1, state, fn idx, state ->
      if done?(state) do
        {:halt, state}
      else
        # A top member must have SOMETHING larger left to pair with; the
        # largest index can never be a top. Cheap prefix prune.
        if idx == ctx.n - 1 do
          {:cont, state}
        else
          state = walk_top_sets(need - 1, [idx | chosen], idx + 1, ctx, state)

          {:cont, state}
        end
      end
    end)
  end

  # Assign each top (in ascending order) its bottom, trying bottoms in
  # ascending order so the bottom sequence comes out lexicographically.
  #
  # `k` is `length(tops)`, and `length(bottoms)` is always the same. `costs`
  # is `{c8, c9, c10}` of the pairs in `acc`, summed as they are added, so a
  # complete candidate's criteria cost nothing more to know.
  defp walk_bottoms([], _k, [], _bottom_mask, acc, costs, ctx, state) do
    state = step(state, ctx)
    score_candidate(acc, costs, ctx, state)
  end

  defp walk_bottoms([t | tops], k, bottoms, bottom_mask, acc, costs, ctx, state) do
    state = step(state, ctx)
    node = {t, tops, k, bottoms, bottom_mask, elem(ctx.allowed, t), acc, costs}
    try_bottoms(bottoms, node, ctx, state)
  end

  # The bottoms of one top, in order - a plain recursion rather than
  # `Enum.reduce_while/3`, whose protocol dispatch was a sixth of the walk.
  defp try_bottoms([], _node, _ctx, state), do: state

  defp try_bottoms([b | more], node, ctx, state) do
    {t, tops, k, bottoms, bottom_mask, allowed, acc, costs} = node

    cond do
      done?(state) ->
        state

      # The top member is by definition the smaller TPN of its pair.
      b < t ->
        try_bottoms(more, node, ctx, state)

      # [C1] (2.1.1) - prefix prune. Everything below this choice is dead,
      # and "everything below" is most of the tree.
      (allowed >>> b &&& 1) == 0 ->
        try_bottoms(more, node, ctx, state)

      true ->
        rest = List.delete(bottoms, b)
        rest_mask = bxor(bottom_mask, 1 <<< b)

        # Weighted: `completable?/5` is a matching over the whole
        # remainder, so it is not one unit of the same work `walk_bottoms/8`
        # is. Charged by the size of the sub-problem it is asked about -
        # `length(tops) + length(rest)`, the two being equal - which is what
        # its cost was proportional to when the budget was set. The charge
        # is unchanged by the 2026-09-16 speed-up, so a bracket runs out of
        # steps at exactly the point it always did.
        state = step(state, ctx, 2 * (k - 1))

        state =
          if not state.out_of_steps and completable?(tops, k - 1, rest, rest_mask, ctx) do
            costs = add_costs(costs, t, b, ctx)
            walk_bottoms(tops, k - 1, rest, rest_mask, [{t, b} | acc], costs, ctx, state)
          else
            state
          end

        try_bottoms(more, node, ctx, state)
    end
  end

  # [C3]-flavoured prune inside the bracket: can the remaining tops still be
  # given distinct legal bottoms at all? Answering it here turns a doomed
  # subtree into one feasibility query instead of a full descent.
  #
  # Skipped for tiny remainders, where descending is cheaper than asking. A
  # single top and a single bottom answer "yes" without checking that the two
  # have not met: the descent finds out, and the answer has always been
  # given this way, so the walk's step count depends on it.
  #
  # The matching is `Matching.bipartite_perfect?/3` over the precomputed
  # `allowed` masks. It used to build a fresh adjacency map over the whole
  # remainder with a list-membership test per pair - cubic in the bracket
  # size, and on a 500-team round one nearly all of the fifty seconds the
  # round took. Both answer whether a perfect matching exists, so the walk
  # prunes exactly the same subtrees. Up to three tops - most of the calls,
  # the walk spending its time near the leaves - every assignment is simply
  # tried.
  defp completable?(_tops, k, _bottoms, _bottom_mask, _ctx) when k <= 1, do: true

  defp completable?(tops, k, bottoms, _bottom_mask, ctx) when k <= 3,
    do: assignable?(tops, bottoms, ctx.allowed)

  defp completable?(tops, _k, _bottoms, bottom_mask, ctx),
    do: Matching.bipartite_perfect?(tops, bottom_mask, ctx.allowed)

  defp assignable?([], [], _allowed), do: true

  defp assignable?([t | tops], bottoms, allowed) do
    mask = elem(allowed, t)

    Enum.any?(bottoms, fn b ->
      (mask >>> b &&& 1) == 1 and assignable?(tops, List.delete(bottoms, b), allowed)
    end)
  end

  # {c8, c9, c10} of one pair, added to the running sums. The same three
  # counts `criteria/2` makes per pair, from the tables.
  defp add_costs({c8, c9, c10} = costs, t, b, ctx) do
    {colour_t, strong_t, up_t, floated_t} = elem(ctx.info, t)
    {colour_b, strong_b, up_b, floated_b} = elem(ctx.info, b)

    c10_add =
      if ctx.c10? do
        bool_to_int(up_t and floated_b) + bool_to_int(up_b and floated_t)
      else
        0
      end

    cond do
      # `clash?/2`: both want a colour, and the same one.
      colour_t != nil and colour_t == colour_b ->
        c9_add = if ctx.type == :b and strong_t and strong_b, do: 1, else: 0
        {c8 + 1, c9 + c9_add, c10 + c10_add}

      c10_add == 0 ->
        costs

      true ->
        {c8, c9, c10 + c10_add}
    end
  end

  # 3.6.4's three minimisation criteria for a complete candidate - already
  # summed along the walk (`add_costs/4`), so equal to `criteria/2` of its
  # pairs. The pairs themselves are only built for a new best.
  defp score_candidate(acc, scores, ctx, state) do
    state = %{state | candidates: state.candidates + 1}

    cond do
      state.candidates > ctx.max_candidates ->
        %{state | exhausted: true}

      is_nil(state.best_scores) or scores < state.best_scores ->
        pairs =
          acc
          |> Enum.reverse()
          |> Enum.map(fn {t, b} -> {elem(ctx.tpns, t), elem(ctx.tpns, b)} end)

        %{state | best: pairs, best_scores: scores}

      true ->
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
        # Counted per TEAM, as 2.3.7 reads ("the number of upfloaters'
        # opponents"): when two upfloaters meet and both floated last round,
        # each is an upfloater's opponent that floated, and that is two. It
        # was counted once per pair; found by reading while writing the
        # whole-round reference in `team_pairing_validation_test.exs`, whose
        # generated rounds had not happened to reach the shape.
        Enum.reduce(pairs, 0, fn {a, b}, n ->
          n + bool_to_int(opponent_of_upfloater_floated?(a, b, ctx)) +
            bool_to_int(opponent_of_upfloater_floated?(b, a, ctx))
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

  defp bool_to_int(true), do: 1
  defp bool_to_int(false), do: 0

  defp done?(%{out_of_steps: true}), do: true
  defp done?(%{best_scores: {0, 0, 0}}), do: true
  defp done?(%{exhausted: true}), do: true
  defp done?(_), do: false
end
