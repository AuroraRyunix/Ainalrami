alias Ainalrami.Test.FuzzTournament
counts =
  for seed <- 1..80_000, reduce: %{} do
    acc ->
      {_r, n, _f, _roster} = FuzzTournament.begin!(seed, 16, 11..20)
      Map.update(acc, n, 1, &(&1 + 1))
  end
IO.inspect(Enum.sort(counts))
le16 = for {n, c} <- counts, n <= 16, reduce: 0, do: (acc -> acc + c)
IO.puts("N<=16: #{le16} of 80000 (#{Float.round(le16 / 800, 2)}%)")
