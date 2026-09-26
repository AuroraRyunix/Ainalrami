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
# So this one does, simply - a Swiss by match points (the pairing is not
# under test; the tie-breaks computed from it are): 6-20 teams of 4 boards,
# sometimes a reserve who plays instead of a regular, individual forfeits,
# and a pairing-allocated bye for an odd field.
#
# Each file is read back through `Ainalrami.Trf.parse/1` and
# `Ainalrami.Tiebreaks.Team.from_trf/2` - the path the checker takes - and
# the values and final ranks are compared with TieBreakServer's. Match
# points are 2/1/0 on both sides (the TRF26 `362` record is written for
# TieBreakServer).
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

boards = 4
wins = %{"1" => 1.0, "=" => 0.5, "0" => 0.0, "+" => 1.0, "-" => 0.0}

# ---- generation ---------------------------------------------------------

generate = fn seed ->
  :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 5})
  teams = 6 + :rand.uniform(15) - 1
  rounds = Enum.min([teams - 1, 5 + :rand.uniform(5) - 1])
  roster_size = fn t -> if rem(t + seed, 3) == 0, do: boards + 1, else: boards end

  {rosters, _next} =
    Enum.map_reduce(1..teams, 1, fn t, next ->
      size = roster_size.(t)
      {{t, Enum.to_list(next..(next + size - 1))}, next + size}
    end)

  rosters = Map.new(rosters)
  players = rosters |> Map.values() |> List.flatten() |> Enum.sort()
  rating = Map.new(players, &{&1, 2400 - &1 * 7 + :rand.uniform(60)})

  # games[rank][round] = {opponent_rank | nil, colour, result}
  play_round = fn r, state ->
    %{mp: mp, gp: gp, met: met, byes: byes, games: games, cd: cd} = state

    order = Enum.sort_by(1..teams, &{-mp[&1], -gp[&1], &1})

    {bye, order} =
      if rem(teams, 2) == 1 do
        b = order |> Enum.reverse() |> Enum.find(&(&1 not in byes))
        {b, List.delete(order, b)}
      else
        {nil, order}
      end

    # Greedy: the top team meets the highest team it has not met; a rematch
    # only when nothing else is left.
    pair = fn _pair, [], acc -> Enum.reverse(acc)
      pair, [a | rest], acc ->
        b = Enum.find(rest, &(not MapSet.member?(met, {a, &1}))) || hd(rest)
        pair.(pair, List.delete(rest, b), [{a, b} | acc])
    end

    pairs = pair.(pair, order, [])

    lineup = fn t ->
      roster = rosters[t]

      if length(roster) > boards and :rand.uniform() < 0.5 do
        List.delete_at(roster, :rand.uniform(boards) - 1)
      else
        Enum.take(roster, boards)
      end
    end

    result = fn a, b ->
      x = :rand.uniform()
      e = 1 / (1 + :math.pow(10, (rating[b] - rating[a]) / 400))

      cond do
        x < 0.015 -> {"+", "-"}
        x < 0.03 -> {"-", "+"}
        x < 0.03 + 0.3 -> {"=", "="}
        x < 0.33 + 0.67 * e -> {"1", "0"}
        true -> {"0", "1"}
      end
    end

    # The team with fewer whites on board 1 so far gets white there, so no
    # team's colour difference runs away (TieBreakServer's colour bookkeeping
    # indexes a table that stops at +-4).
    {games, mp, gp, cd} =
      Enum.reduce(pairs, {games, mp, gp, cd}, fn {a, b}, {games, mp, gp, cd} ->
        {a, b} = if cd[a] <= cd[b], do: {a, b}, else: {b, a}
        cd = %{cd | a => cd[a] + 1, b => cd[b] - 1}
        la = lineup.(a)
        lb = lineup.(b)

        {games, pa, pb} =
          Enum.zip(la, lb)
          |> Enum.with_index(1)
          |> Enum.reduce({games, 0.0, 0.0}, fn {{x, y}, board}, {games, pa, pb} ->
            {rx, ry} = result.(x, y)
            white_first? = rem(board, 2) == 1

            games =
              games
              |> put_in([x, r], {y, if(white_first?, do: "w", else: "b"), rx})
              |> put_in([y, r], {x, if(white_first?, do: "b", else: "w"), ry})

            {games, pa + wins[rx], pb + wins[ry]}
          end)

        {ma, mb} =
          cond do
            pa > pb -> {2.0, 0.0}
            pa < pb -> {0.0, 2.0}
            true -> {1.0, 1.0}
          end

        {games, %{mp | a => mp[a] + ma, b => mp[b] + mb}, %{gp | a => gp[a] + pa, b => gp[b] + pb}, cd}
      end)

    {games, mp, gp} =
      case bye do
        nil ->
          {games, mp, gp}

        t ->
          games = Enum.reduce(Enum.take(rosters[t], boards), games, &put_in(&2, [&1, r], {nil, "-", "U"}))
          {games, %{mp | t => mp[t] + 2.0}, %{gp | t => gp[t] + boards * 1.0}}
      end

    met = Enum.reduce(pairs, met, fn {a, b}, met -> met |> MapSet.put({a, b}) |> MapSet.put({b, a}) end)
    %{state | mp: mp, gp: gp, cd: cd, met: met, games: games, byes: if(bye, do: [bye | byes], else: byes)}
  end

  zero = Map.new(1..teams, &{&1, 0.0})
  start = %{mp: zero, gp: zero, cd: Map.new(1..teams, &{&1, 0}), met: MapSet.new(), byes: [], games: Map.new(players, &{&1, %{}})}
  final = Enum.reduce(1..rounds, start, play_round)

  trf_players =
    for rank <- players do
      games =
        for r <- 1..rounds do
          case final.games[rank][r] do
            nil -> %{opponent_rank: nil, colour: "-", result: ""}
            {opp, colour, res} -> %{opponent_rank: opp, colour: colour, result: res}
          end
        end

      points =
        games
        |> Enum.map(fn g -> if g.result == "U", do: 1.0, else: Map.get(wins, g.result, 0.0) end)
        |> Enum.sum()

      %{rank: rank, name: "Player #{rank}", fide_rating: rating[rank], points: points, games: games}
    end

  text =
    Trf.serialize(%{
      tournament: %{name: "Ainalrami team tie-breaks seed=#{seed}", type: "swiss", number_of_rounds: rounds},
      players: trf_players,
      teams: Enum.map(1..teams, &%{name: "Team #{&1}", player_ranks: rosters[&1]})
    }) <> "362  W 2.0    D 1.0    L 0.0    P 2.0\r\n"

  {text, rounds}
end

# ---- TieBreakServer ----------------------------------------------------

tbs = fn file, codes, rounds ->
  args =
    [Path.join(tbs_dir, "tiebreakchecker.py"), "-i", file, "-o", "-", "-s", "-n", "#{rounds}", "-d", "T", "-t"] ++
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
        abs(Float.round(mine * 1.0, decimals) - v) < 1.0e-9

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
  Enum.reduce(first..(first + count - 1), %{files: 0, values: 0, bad: 0, rank_bad: 0, known: 0, errors: 0}, fn seed, acc ->
    {text, rounds} = generate.(seed)

    {value_codes, rank_codes} =
      case opts[:random_lists] do
        nil ->
          {fixed_value_codes, fixed_rank_codes}

        list_seed ->
          list = TiebreakRandomList.draw(:team, list_seed, seed)
          {Enum.reject(list, &(hd(String.split(&1, "/")) in group_codes)), list}
      end

    file = Path.join(work, "team#{seed}.trf")
    File.write!(file, text)

    trf = text |> Trf.parse() |> then(fn {:ok, trf} -> trf; trf -> trf end)
    event = Team.from_trf(trf, match_points: %{win: 2.0, draw: 1.0, loss: 0.0})
    # The list's first score is the primary (reading T5), for the steps
    # replayed through Team.order_group/3.
    listed = case rank_codes, do: (["GPTS" | _] -> %{event | primary: :gp}; _ -> event)

    with {:ok, ours} <- Ainalrami.Tiebreaks.compute(event, value_codes),
         {:ok, theirs} <- tbs.(file, value_codes, rounds),
         {:ok, ranked} <- Ainalrami.Tiebreaks.rank(event, rank_codes),
         {:ok, their_ranks} <- tbs.(file, rank_codes, rounds) do
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

      {value_known, bad} =
        for {code, i} <- Enum.with_index(value_codes),
            {id, {_rank, values}} <- theirs,
            mine = get_in(ours, [code, id]),
            not close?.(mine, Enum.at(values, i)) do
          {code, id, mine, Enum.at(values, i)}
        end
        |> Enum.split_with(fn {code, id, _, t} -> t6?.(code, id, t) end)

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
        for {_r, m} <- event.teams[a].rounds, m.opponent == b, {board, gp} <- m.boards, reduce: %{} do
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
                  t6?.(code, id, t) -> {true, "reading T6"}
                  true -> {false, nil}
                end
              end

            # Finding E is only BC's precondition: the sums themselves must
            # be 12.1's, board number times game points (an unplayed match
            # its result on every board - reading Q3).
            per_board = %{pab: 1.0, forfeit_win: 1.0, full_bye: 1.0, half_bye: 0.5}

            bc_sum = fn id ->
              Enum.sum(
                for {_r, m} <- event.teams[id].rounds,
                    boards =
                      if(m.boards == %{} and Map.has_key?(per_board, m.kind),
                        do: Map.new(1..event.boards, &{&1, per_board[m.kind]}),
                        else: m.boards
                      ),
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
            reasons =
              Enum.uniq(
                for({_, r} <- checks, r, do: r) ++
                  if(e?, do: ["finding E"], else: []) ++ if(ko?, do: ["finding D, readings T4/T7"], else: [])
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

      if bad != [] or rank_bad != [] or known != [] or value_known != [] do
        IO.puts("== seed #{seed}: #{length(bad)} values, #{length(rank_bad)} ranks differ, list #{Enum.join(rank_codes, " ")}")
        bad |> Enum.group_by(&elem(&1, 0)) |> Enum.each(fn {code, list} -> IO.puts("   #{code}: #{inspect(Enum.take(list, 4))}") end)
        if value_known != [], do: IO.puts("   #{length(value_known)} values known (reading T6)")
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
              known: acc.known + length(known) + length(value_known)}
    else
      {:error, reason} ->
        IO.puts("== seed #{seed}: error #{inspect(reason)}")
        %{acc | errors: acc.errors + 1}
    end
  end)

IO.puts("\nfiles #{totals.files}, values compared #{totals.values}, value mismatches #{totals.bad}, " <>
  "rank mismatches #{totals.rank_bad}, known #{totals.known}, errors #{totals.errors}")

if totals.bad + totals.rank_bad + totals.errors > 0, do: System.halt(1)
