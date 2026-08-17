defmodule OpenPair.TiebreakOrderTest do
  @moduledoc """
  Does the engine's final tie-break agree with Article 4?

  3.8.1 breaks a tie below every criterion by which candidate was **generated
  earlier** in the sequence of 3.6/3.7 — transpositions of S2 first, then
  exchanges between S1 and S2. `OpenPair.Pairing` never walks that sequence;
  it solves a matching and breaks the tie with `transposition_key/3`.

  Whether those two orders agree has been carried as an open question and an
  assumed approximation. This decides it, for the transposition half, by
  generating candidates in Article 4.2 order with `OpenPair.Sequence` — a
  module that knows nothing about the engine — and checking the engine's key
  increases along it.
  """

  use ExUnit.Case, async: true

  alias OpenPair.{Pairing, Sequence}

  describe "4.2 transpositions vs transposition_key/3" do
    test "the key increases strictly along Article 4.2's order (homogeneous)" do
      # Eight players on one score. S1 = first four by Article 1.2, S2 = the
      # rest, so N1 = 4 and every transposition of S2 is significant.
      bracket = for rank <- 1..8, do: player(rank, 2.0)
      group = bracket

      keys =
        for ordering <- Sequence.transpositions(Enum.to_list(5..8), 4) do
          partner = partner_map(Enum.to_list(1..4), ordering)
          Pairing.transposition_key(bracket, group, partner)
        end

      assert length(keys) == 24, "4! orderings of a four-member S2"

      assert keys == Enum.sort(keys),
             "the engine's key must rank candidates in the order Article 4.2 generates them"

      assert keys == Enum.uniq(keys), "distinct transpositions must get distinct keys"

      # And the identity — S1[i] vs S2[i], the candidate 3.3.1 builds first —
      # must come first under the key, since it is the one the regulations try
      # before any alteration at all.
      assert hd(keys) == [0, 1, 2, 3]
    end

    test "the same holds for an odd bracket, where one player is left unpaired" do
      bracket = for rank <- 1..7, do: player(rank, 1.5)
      group = bracket

      # MaxPairs = 3, so S1 is the first three and S2 the remaining four; the
      # unpaired S2 member downfloats and is ignored for ordering (4.2.2's
      # note), which is exactly what `transpositions/2`'s prefix does.
      keys =
        for ordering <- Sequence.transpositions(Enum.to_list(4..7), 3) do
          partner = partner_map(Enum.to_list(1..3), Enum.take(ordering, 3))
          Pairing.transposition_key(bracket, group, partner)
        end

      assert keys == Enum.sort(keys)
      assert keys == Enum.uniq(keys)
    end

    test "a heterogeneous bracket orders on its MDPs, per 3.2.2" do
      # Two MDPs at a higher score plus five residents. 3.2.2 puts the MDPs in
      # S1 and the residents in S2, so the key ranks MDP-Pairings — which is
      # what 3.7.2 alters once the remainder is exhausted.
      bracket =
        for(rank <- 1..2, do: player(rank, 3.0)) ++ for rank <- 3..7, do: player(rank, 2.0)

      group = Enum.filter(bracket, &(&1.points == 2.0))

      keys =
        for ordering <- Sequence.transpositions(Enum.to_list(3..7), 2) do
          partner = partner_map([1, 2], Enum.take(ordering, 2))
          Pairing.transposition_key(bracket, group, partner)
        end

      assert length(keys) == 20, "5 * 4 significant orderings for two MDPs"
      assert keys == Enum.sort(keys)
      assert keys == Enum.uniq(keys)
    end
  end

  describe "what the key does not order" do
    test "an exchange reaches a candidate no transposition can" do
      # 4.3: once transpositions are exhausted, players are swapped BETWEEN S1
      # and S2. The engine considers those candidates — its matcher searches
      # every matching — but has no generation-order ranking for them, which
      # is the whole of the remaining divergence from 3.8.1.
      #
      # Pinned so the boundary of the claim above is explicit rather than
      # implied: with S1 = 1..4 fixed, no transposition can pair 1 with 2.
      transposed =
        for ordering <- Sequence.transpositions(Enum.to_list(5..8), 4) do
          partner_map(Enum.to_list(1..4), ordering)
        end

      refute Enum.any?(transposed, &(Map.get(&1, 1) == 2)),
             "no transposition of S2 can pair two S1 members with each other"

      # An exchange can: swap 4 out of S1 for 5, and 1 may then face 2 in the
      # re-sorted subgroups.
      exchanges = Sequence.exchanges([1, 2, 3, 4], [5, 6, 7, 8])
      assert {[1, 2, 3, 5], [4, 6, 7, 8]} in exchanges
    end
  end

  defp partner_map(s1, s2_ordering) do
    s1
    |> Enum.zip(s2_ordering)
    |> Enum.flat_map(fn {a, b} -> [{a, b}, {b, a}] end)
    |> Map.new()
  end

  defp player(rank, points) do
    %{
      name: "P#{rank}",
      title: "",
      federation: "",
      sex: "",
      fide_rating: 2000 - rank,
      fide_number: nil,
      birth_date: "",
      points: points,
      rank: rank,
      games: []
    }
  end
end
