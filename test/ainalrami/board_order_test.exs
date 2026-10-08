defmodule Ainalrami.BoardOrderTest do
  @moduledoc """
  The order the pairs come back in is the order of the boards, and C.04.2
  Art. 3.6 says what it is: the higher score of the pair's higher-ranked
  player, then the higher sum of the two scores, then the smaller TPN of
  the higher-ranked player - "higher-ranked" by score, then TPN (C.04.3
  1.2). The pairing-allocated bye goes last.
  """

  use ExUnit.Case, async: true

  alias Ainalrami.Pairing

  defp player(rank, points \\ 0.0, games \\ []),
    do: %{rank: rank, name: "P#{rank}", points: points, games: games}

  # 3.6 restated independently of `board_order/2`, so the test cannot agree
  # with a wrong implementation by sharing it.
  defp fide_key({white, nil}, _points), do: {1, 0, 0, white}

  defp fide_key({a, b}, points) do
    {higher, lower} =
      if points[a] > points[b] or (points[a] == points[b] and a < b), do: {a, b}, else: {b, a}

    {0, -points[higher], -(points[higher] + points[lower]), higher}
  end

  defp in_fide_order?(pairs, players) do
    points = Map.new(players, &{&1.rank, &1.points})
    pairs == Enum.sort_by(pairs, &fide_key(&1, points))
  end

  test "round 1 with an absentee: boards by the higher player's TPN, whatever the ratings" do
    # Seventeen numbered players, number 16 absent. The pairing is 1-9 ..
    # 7-15 and 8-17 - and 8-17 is the LAST board, however highly number 17
    # is rated: 3.6 reads the TPN, not the rating.
    players =
      for rank <- 1..17 do
        games = if rank == 16, do: [%{opponent_rank: nil, colour: nil, result: "Z"}], else: []

        rank
        |> player()
        |> Map.put(:rating, if(rank == 17, do: 2600, else: 2000 - rank))
        |> Map.put(:games, games)
      end

    pairs = Pairing.pair_next_round(players)

    assert Enum.map(pairs, fn {w, b} -> Enum.sort([w, b]) end) ==
             [[1, 9], [2, 10], [3, 11], [4, 12], [5, 13], [6, 14], [7, 15], [8, 17]]
  end

  # The cascade used to hand pairs back in the order it found them, bracket
  # by bracket, which is not 3.6's order once a float or a heterogeneous
  # bracket is involved - about one round in thirteen of these. Fails
  # without `board_order/2`.
  test "random events, every round in 3.6 order" do
    :rand.seed(:exsss, {36, 3, 6})

    for _event <- 1..40 do
      n = Enum.random(9..24)
      players = for rank <- 1..n, do: player(rank)

      Enum.reduce(1..6, players, fn _round, players ->
        pairs = Pairing.pair_next_round(players, expected_rounds: 6)
        assert in_fide_order?(pairs, players), inspect({pairs, players}, limit: :infinity)
        play(players, pairs)
      end)
    end
  end

  defp play(players, pairs) do
    entries =
      Enum.flat_map(pairs, fn
        {w, nil} ->
          [{w, %{opponent_rank: nil, colour: nil, result: "U"}}]

        {w, b} ->
          {rw, rb} = Enum.random([{"1", "0"}, {"=", "="}, {"0", "1"}])

          [
            {w, %{opponent_rank: b, colour: "w", result: rw}},
            {b, %{opponent_rank: w, colour: "b", result: rb}}
          ]
      end)
      |> Map.new()

    Enum.map(players, fn p ->
      game = Map.fetch!(entries, p.rank)

      %{
        p
        | games: p.games ++ [game],
          points: p.points + Ainalrami.Trf.points_for_game(game)
      }
    end)
  end
end
