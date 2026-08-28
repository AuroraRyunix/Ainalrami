# What colour does each engine give the top player on each board of round 1?
#
# Round one is the cleanest possible probe of Article 5.2.5: no player has
# played a game, so nobody holds a colour preference and every board falls
# through 5.2.1-5.2.4 to the parity rule alone.
#
# 5.2.5 gives the higher ranked player of a board the initial colour when
# their number is ODD and the opposite when it is EVEN. WHICH NUMBER that is
# was disputed, and the adjudicator column below used to answer it wrongly.
#
# TWO RETRACTIONS, both from 2026-08-27:
#
#  1. This tool tested the parity of the raw starting rank - the TPN as
#     C.04.2 Article 2 fixes it for the whole tournament. The FIDE Systems
#     of Pairings and Programs Commission ruled against that reading: the
#     numbering SKIPS players who have never been paired, so it is a
#     position among the players who have ARRIVED, recomputed every round.
#     Both sides of the dispute argued from the same sentence, C.04.2:2.4,
#     and this project read it backwards. `Ainalrami.Pairing`'s
#     `arrival_numbers/2` carries the ruling in full.
#
#  2. Worse, and this tool's own frame was built on it:
#     `docs/dispute-initial-colour.md` claimed the two references renumber
#     differently FROM EACH OTHER, so that "agreeing with the references is
#     not even a well-defined target". That was false when written - it was
#     the pre-probe hypothesis written up as a finding, and
#     `tools/rip_probe.exs` refuted it inside that same document's own
#     evidence section. Re-confirmed against the local binary on
#     2026-08-27. bbpPairings and Gacrux agree with each other, and now so
#     do we.
#
# The parity below is therefore taken on the ARRIVAL NUMBER. On a clean
# field that is the rank and the two readings are indistinguishable, which
# is exactly why this tool takes a bye list: a pre-marked bye is what pulls
# the numbering off the rank, and it is the case the tool exists to examine.
#
#   mix run tools/round_one_colours.exs [players] [comma-separated bye ranks]

n = System.argv() |> Enum.at(0, "10") |> String.to_integer()

# Ranks sitting round one out on an arbiter-assigned bye, which is how the
# fuzz harness spells one: a pre-recorded round-one game with no opponent
# and no colour. `Z` does not participate in a pairing, so these players
# never arrive and are never numbered -- which shifts the number of
# everyone ranked below them off their rank. That gap is the whole point of
# the tool: on a clean field the two readings of 5.2.5 give identical
# output and nothing is being tested.
byes =
  System.argv()
  |> Enum.at(1, "")
  |> String.split(",", trim: true)
  |> Enum.map(&String.to_integer/1)

exe =
  System.get_env("BBPPAIRINGS_EXE", "../openpairings/priv/bbppairings/bbpPairings-windows.exe")

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

IO.puts(
  trf
  |> String.split(~r/\r?\n/)
  |> Enum.filter(&String.starts_with?(&1, "152"))
  |> inspect()
)

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

# Gacrux is the third implementation of the same 2026 rules. It renumbers,
# and so does bbpPairings, and they do it identically -- see retraction 2
# in the header for the claim to the contrary that this column was once
# built to test. It stays here as a regression check, not as an open
# question. Locally the column is blank: Gacrux needs networkx, which is
# not installed on this machine.
gacrux =
  case Ainalrami.Test.Gacrux.pair(trf) do
    {:ok, pairs} -> pairs
    other -> other
  end

# JaVaFo is the PRE-2026 reference. The old rule (E.5) tested the parity of
# a "pairing number", defined in A.2 as the initial ranking "and subsequent
# modifications depending on possible late entries or rating adjustments";
# the 2026 rewrite replaced that with a TPN pinned to C.04.2 Article 2.
# Now that the SPP has settled what the 2026 rule means, this column is a
# question about lineage rather than about correctness: whether the
# renumbering the references share is inherited from the old wording or
# postdates it.
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

# 5.2.5's numbering, for the adjudicator column. The arrivals are the
# players this round is actually pairing, numbered 1..k up the starting
# rank; a player who has not arrived gets no number at all.
#
# `Ainalrami.Test.Field.derive/1` is the repo's shared statement of "who
# does this round seat", ported from bbpPairings' `playedRounds` +
# `dutch.cpp:658`. Reusing it rather than writing the predicate out again
# here is deliberate: a second private copy of a pairing rule is the exact
# shape of nearly every real defect this project has found (`played?/1`
# against the shared code table, `NbParties` counting four codes against
# nine, the two copies of "what is a played code" deleted in one commit).
#
# It is the right set only because this tool is round-one-only. In general
# an arrival is "in this round's pool OR paired in some earlier round"
# (`Ainalrami.Pairing`'s `arrived_for?/2`); before round one there are no
# earlier rounds, so the second half is empty and arrival collapses to the
# active set. Point this tool at a later round and that stops being true.
arrivals =
  players
  |> Ainalrami.Test.Field.derive()
  |> Enum.sort_by(& &1.rank)
  |> Enum.with_index(1)
  # `number`, not `n`: `n` is the field size two dozen lines up.
  |> Map.new(fn {player, number} -> {player.rank, number} end)

IO.puts(
  "\n board  | top TPN | arr # | parity | ours  | bbp   | gacrux | javafo | who follows 5.2.5?"
)

IO.puts(
  " -------+---------+-------+--------+-------+-------+--------+--------+-------------------"
)

ours_by
|> Map.keys()
|> Enum.sort()
|> Enum.each(fn board ->
  [top, bottom] = board

  # The article: the higher ranked player takes the initial colour on an
  # odd ARRIVAL NUMBER -- not on an odd TPN, per the SPP's 2026-08-27
  # ruling. Every player here is on zero, so Article 1.2's "higher ranked"
  # (score first, then TPN) collapses to the lower TPN, which is `top`.
  #
  # `Map.fetch!`, not `Map.get(.., top)`: a seated player who is missing
  # from the arrival numbering is a broken premise, and falling back to the
  # rank is precisely the overturned rule creeping back in.
  number = Map.fetch!(arrivals, top)
  parity = if rem(number, 2) == 1, do: "odd ", else: "even"
  article_white = if rem(number, 2) == 1, do: top, else: bottom

  ow = Map.get(ours_by, board)
  tw = Map.get(theirs_by, board)
  gw = Map.get(gacrux_by, board)
  jw = Map.get(javafo_by, board)

  who =
    [{"ours", ow}, {"bbp", tw}, {"gacrux", gw}, {"javafo", jw}]
    |> Enum.filter(fn {_, w} -> w == article_white end)
    |> Enum.map_join(" ", &elem(&1, 0))

  IO.puts(
    " #{String.pad_trailing("#{top}v#{bottom}", 6)} |   #{String.pad_leading("#{top}", 5)} |" <>
      " #{String.pad_leading("#{number}", 5)} |  #{parity}  |" <>
      " #{String.pad_leading("#{ow}", 5)} | #{String.pad_leading("#{tw}", 5)} |" <>
      " #{String.pad_leading("#{gw}", 6)} | #{String.pad_leading("#{jw}", 6)} |" <>
      " #{if who == "", do: "NOBODY", else: who}"
  )
end)

IO.puts("""

Reading this: the "arr #" column is the top player's position among the
players this round is pairing, and 5.2.5 alternates the initial colour
(White here) down THAT numbering, not down the TPN. An engine follows the
regulation on a board when it gives White to the higher-ranked player on an
odd arrival number and to the lower-ranked one on an even number; the last
column names the engines that did.

Where a bye is pre-marked, the two columns come apart, and that is the only
case worth running. Field of 10 with byes on 1 and 3: board 2v7 has top TPN
2, even, which the overturned reading answered as White to 7 -- but player 2
is arrival number 1, because TPN 1 never arrived, so White is correctly
player 2. Every engine here said 2. Until 2026-08-27 this tool printed
NOBODY on that board, and the mistake was its own.
""")
