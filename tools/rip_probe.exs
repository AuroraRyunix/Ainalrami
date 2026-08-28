# Does Gacrux renumber around a player who has ALREADY PLAYED but is
# sitting this round out?
#
# ANSWERED, BY THIS SCRIPT: no - and neither does bbpPairings. Both skip
# only players who have NEVER participated. Re-confirmed 2026-08-27 against
# the local bbpPairings binary, and endorsed by the SPP on the same day.
#
# This header is kept because the hypothesis it records did real damage.
# The original read: Gacrux's condition is `rfp or rip` - ready for pairing
# now, OR paired at some point before - while "bbpPairings has no such
# clause and skips anyone not valid for the current round. If that reading
# is right the two references part company here, and Gacrux sides with this
# engine."
#
# That was a hypothesis. This probe refuted it on first run - board [2,7]
# answers 7 from every engine, the unrenumbered answer - and the refutation
# was never propagated. The hypothesis went on being quoted as a finding in
# `docs/dispute-initial-colour.md`, in this repo's README, and in the
# three-way harness, where it justified weakening a classifier. Stating a
# hypothesis in the same prose register as a result is how that happens.
#
# Round one cannot show it: nobody has played yet, so `rip` is zero for
# everyone and the two conditions coincide. This position is round two.
#
#   GACRUX_DIR=../TieBreakServer GACRUX_PYTHON=python \
#     MIX_ENV=test mix run tools/rip_probe.exs

exe = System.get_env("BBPPAIRINGS_EXE", "../openpairings/priv/bbppairings/bbpPairings-windows.exe")

g = fn opp, colour, result -> %{opponent_rank: opp, colour: colour, result: result} end
z = %{opponent_rank: nil, colour: nil, result: "Z"}

# Round 1: 1 draws 5 and 6 draws 7. Everyone else sits it out.
# Round 2: player 1 - who HAS played - sits out. Exactly one player is
# skipped, so the renumbering shifts parity for everyone below them; an
# even number skipped would preserve it and prove nothing.
players = [
  %{rank: 1, points: 0.5, games: [g.(5, "w", "="), z]},
  %{rank: 2, points: 0.0, games: [z]},
  %{rank: 3, points: 0.0, games: [z]},
  %{rank: 4, points: 0.0, games: [z]},
  %{rank: 5, points: 0.5, games: [g.(1, "b", "=")]},
  %{rank: 6, points: 0.5, games: [g.(7, "w", "=")]},
  %{rank: 7, points: 0.5, games: [g.(6, "b", "=")]},
  %{rank: 8, points: 0.0, games: [z]}
]

players =
  Enum.map(players, fn p ->
    Map.merge(p, %{
      name: "P#{p.rank}",
      sex: "",
      title: "",
      federation: "",
      fide_rating: 2400 - p.rank * 10,
      fide_number: nil,
      birth_date: ""
    })
  end)

trf =
  Ainalrami.Trf.serialize(%{
    tournament: %{
      name: "rip probe",
      type: "swiss",
      number_of_rounds: 5,
      initial_colour: "w"
    },
    players: players
  })

path = Path.join(System.tmp_dir!(), "rip_probe.trf")
out = Path.join(System.tmp_dir!(), "rip_probe_out.txt")
File.write!(path, trf)

IO.puts("round 2. Player 1 has played (round 1) and sits this round out.")
IO.puts("Never played at all: 2, 3, 4, 8 - so 5.2.5 decides any board among them.\n")

ours = Ainalrami.Pairing.pair_next_round(players, expected_rounds: 5, initial_colour: "w")

bbp =
  case System.cmd(exe, ["--dutch", path, "-p", out], stderr_to_stdout: true) do
    {_, 0} ->
      out
      |> File.read!()
      |> String.split(~r/\r?\n/)
      |> Enum.reject(&(String.trim(&1) == ""))
      |> tl()
      |> Enum.map(fn l ->
        [w, b] = l |> String.trim() |> String.split(~r/\s+/)
        {String.to_integer(w), String.to_integer(b)}
      end)

    {msg, code} ->
      IO.puts("bbpPairings failed (#{code}): #{String.slice(String.trim(msg), 0, 90)}")
      []
  end

gacrux =
  case Ainalrami.Test.Gacrux.pair(trf) do
    {:ok, pairs} -> pairs
    other -> IO.puts("gacrux: #{inspect(other)}") && []
  end

by_board = fn pairs ->
  for {w, b} <- pairs, b != nil, b != 0, into: %{}, do: {Enum.sort([w, b]), w}
end

o = by_board.(ours)
b = by_board.(bbp)
gx = by_board.(gacrux)

IO.puts(" board  | ours | bbp | gacrux | same board?")
IO.puts(" -------+------+-----+--------+------------")

(Map.keys(o) ++ Map.keys(b) ++ Map.keys(gx))
|> Enum.uniq()
|> Enum.sort()
|> Enum.each(fn board ->
  IO.puts(
    " #{String.pad_trailing(inspect(board), 6)} | #{String.pad_leading("#{Map.get(o, board, "-")}", 4)} |" <>
      " #{String.pad_leading("#{Map.get(b, board, "-")}", 3)} |" <>
      " #{String.pad_leading("#{Map.get(gx, board, "-")}", 6)} |" <>
      " #{Enum.count([o, b, gx], &Map.has_key?(&1, board))}/3"
  )
end)

shared = o |> Map.keys() |> Enum.filter(&(Map.has_key?(b, &1) and Map.has_key?(gx, &1)))

IO.puts("\non the #{length(shared)} board(s) all three formed:")
IO.puts("  ours == gacrux : #{Enum.all?(shared, &(Map.get(o, &1) == Map.get(gx, &1)))}")
IO.puts("  ours == bbp    : #{Enum.all?(shared, &(Map.get(o, &1) == Map.get(b, &1)))}")
IO.puts("  bbp  == gacrux : #{Enum.all?(shared, &(Map.get(b, &1) == Map.get(gx, &1)))}")
