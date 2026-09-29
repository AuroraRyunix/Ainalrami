defmodule Ainalrami.CardinalityMatching do
  @moduledoc """
  Maximum-cardinality matching in a general graph, and the vertices some
  maximum matching leaves exposed.

  `Ainalrami.Pairing` asks one question of a score group that this answers
  exactly: which players of the group can be the one left over by a
  largest matching of it (with a stand-in vertex added for "the bye", see
  `Pairing`'s odd bracket over the bye group). That set is the `D` of the
  Gallai-Edmonds decomposition: with `M` a maximum matching and `u` a
  vertex it leaves exposed, `D` is the set of vertices reachable from `u`
  by an alternating path of even length - flipping the path exposes its
  far end instead, and conversely every maximum matching that exposes `v`
  differs from `M` by such a path. Edmonds' search from `u`, which finds no
  augmenting path because `M` is maximum, labels exactly those vertices
  OUTER (blossoms contracted: every vertex of a blossom is outer).

  The search is the textbook one (Edmonds 1965, in the array form of the
  common O(n^3) implementation: `base`, parent links `p`, blossom marking
  through the least common ancestor). Only the single-exposed-vertex case
  is answered, which is the one `Pairing` needs (a graph of odd order with
  a near-perfect matching); anything else is `:no`.

  Checked against brute force (every vertex removed in turn, the maximum
  matching recomputed by exhaustive search) in
  `test/ainalrami/cardinality_matching_test.exs`.
  """

  @doc """
  A maximum matching of the graph on vertices `0..n-1`, `adj` a tuple of
  neighbour lists (symmetric). Returns a map `v => mate` holding both ends
  of every pair.
  """
  def maximum(adj) do
    n = tuple_size(adj)
    match = greedy(adj, n)

    Enum.reduce(0..(n - 1)//1, match, fn v, match ->
      if is_map_key(match, v) do
        match
      else
        case search(adj, n, match, v) do
          {:path, to, p} -> augment(to, p, match)
          {:none, _outer} -> match
        end
      end
    end)
  end

  @doc """
  `{:ok, set}`: the vertices some maximum matching leaves exposed, when a
  maximum matching leaves exactly one vertex exposed; `:no` otherwise.
  """
  def exposable(adj) do
    n = tuple_size(adj)
    match = maximum(adj)

    case Enum.reject(0..(n - 1)//1, &is_map_key(match, &1)) do
      [u] ->
        {:none, outer} = search(adj, n, match, u)
        {:ok, outer}

      _ ->
        :no
    end
  end

  defp greedy(adj, n) do
    Enum.reduce(0..(n - 1)//1, %{}, fn v, match ->
      if is_map_key(match, v) do
        match
      else
        case Enum.find(elem(adj, v), &(not is_map_key(match, &1))) do
          nil -> match
          u -> match |> Map.put(v, u) |> Map.put(u, v)
        end
      end
    end)
  end

  # Edmonds' search from `root`: `{:path, exposed vertex, parents}` when an
  # augmenting path exists, else `{:none, outer vertices}`.
  defp search(adj, n, match, root) do
    st = %{
      base: Map.new(0..(n - 1)//1, &{&1, &1}),
      p: %{},
      used: MapSet.new([root]),
      match: match,
      root: root,
      n: n
    }

    bfs(:queue.from_list([root]), adj, st)
  end

  defp bfs(queue, adj, st) do
    case :queue.out(queue) do
      {:empty, _} ->
        {:none, st.used}

      {{:value, v}, queue} ->
        case scan(elem(adj, v), v, queue, st) do
          {:path, _to, _p} = found -> found
          {:cont, queue, st} -> bfs(queue, adj, st)
        end
    end
  end

  defp scan([], _v, queue, st), do: {:cont, queue, st}

  defp scan([to | rest], v, queue, st) do
    cond do
      Map.fetch!(st.base, v) == Map.fetch!(st.base, to) or Map.get(st.match, v) == to ->
        scan(rest, v, queue, st)

      to == st.root or
          (is_map_key(st.match, to) and is_map_key(st.p, Map.fetch!(st.match, to))) ->
        {queue, st} = contract(v, to, queue, st)
        scan(rest, v, queue, st)

      not is_map_key(st.p, to) ->
        p = Map.put(st.p, to, v)

        case Map.get(st.match, to) do
          nil ->
            {:path, to, p}

          mt ->
            st = %{st | p: p, used: MapSet.put(st.used, mt)}
            scan(rest, v, :queue.in(mt, queue), st)
        end

      true ->
        scan(rest, v, queue, st)
    end
  end

  # An edge between two outer vertices of the tree closes an odd cycle:
  # every vertex whose base lies on it takes the cycle's base, and becomes
  # outer.
  defp contract(v, to, queue, st) do
    cur = lca(v, to, st)
    {p, blossom} = mark_path(v, cur, to, st.p, MapSet.new(), st)
    {p, blossom} = mark_path(to, cur, v, p, blossom, st)

    {base, used, queue} =
      Enum.reduce(0..(st.n - 1)//1, {st.base, st.used, queue}, fn i, {base, used, queue} ->
        if MapSet.member?(blossom, Map.fetch!(st.base, i)) do
          base = Map.put(base, i, cur)

          if MapSet.member?(used, i),
            do: {base, used, queue},
            else: {base, MapSet.put(used, i), :queue.in(i, queue)}
        else
          {base, used, queue}
        end
      end)

    {queue, %{st | p: p, base: base, used: used}}
  end

  defp lca(a, b, st), do: rise_b(b, rise_a(a, MapSet.new(), st), st)

  defp rise_a(a, seen, st) do
    a = Map.fetch!(st.base, a)
    seen = MapSet.put(seen, a)

    case Map.get(st.match, a) do
      nil -> seen
      ma -> rise_a(Map.fetch!(st.p, ma), seen, st)
    end
  end

  defp rise_b(b, seen, st) do
    b = Map.fetch!(st.base, b)

    if MapSet.member?(seen, b),
      do: b,
      else: rise_b(Map.fetch!(st.p, Map.fetch!(st.match, b)), seen, st)
  end

  defp mark_path(v, b, children, p, blossom, st) do
    if Map.fetch!(st.base, v) == b do
      {p, blossom}
    else
      mv = Map.fetch!(st.match, v)

      blossom =
        blossom |> MapSet.put(Map.fetch!(st.base, v)) |> MapSet.put(Map.fetch!(st.base, mv))

      p = Map.put(p, v, children)
      mark_path(Map.fetch!(p, mv), b, mv, p, blossom, st)
    end
  end

  defp augment(nil, _p, match), do: match

  defp augment(v, p, match) do
    pv = Map.fetch!(p, v)
    ppv = Map.get(match, pv)
    augment(ppv, p, match |> Map.put(v, pv) |> Map.put(pv, v))
  end
end
