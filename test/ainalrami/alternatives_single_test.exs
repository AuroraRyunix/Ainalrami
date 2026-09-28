defmodule Ainalrami.AlternativesSingleTest do
  @moduledoc """
  `Alternatives.float_alternative/5` - one floater's question - must be the
  entry `float_alternatives/3` has for that floater, on every round, for
  every floater, at every cap. Rounds are generated: small fields played
  forward on the engine's own pairings with random results, and every
  round along the way asked.
  """

  use ExUnit.Case, async: true

  alias Ainalrami.{Alternatives, Pairing}

  @tournaments 300
  @expected_rounds 7

  defp player(rank) do
    %{
      name: "P#{rank}",
      title: "",
      federation: "",
      sex: "",
      fide_rating: 2400 - rank * 10,
      fide_number: nil,
      birth_date: "",
      points: 0.0,
      rank: rank,
      games: []
    }
  end

  # Random results on the engine's own pairing; the bye holder scores the
  # pairing-allocated bye's point.
  defp play(players, pairs) do
    outcome =
      Enum.reduce(pairs, %{}, fn
        {w, nil}, acc ->
          Map.put(acc, w, {%{result: "U", colour: nil, opponent_rank: nil}, 1.0})

        {w, b}, acc ->
          {rw, rb, pw, pb} =
            Enum.random([{"1", "0", 1.0, 0.0}, {"0", "1", 0.0, 1.0}, {"=", "=", 0.5, 0.5}])

          acc
          |> Map.put(w, {%{result: rw, colour: "w", opponent_rank: b}, pw})
          |> Map.put(b, {%{result: rb, colour: "b", opponent_rank: w}, pb})
      end)

    Enum.map(players, fn p ->
      {game, points} = Map.fetch!(outcome, p.rank)
      %{p | games: p.games ++ [game], points: p.points + points}
    end)
  end

  # The cap varies with the seed: the default, none at all, and one small
  # enough that some questions are skipped - each must match too.
  defp opts(seed) do
    base = [expected_rounds: @expected_rounds]

    case rem(seed, 3) do
      0 -> base
      1 -> Keyword.put(base, :max_candidates, :all)
      2 -> Keyword.put(base, :max_candidates, 3)
    end
  end

  # Every round of one generated tournament, as `{players, pairs}` before
  # its results.
  defp rounds(seed) do
    :rand.seed(:exsss, {seed, 17, 29})
    field = for r <- 1..Enum.random(5..14), do: player(r)

    Enum.reduce_while(1..Enum.random(2..6), {field, []}, fn _, {players, acc} ->
      try do
        pairs = Pairing.pair_next_round(players, expected_rounds: @expected_rounds)
        {:cont, {play(players, pairs), [{players, pairs} | acc]}}
      rescue
        Pairing.NoValidPairingError -> {:halt, {players, acc}}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp bye_holder(pairs), do: Enum.find_value(pairs, fn {w, b} -> if is_nil(b), do: w end)

  test "every floater's single answer is its entry of the all-at-once answer" do
    tally =
      for seed <- 1..@tournaments,
          {players, pairs} <- rounds(seed),
          reduce: %{floats: 0, skipped: 0} do
        tally ->
          opts = opts(seed)
          all = Alternatives.float_alternatives(players, pairs, opts)

          for entry <- all do
            assert Alternatives.float_alternative(
                     players,
                     pairs,
                     entry.group,
                     entry.floater,
                     opts
                   ) ==
                     entry,
                   "seed #{seed}, floater #{entry.floater} of #{entry.group}"
          end

          # Asked about somebody who did not float, or about the bye: nil.
          floaters = MapSet.new(all, & &1.floater)
          group = if all == [], do: 0.0, else: hd(all).group

          for {w, b} <- pairs, rank <- [w, b], rank, not MapSet.member?(floaters, rank) do
            assert Alternatives.float_alternative(players, pairs, group, rank, opts) == nil
          end

          if holder = bye_holder(pairs) do
            refute Enum.any?(all, &(&1.floater == holder))
          end

          %{
            floats: tally.floats + length(all),
            skipped: tally.skipped + Enum.count(all, &Map.has_key?(&1, :skipped))
          }
      end

    # The generator must actually ask: plenty of floaters, some past the cap.
    assert tally.floats > 100, inspect(tally)
    assert tally.skipped > 0, inspect(tally)
  end

  test "a floater asked about the wrong bracket gets nil; 2 and 2.0 are one bracket" do
    opts = [expected_rounds: @expected_rounds, max_candidates: 3]

    {players, pairs, entry} =
      Enum.find_value(1..50, fn seed ->
        Enum.find_value(rounds(seed), fn {players, pairs} ->
          players
          |> Alternatives.float_alternatives(pairs, opts)
          |> Enum.find(&(&1.group == trunc(&1.group)))
          |> case do
            nil -> nil
            entry -> {players, pairs, entry}
          end
        end)
      end)

    assert Alternatives.float_alternative(players, pairs, entry.group + 100, entry.floater, opts) ==
             nil

    assert Alternatives.float_alternative(players, pairs, trunc(entry.group), entry.floater, opts) ==
             entry
  end
end
