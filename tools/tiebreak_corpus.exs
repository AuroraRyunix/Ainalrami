# Writes generated tournaments for tools/tiebreak_compare.exs.
#
#     mix run tools/tiebreak_corpus.exs DIR COUNT [FIRST_SEED]
#
# Each file is one Ainalrami.Generator tournament with its seed in the name.
# The mix leans on what Article 16 is about: forfeits, requested byes
# (half- and zero-point, some of them trailing - the 16.2.5 case), odd
# fields (pairing-allocated byes), and short events where one unplayed round
# weighs a lot. Plain tournaments are in there too.

[dir, count | rest] = System.argv()
count = String.to_integer(count)
first = case rest, do: ([seed] -> String.to_integer(seed); [] -> 1)

File.mkdir_p!(dir)

for seed <- first..(first + count - 1) do
  :rand.seed(:exsss, {seed, seed * 3 + 1, seed * 7 + 5})

  opts = [
    seed: seed,
    players: Enum.random(5..40),
    rounds: Enum.random(3..11),
    forfeit_pct: Enum.random([0, 0, 3, 8, 15]),
    requested_bye_pct: Enum.random([0, 0, 5, 10, 20])
  ]

  {text, _seed} = Ainalrami.Generator.generate(opts)
  File.write!(Path.join(dir, "g#{seed}.trf"), text)
end

IO.puts("wrote #{count} tournaments to #{dir}")
