defmodule OpenPair.Matching do
  @moduledoc """
  Maximum-weight matching over a bracket, allowing some players to go
  unmatched (floaters) — via memoized bitmask dynamic programming over
  the *whole* bracket, not restricted to any bipartite split.

  An earlier version restricted pairing to a strict "better half (S1) vs
  worse half (S2)" bipartite split, on the theory that this is the real
  FIDE/JaVaFo/bbpPairings structure (it's what round 1 empirically does).
  A real `javafo.jar` round-2 comparison run at scale (2000 random
  histories) proved that wrong: only 10.7% matched, including a
  regression on a case that matched exactly before the bipartite
  restriction was introduced. Re-reading bbpPairings' own source
  (`swisssystems/dutch.cpp`'s `computeEdgeWeight`) confirms why — it
  computes a weight for ANY two compatible players, using bracket
  membership as a WEIGHTED BONUS in that computation, not as a hard
  exclusion of cross-bracket or non-S1/S2 pairs. The genuinely correct
  shape is general (non-bipartite) matching with a strong preference for
  the natural structure, not a hard restriction to it.

  General maximum-weight matching (Edmonds' Blossom algorithm) is the
  textbook polynomial-time answer; this project uses a memoized subset-DP
  instead, for the same implementation-correctness-confidence reason the
  bipartite version was chosen over Blossom originally: O(2^n) states
  where n is the WHOLE bracket size (not half, unlike the bipartite
  version) is worse in the worst case, but real tournament brackets after
  round 1 split into multiple score groups (not one giant tied bracket),
  keeping n small in practice — see `max_weight_matching/3`'s doc for the
  actual complexity trade-off and where this could still be too slow.
  """

  import Bitwise

  @doc """
  `players` is the bracket (a list, any order). `pair_weight_fun.(a, b)`
  returns an integer weight for pairing `a` with `b`, or `nil` if they can
  never be paired (an absolute-criterion violation, e.g. a rematch).
  `float_weight_fun.(player)` returns the (typically deeply negative)
  weight of leaving `player` unmatched instead — see
  `OpenPair.Pairing.pair_bracket/1` for how the caller makes floating
  always cost less than any legal pairing, with a same-sized bracket's
  worse-ranked players floating first as a tie-break.

  Returns `{pairs, floaters}` for the maximum-total-weight matching:
  `pairs` is `[{a, b}, ...]`, `floaters` is the unmatched players.

  O(2^n * n) time/space, n = bracket size — exponential in the WHOLE
  bracket (unlike a bipartite formulation's O(k * 2^k) in half of it),
  because pairing is no longer restricted to a bipartite split at all.
  Fine for realistic tournament brackets (a score group rarely exceeds a
  few dozen players even in a large field, since round 1 already spread
  the roster across multiple scores); a bracket approaching the whole
  field (everyone still tied) would be genuinely slow — not yet capped or
  guarded against here.
  """
  def max_weight_matching(players, pair_weight_fun, float_weight_fun) do
    {_count, {_weight, pairs, floaters}} =
      players
      |> max_weight_matchings(pair_weight_fun, float_weight_fun)
      |> Enum.max_by(fn {_count, {weight, _pairs, _floaters}} -> weight end)

    {pairs, floaters}
  end

  @doc """
  The best matching for EACH possible number of floaters, as
  `%{float_count => {weight, pairs, floaters}}`.

  Maximising a single bracket in isolation is not the same as maximising
  the round. A bracket that pairs as many of its own players as possible
  can strand a later one — two players left holding nothing but a rematch
  with each other — and the cascade then has no way to produce a legal
  round at all. Traced on a real 10-player case (seed 14, round 5): this
  engine emitted TWO pairing-allocated byes in an even field, which is not
  a legal pairing under any reading, while javafo floated an extra pair of
  players down so the last bracket could complete.

  Recovering from that needs alternatives, not just the optimum, so the
  caller can trade a worse bracket for a round that finishes. Same
  memoised subset DP as before, keeping the best weight per floater count
  instead of the single best overall.
  """
  def max_weight_matchings(players, pair_weight_fun, float_weight_fun) do
    n = length(players)
    arr = List.to_tuple(players)
    full_mask = (1 <<< n) - 1
    memo_key = make_ref()
    Process.put(memo_key, %{})

    try do
      solve(full_mask, arr, n, pair_weight_fun, float_weight_fun, memo_key)
    after
      Process.delete(memo_key)
    end
  end

  defp solve(0, _arr, _n, _pair_weight_fun, _float_weight_fun, _memo_key), do: %{0 => {0, [], []}}

  defp solve(mask, arr, n, pair_weight_fun, float_weight_fun, memo_key) do
    cache = Process.get(memo_key)

    case Map.fetch(cache, mask) do
      {:ok, result} ->
        result

      :error ->
        result = compute_solve(mask, arr, n, pair_weight_fun, float_weight_fun, memo_key)
        Process.put(memo_key, Map.put(Process.get(memo_key), mask, result))
        result
    end
  end

  defp compute_solve(mask, arr, n, pair_weight_fun, float_weight_fun, memo_key) do
    i = lowest_set_bit_index(mask, 0)
    p = elem(arr, i)
    rest_mask = mask &&& bnot(1 <<< i)

    float_options =
      rest_mask
      |> solve(arr, n, pair_weight_fun, float_weight_fun, memo_key)
      |> Enum.reduce(%{}, fn {count, {weight, pairs, floaters}}, acc ->
        put_best(acc, count + 1, {weight + float_weight_fun.(p), pairs, [p | floaters]})
      end)

    Enum.reduce(0..(n - 1), float_options, fn j, acc ->
      if bit_set?(rest_mask, j) do
        q = elem(arr, j)

        case pair_weight_fun.(p, q) do
          nil ->
            acc

          weight ->
            rest_mask
            |> bandnot(j)
            |> solve(arr, n, pair_weight_fun, float_weight_fun, memo_key)
            |> Enum.reduce(acc, fn {count, {rest_weight, pairs, floaters}}, inner ->
              put_best(inner, count, {weight + rest_weight, [{p, q} | pairs], floaters})
            end)
        end
      else
        acc
      end
    end)
  end

  defp bandnot(mask, j), do: mask &&& bnot(1 <<< j)

  defp put_best(acc, count, {weight, _pairs, _floaters} = candidate) do
    case acc do
      %{^count => {existing, _, _}} when existing >= weight -> acc
      _ -> Map.put(acc, count, candidate)
    end
  end

  defp lowest_set_bit_index(mask, i) do
    if bit_set?(mask, i), do: i, else: lowest_set_bit_index(mask, i + 1)
  end

  defp bit_set?(mask, i), do: (mask >>> i &&& 1) == 1
end
