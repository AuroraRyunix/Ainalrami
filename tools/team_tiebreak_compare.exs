# Team tie-breaks (C.07 Articles 11-13) against FIDE's TieBreakServer, on
# team tournaments generated here game by game.
#
#     mix run tools/team_tiebreak_compare.exs [--count 100] [--first 1] \
#         [--codes "..."] [--rank "..."] [--keep DIR]
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

{opts, _, _} =
  OptionParser.parse(System.argv(),
    strict: [count: :integer, first: :integer, codes: :string, rank: :string, keep: :string]
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
group_codes = ~w(EDE EDEBT EDEBB EDET EDEB BC TBR BBE)
value_codes = Enum.reject(codes, &(&1 in group_codes))

totals =
  Enum.reduce(first..(first + count - 1), %{files: 0, values: 0, bad: 0, rank_bad: 0, known: 0, errors: 0}, fn seed, acc ->
    {text, rounds} = generate.(seed)
    file = Path.join(work, "team#{seed}.trf")
    File.write!(file, text)

    event = text |> Trf.parse() |> then(fn {:ok, trf} -> trf; trf -> trf end) |> Team.from_trf(match_points: %{win: 2.0, draw: 1.0, loss: 0.0})

    with {:ok, ours} <- Ainalrami.Tiebreaks.compute(event, value_codes),
         {:ok, theirs} <- tbs.(file, value_codes, rounds),
         {:ok, ranked} <- Ainalrami.Tiebreaks.rank(event, rank_codes),
         {:ok, their_ranks} <- tbs.(file, rank_codes, rounds) do
      bad =
        for {code, i} <- Enum.with_index(value_codes),
            {id, {_rank, values}} <- theirs,
            mine = get_in(ours, [code, id]),
            not close?.(mine, Enum.at(values, i)) do
          {code, id, mine, Enum.at(values, i)}
        end

      rank_bad = for row <- ranked, elem(their_ranks[row.id], 0) != row.rank, do: {row.id, row.rank, elem(their_ranks[row.id], 0)}

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

      {known, rank_bad} =
        if Enum.any?(rank_codes, &String.contains?(&1, "DE")),
          do: Enum.split_with(rank_bad, fn {id, _, _} -> rematch?.(id) end),
          else: {[], rank_bad}

      if bad != [] or rank_bad != [] do
        IO.puts("== seed #{seed}: #{length(bad)} values, #{length(rank_bad)} ranks differ")
        bad |> Enum.group_by(&elem(&1, 0)) |> Enum.each(fn {code, list} -> IO.puts("   #{code}: #{inspect(Enum.take(list, 4))}") end)
        if rank_bad != [], do: IO.puts("   ranks (team, ours, theirs): #{inspect(Enum.take(rank_bad, 6))}")
      else
        unless opts[:keep], do: File.rm!(file)
      end

      %{acc | files: acc.files + 1, values: acc.values + map_size(theirs) * length(value_codes),
              bad: acc.bad + length(bad), rank_bad: acc.rank_bad + length(rank_bad),
              known: acc.known + length(known)}
    else
      {:error, reason} ->
        IO.puts("== seed #{seed}: error #{inspect(reason)}")
        %{acc | errors: acc.errors + 1}
    end
  end)

IO.puts("\nfiles #{totals.files}, values compared #{totals.values}, value mismatches #{totals.bad}, " <>
  "rank mismatches #{totals.rank_bad}, known (finding C) #{totals.known}, errors #{totals.errors}")

if totals.bad + totals.rank_bad + totals.errors > 0, do: System.halt(1)
