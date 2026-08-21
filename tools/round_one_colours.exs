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

# Gacrux is the third implementation of the same 2026 rules. Whether it
# sides with the article or with bbpPairings on 5.2.5 is the difference
# between "one reference is wrong" and "both references renumber", and it
# is worth measuring rather than reading out of its source.
gacrux =
  case Ainalrami.Test.Gacrux.pair(trf) do
    {:ok, pairs} -> pairs
    other -> other
  end

# JaVaFo is the PRE-2026 reference. The old rule (E.5) tested the parity of
# a "pairing number", defined in A.2 as the initial ranking "and subsequent
# modifications depending on possible late entries or rating adjustments";
# the 2026 rewrite replaced that with a TPN pinned to C.04.2 Article 2. If
# JaVaFo renumbers too, the behaviour bbpPairings and Gacrux share is
# inherited from the old wording rather than invented -- which is a very
# different dispute from two engines independently misreading 5.2.5.
javafo =
  if Ainalrami.Test.Javafo.available?() do
    case Ainalrami.Test.Javafo.pair(trf) do
      {:ok, pairs} -> pairs
      other -> other
    end
  else
    IO.puts("javafo.jar not found at #{Ainalrami.Test.Javafo.jar_path()} -- skipping")
    []
  end

by_board = fn pairs ->
  case pairs do
    list when is_list(list) ->
      for {w, b} <- list, b != nil, into: %{}, do: {Enum.sort([w, b]), w}

    _ ->
      %{}
  end
end

ours_by = by_board.(ours)
theirs_by = by_board.(theirs)
gacrux_by = by_board.(gacrux)
javafo_by = by_board.(javafo)

IO.puts("\n board  | top TPN | parity | ours  | bbp   | gacrux | javafo | who follows 5.2.5?")
IO.puts(" -------+---------+--------+-------+-------+--------+--------+-------------------")

ours_by
|> Map.keys()
|> Enum.sort()
|> Enum.each(fn board ->
  [top, bottom] = board
  parity = if rem(top, 2) == 1, do: "odd ", else: "even"

  # The article: the higher ranked player takes the initial colour on an
  # odd TPN. Every player here is on zero, so the higher ranked is the
  # lower TPN.
  article_white = if rem(top, 2) == 1, do: top, else: bottom

  ow = Map.get(ours_by, board)
  tw = Map.get(theirs_by, board)
  gw = Map.get(gacrux_by, board)
  jw = Map.get(javafo_by, board)

  who =
    [{"ours", ow}, {"bbp", tw}, {"gacrux", gw}, {"javafo", jw}]
    |> Enum.filter(fn {_, w} -> w == article_white end)
    |> Enum.map_join(" ", &elem(&1, 0))

  IO.puts(
    " #{String.pad_trailing("#{top}v#{bottom}", 6)} |   #{String.pad_leading("#{top}", 5)} |  #{parity}  |" <>
      " #{String.pad_leading("#{ow}", 5)} | #{String.pad_leading("#{tw}", 5)} |" <>
      " #{String.pad_leading("#{gw}", 6)} | #{String.pad_leading("#{jw}", 6)} |" <>
      " #{if who == "", do: "NOBODY", else: who}"
  )
end)

IO.puts("""

Reading this: on a clean field Article 5.1 gives board 1's higher-ranked
player the drawn colour (White here), board 2's the opposite, and so on
down. Whichever column does that is following the regulation.
""")
