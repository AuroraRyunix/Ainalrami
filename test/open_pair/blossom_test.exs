defmodule OpenPair.BlossomTest do
  use ExUnit.Case

  alias OpenPair.Blossom

  describe "augment/3" do
    test "finds a perfect matching on a simple path" do
      neighbours = %{1 => [2], 2 => [1, 3], 3 => [2, 4], 4 => [3]}
      result = Blossom.augment([1, 2, 3, 4], %{}, &Map.fetch!(neighbours, &1))

      assert matching_size(result) == 2
      assert valid_matching?(result, neighbours)
    end

    test "reaches vertices that only become discoverable after a blossom contraction" do
      # The textbook case. An odd (5-vertex) cycle 1-2-3-4-5-1, pre-matched
      # 1-2 and 3-4 (5 is the cycle's own leftover), with two more free
      # vertices 6 and 7 pendant off vertices 2 and 4 — both already
      # matched INSIDE the cycle.
      #
      # Neither 6 nor 7 is reachable by a plain (non-blossom) alternating
      # search from root 5: a plain search only ever pushes a newly-found
      # vertex's MATCH PARTNER onto the queue, never the vertex itself, so
      # from root 5 only vertices 4 and 1 (5's own neighbours) and then 3
      # and 2 (their match partners) ever get explored — vertex 4 itself
      # is never dequeued to have ITS edge to 7 explored, and vertex 2 is
      # never dequeued to have its edge to 6 explored. Only blossom
      # contraction (recognising 1-2-3-4-5 as one cycle once the search
      # reaches 2 via a second, non-matching route through 3) pushes 1 and
      # 4 onto the queue themselves, which is what makes 6 and 7 reachable
      # at all. Confirmed by hand-tracing the search before writing this.
      edges = [{1, 2}, {2, 3}, {3, 4}, {4, 5}, {5, 1}, {2, 6}, {4, 7}]
      neighbours = adjacency(edges)
      initial = bidirectional(%{1 => 2, 3 => 4})

      result = Blossom.augment([1, 2, 3, 4, 5, 6, 7], initial, &Map.get(neighbours, &1, []))

      assert valid_matching?(result, neighbours)
      # 7 vertices, so 3 pairs is the best any matching can do.
      assert matching_size(result) == 3
      assert matching_size(result) == max_matching_size([1, 2, 3, 4, 5, 6, 7], neighbours)
    end

    test "reaches the brute-force maximum on random small graphs, some containing odd cycles" do
      for seed <- 1..25 do
        :rand.seed(:exsss, {seed, seed * 3, seed * 7})
        n = Enum.random(4..6)
        vertices = Enum.to_list(1..n)
        edges = for a <- vertices, b <- vertices, a < b, :rand.uniform() < 0.35, do: {a, b}
        neighbours = adjacency(edges)

        result = Blossom.augment(vertices, %{}, &Map.get(neighbours, &1, []))

        assert valid_matching?(result, neighbours),
               "seed #{seed}: invalid matching #{inspect(result)} for edges #{inspect(edges)}"

        expected = max_matching_size(vertices, neighbours)

        assert matching_size(result) == expected,
               "seed #{seed}: got #{matching_size(result)}, brute force says #{expected} " <>
                 "is possible, edges: #{inspect(edges)}"
      end
    end

    test "augmenting an already-maximum matching changes nothing" do
      neighbours = %{1 => [2], 2 => [1, 3], 3 => [2]}
      already_maximum = bidirectional(%{1 => 2})

      assert Blossom.augment([1, 2, 3], already_maximum, &Map.fetch!(neighbours, &1)) ==
               already_maximum
    end

    test "a vertex with no legal neighbours is simply left unmatched" do
      neighbours = %{1 => [2], 2 => [1], 3 => []}

      result = Blossom.augment([1, 2, 3], %{}, &Map.get(neighbours, &1, []))

      refute Map.has_key?(result, 3)
      assert matching_size(result) == 1
    end
  end

  defp adjacency(edges) do
    Enum.reduce(edges, %{}, fn {a, b}, acc ->
      acc |> Map.update(a, [b], &[b | &1]) |> Map.update(b, [a], &[a | &1])
    end)
  end

  defp bidirectional(pairs) do
    Enum.reduce(pairs, %{}, fn {a, b}, acc -> acc |> Map.put(a, b) |> Map.put(b, a) end)
  end

  defp matching_size(matching) do
    matching |> Map.to_list() |> Enum.uniq_by(fn {a, b} -> Enum.sort([a, b]) end) |> length()
  end

  defp valid_matching?(matching, neighbours) do
    Enum.all?(matching, fn {a, b} ->
      Map.get(matching, b) == a and b in Map.get(neighbours, a, [])
    end)
  end

  # Exhaustive search over which edges to include as a matching — the
  # independent oracle the blossom implementation is checked against.
  # Fine for the small (<=6 vertex) graphs these tests use; not meant to
  # scale.
  defp max_matching_size(vertices, neighbours) do
    edges = for a <- vertices, b <- Map.get(neighbours, a, []), a < b, do: {a, b}
    best_matching(edges, MapSet.new())
  end

  defp best_matching([], _used), do: 0

  defp best_matching([{a, b} | rest], used) do
    skip = best_matching(rest, used)

    if MapSet.member?(used, a) or MapSet.member?(used, b) do
      skip
    else
      take = 1 + best_matching(rest, used |> MapSet.put(a) |> MapSet.put(b))
      max(skip, take)
    end
  end
end
