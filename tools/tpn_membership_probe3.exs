# Part three of the "what does PAIRED mean?" probe (see tpn_membership_probe.exs
# for the method and the controls).
#
# Parts one and two left three things open, and part two turned up a fourth:
#
#   9   a player being paired in the round under computation who is given
#       THIS round's pairing-allocated bye rather than an opponent - does it
#       count towards that same round's numbering?
#   10  `0000 - -` came out SKIPPED while `<opponent> - -` came out COUNTED.
#       So it is not the forfeit that qualifies a player; it is having had a
#       real opponent. Test the mirror, `0000 - +`, and a real-opponent `-`
#       reconfirmed side by side.
#   11  1c re-run on its own (its output was truncated the first time).
#   12  a real opponent with a BYE code - is the opponent field alone
#       enough, or must the result also be a pairing result?
#
#   BBPPAIRINGS_EXE=../openpairings/priv/bbppairings/bbpPairings-windows.exe \
#     MIX_ENV=test mix run tools/tpn_membership_probe3.exs

exe = System.get_env("BBPPAIRINGS_EXE", "../openpairings/priv/bbppairings/bbpPairings-windows.exe")

z = %{opponent_rank: nil, colour: nil, result: "Z"}
hb = %{opponent_rank: nil, colour: nil, result: "H"}
blank = %{opponent_rank: nil, colour: nil, result: ""}
g = fn opp, colour, result -> %{opponent_rank: opp, colour: colour, result: result} end

played_codes = ~w(1 0 = W D L)
played? = fn gm -> gm.result in played_codes end

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

run = fn name, expectation, players, t_rank, patch ->
  IO.puts("\n" <> String.duplicate("=", 78))
  IO.puts(name)
  IO.puts("expectation: #{expectation}")

  trf =
    Ainalrami.Trf.serialize(%{
      tournament: %{
        name: String.slice(name, 0, 40),
        type: "swiss",
        number_of_rounds: 9,
        initial_colour: "w"
      },
      players: players
    })
    |> patch.()

  slug = name |> String.replace(~r/[^a-zA-Z0-9]+/, "_") |> String.slice(0, 40)
  path = Path.join(System.tmp_dir!(), "tpn3_#{slug}.trf")
  out = Path.join(System.tmp_dir!(), "tpn3_#{slug}_out.txt")
  File.write!(path, trf)

  by_rank = Map.new(players, &{&1.rank, &1})

  IO.puts("T's line: " <> (trf |> String.split(~r/\r?\n/) |> Enum.find(&String.starts_with?(&1, "001 #{String.pad_leading("#{t_rank}", 4)} ")) |> to_string() |> String.slice(80, 60)))

  case System.cmd(exe, ["--dutch", path, "-p", out], stderr_to_stdout: true) do
    {msg, 0} ->
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

      if String.trim(msg) != "", do: IO.puts("bbp said: #{String.trim(msg)}")
      IO.puts("bbp pairings (white black): #{inspect(pairs)}")

      paired_ranks = pairs |> Enum.flat_map(fn {a, b} -> [a, b] end) |> Enum.reject(&(&1 == 0))
      bye_rank = Enum.find_value(pairs, fn {a, b} -> if b == 0, do: a end)
      IO.puts("paired this round: #{inspect(Enum.sort(paired_ranks))}   bye: #{inspect(bye_rank)}")
      IO.puts("T (rank #{t_rank}) in this round's pairing? #{t_rank in paired_ranks}")

      IO.puts("\n board   | top | actual W | TPN=rank | TPN=rank-1 | reads as")
      IO.puts(" --------+-----+----------+----------+------------+---------")

      verdicts =
        pairs
        |> Enum.reject(fn {_, b} -> b == 0 end)
        |> Enum.map(fn {w, b} ->
          a = by_rank[w]
          c = by_rank[b]
          both_clean = not Enum.any?(a.games ++ c.games, played?)

          {top, bottom} =
            if {-a.points, a.rank} <= {-c.points, c.rank}, do: {a, c}, else: {c, a}

          cond do
            not both_clean ->
              IO.puts(" #{String.pad_trailing("#{top.rank}v#{bottom.rank}", 7)} | #{String.pad_leading("#{top.rank}", 3)} | #{String.pad_leading("#{w}", 8)} |        - |          - | skipped (a played game)")
              nil

            top.rank == t_rank or bottom.rank == t_rank ->
              IO.puts(" #{String.pad_trailing("#{top.rank}v#{bottom.rank}", 7)} | #{String.pad_leading("#{top.rank}", 3)} | #{String.pad_leading("#{w}", 8)} |        - |          - | skipped (involves T)")
              nil

            true ->
              inc_white = if rem(top.rank, 2) == 1, do: top.rank, else: bottom.rank
              exc_white = if rem(top.rank - 1, 2) == 1, do: top.rank, else: bottom.rank

              verdict =
                cond do
                  w == inc_white and w == exc_white -> :ambiguous
                  w == inc_white -> :included
                  w == exc_white -> :excluded
                  true -> :neither
                end

              IO.puts(
                " #{String.pad_trailing("#{top.rank}v#{bottom.rank}", 7)} | #{String.pad_leading("#{top.rank}", 3)} |" <>
                  " #{String.pad_leading("#{w}", 8)} | #{String.pad_leading("#{inc_white}", 8)} |" <>
                  " #{String.pad_leading("#{exc_white}", 10)} | #{verdict |> to_string() |> String.upcase()}"
              )

              verdict
          end
        end)
        |> Enum.reject(&is_nil/1)

      IO.puts("\n tally over #{length(verdicts)} readable board(s): #{inspect(Enum.frequencies(verdicts))}")

      IO.puts(
        cond do
          verdicts == [] -> " VERDICT: NO READABLE BOARD - probe proves nothing"
          Enum.uniq(verdicts) == [:included] -> " VERDICT: T IS COUNTED in the numbering"
          Enum.uniq(verdicts) == [:excluded] -> " VERDICT: T IS SKIPPED by the numbering"
          true -> " VERDICT: INCONSISTENT - do not trust this position"
        end
      )

    {msg, code} ->
      IO.puts("bbpPairings failed (#{code}): #{String.trim(msg)}")
  end
end

id = & &1

# Rewrite T's first round-1 game token. `serialize/1` refuses most of these
# spellings, so they are written as something legal and patched on the way out.
patch_t1 = fn from, to ->
  fn trf ->
    trf
    |> String.split(~r/\r?\n/)
    |> Enum.map(fn line ->
      if String.starts_with?(line, "001    1 "),
        do: String.replace(line, from, to, global: false),
        else: line
    end)
    |> Enum.join("\n")
  end
end

# ---------------------------------------------------------------------------
# 9. THE CURRENT ROUND'S OWN BYE.
#
# T (rank 1) has a blank round 1 - never paired - and no round-2 entry, so it
# IS available for round 2. It is alone on nought while all twelve others
# carry a half-point bye, so T is the bottom score group of one and takes
# round 2's pairing-allocated bye. The other twelve are clean and pair among
# themselves, six readable boards.
#
# This is the case the implementation cannot infer: T is "being paired" this
# round in the sense of entering the pairing, but never gets an opponent.
# ---------------------------------------------------------------------------

run.(
  "9 CURRENT-ROUND BYE - T enters round 2's pairing and receives the bye",
  "unknown - decides whether 'paired' means 'entered the pairing' or 'got an opponent'",
  [player.(1, [blank])] ++ for(rank <- 2..13, do: player.(rank, [hb])),
  1,
  id
)

# ---------------------------------------------------------------------------
# 10. IS IT THE OPPONENT FIELD OR THE RESULT?
# ---------------------------------------------------------------------------

run.(
  "10a REAL OPPONENT, forfeit loss - reconfirmation of 1b",
  "COUNTED (part one said so)",
  [player.(1, [g.(2, "w", "-"), z])] ++
    [player.(2, [g.(1, "b", "-")])] ++ for(rank <- 3..13, do: player.(rank, [z])),
  1,
  id
)

run.(
  "10b NO OPPONENT, forfeit WIN 0000 - + (patched)",
  "unknown - 0000 - - came out SKIPPED",
  [player.(1, [z, z])] ++ for(rank <- 2..13, do: player.(rank, [z])),
  1,
  patch_t1.("0000 - Z", "0000 - +")
)

run.(
  "10c NO OPPONENT, forfeit LOSS 0000 - - (patched, reconfirms 3d)",
  "SKIPPED (part two said so)",
  [player.(1, [z, z])] ++ for(rank <- 2..13, do: player.(rank, [z])),
  1,
  patch_t1.("0000 - Z", "0000 - -")
)

# ---------------------------------------------------------------------------
# 12. A REAL OPPONENT CARRYING A BYE CODE. If the opponent field alone is
# what qualifies a player, this counts; if the result must also be a pairing
# result, it does not. Not a legal TRF, but it separates the two readings.
# ---------------------------------------------------------------------------

run.(
  "12 REAL OPPONENT with a Z result, `   2 w Z` (patched)",
  "unknown - separates 'has an opponent' from 'has a pairing result'",
  [player.(1, [z, z])] ++ for(rank <- 2..13, do: player.(rank, [z])),
  1,
  patch_t1.("0000 - Z", "   2 w Z")
)

run.(
  "12b REAL OPPONENT with an H result, `   2 w H` (patched)",
  "unknown",
  [player.(1, [z, z])] ++ for(rank <- 2..13, do: player.(rank, [z])),
  1,
  patch_t1.("0000 - Z", "   2 w H")
)

# ---------------------------------------------------------------------------
# 11. 1c on its own - T forfeits away a game its opponent wins by default.
# ---------------------------------------------------------------------------

run.(
  "11 (=1c) T forfeit loss, opponent forfeit win",
  "COUNTED, per part one's truncated run",
  [player.(1, [g.(2, "w", "-"), z])] ++
    [player.(2, [g.(1, "b", "+")])] ++ for(rank <- 3..13, do: player.(rank, [z])),
  1,
  id
)
