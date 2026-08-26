defmodule Ainalrami.PointSystemTest do
  @moduledoc """
  What a result is WORTH, and the file directives that say so.

  This matters more than a scoring detail usually would. Points decide a
  player's score, score decides which bracket they are paired in, and the
  bracket decides everything after it - so an engine that reads these
  differently from the reference does not report different totals, it pairs
  a different tournament and reports it with full confidence.

  Unread until 2026-08-24, which meant silently discarded: the directives
  fell through to the header parser, exactly as `250`/`260` once did.
  """
  use ExUnit.Case, async: true

  alias Ainalrami.Pairing
  alias Ainalrami.Trf

  describe "what each result code is worth" do
    test "the standard system is unchanged by the system becoming configurable" do
      # The one-argument form is what every existing caller uses, and every
      # corpus this project has ever run was measured through it.
      assert Trf.points_for("1") == 1.0
      assert Trf.points_for("W") == 1.0
      assert Trf.points_for("+") == 1.0
      assert Trf.points_for("F") == 1.0
      assert Trf.points_for("U") == 1.0
      assert Trf.points_for("=") == 0.5
      assert Trf.points_for("D") == 0.5
      assert Trf.points_for("H") == 0.5
      assert Trf.points_for("0") == 0.0
      assert Trf.points_for("L") == 0.0
      assert Trf.points_for("-") == 0.0
      assert Trf.points_for("Z") == 0.0
    end

    test "each code draws from the field bbpPairings draws it from" do
      # Distinct values throughout, so a code reading the wrong field cannot
      # coincidentally produce the right number. This is the whole content
      # of `getPoints` (tournament.h:310-322) stated as a table.
      system = %{
        win: 7.0,
        draw: 3.0,
        loss: 2.0,
        pairing_allocated_bye: 5.0,
        forfeit_loss: 1.0,
        zero_point_bye: 0.25
      }

      assert Trf.points_for("1", system) == 7.0
      assert Trf.points_for("W", system) == 7.0

      # `+` is a forfeit WIN and `F` an arbiter's full-point bye. Both are
      # unplayed, and neither is the pairing's own bye, so both are worth a
      # win rather than the bye value.
      assert Trf.points_for("+", system) == 7.0
      assert Trf.points_for("F", system) == 7.0

      # `U` alone is the pairing-allocated bye.
      assert Trf.points_for("U", system) == 5.0

      # A half-point bye has no value of its own; it is a draw.
      assert Trf.points_for("=", system) == 3.0
      assert Trf.points_for("H", system) == 3.0

      assert Trf.points_for("0", system) == 2.0
      assert Trf.points_for("-", system) == 1.0
      assert Trf.points_for("Z", system) == 0.25
      assert Trf.points_for(nil, system) == 0.25
    end
  end

  describe "reading the directives" do
    test "each BB line sets its own field" do
      %{tournament: t} =
        Trf.parse("""
        012 Points
        BBW  2.0
        BBD  1.0
        BBL  0.5
        BBZ  0.1
        BBF  0.2
        BBU  1.5
        """)

      assert t[:point_system] == %{
               win: 2.0,
               draw: 1.0,
               loss: 0.5,
               zero_point_bye: 0.1,
               forfeit_loss: 0.2,
               pairing_allocated_bye: 1.5
             }
    end

    test "BBW drags the bye with it, and BBU pins it against that" do
      # bbpPairings' `usePairingAllocatedByeScore` flag (trf.cpp:1204-1232).
      # A file that only says "a win is 2" means the bye is 2 as well.
      %{tournament: t} = Trf.parse("012 P\nBBW  2.0\n")
      assert t[:point_system].pairing_allocated_bye == 2.0

      # But once BBU has spoken, BBW must not overwrite it - and the flag is
      # set by the DIRECTIVE, not by position, so this holds in either order.
      %{tournament: before} = Trf.parse("012 P\nBBU  0.5\nBBW  2.0\n")
      assert before[:point_system].pairing_allocated_bye == 0.5
      assert before[:point_system].win == 2.0

      %{tournament: after_} = Trf.parse("012 P\nBBW  2.0\nBBU  0.5\n")
      assert after_[:point_system].pairing_allocated_bye == 0.5
    end

    test "a 162 line says the same thing in fixed columns" do
      # `readPointSystem` (trf.cpp:573-631) walks `startIndex += 9` from
      # index 5: the symbol sits at the start of each nine-column entry and
      # the score in the four columns after it, leaving four columns of
      # filler. Entries spaced any other way parse their first record and
      # then read filler as a symbol, which is what makes the exact width
      # worth a test of its own.
      line = "162  " <> "W 2.0    " <> "D 1.0    " <> "Z 0.3    "

      %{tournament: t} = Trf.parse("012 P\n" <> line <> "\n")

      assert t[:point_system].win == 2.0
      assert t[:point_system].draw == 1.0

      # `Z` sets the forfeit loss along with the zero-point bye - one symbol,
      # two fields, which is the reference's own reading.
      assert t[:point_system].zero_point_bye == 0.3
      assert t[:point_system].forfeit_loss == 0.3
    end

    test "the symbol the reference refuses is refused here too" do
      # `X` throws `InvalidLineException("symbol X not supported")` there.
      # Guessing at it would mean pairing a tournament on invented scores.
      assert_raise Trf.ValidationError, ~r/symbol X/, fn ->
        Trf.parse("012 P\n162  X 1.0 \n")
      end
    end

    test "an unreadable value is refused rather than defaulted" do
      assert_raise Trf.ValidationError, ~r/point value/, fn ->
        Trf.parse("012 P\nBBW  abc\n")
      end
    end

    test "a file that says nothing has no point system, not a default one" do
      # `nil` rather than the default map, so serialising a file that never
      # mentioned points cannot invent directives it did not carry.
      %{tournament: t} = Trf.parse("012 P\n")
      refute Map.has_key?(t, :point_system)
    end
  end

  describe "writing the directives" do
    test "a standard system emits nothing at all" do
      # Every file bbpPairings has already validated in this project's
      # corpora must serialise byte-identically to before this existed.
      trf =
        Trf.serialize(%{
          tournament: %{name: "P", type: "swiss", point_system: Trf.default_point_system()},
          players: []
        })

      refute trf =~ "BB"
    end

    test "BBU is written whenever BBW is, because the reader would infer it" do
      # The bug this exists for: "emit only what differs from the default"
      # is the obvious rule and is wrong for exactly this field. Reading a
      # BBW sets pairing_allocated_bye to the same value unless a BBU has
      # already pinned it - `pab_pinned?` here, `usePairingAllocatedByeScore`
      # in bbpPairings. So a 3-1-0 system with an ordinary one-point bye
      # omitted BBU as "not different", and the reader then made the bye
      # worth three.
      #
      # That is not a round-trip defect. The FILE stated a point system the
      # caller never asked for, and anything reading it - including
      # bbpPairings - was entitled to believe it.
      system = %{Trf.default_point_system() | win: 3.0, draw: 1.0}

      trf =
        Trf.serialize(%{
          tournament: %{name: "P", type: "swiss", point_system: system},
          players: []
        })

      assert trf =~ "BBW"
      assert trf =~ "BBU", "BBW without BBU makes the reader infer a 3-point bye"

      assert Trf.parse(trf).tournament[:point_system].pairing_allocated_bye == 1.0,
             "the bye must come back as the one the caller specified"
    end

    test "only the values that differ are written" do
      trf =
        Trf.serialize(%{
          tournament: %{
            name: "P",
            type: "swiss",
            point_system: %{Trf.default_point_system() | pairing_allocated_bye: 0.5}
          },
          players: []
        })

      assert trf =~ "BBU"
      refute trf =~ "BBW"
      refute trf =~ "BBD"
    end

    test "the line is long enough and in the right column for the real parser" do
      # `readPoints` (trf.cpp:637-644) demands at least 8 characters and
      # reads from column 5. `BBW 2.0` is the obvious spelling, is 7
      # characters, and is rejected as an invalid line - which is how this
      # first reached the real binary and bounced.
      trf =
        Trf.serialize(%{
          tournament: %{
            name: "P",
            type: "swiss",
            point_system: %{Trf.default_point_system() | win: 2.0}
          },
          players: []
        })

      line = trf |> String.split("\r\n") |> Enum.find(&String.starts_with?(&1, "BBW"))

      assert String.length(line) >= 8
      assert String.trim(String.slice(line, 4, 8)) == "2.0"
    end

    test "a written system reads back as itself" do
      system = %{
        win: 2.0,
        draw: 1.0,
        loss: 0.5,
        zero_point_bye: 0.1,
        forfeit_loss: 0.2,
        pairing_allocated_bye: 1.5
      }

      round_tripped =
        %{tournament: %{name: "P", type: "swiss", point_system: system}, players: []}
        |> Trf.serialize()
        |> Trf.parse()

      assert round_tripped.tournament[:point_system] == system
    end
  end

  describe "what it changes in the pairing" do
    test "a bye worth half a point puts its holder in a different bracket" do
      # The configuration FIDE actually permits, and the reason this is
      # worth implementing rather than noting. Two players hold a
      # pairing-allocated bye and nothing else; under the standard system
      # they are on 1.0 and under BBU 0.5 they are on 0.5, which is a
      # different score group and therefore a different bracket.
      games = [%{opponent_rank: nil, colour: nil, result: "U"}]

      assert Trf.points_for(hd(games).result) == 1.0

      assert Trf.points_for(hd(games).result, %{
               Trf.default_point_system()
               | pairing_allocated_bye: 0.5
             }) == 0.5
    end

    test "C2 bye eligibility follows the points, not a fixed list of codes" do
      # bbpPairings gates on `getPoints(...) >= pointsForWin`, so the set of
      # disqualifying codes MOVES with the point system. Under the standard
      # one this is exactly `U`, `F` and `+`; set the forfeit loss to a
      # win's value and `-` joins them.
      standard = Trf.default_point_system()
      paid = %{standard | forfeit_loss: 1.0}

      assert Trf.points_for("-", standard) < standard.win
      assert Trf.points_for("-", paid) >= paid.win

      # And the codes that are UNPLAYED are what the rule can reach at all.
      refute Trf.game_was_played?("-")
      refute Trf.game_was_played?("U")
      refute Trf.game_was_played?("H")
      assert Trf.game_was_played?("1")
      assert Trf.game_was_played?("W")
      assert Trf.game_was_played?("D")
      assert Trf.game_was_played?("L")
    end

    # `getFloat` (dutch.cpp:110-129) decides whether an UNPLAYED round was a
    # downfloat by asking whether it paid more than a LOSS:
    #
    #     getPoints(player, match) > tournament.pointsForLoss
    #
    # `float_direction/4` read that as `> 0.0`, which is the same number
    # only while a loss is worth nothing. The two readings agree under the
    # standard system and under every other named system this harness runs -
    # `half_bye`, `football`, `double`, `paid_forfeit` all leave a loss at
    # zero - so 2.5 billion cross-checked pairings could not reach it. Set
    # `BBL 0.5` and a half-point bye stops being better than losing: it is
    # no longer a downfloat, and C14-C21 read a float history the reference
    # does not have for every player who ever sat a round out. Measured at
    # 88.62% of rounds against the reference on a 300-tournament range, and
    # 100.00% with the threshold read from the file.
    @half_point_bye_fixture "test/fixtures/point_system/paid-loss-half-point-bye-float.trf"

    test "an unplayed round is a downfloat only if it beat a LOSS, not zero" do
      %{players: players, tournament: t} = Trf.parse(File.read!(@half_point_bye_fixture))

      assert t[:point_system].loss == 0.5, "the fixture is the BBL 0.5 case"

      pairs =
        Pairing.pair_next_round(players,
          expected_rounds: t[:rounds],
          point_system: t[:point_system]
        )

      # Nine players, round 3. Score groups 1.5 = {2,3,5,9}, 1.0 = {4,7,8},
      # 0.5 = {1,6}; rank 1 takes the bye and the whole question is the 1.0
      # bracket, which pairs one board and floats one player. Rank 7 sat out
      # round 2 with `H`: worth 0.5, which is a draw's value and also a
      # LOSS's value here, so it is FLOAT_NONE. Reading it as a downfloat
      # made "pair 7, float 4" score a point of C14 it has not earned, and
      # this engine took it. Real bbpPairings pairs 4 v 8 and floats 7.
      assert normalise(pairs) == [[1], [2, 3], [4, 8], [5, 9], [6, 7]]
    end

    @float_history_fixture "test/fixtures/point_system/paid-loss-float-history.trf"

    test "a half-point bye under BBL 0.5 leaves no float history behind it" do
      %{players: players, tournament: t} = Trf.parse(File.read!(@float_history_fixture))

      pairs =
        Pairing.pair_next_round(players,
          expected_rounds: t[:rounds],
          point_system: t[:point_system]
        )

      # The same threshold, reached through C14 and C18 rather than a bare
      # tie-break: ranks 4 and 9 both hold `H` results, and with them read as
      # downfloats the 1.5 bracket {2,4,7} preferred to pair 4 and float 2.
      # bbpPairings pairs 2 v 7 and floats 4.
      assert normalise(pairs) == [[1, 3], [2, 7], [4, 9], [6, 8]]
    end

    defp normalise(pairs) do
      pairs
      |> Enum.map(fn
        {w, nil} -> [w]
        {w, b} -> Enum.sort([w, b])
      end)
      |> Enum.sort()
    end
  end
end
