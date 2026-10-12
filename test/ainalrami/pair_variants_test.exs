defmodule Ainalrami.PairVariantsTest do
  # Not async: two tests pin the search mode through the environment.
  use ExUnit.Case, async: false

  alias Ainalrami.Pairing
  alias Ainalrami.Test.FuzzTournament, as: Fuzz

  # A position k open games into round `target + 1`, played forward by the
  # engine on the fuzz generator - the shape tools/variants_check.exs
  # measures by the million, here a handful.
  defp position(seed, n, target, k) do
    {rounds, _count, forbidden, roster} = Fuzz.begin!(seed, 9, n..n)

    opts = [
      expected_rounds: rounds,
      forbidden_pairs: forbidden,
      initial_colour: String.downcase(Fuzz.initial_colour()),
      point_system: Fuzz.point_system()
    ]

    {players, pairs} =
      Enum.reduce(1..target, {roster, nil}, fn _round, {players, _} ->
        pairs = Pairing.pair_next_round(players, opts)
        {Fuzz.apply_round(players, pairs, Fuzz.simulate_results(pairs)), pairs}
      end)

    open = pairs |> Enum.filter(fn {_w, b} -> b end) |> Enum.take(k)
    by_rank = Map.new(players, &{&1.rank, &1})

    variants =
      for world <- worlds(k) do
        open
        |> Enum.zip(world)
        |> Enum.flat_map(fn {{w, b}, {wr, br}} ->
          [
            {w, with_result(by_rank[w], target - 1, wr)},
            {b, with_result(by_rank[b], target - 1, br)}
          ]
        end)
        |> Map.new()
      end

    {players, variants, opts}
  end

  defp worlds(0), do: [[]]

  defp worlds(k),
    do: for(o <- [{"1", "0"}, {"=", "="}, {"0", "1"}], rest <- worlds(k - 1), do: [o | rest])

  defp with_result(player, index, result) do
    old = Enum.at(player.games, index)
    points = player.points - Fuzz.result_points(old.result) + Fuzz.result_points(result)

    %{
      player
      | points: points,
        games: List.replace_at(player.games, index, %{old | result: result})
    }
  end

  defp merge(players, variant), do: Enum.map(players, &Map.get(variant, &1.rank, &1))

  defp alone(players, opts) do
    {:ok, Pairing.pair_next_round(players, opts)}
  rescue
    e in Pairing.NoValidPairingError -> {:error, e}
  end

  defp with_mode(mode, fun) do
    System.put_env("AINALRAMI_VARIANT_MODE", mode)

    try do
      fun.()
    after
      System.delete_env("AINALRAMI_VARIANT_MODE")
    end
  end

  test "every variant gets exactly what pairing it on its own gives" do
    for {seed, n, target, k} <- [{11, 12, 2, 2}, {12, 17, 3, 3}, {13, 24, 4, 2}, {14, 9, 3, 2}] do
      {players, variants, opts} = position(seed, n, target, k)
      expected = Enum.map(variants, &alone(merge(players, &1), opts))
      assert Pairing.pair_variants(players, variants, opts) == expected
    end
  end

  test "each search mode gives the same answers" do
    {players, variants, opts} = position(21, 16, 3, 2)
    expected = Enum.map(variants, &alone(merge(players, &1), opts))

    for mode <- ~w(plain force off) do
      assert with_mode(mode, fn -> Pairing.pair_variants(players, variants, opts) end) ==
               expected,
             "mode #{mode}"
    end
  end

  test "an empty variant is the position itself, and no variants is no answers" do
    {players, _variants, opts} = position(31, 10, 2, 1)
    assert Pairing.pair_variants(players, [%{}], opts) == [alone(players, opts)]
    assert Pairing.pair_variants(players, [], opts) == []
  end

  test "a variant that changes the game structure is paired on its own" do
    {players, [first | _] = variants, opts} = position(41, 14, 3, 1)

    # A forfeit against the same opponent keeps the structure - only the
    # replaced players' own colour history and rematches change, which the
    # batch works out again for them. A colour corrected in an earlier
    # round changes the structure (the inferred initial colour reads every
    # colour), so that variant takes the plain path. Both get the plain
    # answer.
    [rank | _] = Map.keys(first)
    player = first[rank]
    forfeit = %{player | games: List.update_at(player.games, 2, &%{&1 | result: "+"})}

    recoloured = %{
      player
      | games:
          List.update_at(
            player.games,
            0,
            &%{&1 | colour: if(&1.colour == "w", do: "b", else: "w")}
          )
    }

    mixed = [Map.put(first, rank, forfeit), Map.put(first, rank, recoloured) | variants]

    assert Pairing.pair_variants(players, mixed, opts) ==
             Enum.map(mixed, &alone(merge(players, &1), opts))
  end

  test "a round that cannot be paired is an error entry, not a raise" do
    # Three players who have all met: no legal round.
    g = fn opp, colour -> %{opponent_rank: opp, colour: colour, result: "="} end

    players = [
      %{rank: 1, points: 1.0, games: [g.(2, "w"), g.(3, "b")]},
      %{rank: 2, points: 1.0, games: [g.(1, "b"), g.(3, "w")]},
      %{rank: 3, points: 1.0, games: [g.(2, "b"), g.(1, "w")]},
      %{
        rank: 4,
        points: 0.0,
        games:
          [%{opponent_rank: nil, colour: nil, result: "Z"}] ++
            [%{opponent_rank: nil, colour: nil, result: "Z"}]
      }
    ]

    expected = alone(players, [])
    assert match?({:error, %Pairing.NoValidPairingError{}}, expected)
    assert Pairing.pair_variants(players, [%{}, %{}], []) == [expected, expected]
  end

  test "bad input is refused as pair_next_round/2 refuses it" do
    {players, _variants, opts} = position(51, 8, 2, 1)

    assert_raise ArgumentError, ~r/variants must be a list/, fn ->
      # Through the process dictionary, so the type checker sees `dynamic`.
      Process.put(:pair_variants_test_input, %{})
      Pairing.pair_variants(players, Process.delete(:pair_variants_test_input), opts)
    end

    assert_raise ArgumentError, ~r/not a player/, fn ->
      Pairing.pair_variants(players, [%{999 => hd(players)}], opts)
    end

    assert_raise ArgumentError, ~r/carries rank/, fn ->
      [a, b | _] = players
      Pairing.pair_variants(players, [%{a.rank => b}], opts)
    end

    assert_raise ArgumentError, fn -> Pairing.pair_variants(players, [], initial_colour: "W") end
  end

  test "nothing of the batch is left in the process" do
    {players, variants, opts} = position(61, 12, 3, 1)
    before = Process.get() |> Keyword.keys() |> MapSet.new()
    Pairing.pair_variants(players, variants, opts)
    left = Process.get() |> Keyword.keys() |> MapSet.new() |> MapSet.difference(before)

    assert Enum.filter(
             left,
             &(is_atom(&1) and String.starts_with?(Atom.to_string(&1), "ainalrami"))
           ) == []
  end
end
