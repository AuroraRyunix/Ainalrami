defmodule Ainalrami.C2SecondByeTest do
  @moduledoc """
  C.04.3 art. 2.1.2 [C2]: a player who has already received a
  pairing-allocated bye shall not receive another. Absolute, so a candidate
  that would do it is discarded rather than scored.

  Both fixtures here are positions where bbpPairings 6.0.0 does it anyway
  and Gacrux - a third, independent 2026 implementation - pairs them the way
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
             "the lowest-scoring - rank 3 on 4.0. Gacrux agrees; bbpPairings byes rank 4."
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

  # Round 8, 9 players, from the random-acceleration axis. The strongest of
  # the three: the round has exactly ONE legal shape, reachable by pure
  # elimination, and C5 never gets a say.
  #
  # Ranks 3 and 5 sit the round out on arbiter byes, leaving seven active.
  # Ranks 1, 2, 8 and 9 already hold a pairing-allocated bye, so [C2] says
  # each of them must be PAIRED. Then, one forced step at a time:
  #
  #   rank 8 holds a bye and has one opponent left (4)  -> 4-8
  #   rank 2 holds a bye and now has one left      (1)  -> 2-1
  #   rank 9 holds a bye and now has one left      (7)  -> 9-7
  #   rank 6 is all that remains, and is eligible       -> bye
  #
  # bbpPairings pairs 4-2 instead, which takes rank 8's only opponent and
  # leaves it nowhere to go but a second bye.
  test "a forced chain of C2-ineligible players fixes the whole round" do
    %{players: players} = Ainalrami.Trf.parse(File.read!("#{@doc_dir}/seed7073463-r8-p9.trf"))

    pairs = Pairing.pair_next_round(players, expected_rounds: 9)
    by_rank = Map.new(players, &{&1.rank, &1})
    bye = Enum.find_value(pairs, fn {w, b} -> if is_nil(b), do: w end)
    played = Enum.map(pairs, fn {w, b} -> Enum.sort([w, b]) end) |> MapSet.new()

    for pair <- [[4, 8], [1, 2], [7, 9]] do
      assert pair in played,
             "#{inspect(pair)} is forced by elimination once C2 rules out the bye for " <>
               "ranks 1, 2, 8 and 9 - got #{inspect(MapSet.to_list(played))}"
    end

    assert bye == 6, "rank 6 is the only player left, and the only one still bye-eligible"

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
