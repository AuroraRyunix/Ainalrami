defmodule Ainalrami.Trf26Test do
  @moduledoc """
  TRF26 - FIDE's Tournament Report File Format Version 2026 - as the
  `:trf26` dialect writes it and `parse/1` reads it. The property that
  matters most is the last one: both spellings of one tournament pair the
  same round.
  """

  use ExUnit.Case, async: true

  alias Ainalrami.{Pairing, Trf}
  alias Ainalrami.Trf.ValidationError

  defp player(rank, points, games, extra \\ []) do
    Map.merge(
      %{
        name: "Player #{rank}",
        title: "",
        federation: "BEL",
        sex: "m",
        fide_rating: 2300 - rank * 20,
        fide_number: 100_000 + rank,
        birth_date: "",
        points: points,
        rank: rank,
        games: games
      },
      Map.new(extra)
    )
  end

  defp game(opponent, colour, result),
    do: %{opponent_rank: opponent, colour: colour, result: result}

  defp bye(code), do: %{opponent_rank: nil, colour: nil, result: code}

  # Six players after two rounds under 3-1-0 scoring with an ordinary
  # one-point bye; the top three accelerated for three rounds, 1 and 4 kept
  # apart, and two byes granted for round three - a half-point one for 5
  # and a zero-point one for 6, credited up front as the engines' files
  # credit them (5 holds 3.0 from the board and 1.0 for the bye).
  defp tournament do
    %{
      tournament: %{
        name: "Trf26 Open",
        city: "Bruges",
        federation: "BEL",
        number_of_rounds: 7,
        initial_colour: "w",
        point_system: %{
          win: 3.0,
          draw: 1.0,
          loss: 0.0,
          pairing_allocated_bye: 1.0,
          forfeit_loss: 0.0,
          zero_point_bye: 0.0
        },
        forbidden_pairs: [[1, 4]],
        type_code: "FIDE_DUTCH_2026_BAKU",
        tie_breaks: ["BH", "SB"],
        time_control_code: "5400+30"
      },
      players: [
        player(1, 6.0, [game(4, "w", "1"), game(2, "b", "1")], accelerations: [1.0, 1.0, 0.5]),
        player(2, 3.0, [game(5, "b", "1"), game(1, "w", "0")], accelerations: [1.0, 1.0, 0.5]),
        player(3, 4.0, [game(6, "w", "1"), game(4, "b", "=")], accelerations: [1.0, 1.0, 0.5]),
        player(4, 1.0, [game(1, "b", "0"), game(3, "w", "=")]),
        player(5, 4.0, [game(2, "w", "0"), game(6, "b", "1"), bye("H")]),
        player(6, 0.0, [game(3, "b", "0"), game(5, "w", "0"), bye("Z")])
      ]
    }
  end

  # A line by BYTE column, the way a foreign writer builds one.
  defp row(pairs) do
    Enum.reduce(pairs, "", fn {col, text}, acc ->
      acc <> String.duplicate(" ", max(col - 1 - byte_size(acc), 0)) <> text
    end) <> "\r\n"
  end

  defp lines(text), do: String.split(text, "\r\n", trim: true)

  defp line_for(text, rank),
    do:
      Enum.find(lines(text), &String.starts_with?(&1, "001 " <> String.pad_leading("#{rank}", 4)))

  defp colour_blind(pairs), do: pairs |> Enum.map(&Enum.sort(Tuple.to_list(&1))) |> Enum.sort()

  describe "the :trf26 dialect" do
    test "writes FIDE's spelling of every line and none of the engines'" do
      text = Trf.serialize(tournament(), dialect: :trf26)
      all = lines(text)

      assert "142 7" in all
      assert "152 W" in all
      assert "162  W 3.0    D 1.0    L 0.0    A 0.0    P 1.0" in all
      assert "192 FIDE_DUTCH_2026_BAKU" in all
      assert "202 BH,SB" in all
      assert "222 5400+30" in all

      # Baku on the top three: two ranges, not nine lines.
      assert "250       1.0   1   2    1    3" in all
      assert "250       0.5   3   3    1    3" in all
      assert Enum.count(all, &String.starts_with?(&1, "250")) == 2

      # "Never" is rounds 1 to 7 in a file that has a round count.
      assert "260   1   7    1    4" in all

      # The round-three byes are records, not columns.
      assert "240 H 003    5" in all
      assert "240 Z 003    6" in all
      refute line_for(text, 5) =~ "0000 - H"
      refute line_for(text, 6) =~ "0000 - Z"
      # ...and the total is the standings total, without the bye not yet reached.
      assert line_for(text, 5) =~ ~r/ 3\.0 {4}5 /

      for spelling <- ~w(XXR XXP XXA BBW BBD BBU) do
        refute Enum.any?(all, &String.starts_with?(&1, spelling)), "#{spelling} in a TRF26 file"
      end
    end

    test "the engine dialect is untouched, and still the default" do
      plain = Trf.serialize(tournament())
      assert plain == Trf.serialize(tournament(), dialect: :engine)

      all = lines(plain)
      assert "XXP 1 4" in all
      assert "BBW  3.0" in all
      assert line_for(plain, 5) =~ "0000 - H"
      refute Enum.any?(all, &String.starts_with?(&1, "240"))
      refute Enum.any?(all, &String.starts_with?(&1, "162"))
    end

    test "an unknown dialect is refused by name" do
      assert_raise ArgumentError, ~r/unknown TRF dialect :trf27/, fn ->
        Trf.serialize(tournament(), dialect: :trf27)
      end
    end

    test "reads back to the players the engine dialect gives, byes and points included" do
      from_engine = tournament() |> Trf.serialize() |> Trf.parse()
      from_trf26 = tournament() |> Trf.serialize(dialect: :trf26) |> Trf.parse()

      shape = fn parsed ->
        Enum.map(parsed.players, &{&1.rank, &1.points, &1.games, &1[:accelerations]})
      end

      assert shape.(from_trf26) == shape.(from_engine)
      assert from_trf26.tournament[:point_system] == from_engine.tournament[:point_system]
      assert from_trf26.tournament[:number_of_rounds] == 7
      assert from_trf26.tournament[:initial_colour] == "w"

      # What only the TRF26 file says.
      assert from_trf26.tournament[:type_code] == "FIDE_DUTCH_2026_BAKU"
      assert from_trf26.tournament[:tie_breaks] == ["BH", "SB"]
      assert from_trf26.tournament[:time_control_code] == "5400+30"

      assert from_trf26.tournament[:byes] == [
               %{type: "H", round: 3, ranks: [5]},
               %{type: "Z", round: 3, ranks: [6]}
             ]

      # A range-limited group where the engine file has a plain one: the
      # same ban for every round of this tournament.
      assert from_trf26.tournament[:forbidden_pairs] == [{[1, 4], 1, 7}]
      assert from_engine.tournament[:forbidden_pairs] == [[1, 4]]
    end

    test "pairs the same round from either spelling" do
      pair = fn parsed ->
        Pairing.pair_next_round(parsed.players,
          expected_rounds: parsed.tournament[:number_of_rounds],
          forbidden_pairs: parsed.tournament[:forbidden_pairs],
          point_system: parsed.tournament[:point_system]
        )
      end

      from_engine = tournament() |> Trf.serialize() |> Trf.parse() |> pair.()
      from_trf26 = tournament() |> Trf.serialize(dialect: :trf26) |> Trf.parse() |> pair.()

      assert colour_blind(from_trf26) == colour_blind(from_engine)
      # 5 and 6 sit round three out, 1 and 4 are kept apart.
      seated = from_trf26 |> Enum.flat_map(&Tuple.to_list/1) |> Enum.reject(&is_nil/1)
      refute 5 in seated
      refute 6 in seated
      refute Enum.any?(from_trf26, &(&1 in [{1, 4}, {4, 1}]))
    end

    test "a standard point system writes no 162 line" do
      data = put_in(tournament(), [:tournament, :point_system], Trf.default_point_system())
      refute Trf.serialize(data, dialect: :trf26) =~ "162"
    end
  end

  describe "240 records" do
    test "one for a round already played must agree with the 001 line" do
      base = Trf.serialize(tournament())

      # Player 5 played round two; a bye there contradicts the line.
      assert_raise ValidationError, ~r/240 line gives starting rank 5 a H bye in round 2/, fn ->
        Trf.parse(base <> "240 H 002    5\r\n")
      end

      # ...and one that agrees with the column changes nothing.
      agreed = Trf.parse(base <> "240 H 003    5\r\n")
      plain = Trf.parse(base)
      assert Enum.map(agreed.players, & &1.games) == Enum.map(plain.players, & &1.games)
      assert Enum.map(agreed.players, & &1.points) == Enum.map(plain.players, & &1.points)
    end

    test "one further ahead than the game list is kept, not applied" do
      parsed = Trf.parse(Trf.serialize(tournament()) <> "240 H 005    2\r\n")

      assert %{games: games, points: 3.0} = Enum.find(parsed.players, &(&1.rank == 2))
      assert length(games) == 2
      assert %{type: "H", round: 5, ranks: [2]} in parsed.tournament[:byes]
    end

    test "a rank no 001 line has, or a type the spec has not, is refused" do
      base = Trf.serialize(tournament())

      assert_raise ValidationError, ~r/starting rank 9, which no 001 line has/, fn ->
        Trf.parse(base <> "240 Z 003    9\r\n")
      end

      assert_raise ValidationError, ~r/unknown bye type "U"/, fn ->
        Trf.parse(base <> "240 U 003    5\r\n")
      end
    end

    test "a late entrant's short line is padded up to the bye" do
      # Player 7 has no games at all after two rounds and a half-point bye
      # granted for round three.
      data = update_in(tournament(), [:players], &(&1 ++ [player(7, 0.0, [])]))
      text = Trf.serialize(data, dialect: :engine) <> "240 H 003    7\r\n"
      parsed = Trf.parse(text)

      assert %{games: [%{result: nil}, %{result: nil}, %{result: "H"}], points: 1.0} =
               Enum.find(parsed.players, &(&1.rank == 7))
    end
  end

  describe "299 records" do
    test "a global typed record sets what that result is worth" do
      text =
        Trf.serialize(tournament()) <>
          row([{1, "299"}, {5, "+"}, {14, " 0.5"}]) <> row([{1, "299"}, {5, "F"}, {14, " 2.0"}])

      system = Trf.parse(text).tournament[:point_system]

      assert system.forfeit_win == 0.5
      assert system.full_point_bye == 2.0
      assert Trf.points_for("+", system) == 0.5
      assert Trf.points_for("F", system) == 2.0
      assert Trf.points_for("H", system) == 1.0
      assert Trf.points_for("+", Trf.default_point_system()) == 1.0
    end

    test "is written back out, in either dialect" do
      data = put_in(tournament(), [:tournament, :point_system, :forfeit_win], 0.5)

      for dialect <- [:engine, :trf26] do
        text = Trf.serialize(data, dialect: dialect)
        assert text =~ ~r/^299 \+ {8} 0\.5\r$/m
        assert Trf.parse(text).tournament[:point_system][:forfeit_win] == 0.5
      end
    end

    test "a forfeit loss unlike the zero-point bye is a 299 in TRF26, a BBF in the engine dialect" do
      data = put_in(tournament(), [:tournament, :point_system, :forfeit_loss], 0.5)

      trf26 = Trf.serialize(data, dialect: :trf26)
      assert trf26 =~ ~r/^299 - {8} 0\.5\r$/m
      assert Trf.parse(trf26).tournament[:point_system].forfeit_loss == 0.5

      engine = Trf.serialize(data)
      assert engine =~ "BBF  0.5"
      refute engine =~ "299 -"
    end

    test "free points are written back out, in either dialect" do
      data =
        put_in(tournament(), [:tournament, :free_points], [
          %{type: "", match_points: nil, points: 0.5, round: nil, ranks: [3]},
          %{type: "", match_points: nil, points: -1.0, round: 2, ranks: [4, 6]}
        ])

      for dialect <- [:engine, :trf26] do
        all = data |> Trf.serialize(dialect: dialect) |> lines()

        assert "299           0.5         3" in all
        assert "299          -1.0  002    4    6" in all

        assert Trf.parse(Enum.join(all, "
")).tournament[:free_points] == [
                 %{type: "", match_points: nil, points: 0.5, round: nil, ranks: [3]},
                 %{type: "", match_points: nil, points: -1.0, round: 2, ranks: [4, 6]}
               ]
      end
    end

    test "free points are kept, not applied - the 001 total already holds them" do
      text =
        Trf.serialize(tournament()) <> row([{1, "299"}, {14, "-1.0"}, {20, "002"}, {24, "   4"}])

      parsed = Trf.parse(text)

      assert [%{type: "", points: -1.0, round: 2, ranks: [4]}] = parsed.tournament[:free_points]
      assert Enum.find(parsed.players, &(&1.rank == 4)).points == 1.0
    end

    test "a typed record limited to a round or to players is refused, not dropped" do
      base = Trf.serialize(tournament())

      assert_raise ValidationError, ~r/limited to a round or to named players/, fn ->
        Trf.parse(base <> row([{1, "299"}, {5, "+"}, {14, " 0.5"}, {20, "002"}]))
      end

      assert_raise ValidationError, ~r/limited to a round or to named players/, fn ->
        Trf.parse(base <> row([{1, "299"}, {5, "+"}, {14, " 0.5"}, {20, "000"}, {24, "   4"}]))
      end
    end
  end

  describe "the TRF26 headers" do
    test "a type code off the table is refused before the file is written" do
      data = put_in(tournament(), [:tournament, :type_code], "FIDE_DUTCH_2025")

      assert_raise ValidationError,
                   ~r/192: "FIDE_DUTCH_2025" is not a tournament type code/,
                   fn ->
                     Trf.serialize(data, dialect: :trf26)
                   end

      for code <-
            ~w(FIDE_DUTCH_2017 BERGER_ROUNDROBIN_G2 FIDE_SCHILLER_4x3 FIDE_TEAM_BAKU CUSTOM_SWISS) do
        assert Trf.tournament_type_code?(code), code
      end

      refute Trf.tournament_type_code?("BERGER_ROUNDROBIN_G0")
      assert length(Trf.tournament_type_codes()) == 54
    end

    test "a time control that is not encoded is refused" do
      data = put_in(tournament(), [:tournament, :time_control_code], "90 min + 30 sec")

      assert_raise ValidationError,
                   ~r/222: "90 min \+ 30 sec" is not an encoded time control/,
                   fn ->
                     Trf.serialize(data, dialect: :trf26)
                   end

      for code <- ~w(5400+30 40/6000+30:900+30 W300-B240 600) do
        assert Trf.encoded_time_control?(code), code
      end

      refute Trf.encoded_time_control?("W300")
    end

    test "212 gives the tie-breaks when there is no 202" do
      text =
        Trf.serialize(update_in(tournament(), [:tournament], &Map.delete(&1, :tie_breaks))) <>
          "212 PTS,BHC1,BH\r\n"

      parsed = Trf.parse(text)

      assert parsed.tournament[:standings_order] == ["PTS", "BHC1", "BH"]
      assert parsed.tournament[:tie_breaks] == ["BHC1", "BH"]
    end
  end
end
