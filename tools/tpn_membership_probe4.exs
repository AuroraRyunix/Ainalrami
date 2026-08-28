# Part four of the "what does PAIRED mean?" probe (see tpn_membership_probe.exs
# for the method and the controls).
#
# Part three's scenario 10 could not be read: `0000 - +` needs a score of 1.0
# to pass bbpPairings' own score check, so it was rejected before it reached
# the numbering. Here T is written as a `U` bye (also 1.0) and the code is
# patched to `+` on the way out, so the file passes the check and the ONLY
# difference from part one's scenario 2 - which came out COUNTED - is that
# one character.
#
#   BBPPAIRINGS_EXE=../openpairings/priv/bbppairings/bbpPairings-windows.exe \
#     MIX_ENV=test mix run tools/tpn_membership_probe4.exs

exe =
  System.get_env("BBPPAIRINGS_EXE", "../openpairings/priv/bbppairings/bbpPairings-windows.exe")

u = %{opponent_rank: nil, colour: nil, result: "U"}
z = %{opponent_rank: nil, colour: nil, result: "Z"}

player = fn rank, games, pts ->
  %{
    rank: rank,
    name: "P#{rank}",
    sex: "",
    title: "",
    federation: "",
    fide_rating: 2400 - rank * 10,
    fide_number: nil,
    birth_date: "",
    points: pts,
    games: games
  }
end

for {label, from, to} <- [
      {"0000 - U (control, part one said COUNTED)", "0000 - U", "0000 - U"},
      {"0000 - + forfeit win with no opponent", "0000 - U", "0000 - +"}
    ] do
  players = [player.(1, [u, z], 1.0)] ++ for(r <- 2..13, do: player.(r, [z], 0.0))

  trf =
    Ainalrami.Trf.serialize(%{
      tournament: %{name: "p4", type: "swiss", number_of_rounds: 9, initial_colour: "w"},
      players: players
    })
    |> String.split(~r/\r?\n/)
    |> Enum.map(fn l ->
      if String.starts_with?(l, "001    1 "),
        do: String.replace(l, from, to, global: false),
        else: l
    end)
    |> Enum.join("\n")

  path = Path.join(System.tmp_dir!(), "p4.trf")
  out = Path.join(System.tmp_dir!(), "p4_out.txt")
  File.write!(path, trf)
  IO.puts("\n=== #{label}")
  IO.puts("T's line: " <> (trf |> String.split(~r/\r?\n/) |> Enum.at(6) |> String.slice(78, 40)))

  case System.cmd(exe, ["--dutch", path, "-p", out], stderr_to_stdout: true) do
    {_, 0} ->
      pairs =
        out
        |> File.read!()
        |> String.split(~r/\r?\n/)
        |> Enum.reject(&(String.trim(&1) == ""))
        |> tl()
        |> Enum.map(fn l ->
          [w, b] = l |> String.trim() |> String.split(~r/\s+/)
          {String.to_integer(w), String.to_integer(b)}
        end)

      IO.puts("pairs: #{inspect(pairs)}")

      v =
        for {w, b} <- pairs, b != 0, w != 1, b != 1 do
          top = min(w, b)
          inc = if rem(top, 2) == 1, do: top, else: max(w, b)
          if w == inc, do: :included, else: :excluded
        end

      IO.puts("boards: #{inspect(Enum.frequencies(v))}  ->  #{inspect(Enum.uniq(v))}")

    {msg, code} ->
      IO.puts("bbp failed (#{code}): #{String.trim(msg)}")
  end
end
