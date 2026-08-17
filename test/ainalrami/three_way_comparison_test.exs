defmodule Ainalrami.ThreeWayComparisonTest do
  @moduledoc """
  Asks all three engines the same question, every round.

  ## Why this exists

  This project has been steering by agreement with bbpPairings, on the
  strength of one earlier measurement: bbpPairings and Gacrux agreed with
  each other on **324 comparable rounds, zero disagreements**. That was
  used to justify treating either as ground truth.

  324 rounds with zero disagreements does not establish that. Zero
  observed failures in n trials bounds the true rate at roughly `3/n` with
  95% confidence — here about **0.9%**. So the references could disagree
  with each other on nearly one round in a hundred and that measurement
  would very likely still have come back clean.

  That mattered little when this engine was at 90% of exact rounds: the
  error being measured was ten times larger than the uncertainty in the
  ruler. It matters now. At 98.7% the remaining disagreement is **1.3%**,
  the same order as the ruler's own slack, and "ainalrami is wrong" and
  "the reference is wrong" stop being distinguishable by a two-way
  comparison at all.

  So this runs all three, at whatever scale is asked for, and reports the
  pairwise rates plus the three-way split. Two things come out of it: a
  tight bound on how far the references actually agree, and — for the
  rounds where this engine differs — whether the other two agree with each
  other (this engine is wrong) or disagree (nobody's ground truth).

  ## Cost

  Gacrux is a Python script, ~750ms per round against bbpPairings' ~21ms,
  so this is roughly 35x the cost of the two-way harness and is excluded
  from the default suite. It parallelises cleanly.

      PAIRING_FUZZ_COUNT=200 PAIRING_FUZZ_ROUNDS=9 mix test --only three_way

  Same tunables as the other harnesses. Tournaments are played forward on
  bbpPairings' answers so all three see an identical history each round.
  """

  use ExUnit.Case
  alias Ainalrami.{Pairing, Test.Bbppairings, Test.Gacrux}

  @moduletag :three_way
  @moduletag timeout: :infinity

  test "bbpPairings, Gacrux and Ainalrami on identical positions" do
    count = env_int("PAIRING_FUZZ_COUNT", 20)
    rounds = env_int("PAIRING_FUZZ_ROUNDS", 5)
    players = env_int("PAIRING_FUZZ_MIN_PLAYERS", 4)..env_int("PAIRING_FUZZ_MAX_PLAYERS", 40)

    rows =
      1..count
      |> Task.async_stream(&run_tournament(&1, rounds, players),
        max_concurrency: System.schedulers_online(),
        timeout: :infinity,
        ordered: false
      )
      |> Enum.flat_map(fn {:ok, r} -> r end)

    report(rows)

    assert rows != [], "no comparable rounds were produced"
  end

  defp run_tournament(seed, rounds, player_range) do
    :rand.seed(:exsss, {seed, seed * 7919, seed * 104_729})
    player_count = Enum.random(player_range)

    roster =
      for i <- 1..player_count do
        %{rank: i, name: "P#{i}", fide_rating: Enum.random(1000..2800), points: 0.0, games: []}
      end
      |> Enum.shuffle()
      |> Enum.with_index(1)
      |> Enum.map(fn {p, i} -> %{p | rank: i} end)

    {rows, _} =
      Enum.reduce_while(1..rounds, {[], roster}, fn round, {acc, ps} ->
        trf = build_trf(ps, rounds)

        with {:ok, bbp} <- Bbppairings.pair(trf),
             {:ok, gac} <- Gacrux.pair(trf) do
          ours = safely_pair(ps, rounds)

          row = %{
            seed: seed,
            round: round,
            bbp_gac: same?(bbp, gac),
            ours_bbp: same?(ours, bbp),
            ours_gac: same?(ours, gac)
          }

          {:cont, {[row | acc], apply_round(ps, bbp)}}
        else
          _ -> {:halt, {acc, ps}}
        end
      end)

    rows
  end

  defp safely_pair(players, rounds) do
    Pairing.pair_next_round(players, expected_rounds: rounds)
  rescue
    _ -> :raised
  end

  defp same?(:raised, _), do: false
  defp same?(_, :raised), do: false
  defp same?(a, b), do: normalize(a) == normalize(b)

  defp normalize(pairs) do
    pairs |> Enum.map(fn {a, b} -> Enum.sort_by([a, b], &(&1 || :infinity)) end) |> Enum.sort()
  end

  defp report(rows) do
    n = length(rows)
    pct = fn k -> "#{Float.round(k * 100 / n, 2)}%" end

    bbp_gac = Enum.count(rows, & &1.bbp_gac)
    ours_bbp = Enum.count(rows, & &1.ours_bbp)
    ours_gac = Enum.count(rows, & &1.ours_gac)

    IO.puts("\nthree-way comparison over #{n} round(s):\n")
    IO.puts("  bbpPairings  vs Gacrux       #{bbp_gac}/#{n}  #{pct.(bbp_gac)}")
    IO.puts("  Ainalrami     vs bbpPairings  #{ours_bbp}/#{n}  #{pct.(ours_bbp)}")
    IO.puts("  Ainalrami     vs Gacrux       #{ours_gac}/#{n}  #{pct.(ours_gac)}")

    # The reason for running three: when this engine differs, is it
    # outvoted or is there simply no majority to be outvoted by?
    ours_differs = Enum.reject(rows, &(&1.ours_bbp and &1.ours_gac))

    outvoted = Enum.count(ours_differs, & &1.bbp_gac)
    no_majority = Enum.count(ours_differs, &(not &1.bbp_gac))

    IO.puts("\n  of the #{length(ours_differs)} round(s) where Ainalrami differs from either:")
    IO.puts("    references agree, so Ainalrami is the odd one out   #{outvoted}")
    IO.puts("    references disagree too, so there is no ground truth #{no_majority}")

    # Rule of three: zero observed failures in n trials bounds the true
    # rate at about 3/n with 95% confidence.
    if bbp_gac == n do
      IO.puts(
        "\n  references never disagreed; that bounds their true disagreement " <>
          "rate at about #{Float.round(300 / n, 2)}% (95%), not at zero"
      )
    end

    IO.puts("")
  end

  defp build_trf(players, total_rounds) do
    Ainalrami.Trf.serialize(%{tournament: %{name: "ThreeWay", type: "swiss"}, players: players}) <>
      "152 W\r\nXXR #{total_rounds}\r\n"
  end

  defp apply_round(players, pairs) do
    games =
      Enum.reduce(pairs, %{}, fn
        {w, nil}, acc ->
          Map.put(acc, w, {%{opponent_rank: nil, colour: nil, result: "U"}, 1.0})

        {w, b}, acc ->
          {rw, rb, pw, pb} =
            case Enum.random([:w, :b, :d]) do
              :w -> {"1", "0", 1.0, 0.0}
              :b -> {"0", "1", 0.0, 1.0}
              :d -> {"=", "=", 0.5, 0.5}
            end

          acc
          |> Map.put(w, {%{opponent_rank: b, colour: "w", result: rw}, pw})
          |> Map.put(b, {%{opponent_rank: w, colour: "b", result: rb}, pb})
      end)

    Enum.map(players, fn p ->
      case Map.fetch(games, p.rank) do
        {:ok, {game, pts}} -> %{p | points: p.points + pts, games: p.games ++ [game]}
        :error -> p
      end
    end)
  end

  defp env_int(name, default) do
    name |> System.get_env(to_string(default)) |> String.to_integer()
  end
end
