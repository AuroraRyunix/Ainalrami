defmodule Ainalrami.TeamBoardReadingTest do
  @moduledoc """
  Two readings of a real team report that `Tiebreaks.Team.from_trf/2` (and
  through it `ainalrami -c`'s team replay and standings check) got wrong:

    * a board one team could not fill, written for the other team's player
      as a win with no opponent (`0000 - F`), lost that player's point -
      only games against somebody were boards;
    * a team given the pairing-allocated bye in the `320` record alone,
      its players' columns left blank, was scored as a zero-point bye
      instead of the `320` record's points.
  """
  use ExUnit.Case, async: true

  alias Ainalrami.{TeamReplay, Trf}
  alias Ainalrami.Tiebreaks.Team

  defp game(opp, colour, result), do: %{opponent_rank: opp, colour: colour, result: result}
  defp blank, do: %{opponent_rank: nil, colour: nil, result: ""}

  defp player(rank, games),
    do: %{rank: rank, name: "P#{rank}", fide_rating: 2000, points: 0.0, games: games}

  defp parse(players, teams, tournament) do
    %{
      tournament: Map.merge(%{name: "T", number_of_rounds: 2}, tournament),
      players: players,
      teams: teams
    }
    |> Trf.serialize(dialect: :trf26)
    |> Trf.parse()
  end

  test "a board the other team could not fill counts as a forfeit win on that board" do
    # Team 1 (players 1-2) against team 2 (3-4), two boards; team 2 has
    # only player 3, so player 2's board is a win with no opponent.
    parsed =
      parse(
        [
          player(1, [game(3, "w", "0")]),
          player(2, [game(nil, nil, "F")]),
          player(3, [game(1, "b", "1")]),
          player(4, [blank()])
        ],
        [
          %{number: 1, name: "One", player_ranks: [1, 2]},
          %{number: 2, name: "Two", player_ranks: [3, 4]}
        ],
        %{team_point_system: %{win: 2.0, draw: 1.0, loss: 0.0}}
      )

    event = Team.from_trf(parsed)
    one = event.teams[1].rounds[1]
    two = event.teams[2].rounds[1]

    assert event.boards == 2
    assert one.gp == 1.0
    assert two.gp == 1.0
    # Level on game points, a board played: a drawn match.
    assert one.kind == :played
    assert one.mp == 1.0 and two.mp == 1.0

    history = TeamReplay.history(parsed)
    assert history[1][1].kind == :match
    assert history[1][1].opponent == 2
    assert history[1][1].colour == :white
    assert history[1][1].played?
  end

  test "a team the 320 record alone gives the bye is scored as the bye" do
    parsed =
      parse(
        [
          player(1, [game(3, "w", "1")]),
          player(2, [game(4, "b", "=")]),
          player(3, [game(1, "b", "0")]),
          player(4, [game(2, "w", "=")]),
          player(5, [blank()]),
          player(6, [blank()])
        ],
        [
          %{number: 1, name: "One", player_ranks: [1, 2]},
          %{number: 2, name: "Two", player_ranks: [3, 4]},
          %{number: 3, name: "Three", player_ranks: [5, 6]}
        ],
        %{
          team_point_system: %{win: 2.0, draw: 1.0, loss: 0.0},
          team_pab: %{match_points: 1.0, game_points: 1.0, teams: [3]}
        }
      )

    event = Team.from_trf(parsed)
    bye = event.teams[3].rounds[1]

    assert bye.kind == :pab
    assert bye.mp == 1.0
    assert bye.gp == 1.0
    assert TeamReplay.history(parsed)[3][1].kind == :pab
  end

  test "a round of whole-match forfeits only (330) still counts as a round" do
    # Round 2 was paired, but its one match was forfeited as a whole and
    # no board was written; player 1 has a zero-point bye for round 3,
    # recorded before round 3 is paired (TRF26 writes it as a 240 record).
    parsed =
      parse(
        [
          player(1, [game(3, "w", "1"), blank(), game(nil, nil, "Z")]),
          player(2, [game(4, "b", "="), blank()]),
          player(3, [game(1, "b", "0"), blank()]),
          player(4, [game(2, "w", "="), blank()])
        ],
        [
          %{number: 1, name: "One", player_ranks: [1, 2]},
          %{number: 2, name: "Two", player_ranks: [3, 4]}
        ],
        %{
          team_point_system: %{win: 2.0, draw: 1.0, loss: 0.0},
          forfeited_matches: [%{type: "+-", round: 2, white: 1, black: 2}]
        }
      )

    assert Enum.at(Enum.find(parsed.players, &(&1.rank == 1)).games, 2).result == "Z"

    event = Team.from_trf(parsed)
    assert event.rounds >= 2
    assert event.teams[1].rounds[2].kind == :forfeit_win

    history = TeamReplay.history(parsed)
    assert TeamReplay.paired_rounds(history) == 2
    refute TeamReplay.free?(Enum.find(parsed.players, &(&1.rank == 1)), 3)
  end
end
