defmodule Ainalrami.LetterResultCodesTest do
  @moduledoc """
  TRF16's letter spellings of an ordinary result: `W` = win, `D` = draw,
  `L` = loss.

  `Trf.parse/1` used to raise `ValidationError` on a legal file carrying any
  of them, because `@playing_codes`/`@bye_codes` between them omitted all
  three. Worse, `pairing.ex` had `W` in its bye-disqualifying list on the
  reading that it was an *unplayed* win.

  Both were settled against bbpPairings' own reader rather than argued:
  `gameWasPlayed = false` is set for exactly `+ - H F U Z` and space
  (`trf.cpp:278-286`), which does not include W/D/L, and those three are
  scored through the same WIN/DRAW/LOSS branch as `1`/`=`/`0`
  (`trf.cpp:252-270`). So they are played games against a real opponent, and
  `eligibleForBye`'s `!match.gameWasPlayed` gate (`common.h:111`) means an
  ordinary win can never cost a player their bye eligibility.
  """

  use ExUnit.Case, async: true

  alias Ainalrami.{Pairing, Trf}

  describe "Trf.points_for/1" do
    test "scores the letter codes like the symbols they spell" do
      assert Trf.points_for("W") == Trf.points_for("1")
      assert Trf.points_for("D") == Trf.points_for("=")
      assert Trf.points_for("L") == Trf.points_for("0")

      assert Trf.points_for("W") == 1.0
      assert Trf.points_for("D") == 0.5
      assert Trf.points_for("L") == 0.0
    end
  end

  describe "Trf.parse/1" do
    test "accepts a file whose results are spelled with letters, and normalises them" do
      # Two players, one round, "W" against "L" - the letter form of 1 v 0.
      # The old parser raised on this outright.
      trf = """
      012 Letter codes\r
      062 2\r
      001    1      Alpha, A                          2000                             1.0    1     2 w W\r
      001    2      Beta, B                           1900                             0.0    2     1 b L\r
      XXR 1\r
      """

      %{players: players} = Trf.parse(trf)

      assert [%{games: [alpha]}, %{games: [beta]}] = players

      # Normalised on the way in, so nothing downstream has to know about the
      # letter forms at all.
      assert alpha.result == "1"
      assert beta.result == "0"
    end
  end

  describe "bye eligibility" do
    test "an ordinary win does not disqualify a player from the bye" do
      # Constructed so rank 1 is the ONLY player who may take it: ranks 2 and 3
      # each hold a full-point bye ("F"), which genuinely does disqualify. An
      # earlier draft left another eligible player in the field, so the engine
      # simply gave the bye to them and the test passed with `W` still in the
      # disqualifying list - proving nothing.
      #
      # Round 1: 1 beat 2, 3 sat out. Round 2: 1 beat 3, 2 sat out. Both wins
      # spelled with letters. Ranks 2 and 3 have not met, so the only legal
      # round-3 shape is 2 v 3 with rank 1 on the bye.
      players = [
        player(1, 2.0, [
          %{result: "W", colour: "w", opponent_rank: 2},
          %{result: "W", colour: "b", opponent_rank: 3}
        ]),
        player(2, 1.0, [
          %{result: "L", colour: "b", opponent_rank: 1},
          %{result: "F", colour: nil, opponent_rank: nil}
        ]),
        player(3, 1.0, [
          %{result: "F", colour: nil, opponent_rank: nil},
          %{result: "L", colour: "w", opponent_rank: 1}
        ])
      ]

      pairs = Pairing.pair_next_round(players, expected_rounds: 5)

      assert {1, nil} in pairs,
             "rank 1's only unplayed-game-free history is two wins; barring them from the bye " <>
               "leaves the position with no legal bye assignee at all"

      assert Enum.count(pairs, fn {_w, b} -> is_nil(b) end) == 1
      seated = Enum.flat_map(pairs, fn {w, b} -> if b, do: [w, b], else: [w] end)
      assert Enum.sort(seated) == [1, 2, 3]
    end

    test "a forfeit win still does disqualify - the rule itself is intact" do
      players = [
        player(1, 1.0, [%{result: "+", colour: nil, opponent_rank: 2}]),
        player(2, 0.0, [%{result: "-", colour: nil, opponent_rank: 1}]),
        player(3, 0.5, [%{result: "H", colour: nil, opponent_rank: nil}])
      ]

      pairs = Pairing.pair_next_round(players, expected_rounds: 5)

      assert {byer, nil} = Enum.find(pairs, fn {_w, b} -> is_nil(b) end)
      refute byer == 1, "a forfeit win is an unplayed win worth a full point - C2 bars it"
    end
  end

  describe "Trf.result_codes/0" do
    test "the published code table is complete and self-consistent" do
      # Public, with no caller inside this repo - it exists for the sibling
      # app, which means nothing here pinned its shape and it could have been
      # renamed or thinned without anything noticing. Pinned now.
      codes = Trf.result_codes()

      assert codes == %{
               win: "1",
               draw: "=",
               loss: "0",
               forfeit_win: "+",
               forfeit_loss: "-",
               half_point_bye: "H",
               full_point_bye: "F",
               pairing_allocated_bye: "U",
               zero_point_bye: "Z"
             }

      # Every published code must be one `points_for/1` actually scores, and
      # every one must be distinct - a duplicate would silently collapse two
      # outcomes for any caller building a file from this table.
      values = Map.values(codes)
      assert length(Enum.uniq(values)) == length(values)

      for {name, code} <- codes do
        assert Trf.points_for(code) in [0.0, 0.5, 1.0], "#{name} (#{code}) is unscored"
      end
    end
  end

  defp player(rank, points, games) do
    %{
      name: "P#{rank}",
      title: "",
      federation: "",
      sex: "",
      fide_rating: 2000 - rank * 100,
      fide_number: nil,
      birth_date: "",
      points: points,
      rank: rank,
      games: games
    }
  end
end
