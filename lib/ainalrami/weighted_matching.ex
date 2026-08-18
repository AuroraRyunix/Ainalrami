defmodule Ainalrami.WeightedMatching do
  @moduledoc """
  Maximum-weight matching in a general (non-bipartite) graph — the
  Galil/Micali/Gabow (1986) primal-dual algorithm, confirmed as what
  bbpPairings actually uses from its own source (`src/matching/computer.h`:
  "the basic algorithm presented in 'An O(EV log V) Algorithm for Finding
  a Maximal Weighted Matching in General Graphs'", implemented at O(n^3)).

  This is a port of the CONTROL FLOW read directly from that source
  (`src/matching/detail/graph.cpp`, `rootblossom.cpp`, `parentblossom.cpp`,
  `computer.cpp`) — not a reconstruction from memory. An earlier attempt
  in this project WAS written from memory and was wrong in a way that
  wouldn't have announced itself (a stub main loop, a silently-overwritten
  branch) — exactly the failure mode a weighted matcher is dangerous for,
  since a wrong result here is a legal-looking pairing that simply isn't
  the best one, not an illegal one a legality check would catch.

  ## What's simplified relative to bbpPairings, and why that's safe

  bbpPairings maintains incremental caches (`minOuterEdges` tables,
  per-blossom `minOuterEdgeResistance`) specifically so it never rescans
  the whole graph — that's what gets it to O(n^3). This module rescans
  instead: every "find the minimum X" step in `graph.cpp` is reproduced
  here as a plain `Enum` walk over the current state. That trades
  asymptotic complexity for a much smaller, more directly verifiable
  translation of the same mathematical method — legitimate specifically
  because `Ainalrami.Pairing`'s brackets are small in practice (measured:
  median 9, p90 19 for a combined current+next bracket), not because the
  complexity doesn't matter in general.

  ## The four dual-adjustment cases

  Every "stage" (one call to `augment_once/1`) grows an alternating
  forest from every currently-unmatched vertex, repeatedly finding the
  SMALLEST amount by which every dual variable in the forest can move
  before something becomes tight, and reacting to whichever thing that
  is:

    * an unmatched OUTER vertex's own dual variable hits zero — done,
      matching increases by one (see `graph.cpp`'s
      `!minOuterDualVariable` branch)
    * a ZERO-labelled (already-zero-dual, unmatched) vertex becomes
      tight against an OUTER vertex — augment directly between them
    * two OUTER vertices in DIFFERENT trees become tight — augment
      between them
    * two OUTER vertices in the SAME tree become tight — that closes an
      odd cycle; contract it into one blossom
    * a FREE (matched, not yet in the forest) vertex becomes tight
      against an OUTER vertex — grow the tree: label it INNER, label its
      match OUTER
    * an INNER blossom's OWN dual variable hits zero — it has no slack
      left to contribute; dissolve it back into its children, relabelling
      each by position relative to where the tree entered it

  Verified against `Ainalrami.Matching`'s exact subset-DP as an
  independent oracle — see `weighted_matching_test.exs` — because total
  weight is the one thing a legality check cannot confirm.

  ## Doubled weights

  Following bbpPairings exactly: every edge weight is doubled internally
  so dual variables stay integral through the `>> 1` divisions the
  four-way minimum needs. `solve/2` takes plain integer weights and
  doubles them itself.
  """

  @doc """
  Maximum-weight matching over vertices `0..n-1`.

  `edges` is `[{i, j, weight}]` with POSITIVE integer weights (zero and
  negative are treated as "no edge" — bbpPairings' own convention, and
  safe here because `Ainalrami.Pairing`'s packed criterion weights are
  always at least 1 for any legal pair: the lowest-priority term, rank
  spread, is `abs(a.rank - b.rank)` and a pair's two ranks are always
  distinct).

  Returns `%{vertex => partner}` with both directions of every matched
  pair present; unmatched vertices are absent from the map.
  """
  def solve(n, _edges) when n <= 1, do: %{}

  def solve(n, edges) do
    n
    |> build_state(edges)
    |> augment_until_done()
    |> resolve_all_matching()
    |> to_matching()
  end

  defp build_state(n, edges) do
    # Adjacency, not a flat `{u, v} => w` map. `resistance/3` is the
    # innermost operation in the whole algorithm -- the delta scans call it
    # once per vertex pair, every step -- and a tuple key means allocating
    # and hashing a two-tuple on each of those. Nesting lets the scans
    # fetch one vertex's row once and then do plain single-key lookups
    # against it.
    weights =
      Enum.reduce(edges, %{}, fn {i, j, w}, acc ->
        if w > 0 do
          acc
          |> Map.update(i, %{j => 2 * w}, &Map.put(&1, j, 2 * w))
          |> Map.update(j, %{i => 2 * w}, &Map.put(&1, i, 2 * w))
        else
          acc
        end
      end)

    max_w =
      Enum.reduce(edges, 0, fn {_i, _j, w}, acc ->
        if w > 0, do: max(acc, 2 * w), else: acc
      end)

    state = %{
      n: n,
      weight: weights,
      # Dual variable per VERTEX only — bbpPairings separately tracks a
      # dual variable per BLOSSOM (`ParentBlossom.dualVariable`); this
      # merges that into the same map keyed by blossom id (>= n for
      # non-trivial blossoms), since nothing about the algorithm needs
      # them kept apart.
      dual: Map.new(0..(n - 1), &{&1, max_w}),
      mate: %{},
      # `in_blossom[v]` is always the TOP-LEVEL blossom currently
      # containing vertex v — the direct analogue of bbpPairings'
      # `Vertex.rootBlossom`.
      in_blossom: Map.new(0..(n - 1), &{&1, &1}),
      # Nested structure, needed only for expansion: children in cyclic
      # order starting from the child containing the base, and each
      # child's parent. Trivial (single-vertex) blossoms have no entry.
      children: %{},
      parent_of: %{},
      base: Map.new(0..(n - 1), &{&1, &1}),
      # Per TOP-LEVEL blossom, ASYMMETRIC: the external vertex this
      # blossom's base is matched to, or nil. This is the direct
      # analogue of bbpPairings' `RootBlossom.baseVertexMatch` — a
      # per-blossom field, deliberately NOT required to agree with the
      # other side's own field at every instant.
      #
      # Kept separate from `mate` (below) after tracing exactly why that
      # separation matters: augmenting a tight edge between two DIFFERENT
      # trees calls `augment_to_source` from BOTH endpoints in turn. If
      # "was this blossom already matched" were read from the same
      # SYMMETRIC map the first call just wrote into, the second call
      # would see its own sibling's brand-new write and misread it as a
      # stale match needing further walking — an infinite loop on
      # anything past the trivial one-edge case.
      blossom_match: %{},
      # Connector vertex pair for every cyclically-adjacent pair of
      # children ever formed — see `form_blossom/3`'s doc.
      connectors: %{},
      # Per TOP-LEVEL blossom only.
      label: %{},
      # {labeling_vertex, labeled_vertex}: the edge that connected this
      # INNER blossom to its OUTER parent when the tree grew into it.
      label_edge: %{},
      next_blossom_id: n
    }

    state
  end

  # A stage bound of `2n` is generous — the reference algorithm needs at
  # most n stages total (one per matching-size increase) — so hitting
  # this is a bug, not a slow instance, and failing loudly beats hanging.
  defp augment_until_done(state), do: augment_until_done(state, 2 * state.n + 5)

  defp augment_until_done(_state, 0), do: raise("WeightedMatching: exceeded stage budget")

  defp augment_until_done(state, budget) do
    case augment_once(state) do
      {:ok, state} -> augment_until_done(state, budget - 1)
      :done -> state
    end
  end

  defp to_matching(state) do
    # `state.mate` is already `%{vertex => partner}`; this used to rebuild it
    # key by key, which is an identity copy with extra steps.
    state.mate
  end

  # ---------------------------------------------------------- one stage

  # Grows one alternating forest from every exposed vertex until either
  # the matching grows by one (returns `{:ok, state}`) or no exposed
  # OUTER vertex remains, meaning the current matching is already maximum
  # (Berge's theorem: no augmenting path exists) — `:done`.
  defp augment_once(state) do
    state = init_labels(state)
    Process.put(:wm_grow_steps, 0)

    case min_outer_dual(state) do
      nil -> :done
      _ -> grow(state)
    end
  end

  defp init_labels(state) do
    label =
      Enum.reduce(top_blossoms(state), %{}, fn b, acc ->
        cond do
          matched?(state, b) -> Map.put(acc, b, :free)
          dual_of(state, base_vertex(state, b)) > 0 -> Map.put(acc, b, :outer)
          true -> Map.put(acc, b, :zero)
        end
      end)

    %{state | label: label, label_edge: %{}}
  end

  # Every currently top-level blossom id — vertices not absorbed into a
  # larger blossom, plus every non-trivial blossom with no parent.
  #
  # SORTED, and that is not cosmetic. `Map.values/1` returns Erlang's
  # internal order, which changes shape at the 32-key flatmap-to-hashmap
  # transition, and every consumer here breaks ties with a strict `<` —
  # first encountered wins. `min_free_or_zero_to_outer/1`, `min_outer_edge/2`,
  # `outer_vertices/1`, `min_outer_outer/1` and `grow/1`'s `Enum.find` for a
  # zero-dual outer vertex all inherit whatever order this returns. So when
  # several maximum-weight matchings tie, which one came back was decided by
  # map internals: reproducible for identical input, but not canonical, and
  # free to change with the field size or an Erlang release.
  #
  # Blossom ids are integers (vertices are `0..n-1`, blossoms are allocated
  # above that), so sorting gives a total order that is stable, cheap, and
  # tied to the problem rather than to the runtime. docs/engineering-log.md's argument that
  # the refinement stages leave no ties to break is an empirical observation
  # over one corpus, not an invariant — and an invariant is what a pairing
  # engine's determinism should rest on.
  defp top_blossoms(state) do
    state.in_blossom |> Map.values() |> Enum.uniq() |> Enum.sort()
  end

  defp matched?(state, b), do: Map.has_key?(state.blossom_match, b)
  defp base_vertex(state, b), do: Map.fetch!(state.base, b)
  defp dual_of(state, v), do: Map.fetch!(state.dual, v)

  defp min_outer_dual(state) do
    top_blossoms(state)
    |> Enum.filter(&(Map.get(state.label, &1) == :outer))
    |> Enum.map(&dual_of(state, base_vertex(state, &1)))
    |> case do
      [] -> nil
      duals -> Enum.min(duals)
    end
  end

  # ------------------------------------------------------- the main loop

  defp grow(state) do
    # A cheap safety net, not a normal path: this many iterations within
    # ONE stage would mean the search is stuck, not merely slow, since
    # each iteration makes the search strictly more constrained. Left in
    # after using it (with tracing, since removed) to localise the
    # infinite-recursion bug in an earlier version's blossom resolution —
    # failing loudly beats hanging silently if a future change
    # reintroduces something similar.
    steps = Process.get(:wm_grow_steps, 0)

    if steps > 4 * state.n + 20 do
      raise "WeightedMatching: exceeded grow-step budget (#{steps} steps, n=#{state.n})"
    end

    Process.put(:wm_grow_steps, steps + 1)

    min_outer = min_outer_dual(state)

    # The smallest resistance from ANY free-or-zero vertex to an OUTER
    # one, tracked alongside which vertex achieves it — bbpPairings'
    # `minInnerOuterEdgeResistance`. Rescanned each iteration (see
    # moduledoc); still only O(n^2) per call and there are O(n) calls per
    # stage, which is fine at bracket scale.
    {min_free_outer, free_outer_vertex} = min_free_or_zero_to_outer(state)
    {min_outer_outer, outer_pair} = min_outer_outer(state)
    {min_inner_blossom, inner_blossom_id} = min_inner_blossom_dual(state)

    candidates =
      [
        min_outer,
        min_free_outer,
        (min_outer_outer && div(min_outer_outer, 2)) || nil,
        (min_inner_blossom && div(min_inner_blossom, 2)) || nil
      ]
      |> Enum.reject(&is_nil/1)

    # `augment_once/1` checks `min_outer_dual/1` before the FIRST call, but
    # `grow/1` re-enters itself (`{:grow, state} -> grow(state)` below) and
    # nothing rechecks it there. With no outer vertex left, `min_outer` is nil
    # and every other candidate can be nil too: `Enum.min([])` raised
    # `Enum.EmptyError`, and `min_outer - delta` below raised `ArithmeticError`
    # on nil. The step and stage budgets catch loops, not this.
    #
    # No matching this engine produces is known to reach it — it is guarded
    # rather than reproduced. An exhausted search is the same answer
    # `augment_once/1`'s own precheck gives: stop, and let the caller see the
    # matching as it stands.
    if candidates == [] or is_nil(min_outer) do
      {:done, state}
    else
      grow_with_delta(state, min_outer, min_free_outer, free_outer_vertex, min_outer_outer,
        outer_pair: outer_pair,
        min_inner_blossom: min_inner_blossom,
        inner_blossom_id: inner_blossom_id,
        delta: Enum.min(candidates)
      )
    end
  end

  defp grow_with_delta(state, min_outer, min_free_outer, free_outer_vertex, min_outer_outer, opts) do
    outer_pair = opts[:outer_pair]
    min_inner_blossom = opts[:min_inner_blossom]
    inner_blossom_id = opts[:inner_blossom_id]
    delta = opts[:delta]

    state = apply_delta(state, delta)

    cond do
      min_outer - delta == 0 ->
        # An exposed OUTER vertex's dual variable is now zero: it is its
        # own trivial augmenting path.
        v =
          base_vertex(
            state,
            Enum.find(
              top_blossoms(state),
              &(dual_of(state, base_vertex(state, &1)) == 0 and Map.get(state.label, &1) == :outer)
            )
          )

        {:ok, augment_to_source(state, v, nil)}

      min_free_outer && min_free_outer - delta == 0 ->
        handle_free_outer_tight(state, free_outer_vertex)

      min_outer_outer && min_outer_outer - 2 * delta == 0 ->
        handle_outer_outer_tight(state, outer_pair)

      min_inner_blossom && min_inner_blossom - 2 * delta == 0 ->
        {:cont, expand_blossom(state, inner_blossom_id)} |> continue_growing()

      true ->
        # Numerically shouldn't happen — one of the four must hit zero —
        # but guards against an infinite loop from a rounding slip rather
        # than hanging.
        :done
    end
    |> case do
      {:ok, _state} = result -> result
      {:grow, state} -> grow(state)
      :done -> :done
    end
  end

  defp continue_growing({:cont, state}), do: {:grow, state}

  defp handle_free_outer_tight(state, v) do
    outer_partner = min_outer_edge(state, v)

    if Map.get(state.label, Map.fetch!(state.in_blossom, v)) == :zero do
      # ZERO vertex tight against OUTER: augment directly.
      state = augment_to_source(state, outer_partner, v)
      state = augment_to_source(state, v, outer_partner)
      {:ok, state}
    else
      # FREE vertex tight against OUTER: grow the tree through it. Reads
      # v's BLOSSOM's own match field (asymmetric, per-blossom — see
      # `state.blossom_match`'s doc), not a vertex-level lookup on `v`
      # itself: v may not be its blossom's current base if that blossom
      # persisted, still non-trivial, from an earlier stage.
      v_blossom = Map.fetch!(state.in_blossom, v)
      matched_blossom = Map.fetch!(state.in_blossom, Map.fetch!(state.blossom_match, v_blossom))

      state = %{
        state
        | label: state.label |> Map.put(v_blossom, :inner) |> Map.put(matched_blossom, :outer),
          label_edge: Map.put(state.label_edge, v_blossom, {outer_partner, v})
      }

      {:grow, state}
    end
  end

  defp handle_outer_outer_tight(state, {v0, v1}) do
    b0 = Map.fetch!(state.in_blossom, v0)
    b1 = Map.fetch!(state.in_blossom, v1)

    if tree_root(state, b0) == tree_root(state, b1) do
      {:grow, form_blossom(state, v0, v1)}
    else
      state = augment_to_source(state, v0, v1)
      state = augment_to_source(state, v1, v0)
      {:ok, state}
    end
  end

  # The tree root reachable from blossom `b` by walking upward.
  #
  # This is the one place the earlier version of this port was
  # structurally wrong, not just off by a constant: an OUTER blossom
  # comes in two kinds. The literal tree root is unmatched (found in
  # `init_labels`). Every OTHER outer blossom got there by being some
  # INNER vertex's match partner — its base vertex's mate sits inside
  # that INNER blossom — and only the INNER SIDE of that connection ever
  # gets a `label_edge` entry (`handle_free_outer_tight` sets it on
  # `v_blossom`, never on `matched_blossom`). Treating a matched OUTER
  # blossom as a dead end, as an earlier version of this function did,
  # made every non-root OUTER blossom in a tree indistinguishable from
  # one in a different tree entirely.
  #
  # Confirmed against `graph.cpp`'s own walk-back loop
  # (`rootblossom->baseVertex` / `baseVertexMatch` / `labeledVertex` /
  # `labelingVertex`, four fields read in that order each step): from a
  # matched OUTER blossom, follow base -> its mate -> the mate's INNER
  # blossom -> that blossom's OWN label edge -> continue from there.
  defp tree_root(state, b) do
    case Map.get(state.label, b) do
      label when label in [:outer, :inner] -> List.last(blossom_ids_to_root(state, b))
      _ -> nil
    end
  end

  # --------------------------------------------------------- resistance

  # resistance(u, v) = dual[u] + dual[v] - weight(u, v); nil if no edge.
  defp resistance(state, u, v) do
    case state.weight do
      %{^u => row} ->
        case row do
          %{^v => w} -> dual_of(state, u) + dual_of(state, v) - w
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Hoisted rather than restructured: the traversal and the answer are
  # exactly what the straightforward nested `resistance/3` loop gave. What
  # moved is the repeated work — each outer vertex's dual is looked up once
  # for the whole scan instead of once per candidate, and each candidate's
  # adjacency row and dual once instead of once per outer vertex.
  defp min_free_or_zero_to_outer(state) do
    duals = state.dual
    outer_with_duals = Enum.map(outer_vertices(state), &{&1, Map.fetch!(duals, &1)})

    non_outer_blossoms =
      top_blossoms(state) |> Enum.filter(&(Map.get(state.label, &1) in [:free, :zero]))

    non_outer_blossoms
    |> Enum.flat_map(&blossom_vertices(state, &1))
    |> Enum.reduce({nil, nil}, fn v, acc ->
      case state.weight do
        %{^v => row} ->
          dual_v = Map.fetch!(duals, v)

          Enum.reduce(outer_with_duals, acc, fn {ov, dual_ov}, {best, best_v} ->
            case row do
              %{^ov => w} ->
                r = dual_v + dual_ov - w
                if best == nil or r < best, do: {r, v}, else: {best, best_v}

              _ ->
                {best, best_v}
            end
          end)

        _ ->
          acc
      end
    end)
  end

  defp min_outer_edge(state, v) do
    outer_vertices(state)
    |> Enum.reduce({nil, nil}, fn ov, {best, best_ov} ->
      case resistance(state, v, ov) do
        nil -> {best, best_ov}
        r when best == nil or r < best -> {r, ov}
        _ -> {best, best_ov}
      end
    end)
    |> elem(1)
  end

  defp outer_vertices(state) do
    top_blossoms(state)
    |> Enum.filter(&(Map.get(state.label, &1) == :outer))
    |> Enum.flat_map(&blossom_vertices(state, &1))
  end

  defp blossom_vertices(state, b) do
    if Map.has_key?(state.children, b) do
      state.children |> Map.fetch!(b) |> Enum.flat_map(&blossom_vertices(state, &1))
    else
      [b]
    end
  end

  # Two things here are about cost, not meaning, and the answer is
  # identical either way.
  #
  # `blossom_vertices/2` is a recursive walk of a blossom's children. A
  # comprehension re-evaluates its generators for every combination of the
  # ones before them, so writing `v0 <- blossom_vertices(state, b0)` inside
  # the `b1` loop ran that walk once per PAIR of blossoms rather than once
  # per blossom — O(B^2) tree walks per call. Hoisted into a map.
  #
  # And the pair list was materialised in full before being reduced, which
  # allocates O(V^2) tuples on every delta step. Folding directly keeps the
  # same traversal without building it.
  #
  # This is the hot path: `min_outer_outer/1` runs once per grow step and
  # a grow step runs O(V) times per augmentation. Pairing 209 players went
  # from 90s to the figure quoted in `docs/validation.md`.
  defp min_outer_outer(state) do
    outer_blossoms = top_blossoms(state) |> Enum.filter(&(Map.get(state.label, &1) == :outer))
    vertices = Map.new(outer_blossoms, &{&1, blossom_vertices(state, &1)})

    duals = state.dual

    # Both sides of the comparison, prepared once per blossom. The
    # generator nesting below is b0, then b1, then their vertices — so
    # anything fetched inside it was being rebuilt once per PAIR of
    # blossoms. `right` in particular was a fresh list of |b1| tuples for
    # every b0 that preceded it, and each v0's adjacency row and dual were
    # re-read for every b1.
    #
    # The iteration order is deliberately identical. Both scans take the
    # FIRST strict minimum, so visiting the same pairs in a different
    # sequence would resolve ties to a different edge and change which
    # pairing comes out — which is why this hoists rather than restructures.
    prepared =
      Map.new(outer_blossoms, fn b ->
        {b,
         Enum.map(Map.fetch!(vertices, b), fn v ->
           {v, Map.get(state.weight, v), Map.fetch!(duals, v)}
         end)}
      end)

    for b0 <- outer_blossoms, reduce: {nil, nil} do
      acc ->
        left = Map.fetch!(prepared, b0)

        for b1 <- outer_blossoms, b0 < b1, reduce: acc do
          acc1 ->
            right = Map.fetch!(prepared, b1)

            for {v0, row, dual_v0} <- left, row != nil, reduce: acc1 do
              acc2 ->
                Enum.reduce(right, acc2, fn {v1, _row1, dual_v1}, {best, best_pair} ->
                  case row do
                    %{^v1 => w} ->
                      r = dual_v0 + dual_v1 - w
                      if best == nil or r < best, do: {r, {v0, v1}}, else: {best, best_pair}

                    _ ->
                      {best, best_pair}
                  end
                end)
            end
        end
    end
  end

  defp min_inner_blossom_dual(state) do
    top_blossoms(state)
    |> Enum.filter(&(Map.get(state.label, &1) == :inner and Map.has_key?(state.children, &1)))
    |> Enum.map(&{Map.fetch!(state.dual, &1), &1})
    |> case do
      [] -> {nil, nil}
      pairs -> Enum.min_by(pairs, &elem(&1, 0))
    end
  end

  # ------------------------------------------------------ dual updates

  defp apply_delta(state, 0), do: state

  defp apply_delta(state, delta) do
    Enum.reduce(top_blossoms(state), state, fn b, state ->
      case Map.get(state.label, b) do
        :outer -> update_blossom_duals(state, b, -delta)
        :inner -> update_blossom_duals(state, b, delta)
        _ -> state
      end
    end)
  end

  defp update_blossom_duals(state, b, delta) do
    vs = blossom_vertices(state, b)
    dual = Enum.reduce(vs, state.dual, fn v, d -> Map.update!(d, v, &(&1 + delta)) end)

    dual =
      if Map.has_key?(state.children, b) do
        Map.update!(dual, b, &(&1 - 2 * delta))
      else
        dual
      end

    %{state | dual: dual}
  end

  # ------------------------------------------------------- augmentation

  # Direct translation of bbpPairings' `augmentToSource`.
  #
  # An earlier version of this tried to resolve vertex-level `mate`
  # INLINE as it walked — treating each visited blossom as needing
  # resolution "from an entry vertex to a specific exit vertex". That
  # turned out to be the wrong problem entirely, found by hand-tracing
  # the bare-triangle case against a brute-force oracle: for the
  # entry-equals-exit case (a blossom visited via its own dual variable
  # hitting zero, not via a further match), that design just returned
  # immediately WITHOUT EVER PAIRING UP THE BLOSSOM'S OTHER CHILDREN —
  # not a recursion bug, a real correctness gap.
  #
  # Re-reading `augmentToSource` itself settled it: bbpPairings does not
  # resolve entry-to-exit at all. It CASCADES a base reassignment through
  # every blossom the walk touches (`rootBlossom->baseVertex = vertex`,
  # repeated for the next blossom up via `originalMatch.baseVertex =
  # originalMatch.labeledVertex`) and defers ALL internal vertex pairing
  # to one separate pass (`putVerticesInMatchingOrder`), run once after
  # the WHOLE algorithm terminates — see `resolve_all_matching/1`. Only
  # ONE special point (the base) ever needs handling per blossom, which
  # is both simpler and the actual textbook blossom lemma: given any one
  # base, the remaining even number of vertices pairs up consecutively
  # around the cycle. No "exit" concept exists in the correct model.
  defp augment_to_source(state, v, new_match) do
    b = Map.fetch!(state.in_blossom, v)
    # The asymmetric, per-blossom field — see `state.blossom_match`'s doc
    # on why this must NOT be the same symmetric map `mate` is.
    old_partner = Map.get(state.blossom_match, b)

    state = %{
      state
      | base: Map.put(state.base, b, v),
        blossom_match: put_or_delete(state.blossom_match, b, new_match)
    }

    case old_partner do
      nil ->
        state

      partner ->
        parent_blossom = Map.fetch!(state.in_blossom, partner)
        {labeling_v, labeled_v} = Map.fetch!(state.label_edge, parent_blossom)

        state = %{
          state
          | base: Map.put(state.base, parent_blossom, labeled_v),
            blossom_match: put_or_delete(state.blossom_match, parent_blossom, labeling_v)
        }

        augment_to_source(state, labeling_v, labeled_v)
    end
  end

  defp set_mate(mate, a, nil), do: Map.delete(mate, a)
  defp set_mate(mate, a, b), do: mate |> Map.put(a, b) |> Map.put(b, a)

  # `matched?/2` uses `Map.has_key?`, so an "unmatch" must DELETE the key
  # rather than set it to nil — leaving a `b => nil` entry behind would
  # make an exposed blossom look matched.
  defp put_or_delete(map, k, nil), do: Map.delete(map, k)
  defp put_or_delete(map, k, v), do: Map.put(map, k, v)

  # Resolves the alternating matching WITHIN the (possibly nested)
  # blossom containing `entry`, from `entry` to `exit_v` — both vertices
  # of the SAME top-level blossom.
  #
  # Looks up `b` via `in_blossom[entry]`, which is why this must ONLY
  # ever be called with entry/exit_v that are genuinely within the
  # TOP-level blossom — never as a way to "descend into a specific
  # child", since `in_blossom` always resolves back to the SAME top-level
  # id regardless of nesting depth. `resolve_nontrivial/4` and
  # `pair_remaining/5` both already know exactly which CHILD they need to
  # descend into at each step, and must call `resolve_within/4` (below)
  # directly with that child rather than this function — calling this
  # one instead, as an earlier version did in the `exit_idx == 0` case,
  # re-derives the SAME top-level blossom via `in_blossom` and recurses
  # into itself forever. Found by tracing the bare-triangle case, which
  # hung silently with no crash and no further trace output right after
  # blossom formation succeeded.
  # Run once, after `augment_until_done/1` has finished cascading every
  # blossom's base to its final value — the direct analogue of
  # bbpPairings' separate `putVerticesInMatchingOrder` pass
  # (`Computer::computeMatching()` runs it once per root blossom only
  # after `graph->computeMatching()` itself has fully converged).
  #
  # Two independent things to set, per top-level blossom: the EXTERNAL
  # pair (this blossom's base, matched to `blossom_match`, an asymmetric
  # field — see that field's own doc) and the INTERNAL pairing (every
  # other vertex in the blossom, paired up two at a time relative to
  # that SAME base — the textbook one-special-point blossom lemma: given
  # any one base, the remaining even number of vertices pairs up
  # consecutively around the odd cycle).
  defp resolve_all_matching(state) do
    Enum.reduce(top_blossoms(state), state, fn b, state ->
      state =
        case Map.get(state.blossom_match, b) do
          nil -> state
          partner -> %{state | mate: set_mate(state.mate, base_vertex(state, b), partner)}
        end

      resolve_blossom_internal(state, b)
    end)
  end

  defp resolve_blossom_internal(state, b) do
    if Map.has_key?(state.children, b) do
      resolve_blossom_internal_nontrivial(state, b)
    else
      state
    end
  end

  defp resolve_blossom_internal_nontrivial(state, b) do
    children = Map.fetch!(state.children, b)
    base_v = base_vertex(state, b)
    base_child = Enum.find(children, &(base_v in blossom_vertices(state, &1)))
    base_idx = Enum.find_index(children, &(&1 == base_child))
    rotated = Enum.drop(children, base_idx) ++ Enum.take(children, base_idx)
    n = length(rotated)

    # The base child's OWN base is `base_v` itself (possibly deep inside
    # it, if base_child is non-trivial) — set explicitly before
    # recursing, since `base_v` may not already equal whatever
    # `base_child`'s own base field happens to hold.
    state = %{state | base: Map.put(state.base, base_child, base_v)}
    state = resolve_blossom_internal(state, base_child)

    pair_children(state, rotated, 1, n)
  end

  # Children at rotated positions 1, 2, ..., n-1 (base_child is position
  # 0 and already handled) pair up two at a time: (1,2), (3,4), and so
  # on — always an even count, since `n` (the blossom's own child count)
  # is always odd.
  defp pair_children(state, _rotated, i, n) when i >= n, do: state

  defp pair_children(state, rotated, i, n) do
    child_a = Enum.at(rotated, i)
    child_b = Enum.at(rotated, i + 1)
    {out_a, in_b} = connector(state, child_a, child_b)

    state = %{state | base: Map.put(state.base, child_a, out_a)}
    state = resolve_blossom_internal(state, child_a)
    state = %{state | base: Map.put(state.base, child_b, in_b)}
    state = resolve_blossom_internal(state, child_b)
    state = %{state | mate: set_mate(state.mate, out_a, in_b)}

    pair_children(state, rotated, i + 2, n)
  end

  # The connector vertex pair for a cyclically-adjacent pair of children
  # `{from, to}` (a vertex in `from`, a vertex in `to`, joined by a real
  # graph edge) — recorded once, at whichever blossom formation first
  # made them adjacent, and read many times across however many further
  # augmentations touch that blossom before it next expands.
  defp connector(state, from, to), do: Map.fetch!(state.connectors, {from, to})

  # ----------------------------------------------------- blossom lifecycle

  # Contract the odd cycle closed by the tight edge (v0, v1) — both
  # OUTER, both in the same tree — into one new blossom, labelled OUTER.
  #
  # Building `cycle` needed a second pass beyond `blossom_path_to_root`
  # once `augment_to_source` needed real connector VERTICES, not just the
  # blossom-id chain: `path_to_target/4` walks the same chain but returns
  # the actual vertex sequence, from which consecutive pairs ARE the
  # connectors — each blossom but the last contributes an (entry, exit)
  # pair, and the vertex the walk continues on is exactly the next
  # blossom's own entry, by construction of the walk itself.
  defp form_blossom(state, v0, v1) do
    b0 = Map.fetch!(state.in_blossom, v0)
    b1 = Map.fetch!(state.in_blossom, v1)
    ids0 = blossom_ids_to_root(state, b0)
    ids1 = blossom_ids_to_root(state, b1)
    common = find_common_ancestor(ids0, ids1)

    ids0_before = Enum.take_while(ids0, &(&1 != common))
    ids1_before = Enum.take_while(ids1, &(&1 != common))

    flat0 = path_to_target(state, b0, v0, common)
    flat1 = path_to_target(state, b1, v1, common)

    cycle = ids0_before ++ [common] ++ Enum.reverse(ids1_before)

    # `add_connectors/2` needs each id list in the SAME direction its own
    # `flat` was actually walked — `path_to_target/4` always walks UP
    # (b -> ... -> common), so that direction is `ids0_before ++
    # [common]` and `ids1_before ++ [common]`, never reversed. An earlier
    # version reversed BOTH the id list and (separately) the flat vertex
    # list here, meaning to "flip" the walk direction for the b1 side to
    # match `cycle`'s own down-oriented listing — but a connector is the
    # same edge regardless of which direction it's conceptually walked,
    # so reversing it at all was never correct, and doing it to both
    # lists independently misaligned them against each other. Found by
    # hand-tracing a bare triangle: the reversed pairing produced a
    # connector `{0,1} => {2,2}`, claiming vertex 2 belongs to blossom 0
    # and blossom 1, when neither actually contains it.
    connectors =
      state.connectors
      |> add_connectors(ids0_before ++ [common], flat0)
      |> add_connectors(ids1_before ++ [common], flat1)
      # The fresh tight edge itself closes the cycle from the last child
      # (b1) back to the first (b0).
      |> Map.put({List.last(cycle), List.first(cycle)}, {v1, v0})
      |> Map.put({List.first(cycle), List.last(cycle)}, {v0, v1})

    new_id = state.next_blossom_id
    children_map = Map.put(state.children, new_id, cycle)
    parent_of = Enum.reduce(cycle, state.parent_of, &Map.put(&2, &1, new_id))

    in_blossom =
      Enum.reduce(cycle, state.in_blossom, fn c, acc ->
        Enum.reduce(blossom_vertices(state, c), acc, &Map.put(&2, &1, new_id))
      end)

    base = Map.put(state.base, new_id, base_vertex(state, common))

    # The new blossom's own external connection is whatever `common` had
    # — contracting around it doesn't change what it was matched to.
    blossom_match =
      put_or_delete(state.blossom_match, new_id, Map.get(state.blossom_match, common))

    %{
      state
      | children: children_map,
        parent_of: parent_of,
        in_blossom: in_blossom,
        base: base,
        blossom_match: blossom_match,
        connectors: connectors,
        dual: Map.put(state.dual, new_id, 0),
        label: Map.put(state.label, new_id, :outer),
        next_blossom_id: new_id + 1
    }
  end

  # Records the connector between every CONSECUTIVE pair of blossoms in
  # `ids` (both directions), reading the vertex pairs straight off
  # `flat`, which `path_to_target/4` built alongside the same walk.
  defp add_connectors(connectors, ids, flat) do
    ids
    |> Enum.with_index()
    |> Enum.reduce(connectors, fn {id, i}, acc ->
      if i + 1 < length(ids) do
        next_id = Enum.at(ids, i + 1)
        out_v = Enum.at(flat, 2 * i + 1)
        in_v = Enum.at(flat, 2 * i + 2)

        acc
        |> Map.put({id, next_id}, {out_v, in_v})
        |> Map.put({next_id, id}, {in_v, out_v})
      else
        acc
      end
    end)
  end

  # Flat vertex-level walk from `entry_vertex` (in blossom `b`) up to and
  # INCLUDING the entry into `target` — the same chain
  # `blossom_path_to_root/2` walks at blossom-id granularity, but
  # returning the actual connecting VERTICES (two per blossom passed
  # through: how the walk entered it, and how it leaves), which is what
  # `add_connectors/2` and `resolve_internal/3` both need and
  # `blossom_path_to_root/2` alone cannot provide.
  defp path_to_target(_state, target, entry_vertex, target), do: [entry_vertex]

  defp path_to_target(state, b, entry_vertex, target) do
    case Map.get(state.label, b) do
      :outer ->
        base = base_vertex(state, b)
        mate_v = Map.fetch!(state.blossom_match, b)
        next_blossom = Map.fetch!(state.in_blossom, mate_v)
        [entry_vertex, base] ++ path_to_target(state, next_blossom, mate_v, target)

      :inner ->
        {labeling_v, labeled_v} = Map.fetch!(state.label_edge, b)
        next_blossom = Map.fetch!(state.in_blossom, labeling_v)
        [entry_vertex, labeled_v] ++ path_to_target(state, next_blossom, labeling_v, target)
    end
  end

  # Full path from `b` up to (and including) its tree root, WITHOUT
  # skipping any blossom along the way — unlike an earlier version of
  # this function, which jumped straight from an OUTER blossom to the
  # next one up without recording the INNER blossom it passed through to
  # get there.
  #
  # That skip was invisible to `tree_root/2` (skipping intermediate
  # blossoms never changes where a walk eventually TERMINATES, so which
  # root two searches share is unaffected). It was NOT invisible to
  # `form_blossom/3`, which uses this same chain to build the new
  # blossom's actual cycle: a bare triangle graph (`n=3`, all three
  # edges present) produced a two-child cycle `[0, 2]`, silently missing
  # blossom 1 — a blossom the whole method's correctness DEPENDS on
  # having an odd number of children in, and `blossom_vertices/2`
  # recursing over that broken structure never terminated. Found by
  # tracing that exact minimal case after the triangle hung with no
  # output at all.
  defp blossom_ids_to_root(state, b) do
    case Map.get(state.label, b) do
      :outer ->
        case Map.get(state.blossom_match, b) do
          nil ->
            [b]

          partner ->
            next_blossom = Map.fetch!(state.in_blossom, partner)
            [b | blossom_ids_to_root(state, next_blossom)]
        end

      :inner ->
        {labeling_v, _} = Map.fetch!(state.label_edge, b)
        [b | blossom_ids_to_root(state, Map.fetch!(state.in_blossom, labeling_v))]
    end
  end

  defp find_common_ancestor(path0, path1) do
    set1 = MapSet.new(path1)
    Enum.find(path0, &MapSet.member?(set1, &1))
  end

  # Dissolve blossom `b` (its dual variable just hit zero) back into its
  # children — direct translation of `graph.cpp`'s `!minInnerDualVariable`
  # branch (the `rootBlossomPool.construct` calls around line 680).
  #
  # Every child but the base one (`rootChild`) sits on the cycle between
  # `base_child` (holds b's own current base vertex, still matched
  # EXTERNALLY exactly as b was) and `connect_child` (holds b's entry
  # vertex `labeled_v`, still entered EXTERNALLY exactly as b was, via
  # b's own original `label_edge`). Walking the cycle from `base_child`
  # one way reaches `connect_child`; that arc becomes the live tree chain
  # (children alternate OUTER/INNER, each adjacent pair matched to each
  # other via their recorded `connector`, continuing the SAME alternation
  # that made b a valid blossom in the first place); the *other* arc is
  # simply not part of the tree and its children pair off the same way
  # but are labelled FREE. `base_child` and `connect_child` are always
  # labelled INNER (an odd cycle has an odd-length chain between them),
  # confirmed against the C++'s explicit `&rootChild == currentChild`
  # override.
  #
  # `connect_forward` (whether walking forward from `base_child` reaches
  # `connect_child` in an even or odd number of hops) is what the C++
  # computes by toggling a bool once per hop starting `true` — i.e. even
  # hop count keeps it `true` — and is what decides BOTH which arc is
  # "the tree chain" and, per INNER child, which of its two neighbours is
  # its tree-parent (`label_edge`) versus its match partner (`base`,
  # via `linksToNext`, which toggles every position regardless of arc).
  #
  # An earlier version of this function always walked forward only, never
  # set `blossom_match` for any newly-exposed child, and always treated
  # the base child as OUTER — none of which match the source. Rewritten
  # from a line-by-line reading of the actual construct-call ternaries
  # after two crashes downstream (a missing vertex in the final matching,
  # a `nil` leaking into a connector lookup) traced back to this gap.
  defp expand_blossom(state, b) do
    children = Map.fetch!(state.children, b)
    {labeling_v, labeled_v} = Map.fetch!(state.label_edge, b)
    root_vertex = base_vertex(state, b)
    root_match = Map.get(state.blossom_match, b)

    base_child = Enum.find(children, &(root_vertex in blossom_vertices(state, &1)))
    connect_child = Enum.find(children, &(labeled_v in blossom_vertices(state, &1)))

    base_idx = Enum.find_index(children, &(&1 == base_child))
    rotated = Enum.drop(children, base_idx) ++ Enum.take(children, base_idx)
    n = length(rotated)
    connect_idx = Enum.find_index(rotated, &(&1 == connect_child))
    connect_forward = rem(connect_idx, 2) == 0

    state =
      rotated
      |> Enum.with_index()
      |> Enum.reduce(state, fn {child, i}, state ->
        links_to_next = rem(i, 2) == 1
        next_child = Enum.at(rotated, rem(i + 1, n))
        prev_child = Enum.at(rotated, rem(i - 1 + n, n))
        neighbor = if links_to_next, do: next_child, else: prev_child

        free? =
          if connect_forward do
            i > connect_idx
          else
            i > 0 and i < connect_idx
          end

        label =
          cond do
            free? -> :free
            i == 0 -> :inner
            links_to_next != connect_forward -> :inner
            true -> :outer
          end

        {base_v, base_match_v} =
          if i == 0 do
            {root_vertex, root_match}
          else
            connector(state, child, neighbor)
          end

        label_edge =
          cond do
            child == connect_child ->
              {labeling_v, labeled_v}

            label == :inner ->
              le_neighbor = if connect_forward, do: next_child, else: prev_child
              connector(state, le_neighbor, child)

            true ->
              nil
          end

        in_blossom =
          Enum.reduce(blossom_vertices(state, child), state.in_blossom, &Map.put(&2, &1, child))

        state = %{
          state
          | in_blossom: in_blossom,
            base: Map.put(state.base, child, base_v),
            blossom_match: put_or_delete(state.blossom_match, child, base_match_v),
            label: Map.put(state.label, child, label)
        }

        if label_edge do
          %{state | label_edge: Map.put(state.label_edge, child, label_edge)}
        else
          state
        end
      end)

    %{
      state
      | children: Map.delete(state.children, b),
        parent_of: Map.new(state.parent_of |> Enum.reject(fn {_c, p} -> p == b end)),
        label: Map.delete(state.label, b),
        label_edge: Map.delete(state.label_edge, b),
        dual: Map.delete(state.dual, b)
    }
  end
end
