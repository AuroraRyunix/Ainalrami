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

  ## Finding the minimum without rescanning

  Every "find the minimum X" step in `graph.cpp` was originally reproduced
  here as a plain `Enum` walk over the whole state — a much smaller and
  more directly verifiable translation, at the cost of the asymptotics
  bbpPairings buys with its `minOuterEdges` tables and per-blossom
  `minOuterEdgeResistance`.

  That was defensible while `Ainalrami.Pairing`'s brackets were small
  (median 9, p90 19 for a combined current+next bracket) and stopped being
  so once the engine was pointed at a 209-player field, where the whole
  round is handed to this module 124 times: one round took ninety seconds.

  The two dominant scans are now maintained incrementally instead — see
  the "delta-scan caches" section below for what is stored and, more
  importantly, for the property that makes maintaining it sound. The
  remaining walks are over one blossom or one label class rather than over
  every vertex pair.

  **This changes which minimum is found when several tie, and 86% of delta
  steps have a tied minimum.** That is safe here, and was measured before
  the caches were written rather than assumed: inverting the tie-break of
  the old scans left the engine agreeing with bbpPairings on 1358/1358
  rounds. The matching this module returns is determined by the weights,
  not by the order the search happens to visit equal-slack edges in.

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
    |> new(edges)
    |> solve()
    |> elem(1)
  end

  @doc """
  A persistent matcher over vertices `0..n-1`, for callers that solve the
  same graph repeatedly with small changes between solves.

  `Ainalrami.Pairing`'s bracket cascade solves the whole field about a
  hundred and twenty times per round, and between consecutive solves the
  median change is about two hundred edges out of five thousand -- under
  four percent -- and sometimes none at all. Solving each from an empty
  matching ran roughly a hundred stages every time; re-augmenting from the
  previous solution runs a handful.

  This is exactly what bbpPairings' `Computer` does, and the algorithm is
  its `setEdgeWeight` / `prepareVertexForWeightAdjustments`: when an
  edge's weight changes, the two endpoints are unmatched, every blossom
  containing them is dissolved back to trivial, and their duals are reset
  to the initial maximum. Every other vertex keeps its match, its dual and
  its blossom structure. That state is still a valid starting point for
  the primal-dual search -- the invariants the algorithm maintains (dual
  feasibility, complementary slackness on matched edges) hold on the
  untouched part, and the touched vertices are exactly as they were at
  the start of a fresh solve -- so `solve/1` reaches the same optimum.

      state = WeightedMatching.new(n, edges)
      {state, matching} = WeightedMatching.solve(state)
      state = WeightedMatching.set_weight(state, u, v, new_w)
      {state, matching} = WeightedMatching.solve(state)

  `solve/2` is `new/2` followed by one `solve/1`, and remains the API for
  one-shot callers and for the tests.

  Options: `:max_weight` (the ceiling every later weight must stay under,
  on the caller's scale), `:gcd` (override the weight reduction), and
  `:duals` -- a map of initial dual values, one per vertex, on TWICE the
  weight scale: `duals[u] + duals[v] >= 2 * w(u, v)` must hold on every
  edge, and the edges where it holds with equality are the ones the
  greedy start may match. A caller whose weights are a sum of per-vertex
  terms can make every edge tight this way and hand the search an almost
  complete matching; see `greedy_start/3`.
  """
  def new(n, edges, opts \\ []) do
    # `:gcd` overrides the reduction. A persistent caller whose LATER
    # weights may not share the initial edges' common factor passes
    # `gcd: 1` and forgoes the bignum saving rather than risk
    # `set_weight/4` refusing a weight that is not on the initial scale.
    # `:duals` -- see `greedy_start/3` -- are on the doubled scale the
    # matcher compares against, so they are not reduced; a caller giving
    # them gets no reduction either.
    gcd =
      case {Keyword.get(opts, :gcd), Keyword.get(opts, :duals)} do
        {nil, nil} -> gcd_of(edges)
        {nil, _} -> 1
        {g, _} when is_integer(g) and g >= 1 -> g
      end

    edges = if gcd > 1, do: reduce_weights(edges), else: edges

    # The initial dual, and the ceiling every later weight must stay under
    # -- bbpPairings fixes `aboveMaxEdgeWeight` at construction and asserts
    # on `setEdgeWeight`. Defaults to the largest weight present, which is
    # right for a one-shot solve; a caller that will raise weights later
    # passes `:max_weight` explicitly, on the caller's own scale.
    ceiling =
      case Keyword.get(opts, :max_weight) do
        nil -> nil
        w -> 2 * div(w, gcd)
      end

    state = build_state(n, edges, ceiling, Keyword.get(opts, :duals))
    Map.put(state, :gcd, gcd)
  end

  @doc """
  Re-augment from the current matching to a maximum-weight one. Returns
  `{state, matching}`; the state carries the solution forward.
  """
  def solve(state) do
    # Caches are carried stage to stage WITHIN a solve (`carry_caches/2`)
    # and never across one: a `set_weight/4` in between changed weights the
    # cached resistances were computed from. Cleared here so the first stage
    # rebuilds; an empty label map is the signal `carry_caches/2` reads.
    state = %{state | label: %{}}

    state =
      state
      |> greedy_resume()
      |> even_up_exposed_duals()
      |> augment_until_done()
      |> resolve_all_matching()

    {state, to_matching(state)}
  end

  # The resumed-solve counterpart of `greedy_start/3`: every vertex that
  # `prepare_vertex/2` reset -- exposed, its own top-level blossom, its
  # dual back at the ceiling -- gets the lowest dual that keeps every edge
  # at it feasible against its neighbours' CURRENT duals, `max(2w - y_u)`,
  # and is then matched to its lowest-indexed exposed neighbour on a tight
  # edge if it has one. That is exactly what the first stage would do for
  # it when its tightest neighbour is exposed -- bring the dual down, find
  # the tight outer-outer edge, augment -- minus the stage: its label reset,
  # cache rebuild and tree growth across the field. At a bracket boundary
  # every resident is prepared and their heaviest edges are to each other,
  # so most of them pair here.
  defp greedy_resume(state) do
    max_w = state.max_w

    fresh =
      for v <- 0..(state.n - 1)//1,
          Map.fetch!(state.in_blossom, v) == v,
          not Map.has_key?(state.blossom_match, v),
          Map.fetch!(state.dual, v) == max_w,
          do: v

    case fresh do
      [] ->
        state

      _ ->
        {dual, bm} =
          Enum.reduce(fresh, {state.dual, state.blossom_match}, fn v, {dual, bm} ->
            row = Map.get(state.weight, v, %{})

            yv =
              Enum.reduce(row, 0, fn {u, w2}, acc ->
                need = w2 - Map.fetch!(dual, u)
                if need > acc, do: need, else: acc
              end)

            dual = Map.put(dual, v, yv)

            if Map.has_key?(bm, v) do
              {dual, bm}
            else
              partner =
                Enum.reduce(row, nil, fn {u, w2}, best ->
                  if yv + Map.fetch!(dual, u) == w2 and
                       Map.fetch!(state.in_blossom, u) == u and
                       not Map.has_key?(bm, u) and (best == nil or u < best),
                     do: u,
                     else: best
                end)

              case partner do
                nil -> {dual, bm}
                u -> {dual, bm |> Map.put(v, u) |> Map.put(u, v)}
              end
            end
          end)

        %{state | dual: dual, blossom_match: bm}
    end
  end

  # bbpPairings' `computeMatching()` prologue (graph.cpp:793-845): "Make
  # sure all exposed Vertex dualVariables have the same parity."
  #
  # Within a stage the dual adjustment can be half a unit of the doubled
  # scale, so a MATCHED vertex can finish a solve with an odd dual -- which
  # is fine while it stays matched, because the sum along its matched edge
  # stays even. `prepare_vertex/2` unmatches that vertex's partner without
  # touching the partner's dual, and an EXPOSED vertex with an odd dual
  # breaks the arithmetic: the four-way minimum halves the outer-outer and
  # inner-blossom candidates, every tightness event is missed by one, and
  # `grow_with_delta/6` falls through to its "numerically shouldn't happen"
  # branch and stops early. Measured: three odd duals at entry, and a
  # twelve-vertex solve that stopped after one augmentation with ten
  # exposed vertices left.
  #
  # The fix is theirs exactly: every exposed top-level blossom whose base
  # dual is odd gets +1 on each of its vertices, and -2 on its own blossom
  # dual if it is non-trivial, so every edge's dual sum is unchanged. On a
  # fresh solve every dual is `max_w`, which is even, so this is a no-op
  # there and `solve/2` is unaffected.
  defp even_up_exposed_duals(state) do
    # Before the first stage the label map is empty and `top_blossoms/1`
    # would see nothing; on a fresh state every dual is `max_w`, even, so
    # falling back to `in_blossom` here costs one walk and changes nothing.
    top =
      if map_size(state.label) == 0,
        do: state.in_blossom |> Map.values() |> Enum.uniq(),
        else: top_blossoms(state)

    Enum.reduce(top, state, fn b, state ->
      if not matched?(state, b) and rem(dual_of(state, base_vertex(state, b)), 2) == 1 do
        vs = blossom_vertices(state, b)
        dual = Enum.reduce(vs, state.dual, fn v, d -> Map.update!(d, v, &(&1 + 1)) end)

        dual =
          if Map.has_key?(state.children, b),
            do: Map.update!(dual, b, &(&1 - 2)),
            else: dual

        %{state | dual: dual}
      else
        state
      end
    end)
  end

  @doc """
  The vertex `v` is matched to, or `nil` when it is exposed. Valid after a
  `solve/1`.
  """
  def mate_of(state, v), do: Map.get(state.mate, v)

  @doc """
  The weight of the edge `{u, v}` as the caller gave it (to `new/3` or
  `set_weight/4`), or 0 when there is no edge.
  """
  def edge_weight(state, u, v) do
    case state.weight do
      %{^u => %{^v => w2}} -> div(w2 * state.gcd, 2)
      _ -> 0
    end
  end

  @doc """
  Every edge at `u` with a positive weight, as `{neighbour, weight}` pairs on
  the caller's scale.
  """
  def neighbours(state, u) do
    state.weight
    |> Map.get(u, %{})
    |> Enum.map(fn {v, w2} -> {v, div(w2 * state.gcd, 2)} end)
  end

  @doc """
  Change the weight of the edge between `u` and `v`. Zero or negative
  removes it. The next `solve/1` re-augments from the previous solution.

  **Only `u` is prepared** -- unmatched, its blossoms dissolved, its dual
  reset. `v` is left exactly as it was, match and all. This asymmetry is
  bbpPairings' `setEdgeWeight(modifiedVertex, neighbor, w)` and it is
  what makes the whole thing fast: `finalizePair` writes every edge of two
  vertices, `2m` calls, and with only the modified end prepared those `2m`
  calls disturb exactly two vertices. Preparing both ends -- as this did at
  first, from reading the two arguments as symmetric -- unmatched every
  vertex in the graph on every finalisation, and the "resumed" solve ran
  ~m/2 stages, the same as a cold one. Measured: 104 stages against 11.

  Why one side is enough: the invariants are per edge. Dual feasibility on
  `(u, v)` holds for any weight under the ceiling once `u`'s dual is back
  at the maximum. Complementary slackness on `v`'s matched edge `(v, x)`
  is untouched, since that edge's weight did not change. The one case
  where `v`'s state DID depend on `(u, v)` is `v` matched to `u`, and
  preparing `u` unmatches that pair from `u`'s side, leaving `v` exposed
  -- which is exactly the state a fresh solve would put it in.

  The weight is reduced by the same GCD `new/3` found, so it lands on the
  same scale as the edges already stored; a weight that is not a multiple
  of that GCD, or that would exceed the initial dual, raises -- both mean
  the caller's weights have changed shape and a fresh `new/3` is needed.
  """
  def set_weight(state, u, v, w) when u != v do
    w2 =
      cond do
        w <= 0 ->
          0

        rem(w, state.gcd) != 0 ->
          raise ArgumentError,
                "set_weight: #{w} is not on the scale this matcher was built at " <>
                  "(gcd #{state.gcd}); build a fresh state"

        true ->
          2 * div(w, state.gcd)
      end

    if w2 > state.max_w do
      raise ArgumentError,
            "set_weight: weight exceeds the initial dual this matcher was built with; " <>
              "build a fresh state"
    end

    state
    |> prepare_vertex(u)
    |> put_weight(u, v, w2)
  end

  # `prepareVertexForWeightAdjustments`, exactly: unmatch, dissolve every
  # enclosing blossom, reset the dual to the initial maximum. Idempotent,
  # so touching both endpoints of several edges in a row costs nothing
  # extra for a vertex already prepared.
  defp prepare_vertex(state, v) do
    state = dissolve_to_vertex(state, v)

    # `v` is now its own top-level blossom. Unmatch it, both directions.
    state =
      case Map.get(state.blossom_match, v) do
        nil ->
          state

        partner ->
          partner_blossom = Map.fetch!(state.in_blossom, partner)

          %{
            state
            | blossom_match: state.blossom_match |> Map.delete(v) |> Map.delete(partner_blossom)
          }
      end

    %{state | dual: Map.put(state.dual, v, state.max_w)}
  end

  # Dissolve the top-level blossom containing `v`, and keep dissolving
  # until `v` IS the top-level blossom. Each dissolution pushes the parent
  # blossom's dual (halved) down into its vertices -- `freeAncestorOfBase`'s
  # `dualVariableAdjustment` -- so the sum of duals over any edge is
  # unchanged and dual feasibility survives.
  defp dissolve_to_vertex(state, v) do
    case Map.fetch!(state.in_blossom, v) do
      ^v -> state
      b -> state |> dissolve_one(b, v) |> dissolve_to_vertex(v)
    end
  end

  # One level: `b` becomes its children, paired off around its base along
  # the odd cycle exactly as `pair_children/4` pairs them for the final
  # answer -- but at the BLOSSOM level (`blossom_match`), and permanently.
  # No labels are involved: this runs between stages, when there is no
  # tree.
  # `v` is the vertex being prepared, and the blossom is REBASED at it
  # before it is taken apart. This is `prepareVertexForWeightAdjustments`'
  # `baseVertex = &vertex` and it is not optional.
  #
  # In this port a blossom's dual is a separate quantity from its vertices'
  # duals: it records how far the vertex duals have been driven BELOW what
  # the blossom's INTERNAL edges need, so those read as `-z_B` slack while
  # every edge CROSSING the boundary is exactly tight on vertex duals
  # alone. Dissolving adds `z_B / 2` to every vertex, which makes the
  # internal edges tight and pushes every crossing edge OUT of tightness
  # by that same amount. That is fine for the crossing edges that are
  # unmatched -- slack is allowed -- and fatal for the ONE crossing edge
  # that is matched: the base's external match, which the algorithm treats
  # as tight and never revisits.
  #
  # Rebasing at `v` moves that external match onto `v`'s own child --
  # which `prepare_vertex/2` is about to unmatch anyway -- so no matched
  # crossing edge survives the dissolution. Every sibling pair that comes
  # out matched sits on an INTERNAL edge, which the adjustment has just
  # made tight. Complementary slackness holds on every matched edge, and
  # `even_up_exposed_duals/1` then handles the parity of whatever was left
  # exposed.
  #
  # Rebasing is a one-field write here, exactly as in `augment_to_source/3`:
  # the internal alternating structure is resolved lazily from the base by
  # `resolve_all_matching/1`, never stored.
  #
  # Found by checking the invariants directly rather than by reading the
  # reference: with the OLD base kept, two matched crossing edges came out
  # with dual sums 85 against a weight of 82 and 51 against 32, and the
  # search stalled with ten exposed vertices left.
  defp dissolve_one(state, b, v) do
    state = %{state | base: Map.put(state.base, b, v)}
    children = Map.fetch!(state.children, b)
    base_v = v
    partner = Map.get(state.blossom_match, b)
    half_dual = div(Map.fetch!(state.dual, b), 2)

    base_child = Enum.find(children, &(base_v in blossom_vertices(state, &1)))
    base_idx = Enum.find_index(children, &(&1 == base_child))
    rotated = Enum.drop(children, base_idx) ++ Enum.take(children, base_idx)

    # Every vertex of `b` absorbs the blossom's dual. `blossom_vertices/2`
    # is read BEFORE the structure changes.
    all_vertices = blossom_vertices(state, b)

    dual =
      Enum.reduce(all_vertices, state.dual, fn x, d -> Map.update!(d, x, &(&1 + half_dual)) end)
      |> Map.delete(b)

    # Each child becomes top-level: `in_blossom` for its vertices points at
    # it, and it gets its own base and match. The base child inherits `b`'s
    # external match; the others pair up (1,2), (3,4), ... via connectors.
    state =
      rotated
      |> Enum.with_index()
      |> Enum.reduce(%{state | dual: dual}, fn {child, i}, state ->
        in_blossom =
          Enum.reduce(blossom_vertices(state, child), state.in_blossom, &Map.put(&2, &1, child))

        {child_base, child_match} =
          cond do
            i == 0 ->
              {base_v, partner}

            rem(i, 2) == 1 ->
              {out_a, in_b} = connector(state, child, Enum.at(rotated, i + 1))
              {out_a, in_b}

            true ->
              {out_a, in_b} = connector(state, Enum.at(rotated, i - 1), child)
              {in_b, out_a}
          end

        %{
          state
          | in_blossom: in_blossom,
            base: Map.put(state.base, child, child_base),
            blossom_match: put_or_delete(state.blossom_match, child, child_match),
            parent_of: Map.delete(state.parent_of, child),
            label: Map.put(state.label, child, :free)
        }
      end)

    # The partner's own match pointed at `b`'s base vertex already (matches
    # are recorded as VERTICES); the base child now owns that vertex, so
    # nothing to redirect. `b` itself is gone.
    %{
      state
      | children: Map.delete(state.children, b),
        base: Map.delete(state.base, b),
        vertices_of: Map.delete(state.vertices_of, b),
        blossom_match: Map.delete(state.blossom_match, b),
        label: Map.delete(state.label, b),
        tops: tops_split(state.tops, b, children),
        label_edge: Map.delete(state.label_edge, b)
    }
  end

  defp put_weight(state, u, v, 0) do
    weight =
      state.weight
      |> Map.update(u, %{}, &Map.delete(&1, v))
      |> Map.update(v, %{}, &Map.delete(&1, u))

    %{state | weight: weight}
  end

  defp put_weight(state, u, v, w2) do
    weight =
      state.weight
      |> Map.update(u, %{v => w2}, &Map.put(&1, v, w2))
      |> Map.update(v, %{u => w2}, &Map.put(&1, u, w2))

    %{state | weight: weight}
  end

  defp gcd_of(edges) do
    edges
    |> Enum.reduce(0, fn {_i, _j, w}, acc -> if w > 0, do: Integer.gcd(acc, w), else: acc end)
    |> max(1)
  end

  # Divide every weight by the greatest common divisor of all of them.
  #
  # This is worth far more than it looks. `Ainalrami.Pairing` packs
  # C1-C21 into a single integer by giving each criterion its own band, and
  # on a 209-player field that produces edge weights of about a HUNDRED AND
  # THREE DIGITS — every `dual + dual - weight` inside the matcher is then
  # arbitrary-precision arithmetic, on the innermost operation of the whole
  # algorithm. In one real solve the 21,221 edges carried five distinct
  # weights sharing a ninety-digit common factor; dividing it out left
  # values that fit in 64 bits.
  #
  # Exact, not an approximation. Every matching's total scales by exactly
  # 1/g, so the argmax is unchanged, and `solve/2` returns the pairs rather
  # than any weight, so no caller can observe the scale at all. Doubling
  # happens afterwards in `build_state/2`, so the invariant that keeps dual
  # variables integral through the algorithm's halvings still holds.
  #
  # Costs one pass of Euclid over the edge list, against millions of
  # bignum operations saved.
  defp reduce_weights(edges) do
    gcd =
      Enum.reduce(edges, 0, fn {_i, _j, w}, acc ->
        if w > 0, do: Integer.gcd(acc, w), else: acc
      end)

    if gcd > 1 do
      Enum.map(edges, fn
        {i, j, w} when w > 0 -> {i, j, div(w, gcd)}
        edge -> edge
      end)
    else
      edges
    end
  end

  defp build_state(n, edges, ceiling, duals) do
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
      ceiling ||
        Enum.reduce(edges, 0, fn {_i, _j, w}, acc ->
          if w > 0, do: max(acc, 2 * w), else: acc
        end)

    {dual, blossom_match} = greedy_start(n, weights, duals)

    state = %{
      n: n,
      max_w: max_w,
      weight: weights,
      # Dual variable per VERTEX only — bbpPairings separately tracks a
      # dual variable per BLOSSOM (`ParentBlossom.dualVariable`); this
      # merges that into the same map keyed by blossom id (>= n for
      # non-trivial blossoms), since nothing about the algorithm needs
      # them kept apart.
      dual: dual,
      mate: %{},
      # `in_blossom[v]` is always the TOP-LEVEL blossom currently
      # containing vertex v — the direct analogue of bbpPairings'
      # `Vertex.rootBlossom`.
      in_blossom: Map.new(0..(n - 1), &{&1, &1}),
      # Nested structure, needed only for expansion: children in cyclic
      # order starting from the child containing the base, and each
      # child's parent. Trivial (single-vertex) blossoms have no entry.
      children: %{},
      vertices_of: %{},
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
      blossom_match: blossom_match,
      # Connector vertex pair for every cyclically-adjacent pair of
      # children ever formed — see `form_blossom/3`'s doc.
      connectors: %{},
      # Per TOP-LEVEL blossom only.
      label: %{},
      tops: [],
      # {labeling_vertex, labeled_vertex}: the edge that connected this
      # INNER blossom to its OUTER parent when the tree grew into it.
      label_edge: %{},
      # The delta-scan caches — see the "delta-scan caches" section below.
      best_outer: %{},
      cross: cross_empty(),
      shift_outer: 0,
      shift_cross: 0,
      min_outer: nil,
      next_blossom_id: n
    }

    state
  end

  # The starting point of a fresh solve: duals and a greedy matching, both
  # on the tight edges, instead of every dual at the ceiling and no
  # matching at all.
  #
  # bbpPairings starts cold -- every dual `aboveMaxEdgeWeight`, nothing
  # matched -- and so did this, and a cold solve on a 209-player field ran
  # 106 stages: the first delta lowers every dual to the top weight, the
  # heaviest edge goes tight and is matched, and from there it is one
  # augmentation per stage, each stage paying O(V^2) in cache rebuilds and
  # tree growth while the outer set is still most of the graph. Two of
  # those per round (the bye bootstrap and the round matcher's first
  # solve) were 43% of a 209-player round and would be 45% of a
  # 400-player one.
  #
  # Any state that satisfies the invariants is a legal starting point, and
  # the resumed solves after `set_weight/4` already rely on that. So:
  #
  #   * `dual[v]` = the weight of v's heaviest edge (half of it on the
  #     doubled scale). Feasible, since `dual[u] + dual[v]` is then at
  #     least `w(u, v)` from each side; at most `max_w`; and an isolated
  #     vertex sits at zero, which is where the search would put it.
  #   * match each exposed vertex, in index order, to its lowest-indexed
  #     exposed neighbour with which its heaviest edge is TIGHT -- the
  #     two are each other's heaviest, counting ties. Those are exactly
  #     the edges the first stages would have matched; the greedy pass
  #     does it in one walk of the adjacency.
  #
  # No blossoms, so `even_up_exposed_duals/1`'s parity step (which is
  # the one place the doubled scale cares) applies unchanged. On the
  # 209-player round's first graph 5 distinct weights cover 21,221 edges
  # and the greedy pass matches 202 of 209 vertices; the remaining stages
  # are the real work, and the outer set at their start is seven vertices
  # rather than two hundred and nine. When the optimum is not unique the
  # matching returned may differ from the cold search's -- which was
  # itself decided by map internals, not by anything canonical -- and the
  # corpus is the arbiter of whether that matters.
  defp greedy_start(n, weights, given) do
    dual =
      case given do
        nil ->
          Map.new(0..(n - 1)//1, fn v ->
            {v,
             weights
             |> Map.get(v, %{})
             |> Enum.reduce(0, fn {_u, w2}, best -> max(best, div(w2, 2)) end)}
          end)

        given ->
          dual = Map.new(0..(n - 1)//1, fn v -> {v, Map.get(given, v, 0)} end)

          for {u, row} <- weights, {v, w2} <- row, u < v do
            if Map.fetch!(dual, u) + Map.fetch!(dual, v) < w2 do
              raise ArgumentError,
                    "new/3: the given duals are infeasible on edge {#{u}, #{v}}: " <>
                      "#{Map.fetch!(dual, u)} + #{Map.fetch!(dual, v)} < #{w2}"
            end
          end

          dual
      end

    blossom_match =
      Enum.reduce(0..(n - 1)//1, %{}, fn v, bm ->
        yv = Map.fetch!(dual, v)

        if Map.has_key?(bm, v) do
          bm
        else
          partner =
            weights
            |> Map.get(v, %{})
            |> Enum.reduce(nil, fn {u, w2}, best ->
              if yv + Map.fetch!(dual, u) == w2 and not Map.has_key?(bm, u) and
                   (best == nil or u < best),
                 do: u,
                 else: best
            end)

          case partner do
            nil -> bm
            u -> bm |> Map.put(v, u) |> Map.put(u, v)
          end
        end
      end)

    {dual, blossom_match}
  end

  # A stage bound of `2n` is generous — the reference algorithm needs at
  # most n stages total (one per matching-size increase) — so hitting
  # this is a bug, not a slow instance, and failing loudly beats hanging.
  defp augment_until_done(state), do: augment_until_done(state, 2 * state.n + 5)

  defp augment_until_done(_state, 0), do: raise("WeightedMatching: exceeded stage budget")

  defp augment_until_done(state, budget) do
    case augment_once(state) do
      {:ok, state} -> augment_until_done(state, budget - 1)
      {:done, state} -> state
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

    # The labelled state is returned on BOTH paths. Returning a bare `:done`
    # here discarded `init_labels/1`'s work, which was harmless while the
    # label map always held the previous stage's labels and became a real
    # bug the moment `solve/1` started clearing it: `resolve_all_matching/1`
    # reads `top_blossoms/1`, which reads the label keys, and found none.
    case min_outer_dual(state) do
      nil -> {:done, state}
      _ -> grow(state)
    end
  end

  defp init_labels(state) do
    # The set of top-level blossoms is exactly the previous stage's label
    # KEYS: `form_blossom/3` and `expand_blossom/2` keep that key set
    # current, so it survives the boundary even though the label VALUES do
    # not. Re-deriving it from `in_blossom` -- as this used to, with a
    # `Map.values |> Enum.uniq` over every vertex -- was a full O(V) walk
    # per stage for information already in hand. The very first stage has
    # no labels yet and falls back to `in_blossom`.
    top =
      if map_size(state.label) == 0,
        do: state.in_blossom |> Map.values() |> Enum.uniq(),
        else: Map.keys(state.label)

    label =
      Enum.reduce(top, %{}, fn b, acc ->
        cond do
          matched?(state, b) -> Map.put(acc, b, :free)
          dual_of(state, base_vertex(state, b)) > 0 -> Map.put(acc, b, :outer)
          true -> Map.put(acc, b, :zero)
        end
      end)

    # A new stage relabels everything at once, which is the one moment the
    # outer set can SHRINK. The delta-scan caches are rebuilt from scratch
    # here rather than repaired, and that is the whole reason maintaining
    # them incrementally elsewhere is sound — see the "delta-scan caches"
    # section. O(V^2), once per stage, against O(V) stages.
    carry_caches(
      %{state | label: label, label_edge: %{}, tops: Enum.sort(top)},
      state.label
    )
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
    # The label map's keys ARE the top-level blossoms: `init_labels/1`
    # populates it for every one at a stage boundary, `form_blossom/3` adds
    # the new blossom and removes its children, `expand_blossom/2` does the
    # reverse. Reading it is O(top-level count); deriving the same set from
    # `in_blossom` -- as this used to -- was O(V) per call plus a sort, and
    # this is called four thousand times per solve on a 209-player field.
    #
    # Still SORTED, for the reason the comment above gives: several
    # consumers take the first strict minimum, and Erlang's map order is
    # not stable across the 32-key flatmap-to-hashmap transition.
    #
    # And CACHED: `state.tops` is that sorted list, rebuilt by `init_labels/1`
    # once per stage and patched in place by the four structural events
    # (`tops_formed/3`, `tops_split/3`). Sorting the keys on every call was
    # two to three sorts per delta step -- 0.8 s of a 400-player round.
    state.tops
  end

  # `new_id` replaces `children` at the top level. Ids are allocated in
  # increasing order, so the new one belongs at the end.
  defp tops_formed(tops, children, new_id), do: (tops -- children) ++ [new_id]

  # `children` replace `b` at the top level (expansion, dissolution).
  defp tops_split(tops, b, children) do
    merge_sorted(List.delete(tops, b), Enum.sort(children))
  end

  defp merge_sorted([], ys), do: ys
  defp merge_sorted(xs, []), do: xs
  defp merge_sorted([x | xs], [y | _] = ys) when x <= y, do: [x | merge_sorted(xs, ys)]
  defp merge_sorted(xs, [y | ys]), do: [y | merge_sorted(xs, ys)]

  defp matched?(state, b), do: Map.has_key?(state.blossom_match, b)
  defp base_vertex(state, b), do: Map.fetch!(state.base, b)
  defp dual_of(state, v), do: Map.fetch!(state.dual, v)

  # The minimum dual over every OUTER VERTEX -- not over each outer
  # blossom's base. bbpPairings' `updateMinOuterDualVariable` is called for
  # every vertex whose root blossom is outer (graph.cpp:401-412), and the
  # vertex that reaches zero is passed to `augmentToSource`, which rebases
  # the blossom at it.
  #
  # In a fresh solve the two are the same number: every vertex of an outer
  # blossom entered together and has moved together, so they share a dual.
  # After `prepare_vertex/2` they need not: a vertex reset to the maximum
  # can share a blossom with one inherited at 7, and guarding the base
  # alone let the low one be driven to -10. Measured, seed 168 of
  # `tools/matching_incremental.exs`.
  # Tracked, not scanned: `state.min_outer` is `{biased_dual, vertex}` over
  # every outer vertex, where the biased dual is the dual plus `shift_outer`
  # -- invariant under `apply_delta/2`, since every outer dual falls by
  # exactly what the shift rises by. Within a stage the outer set only
  # grows, so the minimum only ever has to take new vertices into account,
  # and every vertex that becomes outer passes through `settle_outer_vertex/2`,
  # which offers it. A stage start recomputes it from the outer set once
  # (`carry_caches/2`, `rebuild_caches/1`). This was a scan of every outer
  # vertex on every delta step -- bbpPairings tracks `minOuterDualVariable`
  # the same way (graph.cpp:401-412, updated on growth). Ties go to the
  # lower vertex id, a canonical order.
  defp min_outer_dual(state) do
    case state.min_outer do
      nil -> nil
      {biased, _v} -> biased - state.shift_outer
    end
  end

  defp min_outer_dual_vertex(state) do
    case state.min_outer do
      nil -> nil
      {biased, v} -> {biased - state.shift_outer, v}
    end
  end

  defp offer_min_outer(state, v) do
    biased = Map.fetch!(state.dual, v) + state.shift_outer

    case state.min_outer do
      {b0, v0} when b0 < biased or (b0 == biased and v0 < v) -> state
      _ -> %{state | min_outer: {biased, v}}
    end
  end

  defp recompute_min_outer(state, outer_blossoms) do
    outer_blossoms
    |> Enum.flat_map(&blossom_vertices(state, &1))
    |> Enum.reduce(%{state | min_outer: nil}, &offer_min_outer(&2, &1))
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
        # The VERTEX whose dual reached zero, which `augment_to_source/3`
        # rebases its blossom at. Not the blossom's current base: after
        # `prepare_vertex/2` a blossom's vertices can hold different duals,
        # and the one at zero need not be the base.
        {0, v} = min_outer_dual_vertex(state)

        {:ok, augment_to_source(state, v, nil)}

      min_free_outer && min_free_outer - delta == 0 ->
        handle_free_outer_tight(state, free_outer_vertex)

      min_outer_outer && min_outer_outer - 2 * delta == 0 ->
        handle_outer_outer_tight(state, outer_pair)

      min_inner_blossom && min_inner_blossom - 2 * delta == 0 ->
        # Captured BEFORE the expansion, because the blossom id stops
        # existing. Its vertices were inner and so held no cache entries;
        # the children that come out `:free` need them computed now.
        expanded = blossom_vertices(state, inner_blossom_id)

        {:cont, refresh_caches(expand_blossom(state, inner_blossom_id), expanded)}
        |> continue_growing()

      true ->
        # Numerically shouldn't happen — one of the four must hit zero —
        # but guards against an infinite loop from a rounding slip rather
        # than hanging.
        {:done, state}
    end
    |> case do
      {:ok, _state} = result -> result
      {:grow, state} -> grow(state)
      {:done, _state} = result -> result
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

      # One blossom left the non-outer set and one joined the outer set, so
      # both need their own cache entries rebuilt and the newly-outer one
      # needs offering to everything it neighbours.
      changed =
        blossom_vertices(state, v_blossom) ++ blossom_vertices(state, matched_blossom)

      {:grow, refresh_caches(state, changed)}
    end
  end

  defp handle_outer_outer_tight(state, {v0, v1}) do
    b0 = Map.fetch!(state.in_blossom, v0)
    b1 = Map.fetch!(state.in_blossom, v1)

    if tree_root(state, b0) == tree_root(state, b1) do
      # Formation is the one event that INVALIDATES rather than extends: an
      # edge between two vertices now inside the same blossom has stopped
      # being a cross edge, and any inner child has just become outer. Both
      # are covered by recomputing every vertex of the new blossom.
      # Which children were INNER before formation is knowable only now,
      # before `form_blossom/3` relabels everything: their vertices have no
      # cache entries and made no offers, so they need the full treatment.
      # The OUTER children's vertices already hold valid entries and have
      # already offered themselves; formation can only INVALIDATE one of
      # those -- by putting its partner inside the same new blossom -- so
      # they are filtered, and rescanned only if their entry died.
      #
      # This is bbpPairings' `initializeFromChildren`: `updateOuterOuterEdges`
      # for the LABEL_INNER children, and a min over existing tables for the
      # rest. Re-settling every vertex of every new blossom -- as this did --
      # was 479,000 row walks per 209-player round, 78% of it.
      {state, children, formerly_inner} = form_blossom(state, v0, v1)
      new_b = Map.fetch!(state.in_blossom, v0)
      {:grow, refresh_after_formation(state, new_b, children, formerly_inner)}
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

  ## ------------------------------------------------- delta-scan caches
  #
  # `min_free_or_zero_to_outer/1` and `min_outer_outer/1` were 84% of a
  # solve between them, and both rescanned every relevant vertex pair on
  # every delta step: O(V^2) a step, O(V^2) steps, which is the O(V^4) this
  # module was measured at. bbpPairings avoids that with `minOuterEdges`
  # and per-blossom `minOuterEdgeResistance`, and NOTICE records dropping
  # them as a deliberate trade for a smaller translation. These are them,
  # in the form this port can carry.
  #
  # Two maps, both keyed by VERTEX rather than by blossom, which is what
  # makes blossom formation cheap to handle:
  #
  #   * `best_outer[v]`, for v labelled `:free` or `:zero` — the
  #     least-resistance edge from v to any outer vertex, as
  #     `{resistance, outer_vertex}`.
  #   * `best_cross[v]`, for v labelled `:outer` — the least-resistance
  #     edge from v to an outer vertex in a DIFFERENT top-level blossom.
  #
  # Nothing is stored for an `:inner` vertex. It would never be read, and
  # storing it would go stale: `shift_caches/2` moves every entry by the
  # amount an outer-to-non-outer edge moves, and an inner vertex's own dual
  # rises by delta rather than staying put, so the two cancel instead.
  #
  # ## Why maintaining these is sound
  #
  # **Within a stage the outer set only ever grows.** Growing the tree
  # makes a free blossom inner and its mate outer; forming a blossom makes
  # inner children outer; expanding one splits an INNER blossom, whose
  # vertices were never outer. Nothing leaves the outer set until the stage
  # ends and `init_labels/1` starts over.
  #
  # So a cached entry can never go stale by pointing at a vertex that has
  # STOPPED being outer. It can only fall out of date by missing one that
  # has newly joined — which is exactly what `refresh_caches/2` folds in,
  # in one pass over the changed vertices' own adjacency.
  #
  # Blossom formation is the one event that invalidates rather than
  # extends: an edge between two vertices that end up inside the SAME new
  # blossom stops being a cross edge. Both of its endpoints are in that
  # blossom, and every vertex of a new blossom is recomputed from scratch,
  # so the same pass covers it.

  # The caches at a stage boundary, carried forward from the previous stage
  # rather than rebuilt -- WITHIN one solve only.
  #
  # Measured on a cold 209-vertex solve, 105 boundaries: the new stage's
  # outer set was ALWAYS a subset of the previous stage's final outer set --
  # 10,816 of 10,816 kept, 0 newly outer. It has to be: a stage ends by
  # augmenting, which matches exactly two exposed vertices, and then
  # `init_labels/1` makes every matched blossom free; the only blossoms
  # outer at the new start are the still-exposed ones, every one of which
  # was exposed (so outer) a moment ago. And no edge weight changes
  # between two stages of one solve.
  #
  # So the cross table needs FILTERING, not rebuilding: keep an entry when
  # both its blossoms are still outer, drop it otherwise. `best_outer`
  # likewise: an entry whose partner is still outer is still the minimum
  # over a set that only shrank. The only vertices needing a new entry are
  # the ones that left the outer set -- the augmented pair and the tree
  # that hung off them -- and those get one row walk each.
  #
  # Before: every outer vertex re-settled at every stage start,
  # O(|outer| x V) per stage and Theta(V^3) over a cold solve -- 86,000
  # `settle_outer_vertex` calls per 209-player round.
  #
  # ACROSS solves it does not hold and is not attempted. `set_weight/4`
  # changes edge weights, so cached resistances for those edges are stale
  # whatever the labels say, and it exposes vertices that were never outer.
  # `solve/1` clears the caches on entry, so the first stage of every solve
  # rebuilds from nothing -- which is what `prepare_vertex/2` already made
  # cheap, since a resumed solve's outer set is small. A first attempt that
  # carried across solves and patched the newly-outer vertices failed the
  # incremental net on 266 of 300 graphs; the stale resistances were the
  # reason.
  defp carry_caches(state, prev_label) do
    if map_size(prev_label) == 0 do
      rebuild_caches(state)
    else
      outer_blossoms = for {b, :outer} <- state.label, into: MapSet.new(), do: b
      state = recompute_min_outer(state, outer_blossoms)
      cross = cross_retain(state.cross, outer_blossoms)

      in_blossom = state.in_blossom
      outer_vertex? = fn v -> MapSet.member?(outer_blossoms, Map.fetch!(in_blossom, v)) end

      kept =
        state.best_outer
        |> Enum.filter(fn {v, {_r, partner}} ->
          outer_vertex?.(partner) and not outer_vertex?.(v)
        end)
        |> Map.new()

      state = %{state | cross: cross, best_outer: kept}

      needing =
        state.label
        |> Enum.filter(fn {_b, l} -> l in [:free, :zero] end)
        |> Enum.flat_map(fn {b, _} -> blossom_vertices(state, b) end)
        |> Enum.reject(&Map.has_key?(kept, &1))

      # Two ways to give the `needing` vertices their entries, and the
      # cheaper one depends on the stage:
      #
      #   * each needing vertex walks its OWN row looking for outer
      #     neighbours -- O(|needing| x V);
      #   * each OUTER vertex walks its row and offers itself to the
      #     needing neighbours it finds -- O(|outer| x V), which is how
      #     bbpPairings' `initializeInnerOuterEdges` is driven.
      #
      # Early in a cold solve the outer set is most of the graph and only
      # the augmented tree needs recomputing, so the first wins. In a
      # resumed solve after `set_weight/4` the outer set is the two or
      # three prepared vertices and `needing` is every free vertex whose
      # best partner was one of them -- a hundred row walks to find what
      # three would have delivered. Measured on a 209-player round: 136,000
      # row walks from this one reduce, a quarter of the round.
      outer_vertices = Enum.flat_map(outer_blossoms, &blossom_vertices(state, &1))

      if length(needing) <= length(outer_vertices) do
        Enum.reduce(needing, state, &recompute_vertex(&2, &1))
      else
        offer_outer_to(state, outer_vertices, MapSet.new(needing))
      end
    end
  end

  # `best_outer` entries for the vertices in `targets`, delivered by the
  # outer vertices walking their own rows. The caller has already dropped
  # any stale entries the targets held.
  defp offer_outer_to(state, outer_vertices, targets) do
    duals = state.dual
    shift = state.shift_outer

    best_outer =
      Enum.reduce(outer_vertices, state.best_outer, fn u, bo ->
        case Map.get(state.weight, u) do
          nil ->
            bo

          row ->
            dual_u = Map.fetch!(duals, u)

            Enum.reduce(row, bo, fn {v, w}, bo ->
              if MapSet.member?(targets, v),
                do: offer(bo, v, stored(dual_u + Map.fetch!(duals, v) - w, shift), u),
                else: bo
            end)
        end
      end)

    %{state | best_outer: best_outer}
  end

  # Every vertex's entry, from nothing. O(V^2), and run once per stage.
  defp rebuild_caches(state) do
    state = %{
      state
      | best_outer: %{},
        cross: cross_empty(),
        shift_outer: 0,
        shift_cross: 0,
        min_outer: nil
    }

    # Driven from the OUTER vertices, not from all of them. Every entry in
    # either cache is an edge with an outer far end, so offering each outer
    # vertex to its neighbours produces exactly the same maps as asking
    # every vertex to find its own best — and costs O(|outer| x V) instead
    # of O(V^2).
    #
    # That difference is the point at a stage boundary, which is when this
    # runs: `init_labels/1` has just marked every MATCHED blossom free, so
    # the outer set is only the unmatched ones. It starts at the whole
    # field and shrinks towards nothing as the matching fills in, which is
    # precisely the shape that makes iterating all V vertices wasteful.
    # Only the outer vertices are walked at all -- everything a non-outer
    # vertex needs is delivered TO it by an outer neighbour's offer.
    state.label
    |> Enum.filter(fn {_b, l} -> l == :outer end)
    |> Enum.flat_map(fn {b, _} -> blossom_vertices(state, b) end)
    |> Enum.reduce(state, &settle_outer_vertex(&2, &1))
  end

  # Fold a set of just-changed vertices back in, doing exactly what each
  # one's NEW label requires and no more.
  #
  # This used to recompute every changed vertex's own entry and then offer
  # every changed vertex to its neighbours — two full walks of each
  # adjacency row, and half of them for nothing: a vertex that has just
  # become INNER is neither a cache subject nor a candidate for anyone, so
  # offering it walked two hundred neighbours to hit `_ -> state` every
  # time. `offer_vertex/2` was 62% of a solve, from 35,000 calls.
  #
  # Now:
  #
  #   * newly INNER — delete its entries. No walk.
  #   * newly OUTER — ONE walk of its row that computes its own best cross
  #     edge and offers it to every neighbour in the same pass. The two
  #     jobs read the same neighbours with the same duals; fusing them is
  #     free.
  #   * newly FREE or ZERO (only after an expansion) — recompute its
  #     `best_outer`, which does need a walk, since its neighbours' outer
  #     status is what it depends on. Nothing to offer: it is not outer.
  #
  # Same maps as before, reached with roughly a third of the row visits.
  # After `form_blossom/3`: the new blossom `b` is outer, built from
  # `children`, of which the `formerly_inner` vertices had no presence in
  # any cache. This is bbpPairings' `initializeFromChildren`.
  #
  #   * The cross table: MERGE the outer children's rows into `b`'s, and
  #     every other blossom's entries for the children into one entry for
  #     `b`. No vertex walked. The second-best edge to every other blossom
  #     was already in the table, so nothing is lost when the best one
  #     becomes internal -- which is exactly the case formation produces,
  #     since blossoms merge because their best edges pointed at each
  #     other. Under the previous per-vertex design that invalidated almost
  #     every entry and cost 252,000 rescans per 209-player round.
  #   * The formerly-inner vertices: walked once, offering their edges to
  #     the table and to `best_outer` (they are outer now).
  #   * Every vertex of `b` loses its `best_outer` entry, since an outer
  #     vertex holds none.
  defp refresh_after_formation(state, b, children, formerly_inner) do
    state = cross_merge(state, b, children)

    Enum.reduce(blossom_vertices(state, b), state, fn v, state ->
      if MapSet.member?(formerly_inner, v),
        do: settle_outer_vertex(state, v),
        else: %{state | best_outer: Map.delete(state.best_outer, v)}
    end)
  end

  defp refresh_caches(state, changed) do
    Enum.reduce(changed, state, fn v, state ->
      case Map.get(state.label, Map.fetch!(state.in_blossom, v)) do
        :inner ->
          %{state | best_outer: Map.delete(state.best_outer, v)}

        :outer ->
          settle_outer_vertex(state, v)

        _ ->
          recompute_vertex(state, v)
      end
    end)
  end

  # For a vertex that is (now) outer, in one pass over its adjacency row:
  # offer itself to every free/zero neighbour (`best_outer`), and offer
  # every edge to an outer neighbour in another blossom to the cross table
  # (both rows). This is the ONLY place a vertex's edges are ever walked
  # for the cross table; everything else about the table is a merge or a
  # delete.
  defp settle_outer_vertex(state, v) do
    state = offer_min_outer(state, v)
    blossom = Map.fetch!(state.in_blossom, v)
    best_outer = Map.delete(state.best_outer, v)
    cross = state.cross

    case Map.get(state.weight, v) do
      nil ->
        %{state | best_outer: best_outer, cross: cross}

      row ->
        # Everything the loop reads is pulled out of `state` ONCE, and the
        # two caches are threaded through the reduce as bare maps. Writing
        # `%{state | ...}` inside the loop rebuilds the whole state map on
        # every neighbour visited, which measured at four times the cost of
        # the work it wrapped.
        dual_v = Map.fetch!(state.dual, v)
        duals = state.dual
        labels = state.label
        in_blossom = state.in_blossom
        # The stored (biased) resistance is `dual_v + dual_u - w + shift`;
        # folding the shift into `dual_v` once saves a bignum addition per
        # neighbour.
        dv_cross = dual_v + state.shift_cross
        dv_outer = dual_v + state.shift_outer

        # The label is read FIRST and the resistance computed only for the
        # neighbours that take an offer: an inner neighbour, or one in the
        # same blossom, costs one lookup rather than two lookups and two
        # bignum operations.
        {cross, best_outer} =
          Enum.reduce(row, {cross, best_outer}, fn {u, w}, {cr, bo} ->
            ub = Map.fetch!(in_blossom, u)

            case Map.get(labels, ub) do
              :outer when ub != blossom ->
                {cross_offer(cr, blossom, ub, dv_cross + Map.fetch!(duals, u) - w, v, u), bo}

              label when label in [:free, :zero] ->
                {cr, offer(bo, u, dv_outer + Map.fetch!(duals, u) - w, v)}

              _ ->
                {cr, bo}
            end
          end)

        %{state | cross: cross, best_outer: best_outer}
    end
  end

  # For a FREE or ZERO vertex: its best edge to any outer vertex. (An outer
  # vertex is handled by `settle_outer_vertex/2`; an inner one holds
  # nothing.) The cross table is not a per-vertex thing any more, so only
  # `best_outer` is in question here.
  defp recompute_vertex(state, v) do
    blossom = Map.fetch!(state.in_blossom, v)
    row = Map.get(state.weight, v)

    case Map.get(state.label, blossom) do
      label when label in [:free, :zero] ->
        best = bias(scan_row(state, v, row, blossom, :outer), state.shift_outer)
        %{state | best_outer: put_best(state.best_outer, v, best)}

      _ ->
        %{state | best_outer: Map.delete(state.best_outer, v)}
    end
  end

  defp scan_row(_state, _v, nil, _blossom, _kind), do: nil

  defp scan_row(state, v, row, blossom, kind) do
    dual_v = Map.fetch!(state.dual, v)

    Enum.reduce(row, nil, fn {u, w}, best ->
      u_blossom = Map.fetch!(state.in_blossom, u)

      keep? =
        Map.get(state.label, u_blossom) == :outer and
          (kind == :outer or u_blossom != blossom)

      if keep? do
        r = dual_v + Map.fetch!(state.dual, u) - w
        if best == nil or r < elem(best, 0), do: {r, u}, else: best
      else
        best
      end
    end)
  end

  defp offer(cache, u, r, v) do
    case cache do
      %{^u => {best, _}} when best <= r -> cache
      _ -> Map.put(cache, u, {r, v})
    end
  end

  defp put_best(cache, v, nil), do: Map.delete(cache, v)
  defp put_best(cache, v, best), do: Map.put(cache, v, best)

  defp bias(nil, _shift), do: nil
  defp bias({r, u}, shift), do: {stored(r, shift), u}

  # `apply_delta/2` moves every outer vertex's dual down by delta and every
  # inner vertex's up by the same, so a cached resistance moves by a fixed
  # amount that depends only on how many of its endpoints are outer: one
  # for `best_outer` (the far end), two for `best_cross` (both ends).
  #
  # Crucially, EVERY entry in a given cache moves by the same amount. So
  # rather than rewriting the map — O(V) allocation on every one of O(V^2)
  # delta steps, which measured as costing more than the scans it replaced
  # — the shift is carried as a running offset. Entries are stored biased
  # by the offset at the moment they were written, and read back unbiased,
  # so they all track the duals for free.
  defp shift_caches(state, 0), do: state

  defp shift_caches(state, delta) do
    %{state | shift_outer: state.shift_outer + delta, shift_cross: state.shift_cross + 2 * delta}
  end

  # Stored biased, read unbiased. Comparisons between two entries of the
  # same cache can use the stored form directly, since the bias is common.
  defp stored(r, shift), do: r + shift
  defp unbiased(r, shift), do: r - shift

  # Straight off `best_outer`, which holds an entry for exactly the free
  # and zero vertices that have any edge to an outer one. Was a rescan of
  # every (non-outer, outer) pair on every delta step.
  defp min_free_or_zero_to_outer(state) do
    state.best_outer
    |> Enum.reduce({nil, nil}, fn {v, {r, _u}}, {best, best_v} ->
      if best == nil or r < best, do: {r, v}, else: {best, best_v}
    end)
    |> case do
      {nil, _} -> {nil, nil}
      {r, v} -> {unbiased(r, state.shift_outer), v}
    end
  end

  # The partner achieving that minimum, which the cache already recorded.
  defp min_outer_edge(state, v) do
    case state.best_outer do
      %{^v => {_r, u}} -> u
      _ -> nil
    end
  end

  # The flat vertex list of a blossom.
  #
  # `state.vertices_of` caches it for every NON-TRIVIAL blossom, maintained
  # at the three places the structure changes: `form_blossom/3` sets the new
  # blossom's list to the concatenation of its children's; `expand_blossom/2`
  # and `dissolve_one/3` delete the parent's entry (the children's are still
  # there, since they were non-trivial blossoms or bare vertices before).
  # A trivial blossom IS its vertex.
  #
  # Before this it was recomputed by recursion on every call -- 5.5 million
  # calls per 209-player round, most of them from `refresh_caches/2`
  # expanding a changed blossom to feed `settle_outer_vertex/2`, and each
  # one walking a nested tree that had not changed since the last call. It
  # was the largest cost in the profile once the stage count was right.
  #
  # The recursive walk is kept as the fallback for anything not in the
  # cache, so a caller asking about a blossom mid-transition still gets the
  # right answer rather than a crash.
  defp blossom_vertices(state, b) do
    case state.vertices_of do
      %{^b => vs} -> vs
      _ -> if Map.has_key?(state.children, b), do: walk_blossom_vertices(state, b), else: [b]
    end
  end

  defp walk_blossom_vertices(state, b) do
    if Map.has_key?(state.children, b) do
      state.children |> Map.fetch!(b) |> Enum.flat_map(&walk_blossom_vertices(state, &1))
    else
      [b]
    end
  end

  ## --------------------------------------------- the cross-edge table
  #
  # `state.cross` is bbpPairings' `minOuterEdges`: for every pair of OUTER
  # top-level blossoms, the least-resistance edge between them.
  #
  #     cross :: %{blossom => %{other_blossom => {stored_r, v_here, v_there}}}
  #
  # Symmetric -- both rows hold the edge, each from its own side -- and
  # keyed by BLOSSOM, which is the whole point. The previous design kept one
  # entry per VERTEX (its single best cross edge), and that died on blossom
  # formation: when outer blossoms merge it is because their best edges
  # point at each other, so nearly every entry was invalidated and had to
  # be rescanned -- 252,000 row walks per 209-player round, 58% of it.
  #
  # Per blossom pair, formation is a MERGE: the new blossom's row is the
  # min over its children's rows, and every other blossom's entry for the
  # new one is the min over its entries for the children. No vertex is
  # visited. The second-best edge to every other blossom was already in
  # the table, so nothing is lost when the best one becomes internal.
  #
  # Maintained at:
  #   * `rebuild_cross/1`      -- stage start, from the outer set, by walking
  #   * `cross_add_blossom/2`  -- a blossom has just become outer: walk its
  #                               vertices once, fill its row and everyone
  #                               else's entry for it
  #   * `cross_merge/3`        -- formation: merge children's rows, O(B^2)
  #   * `cross_remove/2`       -- a blossom stops being outer or stops
  #                               existing: drop its row and every entry
  #                               pointing at it
  #
  # Stored resistances carry `shift_cross` bias exactly as before, so the
  # dual shift stays O(1).

  # One flat map, `{lo, hi} => {stored_r, v_lo, v_hi}` with `lo < hi`, plus
  # a running minimum `cross_best :: {stored_r, key} | nil` kept alongside
  # it -- bbpPairings' `minOuterOuterEdgeResistance`. An offer that wins
  # updates both in O(1); `min_outer_outer/1` reads the minimum instead of
  # scanning the table, which at stage start holds ~|outer|^2 entries and
  # was scanned on every one of ~27,000 delta steps a round -- 20% of it.
  #
  # The minimum can only go STALE in one way: `cross_merge/3` drops or
  # re-keys entries, so it recomputes the minimum from the merged table.
  # Within a stage nothing else removes an entry. (A tuple key was measured
  # against a packed integer key and made no difference; the cost of a
  # losing offer is the lookup itself, not the key.)
  ## ------------------------------------------------------ the cross table
  #
  # bbpPairings' `minOuterEdges`: for every pair of OUTER top-level
  # blossoms, the least-resistance edge between them, as `{resistance,
  # vertex_here, vertex_there}`. Kept as ROWS, one per outer blossom,
  # each row a map from partner blossom to that entry, with the symmetric
  # entry in the partner's row -- the same shape as the weight adjacency,
  # and for the same reason: the two operations that change the table
  # touch one blossom's row and its partners' entries for it, and a flat
  # `{lo, hi}`-keyed map made both of them a walk of the whole table.
  #
  #   * `cross_merge/3` (blossom formation) used to rebuild the flat map
  #     from scratch -- O(k^2) in the number of outer blossoms -- and
  #     formations are the commonest event after tree growth: 9,877 of
  #     them on a 400-player round, 5.3 s of 15. Now it folds the
  #     children's rows into one and re-keys the partners' entries:
  #     O(children x k).
  #   * the stage-start filter in `carry_caches/2` dropped every entry of
  #     a blossom that left the outer set by testing all k^2 entries; now
  #     it walks the leaving blossoms' rows: O(left x k).
  #
  # Alongside the rows, `mins[a]` is row a's minimum as `{r, partner}`,
  # and `best` the minimum over the rows as `{r, a, b}` with `a < b`.
  # Offers only lower minima and update them in place; merges and the
  # stage filter can raise them, and recompute exactly the rows they
  # touched plus `best` (one pass over `mins`, O(k)). Ties are broken on
  # `{r, partner}` / `{r, a, b}` -- a canonical order, where the flat map
  # had "first offered wins", which was deterministic but an accident of
  # iteration order.
  #
  # Resistances are stored biased by `shift_cross` at the moment they are
  # written and read back unbiased (`stored/2`, `unbiased/2`), exactly as
  # before; comparisons between entries are on the stored form.

  defp cross_empty, do: {%{}, %{}, nil}

  defp cross_offer({rows, mins, best} = cross, a, b, r, va, vb) do
    case rows do
      %{^a => %{^b => {old, _, _}}} when old <= r ->
        cross

      _ ->
        rows =
          rows
          |> Map.update(a, %{b => {r, va, vb}}, &Map.put(&1, b, {r, va, vb}))
          |> Map.update(b, %{a => {r, vb, va}}, &Map.put(&1, a, {r, vb, va}))

        mins = mins |> offer_min(a, {r, b}) |> offer_min(b, {r, a})
        {lo, hi} = if a < b, do: {a, b}, else: {b, a}
        best = lower_best(best, {r, lo, hi})
        {rows, mins, best}
    end
  end

  # Write the row minimum only when it changes; a `Map.update` that puts
  # the old value back still rebuilds the map.
  defp offer_min(mins, a, cand) do
    case mins do
      %{^a => old} ->
        case lower_min(old, cand) do
          ^old -> mins
          new -> Map.put(mins, a, new)
        end

      _ ->
        Map.put(mins, a, cand)
    end
  end

  defp lower_min({r0, _} = old, {r, _}) when r0 < r, do: old
  defp lower_min({r0, b0} = old, {r, b}) when r0 == r and b0 <= b, do: old
  defp lower_min(_old, new), do: new

  defp lower_best(nil, new), do: new
  defp lower_best(old, new), do: if(new < old, do: new, else: old)

  # Row a's minimum, from its entries.
  defp row_min(row) do
    Enum.reduce(row, nil, fn {b, {r, _, _}}, acc ->
      if acc == nil, do: {r, b}, else: lower_min(acc, {r, b})
    end)
  end

  defp cross_best(mins) do
    Enum.reduce(mins, nil, fn {a, {r, b}}, acc ->
      {lo, hi} = if a < b, do: {a, b}, else: {b, a}
      lower_best(acc, {r, lo, hi})
    end)
  end

  # The new blossom `new_b` has absorbed `children`, all of which were
  # top-level and some of which were outer. Every entry touching a child
  # is re-keyed: an entry between two children is now INTERNAL and is
  # dropped; an entry between a child and an outsider `k` becomes an entry
  # between `new_b` and `k`, keeping the minimum if several collapse onto
  # the same key. No vertex is visited.
  #
  # The second-best edge to every outsider was already in the table, so
  # nothing is lost when the best one becomes internal -- which is exactly
  # the case formation produces, since blossoms merge because their best
  # edges pointed at each other. Under a per-vertex design that
  # invalidated almost every entry and cost 252,000 rescans per 209-player
  # round.
  #
  # Children that were INNER had no entries; the caller walks their
  # vertices with `settle_outer_vertex/2`.
  defp cross_merge(state, new_b, children) do
    child_set = MapSet.new(children)
    {rows, mins, _best} = state.cross

    # The merged row: every child's entries to outsiders, best per outsider.
    new_row =
      Enum.reduce(children, %{}, fn c, acc ->
        Enum.reduce(Map.get(rows, c, %{}), acc, fn {k, {r, vc, vk}}, acc ->
          cond do
            MapSet.member?(child_set, k) -> acc
            match?(%{^k => {old, _, _}} when old <= r, acc) -> acc
            true -> Map.put(acc, k, {r, vc, vk})
          end
        end)
      end)

    rows = Map.drop(rows, children)
    mins = Map.drop(mins, children)

    # Each outsider loses its entries for the children and gains one for
    # `new_b`; its row minimum is recomputed only if it pointed at a child
    # or the new entry beats it.
    {rows, mins} =
      Enum.reduce(new_row, {rows, mins}, fn {k, {r, vc, vk}}, {rows, mins} ->
        row = rows |> Map.fetch!(k) |> Map.drop(children) |> Map.put(new_b, {r, vk, vc})
        rows = Map.put(rows, k, row)

        mins =
          case Map.get(mins, k) do
            {_, p} = old ->
              if MapSet.member?(child_set, p),
                do: Map.put(mins, k, row_min(row)),
                else: Map.put(mins, k, lower_min(old, {r, new_b}))

            nil ->
              Map.put(mins, k, row_min(row))
          end

        {rows, mins}
      end)

    {rows, mins} =
      if map_size(new_row) == 0,
        do: {rows, mins},
        else: {Map.put(rows, new_b, new_row), Map.put(mins, new_b, row_min(new_row))}

    %{state | cross: {rows, mins, cross_best(mins)}}
  end

  # Drop every entry of the blossoms that are no longer outer -- the
  # stage-start filter. Walks the leaving blossoms' rows, not the table.
  defp cross_retain({rows, mins, _best}, outer_blossoms) do
    left = for {b, _} <- rows, not MapSet.member?(outer_blossoms, b), do: b
    left_set = MapSet.new(left)

    {rows, mins} =
      Enum.reduce(left, {rows, mins}, fn b, {rows, mins} ->
        Enum.reduce(Map.fetch!(rows, b), {rows, mins}, fn {k, _}, {rows, mins} ->
          if MapSet.member?(left_set, k) do
            {rows, mins}
          else
            row = rows |> Map.fetch!(k) |> Map.delete(b)
            rows = Map.put(rows, k, row)

            mins =
              case Map.get(mins, k) do
                {_, ^b} -> Map.put(mins, k, row_min(row))
                _ -> mins
              end

            {rows, mins}
          end
        end)
      end)

    rows = Map.drop(rows, left)
    mins = mins |> Map.drop(left) |> Map.reject(fn {_, m} -> m == nil end)
    {rows, mins, cross_best(mins)}
  end

  # The least-resistance outer-outer edge overall, straight off the running
  # minimum.
  defp min_outer_outer(state) do
    case state.cross do
      {_, _, nil} ->
        {nil, nil}

      {rows, _, {r, a, b}} ->
        {_, va, vb} = rows |> Map.fetch!(a) |> Map.fetch!(b)
        {unbiased(r, state.shift_cross), {va, vb}}
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
    |> shift_caches(delta)
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
  # `mate` is a DERIVED view of `blossom_match`, rebuilt here from nothing
  # at the end of every solve. It used to accumulate instead -- harmless
  # when each solve started from an empty state, and wrong the moment a
  # solve started from a previous one: `prepare_vertex/2` re-pairs siblings
  # at the blossom level, and a vertex re-absorbed into a new blossom
  # before the end of the next solve never had its old `mate` entry
  # overwritten. Result: `%{1 => 5, 5 => 1}` alongside `blossom_match`
  # saying `1 <-> 4`, and an asymmetric "matching" handed to the caller.
  defp resolve_all_matching(state) do
    state = %{state | mate: %{}}

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

    # Which cycle members were INNER, captured before the relabel below:
    # their vertices hold no cache entries and need the full treatment after
    # formation, where the outer children's only need filtering. Returned
    # to the caller alongside the new state.
    formerly_inner =
      cycle
      |> Enum.filter(&(Map.get(state.label, &1) == :inner))
      |> Enum.flat_map(&blossom_vertices(state, &1))
      |> MapSet.new()

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

    # The new blossom's vertex list is its children's, concatenated -- read
    # BEFORE `in_blossom` is rewritten below, while each child's own list
    # is still what `blossom_vertices/2` returns for it.
    new_vertices = Enum.flat_map(cycle, &blossom_vertices(state, &1))
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
        vertices_of: Map.put(state.vertices_of, new_id, new_vertices),
        parent_of: parent_of,
        in_blossom: in_blossom,
        base: base,
        blossom_match: blossom_match,
        connectors: connectors,
        dual: Map.put(state.dual, new_id, 0),
        # The children stop being top-level, so their labels go. This
        # keeps `state.label`'s KEY SET equal to the top-level blossom set,
        # which `top_blossoms/1` now relies on — see its comment. Before
        # this the stale child entries were harmless only because
        # `top_blossoms/1` was derived from `in_blossom` instead.
        label: Enum.reduce(cycle, Map.put(state.label, new_id, :outer), &Map.delete(&2, &1)),
        tops: tops_formed(state.tops, cycle, new_id),
        next_blossom_id: new_id + 1
    }
    |> then(&{&1, cycle, formerly_inner})
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
        vertices_of: Map.delete(state.vertices_of, b),
        label: Map.delete(state.label, b),
        tops: tops_split(state.tops, b, children),
        label_edge: Map.delete(state.label_edge, b),
        dual: Map.delete(state.dual, b)
    }
  end
end
