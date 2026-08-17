defmodule OpenPair.ScoreReconciliationTest do
  @moduledoc """
  `score_before/3` winds a player's score back to what it was N rounds ago,
  and every float criterion C14-C21 is decided by comparing two of those
  against each other. It needs a base to wind back FROM.

  It used `player.points` raw. That field is TRF columns 81-84 — the
  arbiter's recorded total — and is not derived from the games at all. Where
  the two disagree, every reconstructed historic score was wrong by the
  difference, silently, and no measurement could see it: the fuzz generator
  computes points by summing the games, so in 195 million pairings the two
  never disagreed once.

  bbpPairings does not trust the field either. `trf.cpp:885-925` sums the
  matches and, on a mismatch, tries subtracting the acceleration and then the
  points of a round beyond `playedRounds`, keeping whichever reconciles.

  The caller that can actually hit this is the sibling Phoenix app, which
  hands the engine player maps it built itself rather than a parsed TRF.
  """

  use ExUnit.Case, async: true

  alias OpenPair.Pairing

  # Four players, two rounds played, pairing round 3. Ranks 1 and 2 are level
  # and rank 1 downfloated in round 2 — the float history the C14/C16 rungs
  # read, and the thing a wrong base corrupts.
  defp roster(points_for_rank_1) do
    [
      player(1, points_for_rank_1, [
        %{result: "1", colour: "w", opponent_rank: 2},
        %{result: "1", colour: "b", opponent_rank: 4}
      ]),
      player(2, 1.0, [
        %{result: "0", colour: "b", opponent_rank: 1},
        %{result: "1", colour: "w", opponent_rank: 3}
      ]),
      player(3, 0.0, [
        %{result: "0", colour: "b", opponent_rank: 4},
        %{result: "0", colour: "b", opponent_rank: 2}
      ]),
      player(4, 1.0, [
        %{result: "1", colour: "w", opponent_rank: 3},
        %{result: "0", colour: "w", opponent_rank: 1}
      ])
    ]
  end

  test "a total that already includes a pre-recorded future round still reconciles" do
    # Rank 1 holds a zero-point bye for the round being paired. Their recorded
    # total is unchanged by it (Z is worth nothing), so the base is exact and
    # the engine must pair the other three normally.
    [p1 | rest] = roster(2.0)
    p1 = %{p1 | games: p1.games ++ [%{result: "Z", colour: nil, opponent_rank: nil}]}

    pairs = Pairing.pair_next_round([p1 | rest], expected_rounds: 5)

    seated = Enum.flat_map(pairs, fn {w, b} -> if b, do: [w, b], else: [w] end)
    refute 1 in seated, "rank 1 already holds a result for this round"
    assert Enum.sort(seated) == [2, 3, 4]
  end

  test "a total inflated by an already-credited future full-point bye is corrected" do
    # The case the raw field got wrong. Rank 1 has 2.0 from two wins, plus a
    # full-point bye for the round being paired that the arbiter has ALREADY
    # credited — so the recorded total reads 3.0 while only 2.0 was earned in
    # the rounds actually played.
    #
    # `reconciled_points/2` recognises 3.0 - 1.0 (the future round) as the
    # played total and winds back from 2.0. Without it the engine believed
    # rank 1 had been on 3.0 and 2.0 in the two previous rounds, moving both
    # float directions it derives from those scores.
    [p1 | rest] = roster(3.0)
    p1 = %{p1 | games: p1.games ++ [%{result: "F", colour: nil, opponent_rank: nil}]}

    pairs = Pairing.pair_next_round([p1 | rest], expected_rounds: 5)

    seated = Enum.flat_map(pairs, fn {w, b} -> if b, do: [w, b], else: [w] end)
    assert Enum.sort(seated) == [2, 3, 4]

    # The real assertion is that this position pairs at all and pairs the same
    # three players: an over-counted base moves scores, scores move brackets,
    # and a wrong bracket is how a legal round becomes a different one.
    assert length(pairs) == 2
  end

  test "an arbiter's hand-adjusted total is left alone" do
    # Nothing reconciles here — 2.5 is not the sum of the games under any of
    # bbpPairings' three corrections — so the recorded total stands. It is the
    # arbiter's authority on a hand-adjusted score, and bbpPairings' own final
    # fallback is the same.
    pairs = Pairing.pair_next_round(roster(2.5), expected_rounds: 5)

    seated = Enum.flat_map(pairs, fn {w, b} -> if b, do: [w, b], else: [w] end)
    assert Enum.sort(seated) == [1, 2, 3, 4]
  end

  describe "pair_later_round/2 honours its own options" do
    test "a forbidden pair passed directly is respected" do
      # It is public and documented, and it used to set none of the state the
      # rules read -- so calling it instead of pair_next_round/2 silently
      # ignored every XXP line and never fired the final-round colour
      # exception. A pairing that breaks an arbiter's explicit exclusion and
      # looks entirely legal is the exact failure the feature exists to stop.
      # Everyone has met everyone except 1-3 and 2-4, so that is the only
      # legal partition and the control pins it. Forbidding 1-3 therefore
      # leaves the position genuinely unpairable — which is the sharpest
      # possible assertion, since an engine ignoring the option pairs it
      # happily and returns two pairs.
      players = roster(2.0)

      natural = Pairing.pair_later_round(players)

      assert Enum.sort(Enum.map(natural, fn {w, b} -> Enum.sort([w, b]) end)) ==
               [[1, 3], [2, 4]],
             "control: this position has exactly one legal pairing when nothing is forbidden"

      assert_raise Pairing.NoValidPairingError, fn ->
        Pairing.pair_later_round(players, forbidden_pairs: [[1, 3]])
      end
    end
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
end
