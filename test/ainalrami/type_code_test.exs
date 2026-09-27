defmodule Ainalrami.TypeCodeTest do
  @moduledoc """
  `Ainalrami.TypeCode` against FIDE's Tournament Type Code Table for TRF
  field 192 (FIDE TEC, published with TRF-2026): every code in the table
  means what the table says, and nothing off it parses.
  """
  use ExUnit.Case, async: true

  alias Ainalrami.{Trf, TypeCode}

  defp parse!(code) do
    assert {:ok, description} = TypeCode.parse(code), code
    description
  end

  test "every fixed code of the table parses, and says whether it is a team system" do
    for code <- Trf.tournament_type_codes() do
      d = parse!(code)
      assert d.code == code
      assert d.team? == String.contains?(code, "TEAM"), code
      assert d.baku? == String.ends_with?(code, "_BAKU"), code
    end
  end

  test "the parametrised families" do
    assert %{system: :round_robin, games: 3} = parse!("BERGER_ROUNDROBIN_G3")

    assert %{system: :team_round_robin, games: 4, team?: true} =
             parse!("BERGER_TEAM_ROUNDROBIN_G4")

    assert %{system: :schiller, teams: 6, players: 2} = parse!("FIDE_SCHILLER_6x2")
    assert %{system: :scheveningen, games: 2} = parse!("FIDE_SCHEVENINGEN_G2")

    for bad <- ~w(BERGER_ROUNDROBIN_G0 BERGER_ROUNDROBIN_G FIDE_SCHILLER_4 FIDE_SCHEVENINGEN_G0) do
      assert TypeCode.parse(bad) == :error, bad
    end
  end

  test "the shorthands are what the table defaults them to" do
    assert %{games: 1, defaults_to: "BERGER_ROUNDROBIN_G1"} = parse!("BERGER_ROUNDROBIN")
    assert %{games: 2, defaults_to: "BERGER_ROUNDROBIN_G2"} = parse!("BERGER_DOUBLEROUNDROBIN")
    assert %{games: 1, defaults_to: "BERGER_ROUNDROBIN"} = parse!("FIDE_ROUNDROBIN")
    assert %{teams: 4, players: 3, defaults_to: "FIDE_SCHILLER_4x3"} = parse!("FIDE_SCHILLER")
    assert %{games: 1} = parse!("FIDE_SCHEVENINGEN")
    assert %{games: 2} = parse!("FIDE_DOUBLESCHEVENINGEN")

    for code <- ~w(BERGER_TEAM_DOUBLEROUNDROBIN FIDE_TEAM_DOUBLEROUNDROBIN) do
      assert %{system: :team_round_robin, games: 2, defaults_to: "BERGER_TEAM_ROUNDROBIN_G2"} =
               parse!(code)
    end

    # FIDE_DOUBLEROUNDROBIN is its own construction, not _G2: the first
    # cycle's last two rounds are played in reverse order.
    assert %{games: 2, reverse_last_two?: true} = parse!("FIDE_DOUBLEROUNDROBIN")
    refute Map.has_key?(parse!("BERGER_DOUBLEROUNDROBIN"), :reverse_last_two?)

    assert %{colour_preferences: :a, score_mode: :match_points, use_secondary?: true} =
             parse!("FIDE_TEAM")

    assert %{colour_preferences: :a, baku?: true, defaults_to: "FIDE_TEAM_TYPEA_MP_GP_BAKU"} =
             parse!("FIDE_TEAM_BAKU")
  end

  test "team Swiss codes: TYPEA/TYPEB, or no colour preferences; primary and secondary scores" do
    assert %{colour_preferences: :a, score_mode: :game_points, use_secondary?: true} =
             parse!("FIDE_TEAM_TYPEA_GP_MP")

    assert %{colour_preferences: :b, score_mode: :match_points, use_secondary?: false} =
             parse!("FIDE_TEAM_TYPEB_MP")

    assert %{colour_preferences: :none, score_mode: :match_points, use_secondary?: true} =
             parse!("FIDE_TEAM_MP_GP")

    assert %{colour_preferences: :none, score_mode: :game_points, use_secondary?: false} =
             parse!("FIDE_TEAM_GP")

    assert %{colour_preferences: :none, baku?: true, use_secondary?: false} =
             parse!("FIDE_TEAM_MP_BAKU")

    # The table has no accelerated variant with game points primary.
    for bad <- ~w(FIDE_TEAM_GP_BAKU FIDE_TEAM_TYPEA_GP_MP_BAKU FIDE_TEAM_MP_MP FIDE_TEAM_TYPEA) do
      assert TypeCode.parse(bad) == :error, bad
    end
  end

  test "the Dutch editions, FIDE_DUTCH by the event's date, and the draft's 2026 spelling" do
    assert %{system: :dutch, edition: 2017} = parse!("FIDE_DUTCH_2017")
    assert %{system: :dutch, edition: 2025, baku?: true} = parse!("FIDE_DUTCH_2025_BAKU")
    assert %{edition: 2025, legacy?: true} = parse!("FIDE_DUTCH_2026")

    dutch = parse!("FIDE_DUTCH")
    assert dutch.edition == :by_date
    assert TypeCode.edition(dutch, "2025/06/30") == 2017
    assert TypeCode.edition(dutch, "2025/07/01") == 2025
    assert TypeCode.edition(dutch, "30.06.2025") == 2017
    assert TypeCode.edition(dutch, "2026-02-14") == 2025
    assert TypeCode.edition(dutch, nil) == :unknown
    assert TypeCode.edition(dutch, "spring") == :unknown
    assert TypeCode.edition(parse!("FIDE_DUTCH_2017"), "2026/01/01") == 2017
    assert TypeCode.edition(parse!("FIDE_DUBOV"), nil) == nil
  end

  test "case and blanks are forgiven; codes off the table are not" do
    assert %{code: "FIDE_TEAM_MP"} = parse!(" fide_team_mp ")
    assert %{code: "FIDE_SCHILLER_4x2"} = parse!("FIDE_SCHILLER_4X2")

    for bad <- ["FIDE_DUTCH_2022", "SWISS", "", "FIDE_TEAM_ROUNDROBIN_G2", nil, 192] do
      assert TypeCode.parse(bad) == :error, inspect(bad)
    end
  end
end
