# Records `WeightedMatching.solve/2`'s output on a fixed corpus of random
# graphs, so an optimisation of the matcher can be proven output-identical
# rather than merely "still passes the tests".
#
#   mix run tools/matching_baseline.exs record   # before the change
#   mix run tools/matching_baseline.exs verify   # after it
#
# Weights span both the small values the unit tests use and the very large
# packed integers `Ainalrami.Pairing` actually produces, since the
# algorithm's arithmetic behaves differently at each scale.

mode = System.argv() |> Enum.at(0, "verify")
path = "matching_baseline.bin"

# Two tiers. The small one is where blossom formation and expansion are
# easy to hit by chance; the large one is where a scale-dependent error
# would hide, and is the size the engine actually runs at.
small =
  for seed <- 1..400 do
    :rand.seed(:exsss, {seed, seed * 7919, seed * 104_729})
    n = Enum.random(2..26)
    scale = Enum.random([1, 1_000, 1_000_000_000])
    density = Enum.random([30, 60, 100])

    edges =
      for i <- 0..(n - 2), j <- (i + 1)..(n - 1), :rand.uniform(100) <= density do
        {i, j, :rand.uniform(50) * scale}
      end

    {seed, n, edges}
  end

large =
  for seed <- 1001..1060 do
    :rand.seed(:exsss, {seed, seed * 7919, seed * 104_729})
    n = Enum.random(40..90)
    scale = Enum.random([1, 1_000_000_000])
    density = Enum.random([40, 70, 100])

    edges =
      for i <- 0..(n - 2), j <- (i + 1)..(n - 1), :rand.uniform(100) <= density do
        {i, j, :rand.uniform(50) * scale}
      end

    {seed, n, edges}
  end

graphs = small ++ large

results =
  Enum.map(graphs, fn {seed, n, edges} ->
    {seed, Ainalrami.WeightedMatching.solve(n, edges)}
  end)

total_weight = fn {_, n, edges}, matching ->
  w = Map.new(edges, fn {i, j, w} -> {{min(i, j), max(i, j)}, w} end)

  matching
  |> Enum.map(fn {a, b} -> Map.get(w, {min(a, b), max(a, b)}, 0) end)
  |> Enum.sum()
  |> div(2)
  |> then(fn s -> {n, s} end)
end

case mode do
  "record" ->
    File.write!(path, :erlang.term_to_binary(results))
    IO.puts("recorded #{length(results)} matchings to #{path}")

  "verify" ->
    unless File.exists?(path) do
      IO.puts("no baseline at #{path} — run `record` first")
      System.halt(1)
    end

    expected = path |> File.read!() |> :erlang.binary_to_term()

    diffs =
      Enum.zip(expected, results)
      |> Enum.reject(fn {{s1, m1}, {s2, m2}} -> s1 == s2 and m1 == m2 end)

    IO.puts("compared #{length(results)} matchings")

    if diffs == [] do
      IO.puts("IDENTICAL")
    else
      IO.puts("#{length(diffs)} DIFFER:")

      for {{seed, before}, {_, now}} <- Enum.take(diffs, 5) do
        g = Enum.find(graphs, fn {s, _, _} -> s == seed end)
        IO.puts("  seed #{seed}: was #{inspect(total_weight.(g, before))}, now #{inspect(total_weight.(g, now))}")
      end

      System.halt(1)
    end
end
