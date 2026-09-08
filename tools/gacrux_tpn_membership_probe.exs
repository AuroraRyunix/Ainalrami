# Does Gacrux number the same players Article 5.2.5's parity is taken on?
#
#   GACRUX_DIR=../TieBreakServer GACRUX_PYTHON=py \
#     MIX_ENV=test mix run tools/gacrux_tpn_membership_probe.exs
#
# ## Why this exists
#
# The 2026-08-29 corpus fired the 5.2.5 consistency check seventeen times,
# all on Gacrux, all in round 2. Reading both sources (2026-09-08) showed
# the check CANNOT detect a 5.2.5 violation in Gacrux: its E.5 branch
# (`pairingdutch.py`, "# E.5") is one tournament-wide constant
# `self.topcolor` combined with one parity test on `hightpn`, so every E.5
# board in a round implies the same initial colour by construction. An
# internal contradiction is not something Gacrux can produce.
#
# Board classification agrees (`crosstabledutch.color_preference` returns
# "nc" for a player with no played games, so the same boards reach E.5), and
# so does the Article 1.2 ordering (`scorelevel` comes from
# `sorted(set(...))`, ASCENDING, so a higher scorelevel is a higher score;
# the E.5 test is score descending then number ascending, which is 1.2).
#
# That leaves one free variable: WHICH PLAYERS GET NUMBERED. Ainalrami
# numbers those `arrived_for?/2` admits - any played game, `U`, `+` with or
# without an opponent, `-` only WITH one; `H`, `F`, `Z`, opponentless `-`
# and a blank round do not. Gacrux numbers `rfp or rip` (`crosstable.py`,
# "# update tpn"), consecutively over ascending rank.
#
# Both number CONSECUTIVELY, which is what makes a divergence matter: one
# player whom one rule counts and the other does not shifts every
# higher-ranked player by one and flips their parity. Where that shift is
# uniform across a round the consistency check calls it `:consistent`, so
# Gacrux's colours could be wrong on whole rounds with that check silent.
# This probe asks the question the check cannot.
#
# `tools/rip_probe.exs` already refuted a different hypothesis about the
# same field - whether Gacrux renumbers around someone who has played but
# sits THIS round out. It does not, and neither does bbpPairings. This is
# about the round-1 result CODES instead.
#
# ## How the number is read, and the three traps on the way
#
# `pairingchecker.py` line 338 picks `sno = "tpn" if "TPN" in
# self.params["experimental"] else "cid"`, so pairing the same file twice -
# once plain, once with `-x TPN` - labels the same boards two ways and
# zipping them recovers the mapping with nothing inferred.
#
# TRAP 1: `arrived_for?/2` is "in THIS round's pairing pool, OR
# participated in a strictly earlier round". In round 2 every active player
# is in the pool, so a probe that simply hands ten players ten different
# round-1 codes measures NOTHING - it prints 1..10 against 1..10 and reads
# as agreement. The code only decides membership for somebody held OUT of
# the round, so each tested player carries their round-1 code and a round-2
# zero-point bye.
#
# TRAP 2: a player held out of the round is on no board, so `-x TPN` never
# prints their number. Their membership is only observable through the
# SHIFT it causes - both engines number ascending by rank, so a tested
# player at rank 1 moves everyone above them by one iff it was counted.
# Hence one run per code, tested player at rank 1, four plain players
# behind them whose numbers are readable.
#
# TRAP 3, which this probe did NOT get past, and the reason its table is a
# NEGATIVE RESULT rather than a finding. Read this before believing the
# output.
#
# Run it and every code, including the control, comes back "counted" from
# Gacrux. That reads as "Gacrux counts H, F, Z and the opponentless `-`
# where Ainalrami does not", which would be a real 5.2.5 divergence. It is
# not what the run shows.
#
# Gacrux's numbering is `rfp or rip`. `rip` is `1 if game["played"] or
# game["opponent"] > 0` (`tiebreak.py`, "# number of gamesin pairing"), so
# every code under test here scores `rip` 0 - none was played and none had
# an opponent. The tested player was therefore numbered on `rfp` alone, and
# `rfp` is set false in exactly one place: `crosstable.py`,
# `if i in cmps and not cmps[i]["present"] and not self.checkonly`.
#
# So Gacrux numbered them because it considered them PRESENT for round 2 -
# it does not read a round-2 zero-point bye as sitting the round out, where
# `active_this_round?/2` does. The two engines disagreed about who is in the
# round, not about who gets a number, and the round-1 code never entered
# into it. Every row of the table is that one disagreement wearing six
# different hats, and the control proves it: a player who never appeared at
# all was "counted" too, which no reading of `rip` allows.
#
# What would actually measure the numbering: hold the tested player out in
# a way Gacrux honours - find what sets `present` and use that - so `rfp` is
# false and `rip` alone decides. Until then the numbering hypothesis for the
# seventeen firings is untested, not confirmed and not refuted.
#
# All three traps have the shape `tools/gacrux_5_2_5_probe.exs` warns about
# in its own header, and `tools/rip_probe.exs` records the cost of missing
# one: an instrument that could not have said no, read as though it had said
# yes.

alias Ainalrami.Pairing
alias Ainalrami.Test.Gacrux

defmodule TpnProbe do
  @dir System.get_env("GACRUX_DIR", "../TieBreakServer")
  @python System.get_env("GACRUX_PYTHON", "python")

  # Every round-1 entry whose membership the SPP's 2026-08-27 reading turns
  # on, with what `arrived_for?/2` says about each.
  # The last entry is the CONTROL, and it is not optional. Every real code
  # here could come back "counted" from an instrument that cannot say
  # anything else - if Gacrux simply numbered by rank, the lowest number
  # among ranks 2-5 would be 2 whatever rank 1 held, and this probe would
  # report unanimous agreement while measuring nothing. A player who never
  # appeared in round 1 at all is the case both rules must skip: `rip` is
  # zero and `rfp` is false. If the control reads "counted", the hold-out
  # did not hold and every other row on this table is void - which is what
  # happens today. See TRAP 3.
  @codes [
    {"U", "pairing-allocated bye", 1.0},
    {"H", "half-point bye", 0.5},
    {"F", "full-point bye", 1.0},
    {"Z", "zero-point bye", 0.0},
    {"+", "forfeit win, no opponent", 1.0},
    {"-", "forfeit loss, no opponent", 0.0},
    {:absent, "CONTROL: never appeared at all", 0.0}
  ]

  def codes, do: @codes

  def pair(trf_text, experimental?) do
    dir = Path.join(System.tmp_dir!(), "tpn-probe-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    input = Path.join(dir, "input.trf")
    output = Path.join(dir, "output.txt")
    File.write!(input, trf_text)

    args =
      [
        Path.join(@dir, "pairingchecker.py"),
        "-i",
        input,
        "-o",
        output,
        "-p",
        "-dT",
        "-m",
        "dutch"
      ] ++ if experimental?, do: ["-x", "TPN"], else: []

    case System.cmd(@python, args, stderr_to_stdout: true) do
      {_out, 0} -> {:ok, output |> File.read!() |> parse()}
      {out, code} -> {:error, {code, String.slice(out, 0, 400)}}
    end
  end

  # The same shape javafo and bbpPairings write: a count line, then one
  # "white black" per pair, 0 for the pairing-allocated bye.
  defp parse(text) do
    text
    |> String.split(~r/\r\n|\n|\r/, trim: true)
    |> Enum.drop(1)
    |> Enum.flat_map(fn line ->
      case line |> String.split(~r/\s+/, trim: true) |> Enum.map(&Integer.parse/1) do
        [{w, ""}, {b, ""}] -> [{w, if(b == 0, do: nil, else: b)}]
        _ -> []
      end
    end)
  end

  # Rank 1 holds `code` in round 1 and a zero-point bye in round 2, so it is
  # out of round 2's pairing and its number rests entirely on whether round
  # 1 counted. Ranks 2-5 played each other in round 1 and carry no round-2
  # entry, so they are the round, and their numbers are what betrays rank
  # 1's membership: 2,3,4,5 if it was counted, 1,2,3,4 if it was not.
  def players(code, points) do
    blank = %{opponent_rank: nil, colour: nil, result: nil}

    round_one =
      case code do
        :absent -> blank
        _ -> %{opponent_rank: nil, colour: nil, result: code}
      end

    tested = %{
      rank: 1,
      name: "Tested",
      points: points,
      games: [round_one, %{opponent_rank: nil, colour: nil, result: "Z"}]
    }

    plain =
      for {rank, opp, colour, result, pts} <- [
            {2, 3, "w", "1", 1.0},
            {3, 2, "b", "0", 0.0},
            {4, 5, "w", "1", 1.0},
            {5, 4, "b", "0", 0.0}
          ] do
        %{
          rank: rank,
          name: "P#{rank}",
          points: pts,
          games: [%{opponent_rank: opp, colour: colour, result: result}]
        }
      end

    for p <- [tested | plain] do
      Map.merge(p, %{
        title: "",
        federation: "",
        sex: "",
        fide_rating: 2000 - p.rank,
        fide_number: nil,
        birth_date: ""
      })
    end
  end

  # Built by BYTE column rather than through `Trf.serialize/2`, because two
  # of the six codes are exactly what that writer refuses: `0000 - +` and
  # `0000 - -`, an arbiter's forfeit win and forfeit loss with nobody on the
  # other side. `Trf.parse/1` accepts them (its `allow_dangling_playing_code`
  # tolerance), bbpPairings writes them, and they are the two whose
  # membership is least obvious - the Ainalrami rule counts the `+` and not
  # the `-`, the one place membership turns on the OPPONENT field rather
  # than the result code. A probe that skipped them would be asking the easy
  # half of the question.
  def trf(players) do
    header = ["012 TPN membership", "022 Probe", "062 #{length(players)}", "082 0", "142 5"]

    rows =
      for p <- players do
        base = [
          {1, "001"},
          {5, String.pad_leading(to_string(p.rank), 4)},
          {15, p.name},
          {49, String.pad_leading(to_string(p.fide_rating), 4)},
          {81, String.pad_leading(:erlang.float_to_binary(p.points / 1, decimals: 1), 4)},
          {86, String.pad_leading(to_string(p.rank), 4)}
        ]

        # Rounds at 92 + 10*(n-1): the id four wide, then the colour and the
        # result one each with a blank between - `Ainalrami.Trf`'s own
        # `round_cols/1` cadence.
        games =
          p.games
          |> Enum.with_index()
          |> Enum.flat_map(fn {g, i} ->
            at = 92 + i * 10

            [
              {at, String.pad_leading(to_string(g.opponent_rank || 0), 4)},
              {at + 5, g.colour || "-"},
              {at + 7, g.result || ""}
            ]
          end)

        row(base ++ games)
      end

    Enum.map_join(header ++ rows, "", &(&1 <> "\r\n"))
  end

  defp row(pairs) do
    Enum.reduce(pairs, "", fn {col, text}, acc ->
      acc <> String.duplicate(" ", max(col - 1 - byte_size(acc), 0)) <> text
    end)
  end

  # Did Gacrux number rank 1? Read off the plain players' own numbers: the
  # lowest number among ranks 2-5 is 2 when rank 1 was counted and 1 when it
  # was not.
  def gacrux_counted_rank_one?(players) do
    with {:ok, by_cid} <- pair(trf(players), false),
         {:ok, by_tpn} <- pair(trf(players), true),
         true <- length(by_cid) == length(by_tpn) and by_cid != [] do
      mapping =
        [by_cid, by_tpn]
        |> Enum.zip()
        |> Enum.flat_map(fn {{w1, b1}, {w2, b2}} ->
          [{w1, w2}] ++ if(is_nil(b1) or is_nil(b2), do: [], else: [{b1, b2}])
        end)
        |> Map.new()

      case Map.values(mapping) do
        [] -> {:error, :no_boards}
        numbers -> {:ok, Enum.min(numbers) == 2, mapping}
      end
    else
      false -> {:error, :differing_rounds}
      other -> other
    end
  end
end

unless Gacrux.available?() do
  IO.puts("Gacrux is not available at #{Gacrux.script_path()} - set GACRUX_DIR.")
  System.halt(1)
end

IO.puts("""
Rank 1 holds the code under test in round 1 and sits round 2 out; ranks 2-5
are the round. Whether rank 1 was numbered is read off THEIR numbers.

round-1 code at rank 1                      Ainalrami  Gacrux     verdict\
""")

results =
  for {code, label, points} <- TpnProbe.codes() do
    players = TpnProbe.players(code, points)
    ours = Map.has_key?(Pairing.arrival_numbers(players, 2), 1)

    case TpnProbe.gacrux_counted_rank_one?(players) do
      {:ok, theirs, _mapping} ->
        verdict = if ours == theirs, do: "agree", else: "DIFFER"

        IO.puts(
          String.pad_trailing("#{label} (#{code})", 44) <>
            String.pad_trailing(if(ours, do: "counted", else: "skipped"), 11) <>
            String.pad_trailing(if(theirs, do: "counted", else: "skipped"), 11) <> verdict
        )

        {code, ours, theirs}

      {:error, reason} ->
        IO.puts(
          String.pad_trailing("#{label} (#{code})", 44) <> "could not read: #{inspect(reason)}"
        )

        {code, ours, :unknown}
    end
  end

compared = Enum.reject(results, fn {_c, _o, t} -> t == :unknown end)
differing = for {code, ours, theirs} <- compared, ours != theirs, do: code

# The control is the whole reading. A player who never appeared cannot be
# counted by any rule; if Gacrux counted it, the hold-out did not hold and
# nothing else on the table means anything.
control_counted? = Enum.any?(compared, fn {code, _ours, theirs} -> code == :absent and theirs end)

IO.puts(
  "\n#{length(compared)} of #{length(results)} codes read, #{length(differing)} disagreeing."
)

cond do
  compared == [] ->
    IO.puts("Nothing was measured - the mapping could not be read for any code.")

  differing == [] ->
    IO.puts("""

    The two rules agree on every code the SPP reading turns on. Gacrux's TPN
    membership is Ainalrami's arrival membership, so the numbering cannot be
    the source of the seventeen firings either - and the systematic case the
    consistency check is blind to does not exist for these codes.
    """)

  control_counted? ->
    IO.puts("""

    READING VOID - see TRAP 3 in this file's header.

    Rows differing: #{Enum.join(differing, ", ")}. That looks like a
    numbering divergence and is not one. The CONTROL - a player who never
    appeared in any round - also came back counted, and no reading of
    Gacrux's `rip` allows that: `rip` needs a played game or a real
    opponent, and the control has neither. So the tested player was numbered
    on `rfp`, meaning Gacrux considered them present for this round despite
    the round-2 zero-point bye that holds them out of Ainalrami's.

    The engines disagreed about who is IN THE ROUND. The round-1 code never
    entered into it, and every row above is that one disagreement repeated.
    Fix the hold-out before reading anything else here.
    """)

  true ->
    IO.puts("""

    A real divergence, on: #{Enum.join(differing, ", ")}.

    The control was skipped by both, so the instrument can say no, and these
    rows are the round-1 code deciding membership. Both engines number
    consecutively over ascending rank, so a player one rule counts and the
    other does not shifts every higher-ranked player's parity - a 5.2.5
    colour difference on whole boards, and where the shift is uniform across
    a round the consistency check reports it as consistent and says nothing.
    """)
end
