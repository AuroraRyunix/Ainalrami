# ADVERSARIAL colour probe, part two: the seams part one could not reach.
#
#   G  no `152` at all - `infer_initial_colour/1` must invert the SAME
#      number the allocation used, and it must use the numbering as of the
#      round the observed colour was RECORDED in, not the current one.
#   H  round one driven through the LATER-round path (a forbidden pair, or
#      acceleration), which bypasses `pair_round_one/1` and its locally
#      built numbering entirely.
#   I  the two membership spellings `Ainalrami.Trf.serialize/1` refuses to
#      write and which parts one-to-three left WITHOUT a verdict:
#      `0000 - +` and a real opponent carrying a bye code.
#
#   BBPPAIRINGS_EXE=../openpairings/priv/bbppairings/bbpPairings-windows.exe \
#     MIX_ENV=test mix run tools/adv_colour_probe2.exs

exe = System.get_env("BBPPAIRINGS_EXE", "../openpairings/priv/bbppairings/bbpPairings-windows.exe")

z = %{opponent_rank: nil, colour: nil, result: "Z"}
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
    fide_rating: 2400 - rank * 7,
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

results = :ets.new(:res2, [:public, :duplicate_bag])

run = fn name, players, opts ->
  rounds = opts[:rounds] || 9
  ic = opts[:initial_colour]
  patch = opts[:patch]

  trf =
    Ainalrami.Trf.serialize(
      %{
        tournament: %{
          name: String.slice(name, 0, 40),
          type: "swiss",
          number_of_rounds: rounds,
          initial_colour: ic,
          forbidden_pairs: opts[:forbidden_pairs]
        },
        players: players
      },
      numeric_extensions: false
    )

  trf = if patch, do: patch.(trf), else: trf

  slug = name |> String.replace(~r/[^a-zA-Z0-9]+/, "_") |> String.slice(0, 40)
  path = Path.join(System.tmp_dir!(), "adv2_#{slug}.trf")
  out = Path.join(System.tmp_dir!(), "adv2_#{slug}_out.txt")
  File.write!(path, trf)

  IO.puts("\n" <> String.duplicate("=", 78))
  IO.puts(name)

  IO.puts(
    "  field: " <>
      Enum.map_join(players, "  ", fn p ->
        hist =
          Enum.map_join(p.games, ",", fn gm ->
            code = if gm.result == "", do: ".", else: gm.result
            if gm.opponent_rank, do: "#{gm.opponent_rank}#{gm.colour}#{code}", else: code
          end)

        "#{p.rank}[#{hist}]"
      end)
  )

  # When the file was patched, hand our engine the PATCHED file too - parsed
  # back - so both sides are reading the same thing.
  ours_players =
    if patch do
      case Ainalrami.Trf.parse(trf) do
        {:ok, %{players: parsed}} -> parsed
        %{players: parsed} -> parsed
        other -> raise "parse failed: #{inspect(other)}"
      end
    else
      players
    end

  ours =
    try do
      Ainalrami.Pairing.pair_next_round(
        ours_players,
        [expected_rounds: rounds] ++
          if(ic, do: [initial_colour: ic], else: []) ++
          if(opts[:forbidden_pairs], do: [forbidden_pairs: opts[:forbidden_pairs]], else: [])
      )
    rescue
      e -> {:error, Exception.message(e)}
    end

  bbp =
    case System.cmd(exe, ["--dutch", path, "-p", out], stderr_to_stdout: true) do
      {_, 0} -> pairs_of.(File.read!(out))
      {msg, code} -> {:error, "exit #{code}: #{String.slice(String.trim(msg), 0, 140)}"}
    end

  case {ours, bbp} do
    {{:error, m}, _} ->
      IO.puts("  OURS RAISED: #{m}")
      :ets.insert(results, {:raised, name})

    {_, {:error, m}} ->
      IO.puts("  bbp refused: #{m}")
      IO.puts("  ours: #{inspect(Enum.sort(ours))}")
      :ets.insert(results, {:bbp_refused, name})

    _ ->
      board = fn ps -> for {w, b} <- ps, b != nil, b != 0, into: %{}, do: {Enum.sort([w, b]), w} end
      o = board.(ours)
      b = board.(bbp)
      shared = o |> Map.keys() |> Enum.filter(&Map.has_key?(b, &1)) |> Enum.sort()
      bad = Enum.filter(shared, &(Map.get(o, &1) != Map.get(b, &1)))

      IO.puts("  ours: #{inspect(Enum.sort(ours))}")
      IO.puts("  bbp : #{inspect(Enum.sort(bbp))}")

      if Map.keys(o) != Map.keys(b) do
        IO.puts(
          "  BOARD MISMATCH only-ours=#{inspect(Map.keys(o) -- Map.keys(b))}" <>
            " only-bbp=#{inspect(Map.keys(b) -- Map.keys(o))}"
        )

        :ets.insert(results, {:board_mismatch, name})
      end

      if bad == [] do
        IO.puts("  colour: all #{length(shared)} shared boards agree")
      else
        Enum.each(bad, fn brd ->
          IO.puts(
            "  *** COLOUR DISAGREEMENT #{inspect(brd)}: ours white=#{Map.get(o, brd)}," <>
              " bbp white=#{Map.get(b, brd)}   [#{path}]"
          )
        end)

        :ets.insert(results, {:colour, "#{name} #{inspect(bad)} [#{path}]"})
      end
  end
end

# ===========================================================================
# GROUP G - no 152 line. The initial colour has to be RECONSTRUCTED, and the
# reconstruction has to invert the same number the allocation uses.
# ===========================================================================
#
# G1/G2: round one is all byes, so the first colours appear in ROUND TWO,
# where only ranks 5 and 6 have arrived. Under the ruling rank 5 is number 1
# there; under the overturned TPN reading it is number 5. Both are odd, so
# these two say nothing on their own - they are the control for G3/G4.

for {white, black} <- [{5, 6}, {6, 5}] do
  run.(
    "G1 no 152, first colours in r2, ranks 5/6, #{white} white",
    Enum.map(1..13, fn r ->
      cond do
        r == white -> player.(r, [z, g.(black, "w", "=")])
        r == black -> player.(r, [z, g.(white, "b", "=")])
        true -> player.(r, [z, z])
      end
    end),
    initial_colour: nil
  )
end

# G3/G4: the first colours appear in ROUND ONE, played by ranks 4 and 5 only.
# Rank 4 is arrival number 1 under the ruling (odd -> it holds the initial
# colour) and TPN 4 under the overturned reading (even -> it holds the
# opposite). The two readings therefore infer OPPOSITE initial colours, and
# every board in the round under computation flips with them.

for {white, black} <- [{4, 5}, {5, 4}] do
  run.(
    "G3 no 152, r1 played by 4/5 only, #{white} white, round 2 under computation",
    Enum.map(1..13, fn r ->
      cond do
        r == 4 -> player.(r, [g.(5, if(white == 4, do: "w", else: "b"), "=")])
        r == 5 -> player.(r, [g.(4, if(white == 5, do: "w", else: "b"), "=")])
        true -> player.(r, [z])
      end
    end),
    initial_colour: nil
  )
end

# G5: the inference round and the current round have DIFFERENT numberings.
# Ranks 12/13 play round one; rank 1 is blank in round one and arrives in
# round two. So at round one the numbering is {12 => 1, 13 => 2} and at
# round three it is the identity over all thirteen. Reading the current
# round's numbering back into round one would be a different rule.

for {white, black} <- [{12, 13}, {13, 12}] do
  run.(
    "G5 no 152, r1 by 12/13 (#{white} white), rank 1 arrives r2, round 3 now",
    Enum.map(1..13, fn r ->
      cond do
        r == 1 -> player.(r, [blank, g.(2, "w", "="), z])
        r == 2 -> player.(r, [z, g.(1, "b", "="), z])
        r == 12 -> player.(r, [g.(13, if(white == 12, do: "w", else: "b"), "="), z, z])
        r == 13 -> player.(r, [g.(12, if(white == 13, do: "w", else: "b"), "="), z, z])
        true -> player.(r, [z, z])
      end
    end),
    initial_colour: nil
  )
end

# ===========================================================================
# GROUP H - round one NOT taken through `pair_round_one/1`.
#
# `pair_next_round/2` only takes the round-one shortcut when there is no
# forbidden pair and no acceleration. Either one routes round one through
# `pair_later_round/2` instead, where the numbering comes from the process
# key rather than from the locally built map - a completely different code
# path for the identical position.
# ===========================================================================

run.(
  "H1 round one with a forbidden pair, 9 players, 152 W",
  for(r <- 1..9, do: player.(r, [])),
  initial_colour: "w",
  forbidden_pairs: [[1, 6]]
)

run.(
  "H2 round one with a forbidden pair, 9 players, 152 B",
  for(r <- 1..9, do: player.(r, [])),
  initial_colour: "b",
  forbidden_pairs: [[1, 6]]
)

run.(
  "H3 round one, rank 1 pre-marked Z, plus a forbidden pair, 152 W",
  [player.(1, [z])] ++ for(r <- 2..10, do: player.(r, [])),
  initial_colour: "w",
  forbidden_pairs: [[2, 7]]
)

run.(
  "H4 round one, rank 1 pre-marked Z, plus a forbidden pair, 152 B",
  [player.(1, [z])] ++ for(r <- 2..10, do: player.(r, [])),
  initial_colour: "b",
  forbidden_pairs: [[2, 7]]
)

accel = fn rank, games, accels ->
  Map.put(player.(rank, games), :accelerations, accels)
end

run.(
  "H5 round one with acceleration, 10 players, 152 W",
  Enum.map(1..10, fn r -> accel.(r, [], if(r <= 5, do: [1.0], else: [0.0])) end),
  initial_colour: "w"
)

run.(
  "H6 round one with acceleration and a pre-marked Z at rank 1, 152 B",
  [accel.(1, [z], [1.0, 0.0])] ++
    Enum.map(2..11, fn r -> accel.(r, [], if(r <= 6, do: [1.0], else: [0.0])) end),
  initial_colour: "b"
)

# ===========================================================================
# GROUP I - the two membership spellings still without a verdict.
#
# Both are written as something `serialize/1` accepts and then patched on the
# way out, so the file that reaches bbpPairings is the one under test and the
# file our engine reads is the SAME patched text, parsed back.
# ===========================================================================

patch_rank1 = fn from, to ->
  fn trf ->
    trf
    |> String.split(~r/\r?\n/)
    |> Enum.map(fn l ->
      if String.starts_with?(l, "001    1 "),
        do: String.replace(l, from, to, global: false),
        else: l
    end)
    |> Enum.join("\r\n")
  end
end

i_field = fn t_games ->
  [player.(1, t_games)] ++
    for(r <- 2..11, do: player.(r, [z])) ++
    [player.(12, [g.(13, "w", "=")]), player.(13, [g.(12, "b", "=")])]
end

for ic <- ["w", "b"] do
  run.(
    "I1 rank 1 = 0000 - + (opponentless forfeit win), 152 #{String.upcase(ic)}",
    i_field.([u, z]),
    initial_colour: ic,
    patch: patch_rank1.("0000 - U", "0000 - +")
  )

  run.(
    "I2 rank 1 = 2 w Z (real opponent, bye code), 152 #{String.upcase(ic)}",
    [player.(1, [g.(2, "w", "0"), z]), player.(2, [g.(1, "b", "1"), z])] ++
      for(r <- 3..11, do: player.(r, [z])) ++
      [player.(12, [g.(13, "w", "=")]), player.(13, [g.(12, "b", "=")])],
    initial_colour: ic,
    patch: patch_rank1.("   2 w 0", "   2 w Z")
  )
end

IO.puts("\n" <> String.duplicate("#", 78))

for tag <- [:colour, :board_mismatch, :raised, :bbp_refused] do
  rows = :ets.lookup(results, tag) |> Enum.map(&elem(&1, 1))
  IO.puts("\n#{tag}: #{length(rows)}")
  Enum.each(rows, &IO.puts("   - #{&1}"))
end
