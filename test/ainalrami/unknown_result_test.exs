defmodule Ainalrami.UnknownResultTest do
  @moduledoc """
  The `?` unknown-result code: FIDE's TRF-26 ITDX symbol for a game that was
  played and whose result is not on record.

  This engine committed to it in writing. Section C.2 of the feedback sent to
  FIDE's Technical & Environment Commission on 2026-09-08 backs `?` over the
  alternative reading - that a reader should treat ANY invalid code as
  unknown - on the grounds that the alternative silently converts a corrupt
  file into a plausible one, which is the failure mode hardest to notice. So
  the two halves of that argument are both pinned here: `?` is read, and an
  invalid code is still invalid.

  The third thing is what a `?` is once read. Until v0.44.0 every
  calculation that needed a value refused; since then it is what TRF-2026
  says: a played game - the record has the opponent and the colours - worth
  the file's `162` `X`, a draw's points by default. It is still not a
  forfeit and not a blank, and nothing turns it into either.
  """

  use ExUnit.Case, async: true

  alias Ainalrami.Generator
  alias Ainalrami.Pairing
  alias Ainalrami.Trf
  alias Ainalrami.Trf.ValidationError

  # One round, two players, mutually referencing. `result` is dropped into
  # column 99 of each line, which is where round one's result belongs.
  defp two_player_trf(white_result, black_result) do
    """
    012 Unknown results\r
    062 2\r
    001    1      Alpha, A                          2000                             0.0    1     2 w #{white_result}\r
    001    2      Beta, B                           1900                             0.0    2     1 b #{black_result}\r
    XXR 1\r
    """
  end

  describe "parse/1" do
    test "a file carrying ? parses, and the code comes back as the file spells it" do
      %{players: [%{games: [alpha]}, %{games: [beta]}]} = Trf.parse(two_player_trf("?", "?"))

      assert alpha.result == "?"
      assert beta.result == "?"

      # The pairing itself is intact - only the outcome is missing.
      assert alpha.opponent_rank == 2
      assert alpha.colour == "w"
    end

    test "? is not a blank, and a blank is not a ?" do
      # The distinction the code exists for. A blank column says the result
      # has not been RECORDED - the round may not have been played, or the
      # file may not have caught up, and either way waiting may produce one.
      # `?` says the game happened and no waiting will produce anything.
      #
      # Round one is blank here and round two is the lost game, because a
      # TRAILING blank block is dropped on the way in by design (a
      # hand-edited file loses its tail); an interior one is a late entrant
      # and survives, which is the case that can sit next to a `?`.
      blank = %{opponent_rank: nil, colour: nil, result: nil}

      text =
        %{
          tournament: %{name: "Late entrant", type: "swiss"},
          players: [
            player(1, [blank, %{opponent_rank: 2, colour: "w", result: "1"}]),
            player(2, [blank, %{opponent_rank: 1, colour: "b", result: "0"}])
          ]
        }
        |> Trf.serialize()
        |> set_result(2, "?")

      %{players: [%{games: alpha}, _]} = Trf.parse(text)

      assert [%{result: nil}, %{result: "?"}] = alpha

      assert Trf.unknown_result?("?")
      refute Trf.unknown_result?(nil)
      refute Trf.unknown_result?("")
    end

    test "? is not any real result either" do
      %{players: [%{games: [alpha]} | _]} = Trf.parse(two_player_trf("?", "?"))

      refute alpha.result in Trf.playing_codes()
      refute alpha.result in Trf.bye_codes()

      # Nothing folds it into a neighbour on the way in, which is the whole
      # reason the parser stopped folding `W`/`D`/`L` too - a code rewritten
      # at the door leaves nothing behind to recover it from.
      refute alpha.result in ["=", "0", "-", "Z"]
    end

    test "an unrecognized code is still refused, and is not read as unknown" do
      # The half of the TEC letter that is a refusal rather than a feature.
      # If this ever passes by being read as `?`, the argument the engine
      # made to FIDE is no longer one it implements.
      assert_raise ValidationError, ~r/unrecognized TRF result code/, fn ->
        Trf.parse(two_player_trf("X", "X"))
      end

      assert_raise ValidationError, ~r/unrecognized TRF result code/, fn ->
        Trf.parse(two_player_trf("*", "*"))
      end
    end

    test "? on one side and a real result on the other is a contradiction, not a lost result" do
      # Knowing one seat is knowing the other. A file that says White's
      # result is lost and Black won is not a file with one missing result;
      # it is two records of the same game that disagree.
      assert_raise ValidationError, ~r/illegal result combination/, fn ->
        Trf.parse(two_player_trf("?", "1"))
      end

      assert_raise ValidationError, ~r/illegal result combination/, fn ->
        Trf.parse(two_player_trf("0", "?"))
      end
    end
  end

  describe "what ? means to everything that reads a result" do
    # TRF-2026's `162` defines `X` as what an unknown result is worth, "like
    # for instance in an adjourned game", a draw's points by default. Until
    # v0.44.0 this engine refused both questions below; it now gives the
    # format's answers, and these pin them.
    test "it scores the file's X, and a draw when the file declares none" do
      assert Trf.points_for("?") == 0.5
      assert Trf.points_for("?", Trf.default_point_system()) == 0.5

      # The draw of the point system in force, not a hard-coded half.
      assert Trf.points_for("?", %{Trf.default_point_system() | draw: 1.0, win: 3.0}) == 1.0
    end

    test "as a game too, opponent or none" do
      # `points_for_game/2` reads the opponent as well as the code, because
      # `0000 - +` and `0000 - -` mean different things from `+` and `-`.
      # Neither reading changes what an unknown result is worth.
      assert Trf.points_for_game(%{opponent_rank: 2, result: "?"}) == 0.5
      assert Trf.points_for_game(%{opponent_rank: nil, result: "?"}) == 0.5
    end

    test "it was played: the record carries the opponent and the colours" do
      # `false` would file it with the forfeits and the byes - FIDE Art. 16's
      # unplayed games, excluded from colour history and from C2's bye
      # eligibility - and give White twice running to a player who had it.
      assert Trf.game_was_played?("?")

      # The blank it must not be confused with is still not a game.
      refute Trf.game_was_played?(nil)
      refute Trf.game_was_played?("")
    end

    test "and the player was in the pairing" do
      %{players: [alpha, _] = players} = Trf.parse(two_player_trf("?", "?"))
      [game] = alpha.games

      assert Trf.participated_in_pairing?(game)
      assert Trf.rounds_played(players) == 1
    end

    test "the tie-breaks and the pairing agree that it was played" do
      # `Ainalrami.Tiebreaks.Event` had counted `?` as a played game since it
      # first read one; `game_was_played?/1` raising was the odd one out.
      %{players: [%{games: [alpha]} | _]} = Trf.parse(two_player_trf("?", "?"))
      event = Ainalrami.Tiebreaks.Event.from_trf(Trf.parse(two_player_trf("?", "?")))
      first = event.participants[1]

      assert Trf.game_was_played?(alpha.result)
      assert first.rounds[1].kind == :played
      assert first.rounds[1].points == 0.5
    end
  end

  describe "a declared X value" do
    # `Ainalrami.PointSystemTest` covers `162` itself (parsing X, and the
    # writer carrying a declared one back out); this section covers what `?`
    # is worth once the file has made that claim.
    test "? scores the declared X value, not the default draw" do
      system = Map.put(Trf.default_point_system(), :unknown, 0.0)
      assert Trf.points_for("?", system) == 0.0
    end

    test "? scores the declared X value when it happens to be a draw" do
      system = Map.put(Trf.default_point_system(), :unknown, 0.5)
      assert Trf.points_for("?", system) == 0.5
    end

    test "? as a game scores the declared X value too, opponent or none" do
      system = Map.put(Trf.default_point_system(), :unknown, 0.25)

      assert Trf.points_for_game(%{opponent_rank: 2, result: "?"}, system) == 0.25
      assert Trf.points_for_game(%{opponent_rank: nil, result: "?"}, system) == 0.25
    end

    test "an X of nought is a value, not an absent one" do
      # `0.0` is truthy in Elixir, which is the whole reason this is safe to
      # write as `||` - and the reason it is pinned.
      system = Map.put(Trf.default_point_system(), :unknown, 0.0)
      assert Trf.points_for_game(%{opponent_rank: 2, result: "?"}, system) == 0.0
    end
  end

  describe "serialize/1" do
    test "refuses ?, in both dialects, and says it is read-only" do
      for dialect <- [:engine, :trf26] do
        assert_raise ValidationError, ~r/read-only result code/, fn ->
          Trf.serialize(unknown_game_data(), dialect: dialect)
        end
      end
    end

    test "the refusal is about the code, not about the shape of the file" do
      # Same two players, same columns, a real result: this is a file the
      # writer is happy with, so the refusal above is `?` and nothing else.
      data = put_in(unknown_game_data().players, opposed("1", "0"))

      assert is_binary(Trf.serialize(data))
    end
  end

  describe "pairing a tournament with an unknown result" do
    # Round one: 1 v 2 is lost, 3 v 4 is on record. Six players, so the
    # round after has brackets, floats and a colour to settle for everyone.
    defp lost_round_one(result) do
      [
        player(1, [%{opponent_rank: 2, colour: "w", result: result}]),
        player(2, [%{opponent_rank: 1, colour: "b", result: result}]),
        player(3, [%{opponent_rank: 4, colour: "w", result: "1"}]),
        player(4, [%{opponent_rank: 3, colour: "b", result: "0"}]),
        player(5, [%{opponent_rank: 6, colour: "w", result: "0"}]),
        player(6, [%{opponent_rank: 5, colour: "b", result: "1"}])
      ]
    end

    defp pair(players, opts \\ []) do
      Pairing.pair_next_round(players, [expected_rounds: 5, initial_colour: "w"] ++ opts)
    end

    test "pairs it as the played draw TRF-2026 values it at, colours and all" do
      # The equivalence is the whole claim: with no `X`, `?` is a game that
      # was played and is worth a draw, so the round is exactly the round of
      # the same file with `=` in its place.
      assert pair(lost_round_one("?")) == pair(lost_round_one("="))
      assert pair(lost_round_one("?")) != []
    end

    test "a declared X moves the score, and only the score" do
      # X = 0: both lost, as far as the brackets go - the round of the same
      # file with a played double loss (`0`/`0`).
      system = Map.put(Trf.default_point_system(), :unknown, 0.0)

      assert pair(lost_round_one("?"), point_system: system) ==
               pair(lost_round_one("0"))
    end

    test "rules on bye eligibility as for the played game" do
      # C2: a player who had a game is eligible; a `?` is a game.
      players = [
        player(1, [%{opponent_rank: 2, colour: "w", result: "?"}]),
        player(2, [%{opponent_rank: 1, colour: "b", result: "?"}])
      ]

      drawn = [
        player(1, [%{opponent_rank: 2, colour: "w", result: "="}]),
        player(2, [%{opponent_rank: 1, colour: "b", result: "="}])
      ]

      assert Pairing.bye_eligibility(players) == Pairing.bye_eligibility(drawn)
    end

    test "a lost game far in the past does not block the rest of the field" do
      # Two players met once, the result was lost, and they have taken a bye
      # every round since. The twelve who have nothing to do with the game
      # get their round, and the two are left out as the byes say.
      {text, _seed} = Generator.generate(seed: 4242, players: 12, rounds: 4)
      %{players: played_out} = Trf.parse(text)

      bye = %{opponent_rank: nil, colour: nil, result: "Z"}

      lost =
        for {rank, opponent, colour} <- [{13, 14, "w"}, {14, 13, "b"}] do
          rank
          |> player([%{opponent_rank: opponent, colour: colour, result: "?"}])
          |> Map.update!(:games, &(&1 ++ List.duplicate(bye, 4)))
        end

      pairs =
        Pairing.pair_next_round(played_out ++ lost, expected_rounds: 9, initial_colour: "w")

      assert pairs != []
      assert Enum.all?(pairs, fn {w, b} -> w not in [13, 14] and b not in [13, 14] end)
    end
  end

  describe "the change is additive" do
    test "every code that parsed before parses to the same thing, and scores the same" do
      # This is the whole safety argument for a corpus-validated engine, and
      # it holds mechanically rather than by measurement: before `?` was
      # recognised, a file containing one raised `ValidationError`, so no
      # file that parsed then can contain the character that every new
      # branch is keyed on. What is left to check is that the branches are
      # in fact keyed on it, which is what this walks.
      expected = %{
        "1" => 1.0,
        "=" => 0.5,
        "0" => 0.0,
        "+" => 1.0,
        "-" => 0.0,
        "W" => 1.0,
        "D" => 0.5,
        "L" => 0.0,
        "H" => 0.5,
        "F" => 1.0,
        "U" => 1.0,
        "Z" => 0.0
      }

      for {code, points} <- expected do
        assert Trf.points_for(code) == points, "#{code} no longer scores #{points}"
      end

      # Every writable code, still exactly what it was: played or not, and
      # in the list it was in.
      for code <- Trf.playing_codes() do
        assert Trf.game_was_played?(code) == code not in ["+", "-"]
      end

      for code <- Trf.bye_codes() do
        refute Trf.game_was_played?(code)
      end
    end

    test "a file of ordinary results still round-trips byte for byte" do
      data = put_in(unknown_game_data().players, opposed("1", "0"))
      text = Trf.serialize(data)

      %{players: [%{games: [white]}, %{games: [black]}]} = Trf.parse(text)

      assert white.result == "1"
      assert black.result == "0"
      assert Trf.serialize(put_in(data.players, opposed(white.result, black.result))) == text
    end
  end

  # Overwrite one round's result column on every `001` line. The writer is
  # the authority on where that column is - round blocks start at 92 and
  # repeat every ten, result at the block's eighth character - so the file
  # is built by `serialize/1` and edited, rather than typed out and counted
  # by hand.
  defp set_result(text, round, code) do
    before = 92 + (round - 1) * 10 + 7 - 1

    text
    |> String.split("\r\n")
    |> Enum.map_join("\r\n", fn
      "001" <> _ = line ->
        <<head::binary-size(^before), _::binary-size(1), rest::binary>> = line
        head <> code <> rest

      other ->
        other
    end)
  end

  defp unknown_game_data do
    %{tournament: %{name: "Unknown", type: "swiss"}, players: opposed("?", "?")}
  end

  defp opposed(white_result, black_result) do
    [
      player(1, [%{opponent_rank: 2, colour: "w", result: white_result}]),
      player(2, [%{opponent_rank: 1, colour: "b", result: black_result}])
    ]
  end

  defp player(rank, games) do
    %{
      rank: rank,
      name: "P#{rank}",
      sex: "",
      title: "",
      federation: "",
      fide_rating: 2400 - rank * 10,
      fide_number: nil,
      birth_date: "",
      points: 0.0,
      games: games
    }
  end
end
