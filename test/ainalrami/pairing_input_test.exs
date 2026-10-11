defmodule Ainalrami.PairingInputTest do
  @moduledoc """
  `Ainalrami.PairingInput` and `Ainalrami.Acceleration` on their own: the
  spelling of the organiser's options, what they resolve to for a round,
  byes recorded for the round, a roster re-scored, and C.04.7's table.
  """
  use ExUnit.Case, async: true

  alias Ainalrami.{Acceleration, PairingInput, Trf}

  describe "rounds" do
    test "a round, a range, several" do
      assert PairingInput.parse_rounds("3") == {:ok, [3]}
      assert PairingInput.parse_rounds("3-5") == {:ok, [3, 4, 5]}
      assert PairingInput.parse_rounds("3-4+7") == {:ok, [3, 4, 7]}
      assert PairingInput.parse_rounds("7+3+3") == {:ok, [3, 7]}
    end

    test "anything else is an error, not a guess" do
      for text <- ["", "0", "x", "3-", "-3", "5-3", "3+", "3--5", "3-4-5", "3,4", "1.5"] do
        assert PairingInput.parse_rounds(text) == :error, text
      end
    end

    test "written and read back, for every set of rounds up to 9" do
      for mask <- 1..511 do
        rounds = for r <- 1..9, Bitwise.band(mask, Bitwise.bsl(1, r - 1)) != 0, do: r

        assert rounds |> PairingInput.format_rounds() |> PairingInput.parse_rounds() ==
                 {:ok, rounds}
      end

      assert PairingInput.format_rounds([3, 4, 7]) == "3-4+7"
      assert PairingInput.format_rounds([2]) == "2"
    end
  end

  describe "a player and their rounds" do
    test "with and without rounds" do
      assert PairingInput.parse_ranked("12") == {:ok, 12, :all}
      assert PairingInput.parse_ranked("12@3-4+7") == {:ok, 12, [3, 4, 7]}
      assert PairingInput.format_ranked(12, :all) == "12"
      assert PairingInput.format_ranked(12, [3, 4, 7]) == "12@3-4+7"
    end

    test "errors" do
      for text <- ["", "x", "0", "12@", "@3", "12@x", "12@3@4", "-1", "1 2"] do
        assert PairingInput.parse_ranked(text) == :error, text
      end
    end
  end

  describe "a group" do
    test "by commas or blanks, for every round or a range" do
      assert PairingInput.parse_group("1,4") == {:ok, [1, 4]}
      assert PairingInput.parse_group("2 9 12") == {:ok, [2, 9, 12]}
      assert PairingInput.parse_group("2,9,12@3-5") == {:ok, {[2, 9, 12], 3, 5}}
      assert PairingInput.parse_group("2 9 12 @4") == {:ok, {[2, 9, 12], 4, 4}}
    end

    test "errors: one player, a player twice, a range that is not one" do
      for text <- ["", "4", "1,1", "1,x", "1,2@", "1,2@5-3", "1,2@3+5", "1,2@3@4", "0,2"] do
        assert PairingInput.parse_group(text) == :error, text
      end
    end

    test "written and read back, both separators" do
      for group <- [[1, 4], [2, 9, 12], {[2, 9, 12], 3, 5}, {[7, 8], 4, 4}], sep <- [" ", ","] do
        assert group |> PairingInput.format_group(sep) |> PairingInput.parse_group() ==
                 {:ok, group}
      end
    end
  end

  describe "organiser_opts/2" do
    test "a tournament with none of it gives no option at all" do
      assert PairingInput.organiser_opts(%{}, 3) == []

      assert PairingInput.organiser_opts(
               %{soft_pairs: [], bye_exclusions: [], bye_preferences: []},
               3
             ) == []

      refute PairingInput.organiser?(%{name: "x"})
      # A position without pairs is nothing to pair by.
      assert PairingInput.organiser_opts(%{soft_position: :weak}, 3) == []
    end

    test "soft pairs bring their position, strong unless the file says weak" do
      assert PairingInput.organiser_opts(%{soft_pairs: [[1, 2]]}, 1) ==
               [soft_pairs: [[1, 2]], soft_position: :strong]

      assert PairingInput.organiser_opts(%{soft_pairs: [{[1, 2], 2, 3}], soft_position: :weak}, 1) ==
               [soft_pairs: [{[1, 2], 2, 3}], soft_position: :weak]
    end

    test "bye exclusions are resolved for the round, preferences passed whole" do
      t = %{
        bye_exclusions: [7, {3, [2, 4]}, {5, :all}, {9, [1]}, {3, [4]}],
        bye_preferences: [{2, :want_soft}, {4, :avoid_hard, [3]}]
      }

      assert PairingInput.organiser?(t)
      assert PairingInput.organiser_opts(t, 4)[:bye_exclusions] == [3, 5, 7]
      assert PairingInput.organiser_opts(t, 1)[:bye_exclusions] == [5, 7, 9]
      assert PairingInput.organiser_opts(t, 4)[:bye_preferences] == t.bye_preferences

      assert PairingInput.organiser_opts(%{bye_exclusions: [{3, [2]}]}, 5) == []
    end
  end

  defp player(rank, games, points) do
    %{rank: rank, games: games, points: points}
  end

  defp game(opponent, colour, result),
    do: %{opponent_rank: opponent, colour: colour, result: result}

  describe "request_byes/4" do
    setup do
      {:ok,
       players: [
         player(1, [game(2, "w", "1")], 1.0),
         player(2, [game(1, "b", "0")], 0.0),
         # Entered late: nothing for round 1.
         player(3, [], 0.0),
         # Already told the arbiter: a half-point bye for round 2.
         player(4, [game(nil, nil, "Z"), game(nil, nil, "H")], 0.5)
       ]}
    end

    test "appends the bye and credits it, padding a short line", %{players: players} do
      [p1, p2, p3, p4] = PairingInput.request_byes(players, [{1, "H"}, {3, "F"}])

      assert List.last(p1.games) == game(nil, nil, "H")
      assert p1.points == 1.5
      assert p2 == Enum.at(players, 1)
      assert p3.games == [game(nil, nil, nil), game(nil, nil, "F")]
      assert p3.points == 1.0
      assert p4 == Enum.at(players, 3)

      [z | _] = PairingInput.request_byes(players, [{1, "Z"}])
      assert z.points == 1.0
      assert length(z.games) == 2
    end

    test "under the point system given", %{players: players} do
      system = Map.merge(Trf.default_point_system(), %{draw: 1.0, win: 3.0, half_point_bye: 0.75})
      [p1, _, p3, _] = PairingInput.request_byes(players, [{1, "H"}, {3, "F"}], system)
      assert p1.points == 1.75
      assert p3.points == 3.0
    end

    test "is what a 240 record parses to" do
      {text, _} = Ainalrami.Generator.generate(seed: 21, players: 9, rounds: 3)
      parsed = Trf.parse(text)
      with_240 = Trf.parse(text <> "240 H   4    2    7\r\n")
      assert PairingInput.request_byes(parsed.players, [{2, "H"}, {7, "H"}]) == with_240.players
    end

    test "refuses a rank nobody has, a type that is not a bye, two for one player, a taken round",
         %{players: players} do
      assert_raise ArgumentError, ~r/not a starting rank/, fn ->
        PairingInput.request_byes(players, [{9, "H"}])
      end

      assert_raise ArgumentError, ~r/"H", "Z" or "F"/, fn ->
        PairingInput.request_byes(players, [{1, "U"}])
      end

      assert_raise ArgumentError, ~r/two byes for starting rank 1/, fn ->
        PairingInput.request_byes(players, [{1, "H"}, {1, "Z"}])
      end

      assert_raise ArgumentError, ~r/starting rank 4 already has an entry for round 2/, fn ->
        PairingInput.request_byes(players, [{4, "Z"}])
      end
    end
  end

  describe "rescore/3" do
    test "totals that are the games' become the games' under the new system" do
      players = [
        player(1, [game(2, "w", "1"), game(3, "b", "="), game(nil, nil, "U")], 2.5),
        player(2, [game(1, "b", "0"), game(nil, nil, "H"), game(3, "w", "-")], 0.5)
      ]

      system =
        Map.merge(Trf.default_point_system(), %{win: 3.0, draw: 1.0, pairing_allocated_bye: 3.0})

      assert [%{points: 7.0}, %{points: 1.0}] = PairingInput.rescore(players, nil, system)
    end

    test "a total with something the games do not explain keeps the difference" do
      players = [player(1, [game(2, "w", "1")], 1.5)]
      system = Map.put(Trf.default_point_system(), :win, 3.0)
      assert [%{points: 3.5}] = PairingInput.rescore(players, nil, system)
    end

    test "to the same system is no change" do
      {text, _} =
        Ainalrami.Generator.generate(
          seed: 5,
          players: 14,
          rounds: 5,
          forfeit_pct: 10,
          requested_bye_pct: 10
        )

      players = Trf.parse(text).players
      system = Trf.default_point_system()
      assert PairingInput.rescore(players, system, system) == players
    end
  end

  describe "Acceleration" do
    test "Group A is the top half rounded up to an even number" do
      for {n, a} <- [
            {0, 0},
            {1, 1},
            {2, 2},
            {3, 2},
            {4, 2},
            {5, 4},
            {8, 4},
            {9, 6},
            {10, 6},
            {12, 6},
            {13, 8},
            {100, 50},
            {101, 52}
          ] do
        assert Acceleration.baku_group_size(n) == a, "#{n} players"
      end
    end

    test "FIDE's own example: nine rounds, five accelerated, 1 1 1 half half" do
      assert Acceleration.baku_points(9, 9) == [1.0, 1.0, 1.0, 0.5, 0.5, 0.0, 0.0, 0.0, 0.0]
      assert Acceleration.baku_points(9, 4) == [1.0, 1.0, 1.0, 0.5]
      assert Acceleration.baku_points(7, 7) == [1.0, 1.0, 0.5, 0.5, 0.0, 0.0, 0.0]
      assert Acceleration.baku_points(1, 1) == [1.0]
      assert Acceleration.baku_points(4, 6) == [1.0, 0.5, 0.0, 0.0, 0.0, 0.0]
    end

    test "baku/3 gives Group A the points and nobody else the key" do
      players = for rank <- 1..10, do: player(rank, [], 0.0)
      result = Acceleration.baku(players, 9)
      assert for(p <- result, Map.has_key?(p, :accelerations), do: p.rank) == Enum.to_list(1..6)
      assert hd(result).accelerations == Acceleration.baku_points(9, 9)

      # A field that grew: the line stays where round 1 drew it.
      grown = Acceleration.baku(players, 9, group_a_last: 4)
      assert for(p <- grown, Map.has_key?(p, :accelerations), do: p.rank) == [1, 2, 3, 4]

      assert Acceleration.baku(players, 9, through: 2) |> hd() |> Map.fetch!(:accelerations) == [
               1.0,
               1.0
             ]
    end

    test "virtual_points/2 puts the table on the players it names" do
      players = for rank <- 1..4, do: player(rank, [], 0.0)
      result = Acceleration.virtual_points(players, %{2 => [1, 0.5], 4 => [0.5]})
      assert Enum.map(result, &Map.get(&1, :accelerations)) == [nil, [1.0, 0.5], nil, [0.5]]
      assert Acceleration.accelerated?(result)
      refute Acceleration.accelerated?(players)
    end

    test "refuses a second acceleration, an unknown rank and a negative value" do
      players = for rank <- 1..4, do: player(rank, [], 0.0)
      accelerated = Acceleration.baku(players, 5)

      assert_raise ArgumentError, ~r/already carry virtual points/, fn ->
        Acceleration.baku(accelerated, 5)
      end

      assert_raise ArgumentError, ~r/already carry virtual points/, fn ->
        Acceleration.virtual_points(accelerated, %{1 => [1.0]})
      end

      assert_raise ArgumentError, ~r/not a starting rank/, fn ->
        Acceleration.virtual_points(players, %{9 => [1.0]})
      end

      assert_raise ArgumentError, ~r/non-negative numbers/, fn ->
        Acceleration.virtual_points(players, %{1 => [-1.0]})
      end
    end
  end
end
