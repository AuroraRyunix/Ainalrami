defmodule OpenPair.Matching do
  @moduledoc """
  Maximum-weight perfect bipartite matching via bitmask dynamic programming
  (Held-Karp style) — O(k * 2^k) time and space, where k is the size of
  each side. Chosen over the classical O(k^3) Hungarian algorithm
  (potentials + augmenting paths) for implementation-correctness
  confidence: this is a much smaller, easier-to-verify algorithm, and k
  here is HALF of one score bracket (not the whole tournament field), so
  it stays well under a size where the exponential factor matters for any
  realistic tournament.

  Replaced an exhaustive recursive backtracking search
  (`OpenPair.Pairing`'s previous `match_bracket/1`) that had no such
  bound: confirmed empirically to take 194ms at just 12 players and to not
  finish within 60 seconds at 16, since it explored the same subsets
  repeatedly with no memoization and its complexity is close to double
  factorial in the bracket size, not the half-bracket size.
  """

  import Bitwise

  @doc """
  `left` and `right` must be the same length k. `weight_fun.(l, r)`
  returns an integer weight, or `nil` if the pair is infeasible (can never
  be part of the matching). Returns `{:ok, pairs, total_weight}` for the
  maximum-total-weight perfect matching (`pairs` is `[{l, r}, ...]`, one
  entry per `left` element), or `:infeasible` if no perfect matching
  avoiding every `nil` pair exists.
  """
  def max_weight_perfect_matching([], [], _weight_fun), do: {:ok, [], 0}

  def max_weight_perfect_matching(left, right, weight_fun)
      when length(left) == length(right) do
    k = length(left)
    left_arr = List.to_tuple(left)
    right_arr = List.to_tuple(right)

    weight = fn i, j -> weight_fun.(elem(left_arr, i), elem(right_arr, j)) end

    full_mask = (1 <<< k) - 1
    dp = %{0 => {0, []}}

    dp =
      Enum.reduce(0..(k - 1), dp, fn i, dp ->
        dp
        |> Enum.filter(fn {mask, _} -> popcount(mask) == i end)
        |> Enum.reduce(dp, fn {mask, {w, assignment}}, acc ->
          extend_with_next_left_item(acc, mask, w, assignment, i, k, weight)
        end)
      end)

    case Map.get(dp, full_mask) do
      nil ->
        :infeasible

      {total_weight, assignment} ->
        pairs = Enum.map(assignment, fn {i, j} -> {elem(left_arr, i), elem(right_arr, j)} end)
        {:ok, pairs, total_weight}
    end
  end

  defp extend_with_next_left_item(acc, mask, w, assignment, i, k, weight) do
    Enum.reduce(0..(k - 1), acc, fn j, acc ->
      if bit_set?(mask, j) do
        acc
      else
        case weight.(i, j) do
          nil ->
            acc

          pair_weight ->
            new_mask = mask ||| 1 <<< j
            new_weight = w + pair_weight
            new_assignment = [{i, j} | assignment]
            put_if_better(acc, new_mask, new_weight, new_assignment)
        end
      end
    end)
  end

  defp put_if_better(acc, mask, weight, assignment) do
    case Map.get(acc, mask) do
      nil ->
        Map.put(acc, mask, {weight, assignment})

      {existing_weight, _} when weight > existing_weight ->
        Map.put(acc, mask, {weight, assignment})

      _ ->
        acc
    end
  end

  defp popcount(mask), do: popcount(mask, 0)
  defp popcount(0, acc), do: acc
  defp popcount(mask, acc), do: popcount(mask >>> 1, acc + (mask &&& 1))

  defp bit_set?(mask, j), do: (mask >>> j &&& 1) == 1
end
