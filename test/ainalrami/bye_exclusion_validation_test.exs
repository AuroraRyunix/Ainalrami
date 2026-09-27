defmodule Ainalrami.ByeExclusionValidationTest do
  @moduledoc """
  The organiser's bye exclusions (`:bye_exclusions`, not a FIDE rule)
  against `Ainalrami.Test.ByeExclusionReference`, an exhaustive reference
  that shares no code with the engine.

  Every seed plays a whole small tournament (4-13 players, 3-9 rounds, with
  requested `H`/`Z` byes, withdrawals, forfeits and sometimes forbidden
  pairs), paired by the engine itself - WITH random exclusions, so the
  history carries exclusion-driven byes too. On every round:

    * `bye_exclusions: []` pairs exactly as no option does.
    * On an even field, or with nobody active excluded, the option changes
      nothing.
    * On an odd field with someone active excluded:
        * the engine pairs iff the reference finds a legal round whose bye
          goes to a player [C2] allows and the organiser did not exclude;
        * the round it pairs is legal under the reference's own rules
          (seating, C1, C3, forbidden pairs, and the bye), and its bye
          holder has the lowest score such a round allows ([C5]);
        * when the unexcluded pairing's bye holder is not excluded, the
          excluded round IS the unexcluded round - the exclusion changes
          the bye choice and nothing else;
        * `explain_round/3` names who was passed over: nobody in that case,
          otherwise the unexcluded bye holder first, and only excluded
          players;
        * a refusal carries `reason: :bye_exclusions` exactly when the
          reference pairs the round without the exclusions, names the
          active excluded players, and offers an override whose lifting
          makes the round pairable.

  The ordinary suite runs 150 seeds. `BYE_EXCL_SEEDS=1-5000` runs a range
  (`mix test test/ainalrami/bye_exclusion_validation_test.exs`).
  """

  use ExUnit.Case, async: true

  alias Ainalrami.Pairing
  alias Ainalrami.Pairing.NoValidPairingError
  alias Ainalrami.Test.ByeExclusionReference, as: Ref

  @moduletag timeout: :infinity

  test "bye exclusions agree with the brute-force reference on every round" do
    results =
      seeds()
      |> Task.async_stream(&run_seed/1,
        max_concurrency: 4,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    stats =
      Enum.reduce(results, %{}, fn r, acc -> Map.merge(acc, r.stats, fn _k, a, b -> a + b end) end)

    failures = Enum.flat_map(results, & &1.failures)

    if System.get_env("BYE_EXCL_SEEDS") do
      IO.puts("\nbye exclusions: #{Enum.count(seeds())} seeds, #{inspect(stats)}")
    end

    assert failures == [],
           "#{length(failures)} disagreement(s), first ones:\n" <>
             (failures |> Enum.take(5) |> Enum.map_join("\n", &inspect(&1, limit: :infinity)))

    # The checks must actually have run, in each of their branches.
    assert stats[:excluded_paired] > 0
    assert stats[:excluded_refused] > 0
    assert stats[:passed_over] > 0
    assert stats[:noop] > 0
  end

  defp seeds do
    case System.get_env("BYE_EXCL_SEEDS") do
      nil ->
        1..150

      spec ->
        [first, last] = spec |> String.split("-") |> Enum.map(&String.to_integer/1)
        first..last
    end
  end

  # ------------------------------------------------------------ generation

  defp run_seed(seed) do
    :rand.seed(:exsss, {seed, seed * 7919 + 1, seed * 104_729 + 2})
    n = Enum.random(4..13)
    rounds = Enum.random(3..9)

    forbidden =
      if :rand.uniform(4) == 1 do
        for _ <- 1..Enum.random(1..3), do: Enum.take_random(1..n, 2) |> Enum.sort()
      else
        []
      end
      |> Enum.uniq()

    players =
      for rank <- 1..n do
        %{rank: rank, name: "P#{rank}", fide_rating: 2400 - rank * 10, points: 0.0, games: []}
      end

    state = %{
      seed: seed,
      players: players,
      withdrawn: MapSet.new(),
      failures: [],
      stats: %{}
    }

    Enum.reduce_while(1..rounds, state, fn round, st ->
      play_round(st, round, rounds, forbidden)
    end)
    |> Map.take([:failures, :stats])
  end

  defp play_round(st, round, rounds, forbidden) do
    n = length(st.players)

    withdrawn =
      if round > 1 do
        Enum.reduce(st.players, st.withdrawn, fn p, acc ->
          if MapSet.size(acc) < div(n, 2) and :rand.uniform(100) <= 3,
            do: MapSet.put(acc, p.rank),
            else: acc
        end)
      else
        st.withdrawn
      end

    players =
      Enum.map(st.players, fn p ->
        cond do
          MapSet.member?(withdrawn, p.rank) ->
            record(p, nil, nil, "Z", 0.0)

          :rand.uniform(100) <= 5 ->
            Enum.random([record(p, nil, nil, "H", 0.5), record(p, nil, nil, "Z", 0.0)])

          true ->
            p
        end
      end)

    st = %{st | players: players, withdrawn: withdrawn}
    active = Enum.filter(players, &(length(&1.games) < round))

    if active == [] do
      {:cont, st}
    else
      excluded = draw_exclusions(active, n)

      opts = [expected_rounds: rounds, initial_colour: "w", forbidden_pairs: forbidden]

      ctx = %{
        played: round - 1,
        expected: rounds,
        forbidden: MapSet.new(forbidden, &Enum.sort/1)
      }

      {to_apply, st} = check_round(st, round, active, excluded, opts, ctx)

      case to_apply do
        nil -> {:halt, st}
        pairs -> {:cont, %{st | players: apply_results(st.players, pairs)}}
      end
    end
  end

  # Most rounds exclude a random quarter of the field; some exclude one
  # player, some everyone active, and a rank that is not playing is thrown
  # in now and then to check it is ignored.
  defp draw_exclusions(active, n) do
    ranks = Enum.map(active, & &1.rank)

    chosen =
      case :rand.uniform(20) do
        k when k <= 9 -> Enum.filter(ranks, fn _ -> :rand.uniform(4) == 1 end)
        k when k <= 14 -> [Enum.random(ranks)]
        k when k <= 17 -> ranks
        _ -> []
      end

    if :rand.uniform(10) == 1, do: Enum.uniq([Enum.random(1..n) | chosen]), else: chosen
  end

  defp record(p, opponent, colour, result, worth) do
    %{
      p
      | points: p.points + worth,
        games: p.games ++ [%{opponent_rank: opponent, colour: colour, result: result}]
    }
  end

  defp apply_results(players, pairs) do
    games =
      Enum.reduce(pairs, %{}, fn
        {w, nil}, acc ->
          Map.put(acc, w, {nil, nil, "U", 1.0})

        {w, b}, acc ->
          {rw, rb, pw, pb} =
            if :rand.uniform(100) <= 6 do
              Enum.random([{"+", "-", 1.0, 0.0}, {"-", "+", 0.0, 1.0}])
            else
              Enum.random([{"1", "0", 1.0, 0.0}, {"=", "=", 0.5, 0.5}, {"0", "1", 0.0, 1.0}])
            end

          acc |> Map.put(w, {b, "w", rw, pw}) |> Map.put(b, {w, "b", rb, pb})
      end)

    Enum.map(players, fn p ->
      case Map.fetch(games, p.rank) do
        {:ok, {opp, colour, result, worth}} -> record(p, opp, colour, result, worth)
        :error -> p
      end
    end)
  end

  # ---------------------------------------------------------------- checks

  defp check_round(st, round, active, excluded, opts, ctx) do
    base = safe_pair(st.players, opts)
    with_x = safe_pair(st.players, opts ++ [bye_exclusions: excluded])
    active_ranks = MapSet.new(active, & &1.rank)
    xa = excluded |> Enum.filter(&MapSet.member?(active_ranks, &1)) |> Enum.sort()
    x = MapSet.new(xa)
    tag = %{seed: st.seed, round: round, excluded: excluded}

    st =
      if safe_pair(st.players, opts ++ [bye_exclusions: []]) == base,
        do: st,
        else: fail(st, tag, :empty_option_changed_output)

    st = bump(st, :rounds)

    cond do
      rem(length(active), 2) == 0 or xa == [] ->
        st = bump(st, :noop)
        st = if with_x == base, do: st, else: fail(st, tag, {:option_had_effect, base, with_x})
        {ok_pairs(base), st}

      length(active) > Ref.max_field() ->
        {ok_pairs(with_x) || ok_pairs(base), bump(st, :too_big)}

      true ->
        ref_x = Ref.min_bye_score(active, x, ctx)
        ref_0 = Ref.min_bye_score(active, MapSet.new(), ctx)

        # Positive control on the reference: without exclusions it must
        # agree with the engine on whether the round can be paired at all.
        st =
          if is_nil(ref_0) == match?({:error, _}, base),
            do: st,
            else: fail(st, tag, {:control, ref_0, base})

        check_excluded(st, tag, active, xa, x, opts, ctx, base, with_x, ref_x, ref_0)
    end
  end

  defp check_excluded(st, tag, active, xa, x, opts, ctx, base, with_x, ref_x, ref_0) do
    case with_x do
      {:ok, pairs} ->
        st = bump(st, :excluded_paired)
        st = if is_nil(ref_x), do: fail(st, tag, {:paired_but_reference_refuses, pairs}), else: st

        st =
          case Ref.violations(active, pairs, x, ctx) do
            [] -> st
            v -> fail(st, tag, {:illegal, v, pairs})
          end

        holder = holder(pairs)
        points = Enum.find_value(active, &(&1.rank == holder && &1.points))
        st = if points == ref_x, do: st, else: fail(st, tag, {:c5, holder, points, ref_x})

        h0 = if match?({:ok, _}, base), do: holder(ok_pairs(base))

        st =
          if (h0 && h0 not in xa) and ok_pairs(base) != pairs,
            do: fail(st, tag, {:not_invariant, ok_pairs(base), pairs}),
            else: st

        st = check_explanation(st, tag, pairs, xa, h0, opts)
        {pairs, check_eligibility(st, tag, active, xa, opts)}

      {:error, %NoValidPairingError{} = e} ->
        st = bump(st, :excluded_refused)
        st = if is_nil(ref_x), do: st, else: fail(st, tag, {:refused_but_reference_pairs, ref_x})

        if is_nil(ref_0) do
          st = if e.reason == :no_legal_pairing, do: st, else: fail(st, tag, {:reason, e.reason})
          {nil, st}
        else
          st = bump(st, :override_offered)

          st =
            if e.reason == :bye_exclusions and e.excluded == xa and e.override in xa,
              do: st,
              else: fail(st, tag, {:refusal_fields, e.reason, e.excluded, e.override})

          lifted = List.delete(xa, e.override)

          case safe_pair(st.players, opts ++ [bye_exclusions: lifted]) do
            {:ok, pairs} ->
              case Ref.violations(active, pairs, MapSet.new(lifted), ctx) do
                [] -> {pairs, st}
                v -> {pairs, fail(st, tag, {:override_illegal, v})}
              end

            other ->
              {ok_pairs(base), fail(st, tag, {:override_still_refused, other})}
          end
        end

      other ->
        {nil, fail(st, tag, {:crashed, other})}
    end
  end

  defp check_explanation(st, tag, pairs, xa, h0, opts) do
    report = Pairing.explain_round(st.players, pairs, opts ++ [bye_exclusions: xa])
    passed = report |> Enum.flat_map(&Map.get(&1, :bye_passed_over, [])) |> Enum.map(& &1.rank)
    holder = holder(pairs)

    ok? =
      Enum.all?(passed, &(&1 in xa)) and holder not in passed and
        if(h0 in xa, do: match?([^h0 | _], passed), else: passed == [])

    st = if passed == [], do: st, else: bump(st, :passed_over)
    if ok?, do: st, else: fail(st, tag, {:passed_over, passed, h0, holder})
  end

  defp check_eligibility(st, tag, active, xa, opts) do
    eligibility = Pairing.bye_eligibility(active, Keyword.put(opts, :bye_exclusions, xa))
    plain = Pairing.bye_eligibility(active, opts)

    wrong =
      Enum.reject(active, fn p ->
        expected =
          if p.rank in xa and is_nil(plain[p.rank]), do: :organiser_exclusion, else: plain[p.rank]

        eligibility[p.rank] == expected
      end)

    if wrong == [], do: st, else: fail(st, tag, {:bye_eligibility, Enum.map(wrong, & &1.rank)})
  end

  defp safe_pair(players, opts) do
    {:ok, Pairing.pair_next_round(players, opts)}
  rescue
    e -> {:error, e}
  end

  defp ok_pairs({:ok, pairs}), do: pairs
  defp ok_pairs(_), do: nil

  defp holder(pairs), do: Enum.find_value(pairs, fn {w, b} -> if is_nil(b), do: w end)

  defp fail(st, tag, what), do: %{st | failures: [Map.put(tag, :what, what) | st.failures]}
  defp bump(st, key), do: %{st | stats: Map.update(st.stats, key, 1, &(&1 + 1))}
end
