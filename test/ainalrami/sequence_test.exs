defmodule Ainalrami.SequenceTest do
  @moduledoc """
  `Ainalrami.Sequence` against the examples C.04.3 Article 4 gives for itself.

  The regulations spell both orderings out with concrete sequences, which
  makes this one of the few parts of the Dutch system that can be checked
  against the text directly rather than against another implementation.
  """

  use ExUnit.Case, async: true

  alias Ainalrami.Sequence

  describe "4.2 transpositions" do
    test "the regulations' 11-player homogeneous example, start and end" do
      # "in a 11-player homogeneous bracket, it is 6-7-8-9-10, 6-7-8-9-11,
      #  6-7-8-10-11, ..., 6-11-10-9-8, 7-6-8-9-10, ..., 11-10-9-8-7
      #  (720 transpositions)"
      #
      # S1 is 1..5 (MaxPairs = 5), S2 is 6..11, and only the first N1 = 5
      # entries of each ordering are significant.
      s2 = [6, 7, 8, 9, 10, 11]
      seq = Sequence.transpositions(s2, 5)

      prefixes = Enum.map(seq, &Enum.take(&1, 5))

      # Every anchor the regulations state, in order.
      assert length(seq) == 720
      assert Enum.take(prefixes, 2) == [[6, 7, 8, 9, 10], [6, 7, 8, 9, 11]]
      # "..., 6-11-10-9-8, 7-6-8-9-10, ..." - the handover from prefixes
      # starting with 6 to those starting with 7.
      assert Enum.at(prefixes, 119) == [6, 11, 10, 9, 8]
      assert Enum.at(prefixes, 120) == [7, 6, 8, 9, 10]
      assert List.last(prefixes) == [11, 10, 9, 8, 7]
    end

    test "the published example's THIRD entry contradicts its own stated rule" do
      # 4.2.2 says transpositions are "sorted depending on the lexicographic
      # value of their first N1 BSN(s)". Its illustrative sequence reads
      # "6-7-8-9-10, 6-7-8-9-11, 6-7-8-10-11, ...". The third entry cannot be
      # right under that rule: [6,7,8,10,9] is lexicographically smaller than
      # [6,7,8,10,11] and is a distinct, valid transposition, so it must come
      # between them.
      #
      # Five of the six anchors the example states DO match a strict reading
      # - the count (720), the first two entries, the 6-to-7 handover
      # ("6-11-10-9-8, 7-6-8-9-10") and the final entry ("11-10-9-8-7"), all
      # asserted above. Only the third does not. Read as an elision or a
      # typo in the published example rather than a different ordering,
      # because no ordering consistent with the other five anchors puts
      # [6,7,8,10,11] third.
      #
      # Pinned as a test so the reading is a recorded decision rather than an
      # accident of implementation. If FIDE clarifies otherwise, this is the
      # test that should fail.
      prefixes =
        [6, 7, 8, 9, 10, 11]
        |> Sequence.transpositions(5)
        |> Enum.map(&Enum.take(&1, 5))

      assert Enum.at(prefixes, 2) == [6, 7, 8, 10, 9]
      assert Enum.at(prefixes, 3) == [6, 7, 8, 10, 11]
    end

    test "the count matches the regulations for a heterogeneous bracket too" do
      # "if the bracket is heterogeneous with two MDPs, it is: 3-4, 3-5, 3-6,
      #  ..., 3-11, 4-3, 4-5, ..., 11-10 (72 transpositions)"
      #
      # Nine resident BSNs (3..11) in S2, N1 = 2 significant entries.
      seq = Sequence.transpositions(Enum.to_list(3..11), 2)

      assert length(seq) == 72

      assert Enum.map(Enum.take(seq, 3), &Enum.take(&1, 2)) == [[3, 4], [3, 5], [3, 6]]
      assert Enum.take(List.last(seq), 2) == [11, 10]
    end

    test "orderings differing only past the significant prefix are one transposition" do
      # 4.2.2's note: the remaining BSNs "are ignored in this context",
      # because they are bound for the remainder or to downfloat. Two
      # orderings sharing a prefix are the same candidate.
      seq = Sequence.transpositions([1, 2, 3], 1)

      assert length(seq) == 3
      assert Enum.map(seq, &hd/1) == [1, 2, 3]
    end
  end

  describe "4.3 exchanges" do
    test "rule 1: fewer exchanged BSNs wins" do
      # "exchanging just one BSN is better than exchanging two of them"
      s1 = [1, 2, 3]
      s2 = [4, 5, 6]

      sizes =
        for {from_s1, _from_s2} <- raw_exchanges(s1, s2),
            do: length(from_s1)

      assert sizes == Enum.sort(sizes), "single-BSN exchanges must all precede pairs"
    end

    test "rule 2: the regulations' own eleven-player examples" do
      # "in a bracket containing eleven players, exchanging 6 with 4 is
      #  better than exchanging 8 with 5; similarly exchanging 8+6 with 4+3
      #  is better than exchanging 9+8 with 5+4"
      s1 = Enum.to_list(1..5)
      s2 = Enum.to_list(6..11)

      assert precedes?(s1, s2, {[4], [6]}, {[5], [8]})
      assert precedes?(s1, s2, {[3, 4], [6, 8]}, {[4, 5], [8, 9]})
    end

    test "rule 3: the largest differing BSN moved out of S1 wins" do
      # "moving 5 from S1 to S2 is better than moving 4; similarly, 5-2 is
      #  better than 4-3; 5-4-1 is better than 5-3-2"
      s1 = Enum.to_list(1..5)
      s2 = Enum.to_list(6..11)

      # Held at equal size and equal sum difference, so rule 3 decides.
      assert precedes?(s1, s2, {[2, 5], [6, 8]}, {[3, 4], [6, 8]})
      assert precedes?(s1, s2, {[1, 4, 5], [6, 7, 9]}, {[2, 3, 5], [6, 7, 9]})
    end

    test "rule 4: the smallest differing BSN moved into S1 wins" do
      # "moving 6 from S2 to S1 is better than moving 7; similarly, 6-9 is
      #  better than 7-8"
      s1 = Enum.to_list(1..5)
      s2 = Enum.to_list(6..11)

      assert precedes?(s1, s2, {[3, 4], [6, 9]}, {[3, 4], [7, 8]})
    end

    test "an exchange returns both subgroups re-sorted per Article 1.2" do
      # 3.6: "reordering the newly formed S1 and S2 according to Article 1.2".
      [{new_s1, new_s2} | _] = Sequence.exchanges([1, 2, 3], [4, 5, 6])

      assert new_s1 == Enum.sort(new_s1)
      assert new_s2 == Enum.sort(new_s2)
      assert Enum.sort(new_s1 ++ new_s2) == [1, 2, 3, 4, 5, 6]
    end
  end

  describe "4.4 sets of pairable MDPs" do
    test "sorted by their smallest differing BSN" do
      assert Sequence.mdp_sets([1, 2, 3], 2) == [[1, 2], [1, 3], [2, 3]]
    end
  end

  # The raw (pre-application) exchange list, in order - what `exchanges/2`
  # sorts before applying. Rebuilt here rather than exposed, so the module's
  # public surface stays the two orderings themselves.
  defp raw_exchanges(s1, s2) do
    max_size = min(length(s1), length(s2))

    for size <- 1..max_size,
        from_s1 <- comb(s1, size),
        from_s2 <- comb(s2, size) do
      {from_s1, from_s2}
    end
    |> Enum.sort_by(&Sequence.exchange_key(&1, s1))
  end

  defp precedes?(s1, s2, a, b) do
    Sequence.exchange_key(a, s1) < Sequence.exchange_key(b, s2)
  end

  defp comb(_l, 0), do: [[]]
  defp comb([], _n), do: []
  defp comb([h | t], n), do: for(r <- comb(t, n - 1), do: [h | r]) ++ comb(t, n)
end
