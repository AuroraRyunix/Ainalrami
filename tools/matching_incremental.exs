# The persistent matcher, checked against the one-shot one.
#
#   mix run tools/matching_incremental.exs
#
# For each random graph: solve once, then perturb a batch of edges with
# set_weight/4 and solve/1 again, several times over. After EVERY solve the
# incremental answer's total weight must equal a fresh solve/2 on the same
# perturbed graph, and it must be a valid matching. If re-augmenting from a
# previous solution ever lands on a worse optimum, this is what catches it.
#
# Batches are deliberately mixed: single edges, dozens at once, whole
# vertices' rows, weights raised, lowered, and removed -- because the
# soundness argument (a prepared vertex is exactly as it was at the start of
# a fresh solve) is per-vertex, and the risky part is what happens to the
# vertices AROUND a prepared one when its blossom is dissolved.

alias Ainalrami.WeightedMatching, as: WM

# A fresh weight for a perturbed edge: usually a new positive value, one
# time in five a removal, so both raising and deleting edges are exercised.
new_weight = fn scale ->
  if :rand.uniform(5) == 1, do: 0, else: :rand.uniform(50) * scale
end

weight_of = fn weights, matching ->
  matching
  |> Enum.map(fn {a, b} -> if a < b, do: Map.get(weights, {a, b}, 0), else: 0 end)
  |> Enum.sum()
end

valid? = fn matching, weights ->
  Enum.all?(matching, fn {a, b} ->
    Map.get(matching, b) == a and a != b and Map.has_key?(weights, {min(a, b), max(a, b)})
  end)
end

failures =
  for seed <- 1..300, reduce: [] do
    acc ->
      :rand.seed(:exsss, {seed, seed * 7919, seed * 104_729})
      n = Enum.random([6, 8, 12, 20, 40, 70])
      scale = Enum.random([1, 1_000, 1_000_000_000])
      density = Enum.random([40, 70, 100])

      weights =
        for i <- 0..(n - 2), j <- (i + 1)..(n - 1), :rand.uniform(100) <= density, into: %{} do
          {{i, j}, :rand.uniform(50) * scale}
        end

      edges = Enum.map(weights, fn {{i, j}, w} -> {i, j, w} end)
      state = WM.new(n, edges, max_weight: 50 * scale)
      {state, m0} = WM.solve(state)

      first_ok = weight_of.(weights, m0) == weight_of.(weights, WM.solve(n, edges)) and valid?.(m0, weights)

      if not first_ok do
        [{seed, :first_solve, n} | acc]
      else
        # Several rounds of perturbation.
        {_state, _weights, bad} =
          Enum.reduce(1..6, {state, weights, nil}, fn round, {state, weights, bad} ->
            if bad do
              {state, weights, bad}
            else
              batch =
                case rem(round, 3) do
                  # a single edge
                  1 -> 1
                  # a handful
                  2 -> Enum.random(3..12)
                  # everything touching one vertex
                  0 -> :vertex
                end

              changes =
                case batch do
                  :vertex ->
                    v = :rand.uniform(n) - 1
                    for u <- 0..(n - 1), u != v, do: {min(u, v), max(u, v), new_weight.(scale)}

                  k ->
                    for _ <- 1..k do
                      i = :rand.uniform(n) - 1
                      j = :rand.uniform(n) - 1
                      if i == j, do: nil, else: {min(i, j), max(i, j), new_weight.(scale)}
                    end
                    |> Enum.reject(&is_nil/1)
                end

              # Weights must stay on the GCD scale set_weight enforces.
              gcd = state.gcd

              changes =
                Enum.map(changes, fn {i, j, w} -> {i, j, if(w == 0, do: 0, else: max(w - rem(w, gcd), gcd))} end)

              {state, weights} =
                Enum.reduce(changes, {state, weights}, fn {i, j, w}, {state, weights} ->
                  {WM.set_weight(state, i, j, w),
                   if(w == 0, do: Map.delete(weights, {i, j}), else: Map.put(weights, {i, j}, w))}
                end)

              {state, m} = WM.solve(state)
              fresh_edges = Enum.map(weights, fn {{i, j}, w} -> {i, j, w} end)
              fresh = WM.solve(n, fresh_edges)

              incr_w = weight_of.(weights, m)
              fresh_w = weight_of.(weights, fresh)

              cond do
                not valid?.(m, weights) -> {state, weights, {round, :invalid, incr_w, fresh_w}}
                incr_w != fresh_w -> {state, weights, {round, :suboptimal, incr_w, fresh_w}}
                true -> {state, weights, nil}
              end
            end
          end)

        if bad, do: [{seed, bad, n} | acc], else: acc
      end
  end

IO.puts("checked 300 graphs x 6 perturbation rounds")

if failures == [] do
  IO.puts("ALL INCREMENTAL SOLVES OPTIMAL AND VALID")
else
  IO.puts("#{length(failures)} FAILURES:")
  for f <- Enum.take(Enum.reverse(failures), 8), do: IO.puts("  #{inspect(f)}")
  System.halt(1)
end
