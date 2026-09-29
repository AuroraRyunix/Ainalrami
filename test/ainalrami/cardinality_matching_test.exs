defmodule Ainalrami.CardinalityMatchingTest do
  @moduledoc """
  `Ainalrami.CardinalityMatching` against exhaustive search on random
  graphs: the matching's size, and the exposable set as "the vertices whose
  removal leaves the maximum matching's size unchanged".
  """

  use ExUnit.Case, async: true

  alias Ainalrami.CardinalityMatching

  test "maximum matchings and exposable sets agree with exhaustive search" do
    rng = :rand.seed_s(:exsss, {7, 11, 13})

    {checked, _rng} =
      Enum.reduce(1..3000, {0, rng}, fn _, {checked, rng} ->
        {n, rng} = :rand.uniform_s(11, rng)
        {density, rng} = :rand.uniform_s(9, rng)
        {edges, rng} = random_edges(n, density, rng)
        adj = adjacency(n, edges)

        match = CardinalityMatching.maximum(adj)
        nu = nu(Enum.to_list(0..(n - 1)//1), edges)

        assert map_size(match) == 2 * nu

        assert Enum.all?(match, fn {v, u} ->
                 Map.fetch!(match, u) == v and {min(u, v), max(u, v)} in edges
               end)

        case CardinalityMatching.exposable(adj) do
          {:ok, set} ->
            assert n - 2 * nu == 1

            expected =
              for v <- 0..(n - 1)//1,
                  nu(List.delete(Enum.to_list(0..(n - 1)//1), v), edges) == nu,
                  do: v

            assert Enum.sort(MapSet.to_list(set)) == expected, "n=#{n} edges=#{inspect(edges)}"
            {checked + 1, rng}

          :no ->
            assert n - 2 * nu != 1
            {checked, rng}
        end
      end)

    assert checked > 500
  end

  defp random_edges(n, density, rng) do
    pairs = for i <- 0..(n - 1)//1, j <- (i + 1)..(n - 1)//1, do: {i, j}

    Enum.reduce(pairs, {[], rng}, fn pair, {acc, rng} ->
      {roll, rng} = :rand.uniform_s(10, rng)
      {if(roll <= density, do: [pair | acc], else: acc), rng}
    end)
  end

  defp adjacency(n, edges) do
    edges
    |> Enum.reduce(Map.new(0..(n - 1)//1, &{&1, []}), fn {i, j}, acc ->
      acc |> Map.update!(i, &[j | &1]) |> Map.update!(j, &[i | &1])
    end)
    |> then(fn map ->
      List.to_tuple(for v <- 0..(n - 1)//1, do: Enum.sort(Map.fetch!(map, v)))
    end)
  end

  # Exhaustive: the first vertex is left out or paired with each neighbour.
  defp nu([], _edges), do: 0

  defp nu([v | rest], edges) do
    skip = nu(rest, edges)

    rest
    |> Enum.filter(&({min(v, &1), max(v, &1)} in edges))
    |> Enum.reduce(skip, fn u, best -> max(best, 1 + nu(List.delete(rest, u), edges)) end)
  end
end
