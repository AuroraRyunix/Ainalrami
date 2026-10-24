defmodule Ainalrami.TeamKeepApartTest do
  @moduledoc """
  `Ainalrami.TeamPairing`'s `:forbidden_pairs` and `:soft_pairs` - teams to
  keep apart, absolutely or where no C.04.6 criterion minds (the moduledoc's
  "Keeping teams apart").

  Three kinds of evidence:

    * hand-worked positions: round ranges, a round the groups make
      unpairable, soft pairs that cannot be avoided without a FIDE cost;
    * the case the option was built for - a sixteen-team, six-club regional
      event over five rounds, clubs kept apart;
    * played events against the brute-force reference
      (`Ainalrami.TeamProof.NaiveReference`, which reads both options from
      their description), with the two properties that matter checked
      directly: no forbidden pair is ever seated, and soft pairs change a
      round only between pairings FIDE ranks equal.
  """
  use ExUnit.Case, async: true

  alias Ainalrami.TeamPairing

  import Ainalrami.TeamProof.Events
  import Ainalrami.TeamProof.NaiveReference, only: [ref_round: 2]

  # Six clubs, sixteen teams of two boards: Brugge, Oostkamp, Gistel and
  # three more, seeded by rating. Gistel 1 and Gistel 2 are seeds 3 and 11,
  # which is exactly the board 3 of an unconstrained round one.
  @clubs [[1, 8, 14], [2, 7, 13], [3, 11, 16], [4, 10], [5, 12], [6, 9, 15]]

  defp field(n), do: for(tpn <- 1..n, do: team(tpn))

  defp pairs(%{pairs: pairs}),
    do: pairs |> Enum.map(&{min(&1.white, &1.black), max(&1.white, &1.black)}) |> Enum.sort()

  defp club_of(tpn), do: Enum.find_index(@clubs, &(tpn in &1))

  describe "the regional event (16 teams, 6 clubs, 5 rounds)" do
    test "round one: Gistel 1 meets seed 12, not Gistel 2, hard or soft" do
      opts = [round: 1, expected_rounds: 5]

      {:ok, fide} = TeamPairing.pair_round(field(16), opts)
      assert {3, 11} in pairs(fide)

      expected = [{1, 9}, {2, 10}, {3, 12}, {4, 11}, {5, 13}, {6, 14}, {7, 15}, {8, 16}]

      for key <- [:forbidden_pairs, :soft_pairs] do
        {:ok, round} = TeamPairing.pair_round(field(16), [{key, @clubs} | opts])
        assert pairs(round) == expected, inspect(key)
      end

      {:ok, soft} = TeamPairing.pair_round(field(16), [soft_pairs: @clubs] ++ opts)
      assert [%{soft: 0, criteria: {0, 0, 0}}] = soft.brackets
    end

    test "five played rounds with the clubs forbidden: no club meets itself" do
      for seed <- 1..12 do
        :rand.seed(:exsss, {seed, 3 * seed + 1, 11 * seed + 5})

        rounds =
          play_event(16, 5, :white, fn round_no, field, _absent, opts ->
            case TeamPairing.pair_round(field, [forbidden_pairs: @clubs] ++ opts) do
              {:ok, round} ->
                for {a, b} <- pairs(round) do
                  refute club_of(a) == club_of(b), "seed #{seed} round #{round_no}: #{a}-#{b}"
                end

                round

              {:error, reason} ->
                flunk("seed #{seed} round #{round_no}: #{inspect(reason)}")
            end
          end)

        assert rounds == 5
      end
    end

    test "five played rounds with the clubs soft: FIDE is never the worse for it" do
      for seed <- 1..12 do
        :rand.seed(:exsss, {seed, 5 * seed + 2, 13 * seed + 7})

        play_event(16, 5, :white, fn round_no, field, _absent, opts ->
          {:ok, fide} = TeamPairing.pair_round(field, opts)
          {:ok, soft} = TeamPairing.pair_round(field, [soft_pairs: @clubs] ++ opts)
          assert_soft_only_ties(fide, soft, @clubs, "seed #{seed} round #{round_no}")
          soft
        end)
      end
    end
  end

  describe "forbidden pairs" do
    test "a round-limited group applies in its rounds only" do
      {:ok, in_range} =
        TeamPairing.pair_round(field(16), round: 1, forbidden_pairs: [{[3, 11], 1, 2}])

      refute {3, 11} in pairs(in_range)

      {:ok, outside} =
        TeamPairing.pair_round(field(16), round: 1, forbidden_pairs: [{[3, 11], 2, 5}])

      assert {3, 11} in pairs(outside)
      assert outside == elem(TeamPairing.pair_round(field(16), round: 1), 1)
    end

    test "a round-limited group without :round is refused, not guessed at" do
      assert {:error, {:invalid_option, :round, nil}} =
               TeamPairing.pair_round(field(4), forbidden_pairs: [{[1, 2], 1, 3}])

      assert {:error, {:invalid_option, :round, nil}} =
               TeamPairing.pair_round(field(4), soft_pairs: [{[1, 2], 1, 3}])
    end

    test "a malformed option is an error naming it" do
      for {key, value} <- [
            forbidden_pairs: [1, 2],
            forbidden_pairs: "1 2",
            soft_pairs: [[1, :two]],
            soft_pairs: [{[1, 2], "1", 3}]
          ] do
        assert {:error, {:invalid_option, ^key, ^value}} =
                 TeamPairing.pair_round(field(4), [{key, value}, round: 1])
      end
    end

    test "groups that make the round unpairable say so, and which would let it pair" do
      # Team 1 may meet nobody.
      groups = [[1, 2], [1, 3], [1, 4]]

      assert {:error, {:forbidden_pairs, %{reason: :no_legal_pairing} = info}} =
               TeamPairing.pair_round(field(4), round: 1, forbidden_pairs: groups)

      assert info.groups == groups
      assert info.lifting == groups

      # One group forbidding everything: nothing smaller to lift.
      assert {:error, {:forbidden_pairs, %{groups: [[1, 2, 3, 4]], lifting: [[1, 2, 3, 4]]}}} =
               TeamPairing.pair_round(field(4), round: 1, forbidden_pairs: [[1, 2, 3, 4]])

      # Two groups each enough on its own: lifting either alone does not do.
      assert {:error, {:forbidden_pairs, %{lifting: []}}} =
               TeamPairing.pair_round(field(4),
                 round: 1,
                 forbidden_pairs: [[1, 2, 3, 4], [1, 2, 3, 4, 5]]
               )
    end

    test "an odd field: the bye's 3.4.1 sees the groups too" do
      assert {:error, {:forbidden_pairs, %{reason: :no_legal_bye, groups: [[1, 2, 3]]}}} =
               TeamPairing.pair_round(field(3), round: 1, forbidden_pairs: [[1, 2, 3]])

      # Only 1-2 forbidden: the bye goes to 3 by 3.4.4 (largest TPN), and
      # 3.4.1 then needs 1-2 paired, so it moves to 2 (or 1).
      {:ok, round} = TeamPairing.pair_round(field(3), round: 1, forbidden_pairs: [[1, 2]])
      assert round.bye in [1, 2]
      refute {1, 2} in pairs(round)
    end

    test "a round impossible without the groups says what it always said" do
      met = [team(1, opponents: [2]), team(2, opponents: [1])]
      assert {:error, :no_legal_pairing} = TeamPairing.pair_round(met, round: 2)

      assert {:error, :no_legal_pairing} =
               TeamPairing.pair_round(met, round: 2, forbidden_pairs: [[1, 2]])
    end

    test "groups naming teams not in the field are harmless" do
      {:ok, plain} = TeamPairing.pair_round(field(6), round: 1)

      assert {:ok, ^plain} =
               TeamPairing.pair_round(field(6), round: 1, forbidden_pairs: [[7, 8], [1, 99]])
    end
  end

  describe "soft pairs" do
    test "never block a round: an unavoidable soft pair is seated and counted" do
      {:ok, round} = TeamPairing.pair_round(field(4), round: 1, soft_pairs: [[1, 2, 3, 4]])
      assert length(round.pairs) == 2
      assert [%{soft: 2}] = round.brackets
    end

    test "never cost a FIDE criterion: [C8] keeps a soft pair it would otherwise lose" do
      # Two rounds in (the other opponents long gone): 1 and 4 had White
      # twice and want Black, 2 and 3 the reverse; 1 has met 3, 2 has met 4.
      # 1-2 / 3-4 fulfils everyone; 1-4 / 2-3 leaves two teams unfulfilled.
      teams = [
        team(1, mp: 2.0, opponents: [3, 91], colours: [:white, :white]),
        team(2, mp: 2.0, opponents: [4, 92], colours: [:black, :black]),
        team(3, mp: 2.0, opponents: [1, 93], colours: [:black, :black]),
        team(4, mp: 2.0, opponents: [2, 94], colours: [:white, :white])
      ]

      opts = [round: 3, expected_rounds: 7]
      {:ok, fide} = TeamPairing.pair_round(teams, opts)
      assert pairs(fide) == [{1, 2}, {3, 4}]

      {:ok, soft} = TeamPairing.pair_round(teams, [soft_pairs: [[1, 2]]] ++ opts)
      assert pairs(soft) == [{1, 2}, {3, 4}]
      assert [%{soft: 1, criteria: {0, 0, 0}}] = soft.brackets

      # Forbidden is another matter: the pair goes, and [C8] pays for it.
      {:ok, hard} = TeamPairing.pair_round(teams, [forbidden_pairs: [[1, 2]]] ++ opts)
      assert pairs(hard) == [{1, 4}, {2, 3}]
      assert [%{criteria: {2, 0, 0}}] = hard.brackets
    end

    test "a round whose FIDE pairing seats no soft pair is that pairing" do
      {:ok, fide} = TeamPairing.pair_round(field(8), round: 1)
      {:ok, soft} = TeamPairing.pair_round(field(8), round: 1, soft_pairs: [[1, 2], [5, 6]])

      assert soft.pairs == fide.pairs
      assert soft.bye == fide.bye
      assert Enum.map(soft.brackets, &Map.delete(&1, :soft)) == fide.brackets
    end

    test "empty options change nothing at all" do
      {:ok, fide} = TeamPairing.pair_round(field(9), round: 1)

      assert {:ok, ^fide} =
               TeamPairing.pair_round(field(9), round: 1, forbidden_pairs: [], soft_pairs: [])

      assert {:ok, ^fide} =
               TeamPairing.pair_round(field(9),
                 round: 1,
                 soft_pairs: [{[1, 5], 3, 4}],
                 forbidden_pairs: [{[1, 5], 3, 4}]
               )
    end

    test "explain: true changes nothing, and -x's account has the count" do
      opts = [round: 1, soft_pairs: @clubs, forbidden_pairs: [[1, 9]]]
      {:ok, plain} = TeamPairing.pair_round(field(16), opts)
      {:ok, explained} = TeamPairing.pair_round(field(16), [explain: true] ++ opts)
      assert Map.delete(explained, :explanation) == plain
    end
  end

  describe "played events against the brute-force reference (4-10 teams, 300 events)" do
    test "with random groups: the reference's round, no forbidden pair, soft only on ties" do
      checked =
        for seed <- 1..300, reduce: 0 do
          acc ->
            :rand.seed(:exsss, {seed, 17 * seed + 1, 3 * seed + 29})
            size = Enum.random(4..10)
            rounds = Enum.random(3..6)
            initial = Enum.random([:white, :black])
            {forbidden, soft} = random_groups(size, rounds)
            apart = [forbidden_pairs: forbidden, soft_pairs: soft]

            acc +
              play_event(size, rounds, initial, fn round_no, field, absent, opts ->
                where =
                  "seed #{seed} round #{round_no}, #{length(field)} teams, " <>
                    "forbidden #{inspect(forbidden)}, soft #{inspect(soft)}"

                reference =
                  ref_round(field, absent: absent, initial: initial, opts: apart ++ opts)

                case TeamPairing.pair_round(field, apart ++ opts) do
                  {:ok, engine} ->
                    assert normalise(engine) == Map.take(reference, [:bye, :pairs]),
                           "#{where}\n  engine:    #{inspect(normalise(engine))}\n" <>
                             "  reference: #{inspect(reference)}\n" <>
                             "  field:     #{inspect(Enum.map(field, &describe_team/1))}"

                    in_force = in_force(forbidden, round_no)

                    for {a, b} <- pairs(engine) do
                      refute {a, b} in in_force, "#{where}: forbidden #{a}-#{b} seated"
                    end

                    # The same round with the forbidden groups and without the
                    # soft ones: soft pairs may only choose between its ties.
                    {:ok, fide} =
                      TeamPairing.pair_round(field, [forbidden_pairs: forbidden] ++ opts)

                    assert_soft_only_ties(fide, engine, soft, where, round_no)

                    # Coverage: rounds the groups actually changed.
                    {:ok, unconstrained} = TeamPairing.pair_round(field, opts)
                    if fide.pairs != unconstrained.pairs, do: bump(:forbidden_moved)
                    if engine.pairs != fide.pairs, do: bump(:soft_moved)

                    if Enum.any?(engine.brackets, &(Map.get(&1, :soft, 0) > 0)),
                      do: bump(:soft_seated)

                    engine

                  {:error, reason} ->
                    assert reference == :impossible,
                           "#{where}: engine refused (#{inspect(reason)}), reference paired"

                    # A refusal the groups caused is named as theirs.
                    case TeamPairing.pair_round(field, opts) do
                      {:ok, _} ->
                        assert {:forbidden_pairs, %{}} = reason
                        bump(:forbidden_refused)

                      {:error, _} ->
                        refute match?({:forbidden_pairs, _}, reason)
                    end

                    :stop
                end
              end)
        end

      assert checked > 800

      # The groups did something worth checking, in every way they can.
      for key <- [:forbidden_moved, :forbidden_refused, :soft_moved, :soft_seated] do
        assert Process.get(key, 0) > 5, "#{key}: #{Process.get(key, 0)}"
      end
    end
  end

  defp bump(key), do: Process.put(key, Process.get(key, 0) + 1)

  # Random club-like groups over `size` teams: a couple of forbidden pairs,
  # some soft groups of two or three, some limited to a range of rounds.
  defp random_groups(size, rounds) do
    tpns = Enum.to_list(1..size)

    group = fn n ->
      members = Enum.take_random(tpns, n)

      if :rand.uniform(3) == 1 do
        first = Enum.random(1..rounds)
        {members, first, Enum.random(first..rounds)}
      else
        members
      end
    end

    forbidden = for _ <- 1..Enum.random(0..2)//1, do: group.(2)
    soft = for _ <- 1..Enum.random(1..3)//1, do: group.(Enum.random(2..3))
    {forbidden, soft}
  end

  defp in_force(groups, round) do
    for g <- groups,
        tpns =
          (case g do
             {tpns, first, last} -> if round in first..last, do: tpns, else: []
             tpns -> tpns
           end),
        a <- tpns,
        b <- tpns,
        a < b,
        do: {a, b}
  end

  # Soft pairs only choose between pairings FIDE ranks equal: the same bye,
  # the same brackets with the same upfloaters and the same {C8, C9, C10}, no
  # more soft pairs than FIDE's own answer seats - and FIDE's answer itself
  # whenever that seats none.
  defp assert_soft_only_ties(fide, soft, groups, where, round \\ 1) do
    soft_set = MapSet.new(in_force(groups, round))
    count = fn round -> Enum.count(pairs(round), &MapSet.member?(soft_set, &1)) end

    assert soft.bye == fide.bye, where

    assert Enum.map(soft.brackets, &Map.take(&1, [:residents, :upfloaters, :criteria])) ==
             Enum.map(fide.brackets, &Map.take(&1, [:residents, :upfloaters, :criteria])),
           where

    assert count.(soft) <= count.(fide), where

    if count.(fide) == 0 do
      assert soft.pairs == fide.pairs, "#{where}: no soft pair to avoid, yet the round moved"
    end

    if MapSet.size(soft_set) > 0 do
      assert Enum.sum(Enum.map(soft.brackets, & &1.soft)) == count.(soft), where
    end
  end
end
