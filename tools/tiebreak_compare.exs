# Compares Ainalrami.Tiebreaks with FIDE's TieBreakServer, player by player.
#
#     mix run tools/tiebreak_compare.exs [--codes "BH BH/C1 SB"] [--rr] file.trf ...
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

{opts, files, _} =
  OptionParser.parse(System.argv(),
    strict: [codes: :string, rr: :boolean, examples: :integer, rank: :string, dir: :string]
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

tbs = fn file, codes, rr?, rounds ->
  flag = if rr?, do: "-p", else: "-s"
  {plain, fore} = Enum.split_with(Enum.with_index(codes), fn {c, _} -> not fore?.(c) end)
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

totals =
  for file <- files, reduce: %{files: 0, skipped: 0, mismatches: 0, compared: 0, known: 0} do
    acc ->
      name = Path.basename(file)

      with {:ok, parsed} <- (try do {:ok, Trf.parse(File.read!(file))} rescue e -> {:error, Exception.message(e)} end),
           event = Event.from_trf(parsed, predetermined?: opts[:rr] || false),
           {:ok, ours} <- Tiebreaks.compute(event, codes),
           {:ok, theirs} <- tbs.(file, codes, opts[:rr] || false, event.rounds) do
        IO.puts("== #{name}: #{map_size(event.participants)} players, #{event.rounds} rounds")

        # With --rank LIST: the final ranks under that list, ours against
        # theirs - the part of the checker's job (VCL4THP Q21) that values
        # alone do not show, direct encounter included.
        rank_bad =
          case opts[:rank] do
            nil ->
              0

            list ->
              rank_codes = String.split(list)
              {:ok, ours_ranked} = Tiebreaks.rank(event, rank_codes)
              {:ok, their_ranked} = tbs.(file, rank_codes, opts[:rr] || false, event.rounds)
              mine = Map.new(ours_ranked, &{&1.id, &1.rank})

              bad =
                for {id, [rank | _]} <- their_ranked,
                    String.to_integer(rank) != mine[id],
                    do: {id, mine[id], String.to_integer(rank)}

              unless bad == [] do
                sample =
                  bad
                  |> Enum.sort()
                  |> Enum.take(examples)
                  |> Enum.map_join(", ", fn {id, m, t} -> "#{id}: ours #{m} theirs #{t}" end)

                IO.puts("   rank under #{list}: #{length(bad)} differ - #{sample}")
              end

              length(bad)
          end

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

            {length(bad), map_size(theirs), length(known)}
          end

        %{
          acc
          | files: acc.files + 1,
            mismatches: acc.mismatches + rank_bad + Enum.sum(Enum.map(results, &elem(&1, 0))),
            compared: acc.compared + Enum.sum(Enum.map(results, &elem(&1, 1))),
            known: acc.known + Enum.sum(Enum.map(results, &elem(&1, 2)))
        }
      else
        {:error, reason} ->
          IO.puts("-- #{name}: skipped (#{String.slice(to_string(reason), 0, 120)})")
          %{acc | skipped: acc.skipped + 1}
      end
  end

IO.puts(
  "\nfiles #{totals.files}, skipped #{totals.skipped}, values compared #{totals.compared}, " <>
    "mismatches #{totals.mismatches}, known differences #{totals.known}"
)

if totals.mismatches > 0, do: System.halt(1)
