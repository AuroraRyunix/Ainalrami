# ADVERSARIAL colour probe. Hand-built positions run through BOTH this
# engine and the real bbpPairings binary, diffing the COLOUR on every board
# the two agree on the composition of.
#
#   BBPPAIRINGS_EXE=../openpairings/priv/bbppairings/bbpPairings-windows.exe \
#     MIX_ENV=test mix run tools/adv_colour_probe.exs
#
# Read-only: it touches nothing under lib/ or test/.

exe = System.get_env("BBPPAIRINGS_EXE", "../openpairings/priv/bbppairings/bbpPairings-windows.exe")

z = %{opponent_rank: nil, colour: nil, result: "Z"}
hb = %{opponent_rank: nil, colour: nil, result: "H"}
fb = %{opponent_rank: nil, colour: nil, result: "F"}
u = %{opponent_rank: nil, colour: nil, result: "U"}
blank = %{opponent_rank: nil, colour: nil, result: ""}
g = fn opp, colour, result -> %{opponent_rank: opp, colour: colour, result: result} end

score_of = fn games ->
  Enum.reduce(games, 0.0, fn gm, acc ->
    acc +
      cond do
        gm.result in ~w(1 + U F W) -> 1.0
        gm.result in ~w(= H D) -> 0.5
        true -> 0.0
      end
  end)
end

player = fn rank, games ->
  %{
    rank: rank,
    name: "P#{rank}",
    sex: "",
    title: "",
    federation: "",
    fide_rating: 2400 - rank * 10,
    fide_number: nil,
    birth_date: "",
    points: score_of.(games),
    games: games
  }
end

pairs_of = fn text ->
  text
  |> String.split(~r/\r?\n/)
  |> Enum.reject(&(String.trim(&1) == ""))
  |> tl()
  |> Enum.map(fn l ->
    [w, b] = l |> String.trim() |> String.split(~r/\s+/)
    {String.to_integer(w), String.to_integer(b)}
  end)
end

results = :ets.new(:results, [:public, :bag])

run = fn name, players, opts ->
  rounds = opts[:rounds] || 9
  ic = opts[:initial_colour]

  trf =
    Ainalrami.Trf.serialize(%{
      tournament: %{
        name: String.slice(name, 0, 40),
        type: "swiss",
        number_of_rounds: rounds,
        initial_colour: ic
      },
      players: players
    })

  slug = name |> String.replace(~r/[^a-zA-Z0-9]+/, "_") |> String.slice(0, 40)
  path = Path.join(System.tmp_dir!(), "adv_#{slug}.trf")
  out = Path.join(System.tmp_dir!(), "adv_#{slug}_out.txt")
  File.write!(path, trf)

  IO.puts("\n" <> String.duplicate("=", 78))
  IO.puts(name)
  IO.puts("  152: #{inspect(ic)}   rounds: #{rounds}")

  IO.puts(
    "  field: " <>
      Enum.map_join(players, "  ", fn p ->
        hist =
          Enum.map_join(p.games, ",", fn gm ->
            code = if gm.result == "", do: ".", else: gm.result
            if gm.opponent_rank, do: "#{gm.opponent_rank}#{gm.colour}#{code}", else: code
          end)

        "#{p.rank}[#{hist}]=#{p.points}"
      end)
  )

  ours =
    try do
      Ainalrami.Pairing.pair_next_round(
        players,
        [expected_rounds: rounds] ++ if(ic, do: [initial_colour: ic], else: [])
      )
    rescue
      e -> {:error, Exception.message(e)}
    end

  bbp =
    case System.cmd(exe, ["--dutch", path, "-p", out], stderr_to_stdout: true) do
      {_, 0} -> pairs_of.(File.read!(out))
      {msg, code} -> {:error, "exit #{code}: #{String.slice(String.trim(msg), 0, 120)}"}
    end

  case {ours, bbp} do
    {{:error, m}, _} ->
      IO.puts("  OURS RAISED: #{m}")
      :ets.insert(results, {:raised, name})

    {_, {:error, m}} ->
      IO.puts("  bbp: #{m}")
      IO.puts("  ours: #{inspect(ours)}")
      :ets.insert(results, {:bbp_refused, name})

    _ ->
      board = fn ps ->
        for {w, b} <- ps, b != nil, b != 0, into: %{}, do: {Enum.sort([w, b]), w}
      end

      o = board.(ours)
      b = board.(bbp)
      shared = o |> Map.keys() |> Enum.filter(&Map.has_key?(b, &1)) |> Enum.sort()
      disagree = Enum.filter(shared, &(Map.get(o, &1) != Map.get(b, &1)))

      only_ours = (Map.keys(o) -- Map.keys(b)) |> Enum.sort()
      only_bbp = (Map.keys(b) -- Map.keys(o)) |> Enum.sort()

      IO.puts("  ours: #{inspect(Enum.sort(ours))}")
      IO.puts("  bbp : #{inspect(Enum.sort(bbp))}")

      if only_ours != [] or only_bbp != [] do
        IO.puts("  BOARD MISMATCH  only-ours=#{inspect(only_ours)} only-bbp=#{inspect(only_bbp)}")
        :ets.insert(results, {:board_mismatch, name})
      end

      if disagree == [] do
        IO.puts("  colour: #{length(shared)}/#{length(shared)} shared boards agree")
      else
        Enum.each(disagree, fn brd ->
          IO.puts(
            "  *** COLOUR DISAGREEMENT on #{inspect(brd)}: ours white=#{Map.get(o, brd)}," <>
              " bbp white=#{Map.get(b, brd)}"
          )
        end)

        :ets.insert(results, {:colour, "#{name} :: #{inspect(disagree)}"})
      end
  end
end

# ===========================================================================
# GROUP A - round one, the baseline and the 152 B mirror
# ===========================================================================

for {n, ic} <- [{8, "w"}, {9, "w"}, {8, "b"}, {9, "b"}, {13, "b"}, {7, "w"}] do
  run.(
    "A #{n} players, round one, 152 #{String.upcase(ic)}",
    for(r <- 1..n, do: player.(r, [])),
    initial_colour: ic
  )
end

# No 152 line at all. Round one has no colours anywhere to infer from, so
# both engines are on their own default.
run.("A no-152 round one, 8 players", for(r <- 1..8, do: player.(r, [])), initial_colour: nil)

# ===========================================================================
# GROUP B - round ONE with a pre-marked absence. Exactly ONE player carries a
# round-one marker; everybody else has a wholly empty history. An even number
# of skipped players preserves parity and would prove nothing.
# ===========================================================================

for {code, marker} <- [{"Z", z}, {"H", hb}, {"F", fb}, {"blank", blank}],
    at <- [1, 5],
    ic <- ["w", "b"] do
  players =
    for r <- 1..9 do
      if r == at, do: player.(r, [marker]), else: player.(r, [])
    end

  run.(
    "B round one, rank #{at} pre-marked #{code}, 152 #{String.upcase(ic)}",
    players,
    initial_colour: ic
  )
end

# ===========================================================================
# GROUP C - round TWO, one player of uncertain arrival status, both 152s.
# Everyone else sat round one out on a Z, so every board is bye-only and
# 5.2.5 decides it. Ranks 12/13 play each other in round one so that the
# round under computation really is round two; they carry a colour history
# and their own boards are not 5.2.5 boards, but they ARE arrivals and both
# engines must agree about that.
# ===========================================================================

c_field = fn t_games ->
  [player.(1, t_games)] ++
    for(r <- 2..11, do: player.(r, [z])) ++
    [player.(12, [g.(13, "w", "=")]), player.(13, [g.(12, "b", "=")])]
end

for {label, t_games} <- [
      {"played r1, out r2", [g.(2, "w", "="), z]},
      {"Z r1, out r2", [z, z]},
      {"H r1, out r2", [hb, z]},
      {"F r1, out r2", [fb, z]},
      {"U r1, out r2", [u, z]},
      {"forfeit win vs 2, out r2", [g.(2, "w", "+"), z]},
      {"forfeit loss vs 2, out r2", [g.(2, "w", "-"), z]},
      {"blank r1, out r2", [blank, z]},
      {"blank r1, IN r2", [blank]},
      {"Z r1, IN r2", [z]}
    ],
    ic <- ["w", "b"] do
  players =
    case label do
      "forfeit win vs 2, out r2" ->
        [player.(1, t_games), player.(2, [g.(1, "b", "-"), z])] ++
          for(r <- 3..11, do: player.(r, [z])) ++
          [player.(12, [g.(13, "w", "=")]), player.(13, [g.(12, "b", "=")])]

      "forfeit loss vs 2, out r2" ->
        [player.(1, t_games), player.(2, [g.(1, "b", "+"), z])] ++
          for(r <- 3..11, do: player.(r, [z])) ++
          [player.(12, [g.(13, "w", "=")]), player.(13, [g.(12, "b", "=")])]

      "played r1, out r2" ->
        [player.(1, t_games), player.(2, [g.(1, "b", "="), z])] ++
          for(r <- 3..11, do: player.(r, [z])) ++
          [player.(12, [g.(13, "w", "=")]), player.(13, [g.(12, "b", "=")])]

      _ ->
        c_field.(t_games)
    end

  run.("C round two, rank 1 = #{label}, 152 #{String.upcase(ic)}", players, initial_colour: ic)
end

# ===========================================================================
# GROUP D - round THREE and FOUR. Arrivals accumulate, so the numbering has
# to be rebuilt per round rather than once.
# ===========================================================================

# Rank 1 arrives in round 2 (blank round one), then sits round three out.
# Ranks 12/13 keep the round counter moving.
run.(
  "D round three, rank 1 arrived in r2 then sat out",
  [player.(1, [blank, u, z])] ++
    for(r <- 2..11, do: player.(r, [z, z])) ++
    [
      player.(12, [g.(13, "w", "="), g.(13, "b", "="), z]),
      player.(13, [g.(12, "b", "="), g.(12, "w", "="), z])
    ],
  initial_colour: "w"
)

run.(
  "D round three, rank 1 blank r1 AND r2 (still not arrived)",
  [player.(1, [blank, blank, z])] ++
    for(r <- 2..11, do: player.(r, [z, z])) ++
    [
      player.(12, [g.(13, "w", "="), g.(13, "b", "="), z]),
      player.(13, [g.(12, "b", "="), g.(12, "w", "="), z])
    ],
  initial_colour: "w"
)

run.(
  "D round four, rank 1 arrived r3 (H,H then a real forfeit) then out",
  [player.(1, [hb, hb, g.(2, "w", "-"), z])] ++
    [player.(2, [z, z, g.(1, "b", "+"), z])] ++
    for(r <- 3..11, do: player.(r, [z, z, z])) ++
    [
      player.(12, [g.(13, "w", "="), g.(13, "b", "="), g.(13, "w", "="), z]),
      player.(13, [g.(12, "b", "="), g.(12, "w", "="), g.(12, "b", "="), z])
    ],
  initial_colour: "b"
)

# ===========================================================================
# GROUP E - the numbering feeding a board whose "higher ranked" player by
# Article 1.2 is NOT the lower starting rank. Rank 1 carries an F bye (1.0)
# and is therefore top of its board by score while ranked below on TPN.
# Ranks 2..N are on nought. An F bye does not count as an arrival, so rank 1
# is numbered only because it is in THIS round's pool.
# ===========================================================================

run.(
  "E score-group top vs rank top, F-bye leader, 152 W",
  [player.(1, [fb, z]), player.(2, [z, fb])] ++
    for(r <- 3..11, do: player.(r, [z])) ++
    [player.(12, [g.(13, "w", "=")]), player.(13, [g.(12, "b", "=")])],
  initial_colour: "w"
)

# ===========================================================================
# GROUP F - no 152 line, in a position where the numbering is NOT the
# identity, so `infer_initial_colour/1` and the allocation must be inverting
# the same number. Round one is played by only part of the field.
# ===========================================================================

# Round one: 12 and 13 play (they are arrivals 1 and 2 in round one's own
# numbering, since nobody else participated). Ranks 1..11 sat it out on Z.
# Round two is under computation and everyone is in the pool.
run.(
  "F no 152, r1 played by ranks 12/13 only, round two under computation",
  for(r <- 1..11, do: player.(r, [z])) ++
    [player.(12, [g.(13, "w", "=")]), player.(13, [g.(12, "b", "=")])],
  initial_colour: nil
)

# The same, one rank shifted so the inferred colour flips if the two sides
# disagree about which number to invert.
run.(
  "F no 152, r1 played by ranks 11/13 only",
  for(r <- 1..10, do: player.(r, [z])) ++
    [
      player.(11, [g.(13, "w", "=")]),
      player.(12, [z]),
      player.(13, [g.(11, "b", "=")])
    ],
  initial_colour: nil
)

# Round one played by ranks 2 and 3 only, with rank 1 never arriving. Under
# the arrival numbering rank 2 is number 1; under the overturned TPN reading
# it is number 2, so the inferred initial colour is the opposite.
run.(
  "F no 152, r1 played by ranks 2/3 only, rank 1 never arrives",
  [player.(1, [z, z])] ++
    [player.(2, [g.(3, "w", "="), z]), player.(3, [g.(2, "b", "="), z])] ++
    for(r <- 4..13, do: player.(r, [z])),
  initial_colour: nil
)

# ===========================================================================
# Summary
# ===========================================================================

IO.puts("\n" <> String.duplicate("#", 78))

for tag <- [:colour, :board_mismatch, :raised, :bbp_refused] do
  rows = :ets.lookup(results, tag) |> Enum.map(&elem(&1, 1))
  IO.puts("\n#{tag}: #{length(rows)}")
  Enum.each(rows, &IO.puts("   - #{&1}"))
end
