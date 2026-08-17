# Late entrants: players admitted after round one (C.04.2 Art. 2.4).
#
# Their early rounds are BLANK -- not a bye, not a forfeit, no entry at all
# -- which is a shape no fuzz axis has ever generated. It touches
# rounds_played/1, float history and score reconciliation at once, so
# whether the two engines read such a file the same way is worth knowing
# before building an axis around it.
#
#   mix run tools/late_entrant_probe.exs

exe = System.get_env("BBPPAIRINGS_EXE", "../openpairings/priv/bbppairings/bbpPairings-windows.exe")

blank = %{opponent_rank: nil, colour: nil, result: ""}

# Round 1: only 1-8 are present. Round 2: everyone, including the two who
# arrived late. All draws, so the field stays compact and nothing separates
# on score except the rounds the latecomers missed.
round1 = [{1, 5}, {2, 6}, {3, 7}, {4, 8}]
round2 = [{1, 9}, {2, 10}, {3, 4}, {5, 6}, {7, 8}]

game = fn opponent, colour -> %{opponent_rank: opponent, colour: colour, result: "="} end

histories =
  Enum.reduce(round1, %{}, fn {w, b}, acc ->
    acc |> Map.put(w, [game.(b, "w")]) |> Map.put(b, [game.(w, "b")])
  end)

histories = Map.put(histories, 9, [blank]) |> Map.put(10, [blank])

histories =
  Enum.reduce(round2, histories, fn {w, b}, acc ->
    acc
    |> Map.update!(w, &(&1 ++ [game.(b, "b")]))
    |> Map.update!(b, &(&1 ++ [game.(w, "w")]))
  end)

players =
  for rank <- 1..10 do
    games = Map.fetch!(histories, rank)
    played = Enum.count(games, &(&1.result == "="))

    %{
      rank: rank,
      name: "Player #{rank}",
      sex: "",
      title: "",
      fide_rating: 2400 - rank * 10,
      federation: "",
      fide_number: nil,
      birth_date: "",
      points: played * 0.5,
      games: games
    }
  end

IO.puts("scores: #{Enum.map_join(players, " ", &"#{&1.rank}=#{&1.points}")}")
IO.puts("late entrants (blank round 1): 9, 10\n")

trf =
  Ainalrami.Trf.serialize(%{
    tournament: %{
      name: "Late entrants",
      type: "swiss",
      number_of_rounds: 5,
      initial_colour: "w"
    },
    players: players
  })

IO.puts("--- the two late lines, as written ---")
trf
|> String.split(~r/\r?\n/)
|> Enum.filter(&(String.starts_with?(&1, "001    9") or String.starts_with?(&1, "001   10")))
|> Enum.each(&IO.puts(inspect(&1)))

path = Path.join(System.tmp_dir!(), "late_entrant.trf")
out = Path.join(System.tmp_dir!(), "late_entrant_out.txt")
File.write!(path, trf)

# Does it survive our own round trip at all?
reparsed = Ainalrami.Trf.parse(trf)
nine = Enum.find(reparsed.players, &(&1.rank == 9))
IO.puts("\nre-parsed #9: points=#{nine.points} games=#{inspect(nine.games)}")

ours =
  try do
    Ainalrami.Pairing.pair_next_round(players, expected_rounds: 5, initial_colour: "w")
  rescue
    e -> {:raised, e}
  end

theirs =
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
      {:error, code, String.trim(msg)}
  end

normalise = fn
  {:raised, _} = r -> r
  {:error, _, _} = e -> e
  pairs -> pairs |> Enum.map(fn {a, b} -> Enum.sort([a, b || 0]) end) |> Enum.sort()
end

IO.puts("\nours:   #{inspect(normalise.(ours))}")
IO.puts("theirs: #{inspect(normalise.(theirs))}")

IO.puts(
  if normalise.(ours) == normalise.(theirs) do
    "\nAGREE"
  else
    "\nDISAGREE — worth building an axis around"
  end
)
