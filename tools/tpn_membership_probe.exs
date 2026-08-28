# What does "has been paired" mean, for the purpose of the TPN numbering
# Article 5.2.5 takes the parity of?
#
# The SPP has ruled that the numbering skips players who have not yet
# arrived (C.04.2:2.4 - "given an appropriate TPN and paired only when they
# actually arrive"). bbpPairings and Gacrux both implement that. What the
# ruling does NOT say is where the line falls for a player whose only
# appearance so far is something other than a played game: a forfeit, a
# pairing-allocated bye, a half-point bye, a blank round. This probe asks
# the reference binary, position by position.
#
# METHOD. Article 5.2.5 is only reached when NEITHER player has a colour
# preference, which in bbpPairings (and in this engine's port of
# `choosePlayerNeutralColor`) means neither has a single PLAYED game -
# identical colour histories fall to 5.2.4 instead, not to 5.2.5. So every
# board this probe reads is between two players whose whole history is
# byes and/or forfeits. On such a board the colour is decided by the parity
# of the higher-ranked player's TPN alone, which makes the board a direct
# readout of that TPN's parity.
#
# Each scenario puts exactly ONE player of uncertain status - the test
# player T - at starting rank 1, and makes every other player unambiguously
# numbered (they are all being paired in the round under computation).
# So TPN(r) = r if T is counted and r - 1 if it is not, for every other
# player r. One player, not two: an even number of skipped players
# preserves parity and would prove nothing.
#
#   BBPPAIRINGS_EXE=../openpairings/priv/bbppairings/bbpPairings-windows.exe \
#     MIX_ENV=test mix run tools/tpn_membership_probe.exs

exe = System.get_env("BBPPAIRINGS_EXE", "../openpairings/priv/bbppairings/bbpPairings-windows.exe")

z = %{opponent_rank: nil, colour: nil, result: "Z"}
blank = %{opponent_rank: nil, colour: nil, result: ""}
u = %{opponent_rank: nil, colour: nil, result: "U"}
hb = %{opponent_rank: nil, colour: nil, result: "H"}
fb = %{opponent_rank: nil, colour: nil, result: "F"}
dash = %{opponent_rank: nil, colour: nil, result: "-"}
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

# ---------------------------------------------------------------------------
# The runner. `t_rank` is the player whose membership is under test; boards
# involving it are reported but never counted towards the verdict, because
# its own TPN is exactly what is unknown.
# ---------------------------------------------------------------------------
run = fn name, expectation, players, t_rank ->
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

  slug = name |> String.replace(~r/[^a-zA-Z0-9]+/, "_") |> String.slice(0, 40)
  path = Path.join(System.tmp_dir!(), "tpn_#{slug}.trf")
  out = Path.join(System.tmp_dir!(), "tpn_#{slug}_out.txt")
  File.write!(path, trf)

  by_rank = Map.new(players, &{&1.rank, &1})

  IO.puts(
    "field: " <>
      Enum.map_join(players, "  ", fn p ->
        "#{p.rank}[#{Enum.map_join(p.games, ",", &(if &1.result == "", do: ".", else: &1.result))}]=#{p.points}"
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
              # 5.2.5 with initial colour White: the higher ranked player
              # takes White on an odd TPN, Black on an even one.
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

      tally = Enum.frequencies(verdicts)
      IO.puts("\n tally over #{length(verdicts)} readable board(s): #{inspect(tally)}")

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

# ---------------------------------------------------------------------------
# Scenario shapes.
#
# `round_two` - 13 players. Rank 1 is T, carrying `t_games` (round 1, then a
# round-2 marker that keeps it out of the round being paired). Rank 2 may
# carry `o_games` (the other half of a forfeit). Everyone else sat round one
# out on a zero-point bye, so all twelve of them are clean, on nought, and
# paired in round 2.
# ---------------------------------------------------------------------------
round_two = fn t_games, o_games ->
  [player.(1, t_games)] ++
    [player.(2, o_games || [z])] ++
    for(rank <- 3..13, do: player.(rank, [z]))
end

# --- controls -------------------------------------------------------------
# Both of these have known answers. If either comes out wrong the harness,
# not the binary, is what is being measured.

run.(
  "CONTROL A - T played round 1, sits round 2 out (rip_probe's shape)",
  "INCLUDED (already established)",
  [player.(1, [g.(13, "w", "="), z])] ++
    for(rank <- 2..12, do: player.(rank, [z])) ++
    [player.(13, [g.(1, "b", "=")])],
  1
)

run.(
  "CONTROL B - T has never been paired and sits round 2 out",
  "SKIPPED (already established)",
  round_two.([z, z], nil),
  1
)

# --- 1. forfeits ----------------------------------------------------------

run.(
  "1a FORFEIT WIN - T's only appearance is a forfeit win, then absent",
  "unknown",
  round_two.([g.(2, "w", "+"), z], [g.(1, "b", "-")]),
  1
)

run.(
  "1b FORFEIT LOSS (double forfeit) - T's only appearance is a forfeit loss",
  "unknown",
  round_two.([g.(2, "w", "-"), z], [g.(1, "b", "-")]),
  1
)

run.(
  "1c FORFEIT LOSS against a forfeit win - T loses by default, then absent",
  "unknown",
  round_two.([g.(2, "w", "-"), z], [g.(1, "b", "+")]),
  1
)

# --- 2. pairing-allocated bye --------------------------------------------

run.(
  "2 PAIRING-ALLOCATED BYE - T's only appearance is a U bye, then absent",
  "unknown",
  round_two.([u, z], nil),
  1
)

# --- 3. half-point / zero-point / full-point byes -------------------------

run.(
  "3a HALF-POINT BYE - T's only appearance is an H bye, then absent",
  "unknown",
  round_two.([hb, z], nil),
  1
)

run.(
  "3b ZERO-POINT BYE - T's only appearance is a Z bye, then absent",
  "unknown (same shape as CONTROL B)",
  round_two.([z, z], nil),
  1
)

run.(
  "3c FULL-POINT BYE - T's only appearance is an F bye, then absent",
  "unknown",
  round_two.([fb, z], nil),
  1
)

run.(
  "3d ABSENT MARKER 0000 - - : T's only appearance is a no-opponent dash",
  "unknown",
  round_two.([dash, z], nil),
  1
)

# --- 4. late entry --------------------------------------------------------

run.(
  "4i LATE ENTRY - blank round 1, marked out of round 2",
  "unknown",
  round_two.([blank, z], nil),
  1
)

# Blank round 1 AND blank round 2: does bbpPairings pair T in round 2 at all,
# or does it understand a wholly blank history as "not yet arrived"? Rank 13
# carries the round-2 marker that makes round 2 the round under computation.
run.(
  "4ii LATE ENTRY - wholly blank history: is T paired in round 2?",
  "unknown - watch the 'T in this round's pairing' line",
  [player.(1, [blank, blank])] ++
    for(rank <- 2..12, do: player.(rank, [z])) ++
    [player.(13, [z, z])],
  1
)

# Arrival round: T is blank for rounds 1-2 and IS paired in round 3. Rank 13
# is a never-paired absentee, parked below every readable board so that its
# own exclusion cannot shift them.
run.(
  "4iii LATE ENTRY - T arrives and is paired in round 3",
  "COUNTED (it is being paired in the round under computation)",
  [player.(1, [blank, blank])] ++
    for(rank <- 2..12, do: player.(rank, [z, z])) ++
    [player.(13, [z, z, z])],
  1
)

# --- 5. the current round, in a round later than round one ----------------

run.(
  "5 CURRENT ROUND - never-paired absentee at rank 1, round 3 under computation",
  "SKIPPED, which leaves ranks 2-13 numbered from 1 - i.e. being paired now counts",
  [player.(1, [z, z, z])] ++ for(rank <- 2..13, do: player.(rank, [z, z])),
  1
)

# --- 6. withdrawn ---------------------------------------------------------

run.(
  "6 WITHDRAWN - T played rounds 1-2 then withdrew, round 3 under computation",
  "COUNTED (it arrived)",
  [player.(1, [g.(12, "w", "="), g.(13, "b", "="), z])] ++
    for(rank <- 2..11, do: player.(rank, [z, z])) ++
    [player.(12, [g.(1, "b", "="), z, z])] ++
    [player.(13, [z, g.(1, "w", "="), z])],
  1
)
