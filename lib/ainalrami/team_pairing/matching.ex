defmodule Ainalrami.TeamPairing.Matching do
  @moduledoc """
  Perfect-matching feasibility for team pairing - the [C3] completion
  oracle.

  Team pairing never *solves* a matching (C.04.6 3.6 defines an enumeration
  order and a predicate, not an optimum - see `Ainalrami.TeamPairing`), but
  it constantly asks one question: *can this set of teams still be fully
  paired without a rematch?* That question gates the bye (3.4.1), every
  candidate upfloater set (3.5.5), the [C6] look-ahead, and every prefix of
  the 3.6 enumeration.

  ## Representation

  Teams are bitmask indices. `feasible?/2` takes the mask of teams still to
  pair and an adjacency map `index => bitmask of allowed partners` (allowed
  = they have not met). An empty mask is trivially feasible.

  ## Why memoised search rather than a blossom algorithm

  The theoretically right tool is Edmonds' blossom algorithm - polynomial
  on any graph. What is implemented instead is: a greedy fast path, then
  exhaustive search over the lowest-indexed unmatched team's partners,
  memoised on the remaining-set bitmask.

  The reason is where the inputs actually live. A team event is tens of
  teams, not hundreds; a team has met at most `round - 1` others, so the
  allowed graph is near-complete for the whole event, and on near-complete
  graphs the greedy pass alone almost always answers. The memoised search
  only runs when greedy fails, which takes a genuinely tangled sub-bracket
  - and those are small, because tangling requires shared history.

  The trade is admitted rather than hidden: on an adversarial large sparse
  graph the memo table could grow exponentially. `@memo_limit` caps it, and
  hitting the cap raises `Ainalrami.TeamPairing.Matching.LimitError` with a
  message saying exactly what to do - it never returns a wrong answer.
  If a real event ever trips it, that is the day this module grows a
  blossom implementation; until then the simple code is the one whose
  correctness is checkable by reading.

  ## Since 2026-09-16

  The premise above ("tens of teams, not hundreds") did not survive a run of
  generated 100-500 team events, where building an adjacency per question
  was most of a round's cost. Round pairing now asks its questions through
  `Ainalrami.TeamPairing.Field` - one adjacency per round, `greedy_cover?/2`
  for the witness, an exact maximum matching behind it - and the 3.6 walk
  through `bipartite_perfect?/3`. `feasible?/2` above is still what answers
  when a round's history is one-sided or has duplicate TPNs, exactly as it
  did.
  """

  defmodule LimitError do
    defexception [:message]
  end

  @memo_limit 500_000

  import Bitwise

  @doc """
  Whether every team in `mask` can be paired with an allowed partner also
  in `mask`.

  `adj` maps each index to the bitmask of its allowed partners (symmetric;
  a team is never its own partner). Odd-popcount masks are infeasible by
  parity before any search.
  """
  def feasible?(mask, _adj) when mask == 0, do: true

  def feasible?(mask, adj) do
    cond do
      rem(popcount(mask), 2) == 1 ->
        false

      greedy?(mask, adj) ->
        true

      true ->
        {result, _memo} = search(mask, adj, %{})
        result
    end
  end

  # Repeatedly match the lowest unpaired index to its lowest allowed
  # partner. No backtracking - a success is a witness, a failure proves
  # nothing. On the near-complete graphs real events produce, this is the
  # whole cost of the oracle.
  defp greedy?(0, _adj), do: true

  defp greedy?(mask, adj) do
    v = lowest_bit(mask)
    partners = Map.get(adj, v, 0) &&& mask

    if partners == 0 do
      false
    else
      u = lowest_bit(partners)
      greedy?(mask &&& bnot(1 <<< v ||| 1 <<< u), adj)
    end
  end

  # Exhaustive: the lowest unpaired index must pair with SOMEBODY, so
  # branching on its partners alone is complete. Memoised on the mask -
  # subproblems repeat heavily because pair order does not matter.
  defp search(0, _adj, memo), do: {true, memo}

  defp search(mask, adj, memo) do
    case memo do
      %{^mask => hit} ->
        {hit, memo}

      _ ->
        if map_size(memo) > @memo_limit do
          raise LimitError,
            message:
              "completion oracle exceeded #{@memo_limit} memo entries on a " <>
                "#{popcount(mask)}-team subproblem. The input graph is larger and " <>
                "sparser than any real team event produces; if this is a real " <>
                "event, this module needs the blossom implementation its moduledoc " <>
                "promises."
        end

        v = lowest_bit(mask)
        partners = Map.get(adj, v, 0) &&& mask
        {found, memo} = try_partners(partners, v, mask, adj, memo)
        {found, Map.put(memo, mask, found)}
    end
  end

  defp try_partners(0, _v, _mask, _adj, memo), do: {false, memo}

  defp try_partners(partners, v, mask, adj, memo) do
    u = lowest_bit(partners)
    rest = mask &&& bnot(1 <<< v ||| 1 <<< u)

    case search(rest, adj, memo) do
      {true, memo} -> {true, memo}
      {false, memo} -> try_partners(partners &&& bnot(1 <<< u), v, mask, adj, memo)
    end
  end

  # ---------------------------------------------------------------------
  # Fast paths over a whole round's adjacency (2026-09-16)
  #
  # `feasible?/2` above takes an adjacency built for the one subproblem it is
  # asked about, and building it - every pair of teams, a list-membership
  # test each - was most of what a large round cost. The functions below take
  # a TUPLE of bitmasks built once, indexed by a fixed numbering, and a mask
  # of the teams in question. They answer the same yes/no question, so a
  # caller can use them in place of `feasible?/2` without any pairing
  # changing: a matching either exists or it does not.
  # ---------------------------------------------------------------------

  @doc """
  Greedy witness search over a precomputed adjacency: repeatedly pairs the
  lowest team in `mask` with its lowest allowed partner in `mask`.

  `true` is a proof (the pairs found are a perfect matching); `false` proves
  nothing, and the caller must fall back to an exact answer.
  """
  def greedy_cover?(0, _allowed), do: true

  def greedy_cover?(mask, allowed) do
    v = lowest_index(mask)
    partners = elem(allowed, v) &&& mask

    if partners == 0 do
      false
    else
      u = lowest_index(partners)
      greedy_cover?(bxor(mask, 1 <<< v ||| 1 <<< u), allowed)
    end
  end

  @doc """
  Whether every index in `tops` can be given a distinct partner from
  `bottoms_mask`, the allowed partners of top `t` being
  `elem(allowed, t)`. Bipartite perfect matching, exact: a greedy pass, then
  Kuhn's augmenting paths for the tops it left over.

  The question `Ainalrami.TeamPairing.Bracket` asks at every prefix of the
  3.6 walk. `tops` and the bottoms must be the same size.
  """
  def bipartite_perfect?(tops, bottoms_mask, allowed) do
    {left, _free, match} =
      Enum.reduce(tops, {[], bottoms_mask, %{}}, fn t, {left, free, match} ->
        cands = elem(allowed, t) &&& free

        if cands == 0 do
          {[t | left], free, match}
        else
          b = lowest_index(cands)
          {left, bxor(free, 1 <<< b), Map.put(match, b, t)}
        end
      end)

    # Kuhn: a top with no augmenting path now will have none later either,
    # so the first failure is final.
    left
    |> Enum.reverse()
    |> Enum.reduce_while(match, fn t, match ->
      case augment(t, 0, match, bottoms_mask, allowed) do
        {:ok, _visited, match} -> {:cont, match}
        {:fail, _visited, _match} -> {:halt, :fail}
      end
    end)
    |> Kernel.!=(:fail)
  end

  defp augment(t, visited, match, bottoms_mask, allowed) do
    cands = elem(allowed, t) &&& bottoms_mask
    try_bottoms(bxor(cands, cands &&& visited), t, visited, match, bottoms_mask, allowed)
  end

  defp try_bottoms(0, _t, visited, match, _bm, _allowed), do: {:fail, visited, match}

  defp try_bottoms(cands, t, visited, match, bottoms_mask, allowed) do
    b = lowest_index(cands)
    bit = 1 <<< b
    visited = visited ||| bit

    case match do
      %{^b => holder} ->
        case augment(holder, visited, match, bottoms_mask, allowed) do
          {:ok, visited, match} ->
            {:ok, visited, Map.put(match, b, t)}

          {:fail, visited, match} ->
            try_bottoms(bxor(cands, bit), t, visited, match, bottoms_mask, allowed)
        end

      _ ->
        {:ok, visited, Map.put(match, b, t)}
    end
  end

  @doc """
  Index of the lowest set bit, in time proportional to the integer's size
  in bytes rather than to the index. The mask must be positive.
  """
  def lowest_index(mask) when mask > 0 do
    low = mask &&& -mask

    if low < 256 do
      byte_log2(low)
    else
      <<top, _::binary>> = bin = :binary.encode_unsigned(low)
      (byte_size(bin) - 1) * 8 + byte_log2(top)
    end
  end

  defp byte_log2(1), do: 0
  defp byte_log2(2), do: 1
  defp byte_log2(4), do: 2
  defp byte_log2(8), do: 3
  defp byte_log2(16), do: 4
  defp byte_log2(32), do: 5
  defp byte_log2(64), do: 6
  defp byte_log2(128), do: 7

  @doc "Number of set bits."
  def popcount(0), do: 0
  def popcount(n), do: rem(n, 2) + popcount(div(n, 2))

  @doc "Index of the lowest set bit. The mask must be non-zero."
  def lowest_bit(mask) when mask > 0, do: count_trailing(mask, 0)

  defp count_trailing(mask, n) when (mask &&& 1) == 1, do: n
  defp count_trailing(mask, n), do: count_trailing(mask >>> 1, n + 1)
end
