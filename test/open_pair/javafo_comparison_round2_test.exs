defmodule OpenPair.JavafoComparisonRound2Test do
  @moduledoc """
  Same methodology as `javafo_comparison_test.exs`, one round further: pair
  round 1 with real `javafo.jar`, simulate random results for it, then ask
  BOTH `javafo.jar` and `OpenPair.Pairing.pair_next_round/1` to pair round 2
  from that identical, real history — diffing composition (colour-blind),
  never feeding either engine's own round-2 opinion back into anything.

      PAIRING_FUZZ_COUNT=100000 mix test --only javafo test/open_pair/javafo_comparison_round2_test.exs
  """

  use ExUnit.Case
  alias OpenPair.{Pairing, Test.Javafo}

  @moduletag :javafo
  @moduletag timeout: :infinity

  test "OpenPair and javafo.jar agree on who plays whom in round 2, across many random round-1 outcomes" do
    count = System.get_env("PAIRING_FUZZ_COUNT", "20") |> String.to_integer()

    results =
      1..count
      |> Task.async_stream(&run_one/1,
        max_concurrency: System.schedulers_online(),
        timeout: :infinity,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    disagreements = Enum.reject(results, &(&1.match? == true))
    match_count = count - length(disagreements)

    IO.puts(
      "\nJaVaFo round-2 comparison: #{match_count}/#{count} matched " <>
        "(#{Float.round(match_count / count * 100, 2)}%)"
    )

    assert disagreements == [], """
    #{length(disagreements)} disagreement(s) out of #{count} random round-1 outcome(s) — a \
    legal-but-different pairing, or a genuine gap in OpenPair's bracket cascade (see
    Pairing.pair_later_round/1's documented simplifications) — not necessarily a bug in
    the sense JaVaFo is "right" and OpenPair is "wrong". Each needs its own look:

    #{Enum.map_join(Enum.take(disagreements, 20), "\n\n", &format_disagreement/1)}
    #{if length(disagreements) > 20, do: "\n... and #{length(disagreements) - 20} more, truncated.", else: ""}
    """
  end

  defp run_one(seed) do
    run_one!(seed)
  rescue
    e -> %{seed: seed, match?: false, openpair: nil, javafo: {:raised, e}}
  end

  defp run_one!(seed) do
    :rand.seed(:exsss, {seed, seed * 7919, seed * 104_729})
    player_count = Enum.random(4..40)

    players_r0 =
      for i <- 1..player_count do
        %{rank: i, name: "P#{i}", fide_rating: Enum.random(1000..2800), points: 0.0, games: []}
      end
      |> Enum.shuffle()
      |> Enum.with_index(1)
      |> Enum.map(fn {p, i} -> %{p | rank: i} end)

    with {:ok, round1_pairs} <- Javafo.pair(build_trf(players_r0)),
         players_r1 = apply_round(players_r0, round1_pairs, simulate_results(round1_pairs)),
         {:ok, javafo_r2} <- Javafo.pair(build_trf(players_r1)) do
      openpair_r2 = Pairing.pair_next_round(players_r1)

      %{
        seed: seed,
        player_count: player_count,
        match?: normalize(openpair_r2) == normalize(javafo_r2),
        openpair: Enum.sort(openpair_r2),
        javafo: Enum.sort(javafo_r2),
        round1: Enum.sort(round1_pairs)
      }
    else
      {:error, {code, out}} ->
        %{
          seed: seed,
          player_count: player_count,
          match?: false,
          openpair: nil,
          javafo: {:error, code, out}
        }
    end
  end

  defp build_trf(players) do
    OpenPair.Trf.serialize(%{tournament: %{name: "Fuzz", type: "swiss"}, players: players}) <>
      "XXR 2\r\n"
  end

  # White win, black win, or draw for a real pairing; a bye (nil opponent)
  # always scores the standard pairing-allocated-bye full point.
  defp simulate_results(pairs) do
    Map.new(pairs, fn
      {white, nil} -> {{white, nil}, :bye}
      {white, black} -> {{white, black}, Enum.random([:white_win, :black_win, :draw])}
    end)
  end

  defp apply_round(players, pairs, results) do
    games_by_rank = games_by_rank(pairs, results)

    Enum.map(players, fn p ->
      game = Map.fetch!(games_by_rank, p.rank)
      %{p | points: p.points + game.points, games: p.games ++ [Map.delete(game, :points)]}
    end)
  end

  defp games_by_rank(pairs, results) do
    Enum.reduce(pairs, %{}, fn {white, black} = pair, acc ->
      outcome = Map.fetch!(results, pair)
      {white_game, black_game} = games_for(white, black, outcome)

      acc = Map.put(acc, white, white_game)
      if black, do: Map.put(acc, black, black_game), else: acc
    end)
  end

  defp games_for(_white, nil, :bye) do
    {%{opponent_rank: nil, colour: nil, result: "U", points: 1.0}, nil}
  end

  defp games_for(white, black, :white_win) do
    {
      %{opponent_rank: black, colour: "w", result: "1", points: 1.0},
      %{opponent_rank: white, colour: "b", result: "0", points: 0.0}
    }
  end

  defp games_for(white, black, :black_win) do
    {
      %{opponent_rank: black, colour: "w", result: "0", points: 0.0},
      %{opponent_rank: white, colour: "b", result: "1", points: 1.0}
    }
  end

  defp games_for(white, black, :draw) do
    {
      %{opponent_rank: black, colour: "w", result: "=", points: 0.5},
      %{opponent_rank: white, colour: "b", result: "=", points: 0.5}
    }
  end

  defp normalize(pairs) do
    pairs
    |> Enum.map(fn {a, b} -> Enum.sort_by([a, b], &(&1 || :infinity)) end)
    |> Enum.sort()
  end

  defp format_disagreement(d) do
    """
    seed #{d.seed}, #{d.player_count} players:
      round 1: #{inspect(Map.get(d, :round1))}
      OpenPair round 2: #{inspect(d.openpair)}
      javafo round 2:   #{inspect(d.javafo)}
    """
  end
end
