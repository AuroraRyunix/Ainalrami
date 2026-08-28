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
  # deterministic rule to replicate - see Pairing.pair_round_one/1's doc):
  # the better-ranked player of each pair gets White when their ARRIVAL
  # NUMBER is odd, Black when even. In round one every player is being
  # paired, so every player has arrived and the number is the rank - which
  # is why this expectation is unchanged by the SPP's 2026-08-27 ruling.
  # `Ainalrami.InitialColourTest` covers the fields where the two differ.
  test "colour follows the documented odd/even rule, not JaVaFo's own arbitrary draw" do
    pairs = Pairing.pair_round_one(players(8)) |> Enum.sort_by(fn {w, b} -> min(w, b || 0) end)

    assert pairs == [{1, 5}, {6, 2}, {3, 7}, {8, 4}]
  end

  test "the parity is the arrival number's, not the starting rank's" do
    # Two players, starting ranks 12 and 20 - a roster whose ranks are not
    # 1..N, which is what a field reduced by withdrawals looks like.
    #
    # These two ranks are chosen because the readings disagree: rank 12 is
    # even, so the overturned fixed-TPN rule gave 20 White, while 12 is the
    # first player being paired and so is arrival number 1 - odd - and takes
    # the initial colour.
    #
    # The previous version of this test used ranks 11 and 20 and asserted
    # 11-White "because rank 11 is odd". Under the new rule number 1 is odd
    # for the top player of ANY two-player field, so that assertion had
    # become a tautology and could never fail again.
    top = %{rank: 12, name: "A", fide_rating: 2000, points: 0.0, games: []}
    bottom = %{rank: 20, name: "B", fide_rating: 1900, points: 0.0, games: []}

    assert Pairing.pair_round_one([top, bottom]) == [{12, 20}]
  end
end
