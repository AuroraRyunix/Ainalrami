defmodule Ainalrami.FinalRoundTopscorersTest do
  @moduledoc """
  C.04.1.g's final-round exception: in the last round, two top scorers may be
  paired even when both hold an absolute preference for the same colour.

  Who counts as a "top scorer" is `points > playedRounds / 2`, and
  bbpPairings computes that as `(playedRounds * pointsForWin) >> 1` on
  DOUBLED point units - so the shift is an exact half, not a floor. This
  engine used `div(played_rounds, 2)`, which rounds down, and admitted a
  player on exactly half as a top scorer where the reference requires
  strictly more.

  The difference is invisible whenever `playedRounds` is even, because
  `div(n, 2) == n / 2` there. Every fuzz axis this project has measured ran
  `PAIRING_FUZZ_ROUNDS=9`, whose final round is paired with 8 rounds played
  - even. That is why an engine reported at 100.00% against bbpPairings on
  every axis still carried this: the corpus could not see it. Re-measured at
  `ROUNDS=8` (7 played, odd), 2,000 tournaments at a 12% bye rate:

      before   15051/15060 rounds = 99.94%   155831/155862 pairs = 99.98%
      after    15060/15060 rounds = 100.00%  155862/155862 pairs = 100.00%

  The same function also read `length(a.games)` - that player's own game
  count - rather than the tournament's played-round count. A player holding
  a pre-recorded bye for the round being paired carries one game more than
  the tournament has played, so the exception could fire a round early for
  them; a late entrant has fewer, so it could fail to fire at all. This is
  the exact indexing bug the rest of the module was deliberately converted
  away from (see `float_direction/4`, where it was worth ten points on the
  bye axis).
  """

  use ExUnit.Case, async: true

  alias Ainalrami.Pairing

  # Ranks 1 and 2 are the only active players in round 8: 3 and 4 each carry a
  # pre-recorded zero-point bye for it, so their history is one entry longer
  # than the tournament has played and `active_this_round?/2` excludes them.
  #
  # 1 and 2 have never met, and both hold five blacks to two whites - an
  # imbalance of 3, so both hold an ABSOLUTE preference for white. Pairing
  # them is therefore legal only if the final-round top-scorer exception
  # applies; otherwise the position has no legal pairing at all.
  defp field(points) do
    [
      duellist(1, points),
      duellist(2, points),
      bystander(3),
      bystander(4)
    ]
  end

  defp duellist(rank, points) do
    colours = ~w(b b b b b w w)
    opponents = [3, 4, 3, 4, 3, 4, 3]

    games =
      Enum.zip(colours, opponents)
      |> Enum.map(fn {colour, opp} ->
        %{result: "=", colour: colour, opponent_rank: opp}
      end)

    player(rank, points, games)
  end

  defp bystander(rank) do
    games =
      Enum.map(1..7, fn _ -> %{result: "=", colour: "w", opponent_rank: 1} end) ++
        [%{result: "Z", colour: nil, opponent_rank: nil}]

    player(rank, 3.5, games)
  end

  describe "the C10/C11 rungs, which exist only on this path" do
    # `bracket_edge_weight/8` only creates an edge where `colour_compatible?/2`
    # holds, and that already rejects a same-absolute-colour clash - so
    # outside the final-round exception, C10 and C11 are constant across every
    # candidate matching and nothing can distinguish them. They had no test at
    # all, because reaching them needs `expected_rounds`, the last round, AND
    # top scorers, which no fuzz axis sets up deliberately.

    test "the exception is confined to the final round" do
      # Same position, same points, one round earlier: the clash is absolute
      # and no exception applies, so the position is unpairable. This is what
      # makes the rung conditional rather than free.
      assert_raise Pairing.NoValidPairingError, fn ->
        Pairing.pair_next_round(field(4.0), expected_rounds: 9)
      end
    end

    test "without a round count, the exception never fires at all" do
      # `:expected_rounds` is optional, and `final_round_topscorers?/2`
      # answers false when it is absent - a caller who does not say how long
      # the tournament is cannot be in its last round.
      assert_raise Pairing.NoValidPairingError, fn ->
        Pairing.pair_next_round(field(4.0))
      end
    end

    test "a non-top-scorer pair is still refused in the final round" do
      # Both on 1.0 of 7 played. The round is right, the clash is right, and
      # they are simply not top scorers - so C10/C11 do not open the gate.
      assert_raise Pairing.NoValidPairingError, fn ->
        Pairing.pair_next_round(field(1.0), expected_rounds: 8)
      end
    end
  end

  defp player(rank, points, games) do
    %{
      name: "P#{rank}",
      title: "",
      federation: "",
      sex: "",
      fide_rating: 2000 - rank * 10,
      fide_number: nil,
      birth_date: "",
      points: points,
      rank: rank,
      games: games
    }
  end

  test "a player on exactly half the played rounds is NOT a top scorer" do
    # 7 played, so the threshold is 3.5 and 3.5 is not more than 3.5. Neither
    # player qualifies, the exception does not apply, and their absolute
    # same-colour clash leaves the position genuinely unpairable.
    #
    # `div(7, 2)` gave 3, both counted as top scorers, and the engine paired
    # them - a pairing bbpPairings refuses.
    assert_raise Pairing.NoValidPairingError, fn ->
      Pairing.pair_next_round(field(3.5), expected_rounds: 8)
    end
  end

  test "a player above half the played rounds is a top scorer, and the pair is allowed" do
    # The control. 4.0 > 3.5, so the exception applies and the same otherwise
    # illegal colour clash becomes pairable - without this, the test above
    # would pass on an engine that had simply stopped pairing anything.
    pairs = Pairing.pair_next_round(field(4.0), expected_rounds: 8)

    assert Enum.sort(Enum.map(pairs, fn {w, b} -> Enum.sort([w, b]) end)) == [[1, 2]]
  end
end
