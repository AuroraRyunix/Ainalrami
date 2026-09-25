# Compares Ainalrami.Tiebreaks with FIDE's TieBreakServer, player by player.
#
#     mix run tools/tiebreak_compare.exs [--codes "BH BH/C1 SB"] [--rr] file.trf ...
#     mix run tools/tiebreak_compare.exs --random-lists SEED [--rr] --dir DIR
#
# `--random-lists SEED` draws a tie-break list per tournament
# (tools/tiebreak_random_list.exs) and compares the values of every code in
# it and the final ranks under it, instead of the fixed `--codes`/`--rank`.
#
# TieBreakServer (Otto Milvang, MIT, (c) FIDE) is the reference the checklist
# expects us to be tested against; it is run, never linked. Located via
# TBS_DIR (default ../TieBreakServer) and run with TBS_PYTHON (it needs 3.11+
# for enum.EnumType). Every code is sent with /V2026 so it applies the 2026
# rules even to a tournament that started before they did - TieBreakServer
# otherwise picks the rules by start date.
#
# Prints, per file, each code's mismatches with the first few players, and a
# total at the end. Exit status 1 when anything disagrees.

alias Ainalrami.Tiebreaks
alias Ainalrami.Tiebreaks.Event
alias Ainalrami.Trf

Code.require_file("tiebreak_random_list.exs", __DIR__)

{opts, files, _} =
  OptionParser.parse(System.argv(),
    strict: [codes: :string, rr: :boolean, examples: :integer, rank: :string, dir: :string, random_lists: :integer]
  )

# --dir DIR: every .trf in it, in seed order - thousands of paths do not fit
# on a Windows command line.
files =
  case opts[:dir] do
    nil ->
      files

    dir ->
      files ++
        # Forward slashes: a backslash in a wildcard pattern is an escape,
        # so a Windows path matched nothing.
        (dir
         |> String.replace("\\", "/")
         |> Path.join("*.trf")
         |> Path.wildcard()
         |> Enum.sort_by(&(Regex.run(~r"(\d+)\.trf$", &1) |> List.last() |> String.to_integer())))
  end

codes =
  String.split(
    opts[:codes] ||
      "PTS BH BH/C1 BH/C2 BH/M1 BH/M2 FB FB/C1 SB SB/C1 PS PS/C1 WIN WON BPG BWG REP STD " <>
        "AOB AOB/F ARO/U1000 ARO/C1/U1000 TPR/U1000 PTP/U1000 APRO/U1000 APPO/U1000"
  )

tbs_dir = System.get_env("TBS_DIR", Path.expand("../TieBreakServer"))
python = System.get_env("TBS_PYTHON", "python")
examples = opts[:examples] || 3

# Reading 1: the checklist's KS/L1 (limit + 1/2 point) is TieBreakServer's
# KS/L+1 - a bare L1 there is a 1% limit.
tbs_code = fn code -> String.replace(code, ~r"/L(\d)", "/L+\\1") end

# `-n`: the rounds actually in the file. Without it TieBreakServer counts every
# ANNOUNCED round, so a file saved after round 1 of 9 gets eight unplayed
# rounds in every tie-break.
#
# Codes that compute Fore Buchholz go LAST: TieBreakServer leaks state from
# an FB computation into every tie-break after it in the same run (finding A,
# docs/finding-tiebreakserver-2026-09.md). The rows are mapped back to the
# order asked for.
fore? = fn code -> String.starts_with?(code, "FB") or code =~ ~r"^AOB.*/F" end

# A ranking run sends the list as asked (`ordered?`): the order IS the
# ranking. Finding A is then classified, not avoided.
tbs = fn file, codes, rr?, rounds, ordered? ->
  flag = if rr?, do: "-p", else: "-s"

  {plain, fore} =
    if ordered?,
      do: {Enum.with_index(codes), []},
      else: Enum.split_with(Enum.with_index(codes), fn {c, _} -> not fore?.(c) end)

  sent = plain ++ fore

  args =
    [Path.join(tbs_dir, "tiebreakchecker.py"), "-i", file, "-o", "-", flag, "-n", "#{rounds}"] ++
      ["-d", "T", "-t"] ++ Enum.map(sent, fn {c, _} -> tbs_code.(c) <> "/V2026" end)

  # position in the output -> position asked for
  back = sent |> Enum.with_index() |> Map.new(fn {{_c, asked}, at} -> {asked, at} end)

  case System.cmd(python, args, stderr_to_stdout: true, env: [{"PYTHONIOENCODING", "utf-8"}]) do
    {out, 0} ->
      [_header | rows] =
        out |> String.split(~r/\r?\n/, trim: true) |> Enum.drop_while(&(not String.starts_with?(&1, "StartNo")))

      {:ok,
       Map.new(rows, fn row ->
         [start, rank | values] = String.split(row, "\t")
         reordered = for i <- 0..(length(codes) - 1)//1, do: Enum.at(values, back[i])
         {String.to_integer(start), [rank | reordered]}
       end)}

    {out, _} ->
      {:error, out |> String.slice(0, 200)}
  end
end

# {value, decimals printed}. TieBreakServer prints AOB to two decimals; the
# comparison is made at the precision it printed, since that is all it says.
number = fn
  nil -> {nil, 0}
  "" -> {nil, 0}
  "None" -> {nil, 0}
  text ->
    decimals = case String.split(text, "."), do: ([_, d] -> String.length(d); _ -> 0)
    case Float.parse(text), do: ({v, _} -> {v, decimals}; :error -> {text, 0})
end

# "No games to average over": we say nil, TieBreakServer prints 0. They rank
# the same, so they are the same answer.
same? = fn
  mine, {their, decimals} ->
    mine = if is_nil(mine), do: 0.0, else: mine * 1.0
    their = if is_nil(their), do: 0.0, else: their

    is_number(their) and
      abs(Float.round(mine, min(decimals, 15)) - their) < 0.001
end

# Reading 8 (docs/conformance-c07-tiebreaks.md): TieBreakServer scores STD
# against a draw's value, C.07 7.7 against the scheduled opponent. A STD
# mismatch that TieBreakServer's rule explains exactly is that known reading
# difference, counted apart from the errors.
std_by_draw = fn event, id ->
  draw = event.points.draw

  event.participants[id].rounds
  |> Map.values()
  |> Enum.map(fn r ->
    cond do
      r.points > draw + 1.0e-9 -> 1.0
      abs(r.points - draw) <= 1.0e-9 -> 0.5
      true -> 0.0
    end
  end)
  |> Enum.sum()
end

# Finding B (docs/finding-tiebreakserver-2026-09.md): TieBreakServer's SB cut
# picks the VUR with the lowest dummy SCORE, not the lowest contribution.
# This reproduces its rule exactly; an SB/Cn mismatch it explains is that
# finding, not an error of ours.
sb_cut_tbs_style = fn event, id, n ->
  ctx = Ainalrami.Tiebreaks.Individual.context(event)
  p = event.participants[id]

  elements =
    for r <- 1..event.rounds//1 do
      round = p.rounds[r]

      score =
        if round.kind == :played,
          do: ctx.adjusted[round.opponent],
          else:
            Ainalrami.Tiebreaks.Unplayed.dummy_score(p.rounds, r, ctx.scores[id], ctx.adjusted, event)

      %{score: score, value: score * round.points, vur: Ainalrami.Tiebreaks.Unplayed.vur?(round)}
    end

  elements =
    Enum.reduce(1..n//1, elements, fn _, list ->
      case list do
        [] ->
          []

        _ ->
          all = Enum.sort_by(list, &{&1.score, &1.value})
          exp = Enum.sort_by(list, &{if(&1.vur, do: 0, else: 1), &1.score, &1.value})
          victim = if hd(all).value > hd(exp).value, do: hd(all), else: hd(exp)
          List.delete(list, victim)
      end
    end)

  elements |> Enum.map(& &1.value) |> Enum.sum()
end

random_seed = opts[:random_lists]
rr? = opts[:rr] || false

# ---- rank classification ------------------------------------------------
#
# A rank difference is "known" only when a documented cause accounts for
# all of it. The test: rank the field again, using TieBreakServer's own
# printed values for every value code and OUR direct encounter for DE
# ("replay").
#
#   - Replay gives TieBreakServer's ranks: the difference comes from values
#     alone. It is known when every value on which the ranking run disagrees
#     with ours is itself a known difference: reading 8 (STD), finding B
#     (SB/Cn), or finding A - the ranking run's value differs from the one
#     TieBreakServer gives with the Fore codes sent last, and that one agrees
#     with ours (or is itself known).
#   - Replay does not give its ranks: the direct encounter differs. Known
#     only as finding C: two of the group tied at the DE step met more than
#     once.
#
# Anything else is unexplained and counted as a mismatch.

direction = fn code ->
  parsed = Ainalrami.Tiebreaks.Code.parse!(code)
  asc? = parsed.name == "TPN"
  if asc? != parsed.reverse?, do: :asc, else: :desc
end

rank_key = fn
  {v, _} when is_number(v) -> Float.round(v * 1.0, 6)
  _ -> -1.0e18
end

de_code? = &TiebreakRandomList.de?/1

replay = fn event, rank_codes, their_rows ->
  indexed = Enum.with_index(rank_codes)

  order = fn order, group, codes ->
    case {group, codes} do
      {[_], _} ->
        [group]

      {_, []} ->
        [group]

      {_, [{code, i} | rest]} ->
        subgroups =
          if de_code?.(code) do
            Ainalrami.Tiebreaks.DirectEncounter.order(group, Ainalrami.Tiebreaks.Code.parse!(code), event)
          else
            group
            |> Enum.group_by(&rank_key.(number.(Enum.at(their_rows[&1], i + 1))))
            |> Enum.sort_by(fn {k, _} -> k end, direction.(code))
            |> Enum.map(fn {_, m} -> Enum.sort(m) end)
          end

        Enum.flat_map(subgroups, &order.(order, &1, rest))
    end
  end

  {rows, _} =
    order.(order, Map.keys(event.participants) |> Enum.sort(), indexed)
    |> Enum.flat_map_reduce(1, fn g, next -> {Enum.map(g, &{&1, next}), next + length(g)} end)

  Map.new(rows)
end

# The group each participant is in when the DE entry is reached, by our
# values of the codes before it.
de_groups = fn event, rank_codes, ours_values ->
  case Enum.find_index(rank_codes, de_code?) do
    nil ->
      []

    at ->
      before = Enum.take(rank_codes, at)

      Map.keys(event.participants)
      |> Enum.group_by(fn id -> Enum.map(before, &rank_key.({ours_values[&1][id], 0})) end)
      |> Map.values()
  end
end

rematch_in? = fn event, group ->
  Enum.any?(group, fn a ->
    event.participants[a].rounds
    |> Map.values()
    |> Enum.filter(&(&1.kind == :played and &1.opponent in group))
    |> Enum.frequencies_by(& &1.opponent)
    |> Enum.any?(fn {_, n} -> n > 1 end)
  end)
end

# {known?, reasons} for one value disagreement in the ranking run.
# `value_run` is TieBreakServer's value from the run with Fore codes last:
# {value, decimals}, {:known, {value, decimals}} (a known difference
# there), or nil (not asked).
value_known = fn event, code, id, mine, rank_value, value_run ->
  their = elem(rank_value, 0)

  cond do
    # Reading 12: TieBreakServer ranks AOB by its value rounded to two
    # decimals; C.07 8.2 names no rounding and we rank the exact average.
    String.starts_with?(code, "AOB") and is_number(mine) and is_number(their) and
      same?.(mine, rank_value) and abs(mine - their) > 1.0e-9 ->
      {true, ["reading 12"]}

    same?.(mine, rank_value) ->
      {true, []}

    String.starts_with?(code, "STD") and is_number(their) and
        abs(std_by_draw.(event, id) - their) < 0.001 ->
      {true, ["reading 8"]}

    (cut = Regex.run(~r"^SB/C(\d)$", code)) && is_number(their) &&
        abs(sb_cut_tbs_style.(event, id, cut |> List.last() |> String.to_integer()) - their) < 0.001 ->
      {true, ["finding B"]}

    match?({v, _} when is_number(v) or is_nil(v), value_run) and same?.(mine, value_run) and
        not same?.(if(is_number(their), do: their), value_run) ->
      {true, ["finding A"]}

    # Findings A and B together: the Fore-last run's value is itself a
    # known difference, and the ranking run's differs from it only by the
    # list position.
    match?({:known, _}, value_run) and
        not same?.(if(is_number(their), do: their), elem(value_run, 1)) ->
      {true, ["finding A", "finding B"]}

    true ->
      {false, []}
  end
end

totals =
  for file <- files,
      reduce: %{files: 0, skipped: 0, mismatches: 0, compared: 0, known: 0, ranks: 0, rank_known: 0} do
    acc ->
      name = Path.basename(file)

      list = if random_seed, do: TiebreakRandomList.draw(if(rr?, do: :rr, else: :swiss), random_seed, TiebreakRandomList.number(file))

      codes = if list, do: Enum.reject(list, de_code?), else: codes
      rank_list = if list, do: Enum.join(list, " "), else: opts[:rank]

      with {:ok, parsed} <- (try do {:ok, Trf.parse(File.read!(file))} rescue e -> {:error, Exception.message(e)} end),
           event = Event.from_trf(parsed, predetermined?: rr?),
           {:ok, ours} <- Tiebreaks.compute(event, codes),
           {:ok, theirs} <- (if codes == [], do: {:ok, %{}}, else: tbs.(file, codes, rr?, event.rounds, false)) do
        IO.puts("== #{name}: #{map_size(event.participants)} players, #{event.rounds} rounds" <> if(list, do: ", list #{Enum.join(list, " ")}", else: ""))

        # The value of each code for each player, and whether it agrees
        # (or is a known difference).
        results =
          for {code, i} <- Enum.with_index(codes) do
            ours_code = ours[code]

            # Bound through a one-element list, not `x = ...` filters: a
            # filter drops nil, and a nil on one side is exactly a mismatch.
            bad =
              for {id, row} <- theirs,
                  [{mine, their}] <- [
                    [
                      {if(ours_code == :dropped, do: nil, else: ours_code[id]),
                       number.(Enum.at(row, i + 1))}
                    ]
                  ],
                  not same?.(mine, their),
                  do: {id, mine, elem(their, 0)}

            {known, bad} =
              cond do
                String.starts_with?(code, "STD") ->
                  Enum.split_with(bad, fn {id, _m, t} ->
                    is_number(t) and abs(std_by_draw.(event, id) - t) < 0.001
                  end)

                cut = Regex.run(~r"^SB/C(\d)$", code) ->
                  n = cut |> List.last() |> String.to_integer()

                  Enum.split_with(bad, fn {id, _m, t} ->
                    is_number(t) and abs(sb_cut_tbs_style.(event, id, n) - t) < 0.001
                  end)

                true ->
                  {[], bad}
              end

            unless known == [] do
              why = if String.starts_with?(code, "STD"), do: "reading 8", else: "TieBreakServer finding B"
              IO.puts("   #{code}: #{length(known)} known (#{why})")
            end

            unless bad == [] do
              sample = bad |> Enum.sort() |> Enum.take(examples) |> Enum.map_join(", ", fn {id, m, t} -> "#{id}: ours #{inspect(m)} theirs #{inspect(t)}" end)
              IO.puts("   #{code}: #{length(bad)} differ - #{sample}")
            end

            {length(bad), map_size(theirs), length(known), MapSet.new(known, &elem(&1, 0))}
          end

        known_ids = codes |> Enum.zip(results) |> Map.new(fn {c, r} -> {c, elem(r, 3)} end)

        # With a rank list: the final ranks under that list, ours against
        # theirs - the part of the checker's job (VCL4THP Q21) that values
        # alone do not show, direct encounter included.
        {rank_bad, rank_known, ranks} =
          case rank_list do
            nil ->
              {0, 0, 0}

            list ->
              # The score first, for both: Ainalrami puts it there itself,
              # TieBreakServer ranks by whatever it is sent first.
              rank_codes =
                case String.split(list) do
                  ["PTS" | _] = codes -> codes
                  codes -> ["PTS" | codes]
                end

              {:ok, ours_ranked} = Tiebreaks.rank(event, rank_codes)
              {:ok, their_ranked} = tbs.(file, rank_codes, rr?, event.rounds, true)
              mine = Map.new(ours_ranked, &{&1.id, &1.rank})

              bad =
                for {id, [rank | _]} <- their_ranked,
                    String.to_integer(rank) != mine[id],
                    do: {id, mine[id], String.to_integer(rank)}

              {known, why} =
                if bad == [] do
                  {false, []}
                else
                  value_codes = Enum.reject(rank_codes, de_code?)
                  {:ok, ours_all} = Tiebreaks.compute(event, value_codes)
                  ours_all = Map.new(ours_all, fn {c, m} -> {c, if(m == :dropped, do: %{}, else: m)} end)
                  replayed = replay.(event, rank_codes, their_ranked)
                  their_final = Map.new(their_ranked, fn {id, [r | _]} -> {id, String.to_integer(r)} end)

                  if replayed == their_final do
                    checks =
                      for {code, i} <- Enum.with_index(rank_codes),
                          not de_code?.(code),
                          {id, row} <- their_ranked do
                        value_run =
                          cond do
                            code in codes and MapSet.member?(known_ids[code], id) ->
                              {:known, number.(Enum.at(theirs[id], Enum.find_index(codes, &(&1 == code)) + 1))}

                            code in codes -> number.(Enum.at(theirs[id], Enum.find_index(codes, &(&1 == code)) + 1))
                            true -> nil
                          end

                        value_known.(event, code, id, ours_all[code][id], number.(Enum.at(row, i + 1)), value_run)
                      end

                    reasons = checks |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq()
                    {Enum.all?(checks, &elem(&1, 0)) and reasons != [], reasons}
                  else
                    groups = de_groups.(event, rank_codes, ours_all)
                    ids = MapSet.new(bad, &elem(&1, 0))

                    c? =
                      Enum.all?(ids, fn id ->
                        g = Enum.find(groups, [], &(id in &1))
                        rematch_in?.(event, g)
                      end)

                    {groups != [] and c?, if(c?, do: ["finding C"], else: ["direct encounter"])}
                  end
                end

              unless bad == [] do
                sample =
                  bad
                  |> Enum.sort()
                  |> Enum.take(examples)
                  |> Enum.map_join(", ", fn {id, m, t} -> "#{id}: ours #{m} theirs #{t}" end)

                label = if known, do: "known (#{Enum.join(why, ", ")})", else: "UNEXPLAINED"
                IO.puts("   rank under #{list}: #{length(bad)} differ, #{label} - #{sample}")
              end

              if known, do: {0, length(bad), 1}, else: {length(bad), 0, 1}
          end

        %{
          acc
          | files: acc.files + 1,
            mismatches: acc.mismatches + rank_bad + Enum.sum(Enum.map(results, &elem(&1, 0))),
            compared: acc.compared + Enum.sum(Enum.map(results, &elem(&1, 1))),
            known: acc.known + rank_known + Enum.sum(Enum.map(results, &elem(&1, 2))),
            ranks: acc.ranks + ranks,
            rank_known: acc.rank_known + rank_known
        }
      else
        {:error, reason} ->
          IO.puts("-- #{name}: skipped (#{String.slice(to_string(reason), 0, 120)})")
          %{acc | skipped: acc.skipped + 1}
      end
  end

IO.puts(
  "\nfiles #{totals.files}, skipped #{totals.skipped}, values compared #{totals.compared}, " <>
    "mismatches #{totals.mismatches}, known differences #{totals.known}, " <>
    "rankings compared #{totals.ranks}, rank known #{totals.rank_known}"
)

if totals.mismatches > 0, do: System.halt(1)
