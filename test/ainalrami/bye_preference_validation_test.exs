defmodule Ainalrami.ByePreferenceValidationTest do
  @moduledoc """
  The bye preferences (`:bye_preferences`, not a FIDE rule) against
  `Ainalrami.Test.ByeExclusionReference`, the exhaustive reference that
  shares no code with the engine.

  Every seed plays a whole small tournament (4-13 players, 3-9 rounds, with
  requested `H`/`Z` byes, withdrawals, forfeits and sometimes forbidden
  pairs), paired by the engine WITH random preferences, so the history
  carries preference-driven byes too. On every round, the test resolves each
  player's settings by the documented precedence itself and checks:

    * `bye_preferences: []` pairs exactly as no option does, and
      `pair_next_round/2` returns `ByePreference.pair/2`'s pairs;
    * the round is legal under the reference's rules with the hard avoids
      as exclusions, or refused exactly when the plain round with those
      exclusions is;
    * on an even field, or with no preference that can act, the pairing is
      the one without preferences;
    * hard wants: a wanted player gets the bye iff the reference finds a
      legal round giving one of them the bye, and then on the lowest score
      such a round allows ([C5] among them);
    * soft wants (no hard want applied): a wanted player gets the bye iff
      the reference finds a legal round giving one of them the bye ON the
      score the plain round's bye holder has;
    * soft avoids (no want applied): the bye goes to someone not avoided
      iff the reference finds a legal round giving it to such a player on
      that score; and the bye score itself never moves under a soft
      setting;
    * `report.moved` is exactly "the pairs differ from the plain round".

  The ordinary suite runs 120 seeds; `BYE_PREF_SEEDS=1-5000` runs a range.
  """

  use ExUnit.Case, async: true

  alias Ainalrami.ByePreference
  alias Ainalrami.Pairing
  alias Ainalrami.Test.ByeExclusionReference, as: Ref

  @moduletag timeout: :infinity

  test "bye preferences agree with the brute-force reference on every round" do
    results =
      seeds()
      |> Task.async_stream(&run_seed/1, max_concurrency: 4, timeout: :infinity, ordered: false)
      |> Enum.map(fn {:ok, result} -> result end)

    stats =
      Enum.reduce(results, %{}, fn r, acc -> Map.merge(acc, r.stats, fn _k, a, b -> a + b end) end)

    failures = Enum.flat_map(results, & &1.failures)

    if System.get_env("BYE_PREF_SEEDS") do
      IO.puts("\nbye preferences: #{Enum.count(seeds())} seeds, #{inspect(stats)}")
    end

    assert failures == [],
           "#{length(failures)} disagreement(s), first ones:\n" <>
             (failures |> Enum.take(5) |> Enum.map_join("\n", &inspect(&1, limit: :infinity)))

    for key <- [
          :hard_granted,
          :hard_unpairable,
          :soft_want_granted,
          :soft_want_outranked,
          :soft_avoid_moved,
          :soft_avoid_outranked,
          :even,
          :refused
        ] do
      assert stats[key] > 0, "branch #{key} never ran"
    end
  end

  defp seeds do
    case System.get_env("BYE_PREF_SEEDS") do
      nil ->
        1..120

      spec ->
        [first, last] = spec |> String.split("-") |> Enum.map(&String.to_integer/1)
        first..last
    end
  end

  # ------------------------------------------------------------ generation

  defp run_seed(seed) do
    :rand.seed(:exsss, {seed, seed * 6271 + 3, seed * 91_121 + 5})
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

    state = %{seed: seed, players: players, withdrawn: MapSet.new(), failures: [], stats: %{}}

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
      prefs = draw_preferences(active, n, round)
      opts = [expected_rounds: rounds, initial_colour: "w", forbidden_pairs: forbidden]
      ctx = %{played: round - 1, expected: rounds, forbidden: MapSet.new(forbidden, &Enum.sort/1)}
      {pairs, st} = check_round(st, round, active, prefs, opts, ctx)

      case pairs do
        nil -> {:halt, st}
        pairs -> {:cont, %{st | players: apply_results(st.players, pairs)}}
      end
    end
  end

  # One to four players with a setting, most for every round, some for
  # chosen rounds (this one included or not), now and then two settings on
  # one player or a rank not playing.
  defp draw_preferences(active, n, round) do
    ranks = Enum.map(active, & &1.rank)
    kinds = ByePreference.preferences()

    base =
      for _ <- 1..Enum.random(1..4) do
        rank = if :rand.uniform(12) == 1, do: Enum.random(1..n), else: Enum.random(ranks)
        kind = Enum.random(kinds)

        case :rand.uniform(6) do
          1 -> {rank, kind, [round]}
          2 -> {rank, kind, [round + 1]}
          _ -> {rank, kind}
        end
      end

    if :rand.uniform(15) == 1, do: [], else: base
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
            if :rand.uniform(100) <= 6,
              do: Enum.random([{"+", "-", 1.0, 0.0}, {"-", "+", 0.0, 1.0}]),
              else:
                Enum.random([{"1", "0", 1.0, 0.0}, {"=", "=", 0.5, 0.5}, {"0", "1", 0.0, 1.0}])

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

  # The documented precedence, restated independently of the module.
  defp effective(prefs, round, active_ranks, c2_ok) do
    by_player =
      prefs
      |> Enum.filter(fn
        {_r, _k} -> true
        {_r, _k, rounds} -> round in rounds
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Enum.reduce(by_player, %{ah: [], wh: [], ws: [], as: []}, fn {rank, kinds}, acc ->
      live? = MapSet.member?(active_ranks, rank)
      eligible? = live? and MapSet.member?(c2_ok, rank)

      cond do
        :avoid_hard in kinds -> Map.update!(acc, :ah, &[rank | &1])
        :want_hard in kinds -> if eligible?, do: Map.update!(acc, :wh, &[rank | &1]), else: acc
        :want_soft in kinds and :avoid_soft in kinds -> acc
        :want_soft in kinds -> if eligible?, do: Map.update!(acc, :ws, &[rank | &1]), else: acc
        :avoid_soft in kinds -> if live?, do: Map.update!(acc, :as, &[rank | &1]), else: acc
      end
    end)
  end

  defp check_round(st, round, active, prefs, opts, ctx) do
    tag = %{seed: st.seed, round: round, prefs: prefs}
    active_ranks = MapSet.new(active, & &1.rank)

    c2_ok =
      for p <- active, Ref.bye_permitted?(p, MapSet.new(), ctx), into: MapSet.new(), do: p.rank

    eff = effective(prefs, round, active_ranks, c2_ok)
    ah = MapSet.new(eff.ah)

    st =
      if safe(fn -> Pairing.pair_next_round(st.players, opts ++ [bye_preferences: []]) end) ==
           safe(fn -> Pairing.pair_next_round(st.players, opts) end),
         do: st,
         else: fail(st, tag, :empty_option_changed_output)

    plain = safe(fn -> Pairing.pair_next_round(st.players, opts ++ [bye_exclusions: eff.ah]) end)
    got = safe(fn -> ByePreference.pair(st.players, opts ++ [bye_preferences: prefs]) end)

    via_option =
      safe(fn -> Pairing.pair_next_round(st.players, opts ++ [bye_preferences: prefs]) end)

    st =
      case {got, via_option} do
        {{:ok, {pairs, _}}, {:ok, pairs}} -> st
        {{:error, _}, {:error, _}} -> st
        other -> fail(st, tag, {:option_differs, other})
      end

    case {plain, got} do
      {{:error, _}, {:error, _}} ->
        {nil, bump(st, :refused)}

      {{:ok, p0}, {:ok, {pairs, report}}} ->
        st =
          if report.moved == (Enum.sort(pairs) != Enum.sort(p0)),
            do: st,
            else: fail(st, tag, :moved_flag)

        st =
          case Ref.violations(active, pairs, ah, ctx) do
            [] -> st
            v -> fail(st, tag, {:illegal, v, pairs})
          end

        {pairs, judge(st, tag, active, eff, ah, ctx, p0, pairs)}

      other ->
        {nil, fail(st, tag, {:refusal_mismatch, other})}
    end
  end

  defp judge(st, tag, active, eff, ah, ctx, p0, pairs) do
    ranks = MapSet.new(active, & &1.rank)
    points = Map.new(active, &{&1.rank, &1.points})
    h = holder(pairs)
    h0 = holder(p0)
    others = fn keep -> ranks |> MapSet.difference(MapSet.new(keep)) |> MapSet.union(ah) end
    small? = length(active) <= Ref.max_field()

    cond do
      rem(length(active), 2) == 0 ->
        st = bump(st, :even)
        if pairs == p0, do: st, else: fail(st, tag, :even_field_moved)

      eff.wh == [] and eff.ws == [] and eff.as == [] ->
        st = bump(st, :inert)
        if pairs == p0, do: st, else: fail(st, tag, :inert_moved)

      not small? ->
        bump(st, :too_big)

      eff.wh != [] and not is_nil(Ref.min_bye_score(active, others.(eff.wh), ctx)) ->
        best = Ref.min_bye_score(active, others.(eff.wh), ctx)
        st = bump(st, :hard_granted)

        if h in eff.wh and points[h] == best,
          do: st,
          else: fail(st, tag, {:hard_not_granted, h, eff.wh, best})

      true ->
        st = if eff.wh != [], do: bump(st, :hard_unpairable), else: st
        soft(st, tag, active, eff, ah, ctx, p0, h, h0, points, others)
    end
  end

  defp soft(st, tag, active, eff, ah, ctx, p0, h, h0, points, others) do
    s0 = points[h0]
    st = if points[h] == s0, do: st, else: fail(st, tag, {:bye_score_moved, h, s0})

    want_at_s0? =
      eff.ws != [] and Ref.min_bye_score(active, others.(eff.ws), ctx) == s0

    cond do
      want_at_s0? ->
        st = bump(st, :soft_want_granted)
        if h in eff.ws, do: st, else: fail(st, tag, {:soft_want_not_granted, h, eff.ws})

      eff.ws != [] and eff.as == [] ->
        st = bump(st, :soft_want_outranked)
        if h == h0 and h not in eff.ws, do: st, else: fail(st, tag, {:soft_want_outranked, h})

      eff.as != [] and h0 in eff.as ->
        avoidable? =
          Ref.min_bye_score(active, MapSet.union(ah, MapSet.new(eff.as)), ctx) == s0

        if avoidable? do
          st = bump(st, :soft_avoid_moved)
          if h in eff.as, do: fail(st, tag, {:soft_avoid_not_honoured, h}), else: st
        else
          st = bump(st, :soft_avoid_outranked)
          if h in eff.as, do: st, else: fail(st, tag, {:soft_avoid_impossible_honoured, h})
        end

      true ->
        st = bump(st, :soft_noop)
        if pairs_equal?(p0, h, h0), do: st, else: fail(st, tag, {:soft_noop_moved, h, h0})
    end
  end

  defp pairs_equal?(_p0, h, h0), do: h == h0

  defp safe(fun) do
    {:ok, fun.()}
  rescue
    e -> {:error, e}
  end

  defp holder(pairs), do: Enum.find_value(pairs, fn {w, b} -> if is_nil(b), do: w end)

  defp fail(st, tag, what), do: %{st | failures: [Map.put(tag, :what, what) | st.failures]}
  defp bump(st, key), do: %{st | stats: Map.update(st.stats, key, 1, &(&1 + 1))}
end
