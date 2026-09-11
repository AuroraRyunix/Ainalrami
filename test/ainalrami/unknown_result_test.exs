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

  What the tests below are mostly about is the third thing, which the letter
  did not have to say: an unknown result is not a forfeit, not a draw and not
  a blank, so nothing downstream may quietly turn it into one. Every
  calculation that would need a value refuses instead, and the refusals are
  asserted rather than left to the moduledoc.
  """

  use ExUnit.Case, async: true

  alias Ainalrami.Generator
  alias Ainalrami.Pairing
  alias Ainalrami.Trf
  alias Ainalrami.Trf.{UnknownResultError, ValidationError}

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
    test "it cannot be scored, under any point system" do
      assert_raise UnknownResultError, fn -> Trf.points_for("?") end

      assert_raise UnknownResultError, fn ->
        Trf.points_for("?", %{Trf.default_point_system() | draw: 0.4})
      end
    end

    test "it cannot be scored as a game either, opponent or none" do
      # `points_for_game/2` reads the opponent as well as the code, because
      # `0000 - +` and `0000 - -` mean different things from `+` and `-`.
      # Neither reading helps here: knowing a game had two seats says
      # nothing about what it was worth.
      assert_raise UnknownResultError, fn ->
        Trf.points_for_game(%{opponent_rank: 2, result: "?"})
      end

      assert_raise UnknownResultError, fn ->
        Trf.points_for_game(%{opponent_rank: nil, result: "?"})
      end
    end

    test "whether it was played is not known, so the predicate refuses rather than picking" do
      # `false` would file it with the forfeits and the byes - FIDE Art. 16's
      # unplayed games, excluded from colour history and from C2's bye
      # eligibility. That is a stronger claim than the file makes, and it is
      # the claim that would quietly reach a pairing.
      assert_raise UnknownResultError, fn -> Trf.game_was_played?("?") end

      # The blank it must not be confused with still answers.
      refute Trf.game_was_played?(nil)
      refute Trf.game_was_played?("")
    end

    test "but the player was in the pairing, and that much the file does say" do
      %{players: [alpha, _] = players} = Trf.parse(two_player_trf("?", "?"))
      [game] = alpha.games

      assert Trf.participated_in_pairing?(game)

      # And so the tournament still knows how far it has been paired, which
      # is what a reader loading a historical file needs first.
      assert Trf.rounds_played(players) == 1
    end
  end

  describe "a declared X value" do
    # FIDE TRF-2026 defines, in the `162` points-table line, the symbol `X`:
    # the points an unknown (`?`) result is worth - "like for instance in an
    # adjourned game", a draw's points by default. `Ainalrami.PointSystemTest`
    # covers `162` itself (parsing X, and the writer carrying a declared one
    # back out); this section covers what `?` is worth once the file has
    # made that claim.
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

    test "without a declared X, ? still raises exactly as before" do
      # The spec's own "a draw's points by default" is deliberately not
      # applied here: an undeclared X is this engine's existing refusal,
      # unchanged.
      assert_raise UnknownResultError, fn -> Trf.points_for("?") end
      assert_raise UnknownResultError, fn -> Trf.points_for("?", Trf.default_point_system()) end

      assert_raise UnknownResultError, fn ->
        Trf.points_for_game(%{opponent_rank: 2, result: "?"})
      end
    end

    test "whether the game was played still raises, whatever X says" do
      # `game_was_played?/1` takes no point system at all - it cannot see a
      # declared X, and would not act on one if it could: X is a score, not
      # a statement about whether the game was played.
      assert_raise UnknownResultError, fn -> Trf.game_was_played?("?") end
    end

    test "a declared X settles the score but not whether the game was played" do
      # `points_for/2` no longer raises here - the file declared X - but
      # colour history and float direction both ask `game_was_played?/1`
      # too, and that predicate does not look at the point system at all
      # (see above). A `?` in the most recent round still stops the round
      # it would have stopped before pairing needed a score at all; a
      # declared X settles what the game was WORTH, not whether it happened.
      players = [
        player(1, [%{opponent_rank: 2, colour: "w", result: "?"}]),
        player(2, [%{opponent_rank: 1, colour: "b", result: "?"}]),
        player(3, [%{opponent_rank: 4, colour: "w", result: "1"}]),
        player(4, [%{opponent_rank: 3, colour: "b", result: "0"}])
      ]

      system = Map.put(Trf.default_point_system(), :unknown, 0.5)

      assert_raise UnknownResultError, fn ->
        Pairing.pair_next_round(players,
          expected_rounds: 5,
          initial_colour: "w",
          point_system: system
        )
      end
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
    test "refuses rather than guessing a score" do
      # Round one: 1 v 2 is lost, 3 v 4 is on record. Nothing in the Dutch
      # system can place player 1 without knowing what they scored, and the
      # engine says so instead of seating them on a guess.
      players = [
        player(1, [%{opponent_rank: 2, colour: "w", result: "?"}]),
        player(2, [%{opponent_rank: 1, colour: "b", result: "?"}]),
        player(3, [%{opponent_rank: 4, colour: "w", result: "1"}]),
        player(4, [%{opponent_rank: 3, colour: "b", result: "0"}])
      ]

      assert_raise UnknownResultError, fn ->
        Pairing.pair_next_round(players, expected_rounds: 5, initial_colour: "w")
      end
    end

    test "but a lost game that no longer feeds any decision does not block the round" do
      # The other half of "the refusal comes from the calculation, not from a
      # gate at the door", and the reason there is no gate. Two players met
      # once, the result was lost, and they have taken a bye every round
      # since - including this one. Nothing about the round being paired
      # needs their score: they are not in a bracket, not in a colour
      # history, and far enough back that no active player's float looks
      # them up. So the twelve players who have nothing to do with the lost
      # game get their round.
      #
      # A gate would refuse this, and refusing it is worse than pairing it:
      # one missing scoresheet belonging to a withdrawn player would make
      # the tournament unpairable for the rest of its life. What the engine
      # will not do is VALUE the unknown, and the test above is where that
      # is pinned.
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

    test "and refuses to rule on bye eligibility for the same reason" do
      players = [
        player(1, [%{opponent_rank: 2, colour: "w", result: "?"}]),
        player(2, [%{opponent_rank: 1, colour: "b", result: "?"}])
      ]

      assert_raise UnknownResultError, fn -> Pairing.bye_eligibility(players) end
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
