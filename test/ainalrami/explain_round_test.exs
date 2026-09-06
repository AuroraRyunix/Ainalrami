defmodule Ainalrami.ExplainRoundTest do
  @moduledoc """
  `Ainalrami.Pairing.explain_round/3` - the diagnostic behind
  `tools/adjudicate.exs`, and the tool every "ours scores better" / "theirs
  scores better" verdict in docs/engineering-log.md was produced with.

  It had no test at all until this file, which is exactly how it came to
  skip `with_float_history/2`. The real path (`pair_later_round/1`) stamps
  float history over the whole roster before accelerating it; the
  diagnostic stamped acceleration and colour stats only. `float_of/2` then
  read `:none` for every player in every position, so **C14-C21 scored the
  same constant on both sides of every comparison** - C14/C16 pinned at
  zero, C15/C17 pinned at one per in-bracket pair.

  Why that is worth a test rather than a shrug: it could never invent a
  disagreement, since both engines' answers were scored with the identical
  blank history and a tie stayed a tie. It could only MISATTRIBUTE one. A
  round genuinely decided on a float rung was reported as tying there and
  differing further down the ladder - and "the rung a disagreement
  surfaces on is not the rung that caused it" is already this project's
  most expensive recurring lesson.
  """

  use ExUnit.Case, async: true

  alias Ainalrami.Pairing

  # Six players, two rounds played, round 3 about to be paired.
  #
  #   R1  1>2  3>4  5>6            -> 1,3,5 on 1.0; 2,4,6 on 0.0
  #   R2  1>3  5>2  4>6
  #
  # R2's middle pair is the point: rank 5 (1.0) was paired against rank 2
  # (0.0), so 5 was floated DOWN and 2 floated UP. Everyone else met an
  # equal score and carries no float.
  #
  # That leaves round 3 with brackets {1,5} on 2.0, {3,4} on 1.0, {2,6} on
  # 0.0, and rank 5 sitting in the top bracket holding a `:down` stamp for
  # r-1 - which is the only way any C14 term can be non-zero.
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

  test "float history is stamped, so the C14-C17 rungs can actually score" do
    report = Pairing.explain_round(roster(), [{1, 5}, {3, 4}, {2, 6}], expected_rounds: 9)

    c14 = total(report, "C14 downfloat repeat r-1")

    assert c14 > 0, """
    C14 scored #{c14}. Rank 5 downfloated in round 2 and is paired inside its
    own bracket in the round being scored, so this rung has something to say.
    Zero here means `explain_round/3` is not stamping float history and every
    C14-C21 verdict it produces is blank on both sides.
    """
  end

  test "the r-2 lookback reads two rounds back, not just the last one" do
    # C14/C16 are the only two float rungs worth asserting on. C15/C17 are
    # `bit(not (crossing? and ... == :up))`, so a blank history scores them
    # ONE per in-bracket pair, not zero -- an assertion that they are
    # non-zero passes with the bug still in place, which an earlier draft of
    # this test did.
    #
    # Three rounds played, round 4 about to be paired:
    #
    #   R1  1>2  3>4  5>6
    #   R2  1>3  5>2  4>6      -> 5 floated down, 2 floated up
    #   R3  1>5  3>6  4>2      -> 3 and 4 floated down, 6 and 2 floated up
    #
    # Round 4 brackets are {1} on 3.0, {5,3,4} on 2.0, {2,6} on 0.0. Scoring
    # the pair {5,3} inside that middle bracket puts BOTH lookbacks in play
    # at once and distinguishes them: rank 3 floated down in R3 (r-1, so
    # C14) and rank 5 floated down in R2 (r-2, so C16), while each is
    # `:none` at the other distance. An index that reads only r-1, or reads
    # r-2 off the wrong element, drops one of the two.
    players = [
      player(1, 3.0, [win(2, "w"), win(3, "w"), win(5, "w")]),
      player(2, 0.0, [loss(1, "b"), loss(5, "b"), loss(4, "b")]),
      player(3, 2.0, [win(4, "w"), loss(1, "b"), win(6, "w")]),
      player(4, 2.0, [loss(3, "b"), win(6, "w"), win(2, "w")]),
      player(5, 2.0, [win(6, "w"), win(2, "w"), loss(1, "b")]),
      player(6, 0.0, [loss(5, "b"), loss(4, "b"), loss(3, "b")])
    ]

    report = Pairing.explain_round(players, [{1, 4}, {5, 3}, {2, 6}], expected_rounds: 9)

    assert total(report, "C14 downfloat repeat r-1") > 0,
           "rank 3 floated down in round 3 and is paired in-bracket here"

    assert total(report, "C16 downfloat repeat r-2") > 0,
           "rank 5 floated down in round 2, which is two rounds back from the round being paired"
  end

  defp total(report, label) do
    Enum.reduce(report, 0, fn bracket, acc ->
      acc +
        Enum.reduce(bracket.rungs, 0, fn
          {^label, value}, inner -> inner + value
          _, inner -> inner
        end)
    end)
  end

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

  defp win(opponent, colour),
    do: %{result: "1", colour: colour, opponent_rank: opponent}

  defp loss(opponent, colour),
    do: %{result: "0", colour: colour, opponent_rank: opponent}

  describe "per-edge rungs" do
    test "a bracket's rungs are exactly the column-wise sum of its edges'" do
      # This is the property the whole feature rests on. If it ever stops
      # holding, a caller attributing a criterion's cost to a board is
      # attributing something that is not there.
      report = Pairing.explain_round(roster(), [{1, 5}, {3, 4}, {2, 6}], expected_rounds: 9)

      for bracket <- report do
        summed =
          bracket.edge_rungs
          |> Enum.map(fn {_edge, rungs} -> Enum.map(rungs, &elem(&1, 1)) end)
          |> Enum.zip_with(&Enum.sum/1)

        assert summed == Enum.map(bracket.rungs, &elem(&1, 1)), """
        bracket #{bracket.group}: the per-edge rungs do not add up to the
        bracket's own totals.

          per-edge sum: #{inspect(summed)}
          bracket:      #{inspect(Enum.map(bracket.rungs, &elem(&1, 1)))}
        """

        # Same labels, same order, so a caller can zip them positionally.
        for {_edge, rungs} <- bracket.edge_rungs do
          assert Enum.map(rungs, &elem(&1, 0)) == Enum.map(bracket.rungs, &elem(&1, 0))
        end
      end
    end

    test "there is one entry per edge, in `pairs` order then the cross edges" do
      report = Pairing.explain_round(roster(), [{1, 5}, {3, 4}, {2, 6}], expected_rounds: 9)

      for bracket <- report do
        assert length(bracket.edge_rungs) == bracket.edge_count

        # The kept pairs come first and in the same order, so a caller can
        # line an entry up with the board it belongs to.
        leading = bracket.edge_rungs |> Enum.take(length(bracket.pairs)) |> Enum.map(&elem(&1, 0))
        assert leading == bracket.pairs
      end
    end
  end

  describe "the state the pairing was made from" do
    # Everything in this block was computed on every round this engine has
    # ever paired and then discarded at the report boundary. The panel that
    # reads it could describe what the criteria cost, and could not answer
    # the only question an arbiter is ever actually asked at the board.
    setup do
      %{report: Pairing.explain_round(roster(), [{1, 5}, {3, 4}, {2, 6}], expected_rounds: 9)}
    end

    test "a rematch inside a bracket is reported, with the round they met", %{report: report} do
      # 3 and 4 are both on 1.0 and met in round 1, so the bracket they
      # share cannot use the one pair it most obviously would.
      bracket = Enum.find(report, &(&1.group == 1.0))

      assert [%{players: [3, 4], reason: :rematch, round: 1}] = bracket.exclusions
    end

    test "two players with the same absolute colour cannot meet", %{report: report} do
      # 1 and 5 both won twice with White: colour difference +2 each, so
      # both are ABSOLUTELY due Black and the pair is forbidden outright.
      bracket = Enum.find(report, &(&1.group == 2.0))

      assert [%{players: [1, 5], reason: :colour, colour: "b"}] = bracket.exclusions
    end

    test "each player's colour state is reported the way FIDE classifies it", %{report: report} do
      bracket = Enum.find(report, &(&1.group == 2.0))
      one = Enum.find(bracket.states, &(&1.rank == 1))

      assert one.colours == ["w", "w"]
      assert one.whites == 2
      assert one.blacks == 0
      # Signed, unlike the `imbalance` the criteria use: "+2" and "-2" are
      # opposite complaints and a colour column has to tell them apart.
      assert one.difference == 2
      assert one.preference == "b"
      assert one.class == :absolute
    end

    test "a balanced player is mild, not strong", %{report: report} do
      # 3 played White then Black: balanced, so due the alternation only.
      bracket = Enum.find(report, &(&1.group == 1.0))
      three = Enum.find(bracket.states, &(&1.rank == 3))

      assert three.difference == 0
      assert three.class == :mild
      assert three.preference == "w"
    end

    test "float history rides along, because C14-C21 grade it", %{report: report} do
      bracket = Enum.find(report, &(&1.group == 2.0))
      five = Enum.find(bracket.states, &(&1.rank == 5))

      # 5 (1.0) was paired against 2 (0.0) in round 2 - a downfloat.
      assert five.floated_last_round == :down
    end

    test "the subgroups are the ones the pairing was built from", %{report: report} do
      bracket = Enum.find(report, &(&1.group == 1.0))

      # Homogeneous bracket of two: it halves.
      refute bracket.heterogeneous?
      assert bracket.s1 == [3]
      assert bracket.s2 == [4]
    end

    # The split shown and the split used have to be the same object, or the
    # panel describes a different tournament than the one on the board.
    test "S1/S2 is the same split transposition_key/3 pairs against" do
      bracket = [
        player(1, 1.0, [win(2, "w")]),
        player(3, 1.0, [win(4, "w")]),
        player(5, 1.0, [win(6, "b")]),
        player(7, 1.0, [win(8, "b")])
      ]

      assert Pairing.subgroups(bracket, 1.0) == {Enum.take(bracket, 2), Enum.drop(bracket, 2)}
    end

    test "a heterogeneous bracket splits into moved-down players and residents" do
      moved_down = player(1, 2.0, [win(2, "w"), win(3, "w")])
      resident_a = player(4, 1.0, [win(5, "w"), loss(6, "b")])
      resident_b = player(7, 1.0, [loss(8, "b"), win(9, "w")])

      {s1, s2} = Pairing.subgroups([moved_down, resident_a, resident_b], 1.0)

      assert Enum.map(s1, & &1.rank) == [1]
      assert Enum.map(s2, & &1.rank) == [4, 7]
    end

    test "round one excludes nothing - nobody has played anybody" do
      roster = for r <- 1..6, do: player(r, 0.0, [])
      [bracket] = Pairing.explain_round(roster, [{1, 4}, {2, 5}, {3, 6}], expected_rounds: 5)

      assert bracket.exclusions == []
      assert Enum.all?(bracket.states, &(&1.class == :none))
    end
  end
end
