defmodule Ainalrami.PairingTest do
  use ExUnit.Case, async: true

  alias Ainalrami.Pairing

  defp players(n) do
    for i <- 1..n, do: %{rank: i, name: "P#{i}", fide_rating: 2500 - i, points: 0.0, games: []}
  end

  # Colour-blind: {white, black} and {black, white} both mean "these two
  # play each other" for the composition assertions below.
  defp as_pair_sets(pairs) do
    pairs
    |> Enum.map(fn {a, b} -> Enum.sort([a, b]) end)
    |> Enum.sort()
  end

  test "even field: pairs the top half against the bottom half, index for index" do
    pairs = Pairing.pair_round_one(players(8))

    assert as_pair_sets(pairs) == [[1, 5], [2, 6], [3, 7], [4, 8]]
  end

  test "odd field: the lowest-ranked player gets the pairing-allocated bye, the rest pair normally" do
    pairs = Pairing.pair_round_one(players(9))

    {bye_pairs, real_pairs} = Enum.split_with(pairs, fn {_w, b} -> is_nil(b) end)

    assert bye_pairs == [{9, nil}]
    assert as_pair_sets(real_pairs) == [[1, 5], [2, 6], [3, 7], [4, 8]]
  end

  test "a single-player field is entirely a bye" do
    assert Pairing.pair_round_one(players(1)) == [{1, nil}]
  end

  test "a two-player field pairs them against each other" do
    assert as_pair_sets(Pairing.pair_round_one(players(2))) == [[1, 2]]
  end

  # Our own documented colour convention (Article 5.2.5 applied with a
  # fixed initial-colour, since Article 5.1's "drawing of lots" has no
  # deterministic rule to replicate — see Pairing.pair_round_one/1's doc):
  # the better-ranked player of each pair gets white when their rank is
  # odd, black when even.
  test "colour follows the documented odd/even-rank rule, not JaVaFo's own arbitrary draw" do
    pairs = Pairing.pair_round_one(players(8)) |> Enum.sort_by(fn {w, b} -> min(w, b || 0) end)

    assert pairs == [{1, 5}, {6, 2}, {3, 7}, {8, 4}]
  end

  test "colour rule is independent of which half the odd-ranked player is in" do
    # Rank 6 (even) is the better-ranked half of pair {2,6}? No — 2 is
    # better-ranked (lower number) than 6, so rank 2 (even) decides colour
    # for this pair, same case as above. This test instead confirms the
    # rule reads the BETTER-ranked player's parity, not literally "s1 vs
    # s2" position, by checking a field where ranks aren't all low numbers.
    top = %{rank: 11, name: "A", fide_rating: 2000, points: 0.0, games: []}
    bottom = %{rank: 20, name: "B", fide_rating: 1900, points: 0.0, games: []}

    # rank 11 is odd -> gets white (the initial colour).
    assert Pairing.pair_round_one([top, bottom]) == [{11, 20}]
  end
end
