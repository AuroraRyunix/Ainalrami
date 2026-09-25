defmodule Ainalrami.TeamProof.BlossomTest do
  @moduledoc """
  The exact reference's matcher against an exhaustive answer.

  `Ainalrami.TeamProof.Blossom` is only as good as this comparison: a
  minimum-cost perfect matching is checked against a bitmask dynamic
  programme (pair the lowest unpaired vertex with every possible partner,
  memoised on the set left) on random graphs of every density, with costs
  from {0, 1} (most ties - the hard case for a primal-dual algorithm) up to
  300-bit integers (what the reference's lexicographic digit packing
  produces).
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias Ainalrami.TeamProof.Blossom

  test "minimum cost and existence agree with exhaustive search" do
    :rand.seed(:exsss, {11, 22, 33})

    for trial <- 1..3000 do
      n = Enum.random([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 16])
      density = Enum.random([0.15, 0.3, 0.5, 0.7, 0.9, 1.0])

      cost =
        case rem(trial, 4) do
          0 -> fn -> Enum.random(0..1) end
          1 -> fn -> Enum.random(0..3) end
          2 -> fn -> Enum.random(0..1000) end
          3 -> fn -> Enum.random(0..(1 <<< 300)) end
        end

      edges =
        for i <- 0..(n - 1)//1, j <- (i + 1)..(n - 1)//1, :rand.uniform() < density do
          {i, j, cost.()}
        end

      expected = dp(n, edges)

      case Blossom.min_cost_perfect(n, edges) do
        :none ->
          assert expected == :none, "trial #{trial}: blossom found none, DP #{inspect(expected)}"

        {:ok, c, _mate} ->
          assert expected == c, "trial #{trial}: blossom #{c}, DP #{inspect(expected)}"
      end
    end
  end

  test "near-complete graphs of 80 vertices: a perfect matching, and cost 0 when one is free" do
    :rand.seed(:exsss, {5, 6, 7})

    for _ <- 1..5 do
      n = 80

      free =
        Enum.shuffle(0..(n - 1))
        |> Enum.chunk_every(2)
        |> MapSet.new(&List.to_tuple(Enum.sort(&1)))

      edges =
        for i <- 0..(n - 1),
            j <- (i + 1)..(n - 1)//1,
            MapSet.member?(free, {i, j}) or :rand.uniform() < 0.9 do
          {i, j, if(MapSet.member?(free, {i, j}), do: 0, else: 1 + :rand.uniform(5))}
        end

      assert {:ok, 0, _} = Blossom.min_cost_perfect(n, edges)
    end
  end

  defp dp(n, edges) do
    cost = Map.new(edges, fn {i, j, c} -> {{i, j}, c} end)
    full = (1 <<< n) - 1
    {v, _} = go(full, n, cost, %{})
    if v == :inf, do: :none, else: v
  end

  defp go(0, _n, _cost, memo), do: {0, memo}

  defp go(mask, n, cost, memo) do
    case memo do
      %{^mask => v} ->
        {v, memo}

      _ ->
        i = Enum.find(0..(n - 1), &((mask >>> &1 &&& 1) == 1))

        {best, memo} =
          for j <- (i + 1)..(n - 1)//1,
              (mask >>> j &&& 1) == 1,
              Map.has_key?(cost, {i, j}),
              reduce: {:inf, memo} do
            {best, memo} ->
              {sub, memo} = go(mask &&& bnot(1 <<< i) &&& bnot(1 <<< j), n, cost, memo)

              cand = if sub == :inf, do: :inf, else: sub + cost[{i, j}]
              {if(cand != :inf and (best == :inf or cand < best), do: cand, else: best), memo}
          end

        {best, Map.put(memo, mask, best)}
    end
  end
end
