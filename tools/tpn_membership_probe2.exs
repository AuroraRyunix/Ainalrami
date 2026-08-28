# Part two of the "what does PAIRED mean?" probe (see tpn_membership_probe.exs
# for the method and the controls).
#
# Part one settled the single-round-history cases: forfeits and the
# pairing-allocated bye COUNT, while H / F / Z byes do NOT. This file settles
# the remaining questions, all of which need a round later than round two, or
# a TRF spelling `Ainalrami.Trf.serialize/1` refuses to write:
#
#   3d  the opponentless forfeit `0000 - -`, hand-patched into the file
#   4   late entry: excluded before arrival, included from the arrival round
#   5   the round under computation, in a round later than round one
#   6   withdrawal after real games
#   7   does arrival PERSIST through later blanks, with no Z marker at all?
#   8   is the ROUND of arrival the round of the qualifying entry?
#
#   BBPPAIRINGS_EXE=../openpairings/priv/bbppairings/bbpPairings-windows.exe \
#     MIX_ENV=test mix run tools/tpn_membership_probe2.exs

exe = System.get_env("BBPPAIRINGS_EXE", "../openpairings/priv/bbppairings/bbpPairings-windows.exe")

z = %{opponent_rank: nil, colour: nil, result: "Z"}
blank = %{opponent_rank: nil, colour: nil, result: ""}
u = %{opponent_rank: nil, colour: nil, result: "U"}
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

# `patch` lets a scenario rewrite the serialized TRF text before it reaches
# bbpPairings, for spellings this engine's serializer refuses to emit.
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
  path = Path.join(System.tmp_dir!(), "tpn2_#{slug}.trf")
  out = Path.join(System.tmp_dir!(), "tpn2_#{slug}_out.txt")
  File.write!(path, trf)

  by_rank = Map.new(players, &{&1.rank, &1})

  IO.puts(
    "field: " <>
      Enum.map_join(players, "  ", fn p ->
        "#{p.rank}[#{Enum.map_join(p.games, ",", &if(&1.result == "", do: ".", else: &1.result))}]=#{p.points}"
      end)
  )

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
      IO.puts("paired this round: #{inspect(Enum.sort(paired_ranks))}")
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
              IO.puts(
                " #{String.pad_trailing("#{top.rank}v#{bottom.rank}", 7)} | #{String.pad_leading("#{top.rank}", 3)} |" <>
                  " #{String.pad_leading("#{w}", 8)} |        - |          - | skipped (a played game -> 5.2.5 not reached)"
              )

              nil

            top.rank == t_rank or bottom.rank == t_rank ->
              IO.puts(
                " #{String.pad_trailing("#{top.rank}v#{bottom.rank}", 7)} | #{String.pad_leading("#{top.rank}", 3)} |" <>
                  " #{String.pad_leading("#{w}", 8)} |        - |          - | skipped (involves T itself)"
              )

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

# ---------------------------------------------------------------------------
# 3d. The opponentless forfeit, `0000 - -`.
#
# A real arbiter spelling for "did not show up, no opponent" that this
# engine's serializer refuses (it insists an opponentless round carry a bye
# code). Written as a Z and patched back to a dash on the way out, so the
# only thing that changes between this run and 3b is that one character.
# ---------------------------------------------------------------------------

run.(
  "3d OPPONENTLESS FORFEIT LOSS 0000 - - (patched into the file)",
  "unknown - 3b with the same shape and a Z came out SKIPPED",
  [player.(1, [z, z])] ++ for(rank <- 2..13, do: player.(rank, [z])),
  1,
  fn trf ->
    trf
    |> String.split(~r/\r?\n/)
    |> Enum.map(fn line ->
      if String.starts_with?(line, "001    1 ") do
        # first of P1's two `0000 - Z` entries becomes `0000 - -`
        String.replace(line, "0000 - Z", "0000 - -", global: false)
      else
        line
      end
    end)
    |> Enum.join("\n")
  end
)

# ---------------------------------------------------------------------------
# 4. LATE ENTRY. Blank rounds, no marker at all, then arrival.
# ---------------------------------------------------------------------------

run.(
  "4i LATE ENTRY - blank round 1, marked out of round 2 with a Z",
  "unknown",
  [player.(1, [blank, z])] ++ for(rank <- 2..13, do: player.(rank, [z])),
  1,
  id
)

run.(
  "4ii LATE ENTRY - wholly blank history: is T even paired in round 2?",
  "unknown - watch the 'T in this round's pairing' line",
  [player.(1, [blank, blank])] ++
    for(rank <- 2..12, do: player.(rank, [z])) ++ [player.(13, [z, z])],
  1,
  id
)

run.(
  "4iii LATE ENTRY - T blank for rounds 1-2, arrives and is paired in round 3",
  "COUNTED if being paired now counts",
  [player.(1, [blank, blank])] ++
    for(rank <- 2..12, do: player.(rank, [z, z])) ++ [player.(13, [z, z, z])],
  1,
  id
)

# The mirror of 4iii: T arrived in round 2 (a real game), and in round 3 it
# is the ONLY player carrying a round-3 marker, so it sits round 3 out.
# Ranks 2..12 are clean and paired now; rank 13 never arrived.
run.(
  "4iv LATE ENTRY - T blank round 1, played round 2, sits round 3 out",
  "COUNTED (it arrived in round 2)",
  [player.(1, [blank, g.(13, "w", "="), z])] ++
    for(rank <- 2..12, do: player.(rank, [z, z])) ++
    [player.(13, [z, g.(1, "b", "=")])],
  1,
  id
)

# ---------------------------------------------------------------------------
# 5. THE ROUND UNDER COMPUTATION, in a round later than round one.
#
# Rank 1 has never been paired and sits round 3 out. Ranks 2..13 have never
# been paired either, but are ALL being paired in round 3. If they come out
# numbered 1..12 (i.e. rank - 1), then being paired in the round under
# computation is itself what makes a player count.
# ---------------------------------------------------------------------------

run.(
  "5 CURRENT ROUND - twelve never-yet-paired players all paired in round 3",
  "ranks 2-13 numbered 1-12, i.e. being paired NOW counts",
  [player.(1, [z, z, z])] ++ for(rank <- 2..13, do: player.(rank, [z, z])),
  1,
  id
)

# ---------------------------------------------------------------------------
# 6. WITHDRAWN after real games.
# ---------------------------------------------------------------------------

run.(
  "6 WITHDRAWN - T played rounds 1-2 then withdrew, round 3 under computation",
  "COUNTED (it arrived)",
  [player.(1, [g.(12, "w", "="), g.(13, "b", "="), z])] ++
    for(rank <- 2..11, do: player.(rank, [z, z])) ++
    [player.(12, [g.(1, "b", "="), z, z])] ++
    [player.(13, [z, g.(1, "w", "="), z])],
  1,
  id
)

# ---------------------------------------------------------------------------
# 7. Does arrival PERSIST through a trailing blank rather than a Z marker?
#
# T forfeits round 1 and then has nothing at all - no Z, no entry. Rank 13
# carries the round-2 marker that makes round 2 the round under computation.
# ---------------------------------------------------------------------------

run.(
  "7 FORFEIT then NOTHING - T's round 2 is blank, not a Z",
  "COUNTED if the forfeit is what counts and blanks cannot undo it",
  [player.(1, [g.(2, "w", "+")])] ++
    [player.(2, [g.(1, "b", "-")])] ++
    for(rank <- 3..12, do: player.(rank, [z])) ++
    [player.(13, [z, z])],
  1,
  id
)

# ---------------------------------------------------------------------------
# 8. Is the ROUND of arrival the round of the qualifying entry? T's only
# appearance is a pairing-allocated bye in round 2; round 3 is computed.
# ---------------------------------------------------------------------------

run.(
  "8 U BYE IN ROUND 2 - T blank round 1, U in round 2, sits round 3 out",
  "COUNTED (the U is a pairing)",
  [player.(1, [blank, u, z])] ++ for(rank <- 2..13, do: player.(rank, [z, z])),
  1,
  id
)
