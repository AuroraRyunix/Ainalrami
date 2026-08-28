# ADVERSARIAL colour probe, part three: `arrival_numbers_at/2`.
#
# `infer_initial_colour/1` needs the numbering as it stood in the round the
# observed colour was RECORDED in, and that round's PAIRING POOL is not
# recoverable from the file. The implementation drops the pool clause and
# keeps only "participated in the pairing of some round up to and including
# this one", on the argument that everyone who entered a pool left it with
# either an opponent or the `U` bye, and both of those participate.
#
# These positions attack that collapse directly. Each has NO `152` line, so
# the whole round's colours hinge on the inference; each puts one player of
# a contested kind in the round the first colour appears in; and in each the
# two candidate numberings give OPPOSITE initial colours, so a shared board
# is a readout rather than a coincidence.
#
#   BBPPAIRINGS_EXE=../openpairings/priv/bbppairings/bbpPairings-windows.exe \
#     MIX_ENV=test mix run tools/adv_colour_probe3.exs

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

results = :ets.new(:res3, [:public, :duplicate_bag])

run = fn name, players, opts ->
  rounds = opts[:rounds] || 9
  patch = opts[:patch]

  trf =
    Ainalrami.Trf.serialize(%{
      tournament: %{
        name: String.slice(name, 0, 40),
        type: "swiss",
        number_of_rounds: rounds,
        initial_colour: opts[:initial_colour]
      },
      players: players
    })

  trf = if patch, do: patch.(trf), else: trf

  slug = name |> String.replace(~r/[^a-zA-Z0-9]+/, "_") |> String.slice(0, 44)
  path = Path.join(System.tmp_dir!(), "adv3_#{slug}.trf")
  out = Path.join(System.tmp_dir!(), "adv3_#{slug}_out.txt")
  File.write!(path, trf)

  IO.puts("\n" <> String.duplicate("=", 78))
  IO.puts(name)

  IO.puts(
    "  field: " <>
      Enum.map_join(opts[:ours] || players, "  ", fn p ->
        hist =
          Enum.map_join(p.games, ",", fn gm ->
            code = if gm.result == "", do: ".", else: gm.result
            if gm.opponent_rank, do: "#{gm.opponent_rank}#{gm.colour}#{code}", else: code
          end)

        "#{p.rank}[#{hist}]"
      end)
  )

  ours =
    try do
      Ainalrami.Pairing.pair_next_round(opts[:ours] || players,
        expected_rounds: rounds
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

# ---------------------------------------------------------------------------
# The shape. Round one is the round the first colour appears in: ranks 2 and
# 3 play it, and rank 1 carries the entry under test. Everyone else sat it
# out on a Z, and round two - which is what gets paired - has the whole field
# in the pool.
#
# If rank 1 is counted at round one, rank 2 is number 2 (EVEN, so it held the
# opposite of the initial colour); if rank 1 is not counted, rank 2 is number
# 1 (ODD, so its colour IS the initial colour). The two readings therefore
# infer opposite initial colours and every board in round two flips.
# ---------------------------------------------------------------------------

field = fn r1_of_rank1, white ->
  Enum.map(1..13, fn r ->
    cond do
      r == 1 -> player.(r, [r1_of_rank1])
      r == 2 -> player.(r, [g.(3, if(white == 2, do: "w", else: "b"), "=")])
      r == 3 -> player.(r, [g.(2, if(white == 3, do: "w", else: "b"), "=")])
      true -> player.(r, [z])
    end
  end)
end

for {label, entry} <- [
      {"U (pairing-allocated bye - WAS in round one's pool)", u},
      {"F (full-point bye - not in the pool, but scores 1.0)", fb},
      {"H (half-point bye)", hb},
      {"Z (zero-point bye)", z},
      {"blank (never arrived)", blank}
    ],
    white <- [2, 3] do
  run.(
    "J rank 1 round one = #{label}, #{white} white",
    field.(entry, white),
    initial_colour: nil
  )
end

# Rank 1 forfeits round one against a real opponent (rank 4). A real opponent
# is the one thing that makes a `-` count, so rank 1 IS numbered at round one
# - and so is rank 4, which shifts rank 2 by two rather than one. Rank 2
# therefore keeps its parity, which makes this the CONTROL: it must agree
# whichever way the collapse falls.
for white <- [2, 3] do
  run.(
    "J rank 1 round one = forfeit loss vs rank 4 (control, even shift), #{white} white",
    Enum.map(1..13, fn r ->
      cond do
        r == 1 -> player.(r, [g.(4, "w", "-")])
        r == 4 -> player.(r, [g.(1, "b", "+")])
        r == 2 -> player.(r, [g.(3, if(white == 2, do: "w", else: "b"), "=")])
        r == 3 -> player.(r, [g.(2, if(white == 3, do: "w", else: "b"), "=")])
        true -> player.(r, [z])
      end
    end),
    initial_colour: nil
  )
end

# The same, but the forfeiting pair is ranks 12 and 13 - BELOW the observed
# colour, so they cannot shift rank 2 at all, and rank 1 alone carries the
# odd shift. Rank 1's `0000 - -` is patched in: it is the one entry that was
# in round one's pool by the pool clause and is rejected by the participation
# clause, which is precisely where the collapse is being asserted.
for white <- [2, 3] do
  run.(
    "J rank 1 round one = 0000 - - (patched), #{white} white",
    Enum.map(1..13, fn r ->
      cond do
        r == 1 -> player.(r, [z])
        r == 2 -> player.(r, [g.(3, if(white == 2, do: "w", else: "b"), "=")])
        r == 3 -> player.(r, [g.(2, if(white == 3, do: "w", else: "b"), "=")])
        true -> player.(r, [z])
      end
    end),
    initial_colour: nil,
    ours:
      Enum.map(1..13, fn r ->
        cond do
          r == 1 -> player.(r, [%{opponent_rank: nil, colour: nil, result: "-"}])
          r == 2 -> player.(r, [g.(3, if(white == 2, do: "w", else: "b"), "=")])
          r == 3 -> player.(r, [g.(2, if(white == 3, do: "w", else: "b"), "=")])
          true -> player.(r, [z])
        end
      end),
    patch: fn trf ->
      trf
      |> String.split(~r/\r?\n/)
      |> Enum.map(fn l ->
        if String.starts_with?(l, "001    1 "),
          do: String.replace(l, "0000 - Z", "0000 - -", global: false),
          else: l
      end)
      |> Enum.join("\r\n")
    end
  )
end

IO.puts("\n" <> String.duplicate("#", 78))

for tag <- [:colour, :board_mismatch, :raised, :bbp_refused] do
  rows = :ets.lookup(results, tag) |> Enum.map(&elem(&1, 1))
  IO.puts("\n#{tag}: #{length(rows)}")
  Enum.each(rows, &IO.puts("   - #{&1}"))
end
