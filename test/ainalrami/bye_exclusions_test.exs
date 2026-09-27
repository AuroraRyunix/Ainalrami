defmodule Ainalrami.ByeExclusionsTest do
  @moduledoc """
  `:bye_exclusions` - the organiser's list of players who must not receive
  the pairing-allocated bye this round. Not a FIDE rule: an excluded player
  is treated exactly as [C2] treats one who already had a bye, and nothing
  else changes. `Ainalrami.ByeExclusionValidationTest` checks it against a
  brute-force reference; these pin the individual behaviours.
  """

  use ExUnit.Case, async: true

  alias Ainalrami.Alternatives
  alias Ainalrami.Pairing
  alias Ainalrami.Pairing.NoValidPairingError

  describe "the bye choice" do
    test "round one: an excluded lowest-ranked player is passed over" do
      assert bye(Pairing.pair_next_round(field(5))) == 5

      pairs = Pairing.pair_next_round(field(5), bye_exclusions: [5])
      assert bye(pairs) == 4
      assert seated(pairs) == [1, 2, 3, 4, 5]
    end

    test "a later round: the lowest scorer is excluded, the next one takes the bye" do
      players = round_two_field()
      assert bye(Pairing.pair_next_round(players)) == 5

      pairs = Pairing.pair_next_round(players, bye_exclusions: [5])
      assert bye(pairs) == 4
      assert seated(pairs) == [1, 2, 3, 4, 5]
      refute had_pairing_bye?(players, bye(pairs))

      pairs = Pairing.pair_next_round(players, bye_exclusions: [4, 5])
      assert bye(pairs) in [1, 2], "0 points is out; of the 1-pointers C2 bars rank 3"
    end

    test "an excluded player is otherwise paired as before" do
      players = round_two_field()
      pairs = Pairing.pair_next_round(players, bye_exclusions: [1])

      assert pairs == Pairing.pair_next_round(players),
             "rank 1 was not going to get the bye, so excluding them changes nothing"
    end

    test "an empty list pairs exactly as no option" do
      players = round_two_field()

      assert Pairing.pair_next_round(players, bye_exclusions: []) ==
               Pairing.pair_next_round(players)

      assert Pairing.pair_next_round(field(5), bye_exclusions: []) ==
               Pairing.pair_next_round(field(5))
    end

    test "is ignored on an even field and for ranks not in the round" do
      assert Pairing.pair_next_round(field(6), bye_exclusions: [6]) ==
               Pairing.pair_next_round(field(6))

      assert Pairing.pair_next_round(field(5), bye_exclusions: [42]) ==
               Pairing.pair_next_round(field(5))
    end

    test "pair_later_round/2 takes the option too" do
      pairs = Pairing.pair_later_round(round_two_field(), bye_exclusions: [5])
      refute bye(pairs) == 5
    end

    test "anything but a list of ranks is refused" do
      assert_raise ArgumentError, ~r/bye_exclusions/, fn ->
        Pairing.pair_next_round(field(5), bye_exclusions: ["5"])
      end

      assert_raise ArgumentError, ~r/bye_exclusions/, fn ->
        Pairing.pair_next_round(field(5), bye_exclusions: 5)
      end
    end
  end

  describe "when the exclusions leave no legal round" do
    test "everyone excluded: refused with the reason, the players and an override" do
      players = round_two_field()

      error =
        assert_raise NoValidPairingError, fn ->
          Pairing.pair_next_round(players, bye_exclusions: [1, 2, 3, 4, 5])
        end

      assert error.reason == :bye_exclusions
      assert error.excluded == [1, 2, 3, 4, 5]
      assert error.override == 5, "the player who takes the bye with no exclusion"
      assert error.message =~ "organiser exclusion"

      # The override: the same list without that one player pairs, and the
      # bye goes to them.
      pairs = Pairing.pair_next_round(players, bye_exclusions: [1, 2, 3, 4])
      assert bye(pairs) == 5
    end

    test "everyone excluded in round one" do
      error =
        assert_raise NoValidPairingError, fn ->
          Pairing.pair_next_round(field(3), bye_exclusions: [1, 2, 3])
        end

      assert {error.reason, error.excluded, error.override} == {:bye_exclusions, [1, 2, 3], 3}
    end

    test "everyone C2 does not already rule out is excluded" do
      # Rank 3 had the round-one bye, so C2 already bars them; excluding the
      # other four leaves nobody.
      players = round_two_field()

      error =
        assert_raise NoValidPairingError, fn ->
          Pairing.pair_next_round(players, bye_exclusions: [1, 2, 4, 5])
        end

      assert error.reason == :bye_exclusions
      assert error.excluded == [1, 2, 4, 5]
      assert error.override == bye(Pairing.pair_next_round(players))
    end

    test "a round impossible without the exclusions keeps the plain reason" do
      # Three players who have all met: no legal round either way.
      players = [
        played(1, [{2, "w", "1"}, {3, "b", "1"}]),
        played(2, [{1, "b", "0"}, {3, "w", "="}]),
        played(3, [{2, "b", "="}, {1, "w", "0"}])
      ]

      error =
        assert_raise NoValidPairingError, fn ->
          Pairing.pair_next_round(players, bye_exclusions: [3])
        end

      assert error.reason == :no_legal_pairing
      assert error.excluded == []
      assert error.override == nil
    end
  end

  describe "the explanation" do
    test "explain_round/3 names who was passed over, on the bye holder's bracket" do
      players = round_two_field()
      pairs = Pairing.pair_next_round(players, bye_exclusions: [5])
      report = Pairing.explain_round(players, pairs, bye_exclusions: [5])

      assert [%{rank: 5, reason: :organiser_exclusion}] ==
               Enum.flat_map(report, &Map.get(&1, :bye_passed_over, []))

      holder_bracket = Enum.find(report, &Map.has_key?(&1, :bye_passed_over))
      assert bye(pairs) in holder_bracket.order
    end

    test "a chain: each excluded player who would have been next is named, in order" do
      pairs = Pairing.pair_next_round(field(5), bye_exclusions: [5, 4])
      assert bye(pairs) == 3

      passed =
        field(5)
        |> Pairing.explain_round(pairs, bye_exclusions: [5, 4])
        |> Enum.flat_map(&Map.get(&1, :bye_passed_over, []))
        |> Enum.map(& &1.rank)

      assert passed == [5, 4]
    end

    test "an exclusion that changed nothing passes nobody over" do
      players = round_two_field()
      pairs = Pairing.pair_next_round(players, bye_exclusions: [1])

      passed =
        players
        |> Pairing.explain_round(pairs, bye_exclusions: [1])
        |> Enum.flat_map(&Map.get(&1, :bye_passed_over, []))

      assert passed == []
    end

    test "without the option no bracket carries the key" do
      players = round_two_field()
      pairs = Pairing.pair_next_round(players)
      refute Enum.any?(Pairing.explain_round(players, pairs), &Map.has_key?(&1, :bye_passed_over))
    end

    test "bye_passed_over: false skips the account" do
      players = round_two_field()
      pairs = Pairing.pair_next_round(players, bye_exclusions: [5])

      report = Pairing.explain_round(players, pairs, bye_exclusions: [5], bye_passed_over: false)
      refute Enum.any?(report, &Map.has_key?(&1, :bye_passed_over))
    end

    test "bye_eligibility/2 reports the exclusion, and keeps C2's own reason" do
      eligibility = Pairing.bye_eligibility(round_two_field(), bye_exclusions: [3, 4, 5])

      assert eligibility[4] == :organiser_exclusion
      assert eligibility[5] == :organiser_exclusion
      assert eligibility[3] == :pairing_bye, "C2 already ruled rank 3 out"
      assert eligibility[1] == nil
    end

    test "bye_alternatives/3 marks an excluded bracket-mate as ineligible for that reason" do
      players = round_two_field()
      pairs = Pairing.pair_next_round(players, bye_exclusions: [4])
      alternatives = Alternatives.bye_alternatives(players, pairs, bye_exclusions: [4])

      assert alternatives.holder == 5

      assert %{rank: 4, outcome: :ineligible, reason: :organiser_exclusion} in alternatives.candidates
    end
  end

  # Five players after round one: 1 beat 4, 2 beat 5, 3 had the bye. So
  # 4 and 5 are the lowest scorers, and 3 is already ruled out by C2.
  defp round_two_field do
    [
      played(1, [{4, "w", "1"}]),
      played(2, [{5, "b", "1"}]),
      %{player(3) | points: 1.0, games: [%{opponent_rank: nil, colour: nil, result: "U"}]},
      played(4, [{1, "b", "0"}]),
      played(5, [{2, "w", "0"}])
    ]
  end

  defp played(rank, games) do
    games =
      for {opp, colour, result} <- games,
          do: %{opponent_rank: opp, colour: colour, result: result}

    points =
      Enum.reduce(games, 0.0, fn g, acc ->
        acc + %{"1" => 1.0, "=" => 0.5, "0" => 0.0}[g.result]
      end)

    %{player(rank) | points: points, games: games}
  end

  defp field(n), do: for(rank <- 1..n, do: player(rank))

  defp player(rank) do
    %{rank: rank, name: "P#{rank}", fide_rating: 2500 - rank * 10, points: 0.0, games: []}
  end

  defp bye(pairs), do: Enum.find_value(pairs, fn {w, b} -> if is_nil(b), do: w end)

  defp seated(pairs),
    do: pairs |> Enum.flat_map(fn {w, b} -> if b, do: [w, b], else: [w] end) |> Enum.sort()

  defp had_pairing_bye?(players, rank) do
    players
    |> Enum.find(&(&1.rank == rank))
    |> Map.fetch!(:games)
    |> Enum.any?(&(&1.result == "U"))
  end
end
