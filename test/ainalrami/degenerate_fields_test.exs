defmodule Ainalrami.DegenerateFieldsTest do
  @moduledoc """
  Fields too small or too lopsided for the fuzz harness to generate.

  `PAIRING_FUZZ_MIN_PLAYERS` bottoms out at 4, and every generated
  tournament has a complete round-one history, so none of the shapes below
  has ever been measured against bbpPairings - they are checked here
  against the regulations directly.

  They are the shapes a real caller reaches first: an arbiter opens a
  tournament, adds one player, and asks for a pairing. An engine that
  raises there is unusable long before its bracket cascade matters.
  """

  use ExUnit.Case, async: true

  alias Ainalrami.Pairing

  @bye %{opponent_rank: nil, colour: nil, result: "Z"}

  describe "field sizes below anything the harness generates" do
    test "an empty field pairs to nothing rather than raising" do
      assert pair([]) == []
    end

    test "a single player takes the pairing-allocated bye" do
      assert pair(field(1)) == [{1, nil}]
    end

    test "two players are simply paired" do
      assert pair(field(2)) == [{1, 2}]
    end

    test "three players are one board and a bye" do
      pairs = pair(field(3))

      assert length(pairs) == 2
      assert Enum.count(pairs, fn {_w, b} -> is_nil(b) end) == 1

      seated = Enum.flat_map(pairs, fn {w, b} -> if b, do: [w, b], else: [w] end)
      assert Enum.sort(seated) == [1, 2, 3], "everyone is accounted for exactly once"
    end
  end

  describe "fields where nobody, or almost nobody, has played" do
    test "a round where every player's only history is a bye still pairs" do
      # Round two of a tournament whose round one was entirely byes. Nobody
      # holds a colour preference, so every board falls to Article 5.2.5 -
      # and nobody is disqualified from the next bye either, since `Z` is
      # not in C2's `U F +`.
      players = for rank <- 1..4, do: %{player(rank) | games: [@bye]}
      pairs = pair(players)

      assert length(pairs) == 2
      assert Enum.all?(pairs, fn {_w, b} -> not is_nil(b) end), "an even field takes no bye"
    end

    test "one unpaired player among players who already hold a result for the round" do
      # Player 1 has no history at all; 2-4 each hold a round-one bye. So
      # round one is NOT complete - bbpPairings counts a round as played
      # only once every player has an entry for it (`evenUpMatchHistories`)
      # - and the round being paired is still round one.
      #
      # Which means 2-4 already have their round-one result and are not
      # available, leaving player 1 alone and taking the bye. Pinned
      # because the answer looks wrong at a glance: three players are
      # "ignored", and that is precisely correct.
      players = [player(1) | for(rank <- 2..4, do: %{player(rank) | games: [@bye]})]

      assert pair(players) == [{1, nil}]
    end
  end

  describe "a field with no legal pairing left" do
    test "raises NoValidPairingError rather than emitting an illegal round" do
      # Two players who have already met, twice over, with nobody else to
      # pair with. There is no legal round, and the engine must say so
      # rather than seat the rematch - matching bbpPairings' own
      # `NoValidPairingException` and its exit code 1.
      met = fn rank, opponent, colour ->
        %{
          player(rank)
          | points: 1.0,
            games: [
              %{opponent_rank: opponent, colour: colour, result: "="},
              %{opponent_rank: opponent, colour: invert(colour), result: "="}
            ]
        }
      end

      players = [met.(1, 2, "w"), met.(2, 1, "b")]

      assert_raise Pairing.NoValidPairingError, fn -> pair(players) end
    end
  end

  defp invert("w"), do: "b"
  defp invert("b"), do: "w"

  defp pair(players) do
    Pairing.pair_next_round(players, expected_rounds: 5, initial_colour: "w")
  end

  defp field(n), do: for(rank <- 1..n, do: player(rank))

  defp player(rank) do
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
      games: []
    }
  end
end
