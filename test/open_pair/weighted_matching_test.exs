defmodule OpenPair.WeightedMatchingTest do
  use ExUnit.Case

  alias OpenPair.WeightedMatching

  describe "solve/2" do
    test "n <= 1 has no matching to make" do
      assert WeightedMatching.solve(0, []) == %{}
      assert WeightedMatching.solve(1, []) == %{}
    end

    test "no edges means nothing gets matched" do
      assert WeightedMatching.solve(4, []) == %{}
    end

    test "a single edge is matched, both directions" do
      assert WeightedMatching.solve(2, [{0, 1, 7}]) == %{0 => 1, 1 => 0}
    end

    test "zero and negative weights are treated as no edge" do
      assert WeightedMatching.solve(2, [{0, 1, 0}]) == %{}
      assert WeightedMatching.solve(2, [{0, 1, -3}]) == %{}
    end

    test "disjoint edges are all taken" do
      result = WeightedMatching.solve(4, [{0, 1, 3}, {2, 3, 5}])

      assert result == %{0 => 1, 1 => 0, 2 => 3, 3 => 2}
    end

    test "picks the heavier of two edges sharing a vertex over both" do
      result = WeightedMatching.solve(3, [{0, 1, 3}, {1, 2, 9}])

      assert result == %{1 => 2, 2 => 1}
    end

    test "a triangle (odd cycle) forces a blossom: only one edge can ever be used" do
      # The textbook minimal case for blossom contraction in a WEIGHTED
      # graph: with all three edges present, no matching can use more than
      # one of them (any two share a vertex), so the maximum-weight
      # matching is simply the single heaviest edge, leaving the third
      # vertex unmatched. Confirmed by hand-tracing this exact case while
      # developing WeightedMatching, back when it was the first graph that
      # made the algorithm form a blossom at all.
      edges = [{0, 1, 5}, {1, 2, 9}, {0, 2, 5}]

      assert WeightedMatching.solve(3, edges) == %{1 => 2, 2 => 1}
    end

    test "reaches the DP-oracle maximum on random small graphs, some requiring blossom formation" do
      for seed <- 1..80 do
        :rand.seed(:exsss, {seed, seed * 3, seed * 7})
        n = Enum.random(3..7)

        edges =
          for a <- 0..(n - 1), b <- 0..(n - 1), a < b, :rand.uniform() < 0.5 do
            {a, b, Enum.random(1..9)}
          end

        result = WeightedMatching.solve(n, edges)

        assert valid_matching?(result, edges),
               "seed #{seed}: invalid matching #{inspect(result)} for edges #{inspect(edges)}"

        expected = oracle_max_weight(n, edges)
        got = total_weight(result, edges)

        assert got == expected,
               "seed #{seed}: got #{got}, oracle says #{expected} is possible, " <>
                 "edges: #{inspect(edges)}, matching: #{inspect(result)}"
      end
    end

    test "reaches the DP-oracle maximum on denser random graphs, exercising blossom expansion" do
      # Wider (n up to 10) and denser (edge probability 0.45) than the test
      # above specifically to reach blossom EXPANSION, not just formation
      # — a blossom's own dual variable hitting zero mid-search only
      # happens when a graph is dense/large enough that a blossom forms
      # and then needs to be dissolved again before the stage finishes.
      # `n` and the edge probability here were picked empirically (during
      # development) to reliably exercise that path.
      for seed <- 101..180 do
        :rand.seed(:exsss, {seed, seed * 3, seed * 7})
        n = Enum.random(4..10)

        edges =
          for a <- 0..(n - 1), b <- 0..(n - 1), a < b, :rand.uniform() < 0.45 do
            {a, b, Enum.random(1..15)}
          end

        result = WeightedMatching.solve(n, edges)

        assert valid_matching?(result, edges),
               "seed #{seed}: invalid matching #{inspect(result)} for edges #{inspect(edges)}"

        expected = oracle_max_weight(n, edges)
        got = total_weight(result, edges)

        assert got == expected,
               "seed #{seed}: got #{got}, oracle says #{expected} is possible, " <>
                 "edges: #{inspect(edges)}, matching: #{inspect(result)}"
      end
    end
  end

  # `OpenPair.Matching`'s bracket DP is a genuinely INDEPENDENT
  # implementation (different algorithm, memoized subset DP over ANY
  # subset rather than a primal-dual blossom search) already relied on
  # elsewhere in this codebase — exactly the oracle `WeightedMatching`'s
  # own moduledoc says it was checked against. `float_weight_fun` returns
  # 0 so leaving a vertex unmatched is free, matching `solve/2`'s own
  # semantics of simply omitting unmatched vertices at no cost.
  defp oracle_max_weight(n, edges) do
    lookup = Map.new(edges, fn {a, b, w} -> {Enum.sort([a, b]), w} end)

    pair_weight_fun = fn a, b ->
      case Map.get(lookup, Enum.sort([a, b])) do
        w when is_integer(w) and w > 0 -> w
        _ -> nil
      end
    end

    {pairs, _floaters} =
      OpenPair.Matching.max_weight_matching(Enum.to_list(0..(n - 1)), pair_weight_fun, fn _ ->
        0
      end)

    Enum.reduce(pairs, 0, fn {a, b}, acc -> acc + pair_weight_fun.(a, b) end)
  end

  defp total_weight(matching, edges) do
    lookup = Map.new(edges, fn {a, b, w} -> {{a, b}, w} end)

    matching
    |> Map.to_list()
    |> Enum.uniq_by(fn {a, b} -> Enum.sort([a, b]) end)
    |> Enum.reduce(0, fn {a, b}, acc ->
      w = Map.get(lookup, {a, b}) || Map.fetch!(lookup, {b, a})
      acc + w
    end)
  end

  defp valid_matching?(matching, edges) do
    edge_set = MapSet.new(edges, fn {a, b, _w} -> Enum.sort([a, b]) end)

    Enum.all?(matching, fn {a, b} ->
      Map.get(matching, b) == a and MapSet.member?(edge_set, Enum.sort([a, b]))
    end)
  end
end
