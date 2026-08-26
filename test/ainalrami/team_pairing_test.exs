defmodule Ainalrami.TeamPairingTest do
  @moduledoc """
  C.04.6 team pairing.

  ## The oracle here is the regulation itself

  For the individual system there is no way to test a whole round against a
  definition, because C.04.3 defines a sequential procedure rather than a
  global optimum - "which whole-round pairing is best" is a question with no
  defined answer, which is why that engine's credibility rests on agreeing
  with bbpPairings across hundreds of millions of pairings instead.

  C.04.6 3.6 is the opposite. It defines the answer AS the first element of
  an enumerable order. So for a bracket small enough to enumerate, the test
  can BE the definition: generate every pairing, sort by identifier, take the
  first that complies, assert the engine returns it. That is a proof, and it
  needs nobody else to have implemented the rules - which is just as well,
  since nobody readable has (bbpPairings, JaVaFo and Gacrux have no team
  code; Swiss-Manager is closed-source).

  `reference_pair/2` below is that brute-force definition. It is written to
  be obviously correct rather than fast, and it is never allowed to share
  code with the engine - a shared helper would make both wrong together,
  which is the exact failure this project has hit before with harnesses that
  quietly agreed with the thing they were checking.
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias Ainalrami.TeamPairing
  alias Ainalrami.TeamPairing.{Bracket, Colour, Matching, Team}

  defp team(tpn, opts \\ []) do
    %Team{
      tpn: tpn,
      match_points: Keyword.get(opts, :mp, 0.0),
      game_points: Keyword.get(opts, :gp, 0.0),
      opponents: Keyword.get(opts, :opponents, []),
      colours: Keyword.get(opts, :colours, []),
      had_pab?: Keyword.get(opts, :pab, false),
      won_by_forfeit?: Keyword.get(opts, :forfeit_win, false),
      floated_last_round?: Keyword.get(opts, :floated, false)
    }
  end

  # ------------------------------------------------------------------
  # Article 1 - definitions
  # ------------------------------------------------------------------

  describe "colour difference (1.6)" do
    test "counts played matches only, White minus Black" do
      assert Team.colour_difference(team(1, colours: [:white, :white, :black])) == 1
      assert Team.colour_difference(team(1, colours: [])) == 0
      assert Team.colour_difference(team(1, colours: [:black, :black])) == -2
    end
  end

  describe "Type A colour preference (1.7.1)" do
    test "White when CD is less than -1" do
      assert Team.preference(team(1, colours: [:black, :black]), :a) == {:white, :strong}
    end

    test "Black when CD is more than +1" do
      assert Team.preference(team(1, colours: [:white, :white]), :a) == {:black, :strong}
    end

    test "White when CD is 0 or -1 and the last two played were Black" do
      # CD 0: W B B W -> no. Need last two Black with CD 0 or -1.
      t = team(1, colours: [:white, :white, :black, :black])
      assert Team.colour_difference(t) == 0
      assert Team.preference(t, :a) == {:white, :strong}
    end

    test "no preference otherwise" do
      assert Team.preference(team(1, colours: [:white, :black]), :a) == :none
      assert Team.preference(team(1, colours: []), :a) == :none
    end

    test "never produces a mild preference - 1.7.1 has no such thing" do
      for colours <- [[], [:white], [:black], [:white, :black], [:black, :white, :black]] do
        pref = Team.preference(team(1, colours: colours), :a)

        refute match?({_, :mild}, pref),
               "Type A produced a mild preference for #{inspect(colours)}"
      end
    end
  end

  describe "Type B colour preference (1.7.2)" do
    test "its strong conditions are Type A's, word for word" do
      # Not a restatement of the implementation - a reading of the text. If
      # these ever diverge, one of the two was edited alone.
      for colours <- [
            [],
            [:white],
            [:black],
            [:white, :white],
            [:black, :black],
            [:white, :black],
            [:white, :white, :black],
            [:black, :black, :white, :white]
          ] do
        a = Team.preference(team(1, colours: colours), :a)
        b = Team.preference(team(1, colours: colours), :b)

        if a != :none do
          assert a == b,
                 "Type A said #{inspect(a)} but Type B said #{inspect(b)} for #{inspect(colours)}"
        end
      end
    end

    test "mild White at CD -1, mild Black at CD +1" do
      assert Team.preference(team(1, colours: [:black]), :b) == {:white, :mild}
      assert Team.preference(team(1, colours: [:white]), :b) == {:black, :mild}
    end

    test "mild from the last played colour when CD is zero and it is not the last round" do
      t = team(1, colours: [:white, :black])
      assert Team.colour_difference(t) == 0
      assert Team.preference(t, :b, false) == {:white, :mild}
    end

    test "none when CD is zero and it IS the last round" do
      t = team(1, colours: [:white, :black])
      assert Team.preference(t, :b, true) == :none
    end

    test "none when the team has yet to play" do
      assert Team.preference(team(1, colours: []), :b, false) == :none
    end
  end

  # ------------------------------------------------------------------
  # Article 3.6 - the identifier and the enumeration order
  # ------------------------------------------------------------------

  describe "the pairing identifier (3.6.2)" do
    test "the regulation's own example" do
      # "If 11-24 16-6 10-9 8-4 is a pairing, its identifier is
      #  4 6 9 11 8 16 10 24."
      pairs = [{11, 24}, {16, 6}, {10, 9}, {8, 4}]
      assert identifier(pairs) == [4, 6, 9, 11, 8, 16, 10, 24]
    end
  end

  describe "bracket pairing (3.6) against exhaustive enumeration" do
    test "round one, eight teams, no history: the natural pairing" do
      teams = for n <- 1..8, do: team(n)
      {:ok, result} = Bracket.pair(teams)

      # With no history and no preferences every pairing complies, so 3.6.3
      # decides alone: the smallest identifier is tops 1,2,3,4 with bottoms
      # 5,6,7,8 in order.
      assert result.pairs == [{1, 5}, {2, 6}, {3, 7}, {4, 8}]
      assert result.scores == {0, 0, 0}
      assert result.exhaustive?
      assert result.candidates == 1, "should have stopped at the first candidate"
    end

    test "matches brute force across many random histories" do
      for seed <- 1..60 do
        :rand.seed(:exsss, {seed, seed * 7, seed * 13})
        size = Enum.random([4, 6, 8])
        teams = random_bracket(size)

        {:ok, result} = Bracket.pair(teams, type: :b)
        expected = reference_pair(teams, type: :b)

        assert result.pairs == expected,
               """
               seed #{seed}, #{size} teams: engine and definition disagree.
                 engine:     #{inspect(result.pairs)}
                 definition: #{inspect(expected)}
                 teams:      #{inspect(Enum.map(teams, &{&1.tpn, &1.colours, &1.opponents}))}
               """
      end
    end

    test "refuses when [C1] admits no pairing at all" do
      # Four teams, everyone has played everyone.
      teams = [
        team(1, opponents: [2, 3, 4]),
        team(2, opponents: [1, 3, 4]),
        team(3, opponents: [1, 2, 4]),
        team(4, opponents: [1, 2, 3])
      ]

      assert Bracket.pair(teams) == {:error, :no_legal_pairing}
    end

    test "an odd bracket is a caller error, not a pairing outcome (1.3.2)" do
      assert_raise ArgumentError, ~r/even number of teams/, fn ->
        Bracket.pair([team(1), team(2), team(3)])
      end
    end
  end

  # ------------------------------------------------------------------
  # Article 3.4 - the bye
  # ------------------------------------------------------------------

  describe "pairing-allocated bye (3.4)" do
    test "lowest score first (3.4.2)" do
      teams = [team(1, mp: 2.0), team(2, mp: 1.0), team(3, mp: 0.0)]
      {:ok, bye, rest} = TeamPairing.assign_bye(teams)

      assert bye.tpn == 3
      assert Enum.map(rest, & &1.tpn) == [1, 2]
    end

    test "then most matches played (3.4.3)" do
      teams = [
        team(1, mp: 1.0),
        team(2, mp: 0.0, colours: [:white]),
        team(3, mp: 0.0, colours: [:white, :black])
      ]

      {:ok, bye, _} = TeamPairing.assign_bye(teams)
      assert bye.tpn == 3
    end

    test "then largest TPN (3.4.4)" do
      teams = [team(1, mp: 0.0), team(2, mp: 0.0), team(3, mp: 1.0)]
      {:ok, bye, _} = TeamPairing.assign_bye(teams)
      assert bye.tpn == 2
    end

    test "[C2] excludes a team that already had one (2.1.2)" do
      teams = [team(1, mp: 1.0), team(2, mp: 0.0), team(3, mp: 0.0, pab: true)]
      {:ok, bye, _} = TeamPairing.assign_bye(teams)

      assert bye.tpn == 2, "the team holding a previous PAB must not receive another"
    end

    test "[C2] also excludes a forfeit win (2.1.2)" do
      teams = [team(1, mp: 1.0), team(2, mp: 0.0), team(3, mp: 0.0, forfeit_win: true)]
      {:ok, bye, _} = TeamPairing.assign_bye(teams)
      assert bye.tpn == 2
    end

    test "3.4.1 outranks the tie-breaks: a bye that strands the rest is not taken" do
      # 1,2,3 have all played each other; 4 and 5 have not played anyone.
      # Byeing 5 (lowest score, largest TPN) would leave 1,2,3,4 where
      # 1,2,3 can only play 4 - unpairable. Byeing 4 leaves 1,2,3,5 which
      # pairs as 1-5 and ... 2-3? No, they have met. So the only legal bye
      # is one of 1,2,3.
      teams = [
        team(1, mp: 0.0, opponents: [2, 3]),
        team(2, mp: 0.0, opponents: [1, 3]),
        team(3, mp: 0.0, opponents: [1, 2]),
        team(4, mp: 0.0),
        team(5, mp: 0.0)
      ]

      {:ok, bye, rest} = TeamPairing.assign_bye(teams)

      {mask, adj} = adjacency(rest)
      assert Matching.feasible?(mask, adj), "3.4.1 requires the remainder to be pairable"
      assert bye.tpn in [1, 2, 3]
    end

    test "an even field takes no bye" do
      teams = for n <- 1..4, do: team(n)
      assert {:ok, nil, ^teams} = TeamPairing.assign_bye(teams)
    end
  end

  # ------------------------------------------------------------------
  # Article 3.5 - upfloater selection
  # ------------------------------------------------------------------

  describe "upfloater selection (3.5)" do
    test "an even scoregroup floats nobody - [C4] minimises the count" do
      residents = [team(1, mp: 1.0), team(2, mp: 1.0)]
      lower = [team(3, mp: 0.0)]

      assert {:ok, []} = TeamPairing.select_upfloaters(residents, lower, :match_points)
    end

    test "[C4] takes ONE upfloater for an odd scoregroup, not more" do
      # Minimise the number (2.3.1). Three residents need one upfloater to
      # make four, and [C5] then maximises its score - so the 3.0 group wins
      # over the 2.5 group, and 3.5.4's lexicographic order picks the
      # smallest TPN within it.
      residents = [team(10, mp: 4.0), team(11, mp: 4.0), team(12, mp: 4.0)]

      lower = [
        team(2, mp: 3.0),
        team(6, mp: 3.0),
        team(8, mp: 3.0),
        team(1, mp: 2.5),
        team(3, mp: 2.5),
        team(5, mp: 2.5)
      ]

      {:ok, set} = TeamPairing.select_upfloaters(residents, lower, :match_points)
      assert Enum.map(set, & &1.tpn) == [2]
    end

    test "3.5.4 orders candidate sets lexicographically by TPN" do
      # The regulation's example: "Let's assume that 2,6,8 have 3 points, and
      # 1,3,5 have 2.5 points. [C4] determines that a set of three upfloaters
      # is needed, and [C5] determines that two upfloaters must have 3 points
      # and the other 2.5. The possible set of upfloaters are: {2,6,1} <
      # {2,6,3} < {2,6,5} < {2,8,1} < ..."
      #
      # Its ORDERING is what this asserts, and the ordering is unambiguous.
      # Its score profile is not: with 2, 6 and 8 all on 3 points, [C5] -
      # "minimise the score differences ... i.e. maximise the scores of the
      # upfloaters" - reads as taking all three 3-pointers, which would make
      # the profile 3/3/3 rather than the 3/3/2.5 the example asserts. The
      # example states that step rather than deriving it, so the text alone
      # does not settle it (see docs/conformance-c0406-teams.md).
      #
      # So the position here has only 2 and 6 on 3 points, which forces the
      # 3/3/2.5 profile the example describes and leaves exactly its first
      # three sets: {2,6,1} < {2,6,3} < {2,6,5}. Three upfloaters are needed
      # because the residents have all played each other, so each can only
      # face an upfloater.
      residents = [
        team(10, mp: 4.0, opponents: [11, 12]),
        team(11, mp: 4.0, opponents: [10, 12]),
        team(12, mp: 4.0, opponents: [10, 11])
      ]

      lower = [
        team(2, mp: 3.0),
        team(6, mp: 3.0),
        team(1, mp: 2.5),
        team(3, mp: 2.5),
        team(5, mp: 2.5)
      ]

      {:ok, set} = TeamPairing.select_upfloaters(residents, lower, :match_points)

      assert Enum.map(set, & &1.tpn) == [2, 6, 1],
             "3.5.4's first set is {2,6,1}, ordered within itself by 3.5.3"
    end

    test "[C5] takes every top-scoring candidate when it can - the reading the example leaves open" do
      # Same shape, but with 8 on 3 points as well. This engine reads [C5] as
      # maximising the upfloaters' scores, so it takes 2, 6 and 8 rather than
      # dropping one for a 2.5-pointer. Asserted so the reading is pinned and
      # visible: if the SPP or a later edition says otherwise, this test is
      # the thing that fails and points at the decision.
      residents = [
        team(10, mp: 4.0, opponents: [11, 12]),
        team(11, mp: 4.0, opponents: [10, 12]),
        team(12, mp: 4.0, opponents: [10, 11])
      ]

      lower = [
        team(2, mp: 3.0),
        team(6, mp: 3.0),
        team(8, mp: 3.0),
        team(1, mp: 2.5),
        team(3, mp: 2.5),
        team(5, mp: 2.5)
      ]

      {:ok, set} = TeamPairing.select_upfloaters(residents, lower, :match_points)
      assert Enum.map(set, & &1.tpn) == [2, 6, 8]
    end

    test "[C5] takes the highest available scores, not the lowest TPNs" do
      residents = [team(10, mp: 4.0)]
      lower = [team(1, mp: 1.0), team(2, mp: 3.0), team(3, mp: 2.0)]

      {:ok, set} = TeamPairing.select_upfloaters(residents, lower, :match_points)

      assert Enum.map(set, & &1.tpn) == [2],
             "the upfloater's score must be maximised (2.3.2), so TPN 2 on 3.0 wins"
    end
  end

  # ------------------------------------------------------------------
  # Article 4 - colours
  # ------------------------------------------------------------------

  describe "first-team (4.2)" do
    test "higher primary score" do
      {first, _} = Colour.first_team(team(5, mp: 1.0), team(2, mp: 2.0))
      assert first.tpn == 2
    end

    test "then higher secondary score" do
      {first, _} = Colour.first_team(team(5, mp: 1.0, gp: 3.0), team(2, mp: 1.0, gp: 1.0))
      assert first.tpn == 5
    end

    test "then smaller TPN" do
      {first, _} = Colour.first_team(team(5, mp: 1.0, gp: 1.0), team(2, mp: 1.0, gp: 1.0))
      assert first.tpn == 2
    end

    test "the secondary score can be switched off (1.2.1)" do
      a = team(5, mp: 1.0, gp: 9.0)
      b = team(2, mp: 1.0, gp: 1.0)

      {first, _} = Colour.first_team(a, b, :match_points, false)
      assert first.tpn == 2, "with 4.2.2 disabled the tie falls to 4.2.3"
    end
  end

  describe "colour allocation (4.3)" do
    test "4.3.1 - odd TPN takes the initial colour in round one" do
      {white, black} = Colour.allocate(team(1, mp: 1.0), team(4, mp: 0.0), initial_colour: :white)
      assert {white.tpn, black.tpn} == {1, 4}
    end

    test "4.3.1 - even TPN takes the opposite" do
      # First-team is 2 (higher score) and its TPN is even.
      {white, black} = Colour.allocate(team(2, mp: 1.0), team(3, mp: 0.0), initial_colour: :white)
      assert {white.tpn, black.tpn} == {3, 2}
    end

    test "4.3.1 respects a Black initial colour" do
      {white, black} = Colour.allocate(team(1, mp: 1.0), team(4, mp: 0.0), initial_colour: :black)
      assert {white.tpn, black.tpn} == {4, 1}
    end

    test "4.3.2 - only one team has a preference, so grant it" do
      wants_white = team(1, mp: 1.0, colours: [:black, :black])
      neutral = team(2, mp: 0.0, colours: [:white, :black])

      {white, _} = Colour.allocate(wants_white, neutral)
      assert white.tpn == 1
    end

    test "4.3.3 - opposite preferences are both granted" do
      wants_white = team(1, mp: 1.0, colours: [:black, :black])
      wants_black = team(2, mp: 0.0, colours: [:white, :white])

      {white, black} = Colour.allocate(wants_white, wants_black)
      assert {white.tpn, black.tpn} == {1, 2}
    end

    test "4.3.5 - White to the LOWER colour difference, and -2 is lower than -1" do
      # Both want White; neither is strong-only, so 4.3.5 decides.
      a = team(1, mp: 1.0, colours: [:black, :black])
      b = team(2, mp: 0.0, colours: [:black, :black, :black])

      assert Team.colour_difference(a) == -2
      assert Team.colour_difference(b) == -3

      {white, _} = Colour.allocate(a, b)
      assert white.tpn == 2, "CD -3 is lower than CD -2, so team 2 takes White"
    end

    test "every allocation gives exactly one team each colour" do
      for seed <- 1..40 do
        :rand.seed(:exsss, {seed, 99, 7})
        [a, b] = random_bracket(2)

        {white, black} = Colour.allocate(a, b, type: :b)
        assert white.tpn != black.tpn
        assert Enum.sort([white.tpn, black.tpn]) == Enum.sort([a.tpn, b.tpn])
      end
    end
  end

  # ------------------------------------------------------------------
  # Whole rounds
  # ------------------------------------------------------------------

  describe "pair_round/2" do
    test "an even field, round one" do
      teams = for n <- 1..6, do: team(n)
      {:ok, round} = TeamPairing.pair_round(teams, round: 1, expected_rounds: 5)

      assert round.bye == nil
      assert length(round.pairs) == 3
      assert_legal_round(round, teams)
    end

    test "an odd field takes a bye and pairs the rest" do
      teams = for n <- 1..7, do: team(n)
      {:ok, round} = TeamPairing.pair_round(teams, round: 1, expected_rounds: 5)

      assert round.bye == 7, "no history, no scores: 3.4.4's largest TPN"
      assert length(round.pairs) == 3
      assert_legal_round(round, teams)
    end

    test "teams are split into brackets by score, highest first" do
      teams = [
        team(1, mp: 2.0),
        team(2, mp: 2.0),
        team(3, mp: 1.0),
        team(4, mp: 1.0),
        team(5, mp: 0.0),
        team(6, mp: 0.0)
      ]

      {:ok, round} = TeamPairing.pair_round(teams, round: 2, expected_rounds: 5)

      assert Enum.map(round.brackets, & &1.score) == [2.0, 1.0, 0.0]
      assert Enum.all?(round.brackets, &(&1.upfloaters == []))
      assert_legal_round(round, teams)
    end

    test "an odd scoregroup pulls an upfloater from below" do
      teams = [
        team(1, mp: 2.0),
        team(2, mp: 1.0),
        team(3, mp: 1.0),
        team(4, mp: 1.0),
        team(5, mp: 0.0),
        team(6, mp: 0.0)
      ]

      {:ok, round} = TeamPairing.pair_round(teams, round: 2, expected_rounds: 5)

      [top | _] = round.brackets
      assert top.residents == [1]
      assert length(top.upfloaters) == 1
      assert_legal_round(round, teams)
    end

    test "never repeats a pairing, across a simulated event" do
      # Nine rounds of eight teams, feeding each round's result back in.
      # [C1] is absolute, so a rematch anywhere is a hard failure.
      teams = for n <- 1..8, do: team(n)

      Enum.reduce(1..7, teams, fn round_no, teams ->
        {:ok, round} = TeamPairing.pair_round(teams, round: round_no, expected_rounds: 7)
        assert_legal_round(round, teams)
        apply_round(teams, round)
      end)
    end

    test "reports whether each bracket's search was exhaustive" do
      teams = for n <- 1..8, do: team(n)
      {:ok, round} = TeamPairing.pair_round(teams)

      assert Enum.all?(round.brackets, & &1.exhaustive?),
             "a small clean bracket must be provably optimal, not budget-limited"
    end
  end

  # ------------------------------------------------------------------
  # The completion oracle
  # ------------------------------------------------------------------

  describe "Matching.feasible?/2" do
    test "an empty set is trivially feasible" do
      assert Matching.feasible?(0, %{})
    end

    test "an odd set never is" do
      refute Matching.feasible?(0b111, %{0 => 0b110, 1 => 0b101, 2 => 0b011})
    end

    test "a complete graph always is" do
      for n <- [2, 4, 6, 8] do
        full = (1 <<< n) - 1
        adj = Map.new(0..(n - 1), fn i -> {i, full - (1 <<< i)} end)
        assert Matching.feasible?(full, adj), "K#{n} must be perfectly matchable"
      end
    end

    test "a path of four is matchable, a star of four is not" do
      # 0-1-2-3
      path = %{0 => 0b0010, 1 => 0b0101, 2 => 0b1010, 3 => 0b0100}
      assert Matching.feasible?(0b1111, path)

      # 0 at the centre, 1/2/3 as leaves: three leaves cannot be covered.
      star = %{0 => 0b1110, 1 => 0b0001, 2 => 0b0001, 3 => 0b0001}
      refute Matching.feasible?(0b1111, star)
    end

    test "greedy failing does not mean infeasible - the search must catch it" do
      # 0 can only pair 3; 1 and 2 pair each other or 3.
      # Greedy takes 0-1 first? No: 0's only partner is 3. Build a case where
      # the lowest index has a low-numbered partner that ruins the rest.
      # 0: {1,3}  1: {0,2}  2: {1,3}  3: {0,2}  - a 4-cycle.
      # Greedy pairs 0-1, leaving 2-3 which IS an edge, so it succeeds here.
      # Force failure: 0:{1,2} 1:{0} 2:{0,3} 3:{2}
      adj = %{0 => 0b0110, 1 => 0b0001, 2 => 0b1001, 3 => 0b0100}
      # Greedy: 0-1, then {2,3} which is an edge -> succeeds.
      assert Matching.feasible?(0b1111, adj)

      # Now one where greedy's first choice is fatal: 0:{1,3} 1:{0,2} 2:{1} 3:{0}
      # Greedy pairs 0-1 leaving {2,3} with no edge -> greedy fails.
      # The true answer: 0-3 and 1-2, so it IS feasible.
      adj2 = %{0 => 0b1010, 1 => 0b0101, 2 => 0b0010, 3 => 0b0001}

      assert Matching.feasible?(0b1111, adj2),
             "greedy picks 0-1 and strands 2 and 3; the exhaustive pass must find 0-3, 1-2"
    end
  end

  # ==================================================================
  # The brute-force definition of 3.6, and helpers
  # ==================================================================

  # Every pairing of the bracket, sorted by identifier (3.6.2/3.6.3), then
  # the first complying with [C1] and achieving the minimum {C8,C9,C10}
  # (3.6.4). Deliberately naive.
  defp reference_pair(teams, opts) do
    type = Keyword.get(opts, :type, :a)
    last_round? = Keyword.get(opts, :last_round?, false)
    by_tpn = Map.new(teams, &{&1.tpn, &1})
    tpns = teams |> Enum.map(& &1.tpn) |> Enum.sort()

    legal =
      tpns
      |> all_pairings()
      |> Enum.map(&normalise/1)
      |> Enum.filter(fn pairs ->
        Enum.all?(pairs, fn {a, b} -> not Team.met?(Map.fetch!(by_tpn, a), b) end)
      end)

    case legal do
      [] ->
        :none

      _ ->
        scored =
          Enum.map(legal, fn pairs ->
            {ref_criteria(pairs, by_tpn, type, last_round?), identifier(pairs), pairs}
          end)

        best = scored |> Enum.map(fn {c, _, _} -> c end) |> Enum.min()

        scored
        |> Enum.filter(fn {c, _, _} -> c == best end)
        |> Enum.min_by(fn {_, id, _} -> id end)
        |> elem(2)
    end
  end

  # {C8, C9, C10} computed independently of the engine. C10 is zero here
  # because these brackets have no upfloaters.
  defp ref_criteria(pairs, by_tpn, type, last_round?) do
    c8 =
      Enum.count(pairs, fn {a, b} ->
        pa = Team.preference(Map.fetch!(by_tpn, a), type, last_round?)
        pb = Team.preference(Map.fetch!(by_tpn, b), type, last_round?)
        same_colour?(pa, pb)
      end)

    c9 =
      if type == :b do
        Enum.count(pairs, fn {a, b} ->
          pa = Team.preference(Map.fetch!(by_tpn, a), type, last_round?)
          pb = Team.preference(Map.fetch!(by_tpn, b), type, last_round?)
          same_colour?(pa, pb) and Team.strong?(pa) and Team.strong?(pb)
        end)
      else
        0
      end

    {c8, c9, 0}
  end

  defp same_colour?(:none, _), do: false
  defp same_colour?(_, :none), do: false
  defp same_colour?({c, _}, {c, _}), do: true
  defp same_colour?(_, _), do: false

  # Every perfect matching of a sorted list, as a list of pair-lists.
  defp all_pairings([]), do: [[]]

  defp all_pairings([h | t]) do
    Enum.flat_map(t, fn partner ->
      rest = t -- [partner]
      Enum.map(all_pairings(rest), &[{h, partner} | &1])
    end)
  end

  # 3.6.1 - smaller TPN is the top member; 3.6.2 - tops ascending, then their
  # bottoms.
  defp normalise(pairs) do
    pairs
    |> Enum.map(fn {a, b} -> {min(a, b), max(a, b)} end)
    |> Enum.sort_by(fn {top, _} -> top end)
  end

  defp identifier(pairs) do
    ordered = normalise(pairs)
    Enum.map(ordered, &elem(&1, 0)) ++ Enum.map(ordered, &elem(&1, 1))
  end

  defp random_bracket(size) do
    for n <- 1..size do
      played = Enum.random(0..3)
      colours = for _ <- 1..played//1, do: Enum.random([:white, :black])

      opponents =
        if size > 2 and Enum.random([true, false]) do
          others = Enum.to_list(1..size) -- [n]
          Enum.take_random(others, Enum.random(0..min(1, length(others))))
        else
          []
        end

      %Team{
        tpn: n,
        match_points: 0.0,
        game_points: 0.0,
        colours: colours,
        opponents: opponents,
        floated_last_round?: Enum.random([true, false])
      }
    end
    |> symmetrise()
  end

  # A one-sided "we played them" is not a history any tournament produces,
  # and [C1] is symmetric - so make the generated history symmetric too,
  # or the reference and the engine can legitimately disagree.
  defp symmetrise(teams) do
    pairs =
      for t <- teams, o <- t.opponents, into: MapSet.new() do
        {min(t.tpn, o), max(t.tpn, o)}
      end

    Enum.map(teams, fn t ->
      opponents =
        pairs
        |> Enum.filter(fn {a, b} -> a == t.tpn or b == t.tpn end)
        |> Enum.map(fn {a, b} -> if a == t.tpn, do: b, else: a end)
        |> Enum.sort()

      %{t | opponents: opponents}
    end)
  end

  defp adjacency(teams) do
    indexed = Enum.with_index(teams)

    adj =
      Map.new(indexed, fn {t, i} ->
        mask =
          Enum.reduce(indexed, 0, fn {o, j}, acc ->
            if i != j and not Team.met?(t, o.tpn), do: acc ||| 1 <<< j, else: acc
          end)

        {i, mask}
      end)

    {(1 <<< length(teams)) - 1, adj}
  end

  # Every team paired exactly once, no rematch, bye accounted for.
  defp assert_legal_round(round, teams) do
    by_tpn = Map.new(teams, &{&1.tpn, &1})
    seated = Enum.flat_map(round.pairs, fn p -> [p.white, p.black] end)

    expected = Enum.map(teams, & &1.tpn) -- List.wrap(round.bye)

    assert Enum.sort(seated) == Enum.sort(expected),
           "every team must be paired exactly once (or hold the bye)"

    for p <- round.pairs do
      refute Team.met?(Map.fetch!(by_tpn, p.white), p.black),
             "[C1] violated: #{p.white} has already played #{p.black}"
    end

    if round.bye do
      refute Team.pab_ineligible?(Map.fetch!(by_tpn, round.bye)),
             "[C2] violated: #{round.bye} may not receive the bye"
    end
  end

  # Feed a paired round back into the teams, so the next round has history.
  defp apply_round(teams, round) do
    result = Map.new(round.pairs, fn p -> {p.white, {:white, p.black}} end)

    result =
      Enum.reduce(round.pairs, result, fn p, acc ->
        Map.put(acc, p.black, {:black, p.white})
      end)

    Enum.map(teams, fn t ->
      case Map.fetch(result, t.tpn) do
        {:ok, {colour, opponent}} ->
          %{
            t
            | colours: t.colours ++ [colour],
              opponents: [opponent | t.opponents],
              match_points: t.match_points + 1.0
          }

        :error ->
          %{t | had_pab?: true, match_points: t.match_points + 1.0}
      end
    end)
  end
end
