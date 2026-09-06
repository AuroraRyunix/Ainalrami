defmodule Ainalrami.AlternativesTest do
  @moduledoc """
  `Ainalrami.Alternatives` - "why not THAT instead", built by scoring the
  alternative with `explain_round/3` and comparing. The rosters here are
  small enough that the right answer can be worked out by hand, which is
  the only way to test a verdict.
  """

  use ExUnit.Case, async: true

  alias Ainalrami.{Alternatives, Pairing}

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

  defp win(opponent, colour), do: %{result: "1", colour: colour, opponent_rank: opponent}
  defp loss(opponent, colour), do: %{result: "0", colour: colour, opponent_rank: opponent}
  defp bye(code), do: %{result: code, colour: nil, opponent_rank: nil}
  defp forfeit_win(opponent), do: %{result: "+", colour: nil, opponent_rank: opponent}

  # Six players after two rounds (the roster `explain_round_test.exs` uses):
  # 1 and 5 on 2.0 are both absolutely due Black, 3 and 4 on 1.0 met in
  # round 1 - so neither top bracket can pair internally and somebody has to
  # float.
  defp roster do
    [
      player(1, 2.0, [win(2, "w"), win(3, "w")]),
      player(2, 0.0, [loss(1, "b"), loss(5, "b")]),
      player(3, 1.0, [win(4, "w"), loss(1, "b")]),
      player(4, 1.0, [loss(3, "b"), win(6, "w")]),
      player(5, 2.0, [win(6, "w"), win(2, "w")]),
      player(6, 0.0, [loss(5, "b"), loss(4, "b")])
    ]
  end

  @opts [expected_rounds: 9]

  describe "violations/1" do
    test "a proposal that breaks the absolute rules is named, pair by pair" do
      # 1-5: both absolutely due Black. 2-6: both absolutely due White. 3-4:
      # met in round 1. The proposal manages to break a rule on every board.
      report = Pairing.explain_round(roster(), [{1, 5}, {3, 4}, {2, 6}], @opts)

      assert [
               %{players: [1, 5], reason: :colour, colour: "b", group: 2.0},
               %{players: [2, 6], reason: :colour, colour: "w", group: 0.0},
               %{players: [3, 4], reason: :rematch, round: 1, group: 1.0}
             ] = Enum.sort_by(Alternatives.violations(report), & &1.players)
    end

    test "the engine's own pairing never violates anything" do
      pairs = Pairing.pair_next_round(roster(), @opts)
      assert Alternatives.violations(Pairing.explain_round(roster(), pairs, @opts)) == []
    end
  end

  describe "compare/2" do
    test "a pairing compared with itself is identical" do
      report = Pairing.explain_round(roster(), Pairing.pair_next_round(roster(), @opts), @opts)
      assert Alternatives.compare(report, report) == :identical
    end

    test "an alternative that differs is placed at the first bracket and rung that separates them" do
      actual = Pairing.pair_next_round(roster(), @opts)
      actual_report = Pairing.explain_round(roster(), actual, @opts)
      # The illegal proposal: legal-or-not, the ladder still scores it.
      other = Pairing.explain_round(roster(), [{1, 5}, {3, 4}, {2, 6}], @opts)

      assert {kind, 2.0, _label, _ours, _theirs} = Alternatives.compare(actual_report, other)
      assert kind in [:worse, :better]
    end
  end

  describe "judge/4" do
    test "carries the verdict, the violations and the alternative's report together" do
      actual = Pairing.pair_next_round(roster(), @opts)
      judged = Alternatives.judge(roster(), actual, [{1, 5}, {3, 4}, {2, 6}], @opts)

      assert length(judged.violations) == 3
      assert is_list(judged.report)
      refute judged.verdict == :identical
    end
  end

  describe "float_alternatives/3 - why HIM and not me" do
    test "every other member of a floating bracket gets a verdict, and none beats the engine" do
      pairs = Pairing.pair_next_round(roster(), @opts)
      alternatives = Alternatives.float_alternatives(roster(), pairs, @opts)

      # Both upper brackets are odd once their one internal pair is
      # forbidden, so at least one player floats.
      assert alternatives != []

      for %{floater: floater, candidates: candidates} = entry <- alternatives do
        refute Map.has_key?(entry, :skipped)
        refute floater in Enum.map(candidates, & &1.rank)

        for c <- candidates do
          assert c.outcome in [:impossible, :worse, :tie, :same, :incomparable],
                 "#{c.rank} instead of #{floater}: #{inspect(c)}"
        end
      end
    end

    test "the pairing-allocated bye is not treated as a float" do
      five = for r <- 1..5, do: player(r, 0.0, [])
      pairs = Pairing.pair_next_round(five, @opts)

      assert Alternatives.float_alternatives(five, pairs, @opts) == []
    end
  end

  describe "bye_alternatives/3 - why did HE get the bye" do
    test "round one of five: the bye goes to the last seed, and every other candidate is worse or impossible" do
      five = for r <- 1..5, do: player(r, 0.0, [])
      pairs = Pairing.pair_next_round(five, @opts)

      assert %{holder: 5, candidates: candidates} =
               Alternatives.bye_alternatives(five, pairs, @opts)

      assert Enum.map(candidates, & &1.rank) == [1, 2, 3, 4]

      for c <- candidates do
        assert c.outcome in [:worse, :impossible, :tie], inspect(c)
      end
    end

    test "a player who already had the bye is ineligible, and is not searched" do
      # Round 2 of five: 5 took the bye in round 1, so C.2 rules them out.
      five = [
        player(1, 1.0, [win(3, "w")]),
        player(2, 1.0, [win(4, "b")]),
        player(3, 0.0, [loss(1, "b")]),
        player(4, 0.0, [loss(2, "w")]),
        player(5, 1.0, [bye("U")])
      ]

      pairs = Pairing.pair_next_round(five, @opts)

      %{holder: holder, candidates: candidates} =
        Alternatives.bye_alternatives(five, pairs, @opts)

      refute holder == 5

      if Enum.any?(candidates, &(&1.rank == 5)) do
        assert %{outcome: :ineligible, reason: :pairing_bye} =
                 Enum.find(candidates, &(&1.rank == 5))
      end
    end

    test "an even field has no bye and nothing to say" do
      pairs = Pairing.pair_next_round(roster(), @opts)
      assert Alternatives.bye_alternatives(roster(), pairs, @opts) == nil
    end
  end

  describe "Pairing.bye_eligibility/2" do
    test "names C.2's three disqualifications and nothing else" do
      players = [
        player(1, 1.0, [bye("U")]),
        player(2, 1.0, [forfeit_win(9)]),
        player(3, 1.0, [bye("F")]),
        player(4, 0.5, [bye("H")]),
        player(5, 0.0, [bye("Z")]),
        player(6, 1.0, [win(7, "w")])
      ]

      assert Pairing.bye_eligibility(players) == %{
               1 => :pairing_bye,
               2 => :forfeit_win,
               3 => :full_point_bye,
               4 => nil,
               5 => nil,
               6 => nil
             }
    end
  end
end
