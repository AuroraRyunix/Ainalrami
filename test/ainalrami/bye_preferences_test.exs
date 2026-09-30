defmodule Ainalrami.ByePreferencesTest do
  @moduledoc """
  `:bye_preferences` - per player, must get / rather gets / rather not /
  must not get the pairing-allocated bye (not a FIDE rule). One test per
  setting and per conflict; `Ainalrami.ByePreferenceValidationTest` holds
  the settings to the brute-force reference on generated tournaments.
  """

  use ExUnit.Case, async: true

  alias Ainalrami.ByePreference
  alias Ainalrami.Pairing
  alias Ainalrami.ByePreference.RefusedError
  alias Ainalrami.Pairing.NoValidPairingError

  describe "must get the bye (:want_hard)" do
    test "gets it on the bye score" do
      players = round_two_field()
      assert bye(Pairing.pair_next_round(players)) == 5

      {pairs, report} = ByePreference.pair(players, bye_preferences: [{4, :want_hard}])
      assert bye(pairs) == 4
      assert seated(pairs) == [1, 2, 3, 4, 5]
      assert report.moved and report.decided_by == :want_hard
      assert report.fide_bye == 5 and report.bye == 4
      assert [%{rank: 4, preference: :want_hard, outcome: :honoured}] = report.outcomes
      assert Pairing.pair_next_round(players, bye_preferences: [{4, :want_hard}]) == pairs
    end

    test "gets it above the bye score too - only the absolute criteria bind a hard want" do
      {pairs, report} = ByePreference.pair(round_two_field(), bye_preferences: [{1, :want_hard}])
      assert bye(pairs) == 1
      assert seated(pairs) == [1, 2, 3, 4, 5]
      assert report.exclusions == [2, 3, 4, 5]
      assert report.opts[:bye_exclusions] == [2, 3, 4, 5]
      refute Keyword.has_key?(report.opts, :bye_preferences)
    end

    test "a player who would have had the bye anyway: nothing moves" do
      players = round_two_field()
      {pairs, report} = ByePreference.pair(players, bye_preferences: [{5, :want_hard}])
      assert pairs == Pairing.pair_next_round(players)
      refute report.moved
      assert report.decided_by == nil
      assert [%{outcome: :honoured}] = report.outcomes
    end

    test "no legal round gives them the bye: paired as without the wish, and said why" do
      # 2 may meet nobody but 1, so a bye for 1 leaves 2 unpaired.
      opts = [forbidden_pairs: [[2, 3], [2, 4], [2, 5]]]
      plain = Pairing.pair_next_round(field(5), opts)

      {pairs, report} = ByePreference.pair(field(5), opts ++ [bye_preferences: [{1, :want_hard}]])
      assert pairs == plain
      refute report.moved
      assert [%{rank: 1, outcome: :unpairable}] = report.outcomes
      assert hd(ByePreference.describe(report)) =~ "no legal round gives this player the bye"
    end

    test "only in the rounds it is set for" do
      players = round_two_field()
      {pairs, report} = ByePreference.pair(players, bye_preferences: [{4, :want_hard, [3, 5]}])
      assert pairs == Pairing.pair_next_round(players)
      assert report.outcomes == []

      {pairs, _} = ByePreference.pair(players, bye_preferences: [{4, :want_hard, [2]}])
      assert bye(pairs) == 4
    end
  end

  describe "rather gets the bye (:want_soft)" do
    test "gets it when on the bye score" do
      {pairs, report} = ByePreference.pair(round_two_field(), bye_preferences: [{4, :want_soft}])
      assert bye(pairs) == 4
      assert report.decided_by == :want_soft
      assert [%{outcome: :honoured}] = report.outcomes
    end

    test "never moves the bye to a higher score" do
      players = round_two_field()
      {pairs, report} = ByePreference.pair(players, bye_preferences: [{1, :want_soft}])
      assert pairs == Pairing.pair_next_round(players)
      refute report.moved
      assert [%{rank: 1, outcome: :outranked}] = report.outcomes
    end

    test "never makes a round unpairable" do
      opts = [forbidden_pairs: [[2, 3], [2, 4], [2, 5]]]
      {pairs, report} = ByePreference.pair(field(5), opts ++ [bye_preferences: [{1, :want_soft}]])
      assert pairs == Pairing.pair_next_round(field(5), opts)
      assert [%{outcome: :outranked}] = report.outcomes
    end
  end

  describe "rather not the bye (:avoid_soft)" do
    test "the next player on the bye score takes it" do
      {pairs, report} = ByePreference.pair(round_two_field(), bye_preferences: [{5, :avoid_soft}])
      assert bye(pairs) == 4
      assert report.decided_by == :avoid_soft
      assert [%{rank: 5, outcome: :honoured}] = report.outcomes
    end

    test "is overruled when nobody else on the bye score can take it" do
      players = round_two_field()

      {pairs, report} =
        ByePreference.pair(players, bye_preferences: [{4, :avoid_soft}, {5, :avoid_soft}])

      # Passing over 5 is free; passing over 4 too would lift the bye to a
      # one-point player, which C5 ranks above the wish.
      assert bye(pairs) == 4
      assert report.decided_by == :avoid_soft

      assert [%{rank: 4, outcome: :outranked}, %{rank: 5, outcome: :honoured}] =
               report.outcomes
    end
  end

  describe "must not get the bye (:avoid_hard)" do
    test "is the organiser's bye exclusion" do
      players = round_two_field()
      {pairs, report} = ByePreference.pair(players, bye_preferences: [{5, :avoid_hard}])
      assert pairs == Pairing.pair_next_round(players, bye_exclusions: [5])
      assert report.exclusions == [5]
      assert [%{rank: 5, outcome: :honoured}] = report.outcomes
    end

    test "and refuses an impossible round the way an exclusion does" do
      error =
        assert_raise NoValidPairingError, fn ->
          Pairing.pair_next_round(round_two_field(),
            bye_preferences: Enum.map(1..5, &{&1, :avoid_hard})
          )
        end

      assert error.reason == :bye_exclusions
    end
  end

  describe "conflicts" do
    test "two players must get it: the FIDE criteria choose between them" do
      {pairs, report} =
        ByePreference.pair(round_two_field(), bye_preferences: [{1, :want_hard}, {4, :want_hard}])

      assert bye(pairs) == 4, "the lower score, as C5 would pick"

      assert [%{rank: 1, outcome: :other_player, holder: 4}, %{rank: 4, outcome: :honoured}] =
               report.outcomes
    end

    test "must get it, on an even field: there is no bye" do
      plain = Pairing.pair_next_round(field(6))
      {pairs, report} = ByePreference.pair(field(6), bye_preferences: [{6, :want_hard}])
      assert pairs == plain
      refute report.moved
      assert [%{outcome: :no_bye_this_round}] = report.outcomes
    end

    test "must get it, having already had a pairing-allocated bye: the round is refused" do
      players = round_two_field()

      error =
        assert_raise RefusedError, fn ->
          Pairing.pair_next_round(players, bye_preferences: [{3, :want_hard}])
        end

      assert error.round == 2
      assert error.players == [%{rank: 3, reason: :pairing_bye, round: 1}]
      assert error.message =~ "#3 must get the pairing-allocated bye"
      assert error.message =~ "(round 1)"
      assert error.message =~ "C2"

      # Only for that case: "rather gets it" is reported and the round paired,
      assert {pairs, report} = ByePreference.pair(players, bye_preferences: [{3, :want_soft}])
      assert pairs == Pairing.pair_next_round(players)
      assert [%{rank: 3, outcome: :ineligible, reason: :pairing_bye}] = report.outcomes

      # and an exclusion that overrules the want leaves nothing to refuse.
      assert {_pairs, report} =
               ByePreference.pair(players,
                 bye_exclusions: [3],
                 bye_preferences: [{3, :want_hard}]
               )

      assert [%{rank: 3, outcome: :conflict}] = report.outcomes
    end

    test "must get it with a second bye, on an even field: nothing to refuse" do
      # A sixth player who sat round one out: six in round two, no bye.
      sixth = %{player(6) | games: [%{opponent_rank: nil, colour: nil, result: "Z"}]}
      players = round_two_field() ++ [sixth]

      assert {_pairs, report} = ByePreference.pair(players, bye_preferences: [{3, :want_hard}])
      assert [%{rank: 3, outcome: :no_bye_this_round}] = report.outcomes
    end

    test "must get it and must not get it: the exclusion stands" do
      players = round_two_field()

      {pairs, report} =
        ByePreference.pair(players, bye_exclusions: [4], bye_preferences: [{4, :want_hard}])

      assert pairs == Pairing.pair_next_round(players, bye_exclusions: [4])
      assert [%{rank: 4, outcome: :conflict, with: :avoid_hard}] = report.outcomes

      {pairs2, report2} =
        ByePreference.pair(players, bye_preferences: [{4, :want_hard}, {4, :avoid_hard}])

      assert pairs2 == pairs

      assert Enum.any?(
               report2.outcomes,
               &match?(%{rank: 4, preference: :want_hard, outcome: :conflict}, &1)
             )
    end

    test "must get it beats rather not; rather gets and rather not cancel out" do
      players = round_two_field()

      {pairs, report} =
        ByePreference.pair(players, bye_preferences: [{4, :want_hard}, {4, :avoid_soft}])

      assert bye(pairs) == 4

      assert %{rank: 4, preference: :avoid_soft, outcome: :conflict, with: :want_hard} in report.outcomes

      {pairs, report} =
        ByePreference.pair(players, bye_preferences: [{4, :want_soft}, {4, :avoid_soft}])

      assert pairs == Pairing.pair_next_round(players)
      assert Enum.all?(report.outcomes, &(&1.outcome == :conflict))
    end

    test "a hard want decides over soft ones" do
      {pairs, report} =
        ByePreference.pair(round_two_field(),
          bye_preferences: [{4, :want_hard}, {5, :want_soft}]
        )

      assert bye(pairs) == 4

      assert %{rank: 5, outcome: :other_player, holder: 4} =
               Enum.find(report.outcomes, &(&1.rank == 5))
    end

    test "a player not paired this round" do
      players = six_with_one_sitting_out()
      {pairs, report} = ByePreference.pair(players, bye_preferences: [{6, :want_hard}])
      assert pairs == Pairing.pair_next_round(players)
      assert [%{rank: 6, outcome: :not_in_round}] = report.outcomes
    end
  end

  describe "why not me" do
    test "a player kept from the bye by another's preference is labelled so, not as the organiser's" do
      players = round_two_field()

      {pairs, report} =
        ByePreference.pair(players, bye_exclusions: [1], bye_preferences: [{4, :want_hard}])

      assert report.opts[:bye_preference_exclusions] == [2, 3, 5]
      eligibility = Pairing.bye_eligibility(players, report.opts)
      assert eligibility[1] == :organiser_exclusion
      assert eligibility[2] == :bye_preference
      assert eligibility[5] == :bye_preference
      assert eligibility[3] == :pairing_bye

      alternatives = Ainalrami.Alternatives.bye_alternatives(players, pairs, report.opts)
      assert %{rank: 5, outcome: :ineligible, reason: :bye_preference} in alternatives.candidates
    end
  end

  describe "the option" do
    test "absent or empty: exactly the plain pairing" do
      players = round_two_field()

      assert Pairing.pair_next_round(players, bye_preferences: []) ==
               Pairing.pair_next_round(players)
    end

    test "anything malformed is refused" do
      for bad <- [[{4, :want}], [{"4", :want_hard}], [{4, :want_hard, [:x]}], 4] do
        assert_raise ArgumentError, ~r/bye_preferences/, fn ->
          Pairing.pair_next_round(round_two_field(), bye_preferences: bad)
        end
      end
    end

    test "explain_round/3 resolves them and carries the account on the bye's bracket" do
      players = round_two_field()
      opts = [bye_preferences: [{4, :want_soft}]]
      pairs = Pairing.pair_next_round(players, opts)
      reports = Pairing.explain_round(players, pairs, opts)

      assert [%{bye_preference: account}] =
               Enum.filter(reports, &Map.has_key?(&1, :bye_preference))

      assert account.bye == 4 and account.decided_by == :want_soft

      {_pairs, report} = ByePreference.pair(players, opts)
      plain = Pairing.explain_round(players, pairs, report.opts ++ [bye_passed_over: false])
      assert Enum.map(reports, &Map.delete(&1, :bye_preference)) == plain
    end

    test "the lower-level explanation refuses them unresolved" do
      assert_raise ArgumentError, ~r/resolve :bye_preferences/, fn ->
        Pairing.explain_context(round_two_field(), bye_preferences: [{4, :want_soft}])
      end
    end

    test "describe/1 says what happened to each" do
      {_pairs, report} =
        ByePreference.pair(round_two_field(),
          bye_preferences: [{4, :want_soft}, {3, :want_soft}]
        )

      assert [three, four] = ByePreference.describe(report)
      assert three =~ "#3 (rather gets the bye)" and three =~ "C2"
      assert four =~ "#4 (rather gets the bye): receives the pairing-allocated bye"
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

  # Six after round one, 6 with a half-point bye already recorded for
  # round two: five are paired, so the round has a bye and 6 is not in it.
  defp six_with_one_sitting_out do
    [
      played(1, [{4, "w", "1"}]),
      played(2, [{5, "b", "1"}]),
      played(3, [{6, "w", "1"}]),
      played(4, [{1, "b", "0"}]),
      played(5, [{2, "w", "0"}]),
      %{
        player(6)
        | points: 0.5,
          games: [
            %{opponent_rank: 3, colour: "b", result: "0"},
            %{opponent_rank: nil, colour: nil, result: "H"}
          ]
      }
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
end
