# Team tie-breaks (C.07 Articles 11-13) against FIDE's TieBreakServer, on
# team tournaments generated here game by game.
#
#     mix run tools/team_tiebreak_compare.exs [--count 100] [--first 1] \
#         [--codes "..."] [--rank "..."] [--keep DIR] [--random-lists SEED]
#
# `--random-lists SEED` ranks each event under its own random team list
# (tools/tiebreak_random_list.exs: the primary score, then one to six team
# codes or individual codes on either score) and compares the values of the
# codes in it, instead of `--codes`/`--rank`.
#
# Neither generator writes board-level team files: Ainalrami pairs teams as
# units, and TieBreakServer's tournamentgenerator.py writes no 013 records.
# So `Ainalrami.TeamTrfGenerator` (test/support/team_trf_generator.ex) does:
# by `rem(seed, 10)` a Swiss, a team round robin, a Scheveningen or a
# Schiller-type event; 3-10 boards; match points 2/1/0 or 3/1/0 in a TRF26
# `362` record; reserves; individual forfeits; whole matches forfeited
# (and double-forfeited), sometimes with a `330` record; pairing-allocated
# byes and free rounds. The pairing is not under test; the tie-breaks
# computed from it are. Predetermined events are compared with `-p` and
# without the Buchholz family (Article 8).
#
# Each file is read back through `Ainalrami.Trf.parse/1` and
# `Ainalrami.Tiebreaks.Team.from_trf/2` - the path the checker takes, match
# points from the file's `362` - and the values and final ranks are
# compared with TieBreakServer's. Known differences are classified by
# cause: findings C-H (docs/finding-tiebreakserver-2026-09.md) and readings
# T4, T6, T7 and T9 (docs/conformance-c07-tiebreaks.md).
#
# Env: TBS_DIR (default ../TieBreakServer), TBS_PYTHON.

alias Ainalrami.Trf
alias Ainalrami.Tiebreaks.Team

Code.require_file("tiebreak_random_list.exs", __DIR__)

{opts, _, _} =
  OptionParser.parse(System.argv(),
    strict: [count: :integer, first: :integer, codes: :string, rank: :string, keep: :string, random_lists: :integer]
  )

count = opts[:count] || 100
first = opts[:first] || 1

codes =
  String.split(
    opts[:codes] ||
      "MPTS GPTS BH:MP BH:GP BH:MP/C1 SB:MP SB:GP EMMSB EMGSB EGMSB EGGSB PS:MP PS:GP " <>
        "BC TBR BBE SSSC"
  )

rank_codes = String.split(opts[:rank] || "MPTS GPTS EDE BH:MP EMGSB")

tbs_dir = System.get_env("TBS_DIR", Path.expand("../TieBreakServer"))
python = System.get_env("TBS_PYTHON", "python")
work = opts[:keep] || Path.join(System.tmp_dir!(), "ain_team_tb")
File.mkdir_p!(work)

# ---- generation ---------------------------------------------------------

Code.require_file("../test/support/team_trf_generator.ex", __DIR__)

# ---- TieBreakServer ----------------------------------------------------

tbs = fn file, codes, rounds, predetermined? ->
  args =
    [Path.join(tbs_dir, "tiebreakchecker.py"), "-i", file, "-o", "-", if(predetermined?, do: "-p", else: "-s"),
     "-n", "#{rounds}", "-d", "T", "-t"] ++
      Enum.map(codes, &(&1 <> "/V2026"))

  case System.cmd(python, args, stderr_to_stdout: true, env: [{"PYTHONIOENCODING", "utf-8"}]) do
    {out, 0} ->
      rows =
        out
        |> String.split(~r/\r?\n/, trim: true)
        |> Enum.drop_while(&(not String.starts_with?(&1, "StartNo")))
        |> tl()

      {:ok, Map.new(rows, fn row ->
        [start, rank | values] = String.split(row, "\t")
        {String.to_integer(start), {String.to_integer(rank), values}}
      end)}

    {out, _} ->
      {:error, String.slice(out, 0, 300)}
  end
end

close? = fn
  nil, t -> t in ["", "0", "None"]
  mine, t ->
    case Float.parse(t) do
      {v, _} ->
        decimals = case String.split(t, "."), do: ([_, d] -> String.length(d); _ -> 0)
        # TieBreakServer rounds its exact decimal half up; ours is a float
        # (15.825 is 15.8249999...), so nudge it before rounding.
        abs(Float.round(mine * 1.0 + 1.0e-9, decimals) - v) < 1.0e-9

      :error -> false
    end
end

# The group-ordering codes have no per-team value in TieBreakServer's
# output that means what ours does (ours is the position given in the tied
# group); they are compared through the ranks instead.
group_codes = ~w(DE EDE EDEBT EDEBB EDET EDEB BC TBR BBE)
fixed_value_codes = Enum.reject(codes, &(&1 in group_codes))
fixed_rank_codes = rank_codes

totals =
  Enum.reduce(first..(first + count - 1), %{files: 0, values: 0, bad: 0, rank_bad: 0, known: 0, errors: 0, sssc_zero: 0, formats: %{}, forfeited: 0, finding_h: 0}, fn seed, acc ->
    %{text: text, rounds: rounds, boards: boards, predetermined?: rr?} =
      generated = Ainalrami.TeamTrfGenerator.generate(seed)

    # Article 8: no Buchholz family when the pairings were fixed in advance.
    buchholz? = fn code -> code |> String.split(["/", ":"]) |> hd() |> Kernel.in(~w(BH FB AOB)) end
    allowed = fn list -> if rr?, do: Enum.reject(list, buchholz?), else: list end

    {value_codes, rank_codes} =
      case opts[:random_lists] do
        nil ->
          {allowed.(fixed_value_codes), allowed.(fixed_rank_codes)}

        list_seed ->
          list = TiebreakRandomList.draw(if(rr?, do: :team_rr, else: :team), list_seed, seed)
          {Enum.reject(list, &(hd(String.split(&1, "/")) in group_codes)), list}
      end

    # Finding F: when the highest achievable primary score is less than the
    # most secondary points one match can give (match points primary, more
    # boards than twice the rounds at 2/1/0), 13.4.2's normalising factor
    # rounds to zero and TieBreakServer stops with a division by zero. We
    # use 1 (reference question Q1). SSSC is left out of such an event's
    # lists and counted as known.
    gp_primary? = match?(["GPTS" | _], rank_codes)
    sssc_zero? =
      not gp_primary? and trunc(rounds * generated.match_points.win / boards) == 0 and
        Enum.any?(rank_codes ++ value_codes, &String.starts_with?(&1, "SSSC"))

    {value_codes, rank_codes} =
      if sssc_zero?,
        do: {Enum.reject(value_codes, &String.starts_with?(&1, "SSSC")), Enum.reject(rank_codes, &String.starts_with?(&1, "SSSC"))},
        else: {value_codes, rank_codes}

    rank_codes = if rank_codes == [], do: ["MPTS"], else: rank_codes
    acc = %{acc | formats: Map.update(acc.formats, generated.format, 1, &(&1 + 1)), forfeited: acc.forfeited + length(generated.forfeited_matches)}
    acc = if sssc_zero?, do: %{acc | known: acc.known + 1, sssc_zero: acc.sssc_zero + 1}, else: acc

    file = Path.join(work, "team#{seed}.trf")
    File.write!(file, text)

    trf = text |> Trf.parse() |> then(fn {:ok, trf} -> trf; trf -> trf end)
    # Match points from the file's 362 record, which is what is under test.
    event = Team.from_trf(trf)

    if event.match_points != generated.match_points or event.predetermined? != rr?,
      do: raise("seed #{seed}: from_trf read #{inspect(event.match_points)}, predetermined #{event.predetermined?}")
    # Reading T9: where boards meet crosswise (Scheveningen, Schiller), a
    # team's board k is its k-th fielded player (ours); TieBreakServer
    # numbers every game of a match by the lower-numbered team's order, for
    # both teams. `board_event` is the event with TieBreakServer's
    # numbering, for replaying its board codes (BC, TBR, BBE, EDE's steps).
    crosswise? = generated.format in [:scheveningen, :schiller]
    game_pts = %{"1" => 1.0, "=" => 0.5, "+" => 1.0, "W" => 1.0, "D" => 0.5}
    by_rank = Map.new(trf.players, &{&1.rank, &1})
    team_of = for {t, i} <- Enum.with_index(trf.teams, 1), p <- t.player_ranks, into: %{}, do: {p, i}

    board_event =
      if crosswise? do
        teams =
          Map.new(event.teams, fn {id, entry} ->
            rounds =
              Map.new(entry.rounds, fn {r, m} ->
                if m.opponent != nil and m.boards != %{} do
                  low = min(id, m.opponent)

                  games =
                    for p <- Enum.at(trf.teams, low - 1).player_ranks,
                        g = Enum.at(by_rank[p].games, r - 1),
                        g && g.opponent_rank && team_of[g.opponent_rank] != low,
                        do: {p, g}

                  boards =
                    games
                    |> Enum.with_index(1)
                    |> Map.new(fn {{p, g}, k} ->
                      mine = if id == low, do: p, else: g.opponent_rank
                      {k, Map.get(game_pts, Enum.at(by_rank[mine].games, r - 1).result, 0.0)}
                    end)

                  {r, %{m | boards: boards}}
                else
                  {r, m}
                end
              end)

            {id, %{entry | rounds: rounds}}
          end)

        %{event | teams: teams}
      else
        event
      end

    # The list's first score is the primary (reading T5), for the steps
    # replayed through Team.order_group/3.
    listed = case rank_codes, do: (["GPTS" | _] -> %{board_event | primary: :gp}; _ -> board_event)

    with {:ok, ours} <- Ainalrami.Tiebreaks.compute(event, value_codes),
         {:ok, theirs} <- tbs.(file, value_codes, rounds, rr?),
         {:ok, ranked} <- Ainalrami.Tiebreaks.rank(event, rank_codes),
         {:ok, their_ranks} <- tbs.(file, rank_codes, rounds, rr?) do
      # Reading T6 (docs/conformance-c07-tiebreaks.md): on game points,
      # TieBreakServer counts WIN and WON per board game, where we count the
      # team's rounds. A value its rule gives exactly is that reading.
      tbs_board_count = fn code, id ->
        players = Enum.at(trf.teams, id - 1).player_ranks
        games = for p <- trf.players, p.rank in players, do: p.games

        Enum.sum(
          for r <- 0..(rounds - 1) do
            round = Enum.map(games, &(Enum.at(&1, r) || %{opponent_rank: nil, result: ""}))

            if Enum.any?(round, & &1.opponent_rank) do
              Enum.count(round, fn g ->
                g.opponent_rank && if(code == "WIN", do: g.result in ["1", "+"], else: g.result == "1")
              end)
            else
              if code == "WIN" and Enum.any?(round, &(&1.result == "U")), do: boards, else: 0
            end
          end
        )
      end

      t6? = fn code, id, t ->
        [name | _] = String.split(code, "/")
        on_gp? = name in ["WIN:GP", "WON:GP"] or (name in ["WIN", "WON"] and listed.primary == :gp)

        on_gp? and match?({_, _}, Float.parse(t || "")) and
          abs(tbs_board_count.(String.slice(name, 0, 3), id) - elem(Float.parse(t), 0)) < 1.0e-9
      end

      # Finding G: in a predetermined event whose round count is a multiple
      # of the field, TieBreakServer's Koya takes one round per cycle as a
      # free round (its test for an odd round robin), though in a
      # Scheveningen or Schiller event every team plays every round. A
      # value its rule gives exactly is that finding.
      team_count = map_size(event.teams)

      tbs_koya = fn code, id ->
        [name | _] = String.split(code, "/")
        score = case name, do: ("KS:MP" -> :mp; "KS:GP" -> :gp; _ -> listed.primary)
        view = Team.view(listed, score)
        totals = Map.new(view.participants, fn {pid, p} -> {pid, Enum.sum(for {_, rd} <- p.rounds, do: rd.points)} end)
        maxgames = if rr? and rem(rounds, team_count) == 0, do: rounds - div(rounds, team_count), else: rounds
        lim = 0.5 * view.points.win * maxgames

        Enum.sum(for {_r, rd} <- view.participants[id].rounds, rd.opponent != nil, totals[rd.opponent] >= lim - 1.0e-9, do: rd.points)
      end

      g? = fn code, id, t ->
        String.starts_with?(code, "KS") and not String.contains?(code, "/") and rr? and
          rem(rounds, team_count) == 0 and close?.(tbs_koya.(code, id), t)
      end

      value_reason = fn code, id, t ->
        cond do
          t6?.(code, id, t) -> "reading T6"
          g?.(code, id, t) -> "finding G"
          true -> nil
        end
      end

      {value_known, bad} =
        for {code, i} <- Enum.with_index(value_codes),
            {id, {_rank, values}} <- theirs,
            mine = get_in(ours, [code, id]),
            not close?.(mine, Enum.at(values, i)) do
          {code, id, mine, Enum.at(values, i)}
        end
        |> Enum.split_with(fn {code, id, _, t} -> value_reason.(code, id, t) != nil end)

      value_why = value_known |> Enum.map(fn {code, id, _, t} -> value_reason.(code, id, t) end) |> Enum.uniq()

      rank_bad = for row <- ranked, elem(their_ranks[row.id], 0) != row.rank, do: {row.id, row.rank, elem(their_ranks[row.id], 0)}

      # A rank difference is known only when a documented cause accounts
      # for all of it. Replay: rank again with TieBreakServer's printed
      # values for the value codes and our own ordering for the group codes
      # (DE, EDE..., TBR, BBE), with BC either as TieBreakServer applies it
      # (its value, lower first, whatever the game points - finding E) or
      # as 12.1 has it (ours). If the TieBreakServer-style replay gives its
      # ranks, the difference is values and BC: known when every value it
      # ranked by is ours or a known difference (reading T6), and BC is
      # finding E. If not, the group codes differ: finding C (a rematch in
      # the group) or unexplained.
      group_codes_in = ~w(DE EDE EDEBT EDEBB EDET EDEB TBR BBE BC)

      # TieBreakServer's knockout step after EDE (13.3.2), as finding D and
      # readings T4 and T7 describe it: it goes to any two teams still tied
      # after EDE, level in both totals or not (T7); only the games of their
      # own matches count and two teams that never met stay tied (T4); and
      # Board Count ranks the HIGHER sum first (D).
      mutual = fn a, b ->
        for {_r, m} <- board_event.teams[a].rounds, m.opponent == b, m.kind == :played, {board, gp} <- m.boards, reduce: %{} do
          acc -> Map.update(acc, board, gp, &(&1 + gp))
        end
      end

      tbs_knockout = fn [a, b] = pair, variant ->
        steps = %{"EDEBT" => [:bc, :tbr], "EDEBB" => [:bc, :bbe], "EDET" => [:tbr], "EDEB" => [:bbe]}[variant]
        ma = mutual.(a, b)
        mb = mutual.(b, a)

        keys =
          for step <- steps do
            case step do
              :bc -> [{Enum.sum(for {k, v} <- ma, do: k * v), Enum.sum(for {k, v} <- mb, do: k * v)}]
              :tbr -> for k <- 1..boards, do: {Map.get(ma, k, 0.0), Map.get(mb, k, 0.0)}
              :bbe -> for k <- (boards - 1)..1//-1, do: {Enum.sum(for {j, v} <- ma, j <= k, do: v), Enum.sum(for {j, v} <- mb, j <= k, do: v)}
            end
          end
          |> List.flatten()

        case {ma, Enum.find(keys, fn {x, y} -> abs(x - y) > 1.0e-9 end)} do
          {m, _} when m == %{} -> [pair]
          {_, nil} -> [pair]
          {_, {x, y}} when x > y -> [[a], [b]]
          _ -> [[b], [a]]
        end
      end

      replay = fn bc_mode ->
        order = fn order, group, codes ->
          case {group, codes} do
            {[_], _} -> [group]
            {_, []} -> [group]
            {_, [{code, i} | rest]} ->
              subgroups =
                cond do
                  code == "BC" and bc_mode == :tbs ->
                    group
                    |> Enum.group_by(fn id -> elem(their_ranks[id], 1) |> Enum.at(i) |> Float.parse() |> elem(0) end)
                    |> Enum.sort_by(&elem(&1, 0), :asc)
                    |> Enum.map(fn {_, m} -> Enum.sort(m) end)

                  bc_mode == :tbs and code in ~w(EDEBT EDEBB EDET EDEB) ->
                    listed
                    |> Team.order_group(group, "EDE")
                    |> Enum.flat_map(fn
                      [_, _] = g -> tbs_knockout.(g, code)
                      g -> [g]
                    end)

                  hd(String.split(code, "/")) in group_codes_in ->
                    Team.order_group(listed, group, code)

                  true ->
                    group
                    |> Enum.group_by(fn id ->
                      case Float.parse(Enum.at(elem(their_ranks[id], 1), i) || "") do
                        {v, _} -> Float.round(v, 6)
                        :error -> -1.0e18
                      end
                    end)
                    |> Enum.sort_by(&elem(&1, 0), :desc)
                    |> Enum.map(fn {_, m} -> Enum.sort(m) end)
                end

              Enum.flat_map(subgroups, &order.(order, &1, rest))
          end
        end

        {rows, _} =
          order.(order, event.teams |> Map.keys() |> Enum.sort(), Enum.with_index(rank_codes))
          |> Enum.flat_map_reduce(1, fn g, next -> {Enum.map(g, &{&1, next}), next + length(g)} end)

        Map.new(rows)
      end

      # Finding C (docs/finding-tiebreakserver-2026-09.md): TieBreakServer's
      # direct encounter loses count after a rematch. A rank difference in
      # a score group where two teams met more than once is that, when the
      # list has a direct-encounter code at all.
      primary = Map.new(ranked, &{&1.id, &1.values[hd(rank_codes)]})

      rematch? = fn id ->
        group = for {other, v} <- primary, v == primary[id], do: other

        Enum.any?(group, fn a ->
          event.teams[a].rounds
          |> Map.values()
          |> Enum.map(& &1.opponent)
          |> Enum.filter(&(&1 in group))
          |> Enum.frequencies()
          |> Enum.any?(fn {_, n} -> n > 1 end)
        end)
      end

      {known, rank_bad, why} =
        cond do
          rank_bad == [] ->
            {[], [], []}

          replay.(:tbs) == Map.new(their_ranks, fn {id, {r, _}} -> {id, r} end) ->
            {:ok, ours_all} = Ainalrami.Tiebreaks.compute(event, Enum.reject(rank_codes, &(hd(String.split(&1, "/")) in group_codes_in)))

            checks =
              for {code, i} <- Enum.with_index(rank_codes),
                  hd(String.split(code, "/")) not in group_codes_in,
                  {id, {_r, values}} <- their_ranks do
                t = Enum.at(values, i)
                mine = ours_all[code][id]

                cond do
                  close?.(mine, t) -> {true, nil}
                  reason = value_reason.(code, id, t) -> {true, reason}
                  true -> {false, nil}
                end
              end

            # Finding E is only BC's precondition: the sums themselves must
            # be 12.1's, board number times game points (a bye or a match
            # won by forfeit a win on every board).
            bc_sum = fn id ->
              Enum.sum(
                for {_r, m} <- board_event.teams[id].rounds,
                    boards = if(m.kind in [:pab, :forfeit_win] and m.boards == %{}, do: Map.new(1..event.boards, &{&1, 1.0}), else: m.boards),
                    {board, gp} <- boards,
                    do: board * gp
              )
            end

            bc_checks =
              for {code, i} <- Enum.with_index(rank_codes), code == "BC", {id, {_r, values}} <- their_ranks do
                {close?.(bc_sum.(id), Enum.at(values, i)), nil}
              end

            checks = checks ++ bc_checks
            e? = "BC" in rank_codes and replay.(:tbs) != replay.(:ours)
            ko? = Enum.any?(rank_codes, &(&1 in ~w(EDEBT EDEBB EDET EDEB))) and replay.(:tbs) != replay.(:ours)

            # Reading T9: our own ranking with TieBreakServer's board
            # numbering differs from our ranking.
            t9? =
              crosswise? and
                match?({:ok, _}, Ainalrami.Tiebreaks.rank(board_event, rank_codes)) and
                elem(Ainalrami.Tiebreaks.rank(board_event, rank_codes), 1) != ranked

            reasons =
              Enum.uniq(
                for({_, r} <- checks, r, do: r) ++
                  if(e?, do: ["finding E"], else: []) ++ if(ko?, do: ["finding D, readings T4/T7"], else: []) ++
                  if(t9?, do: ["reading T9"], else: [])
              )

            if Enum.all?(checks, &elem(&1, 0)) and reasons != [],
              do: {rank_bad, [], reasons},
              else: {[], rank_bad, []}

          Enum.any?(rank_codes, &TiebreakRandomList.de?/1) ->
            {known, bad} = Enum.split_with(rank_bad, fn {id, _, _} -> rematch?.(id) end)
            {known, bad, if(known != [], do: ["finding C"], else: [])}

          true ->
            {[], rank_bad, []}
        end

      # Finding H: TieBreakServer takes the number of boards from games
      # PLAYED over the board, so when every team-round had an individual
      # forfeit it counts one board too few and drops each match's last
      # board. Everything in such an event is set aside as that finding.
      tbs_boards =
        Enum.max(
          for t <- trf.teams, r <- 0..(rounds - 1) do
            Enum.count(t.player_ranks, fn p ->
              g = Enum.at(by_rank[p].games, r)
              g && g.opponent_rank && g.result in ~w(1 = 0 W D L)
            end)
          end
        )

      h? = tbs_boards < boards and (bad != [] or rank_bad != [])

      {bad, rank_bad, known, value_known, why, value_why} =
        if h?,
          do: {[], [], known ++ rank_bad, value_known ++ bad, Enum.uniq(why ++ ["finding H"]), Enum.uniq(value_why ++ ["finding H"])},
          else: {bad, rank_bad, known, value_known, why, value_why}

      if bad != [] or rank_bad != [] or known != [] or value_known != [] do
        IO.puts("== seed #{seed}: #{length(bad)} values, #{length(rank_bad)} ranks differ, list #{Enum.join(rank_codes, " ")}")
        bad |> Enum.group_by(&elem(&1, 0)) |> Enum.each(fn {code, list} -> IO.puts("   #{code}: #{inspect(Enum.take(list, 4))}") end)
        if value_known != [], do: IO.puts("   #{length(value_known)} values known (#{Enum.join(value_why, ", ")})")
        if known != [], do: IO.puts("   #{length(known)} ranks known (#{Enum.join(why, ", ")})")
        if rank_bad != [], do: IO.puts("   ranks (team, ours, theirs): #{inspect(Enum.take(rank_bad, 6))}")
      end

      if bad != [] or rank_bad != [] do
        :ok
      else
        unless opts[:keep], do: File.rm!(file)
      end

      %{acc | files: acc.files + 1, values: acc.values + map_size(theirs) * length(value_codes),
              bad: acc.bad + length(bad), rank_bad: acc.rank_bad + length(rank_bad),
              known: acc.known + length(known) + length(value_known), finding_h: acc.finding_h + if(h?, do: 1, else: 0)}
    else
      {:error, reason} ->
        IO.puts("== seed #{seed}: error #{inspect(reason)}")
        %{acc | errors: acc.errors + 1}
    end
  end)

IO.puts("\nfiles #{totals.files}, values compared #{totals.values}, value mismatches #{totals.bad}, " <>
  "rank mismatches #{totals.rank_bad}, known #{totals.known}, errors #{totals.errors}")
IO.puts("formats #{inspect(totals.formats)}, forfeited matches #{totals.forfeited}, SSSC left out (finding F) #{totals.sssc_zero}, events set aside (finding H) #{totals.finding_h}")

if totals.bad + totals.rank_bad + totals.errors > 0, do: System.halt(1)
