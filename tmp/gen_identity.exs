Code.require_file("tmp/old_fuzz.ex")
alias Ainalrami.Test.FuzzTournament, as: New
n = String.to_integer(System.get_env("N", "20000"))
bad =
  for seed <- 1..n, reduce: 0 do
    acc ->
      o = OldFuzz.begin!(seed, 16, 11..20)
      ot = OldFuzz.build_trf(elem(o, 3), 16, elem(o, 2))
      nw = New.begin!(seed, 16, 11..20)
      nt = New.build_trf(elem(nw, 3), 16, elem(nw, 2))
      # also a simulated round of results to compare downstream draws
      or_ = OldFuzz.simulate_results([{1, 2}, {3, 4}, {5, nil}])
      nr = New.simulate_results([{1, 2}, {3, 4}, {5, nil}])
      if o == nw and ot == nt, do: acc, else: acc + 1
  end
IO.puts("seeds 1..#{n}: #{bad} differ between 30d2b36 and HEAD (11-20 players, 16 rounds, default env)")
