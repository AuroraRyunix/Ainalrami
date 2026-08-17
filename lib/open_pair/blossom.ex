defmodule OpenPair.Blossom do
  @moduledoc """
  Edmonds' Blossom algorithm — general-graph maximum matching via
  augmenting paths. Reached from `OpenPair.Pairing`'s bye-count repair
  pass.

  **That pass is currently unreachable in production**, so nothing here
  runs outside its own tests: `repair_bye_count/3`'s guard `bye_legal?/3`
  checks bye count and C2 eligibility over exactly the set that
  `check_completion/3` has already checked for both, plus C5 — a proper
  subset, so the repair branch never fires. There is also no "greedy
  fallback" for it to follow; the per-bracket cascade that had one was
  deleted. Kept, tested and labelled rather than removed, because the
  guard it backs is cheap and the day `check_completion/3` is relaxed is
  the day this matters.

  A plain alternating-path search (breadth-first from an unmatched
  vertex, stepping a non-matching edge then a matching edge) finds every
  augmenting path in a BIPARTITE graph, but can miss one hidden inside an
  odd cycle of a GENERAL graph — a "blossom". That was the gap in this
  project's first attempt at the repair pass: a plain BFS closed
  1477 -> 65 illegal rounds at 30-round depth, and the 65 remaining are
  exactly the ones a blossom-blind search cannot reach.

  This is a direct translation of the standard O(V^3) reference algorithm
  (see e.g. e-maxx.ru's "blossom" article, the classical write-up of
  Edmonds 1965) into Elixir: the reference's mutable `p[]`/`base[]`/
  `used[]` arrays become maps threaded explicitly through recursive
  search functions instead of arrays mutated in place. The core trick —
  contracting an odd cycle to a single vertex via `base[]` redirection
  rather than actually merging the graph, and reassigning parent
  pointers on the way so the eventual path back to root still resolves
  correctly through a contracted blossom — is unchanged from the
  reference.
  """

  @doc """
  Augments `matching` by running one augmenting-path search from every
  currently-unmatched vertex in `vertices`, applying each path found
  before moving to the next.

  `matching` must carry BOTH directions of every existing pair (`m[a] ==
  b` implies `m[b] == a`) and is returned in the same shape.
  `neighbours_fun.(vertex)` returns the vertices `vertex` could legally
  be paired with — the graph is exactly what this function reports, so
  any pairing constraint (no rematches, colour compatibility, ...) is
  enforced by the caller, not here.

  Running one full augmenting-path search per unmatched vertex, in any
  order, is what the reference algorithm's own outer loop does, and is
  what gives the overall result the "maximum matching" guarantee — a
  single search only guarantees finding a path FROM that one root, not
  that the whole graph is done.
  """
  def augment(vertices, matching, neighbours_fun) do
    Enum.reduce(vertices, matching, fn root, matching ->
      if Map.has_key?(matching, root) do
        matching
      else
        case find_augmenting_path(root, vertices, matching, neighbours_fun) do
          nil -> matching
          {free, parent} -> flip_path(matching, free, parent)
        end
      end
    end)
  end

  # Breadth-first alternating-path search with blossom contraction, from
  # `root` (must be unmatched). Returns `{free_vertex, parent}` — the
  # vertex the path ends at and the parent map needed to trace the whole
  # path back to root — or `nil` if root cannot be matched.
  defp find_augmenting_path(root, vertices, matching, neighbours_fun) do
    state = %{
      base: Map.new(vertices, &{&1, &1}),
      parent: %{},
      used: MapSet.new([root]),
      queue: :queue.in(root, :queue.new())
    }

    case bfs(state, root, matching, neighbours_fun) do
      nil -> nil
      {:found, free, parent} -> {free, parent}
    end
  end

  defp bfs(state, root, matching, neighbours_fun) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        nil

      {{:value, v}, rest} ->
        state = %{state | queue: rest}

        case visit(v, neighbours_fun.(v), root, state, matching) do
          {:found, _free, _parent} = result -> result
          {:continue, state} -> bfs(state, root, matching, neighbours_fun)
        end
    end
  end

  defp visit(_v, [], _root, state, _matching), do: {:continue, state}

  defp visit(v, [to | rest], root, state, matching) do
    same_blossom? = Map.fetch!(state.base, v) == Map.fetch!(state.base, to)
    matching_edge? = Map.get(matching, v) == to

    cond do
      same_blossom? or matching_edge? ->
        visit(v, rest, root, state, matching)

      to == root or blossom_edge?(to, state.parent, matching) ->
        state = contract(v, to, state, matching)
        visit(v, rest, root, state, matching)

      not Map.has_key?(state.parent, to) ->
        parent = Map.put(state.parent, to, v)

        if Map.has_key?(matching, to) do
          partner = Map.fetch!(matching, to)

          state = %{
            state
            | parent: parent,
              used: MapSet.put(state.used, partner),
              queue: :queue.in(partner, state.queue)
          }

          visit(v, rest, root, state, matching)
        else
          {:found, to, parent}
        end

      true ->
        visit(v, rest, root, state, matching)
    end
  end

  # An edge to an already-explored vertex closes an odd cycle rather than
  # extending the tree: `to`'s match partner is itself already in the
  # tree (has a parent recorded).
  defp blossom_edge?(to, parent, matching) do
    case Map.get(matching, to) do
      nil -> false
      partner -> Map.has_key?(parent, partner)
    end
  end

  defp contract(v, to, state, matching) do
    curbase = lca(v, to, state.base, state.parent, matching)

    {blossom, parent} =
      mark_path(v, curbase, to, MapSet.new(), state.base, state.parent, matching)

    {blossom, parent} = mark_path(to, curbase, v, blossom, state.base, parent, matching)

    state = %{state | parent: parent}

    Enum.reduce(Map.keys(state.base), state, fn i, state ->
      if MapSet.member?(blossom, Map.fetch!(state.base, i)) do
        state = %{state | base: Map.put(state.base, i, curbase)}

        if MapSet.member?(state.used, i) do
          state
        else
          %{state | used: MapSet.put(state.used, i), queue: :queue.in(i, state.queue)}
        end
      else
        state
      end
    end)
  end

  # The lowest common ancestor of `a` and `b` in the (partially built)
  # alternating tree, walking each up via its own matched partner's
  # parent until the walks meet. Every such walk terminates at the
  # search's root, which is always unmatched — that is what guarantees
  # this halts.
  defp lca(a, b, base, parent, matching) do
    ancestors = walk_up(a, base, parent, matching, MapSet.new())
    first_shared(b, base, parent, matching, ancestors)
  end

  defp walk_up(v, base, parent, matching, seen) do
    v = Map.fetch!(base, v)
    seen = MapSet.put(seen, v)

    case Map.get(matching, v) do
      nil -> seen
      partner -> walk_up(Map.fetch!(parent, partner), base, parent, matching, seen)
    end
  end

  defp first_shared(v, base, parent, matching, seen) do
    v = Map.fetch!(base, v)

    if MapSet.member?(seen, v) do
      v
    else
      partner = Map.fetch!(matching, v)
      first_shared(Map.fetch!(parent, partner), base, parent, matching, seen)
    end
  end

  # Walks from `v` up to the blossom's base `curbase`, collecting every
  # blossom vertex encountered and reassigning parent pointers to
  # `child` as it goes — the reassignment is what lets the eventual
  # trace-back in `flip_path/3` resolve correctly through a vertex that
  # turned out to be inside a contracted blossom, without ever having to
  # expand the blossom back out again.
  defp mark_path(v, curbase, child, blossom, base, parent, matching) do
    if Map.fetch!(base, v) == curbase do
      {blossom, parent}
    else
      partner = Map.fetch!(matching, v)

      blossom =
        blossom
        |> MapSet.put(Map.fetch!(base, v))
        |> MapSet.put(Map.fetch!(base, partner))

      parent = Map.put(parent, v, child)
      next_v = Map.fetch!(parent, partner)
      mark_path(next_v, curbase, partner, blossom, base, parent, matching)
    end
  end

  # Applies the augmenting path ending at `free`, walking back to the
  # root via `parent` and flipping each edge from unmatched to matched
  # (and vice versa) as it goes. This is the reference algorithm's own
  # trace-back: it never materialises the path as a list, just walks
  # `parent`/`matching` together, which is why `find_augmenting_path/4`
  # only needed to return the endpoint and the parent map.
  defp flip_path(matching, nil, _parent), do: matching

  defp flip_path(matching, a, parent) do
    pa = Map.fetch!(parent, a)
    ppa = Map.get(matching, pa)
    matching = matching |> Map.put(a, pa) |> Map.put(pa, a)
    flip_path(matching, ppa, parent)
  end
end
