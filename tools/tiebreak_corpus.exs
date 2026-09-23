# Writes generated tournaments for tools/tiebreak_compare.exs.
#
#     mix run tools/tiebreak_corpus.exs DIR COUNT [FIRST_SEED]
#
# Each file is one Ainalrami.Generator tournament with its seed in the name.
# The mix leans on what Article 16 is about: forfeits, requested byes
# (half- and zero-point, some of them trailing - the 16.2.5 case), odd
# fields (pairing-allocated byes), and short events where one unplayed round
# weighs a lot. Plain tournaments are in there too.
#
# Half the tournaments also use the generator's checklist axes (VCL4THP
# Q24-Q32): full-point byes, forfeit wins and double forfeits at separate
# rates, unusual over-the-board results (1/2-0, 0-0), and results drawn from
# the FIDE rating table over stepped ratings.

[dir, count | rest] = System.argv()
count = String.to_integer(count)
first = case rest, do: ([seed] -> String.to_integer(seed); [] -> 1)

File.mkdir_p!(dir)

for seed <- first..(first + count - 1) do
  :rand.seed(:exsss, {seed, seed * 3 + 1, seed * 7 + 5})

  base = [
    seed: seed,
    players: Enum.random(5..40),
    rounds: Enum.random(3..11),
    forfeit_pct: Enum.random([0, 0, 3, 8, 15]),
    requested_bye_pct: Enum.random([0, 0, 5, 10, 20])
  ]

  checklist =
    if rem(seed, 2) == 0 do
      [
        full_bye_pct: Enum.random([0, 0, 3, 8]),
        half_bye_pct: Enum.random([0, 5, 10]),
        zero_bye_pct: Enum.random([0, 3, 8]),
        forfeit_win_pct: Enum.random([0, 3, 8]),
        double_forfeit_pct: Enum.random([0, 2, 5]),
        odd_results_pct: Enum.random([0, 2, 5]),
        results: Enum.random([:uniform, :fide]),
        ratings: {:step, Enum.random(2000..2700), Enum.random(5..40)}
      ]
    else
      []
    end

  {text, _seed} = Ainalrami.Generator.generate(base ++ checklist)
  File.write!(Path.join(dir, "g#{seed}.trf"), text)
end

IO.puts("wrote #{count} tournaments to #{dir}")
