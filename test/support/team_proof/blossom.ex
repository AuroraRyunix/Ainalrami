defmodule Ainalrami.TeamProof.Blossom do
  @moduledoc """
  Minimum-cost PERFECT matching in a general graph, for the exact C.04.6
  reference (`Ainalrami.TeamProof.ExactReference`) and nothing else.

  ## Why a second matcher exists at all

  The exact reference must share no code with the engine - not with
  `Ainalrami.TeamPairing.*`, not with `Ainalrami.WeightedMatching` (a port of
  bbpPairings' Galil/Micali/Gabow code) and not with the engine's memoised
  feasibility search. A reference that called the engine's matcher would
  inherit exactly the bugs it is meant to catch.

  So this is an Edmonds primal-dual blossom algorithm written for this
  module, following the structure of Joris van Rantwijk's public-domain
  `mwmatching.py` (Galil 1986, "Efficient algorithms for finding maximum
  matching in graphs", O(n^3)) - a different code lineage from the engine's.
  It is used as "maximum weight among maximum-CARDINALITY matchings", with
  each edge's weight `(max cost + 1) - cost`: when a perfect matching exists
  the maximum cardinality is n/2, every perfect matching then has weight
  `n/2 * (max cost + 1) - cost`, and the heaviest is the cheapest.

  ## How it is trusted

  Not by reading. `test/ainalrami/team_proof_blossom_test.exs` compares it
  with an exhaustive bitmask dynamic programme on thousands of random graphs
  (up to 16 vertices, sparse and dense, tiny and huge costs - the reference
  uses bigint costs of a few hundred bits), and every answer here is checked
  on the way out to BE a perfect matching of the given edges with the cost
  claimed. A wrong answer can therefore only be a matching that is perfect
  and legal but not the cheapest - which is what the DP comparison is for,
  and what the whole-round agreement with the naive reference at 4-10 teams
  checks again from the other side.

  ## State

  The algorithm is naturally imperative (a dozen arrays mutated in place).
  It is ported with those arrays in the process dictionary, and every call
  runs in a short-lived process of its own so no state outlives the call or
  leaks between calls. Costs may be arbitrary non-negative integers,
  bigints included: every step is integer arithmetic (slacks between two
  S-vertices are even, as in the original).
  """

  import Bitwise

  @doc """
  `min_cost_perfect(n, edges)` with vertices `0..n-1` and `edges` a list of
  `{i, j, cost}` (i != j, each pair at most once, cost >= 0).

  Returns `{:ok, cost, mate}` - `mate` a map vertex => partner - or `:none`
  when no perfect matching exists.
  """
  def min_cost_perfect(0, _edges), do: {:ok, 0, %{}}
  def min_cost_perfect(n, _edges) when rem(n, 2) == 1, do: :none
  def min_cost_perfect(_n, []), do: :none

  def min_cost_perfect(n, edges) do
    max_cost = edges |> Enum.map(&elem(&1, 2)) |> Enum.max()
    weighted = Enum.map(edges, fn {i, j, c} -> {i, j, max_cost + 1 - c} end)

    mate = isolated(fn -> max_weight_matching(n, weighted) end)

    if Enum.all?(0..(n - 1), &(Map.fetch!(mate, &1) >= 0)) do
      costs = Map.new(edges, fn {i, j, c} -> {{min(i, j), max(i, j)}, c} end)

      cost =
        for v <- 0..(n - 1), v < mate[v], reduce: 0 do
          acc ->
            # On the way out: a perfect matching of the GIVEN edges.
            u = mate[v]
            true = mate[u] == v
            acc + Map.fetch!(costs, {v, u})
        end

      {:ok, cost, mate}
    else
      :none
    end
  end

  @doc "Whether a perfect matching exists (all costs zero)."
  def perfect?(n, edges) do
    min_cost_perfect(n, Enum.map(edges, fn {i, j} -> {i, j, 0} end)) != :none
  end

  defp isolated(fun) do
    {pid, ref} =
      spawn_monitor(fn ->
        result = fun.()
        exit({:shutdown, {:blossom_result, result}})
      end)

    receive do
      {:DOWN, ^ref, :process, ^pid, {:shutdown, {:blossom_result, result}}} -> result
      {:DOWN, ^ref, :process, ^pid, reason} -> raise "blossom matcher crashed: #{inspect(reason)}"
    end
  end

  # ------------------------------------------------------------------
  # The algorithm. Names follow mwmatching.py so the port can be read
  # against it line by line: vertices 0..nv-1, blossoms nv..2nv-1,
  # "endpoints" p = 2k / 2k+1 for edge k's two ends.
  # ------------------------------------------------------------------

  defp g(tag, i), do: Process.get({tag, i})
  defp p(tag, i, v), do: Process.put({tag, i}, v)
  defp nv, do: Process.get(:nv)

  defp edge(k), do: elem(Process.get(:edges), k)
  defp endpoint(pp), do: elem(edge(div(pp, 2)), rem(pp, 2))

  defp slack(k) do
    {i, j, w} = edge(k)
    g(:dual, i) + g(:dual, j) - 2 * w
  end

  defp max_weight_matching(nvertex, edge_list) do
    edges = List.to_tuple(edge_list)
    nedge = tuple_size(edges)
    Process.put(:edges, edges)
    Process.put(:nv, nvertex)
    maxweight = max(0, edge_list |> Enum.map(&elem(&1, 2)) |> Enum.max())

    for v <- 0..(nvertex - 1), do: p(:nb, v, [])

    for k <- (nedge - 1)..0//-1 do
      {i, j, _} = elem(edges, k)
      p(:nb, i, [2 * k + 1 | g(:nb, i)])
      p(:nb, j, [2 * k | g(:nb, j)])
    end

    for v <- 0..(nvertex - 1) do
      p(:mate, v, -1)
      p(:inb, v, v)
      p(:base, v, v)
      p(:dual, v, maxweight)
    end

    for b <- 0..(2 * nvertex - 1) do
      p(:label, b, 0)
      p(:labelend, b, -1)
      p(:bparent, b, -1)
      p(:childs, b, nil)
      p(:endps, b, nil)
      p(:bestedge, b, -1)
      p(:bbest, b, nil)
    end

    for b <- nvertex..(2 * nvertex - 1) do
      p(:base, b, -1)
      p(:dual, b, 0)
    end

    Process.put(:unused, Enum.to_list(nvertex..(2 * nvertex - 1)))
    Process.put(:nedge, nedge)

    stages(nvertex)

    Map.new(0..(nvertex - 1), fn v ->
      m = g(:mate, v)
      {v, if(m >= 0, do: endpoint(m), else: -1)}
    end)
  end

  defp stages(0), do: :ok

  defp stages(left) do
    nvx = nv()

    for b <- 0..(2 * nvx - 1) do
      p(:label, b, 0)
      p(:bestedge, b, -1)
    end

    for b <- nvx..(2 * nvx - 1), do: p(:bbest, b, nil)
    for k <- 0..(Process.get(:nedge) - 1)//1, do: p(:allow, k, false)
    Process.put(:queue, [])

    for v <- 0..(nvx - 1) do
      if g(:mate, v) == -1 and g(:label, g(:inb, v)) == 0, do: assign_label(v, 1, -1)
    end

    if substages() do
      # End of stage: expand S-blossoms whose dual reached zero.
      for b <- nvx..(2 * nvx - 1) do
        if g(:bparent, b) == -1 and g(:base, b) >= 0 and g(:label, b) == 1 and g(:dual, b) == 0 do
          expand_blossom(b, true)
        end
      end

      stages(left - 1)
    else
      :ok
    end
  end

  defp queue_push(vs), do: Process.put(:queue, Process.get(:queue) ++ List.wrap(vs))

  defp queue_pop do
    case Process.get(:queue) do
      [] ->
        nil

      q ->
        {v, rest} = List.pop_at(q, -1)
        Process.put(:queue, rest)
        v
    end
  end

  # true when the stage augmented, false when no augmenting path exists.
  defp substages do
    if scan_queue() do
      true
    else
      nvx = nv()

      # delta2: free vertex to S-vertex.
      {dt, delta, dedge} =
        Enum.reduce(0..(nvx - 1), {-1, nil, nil}, fn v, {dt, delta, de} = acc ->
          be = g(:bestedge, v)

          if g(:label, g(:inb, v)) == 0 and be != -1 do
            d = slack(be)
            if dt == -1 or d < delta, do: {2, d, be}, else: acc
          else
            {dt, delta, de}
          end
        end)

      # delta3: half the slack between two S-blossoms.
      {dt, delta, dedge} =
        Enum.reduce(0..(2 * nvx - 1), {dt, delta, dedge}, fn b, {dt, delta, _de} = acc ->
          be = g(:bestedge, b)

          if g(:bparent, b) == -1 and g(:label, b) == 1 and be != -1 do
            ks = slack(be)
            0 = rem(ks, 2)
            d = div(ks, 2)
            if dt == -1 or d < delta, do: {3, d, be}, else: acc
          else
            acc
          end
        end)

      # delta4: a T-blossom's dual reaching zero.
      {dt, delta, dedge, dblossom} =
        Enum.reduce(nvx..(2 * nvx - 1), {dt, delta, dedge, nil}, fn b,
                                                                    {dt, delta, de, db} = acc ->
          if g(:base, b) >= 0 and g(:bparent, b) == -1 and g(:label, b) == 2 and
               (dt == -1 or g(:dual, b) < delta) do
            {4, g(:dual, b), de, b}
          else
            _ = db
            acc
          end
        end)

      {dt, delta} =
        if dt == -1 do
          # Max cardinality: no more progress is possible; one last dual
          # step and stop.
          {1, max(0, Enum.min(for v <- 0..(nvx - 1), do: g(:dual, v)))}
        else
          {dt, delta}
        end

      for v <- 0..(nvx - 1) do
        case g(:label, g(:inb, v)) do
          1 -> p(:dual, v, g(:dual, v) - delta)
          2 -> p(:dual, v, g(:dual, v) + delta)
          _ -> :ok
        end
      end

      for b <- nvx..(2 * nvx - 1) do
        if g(:base, b) >= 0 and g(:bparent, b) == -1 do
          case g(:label, b) do
            1 -> p(:dual, b, g(:dual, b) + delta)
            2 -> p(:dual, b, g(:dual, b) - delta)
            _ -> :ok
          end
        end
      end

      case dt do
        1 ->
          false

        2 ->
          p(:allow, dedge, true)
          {i, j, _} = edge(dedge)
          i = if g(:label, g(:inb, i)) == 0, do: j, else: i
          1 = g(:label, g(:inb, i))
          queue_push(i)
          substages()

        3 ->
          p(:allow, dedge, true)
          {i, _j, _} = edge(dedge)
          1 = g(:label, g(:inb, i))
          queue_push(i)
          substages()

        4 ->
          expand_blossom(dblossom, false)
          substages()
      end
    end
  end

  # Returns true on augmentation.
  defp scan_queue do
    case queue_pop() do
      nil ->
        false

      v ->
        1 = g(:label, g(:inb, v))

        if scan_neighbours(v, g(:nb, v)) do
          true
        else
          scan_queue()
        end
    end
  end

  defp scan_neighbours(_v, []), do: false

  defp scan_neighbours(v, [pp | rest]) do
    k = div(pp, 2)
    w = endpoint(pp)

    if g(:inb, v) == g(:inb, w) do
      scan_neighbours(v, rest)
    else
      kslack =
        if g(:allow, k) do
          nil
        else
          ks = slack(k)
          if ks <= 0, do: p(:allow, k, true)
          ks
        end

      cond do
        g(:allow, k) ->
          lw = g(:label, g(:inb, w))

          cond do
            lw == 0 ->
              assign_label(w, 2, bxor(pp, 1))
              scan_neighbours(v, rest)

            lw == 1 ->
              base = scan_blossom(v, w)

              if base >= 0 do
                add_blossom(base, k)
                scan_neighbours(v, rest)
              else
                augment_matching(k)
                true
              end

            g(:label, w) == 0 ->
              2 = lw
              p(:label, w, 2)
              p(:labelend, w, bxor(pp, 1))
              scan_neighbours(v, rest)

            true ->
              scan_neighbours(v, rest)
          end

        g(:label, g(:inb, w)) == 1 ->
          b = g(:inb, v)
          be = g(:bestedge, b)
          if be == -1 or kslack < slack(be), do: p(:bestedge, b, k)
          scan_neighbours(v, rest)

        g(:label, w) == 0 ->
          be = g(:bestedge, w)
          if be == -1 or kslack < slack(be), do: p(:bestedge, w, k)
          scan_neighbours(v, rest)

        true ->
          scan_neighbours(v, rest)
      end
    end
  end

  defp leaves(b) do
    if b < nv() do
      [b]
    else
      Enum.flat_map(g(:childs, b), &leaves/1)
    end
  end

  defp assign_label(w, t, pp) do
    b = g(:inb, w)
    0 = g(:label, w)
    0 = g(:label, b)
    p(:label, w, t)
    p(:label, b, t)
    p(:labelend, w, pp)
    p(:labelend, b, pp)
    p(:bestedge, w, -1)
    p(:bestedge, b, -1)

    case t do
      1 ->
        queue_push(leaves(b))

      2 ->
        base = g(:base, b)
        mb = g(:mate, base)
        true = mb >= 0
        assign_label(endpoint(mb), 1, bxor(mb, 1))
    end
  end

  # Trace back from v and w to find a common ancestor blossom (a new
  # blossom's base) or -1 for an augmenting path.
  defp scan_blossom(v, w) do
    {path, base} = scan_blossom_loop(v, w, [])
    for b <- path, do: p(:label, b, 1)
    base
  end

  defp scan_blossom_loop(-1, -1, path), do: {path, -1}

  defp scan_blossom_loop(v, w, path) do
    b = g(:inb, v)

    if (g(:label, b) &&& 4) != 0 do
      {path, g(:base, b)}
    else
      1 = g(:label, b)
      path = [b | path]
      p(:label, b, 5)

      v =
        if g(:labelend, b) == -1 do
          -1
        else
          t = endpoint(g(:labelend, b))
          bt = g(:inb, t)
          2 = g(:label, bt)
          endpoint(g(:labelend, bt))
        end

      if w != -1, do: scan_blossom_loop(w, v, path), else: scan_blossom_loop(v, w, path)
    end
  end

  defp add_blossom(base, k) do
    {v, w, _} = edge(k)
    bb = g(:inb, base)
    bv = g(:inb, v)
    bw = g(:inb, w)
    [b | unused] = Process.get(:unused)
    Process.put(:unused, unused)
    p(:base, b, base)
    p(:bparent, b, -1)
    p(:bparent, bb, b)

    # From v's side back to the base.
    {vpath, vendps} = climb(bv, bb, b, [], [], fn lend -> lend end)
    # vpath/vendps are in climb order (bv first); the blossom's child list
    # starts at bb and runs the other way.
    path = [bb | Enum.reverse(vpath)]
    endps = Enum.reverse(vendps) ++ [2 * k]
    {wpath, wendps} = climb(bw, bb, b, [], [], fn lend -> bxor(lend, 1) end)
    path = path ++ wpath
    endps = endps ++ wendps

    p(:childs, b, path)
    p(:endps, b, endps)
    1 = g(:label, bb)
    p(:label, b, 1)
    p(:labelend, b, g(:labelend, bb))
    p(:dual, b, 0)

    for lv <- leaves(b) do
      if g(:label, g(:inb, lv)) == 2, do: queue_push(lv)
      p(:inb, lv, b)
    end

    bestedgeto =
      Enum.reduce(path, %{}, fn cb, acc ->
        nblists =
          case g(:bbest, cb) do
            nil -> [Enum.flat_map(leaves(cb), fn lv -> Enum.map(g(:nb, lv), &div(&1, 2)) end)]
            list -> [list]
          end

        acc =
          for nblist <- nblists, kk <- nblist, reduce: acc do
            acc ->
              {i, j, _} = edge(kk)
              j = if g(:inb, j) == b, do: i, else: j
              bj = g(:inb, j)

              if bj != b and g(:label, bj) == 1 and
                   (not Map.has_key?(acc, bj) or slack(kk) < slack(acc[bj])) do
                Map.put(acc, bj, kk)
              else
                acc
              end
          end

        p(:bbest, cb, nil)
        p(:bestedge, cb, -1)
        acc
      end)

    best_list = bestedgeto |> Enum.sort() |> Enum.map(&elem(&1, 1))
    p(:bbest, b, best_list)

    best =
      Enum.reduce(best_list, -1, fn kk, be ->
        if be == -1 or slack(kk) < slack(be), do: kk, else: be
      end)

    p(:bestedge, b, best)
  end

  # Walk from blossom `bx` up the alternating tree to `bb`, setting parents.
  defp climb(bx, bb, _b, path, endps, _f) when bx == bb,
    do: {Enum.reverse(path), Enum.reverse(endps)}

  defp climb(bx, bb, b, path, endps, f) do
    p(:bparent, bx, b)
    lend = g(:labelend, bx)
    true = lend >= 0
    next = g(:inb, endpoint(lend))
    climb(next, bb, b, [bx | path], [f.(lend) | endps], f)
  end

  defp expand_blossom(b, endstage) do
    nvx = nv()
    childs = g(:childs, b)
    endps = g(:endps, b)

    for s <- childs do
      p(:bparent, s, -1)

      cond do
        s < nvx -> p(:inb, s, s)
        endstage and g(:dual, s) == 0 -> expand_blossom(s, endstage)
        true -> for lv <- leaves(s), do: p(:inb, lv, s)
      end
    end

    if not endstage and g(:label, b) == 2 do
      true = g(:labelend, b) >= 0
      entrychild = g(:inb, endpoint(bxor(g(:labelend, b), 1)))
      j = Enum.find_index(childs, &(&1 == entrychild))
      len = length(childs)

      {j, jstep, endptrick} =
        if (j &&& 1) == 1, do: {j - len, 1, 0}, else: {j, -1, 1}

      pp = g(:labelend, b)
      {j, pp} = relabel_path(j, jstep, endptrick, pp, endps)

      bv = Enum.at(childs, j)
      ep = endpoint(bxor(pp, 1))
      p(:label, ep, 2)
      p(:label, bv, 2)
      p(:labelend, ep, pp)
      p(:labelend, bv, pp)
      p(:bestedge, bv, -1)
      relabel_rest(j + jstep, jstep, childs, entrychild)
    end

    p(:label, b, -1)
    p(:labelend, b, -1)
    p(:childs, b, nil)
    p(:endps, b, nil)
    p(:base, b, -1)
    p(:bbest, b, nil)
    p(:bestedge, b, -1)
    Process.put(:unused, [b | Process.get(:unused)])
  end

  defp relabel_path(0, _jstep, _trick, pp, _endps), do: {0, pp}

  defp relabel_path(j, jstep, trick, pp, endps) do
    p(:label, endpoint(bxor(pp, 1)), 0)
    e = Enum.at(endps, j - trick)
    p(:label, endpoint(bxor(bxor(e, trick), 1)), 0)
    assign_label(endpoint(bxor(pp, 1)), 2, pp)
    p(:allow, div(e, 2), true)
    j = j + jstep
    pp = bxor(Enum.at(endps, j - trick), trick)
    p(:allow, div(pp, 2), true)
    relabel_path(j + jstep, jstep, trick, pp, endps)
  end

  defp relabel_rest(j, jstep, childs, entrychild) do
    bv = Enum.at(childs, j)

    cond do
      bv == entrychild ->
        :ok

      g(:label, bv) == 1 ->
        relabel_rest(j + jstep, jstep, childs, entrychild)

      true ->
        lvs = leaves(bv)
        v = Enum.find(lvs, List.last(lvs), &(g(:label, &1) != 0))

        if g(:label, v) != 0 do
          2 = g(:label, v)
          ^bv = g(:inb, v)
          p(:label, v, 0)
          p(:label, endpoint(g(:mate, g(:base, bv))), 0)
          assign_label(v, 2, g(:labelend, v))
        end

        relabel_rest(j + jstep, jstep, childs, entrychild)
    end
  end

  defp augment_blossom(b, v) do
    t = top_below(v, b)
    if t >= nv(), do: augment_blossom(t, v)
    childs = g(:childs, b)
    endps = g(:endps, b)
    i = Enum.find_index(childs, &(&1 == t))
    len = length(childs)

    {j, jstep, trick} =
      if (i &&& 1) == 1, do: {i - len, 1, 0}, else: {i, -1, 1}

    augment_walk(j, jstep, trick, childs, endps)

    childs = Enum.drop(childs, i) ++ Enum.take(childs, i)
    endps = Enum.drop(endps, i) ++ Enum.take(endps, i)
    p(:childs, b, childs)
    p(:endps, b, endps)
    p(:base, b, g(:base, hd(childs)))
    ^v = g(:base, b)
  end

  defp top_below(t, b) do
    if g(:bparent, t) == b, do: t, else: top_below(g(:bparent, t), b)
  end

  defp augment_walk(0, _jstep, _trick, _childs, _endps), do: :ok

  defp augment_walk(j, jstep, trick, childs, endps) do
    j = j + jstep
    t = Enum.at(childs, j)
    pp = bxor(Enum.at(endps, j - trick), trick)
    if t >= nv(), do: augment_blossom(t, endpoint(pp))
    j = j + jstep
    t = Enum.at(childs, j)
    if t >= nv(), do: augment_blossom(t, endpoint(bxor(pp, 1)))
    p(:mate, endpoint(pp), bxor(pp, 1))
    p(:mate, endpoint(bxor(pp, 1)), pp)
    augment_walk(j, jstep, trick, childs, endps)
  end

  defp augment_matching(k) do
    {v, w, _} = edge(k)
    augment_side(v, 2 * k + 1)
    augment_side(w, 2 * k)
  end

  defp augment_side(s, pp) do
    bs = g(:inb, s)
    1 = g(:label, bs)
    if bs >= nv(), do: augment_blossom(bs, s)
    p(:mate, s, pp)

    if g(:labelend, bs) != -1 do
      t = endpoint(g(:labelend, bs))
      bt = g(:inb, t)
      2 = g(:label, bt)
      true = g(:labelend, bt) >= 0
      s2 = endpoint(g(:labelend, bt))
      j = endpoint(bxor(g(:labelend, bt), 1))
      ^t = g(:base, bt)
      if bt >= nv(), do: augment_blossom(bt, j)
      p(:mate, j, g(:labelend, bt))
      augment_side(s2, bxor(g(:labelend, bt), 1))
    end
  end
end
