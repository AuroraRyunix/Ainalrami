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
      rem(popcount(mask), 2) == 1 -> false
      greedy?(mask, adj) -> true
      true -> {result, _memo} = search(mask, adj, %{})
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
      greedy?(mask &&& bnot((1 <<< v) ||| (1 <<< u)), adj)
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
    rest = mask &&& bnot((1 <<< v) ||| (1 <<< u))

    case search(rest, adj, memo) do
      {true, memo} -> {true, memo}
      {false, memo} -> try_partners(partners &&& bnot(1 <<< u), v, mask, adj, memo)
    end
  end

  @doc "Number of set bits."
  def popcount(0), do: 0
  def popcount(n), do: rem(n, 2) + popcount(div(n, 2))

  @doc "Index of the lowest set bit. The mask must be non-zero."
  def lowest_bit(mask) when mask > 0, do: count_trailing(mask, 0)

  defp count_trailing(mask, n) when (mask &&& 1) == 1, do: n
  defp count_trailing(mask, n), do: count_trailing(mask >>> 1, n + 1)
end
