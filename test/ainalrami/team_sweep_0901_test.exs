defmodule Ainalrami.TeamSweep0901Test do
  @moduledoc """
  Sweep 2026-09-01, H6 and M5 - the team engine's two edges.

  H6: `Bracket.pair/2`'s candidate budget counts COMPLETE legal pairings, so
  on a bracket that has none it never counts anything and the walk is bounded
  only by the pruning. Measured before the fix: 300 ms at sixteen teams,
  10.4 s at twenty.

  M5: three public functions that crashed on caller input rather than saying
  what was wrong with it.
  """
  use ExUnit.Case, async: true

  alias Ainalrami.TeamPairing
  alias Ainalrami.TeamPairing.{Bracket, Colour, Team}

  defp team(tpn, fields \\ []) do
    struct(%Team{tpn: tpn, match_points: 0.0, game_points: 0.0}, fields)
  end

  # `clique` teams that have all met each other can only be paired outside the
  # clique; with `clique > n - clique` that is impossible by pigeonhole, so no
  # legal pairing exists and no candidate is ever scored. This is the shape
  # the sweep measured.
  defp infeasible_bracket(n, clique) do
    for tpn <- 1..n do
      opponents = if tpn <= clique, do: Enum.reject(1..clique, &(&1 == tpn)), else: []
      team(tpn, opponents: opponents)
    end
  end

  describe "H6 - the walk budget" do
    test "an infeasible twenty-team bracket is proved impossible quickly instead of grinding" do
      # Since 2026-09-25 the walk is only a fast path capped at 20,000 steps;
      # past it a maximum matching answers, so this is now a proof rather
      # than a spent budget, whatever `:max_steps` says.
      teams = infeasible_bracket(20, 11)

      {microseconds, result} =
        :timer.tc(fn -> Bracket.pair(teams, max_steps: 200_000) end)

      assert result == {:error, :no_legal_pairing}

      # A canary for the pre-fix grind (12.5 s here), not a runner benchmark.
      assert microseconds < 5_000_000, "took #{div(microseconds, 1000)} ms"
    end

    test "budget exhaustion is distinguishable from no legal pairing" do
      # The same shape, small enough that the walk finishes inside the budget:
      # the answer is then the PROOF that nothing is legal, not a shrug.
      teams = infeasible_bracket(6, 4)

      assert Bracket.pair(teams, max_steps: 10_000_000) == {:error, :no_legal_pairing}
    end

    test "a legal forty-team round-one bracket still pairs, well inside the default" do
      teams = for tpn <- 1..40, do: team(tpn)

      assert {:ok, result} = Bracket.pair(teams)
      assert length(result.pairs) == 20
      assert result.scores == {0, 0, 0}
      assert result.exhaustive?
      assert result.steps < 10_000
      assert result.steps == 402
    end

    test "a legal bracket with a rematch to route around still pairs" do
      # 1 has met 2, so the identifier-first candidate is illegal and the walk
      # has to move on - but an answer exists and is found.
      teams = [
        team(1, opponents: [2], colours: [:white]),
        team(2, opponents: [1], colours: [:black]),
        team(3, colours: [:black]),
        team(4, colours: [:white])
      ]

      assert {:ok, result} = Bracket.pair(teams)
      assert {1, 2} not in result.pairs
      assert length(result.pairs) == 2
    end

    test "pair_round/2 still accepts the walk budget, and no longer runs out of it" do
      # A legal twenty-team round one with a budget too small to finish even
      # the first candidate. This was `{:error, :budget_exhausted}` until
      # 2026-09-25; 3.6 no longer uses `:max_steps`, so it pairs.
      teams = for tpn <- 1..20, do: team(tpn)

      assert {:ok, round} = TeamPairing.pair_round(teams, max_steps: 5)
      assert round == elem(TeamPairing.pair_round(teams), 1)
    end

    test "pair_round/2 proves the infeasible twenty-team field impossible instead of walking it" do
      # 3.5's legality check asks the completion oracle about the whole
      # field first, and the oracle answers this shape outright - so the
      # answer is the proof, not a spent budget.
      teams = infeasible_bracket(20, 11)

      {microseconds, result} =
        :timer.tc(fn -> TeamPairing.pair_round(teams, max_steps: 200_000) end)

      assert result == {:error, :no_legal_pairing}
      assert microseconds < 5_000_000, "took #{div(microseconds, 1000)} ms"
    end
  end

  describe "M5 - Team.score/2 and secondary_score/2" do
    test "an unknown score mode is named back" do
      t = team(1, match_points: 3.0, game_points: 9.5)

      assert_raise ArgumentError, ~r/:board_points/, fn -> Team.score(t, :board_points) end

      assert_raise ArgumentError, ~r/:board_points/, fn ->
        Team.secondary_score(t, :board_points)
      end
    end

    test "the two modes it does have still work" do
      t = team(1, match_points: 3.0, game_points: 9.5)

      assert Team.score(t, :match_points) == 3.0
      assert Team.score(t, :game_points) == 9.5
      assert Team.secondary_score(t, :match_points) == 9.5
      assert Team.secondary_score(t, :game_points) == 3.0
    end
  end

  describe "M5 - pair_round/2's score mode" do
    test "an unknown score mode is an error tuple, as the docs promise" do
      teams = for tpn <- 1..4, do: team(tpn)

      assert {:error, {:invalid_option, :score_mode, :board_points}} =
               TeamPairing.pair_round(teams, score_mode: :board_points)
    end

    test "a known score mode still pairs" do
      teams = for tpn <- 1..4, do: team(tpn)

      assert {:ok, %{pairs: pairs}} = TeamPairing.pair_round(teams, score_mode: :game_points)
      assert length(pairs) == 2
    end
  end

  describe "M5 - Colour.allocate/3's parity numbers" do
    test "a numbering that omits one of the two teams is named, not a Map.fetch! crash" do
      a = team(1)
      b = team(2)

      assert_raise ArgumentError, ~r/:parity_numbers/, fn ->
        Colour.allocate(a, b, parity_numbers: %{1 => 1})
      end
    end

    test "a numbering covering both teams is used" do
      a = team(1)
      b = team(2)

      assert {%Team{tpn: first}, %Team{tpn: second}} =
               Colour.allocate(a, b, parity_numbers: %{1 => 1, 2 => 2})

      assert Enum.sort([first, second]) == [1, 2]
    end

    test "no numbering at all still defaults to the two-team one" do
      assert {%Team{}, %Team{}} = Colour.allocate(team(1), team(2))
    end
  end
end
