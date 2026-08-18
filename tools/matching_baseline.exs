# Differential net for `WeightedMatching.solve/2`.
#
#   mix run tools/matching_baseline.exs record   # before a change
#   mix run tools/matching_baseline.exs verify   # after it
#
# Checks TOTAL WEIGHT first and exact identity second, and that ordering is
# the point. A maximum-weight matching need not be unique: on these random
# graphs several matchings often reach the same optimum, so an optimisation
# that picks a different one is correct and an exact-match check would call
# it a regression.
#
# It matters here specifically. 86% of the algorithm's delta steps have a
# TIED minimum, so anything that changes which minimum is chosen -- a cache
# rather than a linear scan, say -- takes a different path through the
# search almost every step. What must not change is the weight it lands on.
#
# Two tiers: small graphs, where blossom formation and expansion are easy
# to hit by chance, and large ones at the size the engine actually runs at,
# where a scale-dependent error would hide.

mode = System.argv() |> Enum.at(0, "verify")
path = "matching_baseline.bin"

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

weight_of = fn edges, matching ->
  lookup = Map.new(edges, fn {i, j, w} -> {{min(i, j), max(i, j)}, w} end)

  matching
  |> Enum.map(fn {a, b} -> Map.get(lookup, {min(a, b), max(a, b)}, 0) end)
  |> Enum.sum()
  |> div(2)
end

results =
  Enum.map(graphs, fn {seed, n, edges} ->
    matching = Ainalrami.WeightedMatching.solve(n, edges)
    {seed, matching, weight_of.(edges, matching), map_size(matching)}
  end)

case mode do
  "record" ->
    File.write!(path, :erlang.term_to_binary(results))
    IO.puts("recorded #{length(results)} matchings to #{path}")

  "verify" ->
    unless File.exists?(path) do
      IO.puts("no baseline at #{path} -- run `record` first")
      System.halt(1)
    end

    expected = path |> File.read!() |> :erlang.binary_to_term()
    pairs = Enum.zip(expected, results)

    worse =
      Enum.filter(pairs, fn {{_, _, w1, _}, {_, _, w2, _}} -> w2 != w1 end)

    differing_size =
      Enum.filter(pairs, fn {{_, _, _, s1}, {_, _, _, s2}} -> s1 != s2 end)

    not_identical =
      Enum.filter(pairs, fn {{_, m1, _, _}, {_, m2, _, _}} -> m1 != m2 end)

    IO.puts("compared #{length(results)} matchings")
    IO.puts("  same total weight:  #{length(results) - length(worse)}/#{length(results)}")
    IO.puts("  same matched count: #{length(results) - length(differing_size)}/#{length(results)}")
    IO.puts("  byte-identical:     #{length(results) - length(not_identical)}/#{length(results)}")

    cond do
      worse != [] ->
        IO.puts("\nNOT OPTIMAL -- total weight changed:")

        for {{seed, _, w1, _}, {_, _, w2, _}} <- Enum.take(worse, 5) do
          IO.puts("  seed #{seed}: #{w1} -> #{w2}")
        end

        System.halt(1)

      differing_size != [] ->
        IO.puts("\nMATCHED A DIFFERENT NUMBER OF VERTICES:")

        for {{seed, _, _, s1}, {_, _, _, s2}} <- Enum.take(differing_size, 5) do
          IO.puts("  seed #{seed}: #{s1} -> #{s2}")
        end

        System.halt(1)

      not_identical != [] ->
        IO.puts("\nOPTIMAL, but a different matching of the same weight in " <>
                  "#{length(not_identical)} case(s) -- expected when the optimum is not unique.")

      true ->
        IO.puts("\nIDENTICAL")
    end
end
