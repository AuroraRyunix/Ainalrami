defmodule OpenPair.Sequence do
  @moduledoc """
  Article 4 of C.04.3 (2026): the order in which a bracket's candidate
  pairings are generated.

  The regulations pair a bracket by *enumeration*. Split it into S1 and S2
  (3.2), pair S1[i] with S2[i] (3.3), and if the result is not perfect,
  alter the composition in a defined sequence (3.5-3.7) — transpositions of
  S2 first, then exchanges between S1 and S2 — taking the first perfect
  candidate. When no perfect candidate exists, 3.8.1 picks the best on C5
  then C6-C21, and breaks a remaining tie by **which was generated earlier**.

  `OpenPair.Pairing` does not enumerate. It solves each bracket as a
  maximum-weight matching whose edge weights pack C1-C21 in priority order,
  which reaches the same optimum without walking the sequence. The two agree
  on which pairing is best; they can only differ when several candidates tie
  on *every* criterion, where the regulations' tie-break is generation order
  and the engine's is `transposition_key/3`'s lexicographic key.

  This module implements the generation order itself, so that claim can be
  tested rather than asserted. It is deliberately independent of the engine:
  it knows nothing about criteria, weights or legality, only about the order
  Article 4 puts candidates in.

  ## What is implemented

    * `transpositions/2` — 4.2. All orderings of S2, sorted by the
      lexicographic value of their first N1 entries, where N1 is the size of
      S1. The remaining entries are ignored for ordering purposes, because
      they represent players bound for the remainder or for downfloating.

    * `exchanges/1` — 4.3. All swaps of equally sized groups between the
      original S1 and S2, sorted by 4.3.2's four comparison rules in order:
      fewest BSNs exchanged; then smallest difference between the sums moved
      each way; then largest differing BSN moved S1->S2; then smallest
      differing BSN moved S2->S1.

  Both are expressed over BSNs (4.1): a bracket's members tagged 1, 2, 3 …
  in Article 1.2 order.
  """

  @doc """
  Every ordering of `s2`, in Article 4.2 order.

  `n1` is the number of players in S1. Orderings are sorted by the
  lexicographic value of their first `n1` entries; entries past that are
  ignored when ordering, since they are bound for the remainder or to
  downfloat.

  The regulations' own example, for an 11-player homogeneous bracket
  (S1 = 1..5, S2 = 6..11): "6-7-8-9-10, 6-7-8-9-11, 6-7-8-10-11, …,
  6-11-10-9-8, 7-6-8-9-10, …, 11-10-9-8-7 (720 transpositions)".
  """
  def transpositions(s2, n1) do
    s2
    |> permutations()
    |> Enum.sort_by(&Enum.take(&1, n1))
    |> Enum.uniq_by(&Enum.take(&1, n1))
  end

  @doc """
  Every exchange between `s1` and `s2`, in Article 4.3 order, as
  `{new_s1, new_s2}` pairs already re-sorted per Article 1.2 (here: ascending
  BSN, since BSNs are assigned in that order).

  The identity (exchanging nothing) is not included — 3.6 reaches exchanges
  only after transpositions are exhausted, and the unexchanged composition
  has already been tried.
  """
  def exchanges(s1, s2) do
    max_size = min(length(s1), length(s2))

    for size <- 1..max_size//1,
        from_s1 <- combinations(s1, size),
        from_s2 <- combinations(s2, size) do
      {from_s1, from_s2}
    end
    |> Enum.sort_by(&exchange_key(&1, s1))
    |> Enum.map(fn {out, in_} ->
      {Enum.sort((s1 -- out) ++ in_), Enum.sort((s2 -- in_) ++ out)}
    end)
  end

  @doc """
  4.3.2's comparison key for one exchange, lower being higher priority.

  Exposed because the ordering is the whole point of the article and is
  worth testing directly against the examples the regulations give.
  """
  def exchange_key({from_s1, from_s2}, _s1) do
    sum_out = Enum.sum(from_s1)
    sum_in = Enum.sum(from_s2)

    # 4.3.2 rules 3 and 4 speak of "the largest differing BSN among those
    # moved from S1" and "the smallest differing BSN among those moved from
    # S2". With both groups sorted, comparing the sequences elementwise picks
    # out the differing member; rule 3 wants the LARGER to win, so it is
    # negated, and rule 4 wants the smaller, so it is not.
    {
      length(from_s1),
      abs(sum_in - sum_out),
      Enum.map(Enum.sort(from_s1, :desc), &(-&1)),
      Enum.sort(from_s2)
    }
  end

  @doc """
  4.4.2: valid sets of pairable MDPs, sorted by their smallest differing BSN.

  `mdps` are the moved-down players' BSNs; `size` is how many of them can be
  paired in this bracket (M1). The rest go to the Limbo (3.2.4).
  """
  def mdp_sets(mdps, size) do
    mdps
    |> combinations(size)
    |> Enum.sort()
  end

  ## ---------- plumbing ----------

  defp permutations([]), do: [[]]

  defp permutations(list) do
    for head <- list, tail <- permutations(list -- [head]), do: [head | tail]
  end

  defp combinations(_list, 0), do: [[]]
  defp combinations([], _size), do: []

  defp combinations([head | tail], size) do
    with_head = for rest <- combinations(tail, size - 1), do: [head | rest]
    with_head ++ combinations(tail, size)
  end
end
