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
    n = length(players)
    arr = List.to_tuple(players)
    full_mask = (1 <<< n) - 1
    memo_key = make_ref()
    Process.put(memo_key, %{})

    try do
      {_weight, pairs, floaters} =
        solve(full_mask, arr, n, pair_weight_fun, float_weight_fun, memo_key)

      {pairs, floaters}
    after
      Process.delete(memo_key)
    end
  end

  defp solve(0, _arr, _n, _pair_weight_fun, _float_weight_fun, _memo_key), do: {0, [], []}

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

    {w_without, pairs_without, floaters_without} =
      solve(rest_mask, arr, n, pair_weight_fun, float_weight_fun, memo_key)

    float_option = {w_without + float_weight_fun.(p), pairs_without, [p | floaters_without]}

    pair_options =
      for j <- 0..(n - 1), bit_set?(rest_mask, j) do
        q = elem(arr, j)

        case pair_weight_fun.(p, q) do
          nil ->
            nil

          w ->
            new_mask = rest_mask &&& bnot(1 <<< j)

            {w_rest, pairs_rest, floaters_rest} =
              solve(new_mask, arr, n, pair_weight_fun, float_weight_fun, memo_key)

            {w + w_rest, [{p, q} | pairs_rest], floaters_rest}
        end
      end
      |> Enum.reject(&is_nil/1)

    Enum.max_by([float_option | pair_options], fn {w, _pairs, _floaters} -> w end)
  end

  defp lowest_set_bit_index(mask, i) do
    if bit_set?(mask, i), do: i, else: lowest_set_bit_index(mask, i + 1)
  end

  defp bit_set?(mask, i), do: (mask >>> i &&& 1) == 1
end
