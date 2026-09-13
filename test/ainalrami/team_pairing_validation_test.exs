defmodule Ainalrami.TeamPairingValidationTest do
  @moduledoc """
  C.04.6 validation beyond the single bracket: whole rounds against a
  brute-force reading of the text, the absolute criteria on large fields, and
  hand-worked positions for each criterion of Article 3.5.

  ## The reference is written from the regulation, not from the engine

  `ref_round/2` below is a second implementation of Articles 3.4-3.6 and 4,
  deliberately naive: it enumerates EVERY subset of the lower teams as an
  upfloater set and EVERY pairing of a bracket, decides pairability by
  trying every partner, and ranks by the criteria in 2.3's priority order.
  It shares no code with `Ainalrami.TeamPairing` beyond the `%Team{}`
  struct. Where the two agree on hundreds of reachable rounds, what is left
  to argue about is the reading - which the reference states in the open -
  not the search.

  Its readings, identical to the engine's by design (each is isolated there
  in a named function):

    * [C4] then [C5] are judged over LEGAL sets (bracket pairable and the
      rest pairable - [C1] and [C3]);
    * [C5] maximises the upfloaters' scores taken in ascending order
      (open question 5 - the article, not the 3.5.4 example);
    * [C6] minimises how many more upfloaters than the parity minimum the
      following scoregroup's bracket would need;
    * [C7] minimises the upfloaters that floated last round, before 3.5.4's
      order (open question 7);
    * 3.6: least {C8, C10}, then the smallest identifier. Type A only here;
      Type B's [C9] is proven at bracket level in `team_pairing_test.exs`.

  ## Histories are reachable

  Random `%Team{}` structs can describe tournaments no event produces (a
  team on 4 match points after one round). So every history here is PLAYED:
  a field starts empty and each round is paired by the engine and then given
  random results - including matches forfeited as a whole, pairing-allocated
  byes, and teams sitting a round out - and the next round is paired from
  that. Every round along the way is checked.
  """
  use ExUnit.Case, async: true

  alias Ainalrami.TeamPairing
  alias Ainalrami.TeamPairing.{Bracket, Team}

  @boards 4

  # ==================================================================
  # Whole rounds against the brute-force reference
  # ==================================================================

  describe "whole rounds against the brute-force reference (4-10 teams)" do
    test "every round of every generated event matches the reference" do
      checked =
        for seed <- 1..90, reduce: 0 do
          acc ->
            :rand.seed(:exsss, {seed, 2 * seed + 1, 7 * seed + 3})
            size = Enum.random(4..10)
            rounds = Enum.random(3..6)
            initial = Enum.random([:white, :black])

            acc +
              play_event(size, rounds, initial, fn round_no, field, absent, opts ->
                reference = ref_round(field, absent: absent, initial: initial, opts: opts)

                where =
                  "seed #{seed}, round #{round_no}, #{length(field)} teams, absent #{inspect(absent)}"

                case TeamPairing.pair_round(field, opts) do
                  {:ok, engine} ->
                    send(
                      self(),
                      {:stat,
                       %{
                         upfloaters?: Enum.any?(engine.brackets, &(&1.upfloaters != [])),
                         bye?: engine.bye != nil,
                         absent?: absent != []
                       }}
                    )

                    assert normalise(engine) == Map.take(reference, [:bye, :pairs]),
                           """
                           #{where}
                             engine:    #{inspect(normalise(engine))}
                             reference: #{inspect(reference)}
                             field:     #{inspect(Enum.map(field, &describe_team/1))}
                           """

                    # Recording the reasons changes nothing, and the reasons
                    # recorded are the reference's.
                    assert {:ok, explained} =
                             TeamPairing.pair_round(field, [explain: true] ++ opts)

                    assert Map.delete(explained, :explanation) == engine,
                           "#{where}: explain changed the round"

                    send(
                      self(),
                      {:reasons,
                       Enum.map(reference.reasons.brackets, & &1.decided_by) ++
                         Enum.map(reference.reasons.rules, &elem(&1, 3)) ++
                         Enum.map(reference.reasons.rules, &elem(&1, 2)) ++
                         List.wrap(reference.reasons.bye && reference.reasons.bye.decided_by) ++
                         if(reference.reasons.bye && reference.reasons.bye.passed_over != [],
                           do: ["3.4.1"],
                           else: []
                         )}
                    )

                    assert reasons(explained.explanation) == reference.reasons,
                           """
                           #{where}: the recorded reasons are not the reference's
                             engine:    #{inspect(reasons(explained.explanation))}
                             reference: #{inspect(reference.reasons)}
                             field:     #{inspect(Enum.map(field, &describe_team/1))}
                           """

                    engine

                  # 3.3.3 - small fields run out of legal pairings (every
                  # eligible team has had its bye, or everyone has met). The
                  # engine may say so only when the definition agrees, and
                  # the event ends there.
                  {:error, reason} ->
                    assert reference == :impossible,
                           "#{where}: engine refused (#{inspect(reason)}) but the reference paired #{inspect(reference)}"

                    :stop
                end
              end)
        end

      # A guard against the generator quietly producing nothing to check.
      assert checked > 250

      # And against it producing only the easy shapes. Measured when written
      # (seeds 1..90): 371 rounds, 259 with an upfloater bracket, 192 with a
      # bye, 105 with a team sitting out.
      stats = collect_stats([])
      assert Enum.count(stats, & &1.upfloaters?) > 150
      assert Enum.count(stats, & &1.bye?) > 100
      assert Enum.count(stats, & &1.absent?) > 50

      # And the recorded reasons it compared cover more than the easy ones.
      # Measured when written: C4 550, C5 95, C7 10, C6 2, 3.5.4 117; bye
      # 3.4.1 12, 3.4.2 79, 3.4.3 8, 3.4.4 92; 4.2.1-4.2.3 498/202/400;
      # 4.3.1 281, 4.3.2 195, 4.3.3 18, 4.3.5 346, 4.3.6 59, 4.3.8 199, 4.3.9
      # 2. 4.3.4 is Type B, which the reference does not play; 4.3.7 and the
      # rest are pinned by hand in `team_pairing_test.exs`.
      seen = collect_reasons(%{})

      for reason <-
            ~w(C4 C5 C6 C7 3.5.4 3.4.1 3.4.2 3.4.3 3.4.4 4.2.1 4.2.2 4.2.3) ++
              ~w(4.3.1 4.3.2 4.3.3 4.3.5 4.3.6 4.3.8) do
        assert Map.get(seen, reason, 0) > 0, "no generated round was decided by #{reason}"
      end
    end
  end

  # ==================================================================
  # Absolute criteria on large fields
  # ==================================================================

  describe "absolute criteria always hold (up to 60 teams)" do
    @tag timeout: 300_000
    test "[C1], [C2], [C3] and Article 4's colours, every round" do
      for {seed, size} <- [{101, 12}, {102, 17}, {103, 24}, {104, 31}, {105, 40}, {106, 60}] do
        :rand.seed(:exsss, {seed, seed + 5, seed * 3})
        rounds = if size > 40, do: 7, else: 9
        initial = Enum.random([:white, :black])

        paired =
          play_event(size, rounds, initial, fn round_no, field, absent, opts ->
            assert {:ok, round} = TeamPairing.pair_round(field, opts),
                   "seed #{seed}, #{size} teams, round #{round_no}: no pairing"

            assert_absolute(round, field, "seed #{seed}, #{size} teams, round #{round_no}")
            assert_colours(round, field, absent, initial)

            # The same round explained: identical, and its record bounded.
            assert {:ok, explained} = TeamPairing.pair_round(field, [explain: true] ++ opts)

            assert Map.delete(explained, :explanation) == round,
                   "seed #{seed}, #{size} teams, round #{round_no}: explain changed the round"

            assert_bounded(explained.explanation, round)
            round
          end)

        assert paired == rounds
      end
    end
  end

  # ==================================================================
  # Hand-worked positions
  # ==================================================================

  describe "hand-worked positions from the text" do
    test "3.6.3 - with no history the smallest identifier is paired" do
      # The TPNs of 3.6.2's example. Tops 4 6 8 9, bottoms 10 11 16 24 in
      # order: identifier 4 6 8 9 10 11 16 24 is the smallest there is.
      teams = for tpn <- [4, 6, 8, 9, 10, 11, 16, 24], do: team(tpn)

      {:ok, result} = Bracket.pair(teams)
      assert result.pairs == [{4, 10}, {6, 11}, {8, 16}, {9, 24}]
    end

    test "3.6.3 - a rematch moves to the next identifier, not to any legal one" do
      # 4 has met 10. The next identifier in order keeps the tops and swaps
      # the first two bottoms: 4 6 8 9 11 10 16 24.
      teams =
        for tpn <- [4, 6, 8, 9, 10, 11, 16, 24] do
          case tpn do
            4 -> team(4, opponents: [10])
            10 -> team(10, opponents: [4])
            n -> team(n)
          end
        end

      {:ok, result} = Bracket.pair(teams)
      assert result.pairs == [{4, 11}, {6, 10}, {8, 16}, {9, 24}]
    end

    test "[C10] counts upfloaters' opponents per team, so two upfloaters meeting count twice" do
      # Upfloaters 1 and 2 and residents 3 and 4 all floated last round.
      # Every pairing puts two floated teams opposite an upfloater: 1-3 2-4
      # and 1-4 2-3 count 3 and 4, and 1-2 3-4 counts 1 and 2. All tie at
      # two, so 3.6.3 takes the smallest identifier, 1 2 3 4. Counting once
      # per PAIR made 1-2 3-4 a one and picked it.
      teams = for tpn <- 1..4, do: team(tpn, floated_last_round?: true)

      {:ok, result} = Bracket.pair(teams, upfloater_tpns: [1, 2])
      assert result.pairs == [{1, 3}, {2, 4}]
      assert result.scores == {0, 0, 2}
    end

    test "[C4] - an even scoregroup whose residents have met takes two upfloaters" do
      residents = [team(1, mp: 2.0, opponents: [2]), team(2, mp: 2.0, opponents: [1])]
      lower = [team(3, mp: 1.0), team(4, mp: 1.0)]

      assert {:ok, set} = TeamPairing.select_upfloaters(residents, lower, :match_points)
      assert Enum.map(set, & &1.tpn) == [3, 4]
    end

    test "[C3] - a bracket that pairs but strands the teams below it is not taken" do
      # 1 and 2 could pair each other, but 3 has met 4, 5 and 6, so the four
      # lower teams cannot be paired among themselves. 3 must float up.
      residents = [team(1, mp: 2.0), team(2, mp: 2.0)]

      lower = [
        team(3, mp: 1.0, opponents: [4, 5, 6]),
        team(4, mp: 1.0, opponents: [3]),
        team(5, mp: 1.0, opponents: [3]),
        team(6, mp: 1.0, opponents: [3])
      ]

      assert {:ok, set} = TeamPairing.select_upfloaters(residents, lower, :match_points)
      assert Enum.map(set, & &1.tpn) == [3, 4]
    end

    test "[C4] outranks [C5]: a lower-scoring single upfloater beats three" do
      # Residents 1, 2, 3 on 3 points. The only 2-pointer, 4, has met all of
      # them, so no bracket with it as the one upfloater pairs. [C4] (the
      # count) is above [C5] (the scores), so one 1-pointer is taken rather
      # than growing the set to keep a 2-pointer in it.
      residents = [team(1, mp: 3.0), team(2, mp: 3.0), team(3, mp: 3.0)]

      lower = [
        team(4, mp: 2.0, opponents: [1, 2, 3]),
        team(5, mp: 1.0),
        team(6, mp: 1.0),
        team(7, mp: 1.0),
        team(8, mp: 1.0)
      ]

      residents = Enum.map(residents, &%{&1 | opponents: [4]})

      assert {:ok, set} = TeamPairing.select_upfloaters(residents, lower, :match_points)
      assert Enum.map(set, & &1.tpn) == [5]
    end

    test "[C6] - the set that leaves the following scoregroup pairable wins over 3.5.4's first" do
      # One upfloater from the 2-point group {4, 5, 6}. 3.5.4 alone would take
      # 4, but 5 and 6 have met, so 4 floating leaves a following scoregroup
      # that needs two upfloaters of its own. 5 floating leaves {4, 6}, which
      # pairs as it is.
      residents = [team(1, mp: 3.0), team(2, mp: 3.0), team(3, mp: 3.0)]

      lower = [
        team(4, mp: 2.0),
        team(5, mp: 2.0, opponents: [6]),
        team(6, mp: 2.0, opponents: [5]),
        team(7, mp: 1.0),
        team(8, mp: 1.0)
      ]

      assert {:ok, set} = TeamPairing.select_upfloaters(residents, lower, :match_points)
      assert Enum.map(set, & &1.tpn) == [5]
    end

    test "[C6] - switched off when the following scoregroup is emptied" do
      # The 3.5.4 example's shape: residents who have all met need three
      # upfloaters, and all three 2-pointers go, so there is no following
      # scoregroup left to protect.
      residents = [
        team(1, mp: 3.0, opponents: [2, 3]),
        team(2, mp: 3.0, opponents: [1, 3]),
        team(3, mp: 3.0, opponents: [1, 2])
      ]

      lower = [
        team(4, mp: 2.0),
        team(5, mp: 2.0),
        team(6, mp: 2.0),
        team(7, mp: 1.0),
        team(8, mp: 1.0),
        team(9, mp: 1.0),
        team(10, mp: 1.0),
        team(11, mp: 1.0),
        team(12, mp: 1.0)
      ]

      assert {:ok, set} = TeamPairing.select_upfloaters(residents, lower, :match_points)
      assert Enum.map(set, & &1.tpn) == [4, 5, 6]
    end

    test "[C7] - a team that floated last round is not floated again when another can be" do
      residents = [team(1, mp: 3.0), team(2, mp: 3.0), team(3, mp: 3.0)]

      lower = [
        team(4, mp: 2.0, floated_last_round?: true),
        team(5, mp: 2.0),
        team(6, mp: 2.0),
        team(7, mp: 1.0),
        team(8, mp: 1.0)
      ]

      assert {:ok, [%Team{tpn: 5}]} =
               TeamPairing.select_upfloaters(residents, lower, :match_points, [])

      # "With the exception of the last two rounds" - then 3.5.4 decides.
      assert {:ok, [%Team{tpn: 4}]} =
               TeamPairing.select_upfloaters(residents, lower, :match_points,
                 last_two_rounds?: true
               )
    end

    test "[C6] outranks [C7]" do
      # 5 and 6 floated last round, 4 did not. But 4 floating would strand 5
      # and 6, who have met. [C6] is above [C7], so one of them floats again,
      # and 3.5.4's order makes it 5.
      residents = [team(1, mp: 3.0), team(2, mp: 3.0), team(3, mp: 3.0)]

      lower = [
        team(4, mp: 2.0),
        team(5, mp: 2.0, opponents: [6], floated_last_round?: true),
        team(6, mp: 2.0, opponents: [5], floated_last_round?: true),
        team(7, mp: 1.0),
        team(8, mp: 1.0)
      ]

      assert {:ok, [%Team{tpn: 5}]} =
               TeamPairing.select_upfloaters(residents, lower, :match_points)
    end

    test "an odd field handed to the selection is refused, not guessed at" do
      assert {:error, :odd_field} =
               TeamPairing.select_upfloaters(
                 [team(1, mp: 1.0)],
                 [team(2), team(3)],
                 :match_points
               )
    end

    test "3.4 - the bye goes to the lowest score, then most matches, then largest TPN, [C2] first" do
      teams = [
        team(1, mp: 2.0, colours: [:white], opponents: [2]),
        team(2, mp: 0.0, colours: [:black], opponents: [1]),
        team(3, mp: 1.0, had_pab?: true),
        team(4, mp: 0.0, won_by_forfeit?: false),
        team(5, mp: 0.0, won_by_forfeit?: true)
      ]

      # 2 and 4 are on the lowest eligible score (5 won a match by forfeit,
      # [C2]); 2 has played more matches (3.4.3).
      {:ok, round} = TeamPairing.pair_round(teams, round: 2, expected_rounds: 5)
      assert round.bye == 2
    end
  end

  # ==================================================================
  # The recorded reasons, on the same hand-worked positions
  # ==================================================================

  describe "the reasons recorded with explain: true, on the hand-worked positions" do
    # The first bracket's selection account when `residents ++ lower` is
    # paired as a whole round. Every position here is an even field whose
    # residents are its top scoregroup, so the first bracket is exactly the
    # `select_upfloaters/4` call the position above makes.
    defp first_selection(residents, lower, opts \\ []) do
      assert {:ok, round} = TeamPairing.pair_round(residents ++ lower, [explain: true] ++ opts)
      assert {:ok, plain} = TeamPairing.pair_round(residents ++ lower, opts)
      assert Map.delete(round, :explanation) == plain
      hd(round.explanation.brackets).selection
    end

    defp set(ups, c5, c6, c7), do: %{upfloaters: ups, c4: length(ups), c5: c5, c6: c6, c7: c7}

    test "[C6] - 4 lost on [C6]; 5 beat 6, equal on everything, on 3.5.4's order" do
      residents = [team(1, mp: 3.0), team(2, mp: 3.0), team(3, mp: 3.0)]

      lower = [
        team(4, mp: 2.0),
        team(5, mp: 2.0, opponents: [6]),
        team(6, mp: 2.0, opponents: [5]),
        team(7, mp: 1.0),
        team(8, mp: 1.0)
      ]

      s = first_selection(residents, lower)

      assert s.chosen == set([5], [2.0], 0, 0)
      assert s.runner_up == set([6], [2.0], 0, 0)
      assert s.decided_by == "3.5.4"
      assert s.considered == [set([4], [2.0], 1, 0), set([5], [2.0], 0, 0), set([6], [2.0], 0, 0)]
      assert s.rejected == [] and s.sizes_without_legal_set == [] and s.c4 == 1
    end

    test "[C6] outranks [C7]: the position as worked above, and with the tie removed" do
      residents = [team(1, mp: 3.0), team(2, mp: 3.0), team(3, mp: 3.0)]

      lower = [
        team(4, mp: 2.0),
        team(5, mp: 2.0, opponents: [6], floated_last_round?: true),
        team(6, mp: 2.0, opponents: [5], floated_last_round?: true),
        team(7, mp: 1.0),
        team(8, mp: 1.0)
      ]

      s = first_selection(residents, lower)
      assert s.considered == [set([4], [2.0], 1, 0), set([5], [2.0], 0, 1), set([6], [2.0], 0, 1)]
      assert {s.chosen.upfloaters, s.runner_up.upfloaters, s.decided_by} == {[5], [6], "3.5.4"}

      # 4 has met 5 and 6 too, so only 6 floating leaves a pairable 4-5.
      # 6 floated last round and 4 did not: 6 is worse on [C7] and better on
      # [C6], and [C6] is the one that decides.
      lower = [
        team(4, mp: 2.0, opponents: [6]),
        team(5, mp: 2.0, opponents: [6], floated_last_round?: true),
        team(6, mp: 2.0, opponents: [4, 5], floated_last_round?: true),
        team(7, mp: 1.0),
        team(8, mp: 1.0)
      ]

      s = first_selection(residents, lower)
      assert s.chosen == set([6], [2.0], 0, 1)
      assert s.runner_up == set([4], [2.0], 1, 0)
      assert s.decided_by == "C6"
    end

    test "[C7] - decided by [C7] only when the runner-up floated; otherwise by 3.5.4" do
      residents = [team(1, mp: 3.0), team(2, mp: 3.0), team(3, mp: 3.0)]

      lower = [
        team(4, mp: 2.0, floated_last_round?: true),
        team(5, mp: 2.0),
        team(6, mp: 2.0),
        team(7, mp: 1.0),
        team(8, mp: 1.0)
      ]

      s = first_selection(residents, lower)

      assert {s.chosen, s.runner_up, s.decided_by} ==
               {set([5], [2.0], 0, 0), set([6], [2.0], 0, 0), "3.5.4"}

      assert hd(s.considered) == set([4], [2.0], 0, 1)

      # 6 floated too: the best other set is now 4, which lost on [C7].
      lower = List.replace_at(lower, 2, team(6, mp: 2.0, floated_last_round?: true))
      s = first_selection(residents, lower)

      assert {s.chosen.upfloaters, s.runner_up, s.decided_by} ==
               {[5], set([4], [2.0], 0, 1), "C7"}

      # The last two rounds: [C7] is off, every set scores 0 on it, and 4 wins
      # on 3.5.4's order.
      s = first_selection(residents, lower, round: 4, expected_rounds: 5)
      assert {s.chosen, s.decided_by} == {set([4], [2.0], 0, 0), "3.5.4"}
    end

    test "[C6] switched off when the following scoregroup is emptied: [C5] decides" do
      residents = [
        team(1, mp: 3.0, opponents: [2, 3]),
        team(2, mp: 3.0, opponents: [1, 3]),
        team(3, mp: 3.0, opponents: [1, 2])
      ]

      lower =
        [team(4, mp: 2.0), team(5, mp: 2.0), team(6, mp: 2.0)] ++
          for(tpn <- 7..12, do: team(tpn, mp: 1.0))

      s = first_selection(residents, lower)

      assert s.chosen == set([4, 5, 6], [2.0, 2.0, 2.0], 0, 0)
      # The next set that can be paired has a 1-pointer in it; its [C6] and
      # [C7] are never worked out because [C5] already lost.
      assert s.runner_up == set([4, 5, 7], [1.0, 2.0, 2.0], nil, nil)
      assert s.decided_by == "C5"

      # One upfloater cannot make a bracket of residents who have all met:
      # all nine single sets are rejected on [C1].
      assert s.sizes_without_legal_set == [1]
      assert length(s.rejected) == 9 and Enum.all?(s.rejected, &(&1.failed == "C1"))
    end

    test "[C4] - an even scoregroup whose residents have met: no other set, so [C4]" do
      residents = [team(1, mp: 2.0, opponents: [2]), team(2, mp: 2.0, opponents: [1])]
      lower = [team(3, mp: 1.0), team(4, mp: 1.0)]

      s = first_selection(residents, lower)

      assert s.c4 == 2 and s.sizes_without_legal_set == [0]
      assert s.rejected == [%{upfloaters: [], c4: 0, c5: [], failed: "C1"}]
      assert {s.chosen.upfloaters, s.runner_up, s.decided_by} == {[3, 4], nil, "C4"}
    end

    test "[C3] - no upfloaters would strand the teams below: rejected on [C3]" do
      residents = [team(1, mp: 2.0), team(2, mp: 2.0)]

      lower = [
        team(3, mp: 1.0, opponents: [4, 5, 6]),
        team(4, mp: 1.0, opponents: [3]),
        team(5, mp: 1.0, opponents: [3]),
        team(6, mp: 1.0, opponents: [3])
      ]

      s = first_selection(residents, lower)

      assert s.rejected == [%{upfloaters: [], c4: 0, c5: [], failed: "C3"}]

      assert {s.chosen.upfloaters, s.runner_up.upfloaters, s.decided_by} ==
               {[3, 4], [3, 5], "3.5.4"}
    end

    test "[C4] outranks [C5]: the 2-pointer is rejected on [C1], a 1-pointer taken" do
      residents = [
        team(1, mp: 3.0, opponents: [4]),
        team(2, mp: 3.0, opponents: [4]),
        team(3, mp: 3.0, opponents: [4])
      ]

      lower = [
        team(4, mp: 2.0, opponents: [1, 2, 3]),
        team(5, mp: 1.0),
        team(6, mp: 1.0),
        team(7, mp: 1.0),
        team(8, mp: 1.0)
      ]

      s = first_selection(residents, lower)

      assert s.rejected == [%{upfloaters: [4], c4: 1, c5: [2.0], failed: "C1"}]
      assert {s.chosen.upfloaters, s.runner_up.upfloaters, s.decided_by} == {[5], [6], "3.5.4"}
    end

    test "3.6.3 and [C10] - a bracket that needs no upfloaters, and one that needs two" do
      # 3.6.3's position as a whole round: one scoregroup, nothing floats, so
      # the empty set is the only set of its size.
      teams =
        for tpn <- [4, 6, 8, 9, 10, 11, 16, 24] do
          case tpn do
            4 -> team(4, opponents: [10])
            10 -> team(10, opponents: [4])
            n -> team(n)
          end
        end

      assert {:ok, round} = TeamPairing.pair_round(teams, explain: true)
      assert [%{selection: s}] = round.explanation.brackets
      assert {s.c4, s.chosen.upfloaters, s.runner_up, s.decided_by} == {0, [], nil, "C4"}

      assert round.pairs |> Enum.map(&Enum.sort([&1.white, &1.black])) |> Enum.sort() ==
               [[4, 11], [6, 10], [8, 16], [9, 24]]

      assert Enum.all?(
               round.explanation.pairs,
               &(&1.colour_rule == "4.3.1" and &1.first_team_rule == "4.2.3")
             )

      # [C10]'s shape: residents 3 and 4 have met, so both upfloaters come up
      # and every pairing puts two floated teams against an upfloater.
      teams = [
        team(1, floated_last_round?: true),
        team(2, floated_last_round?: true),
        team(3, mp: 1.0, opponents: [4], floated_last_round?: true),
        team(4, mp: 1.0, opponents: [3], floated_last_round?: true)
      ]

      assert {:ok, round} = TeamPairing.pair_round(teams, explain: true)
      assert [%{criteria: {0, 0, 2}}] = round.brackets
      assert [%{selection: s}] = round.explanation.brackets
      assert s.rejected == [%{upfloaters: [], c4: 0, c5: [], failed: "C1"}]
      assert {s.chosen.upfloaters, s.decided_by} == {[1, 2], "C4"}
    end
  end

  # ==================================================================
  # Playing an event
  # ==================================================================

  # Plays `rounds` rounds of a `size`-team event. `pair` is called with the
  # round number, the teams in this round's field, the arrived-but-absent
  # TPNs and the options to pair with; it returns the engine's round, whose
  # results are then made up and applied. Returns the number of rounds
  # paired.
  defp play_event(size, rounds, initial, pair) do
    teams = for tpn <- 1..size, do: {tpn, %{team: team(tpn), arrived?: false}}

    {_teams, count} =
      Enum.reduce_while(1..rounds, {Map.new(teams), 0}, fn round_no, {state, count} ->
        # About one team in twelve sits a round out, from round 2 on.
        sitting_out =
          if round_no > 1,
            do: for({tpn, _} <- state, :rand.uniform(12) == 1, do: tpn),
            else: []

        field =
          state
          |> Enum.reject(fn {tpn, _} -> tpn in sitting_out end)
          |> Enum.map(fn {_tpn, s} -> s.team end)
          |> Enum.sort_by(& &1.tpn)

        absent =
          for {tpn, s} <- state, tpn in sitting_out, s.arrived?, do: tpn

        if length(field) < 2 do
          {:cont, {state, count}}
        else
          opts = [
            round: round_no,
            expected_rounds: rounds,
            initial_colour: initial,
            absent: Enum.sort(absent)
          ]

          case pair.(round_no, field, Enum.sort(absent), opts) do
            :stop -> {:halt, {state, count}}
            round -> {:cont, {apply_round(state, round, sitting_out), count + 1}}
          end
        end
      end)

    count
  end

  defp apply_round(state, round, sitting_out) do
    scores = Map.new(state, fn {tpn, s} -> {tpn, s.team.match_points} end)

    state =
      Enum.reduce(round.pairs, state, fn %{white: w, black: b}, state ->
        floated? = scores[w] != scores[b]

        if :rand.uniform(15) == 1 do
          # The whole match forfeited by one side (C.04.2 3.5: not played, so
          # not a meeting and no colour).
          {winner, loser} = if :rand.uniform(2) == 1, do: {w, b}, else: {b, w}

          state
          |> update_team(winner, fn t ->
            %{
              t
              | match_points: t.match_points + 2.0,
                game_points: t.game_points + @boards,
                won_by_forfeit?: true,
                floated_last_round?: floated?
            }
          end)
          |> update_team(loser, &%{&1 | floated_last_round?: floated?})
        else
          boards = for _ <- 1..@boards, do: Enum.random([1.0, 0.5, 0.0])
          gp_w = Enum.sum(boards)
          gp_b = @boards - gp_w

          {mp_w, mp_b} =
            cond do
              gp_w > gp_b -> {2.0, 0.0}
              gp_w < gp_b -> {0.0, 2.0}
              true -> {1.0, 1.0}
            end

          state
          |> update_team(w, fn t ->
            %{
              t
              | match_points: t.match_points + mp_w,
                game_points: t.game_points + gp_w,
                opponents: [b | t.opponents],
                colours: t.colours ++ [:white],
                floated_last_round?: floated?
            }
          end)
          |> update_team(b, fn t ->
            %{
              t
              | match_points: t.match_points + mp_b,
                game_points: t.game_points + gp_b,
                opponents: [w | t.opponents],
                colours: t.colours ++ [:black],
                floated_last_round?: floated?
            }
          end)
        end
      end)

    state =
      if round.bye do
        # 1.4: as many match points and game points as a draw.
        update_team(state, round.bye, fn t ->
          %{
            t
            | match_points: t.match_points + 1.0,
              game_points: t.game_points + @boards / 2,
              had_pab?: true,
              floated_last_round?: false
          }
        end)
      else
        state
      end

    paired = MapSet.new(Enum.flat_map(round.pairs, &[&1.white, &1.black]) ++ List.wrap(round.bye))

    Map.new(state, fn {tpn, s} ->
      cond do
        MapSet.member?(paired, tpn) -> {tpn, %{s | arrived?: true}}
        tpn in sitting_out -> {tpn, %{s | team: %{s.team | floated_last_round?: false}}}
        true -> {tpn, s}
      end
    end)
  end

  defp collect_stats(acc) do
    receive do
      {:stat, stat} -> collect_stats([stat | acc])
    after
      0 -> acc
    end
  end

  defp collect_reasons(acc) do
    receive do
      {:reasons, reasons} ->
        reasons
        |> Enum.reduce(acc, fn r, acc -> Map.update(acc, r, 1, &(&1 + 1)) end)
        |> collect_reasons()
    after
      0 -> acc
    end
  end

  defp update_team(state, tpn, fun), do: Map.update!(state, tpn, &%{&1 | team: fun.(&1.team)})

  # ==================================================================
  # Property assertions
  # ==================================================================

  defp assert_absolute(round, field, where) do
    by_tpn = Map.new(field, &{&1.tpn, &1})
    seated = Enum.flat_map(round.pairs, &[&1.white, &1.black])

    # [C3] / 3.3.1 - everyone paired except at most one, who has the bye.
    assert Enum.sort(seated ++ List.wrap(round.bye)) == Enum.sort(Map.keys(by_tpn)),
           "#{where}: not every team paired exactly once"

    assert round.bye != nil == (rem(length(field), 2) == 1),
           "#{where}: a bye exactly when the field is odd"

    for %{white: w, black: b} <- round.pairs do
      assert w != b
      # [C1]
      refute Team.met?(by_tpn[w], b), "#{where}: [C1] - #{w} and #{b} have met"
    end

    # [C2]
    if round.bye do
      refute Team.pab_ineligible?(by_tpn[round.bye]),
             "#{where}: [C2] - #{round.bye} may not receive the bye"
    end
  end

  defp assert_colours(round, field, absent, initial) do
    by_tpn = Map.new(field, &{&1.tpn, &1})
    numbers = ref_numbers(field, absent)

    for %{white: w, black: b} <- round.pairs do
      assert match?({^w, ^b, _rules}, ref_colours(by_tpn[w], by_tpn[b], numbers, initial)),
             "Article 4 disagrees on #{w}-#{b}"
    end
  end

  # ==================================================================
  # The reference: Articles 3.4-3.6 and 4, by brute force
  # ==================================================================

  defp normalise(round) do
    %{bye: round.bye, pairs: round.pairs |> Enum.map(&{&1.white, &1.black}) |> Enum.sort()}
  end

  defp ref_round(field, opts) do
    absent = Keyword.fetch!(opts, :absent)
    initial = Keyword.fetch!(opts, :initial)
    engine_opts = Keyword.fetch!(opts, :opts)
    round = engine_opts[:round]
    expected = engine_opts[:expected_rounds]
    last_two? = round >= expected - 1

    numbers = ref_numbers(field, absent)
    by_tpn = Map.new(field, &{&1.tpn, &1})

    with {bye, rest, bye_reasons} <- ref_bye(field),
         true <- ref_pairable?(rest) do
      {bracket_pairs, bracket_reasons} =
        rest
        |> ref_brackets(last_two?, [])
        |> Enum.unzip()

      allocated =
        bracket_pairs
        |> Enum.concat()
        |> Enum.map(fn {a, b} -> ref_colours(by_tpn[a], by_tpn[b], numbers, initial) end)

      %{
        bye: bye,
        pairs: allocated |> Enum.map(fn {w, b, _rules} -> {w, b} end) |> Enum.sort(),
        reasons: %{
          bye: bye_reasons,
          brackets: bracket_reasons,
          rules:
            allocated
            |> Enum.map(fn {w, b, {first, colour}} -> {w, b, first, colour} end)
            |> Enum.sort()
        }
      }
    else
      _ -> :impossible
    end
  end

  # The engine's recorded reasons, cut to what the reference can say
  # independently: the bye's passed-over teams and deciding tie-break, each
  # bracket's chosen set and deciding criterion, each pair's Article 4 rules.
  defp reasons(explanation) do
    %{
      bye:
        explanation.bye &&
          %{
            tpn: explanation.bye.tpn,
            passed_over: Enum.map(explanation.bye.passed_over, & &1.tpn),
            decided_by: explanation.bye.decided_by
          },
      brackets:
        Enum.map(explanation.brackets, fn b ->
          %{upfloaters: b.selection.chosen.upfloaters, decided_by: b.selection.decided_by}
        end),
      rules:
        explanation.pairs
        |> Enum.map(&{&1.white, &1.black, &1.first_team_rule, &1.colour_rule})
        |> Enum.sort()
    }
  end

  # Every explanation is bounded, whatever the field: no recorded list longer
  # than the limit, the omitted counts never negative, one entry per pair, and
  # the chosen set is the bracket's upfloaters.
  defp assert_bounded(explanation, round) do
    limit = explanation.limit
    assert length(explanation.pairs) == length(round.pairs)
    assert length(explanation.brackets) == length(round.brackets)

    if explanation.bye do
      assert length(explanation.bye.ineligible) <= limit
      assert length(explanation.bye.passed_over) <= limit
      assert explanation.bye.ineligible_omitted >= 0 and explanation.bye.passed_over_omitted >= 0
    end

    for {account, bracket} <- Enum.zip(explanation.brackets, round.brackets) do
      s = account.selection
      assert length(s.considered) <= limit and length(s.rejected) <= limit
      assert s.considered_omitted >= 0 and s.rejected_omitted >= 0
      assert Enum.sort(s.chosen.upfloaters) == Enum.sort(bracket.upfloaters)
      assert s.decided_by in [nil, "C4", "C5", "C6", "C7", "3.5.4"]
    end
  end

  # 4.3.1's numbering: everyone arrived, in TPN order, from 1.
  defp ref_numbers(field, absent) do
    (Enum.map(field, & &1.tpn) ++ absent) |> Enum.sort() |> Enum.with_index(1) |> Map.new()
  end

  # 3.4: [C2] first, then the first team by lowest score, most matches
  # played, largest TPN, that leaves the rest pairable (3.4.1).
  #
  # Also the reasons: the teams before the bye in that order (each strands
  # the rest), and the first of 3.4.2-3.4.4 on which the bye ranks ahead of
  # the next eligible team.
  defp ref_bye(field) when rem(length(field), 2) == 0, do: {nil, field, nil}

  defp ref_bye(field) do
    ordered =
      field
      |> Enum.reject(&(&1.had_pab? or &1.won_by_forfeit?))
      |> Enum.sort_by(&{&1.match_points, -length(&1.colours), -&1.tpn})

    case Enum.find_index(ordered, fn t -> ref_pairable?(List.delete(field, t)) end) do
      nil ->
        :impossible

      i ->
        t = Enum.at(ordered, i)
        next = Enum.at(ordered, i + 1)

        decided_by =
          cond do
            next == nil -> nil
            t.match_points != next.match_points -> "3.4.2"
            length(t.colours) != length(next.colours) -> "3.4.3"
            true -> "3.4.4"
          end

        reasons = %{
          tpn: t.tpn,
          passed_over: ordered |> Enum.take(i) |> Enum.map(& &1.tpn),
          decided_by: decided_by
        }

        {t.tpn, List.delete(field, t), reasons}
    end
  end

  # Pairable without a rematch: somebody must partner the first team.
  defp ref_pairable?([]), do: true

  defp ref_pairable?([t | rest]) do
    Enum.any?(rest, fn o -> o.tpn not in t.opponents and ref_pairable?(List.delete(rest, o)) end)
  end

  defp ref_brackets([], _last_two?, acc), do: Enum.reverse(acc)

  defp ref_brackets(remaining, last_two?, acc) do
    top = remaining |> Enum.map(& &1.match_points) |> Enum.max()
    {residents, lower} = Enum.split_with(remaining, &(&1.match_points == top))

    legal =
      for set <- subsets(lower),
          rem(length(residents) + length(set), 2) == 0,
          ref_pairable?(residents ++ set),
          ref_pairable?(lower -- set),
          do: set

    # [C4] then [C5]: fewest teams, then the scores ascending, the larger
    # list the better.
    best_c4_c5 = legal |> Enum.map(&{length(&1), c5(&1)}) |> Enum.min()

    ranked =
      legal
      |> Enum.filter(&({length(&1), c5(&1)} == best_c4_c5))
      |> Enum.map(fn set ->
        {{c6(set, lower), c7(set, last_two?), set |> sort_353() |> Enum.map(& &1.tpn)}, set}
      end)
      |> Enum.sort()

    [{{c6, c7, tpns}, set} | others] = ranked

    # The first criterion in 2.3's order on which the chosen set beats the
    # best other legal set: within its [C4]/[C5] group [C6], [C7] or 3.5.4's
    # order; otherwise the best set outside the group, which is worse on [C5]
    # when it has the same size and on [C4] when it is larger - or no other
    # legal set at all, which is [C4] too.
    decided_by =
      case others do
        [{{o6, o7, _}, _} | _] ->
          cond do
            o6 != c6 -> "C6"
            o7 != c7 -> "C7"
            true -> "3.5.4"
          end

        [] ->
          case legal |> Enum.reject(&({length(&1), c5(&1)} == best_c4_c5)) do
            [] ->
              "C4"

            rest ->
              {size, _} = rest |> Enum.map(&{length(&1), c5(&1)}) |> Enum.min()
              if size == length(set), do: "C5", else: "C4"
          end
      end

    ups = MapSet.new(set, & &1.tpn)
    pairs = ref_bracket_pairing(residents ++ set, ups, last_two?)
    reasons = %{upfloaters: tpns, decided_by: decided_by}
    ref_brackets(lower -- set, last_two?, [{pairs, reasons} | acc])
  end

  defp c5(set), do: set |> Enum.map(& &1.match_points) |> Enum.sort() |> Enum.map(&(0 - &1))

  # [C6]: extra upfloaters (beyond parity) the following scoregroup needs.
  defp c6(_set, []), do: 0

  defp c6(set, lower) do
    following_score = lower |> Enum.map(& &1.match_points) |> Enum.max()
    {following, below} = Enum.split_with(lower -- set, &(&1.match_points == following_score))

    if following == [] do
      0
    else
      needed =
        for up <- subsets(below),
            rem(length(following) + length(up), 2) == 0,
            ref_pairable?(following ++ up),
            ref_pairable?(below -- up),
            do: length(up)

      div(Enum.min(needed) - rem(length(following), 2), 2)
    end
  end

  defp c7(_set, true), do: 0
  defp c7(set, false), do: Enum.count(set, & &1.floated_last_round?)

  defp sort_353(set), do: Enum.sort_by(set, &{0 - &1.match_points, &1.tpn})

  # 3.6: every pairing, legal under [C1]; least {C8, C10}; smallest
  # identifier.
  defp ref_bracket_pairing(bracket, ups, last_two?) do
    bracket
    |> Enum.sort_by(& &1.tpn)
    |> all_pairings()
    |> Enum.filter(fn pairs -> Enum.all?(pairs, fn {a, b} -> a.tpn not in b.opponents end) end)
    |> Enum.min_by(fn pairs ->
      tops = Enum.map(pairs, fn {a, b} -> min(a.tpn, b.tpn) end)
      order = Enum.sort_by(pairs, fn {a, b} -> min(a.tpn, b.tpn) end)
      bottoms = Enum.map(order, fn {a, b} -> max(a.tpn, b.tpn) end)
      {c8(pairs), c10(pairs, ups, last_two?), Enum.sort(tops) ++ bottoms}
    end)
    |> Enum.map(fn {a, b} -> {a.tpn, b.tpn} end)
  end

  defp c8(pairs) do
    Enum.count(pairs, fn {a, b} ->
      pa = ref_preference(a)
      pa != nil and pa == ref_preference(b)
    end)
  end

  # "the number of upfloaters' opponents that were floaters in the previous
  # round" - counted per TEAM, as the text reads.
  defp c10(_pairs, _ups, true), do: 0

  defp c10(pairs, ups, false) do
    pairs
    |> Enum.flat_map(fn {a, b} -> [{a, b}, {b, a}] end)
    |> Enum.count(fn {team, opponent} ->
      MapSet.member?(ups, opponent.tpn) and team.floated_last_round?
    end)
  end

  defp all_pairings([]), do: [[]]

  defp all_pairings([h | t]) do
    Enum.flat_map(t, fn partner ->
      Enum.map(all_pairings(List.delete(t, partner)), &[{h, partner} | &1])
    end)
  end

  defp subsets([]), do: [[]]

  defp subsets([h | t]) do
    rest = subsets(t)
    rest ++ Enum.map(rest, &[h | &1])
  end

  # 1.7.1, Type A.
  defp ref_preference(team) do
    cd = Enum.count(team.colours, &(&1 == :white)) - Enum.count(team.colours, &(&1 == :black))
    last_two = team.colours |> Enum.reverse() |> Enum.take(2)

    cond do
      cd < -1 -> :white
      cd > 1 -> :black
      cd in [0, -1] and last_two == [:black, :black] -> :white
      cd in [0, 1] and last_two == [:white, :white] -> :black
      true -> nil
    end
  end

  # Article 4 for one pair, returning {white_tpn, black_tpn, {4.2 rule, 4.3
  # rule}} - the clause that named the first-team and the one that gave it
  # its colour.
  defp ref_colours(a, b, numbers, initial) do
    {first, other, first_rule} =
      cond do
        a.match_points != b.match_points ->
          if a.match_points > b.match_points, do: {a, b, "4.2.1"}, else: {b, a, "4.2.1"}

        a.game_points != b.game_points ->
          if a.game_points > b.game_points, do: {a, b, "4.2.2"}, else: {b, a, "4.2.2"}

        true ->
          if a.tpn < b.tpn, do: {a, b, "4.2.3"}, else: {b, a, "4.2.3"}
      end

    fp = ref_preference(first)
    op = ref_preference(other)

    cd = fn t ->
      Enum.count(t.colours, &(&1 == :white)) - Enum.count(t.colours, &(&1 == :black))
    end

    {colour, rule} =
      cond do
        first.colours == [] and other.colours == [] ->
          {if(rem(numbers[first.tpn], 2) == 1, do: initial, else: flip(initial)), "4.3.1"}

        fp != nil and op == nil ->
          {fp, "4.3.2"}

        fp == nil and op != nil ->
          {flip(op), "4.3.2"}

        fp != nil and op != nil and fp != op ->
          {fp, "4.3.3"}

        cd.(first) != cd.(other) ->
          {if(cd.(first) < cd.(other), do: :white, else: :black), "4.3.5"}

        true ->
          # 4.3.6, counting played matches only, from the latest (C.04.2 3.4).
          split =
            Enum.zip(Enum.reverse(first.colours), Enum.reverse(other.colours))
            |> Enum.find(fn {x, y} -> x != y end)

          cond do
            split != nil -> {flip(elem(split, 0)), "4.3.6"}
            fp != nil -> {fp, "4.3.7"}
            first.colours != [] -> {flip(List.last(first.colours)), "4.3.8"}
            other.colours != [] -> {List.last(other.colours), "4.3.9"}
            true -> {initial, "initial"}
          end
      end

    if colour == :white,
      do: {first.tpn, other.tpn, {first_rule, rule}},
      else: {other.tpn, first.tpn, {first_rule, rule}}
  end

  defp flip(:white), do: :black
  defp flip(:black), do: :white

  # ==================================================================

  # `mp:` is short for `match_points:`; every other key is a struct field.
  # `struct/2` drops unknown keys silently, so the alias is translated rather
  # than passed through.
  defp team(tpn, fields \\ []) do
    {mp, fields} = Keyword.pop(fields, :mp, 0.0)
    struct(%Team{tpn: tpn, match_points: mp, game_points: 0.0}, fields)
  end

  defp describe_team(t) do
    {t.tpn, t.match_points, t.game_points, Enum.sort(t.opponents), t.colours,
     if(t.had_pab?, do: :pab), if(t.won_by_forfeit?, do: :ff), if(t.floated_last_round?, do: :fl)}
  end
end
