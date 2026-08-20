defmodule Ainalrami.C2SecondByeTest do
  @moduledoc """
  C.04.3 art. 2.1.2 [C2]: a player who has already received a
  pairing-allocated bye shall not receive another. Absolute, so a candidate
  that would do it is discarded rather than scored.

  Both fixtures here are positions where bbpPairings 6.0.0 does it anyway
  and Gacrux — a third, independent 2026 implementation — pairs them the way
  this engine does. They are kept as tests, not just as files, because the
  thing they pin is not a preference: if a change ever made this engine
  agree with bbpPairings here, that would be a regression into an illegal
  round, and the corpus would report it as an improvement.
  """
  use ExUnit.Case, async: true

  alias Ainalrami.Pairing

  @doc_dir "test/fixtures/fe1_disputes"

  # Round 9, 10 players, found 11.6 million rounds into the 2026-08-19 run.
  #
  # Rank 4 has met every active player except rank 1, and already holds a
  # pairing-allocated bye (round 4). So C2 leaves exactly one legal shape:
  # rank 4 must be PAIRED, and 1-4 is the only pairing available to them.
  # bbpPairings pairs 1-2 instead, stranding rank 4 into a second bye.
  test "a player whose only remaining opponent is taken cannot be byed instead" do
    %{players: players} = Ainalrami.Trf.parse(File.read!("#{@doc_dir}/seed8848759-r9-p10.trf"))

    pairs = Pairing.pair_next_round(players, expected_rounds: 9)
    by_rank = Map.new(players, &{&1.rank, &1})
    bye = Enum.find_value(pairs, fn {w, b} -> if is_nil(b), do: w end)

    assert {1, 4} in pairs,
           "rank 4's only unplayed active opponent is rank 1, and C2 bars rank 4 " <>
             "from a second pairing-allocated bye, so 1-4 is forced"

    refute had_pairing_bye?(by_rank[bye]),
           "rank #{bye} was given a pairing-allocated bye but already had one"

    assert bye == 3,
           "of the three players C2 leaves eligible (1, 3, 7), C5 puts the bye on " <>
             "the lowest-scoring — rank 3 on 4.0. Gacrux agrees; bbpPairings byes rank 4."
  end

  # The original case, kept for the same reason.
  test "the bye goes to an eligible player even when a lower-scoring one is free" do
    %{players: players} = Ainalrami.Trf.parse(File.read!("#{@doc_dir}/seed735265-r7-p10.trf"))

    pairs = Pairing.pair_next_round(players, expected_rounds: 9)
    by_rank = Map.new(players, &{&1.rank, &1})
    bye = Enum.find_value(pairs, fn {w, b} -> if is_nil(b), do: w end)

    refute had_pairing_bye?(by_rank[bye]),
           "rank #{bye} was given a pairing-allocated bye but already had one"
  end

  # `U`, `F` and `+` are the results that disqualify: a pairing-allocated
  # bye and the two full-point forfeits. Same list the engine enforces on
  # the cascade's final state (`Pairing`'s `@bye_disqualifying_results`).
  defp had_pairing_bye?(player) do
    Enum.any?(player.games, &(&1.result in ~w(U F +)))
  end
end
