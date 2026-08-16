defmodule OpenPair.ExplainRoundTest do
  @moduledoc """
  `OpenPair.Pairing.explain_round/3` — the diagnostic behind
  `tools/adjudicate.exs`, and the tool every "ours scores better" / "theirs
  scores better" verdict in TODO.md was produced with.

  It had no test at all until this file, which is exactly how it came to
  skip `with_float_history/2`. The real path (`pair_later_round/1`) stamps
  float history over the whole roster before accelerating it; the
  diagnostic stamped acceleration and colour stats only. `float_of/2` then
  read `:none` for every player in every position, so **C14-C21 scored the
  same constant on both sides of every comparison** — C14/C16 pinned at
  zero, C15/C17 pinned at one per in-bracket pair.

  Why that is worth a test rather than a shrug: it could never invent a
  disagreement, since both engines' answers were scored with the identical
  blank history and a tie stayed a tie. It could only MISATTRIBUTE one. A
  round genuinely decided on a float rung was reported as tying there and
  differing further down the ladder — and "the rung a disagreement
  surfaces on is not the rung that caused it" is already this project's
  most expensive recurring lesson.
  """

  use ExUnit.Case, async: true

  alias OpenPair.Pairing

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
  # r-1 — which is the only way any C14 term can be non-zero.
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
end
