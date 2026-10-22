defmodule Ainalrami.XXZAbsenceTest do
  @moduledoc """
  `XXZ r1 r2 ...`: JaVaFo's record for the players absent from the round
  about to be paired, and what Swar writes. Until 0.44.1 the parser dropped
  it as an unknown `XX` code and the engine paired the absentees.

  The two fixtures are Swar files with the names, FIDE numbers and birth
  dates taken out. The expected pairings are JaVaFo 2.2's, run on the
  fixture files themselves (`java -jar javafo-2.2.jar FILE -p OUT`), not
  this engine's own output.
  """
  # Not async: `capture_io(:stderr, ...)` is VM-wide.
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Ainalrami.{ByePreference, CLI, EventFormat, Pairing, Trf}

  @round3 "test/fixtures/xxz/swar-round3.trf"
  @round5 "test/fixtures/xxz/swar-round5.trf"

  # JaVaFo 2.2 on each fixture, board order and colours as it printed them.
  @javafo %{
    @round3 => [{1, 4}, {5, 2}, {3, 6}, {7, 22}, {17, 8}, {23, 25}, {26, 24}],
    @round5 => [
      {3, 2},
      {5, 1},
      {8, 4},
      {11, 6},
      {12, 7},
      {10, 13},
      {14, 16},
      {18, 22},
      {25, 9},
      {17, 23},
      {26, 21},
      {27, 24},
      {28, nil}
    ]
  }

  @absent %{
    @round3 => [9, 10, 11, 12, 13, 14, 15, 16, 18, 19, 20, 21, 27, 28, 29, 30],
    @round5 => [15, 19, 20]
  }

  defp parse(path), do: path |> File.read!() |> Trf.parse()

  defp opts(parsed), do: [expected_rounds: parsed.tournament[:number_of_rounds]]

  defp z, do: %{opponent_rank: nil, colour: nil, result: "Z"}

  defp player(rank, games, points \\ 0.0) do
    %{rank: rank, name: "Player #{rank}", points: points, games: games}
  end

  defp game(opponent, colour, result),
    do: %{opponent_rank: opponent, colour: colour, result: result}

  # Four players after one round, as text: 1-3 and 2-4, White winning both.
  defp after_round_one(extra_players \\ [], lines \\ []) do
    players =
      [
        player(1, [game(3, "w", "1")], 1.0),
        player(2, [game(4, "w", "1")], 1.0),
        player(3, [game(1, "b", "0")]),
        player(4, [game(2, "b", "0")])
      ] ++ extra_players

    Trf.serialize(%{tournament: %{name: "Absences"}, players: players}) <>
      Enum.map_join(lines, "", &(&1 <> "\r\n"))
  end

  defp games_of(parsed, rank), do: Enum.find(parsed.players, &(&1.rank == rank)).games

  describe "reading XXZ" do
    test "each named player gets the 0000 - Z column of the round being paired, nobody else" do
      for path <- [@round3, @round5] do
        parsed = parse(path)
        played = Trf.rounds_played(parsed.players)

        for p <- parsed.players do
          at = Enum.at(p.games, played)

          if p.rank in @absent[path] do
            assert at == z(), "#{path}: #{p.rank} not marked absent"
            assert length(p.games) == played + 1
          else
            assert at == nil, "#{path}: #{p.rank} marked absent"
          end
        end
      end
    end

    test "reads exactly as the same file with the column written out" do
      text = after_round_one([], ["XXZ 2 3"])

      with_column =
        Trf.serialize(%{
          tournament: %{name: "Absences"},
          players: [
            player(1, [game(3, "w", "1")], 1.0),
            player(2, [game(4, "w", "1"), z()], 1.0),
            player(3, [game(1, "b", "0"), z()]),
            player(4, [game(2, "b", "0")])
          ]
        })

      assert Trf.parse(text).players == Trf.parse(with_column).players
    end

    test "a late entrant with no columns yet is padded up to the round" do
      parsed = Trf.parse(after_round_one([player(5, [])], ["XXZ 5"]))
      assert games_of(parsed, 5) == [%{opponent_rank: nil, colour: nil, result: nil}, z()]
    end

    test "several lines add up and a rank named twice is one absence" do
      parsed = Trf.parse(after_round_one([], ["XXZ 3", "XXZ 3 4"]))
      assert List.last(games_of(parsed, 3)) == z()
      assert List.last(games_of(parsed, 4)) == z()
      assert length(games_of(parsed, 3)) == 2
    end

    test "an empty XXZ line names nobody and changes nothing" do
      assert Trf.parse(after_round_one([], ["XXZ"])).players ==
               Trf.parse(after_round_one()).players
    end

    test "the same absence already in the column is agreement, not a conflict" do
      text =
        Trf.serialize(%{
          tournament: %{name: "Absences"},
          players: [
            player(1, [game(3, "w", "1")], 1.0),
            player(2, [game(4, "w", "1"), z()], 1.0),
            player(3, [game(1, "b", "0")]),
            player(4, [game(2, "b", "0")])
          ]
        }) <> "XXZ 2\r\n"

      assert games_of(Trf.parse(text), 2) == [game(4, "w", "1"), z()]
    end

    test "a rank the file does not have is refused" do
      assert_raise Trf.ValidationError,
                   ~r/XXZ names starting rank 9, which no 001 line has/,
                   fn ->
                     Trf.parse(after_round_one([], ["XXZ 2 9"]))
                   end
    end

    test "something that is not a starting rank is refused" do
      for token <- ~w(x 0 -3 2,4) do
        assert_raise Trf.ValidationError, ~r/XXZ line names/, fn ->
          Trf.parse(after_round_one([], ["XXZ 1 #{token}"]))
        end
      end
    end

    test "a bye already in that round's column is a conflict" do
      text =
        Trf.serialize(%{
          tournament: %{name: "Absences"},
          players: [
            player(1, [game(3, "w", "1"), %{opponent_rank: nil, colour: nil, result: "H"}], 1.5),
            player(2, [game(4, "w", "1")], 1.0),
            player(3, [game(1, "b", "0")]),
            player(4, [game(2, "b", "0")])
          ]
        }) <> "XXZ 1\r\n"

      assert_raise Trf.ValidationError, ~r/rank 1 is absent from round 2.*"H"/, fn ->
        Trf.parse(text)
      end
    end

    test "a full-point bye already in that round's column is a conflict" do
      # A game cannot be there: a player with a game in a column has been
      # paired in that round, which makes it a round already paired.
      text =
        Trf.serialize(%{
          tournament: %{name: "Absences"},
          players: [
            player(1, [game(3, "w", "1")], 1.0),
            player(2, [game(4, "w", "1")], 1.0),
            player(3, [game(1, "b", "0"), %{opponent_rank: nil, colour: nil, result: "F"}], 1.0),
            player(4, [game(2, "b", "0")])
          ]
        }) <> "XXZ 3
"

      assert_raise Trf.ValidationError, ~r/rank 3 is absent from round 2.*"F"/, fn ->
        Trf.parse(text)
      end
    end
  end

  describe "an unknown XX line" do
    test "is still accepted, with a warning naming it on stderr" do
      stderr =
        capture_io(:stderr, fn ->
          send(self(), {:parsed, Trf.parse(after_round_one([], ["XXQ something new"]))})
        end)

      assert stderr =~ "XXQ something new"
      assert_received {:parsed, parsed}
      assert parsed.players == Trf.parse(after_round_one()).players
    end

    test "known codes and XXZ itself are read in silence" do
      assert capture_io(:stderr, fn -> Trf.parse(File.read!(@round5)) end) == ""
    end
  end

  describe "every pairing entry point leaves the absentees out" do
    for path <- [@round3, @round5] do
      @path path

      test "pair_next_round/2 (#{Path.basename(path)})" do
        parsed = parse(@path)
        assert Pairing.pair_next_round(parsed.players, opts(parsed)) == @javafo[@path]
      end

      test "pair_later_round/2 (#{Path.basename(path)})" do
        parsed = parse(@path)
        assert Pairing.pair_later_round(parsed.players, opts(parsed)) == @javafo[@path]
      end

      test "pair_variants/3 (#{Path.basename(path)})" do
        parsed = parse(@path)

        assert Pairing.pair_variants(parsed.players, [%{}], opts(parsed)) == [
                 {:ok, @javafo[@path]}
               ]
      end

      test "EventFormat.pair_next_round/2 (#{Path.basename(path)})" do
        parsed = parse(@path)
        assert EventFormat.pair_next_round(parsed.players, opts(parsed)) == @javafo[@path]
      end

      test "ByePreference.pair/2 (#{Path.basename(path)})" do
        parsed = parse(@path)
        {pairs, _report} = ByePreference.pair(parsed.players, opts(parsed))
        assert pairs == @javafo[@path]
      end

      test "the command line's -p (#{Path.basename(path)})" do
        out = capture_io(fn -> assert CLI.run([@path, "-p", "-q"]) == 0 end)

        expected =
          Enum.map_join(@javafo[@path], "", fn {w, b} -> "#{w} #{b || 0}\r\n" end)

        assert out == "#{length(@javafo[@path])}\r\n" <> expected
      end
    end
  end

  describe "writing" do
    test "by default the absence stays a column, as before" do
      parsed = parse(@round5)
      text = Trf.serialize(parsed)
      refute text =~ "XXZ"
      assert Trf.parse(text).players == parsed.players
    end

    test "xxz: true writes it back as one XXZ line instead of the columns" do
      parsed = parse(@round5)
      text = Trf.serialize(parsed, xxz: true)

      assert text =~ "\r\nXXZ 15 19 20\r\n"
      # The three columns came off, and nothing else did.
      zs = &length(String.split(&1, "0000 - Z"))
      assert zs.(Trf.serialize(parsed)) - zs.(text) == 3
      assert Trf.parse(text).players == parsed.players
    end

    test "xxz: true round-trips the other fixture too" do
      parsed = parse(@round3)
      text = Trf.serialize(parsed, xxz: true)

      assert text =~ "XXZ " <> Enum.join(@absent[@round3], " ")
      assert Trf.parse(text).players == parsed.players
    end

    test "a Z with a later column after it stays a column" do
      players = [
        player(1, [game(3, "w", "1")], 1.0),
        player(2, [game(4, "w", "1"), z(), %{opponent_rank: nil, colour: nil, result: "H"}], 1.5),
        player(3, [game(1, "b", "0")]),
        player(4, [game(2, "b", "0")])
      ]

      text = Trf.serialize(%{tournament: %{name: "Absences"}, players: players}, xxz: true)
      refute text =~ "XXZ"
    end

    test "TRF26 writes the same absence as a 240 Z record" do
      parsed = parse(@round5)
      text = Trf.serialize(parsed, dialect: :trf26)

      assert text =~ "240 Z 005   15   19   20"
      refute text =~ "XXZ"
      assert Trf.parse(text).players == parsed.players
    end
  end
end
