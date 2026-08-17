defmodule Ainalrami.CompletionRepairTest do
  @moduledoc """
  Fault injection for `repair_completion/3`, the engine's only completion
  safety net.

  It never fires in normal running — measured zero times across plain
  fields, 8% and 15% arbiter-bye rates and 10% forfeits — because
  `bracket_loop/6` stopped ending rounds a group early. That is the right
  outcome and the wrong situation to leave alone: a safety net nothing has
  ever exercised is a guess, and the one time it matters would be the
  first time it runs.

  So `AINALRAMI_FORCE_STRAND=1` restores the old, wrong stop condition on
  purpose. Each round below is paired twice from the same state, once with
  the fault and once without. The fault-injected answer must still be
  legal, and the two must differ often enough to prove the fault is
  actually biting rather than the test passing vacuously.

  Legality is checked independently of any reference engine: every active
  player paired exactly once, no rematch, and the right number of byes
  going to someone C2 allows.
  """

  use ExUnit.Case, async: false

  alias Ainalrami.Pairing

  @rounds 9

  test "a round the cascade strands is still paired legally" do
    {illegal, differed, paired} =
      Enum.reduce(1..40, {[], 0, 0}, fn seed, acc ->
        :rand.seed(:exsss, {seed, seed * 7919, seed * 104_729})

        players =
          for i <- 1..Enum.random(10..24) do
            %{
              rank: i,
              name: "P#{i}",
              fide_rating: Enum.random(1000..2800),
              points: 0.0,
              games: []
            }
          end

        run_tournament(players, seed, acc)
      end)

    assert paired > 0, "no rounds were paired at all"

    assert illegal == [],
           "the completion repair let #{length(illegal)} illegal round(s) through: " <>
             "#{inspect(Enum.take(illegal, 5))}"

    assert differed > 0,
           "AINALRAMI_FORCE_STRAND changed nothing across #{paired} rounds, so this proved " <>
             "nothing. bracket_loop/6's stop condition has probably changed."
  end

  defp run_tournament(players, seed, acc) do
    Enum.reduce(1..@rounds, {players, acc}, fn round, {ps, {illegal, differed, paired}} ->
      active = Ainalrami.Test.Field.active(ps)

      faulted = pair_with(ps, "1")
      clean = pair_with(ps, nil)

      case faulted do
        :refused ->
          {ps, {illegal, differed, paired}}

        pairs ->
          illegal =
            if legal?(pairs, active, ps), do: illegal, else: [{seed, round} | illegal]

          differed =
            differed +
              if clean != :refused and normalise(clean) != normalise(pairs), do: 1, else: 0

          # Advance on the FAULTED answer, so later rounds inherit a
          # history the repair produced rather than a clean one.
          {advance(ps, pairs), {illegal, differed, paired + 1}}
      end
    end)
    |> elem(1)
  end

  defp pair_with(players, flag) do
    if flag,
      do: System.put_env("AINALRAMI_FORCE_STRAND", flag),
      else: System.delete_env("AINALRAMI_FORCE_STRAND")

    try do
      Pairing.pair_next_round(players, expected_rounds: @rounds)
    rescue
      Ainalrami.Pairing.NoValidPairingError -> :refused
    after
      System.delete_env("AINALRAMI_FORCE_STRAND")
    end
  end

  defp normalise(pairs) do
    pairs |> Enum.map(fn {a, b} -> Enum.sort_by([a, b], &(&1 || :infinity)) end) |> Enum.sort()
  end

  defp legal?(pairs, active, players) do
    by_rank = Map.new(players, &{&1.rank, &1})
    seated = Enum.flat_map(pairs, fn {w, b} -> if b, do: [w, b], else: [w] end)
    byes = for {w, nil} <- pairs, do: w

    rematch? =
      Enum.any?(pairs, fn
        {_w, nil} ->
          false

        {w, b} ->
          Enum.any?(
            Map.fetch!(by_rank, w).games,
            &(&1.result in ~w(1 = 0) and &1.opponent_rank == b)
          )
      end)

    bad_bye? =
      Enum.any?(byes, fn w ->
        Enum.any?(Map.fetch!(by_rank, w).games, &(&1.result in ~w(U F + W)))
      end)

    Enum.sort(seated) == Enum.sort(Enum.map(active, & &1.rank)) and
      length(byes) == rem(length(active), 2) and not rematch? and not bad_bye?
  end

  defp advance(players, pairs) do
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
end
