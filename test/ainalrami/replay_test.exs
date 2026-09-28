defmodule Ainalrami.ReplayTest do
  @moduledoc """
  The incremental forced searches of `Ainalrami.Alternatives`
  (`Ainalrami.Pairing.Replay`): the certificate they rest on, checked
  against brute force, and their answers checked against the full
  re-pairing on generated rounds. `tools/alt_diff.exs` is the same check at
  corpus scale.
  """
  # Not async: one test switches `AINALRAMI_ALT_REPLAY`, which is VM-wide.
  use ExUnit.Case, async: false

  alias Ainalrami.{Alternatives, Pairing, WeightedMatching}
  alias Ainalrami.Test.FuzzTournament, as: Fuzz

  # ------------------------------------------------------------- brute force

  # Every matching of the graph, as `%{v => partner}`.
  defp matchings(vertices, weight) do
    case vertices do
      [] ->
        [%{}]

      [v | rest] ->
        alone = matchings(rest, weight)

        paired =
          for u <- rest,
              Map.has_key?(weight, key(v, u)),
              m <- matchings(rest -- [u], weight),
              do: m |> Map.put(v, u) |> Map.put(u, v)

        alone ++ paired
    end
  end

  defp key(a, b), do: {min(a, b), max(a, b)}

  defp total(m, weight) do
    Enum.reduce(m, 0, fn {a, b}, acc ->
      if a < b, do: acc + Map.fetch!(weight, {a, b}), else: acc
    end)
  end

  # For each vertex, every partner (or `:exposed`) it has in SOME maximum-
  # weight matching.
  defp optimal_partners(n, weight) do
    all = matchings(Enum.to_list(0..(n - 1)), weight)
    best = all |> Enum.map(&total(&1, weight)) |> Enum.max()
    optima = Enum.filter(all, &(total(&1, weight) == best))

    Map.new(0..(n - 1), fn v ->
      {v, optima |> Enum.map(&Map.get(&1, v, :exposed)) |> MapSet.new()}
    end)
  end

  defp current_weights(state, n) do
    for a <- 0..(n - 1),
        {b, w} <- WeightedMatching.neighbours(state, a),
        a < b,
        into: %{},
        do: {{a, b}, w}
  end

  # The dual solution the state holds is an optimality certificate: every
  # reduced cost non-negative, zero on the matching, every dual
  # non-negative, every exposed vertex at zero. (`possible_mates/2` checks
  # the part of this each vertex's own edges can refute; this checks it
  # all.)
  defp assert_certificate(state, n) do
    for v <- 0..(n - 1) do
      assert Map.fetch!(state.dual, v) >= 0

      if Map.get(state.mate, v) == nil and WeightedMatching.neighbours(state, v) != [],
        do: assert(Map.fetch!(state.dual, v) == 0)
    end

    for {b, _} <- state.children, do: assert(Map.get(state.dual, b, 0) >= 0)

    for v <- 0..(n - 1) do
      assert WeightedMatching.possible_mates(state, v) != :invalid
    end
  end

  defp assert_superset(state, n) do
    truth = optimal_partners(n, current_weights(state, n))

    for v <- 0..(n - 1) do
      {mates, exposable?} = WeightedMatching.possible_mates(state, v)
      claimed = MapSet.new(mates) |> then(&if(exposable?, do: MapSet.put(&1, :exposed), else: &1))

      assert MapSet.subset?(truth[v], claimed),
             "vertex #{v}: optimal partners #{inspect(truth[v])} not within #{inspect(claimed)}"
    end
  end

  describe "WeightedMatching.possible_mates/2" do
    test "names every partner a vertex has in any maximum-weight matching, after solves, re-weightings and finalisations" do
      for seed <- 1..400 do
        :rand.seed(:exsss, {seed, 17, 4711})
        n = Enum.random(3..9)
        # Few distinct weights, so ties, blossoms and several optima are common.
        top = Enum.random([2, 3, 5, 40])

        edges =
          for a <- 0..(n - 1),
              b <- 0..(n - 1),
              a < b,
              :rand.uniform() < 0.6,
              do: {a, b, Enum.random(1..top)}

        state = WeightedMatching.new(n, edges, max_weight: 4 * top, gcd: 1)
        {state, _} = WeightedMatching.solve(state)
        assert_certificate(state, n)
        assert_superset(state, n)

        Enum.reduce(1..6, state, fn _, state ->
          state =
            case Enum.random([:reweigh, :reweigh, :drop, :finalise]) do
              :reweigh ->
                a = Enum.random(0..(n - 1))
                b = Enum.random(Enum.to_list(0..(n - 1)) -- [a])
                w = Enum.random(1..(2 * top))

                {state, _} =
                  state |> WeightedMatching.set_weight(a, b, w) |> WeightedMatching.solve()

                state

              :drop ->
                a = Enum.random(0..(n - 1))
                b = Enum.random(Enum.to_list(0..(n - 1)) -- [a])

                {state, _} =
                  state |> WeightedMatching.set_weight(a, b, 0) |> WeightedMatching.solve()

                state

              :finalise ->
                case Enum.find(state.mate, fn {a, b} -> a < b end) do
                  nil ->
                    state

                  {a, b} ->
                    case WeightedMatching.finalize_pair(state, a, b) do
                      {:ok, state} -> state
                      :error -> state
                    end
                end
            end

          assert_certificate(state, n)
          assert_superset(state, n)
          state
        end)
      end
    end

    test "inside a blossom, only the partners a full blossom allows" do
      # A triangle 0-1-2 with an edge 2-3 out of it: every optimum matches
      # 2-3 and 0-1, and although all three triangle edges are at reduced
      # cost zero once the blossom forms, 0's only partner is 1.
      edges = [{0, 1, 10}, {1, 2, 10}, {0, 2, 10}, {2, 3, 12}]
      state = WeightedMatching.new(4, edges, max_weight: 40, gcd: 1)
      {state, matching} = WeightedMatching.solve(state)
      assert matching[0] == 1 and matching[2] == 3
      assert_superset(state, 4)
    end
  end

  # ------------------------------------------------------- forced searches

  # Every forced search the alternatives run on a round, answered
  # incrementally and in full: the same pairs, or a fallback.
  defp check_round(players, pairs, opts) do
    recording = Pairing.alternatives_recording(players, opts)
    report = Pairing.explain_round(players, pairs, Keyword.put(opts, :bye_passed_over, false))
    bye = Enum.find_value(pairs, fn {w, b} -> if b == nil, do: w end)
    everyone = Enum.map(players, & &1.rank)
    eligibility = Pairing.bye_eligibility(players, opts)

    # What `float_alternatives/3` and `bye_alternatives/3` force, uncapped:
    # each floater's bracket-mates, and each bye candidate C.2 allows.
    floats =
      for bracket <- report,
          floater <- bracket.floats,
          floater != bye,
          y <- bracket.order -- [floater],
          do: for(m <- bracket.order, m != y, do: [y, m])

    byes =
      case bye do
        nil ->
          []

        holder ->
          bracket = Enum.find(report, &(holder in &1.order)) || List.last(report)

          for y <- bracket.order -- [holder],
              is_nil(Map.get(eligibility, y)),
              do: for(m <- everyone, m != y, do: [y, m])
      end

    forcings = Enum.uniq(floats ++ byes)

    Enum.reduce(forcings, {0, 0}, fn forced, {same, fell} ->
      forced_opts = Keyword.update(opts, :forbidden_pairs, forced, &((&1 || []) ++ forced))

      full =
        try do
          {:ok, Pairing.pair_next_round(players, forced_opts)}
        rescue
          e in Pairing.NoValidPairingError -> {:raised, e.message}
        end

      case {full, recording && Pairing.pair_forced(players, forced_opts, forced, recording)} do
        {_, nil} ->
          {same, fell + 1}

        {{:ok, answer}, {:ok, answer, _info}} ->
          {same + 1, fell}

        {_, {:fallback, reason}} ->
          refute match?({:raised, _}, reason), "the replay itself raised: #{inspect(reason)}"
          {same, fell + 1}

        {full, fast} ->
          flunk("forced #{inspect(forced)}: full #{inspect(full)}, incremental #{inspect(fast)}")
      end
    end)
  end

  defp play(seed, rounds, range, check) do
    {rounds, _count, forbidden, roster} = Fuzz.begin!(seed, rounds, range)

    Enum.reduce(1..rounds, {roster, {0, 0}}, fn _round, {players, tally} ->
      opts = [expected_rounds: rounds, forbidden_pairs: forbidden]

      case (try do
              Pairing.pair_next_round(players, opts)
            rescue
              Pairing.NoValidPairingError -> nil
            end) do
        nil ->
          {players, tally}

        pairs ->
          {s, f} = check.(players, pairs, opts)

          {Fuzz.apply_round(players, pairs, Fuzz.simulate_results(pairs)),
           {elem(tally, 0) + s, elem(tally, 1) + f}}
      end
    end)
    |> elem(1)
  end

  test "every forced search, answered from the recording, is the full re-pairing's answer (4-24 players)" do
    {same, fell} =
      Enum.reduce(1..40, {0, 0}, fn seed, {s, f} ->
        {s2, f2} = play(710_000 + seed, 7, 4..24, &check_round/3)
        {s + s2, f + f2}
      end)

    # Most are answered incrementally; the rest fell back - an impossible
    # search, or a read the certificate could not settle - which is allowed
    # and is the full re-pairing by definition.
    assert same > 0
    assert same >= 2 * fell
  end

  test "the public answers are the same with the recording and without" do
    for seed <- 1..12 do
      {rounds, _count, forbidden, roster} = Fuzz.begin!(720_000 + seed, 6, 10..30)

      Enum.reduce(1..rounds, roster, fn _round, players ->
        opts = [expected_rounds: rounds, forbidden_pairs: forbidden]
        pairs = Pairing.pair_next_round(players, opts)
        all = Keyword.put(opts, :max_candidates, :all)

        answers = fn ->
          {Alternatives.float_alternatives(players, pairs, all),
           Alternatives.bye_alternatives(players, pairs, all)}
        end

        assert with_replay("always", answers) == with_replay("never", answers)
        Fuzz.apply_round(players, pairs, Fuzz.simulate_results(pairs))
      end)
    end
  end

  defp with_replay(mode, fun) do
    previous = System.get_env("AINALRAMI_ALT_REPLAY")
    System.put_env("AINALRAMI_ALT_REPLAY", mode)

    try do
      fun.()
    after
      if previous,
        do: System.put_env("AINALRAMI_ALT_REPLAY", previous),
        else: System.delete_env("AINALRAMI_ALT_REPLAY")
    end
  end
end
