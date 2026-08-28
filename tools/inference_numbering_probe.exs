# Which number does bbpPairings take 5.2.5's parity on when it has to
# DEDUCE the initial colour, because the file carries no `152`?
#
# Two candidate readings of the recorded round:
#
#   OWN      the parity of the coloured player's own arrival number - take
#            the lowest-ranked player holding a colour in the first round
#            that records any, read the parity of THEIR number, and invert
#            their colour on an even one. This is what
#            `infer_initial_colour/1` implements.
#   TOP      the exact inverse of the allocation - on that same board find
#            the TOP by Article 1.2 (score first, TPN only to break the
#            tie, i.e. `order_by_placement/2`), and read the parity of the
#            TOP's number against the TOP's colour.
#
# They coincide whenever the coloured player IS the top of their board, so
# only a first-coloured round LATER than round one can separate them: on
# zero-score round one "higher ranked" collapses to the lower TPN and the
# lowest-ranked coloured player is necessarily a top.
#
# A third reading is measured alongside as a live-corpus control:
#
#   OWN_TPN  OWN, but on the raw TPN instead of the arrival number - the
#            reading the SPP overturned on 2026-08-27.
#
# ## The measurement is taken inside bbpPairings
#
# This engine does not decide the answer. For each position the IDENTICAL
# roster is serialised three times - no `152`, `152 W`, `152 B` - and all
# three are handed to the real binary. `152 W` and `152 B` are the two
# stated runs; the silent one has to reproduce one of them, and which one it
# reproduces IS bbpPairings' deduction, read off bbpPairings' own output.
# When the two stated runs agree the position is blind and is discarded.
#
# The three readings are re-derived here from the file's history rather
# than called out of `Ainalrami.Pairing` - its versions are private and are
# the thing under test.
#
# A separate, clearly-labelled tally at the end DOES run this engine, to
# report conformance on the same no-`152` files. That is a different
# quantity from everything above and is named differently.
#
#   BBPPAIRINGS_EXE=../openpairings/priv/bbppairings/bbpPairings-windows.exe \
#     mix run tools/inference_numbering_probe.exs
#
# Knobs: INP_COUNT (tournaments), INP_ROUNDS, INP_SEED_FROM,
# INP_BYE_PCT, INP_MAX_PLAYERS.
#
# INP_SELFTEST=1 swaps the two candidate readings before Q1's classifier
# sees them and changes nothing else. Q1's OWN and TOP columns must then
# swap. If they do not, that tally arm is dead and its zero means nothing.
#
# Read-only: it touches nothing under lib/ or test/.

exe =
  System.get_env("BBPPAIRINGS_EXE", "../openpairings/priv/bbppairings/bbpPairings-windows.exe")

count = String.to_integer(System.get_env("INP_COUNT", "150"))
rounds = String.to_integer(System.get_env("INP_ROUNDS", "6"))
seed_from = String.to_integer(System.get_env("INP_SEED_FROM", "1"))
bye_pct = String.to_integer(System.get_env("INP_BYE_PCT", "30"))
max_players = String.to_integer(System.get_env("INP_MAX_PLAYERS", "16"))
selftest? = System.get_env("INP_SELFTEST") == "1"

dir = System.tmp_dir!()

blank = %{opponent_rank: nil, colour: nil, result: ""}
bye = fn code -> %{opponent_rank: nil, colour: nil, result: code} end

points_for = fn result ->
  cond do
    result in ~w(1 + U F W) -> 1.0
    result in ~w(= H D) -> 0.5
    true -> 0.0
  end
end

participated? = fn gm -> gm.opponent_rank != nil or gm.result in ~w(U +) end

invert = fn
  "w" -> "b"
  "b" -> "w"
end

new_player = fn rank ->
  %{
    rank: rank,
    name: "P#{rank}",
    sex: "",
    title: "",
    federation: "",
    fide_rating: 2400 - rank * 7,
    fide_number: nil,
    birth_date: "",
    points: 0.0,
    games: []
  }
end

append = fn player, game ->
  %{player | games: player.games ++ [game], points: player.points + points_for.(game.result)}
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
  |> Enum.sort()
end

serialize = fn roster, ic ->
  Ainalrami.Trf.serialize(%{
    tournament: %{
      name: "inference numbering probe",
      type: "swiss",
      number_of_rounds: rounds,
      initial_colour: ic
    },
    players: roster
  })
end

run_bbp = fn trf, slug ->
  path = Path.join(dir, "inp_#{slug}.trf")
  out = Path.join(dir, "inp_#{slug}_out.txt")
  File.write!(path, trf)

  case System.cmd(exe, ["--dutch", path, "-p", out], stderr_to_stdout: true) do
    {_, 0} -> {:ok, pairs_of.(File.read!(out))}
    {msg, code} -> {:error, "exit #{code}: #{String.slice(String.trim(msg), 0, 110)}"}
  end
end

# --- the three readings, re-derived from the file ---------------------------

# The numbering as it stood in a round the file has ALREADY recorded:
# everyone who participated in the pairing of some round up to and including
# `round`, numbered from 1 in ascending starting rank.
arrival_numbers_at = fn roster, round ->
  roster
  |> Enum.sort_by(& &1.rank)
  |> Enum.filter(fn p -> p.games |> Enum.take(round) |> Enum.any?(participated?) end)
  |> Enum.with_index(1)
  |> Map.new(fn {p, n} -> {p.rank, n} end)
end

readings = fn roster ->
  ranked = Enum.sort_by(roster, & &1.rank)

  first_coloured =
    ranked
    |> Enum.flat_map(fn p ->
      p.games |> Enum.with_index() |> Enum.filter(&(elem(&1, 0).colour != nil))
    end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.min(fn -> nil end)

  if first_coloured == nil do
    :no_colours
  else
    round = first_coloured + 1
    numbers = arrival_numbers_at.(ranked, round)

    coloured =
      Enum.find(ranked, fn p ->
        case Enum.at(p.games, first_coloured) do
          %{colour: c} -> c in ["w", "b"] and is_integer(Map.get(numbers, p.rank))
          _ -> false
        end
      end)

    if coloured == nil do
      :no_numbered_colour
    else
      gm = Enum.at(coloured.games, first_coloured)
      own_n = Map.fetch!(numbers, coloured.rank)

      own = if rem(own_n, 2) == 1, do: gm.colour, else: invert.(gm.colour)
      own_tpn = if rem(coloured.rank, 2) == 1, do: gm.colour, else: invert.(gm.colour)

      # The other side of that same board, and the score each carried INTO
      # the round - which is what `order_by_placement/2` sorted on when the
      # colour was allocated.
      opponent = Enum.find(ranked, &(&1.rank == gm.opponent_rank))

      score_before = fn p ->
        p.games |> Enum.take(first_coloured) |> Enum.map(&points_for.(&1.result)) |> Enum.sum()
      end

      {top, top_gm} =
        cond do
          opponent == nil ->
            {coloured, gm}

          {-score_before.(coloured), coloured.rank} <= {-score_before.(opponent), opponent.rank} ->
            {coloured, gm}

          true ->
            {opponent, Enum.at(opponent.games, first_coloured)}
        end

      top_n = Map.get(numbers, top.rank)

      top_reading =
        if is_integer(top_n) and top_gm != nil and top_gm.colour in ["w", "b"] do
          if rem(top_n, 2) == 1, do: top_gm.colour, else: invert.(top_gm.colour)
        else
          nil
        end

      %{
        round: round,
        own: own,
        own_tpn: own_tpn,
        top: top_reading,
        coloured_rank: coloured.rank,
        coloured_colour: gm.colour,
        own_number: own_n,
        top_rank: top.rank,
        top_number: top_n,
        coloured_is_top?: top.rank == coloured.rank
      }
    end
  end
end

# --- the three-way read of bbpPairings' own deduction -----------------------

deduction = fn roster ->
  with {:ok, silent} <- run_bbp.(serialize.(roster, nil), "silent"),
       {:ok, white} <- run_bbp.(serialize.(roster, "w"), "w"),
       {:ok, black} <- run_bbp.(serialize.(roster, "b"), "b") do
    cond do
      white == black -> {:blind, silent}
      silent == white -> {:deduced, "w", silent}
      silent == black -> {:deduced, "b", silent}
      true -> {:neither, silent}
    end
  else
    {:error, m} -> {:error, m}
  end
end

tally = :ets.new(:inp, [:public, :duplicate_bag])
note = fn tag, value -> :ets.insert(tally, {tag, value}) end

Enum.each(seed_from..(seed_from + count - 1), fn seed ->
  :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 3})

  n = Enum.random(8..max_players)
  gen_ic = Enum.random(["w", "b"])

  # Late entries shift the arrival numbering away from the TPN. An ODD count
  # is what flips parity, so one is drawn more often than two.
  late =
    1..n
    |> Enum.shuffle()
    |> Enum.take(Enum.random([0, 1, 1, 1, 2, 3]))
    |> Map.new(fn rank -> {rank, Enum.random([2, 2, 3])} end)

  players = Map.new(1..n, fn rank -> {rank, new_player.(rank)} end)

  # ROUND ONE IS ALL BYES. No colour is recorded, so the first coloured
  # round is round two or later - which is the only place OWN and TOP can
  # part company, and it is also what forces bbpPairings to deduce from a
  # round whose scores already differ (H 0.5, F 1.0, Z 0.0).
  players =
    Enum.reduce(1..n, players, fn rank, acc ->
      code = if Map.has_key?(late, rank), do: nil, else: Enum.random(~w(H F Z))
      Map.put(acc, rank, append.(acc[rank], if(code, do: bye.(code), else: blank)))
    end)

  withdrawn = MapSet.new()

  Enum.reduce_while(2..rounds, {players, withdrawn}, fn round, {players, withdrawn} ->
    {players, sitting} =
      Enum.reduce(1..n, {players, MapSet.new()}, fn rank, {acc, out_set} ->
        player = acc[rank]
        arrival = Map.get(late, rank)

        cond do
          arrival != nil and round < arrival ->
            {Map.put(acc, rank, append.(player, blank)), MapSet.put(out_set, rank)}

          MapSet.member?(withdrawn, rank) ->
            {Map.put(acc, rank, append.(player, bye.("Z"))), MapSet.put(out_set, rank)}

          :rand.uniform(100) <= bye_pct ->
            {Map.put(acc, rank, append.(player, bye.(Enum.random(~w(H Z F))))),
             MapSet.put(out_set, rank)}

          true ->
            {acc, out_set}
        end
      end)

    roster = 1..n |> Enum.map(&players[&1])
    playing = Enum.reject(roster, &MapSet.member?(sitting, &1.rank))

    if length(playing) < 4 do
      note.(:starved, "seed #{seed} r#{round}")
      {:halt, {players, withdrawn}}
    else
      # Round two has no colour anywhere in the file yet, so there is
      # nothing to deduce FROM: it is paired under an explicit `152` to
      # seed the colours, and the `152` is then never written again. That
      # is precisely the round-trip the asymmetry claim is about.
      result =
        if round == 2 do
          case run_bbp.(serialize.(roster, gen_ic), "seed") do
            {:ok, pairs} -> {:seeded, pairs}
            {:error, m} -> {:error, m}
          end
        else
          case deduction.(roster) do
            {:deduced, colour, pairs} ->
              case readings.(roster) do
                %{} = r -> {:measured, colour, r, pairs, roster}
                other -> {:unreadable, other}
              end

            other ->
              other
          end
        end

      case result do
        {:error, m} ->
          note.(:refused, "seed #{seed} r#{round} #{m}")
          {:halt, {players, withdrawn}}

        {:neither, _} ->
          note.(:neither, "seed #{seed} r#{round}")
          {:halt, {players, withdrawn}}

        {:unreadable, why} ->
          note.(:unreadable, "seed #{seed} r#{round} #{inspect(why)}")
          {:halt, {players, withdrawn}}

        _ ->
          # A BLIND position - `152 W` and `152 B` paired identically, so
          # the file never reached 5.2.5 and the deduction is unobservable.
          # It measures nothing, but the tournament is still perfectly good
          # to carry forward, so it advances rather than halting.
          {pairs, measured} =
            case result do
              {:seeded, pairs} ->
                {pairs, nil}

              {:blind, pairs} ->
                note.(:blind, "seed #{seed} r#{round}")
                {pairs, nil}

              {:measured, colour, r, pairs, roster} ->
                {pairs, {colour, r, roster}}
            end

          if measured do
            {bbp_colour, r, roster} = measured
            note.(:position, "seed #{seed} r#{round}")

            # INSTRUMENT SELF-CHECK. If bbpPairings simply DEFAULTED to
            # White whenever the `152` is missing, every table below would
            # read the same way while measuring nothing at all. The
            # deduction is only being exercised if the silent run
            # reproduces the `152 B` run somewhere.
            note.({:bbp_says, bbp_colour}, 1)

            # Q1 - OWN vs TOP.
            # INSTRUMENT SELF-TEST for Q1. With INP_SELFTEST=1 the two
            # readings are swapped before the classifier sees them, and
            # nothing else changes. The report must then read TOP where it
            # read OWN. A run that does NOT flip has a dead tally arm, and
            # its zero in the TOP column would mean nothing.
            {own_reading, top_reading} =
              if selftest?, do: {r.top, r.own}, else: {r.own, r.top}

            if top_reading != nil do
              if own_reading == top_reading do
                note.(:ab_agree, 1)
              else
                note.(:ab_split, 1)

                who =
                  cond do
                    bbp_colour == own_reading -> :own
                    bbp_colour == top_reading -> :top
                    true -> :neither
                  end

                note.({:ab_followed, who}, 1)
                note.({:ab_split_own, own_reading}, 1)

                path = Path.join(dir, "inp_split_#{seed}_#{round}.trf")
                File.write!(path, serialize.(roster, nil))

                note.(
                  :ab_detail,
                  "seed #{seed} r#{round} first-coloured r#{r.round}" <>
                    " coloured=#{r.coloured_rank}(#{r.coloured_colour},n=#{r.own_number})" <>
                    " top=#{r.top_rank}(n=#{r.top_number})" <>
                    " OWN=#{own_reading} TOP=#{top_reading} bbp=#{bbp_colour} -> #{who}  [#{path}]"
                )
              end
            else
              note.(:top_unreadable, "seed #{seed} r#{round}")
            end

            # Q2 - arrival numbering vs the overturned raw-TPN reading.
            if r.own != r.own_tpn do
              note.(:tpn_split, 1)

              who =
                cond do
                  bbp_colour == r.own -> :arrival
                  bbp_colour == r.own_tpn -> :raw_tpn
                  true -> :neither
                end

              note.({:tpn_followed, who}, 1)
            else
              note.(:tpn_agree, 1)
            end

            # Q3 - does OWN predict bbpPairings at all, split or not?
            note.({:own_predicts, bbp_colour == r.own}, 1)

            # Q4 - CONFORMANCE. This one DOES run our engine, on the same
            # no-`152` file, and is a different quantity from Q1-Q3.
            ours =
              try do
                Ainalrami.Pairing.pair_next_round(roster, expected_rounds: rounds)
              rescue
                e -> {:raised, Exception.message(e)}
              end

            case ours do
              {:raised, m} ->
                note.(:conformance_raised, "seed #{seed} r#{round}: #{m}")

              _ ->
                note.(:conformance_position, 1)

                # This engine spells the pairing-allocated bye `{rank, nil}`
                # and bbpPairings' output file spells it `rank 0`. Same
                # thing; normalise before comparing, or every bye round
                # reports as a difference.
                ours =
                  ours |> Enum.map(fn {w, b} -> {w, b || 0} end) |> Enum.sort()

                if ours == pairs do
                  note.(:conformance_ok, 1)
                else
                  note.(
                    :conformance_bad,
                    "seed #{seed} r#{round} ours=#{inspect(ours)} bbp=#{inspect(pairs)}"
                  )
                end
            end
          end

          # Advance on bbpPairings' own answer, so a deduction we disagree
          # with cannot corrupt the next round's measurement.
          players =
            Enum.reduce(pairs, players, fn
              {w, 0}, acc ->
                Map.put(acc, w, append.(acc[w], bye.("U")))

              {w, bl}, acc ->
                case Enum.random([:played, :played, :played, :played, :played, :wf, :bf]) do
                  :played ->
                    res = Enum.random(~w(1 = 0))
                    inv = %{"1" => "0", "=" => "=", "0" => "1"}

                    acc
                    |> Map.put(w, append.(acc[w], %{opponent_rank: bl, colour: "w", result: res}))
                    |> Map.put(
                      bl,
                      append.(acc[bl], %{opponent_rank: w, colour: "b", result: inv[res]})
                    )

                  :wf ->
                    acc
                    |> Map.put(w, append.(acc[w], %{opponent_rank: bl, colour: "w", result: "-"}))
                    |> Map.put(
                      bl,
                      append.(acc[bl], %{opponent_rank: w, colour: "b", result: "+"})
                    )

                  :bf ->
                    acc
                    |> Map.put(w, append.(acc[w], %{opponent_rank: bl, colour: "w", result: "+"}))
                    |> Map.put(
                      bl,
                      append.(acc[bl], %{opponent_rank: w, colour: "b", result: "-"})
                    )
                end
            end)

          withdrawn =
            if round >= 3 and MapSet.size(withdrawn) < div(n, 4) and :rand.uniform(100) <= 15 do
              MapSet.put(withdrawn, Enum.random(1..n))
            else
              withdrawn
            end

          {:cont, {players, withdrawn}}
      end
    end
  end)
end)

# --- report -----------------------------------------------------------------

sum = fn tag -> tally |> :ets.lookup(tag) |> length() end
rows = fn tag -> tally |> :ets.lookup(tag) |> Enum.map(&elem(&1, 1)) end

positions = sum.(:position)

# Positions from one tournament share a first-coloured round, so they are
# NOT independent samples. Counting the distinct tournaments a result came
# from is the honest denominator to quote alongside the position count.
seeds_of = fn tag ->
  tag
  |> rows.()
  |> Enum.map(&(&1 |> String.split(" ") |> Enum.at(1)))
  |> Enum.uniq()
  |> length()
end

IO.puts("""

#{count} tournaments, #{rounds} rounds, round one all byes, no `152` after round two.

READABLE POSITIONS (`152 W` and `152 B` gave different pairings, and the
silent run reproduced exactly one of them): #{positions}
  drawn from #{seeds_of.(:position)} distinct tournaments. Positions inside one
  tournament share a first-coloured round and are not independent.

INSTRUMENT SELF-CHECK - what the silent run was read as deducing.
Both rows must be non-zero, or bbpPairings was only ever observed
defaulting and nothing below is a measurement.

    deduced White : #{sum.({:bbp_says, "w"})}
    deduced Black : #{sum.({:bbp_says, "b"})}
""")

IO.puts("""
Q1  OWN (the coloured player's own arrival number)
      vs TOP (the top-of-board arrival number - the exact inverse)

    positions where the two readings predict the SAME draw : #{sum.(:ab_agree)}
    positions where they predict OPPOSITE draws            : #{sum.(:ab_split)}
      (from #{seeds_of.(:ab_detail)} distinct tournaments)
      of those, bbpPairings followed OWN                   : #{sum.({:ab_followed, :own})}
      of those, bbpPairings followed TOP                   : #{sum.({:ab_followed, :top})}
      of those, bbpPairings followed NEITHER               : #{sum.({:ab_followed, :neither})}
    positions where TOP could not be read                  : #{sum.(:top_unreadable)}

    of the OPPOSITE-draw positions, OWN said White         : #{sum.({:ab_split_own, "w"})}
    of the OPPOSITE-draw positions, OWN said Black         : #{sum.({:ab_split_own, "b"})}
""")

IO.puts("""
Q2  OWN on the ARRIVAL number vs OWN on the RAW TPN (the overturned reading)

    positions where the two coincide          : #{sum.(:tpn_agree)}
    positions where they predict OPPOSITE     : #{sum.(:tpn_split)}
      of those, bbpPairings followed ARRIVAL  : #{sum.({:tpn_followed, :arrival})}
      of those, bbpPairings followed RAW TPN  : #{sum.({:tpn_followed, :raw_tpn})}
      of those, bbpPairings followed NEITHER  : #{sum.({:tpn_followed, :neither})}
""")

IO.puts("""
Q3  Does OWN predict bbpPairings' deduction over ALL readable positions?

    OWN correct : #{sum.({:own_predicts, true})}
    OWN wrong   : #{sum.({:own_predicts, false})}
""")

IO.puts("""
Q4  CONFORMANCE - this engine vs bbpPairings on the same no-`152` files.
    A DIFFERENT quantity from Q1-Q3: it compares whole pairings, colours
    included, and this engine is in the loop.

    positions compared : #{sum.(:conformance_position)}
    identical          : #{sum.(:conformance_ok)}
    differing          : #{length(rows.(:conformance_bad))}
    raised             : #{length(rows.(:conformance_raised))}
""")

for tag <- [:ab_detail, :conformance_bad, :conformance_raised] do
  r = rows.(tag)

  if r != [] do
    IO.puts("#{tag} (#{length(r)}):")
    r |> Enum.take(30) |> Enum.each(&IO.puts("   - #{&1}"))
    IO.puts("")
  end
end

IO.puts("positions discarded, and why:")

for tag <- [:blind, :neither, :unreadable, :refused, :starved] do
  r = rows.(tag)
  IO.puts("  #{tag}: #{length(r)}")

  if tag in [:refused, :neither, :unreadable] do
    r |> Enum.take(5) |> Enum.each(&IO.puts("     - #{&1}"))
  end
end
