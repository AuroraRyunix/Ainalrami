defmodule Ainalrami.TrfTeamRecordsTest do
  @moduledoc """
  TRF26 team records (`310`, `362`, `320`, `330`): read, written back,
  used by `Tiebreaks.Team.from_trf/2`, and checked by `ainalrami -c`.
  """
  use ExUnit.Case
  import ExUnit.CaptureIO

  alias Ainalrami.{CLI, Log, Trf}
  alias Ainalrami.Tiebreaks.Team

  setup do
    on_exit(fn -> Log.set_quiet(false) end)
  end

  # Three teams, two boards, one round. "One" (players 1, 2, reserve 3)
  # beats "Two" (4, 5) 1.5-0.5; "Three" (6, 7) has the pairing-allocated
  # bye. The 310 numbers are not the file order: Three is 1, One 2, Two 3.
  defp data(ranks \\ %{1 => 1, 2 => 2, 3 => 3}, extra \\ %{}) do
    g = fn opp, colour, result -> %{opponent_rank: opp, colour: colour, result: result} end
    none = %{opponent_rank: nil, colour: "-", result: ""}
    bye = %{opponent_rank: nil, colour: "-", result: "U"}

    players = [
      {1, [none]},
      {2, [g.(4, "w", "1")]},
      {3, [g.(5, "b", "=")]},
      {4, [g.(2, "b", "0")]},
      {5, [g.(3, "w", "=")]},
      {6, [bye]},
      {7, [bye]}
    ]

    %{
      tournament:
        Map.merge(
          %{
            name: "team records",
            type: "team-swiss",
            number_of_rounds: 1,
            standings_order: ~w(MPTS GPTS),
            team_point_system: %{win: 3.0, draw: 1.0, loss: 0.0, pab: 3.0}
          },
          extra
        ),
      players:
        for {rank, games} <- players do
          %{rank: rank, name: "P#{rank}", points: 0.0, games: games}
        end,
      teams: [
        %{
          number: 2,
          name: "One",
          nickname: "ONE",
          strength: 2100,
          match_points: 3.0,
          game_points: 1.5,
          final_rank: ranks[2],
          player_ranks: [1, 2, 3]
        },
        %{
          number: 3,
          name: "Two",
          match_points: 0.0,
          game_points: 0.5,
          final_rank: ranks[3],
          player_ranks: [4, 5]
        },
        %{
          number: 1,
          name: "Three",
          match_points: 3.0,
          game_points: 2.0,
          final_rank: ranks[1],
          player_ranks: [6, 7]
        }
      ]
    }
  end

  describe "parse/1 and serialize/2" do
    test "a 310 record's columns" do
      line =
        data()
        |> Trf.serialize()
        |> String.split("\r\n")
        |> Enum.find(&String.starts_with?(&1, "310   2"))

      assert String.slice(line, 8, 32) |> String.trim() == "One"
      assert String.slice(line, 41, 5) == "ONE  "
      assert String.slice(line, 47, 6) == "  2100"
      assert String.slice(line, 54, 6) == "   3.0"
      assert String.slice(line, 61, 6) == "   1.5"
      assert String.slice(line, 68, 3) == "  2"
      assert String.slice(line, 73, 14) == "   1    2    3"
    end

    test "310, 362, 320 and 330 round-trip" do
      given =
        data(%{1 => 1, 2 => 2, 3 => 3}, %{
          team_pab: %{match_points: 3.0, game_points: 2.0, teams: [1]},
          forfeited_matches: [%{type: "+-", round: 1, white: 2, black: 3}]
        })

      parsed = given |> Trf.serialize() |> Trf.parse()

      for {written, read} <- Enum.zip(given.teams, parsed.teams) do
        assert Map.take(read, Map.keys(written)) == written
      end

      assert parsed.tournament.team_point_system == given.tournament.team_point_system
      assert parsed.tournament.team_pab == given.tournament.team_pab
      assert parsed.tournament.forfeited_matches == given.tournament.forfeited_matches

      team_lines = fn d ->
        d |> Trf.serialize() |> String.split("\r\n") |> Enum.filter(&(&1 =~ ~r/^3[1-6]\d/))
      end

      assert length(team_lines.(given)) == 6
      assert team_lines.(parsed) == team_lines.(given)
    end

    test "013 still reads, and a file with 310 ignores its 013 lines" do
      old = %{data() | teams: Enum.map(data().teams, &Map.take(&1, [:name, :player_ranks]))}
      assert Trf.parse(Trf.serialize(old)).teams == old.teams

      team_013 =
        old
        |> Trf.serialize()
        |> String.split("\r\n")
        |> Enum.filter(&String.starts_with?(&1, "013"))
        |> Enum.map_join(&(&1 <> "\r\n"))

      both = Trf.serialize(data()) <> team_013
      assert Enum.map(Trf.parse(both).teams, & &1.number) == [2, 3, 1]
    end

    test "362 in TieBreakServer's own spelling" do
      parsed = Trf.parse(Trf.serialize(data()) <> "362  W 2.0    D 1.0    L 0.0    P 2.0\r\n")
      assert parsed.tournament.team_point_system == %{win: 2.0, draw: 1.0, loss: 0.0, pab: 2.0}
    end
  end

  describe "Team.from_trf/2 with 310 and 362" do
    test "teams keep their 310 numbers and score by the 362 match points" do
      event = data() |> Trf.serialize() |> Trf.parse() |> Team.from_trf()

      assert Map.keys(event.teams) |> Enum.sort() == [1, 2, 3]
      assert event.match_points == %{win: 3.0, draw: 1.0, loss: 0.0}

      one = event.teams[2].rounds[1]
      assert one.opponent == 3
      assert one.mp == 3.0
      assert event.teams[3].rounds[1].mp == 0.0
      assert event.teams[1].rounds[1].kind == :pab
      assert event.teams[1].rounds[1].mp == 3.0
    end

    test "320's match points for the bye beat 362's P, and :match_points beats both" do
      event =
        data(%{1 => 1, 2 => 2, 3 => 3}, %{
          team_pab: %{match_points: 1.0, game_points: 1.0, teams: [1]}
        })
        |> Trf.serialize()
        |> Trf.parse()
        |> Team.from_trf()

      assert event.teams[1].rounds[1].mp == 1.0

      override =
        data()
        |> Trf.serialize()
        |> Trf.parse()
        |> Team.from_trf(match_points: %{win: 2.0})

      assert override.teams[2].rounds[1].mp == 2.0
    end
  end

  describe "ainalrami -c on a team file" do
    defp check(data) do
      path =
        Path.join(
          System.tmp_dir!(),
          "ainalrami_team_check_#{System.unique_integer([:positive])}.trf"
        )

      File.write!(path, Trf.serialize(data))
      on_exit(fn -> File.rm(path) end)

      capture_io(fn -> capture_io(:stderr, fn -> CLI.run([path, "-c"]) end) |> IO.write() end)
    end

    test "agrees with a file whose 310 ranks follow its list" do
      # Three and One on 3 MP; Three has more game points.
      out = check(data())
      assert out =~ "standings: all 3 ranks follow MPTS GPTS"
      refute out =~ "team 1:"
    end

    test "reports every team whose rank the list does not give" do
      out = check(data(%{1 => 2, 2 => 1, 3 => 3}))
      assert out =~ "standings: 2 rank(s) do not follow MPTS GPTS"
      assert out =~ "team 1: file says 2, tie-breaks give 1 (MPTS=3.0 GPTS=2.0)"
      assert out =~ "team 2: file says 1, tie-breaks give 2"
      refute out =~ "team 3:"
    end

    test "skips, saying so, a team file with no team ranks" do
      old = %{data() | teams: Enum.map(data().teams, &Map.take(&1, [:name, :player_ranks]))}
      out = check(old)
      assert out =~ "a team event with no team ranks in the file"
    end
  end
end
