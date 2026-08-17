# What colour does each engine give the top player on each board of round 1?
#
# Article 5.1 alternates the initial colour down the initial ranking, so on a
# clean field the higher-ranked player of board 1 takes the drawn colour,
# board 2's takes the opposite, and so on. That makes round one the cleanest
# possible probe of Article 5.2.5: no player has a preference, so every board
# falls through 5.2.1-5.2.4 to the parity rule alone.
#
#   mix run tools/round_one_colours.exs [players]

n = System.argv() |> Enum.at(0, "10") |> String.to_integer()

# Ranks sitting round one out on an arbiter-assigned bye, which is how the
# fuzz harness spells one: a pre-recorded round-one game with no opponent
# and no colour. Their presence is the whole question -- a clean field
# agrees, so whatever splits the engines needs someone missing.
byes =
  System.argv()
  |> Enum.at(1, "")
  |> String.split(",", trim: true)
  |> Enum.map(&String.to_integer/1)

exe = System.get_env("BBPPAIRINGS_EXE", "../openpairings/priv/bbppairings/bbpPairings-windows.exe")

players =
  for rank <- 1..n do
    %{
      rank: rank,
      name: "Player #{rank}",
      sex: "",
      title: "",
      fide_rating: 2400 - rank * 10,
      federation: "",
      fide_number: nil,
      birth_date: "",
      points: if(rank in byes, do: 0.0, else: 0.0),
      games:
        if rank in byes do
          [%{opponent_rank: nil, colour: nil, result: "Z"}]
        else
          []
        end
    }
  end

IO.puts("field of #{n}, round-one byes: #{inspect(byes)}")

trf =
  Ainalrami.Trf.serialize(%{
    tournament: %{
      name: "Round one colours",
      number_of_players: n,
      number_of_rounds: 5,
      initial_colour: "w"
    },
    players: players
  })

path = Path.join(System.tmp_dir!(), "r1colours.trf")
out = Path.join(System.tmp_dir!(), "r1colours_out.txt")
File.write!(path, trf)

IO.puts("152 line present? #{String.contains?(trf, "152")}")
IO.puts(trf |> String.split(~r/\r?\n/) |> Enum.filter(&String.starts_with?(&1, "152")) |> inspect())

ours = Ainalrami.Pairing.pair_next_round(players, expected_rounds: 5, initial_colour: "w")

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
      IO.puts("bbpPairings failed (#{code}): #{msg}")
      []
  end

IO.puts("\n board |    ours     |    bbpPairings | top rank | top parity | agree?")
IO.puts(" ------+-------------+----------------+----------+------------+-------")

ours_sorted = Enum.sort_by(ours, fn {w, b} -> min(w, b || 9999) end)
theirs_sorted = Enum.sort_by(theirs, fn {w, b} -> min(w, b) end)

Enum.zip(ours_sorted, theirs_sorted)
|> Enum.with_index(1)
|> Enum.each(fn {{{ow, ob}, {tw, tb}}, board} ->
  top = min(ow, ob || 9999)
  parity = if rem(top, 2) == 1, do: "odd ", else: "even"
  agree = if {ow, ob} == {tw, tb}, do: "yes", else: "NO"
  ours_s = String.pad_trailing("#{ow} W, #{ob} B", 11)
  theirs_s = String.pad_trailing("#{tw} W, #{tb} B", 14)
  IO.puts("   #{String.pad_leading("#{board}", 3)} | #{ours_s} | #{theirs_s} |    #{String.pad_leading("#{top}", 5)} |    #{parity}    | #{agree}")
end)

IO.puts("""

Reading this: on a clean field Article 5.1 gives board 1's higher-ranked
player the drawn colour (White here), board 2's the opposite, and so on
down. Whichever column does that is following the regulation.
""")
