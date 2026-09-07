# Judges JaVaFo-paired rounds with Ainalrami.Alternatives the way OpenPairings'
# rationale page does for a JaVaFo tournament, and checks every :better verdict
# against Ainalrami's OWN pairing of the same field. The instrument that found
# the completion-rung accounting defect fixed in 0.21.0 (see CHANGELOG).
#
#   MIX_ENV=test mix run tools/judge_javafo.exs [seeds] [rounds] [min_players] [max_players]
#   BYE_PCT / FORFEIT_PCT set the requested-bye and forfeit rates (default 8 / 5).
#
# Needs javafo.jar (see test/support/javafo.ex) and a Java runtime.

alias Ainalrami.{Alternatives, Pairing, Trf}
alias Ainalrami.Test.Javafo

defmodule Judge do
  def roster(n) do
    for(
      i <- 1..n,
      do: %{rank: i, name: "P#{i}", fide_rating: Enum.random(1000..2800), points: 0.0, games: []}
    )
    |> Enum.shuffle()
    |> Enum.with_index(1)
    |> Enum.map(fn {p, i} -> %{p | rank: i} end)
  end

  def trf(players, rounds) do
    Trf.serialize(%{tournament: %{name: "Judge", type: "swiss"}, players: players}) <>
      "XXR #{rounds}\r\n"
  end

  def requested_byes(players, pct) do
    Enum.map(players, fn p ->
      if :rand.uniform(100) <= pct do
        {res, pts} = Enum.random([{"H", 0.5}, {"Z", 0.0}])

        %{
          p
          | points: p.points + pts,
            games: p.games ++ [%{opponent_rank: nil, colour: nil, result: res}]
        }
      else
        p
      end
    end)
  end

  def results(pairs, forfeit_pct) do
    Map.new(pairs, fn
      {w, nil} ->
        {{w, nil}, :bye}

      {w, b} ->
        outcome =
          if forfeit_pct > 0 and :rand.uniform(100) <= forfeit_pct,
            do: Enum.random([:white_forfeits, :black_forfeits, :double_forfeit]),
            else: Enum.random([:white_win, :black_win, :draw])

        {{w, b}, outcome}
    end)
  end

  def advance(players, pairs, results) do
    games =
      Enum.reduce(pairs, %{}, fn {w, b} = pair, acc ->
        {wg, bg} = games_for(w, b, Map.fetch!(results, pair))
        acc = Map.put(acc, w, wg)
        if b, do: Map.put(acc, b, bg), else: acc
      end)

    Enum.map(players, fn p ->
      case Map.fetch(games, p.rank) do
        {:ok, g} -> %{p | points: p.points + g.points, games: p.games ++ [Map.delete(g, :points)]}
        :error -> p
      end
    end)
  end

  defp games_for(_w, nil, :bye),
    do: {%{opponent_rank: nil, colour: nil, result: "U", points: 1.0}, nil}

  defp games_for(w, b, :white_win), do: {g(b, "w", "1", 1.0), g(w, "b", "0", 0.0)}
  defp games_for(w, b, :black_win), do: {g(b, "w", "0", 0.0), g(w, "b", "1", 1.0)}
  defp games_for(w, b, :draw), do: {g(b, "w", "=", 0.5), g(w, "b", "=", 0.5)}
  defp games_for(w, b, :white_forfeits), do: {g(b, "w", "-", 0.0), g(w, "b", "+", 1.0)}
  defp games_for(w, b, :black_forfeits), do: {g(b, "w", "+", 1.0), g(w, "b", "-", 0.0)}
  defp games_for(w, b, :double_forfeit), do: {g(b, "w", "-", 0.0), g(w, "b", "-", 0.0)}

  defp g(opp, colour, result, points),
    do: %{opponent_rank: opp, colour: colour, result: result, points: points}

  def run(seed, rounds, range, bye_pct, forfeit_pct) do
    :rand.seed(:exsss, {seed, seed * 7919, seed * 104_729})
    players = roster(Enum.random(range))

    Enum.reduce_while(1..rounds, {[], players}, fn round, {acc, players} ->
      players = requested_byes(players, bye_pct)
      trf = trf(players, rounds)

      case Javafo.pair(trf) do
        {:ok, []} ->
          {:halt, {acc, players}}

        {:ok, jpairs} ->
          parsed = Trf.parse(trf)
          opts = [expected_rounds: rounds]
          field = parsed.players

          jreport = Pairing.explain_round(field, jpairs, opts)
          apairs = Pairing.pair_next_round(field, opts)
          areport = Pairing.explain_round(field, apairs, opts)
          own = Alternatives.compare(jreport, areport)

          full = opts ++ [max_candidates: :all]
          floats = Alternatives.float_alternatives(field, jpairs, full)
          bye = Alternatives.bye_alternatives(field, jpairs, full)

          # Self-check: Ainalrami's own round must never have a :better.
          own_floats = Alternatives.float_alternatives(field, apairs, full)
          own_bye = Alternatives.bye_alternatives(field, apairs, full)

          betters =
            for {source, entry} <- [{:float, floats}, {:bye, bye}],
                e <- List.wrap(entry),
                e != nil,
                c <- Map.get(e, :candidates, []),
                c.outcome == :better do
              %{
                seed: seed,
                round: round,
                source: source,
                label: c.differs_at.label,
                actual: c.differs_at.actual,
                alternative: c.differs_at.alternative,
                group: c.differs_at.group,
                own: own,
                odd: rem(length(Ainalrami.Test.Field.active(players)), 2)
              }
            end

          self_betters =
            for {source, entry} <- [{:float, own_floats}, {:bye, own_bye}],
                e <- List.wrap(entry),
                e != nil,
                c <- Map.get(e, :candidates, []),
                c.outcome == :better do
              %{seed: seed, round: round, source: source, label: c.differs_at.label, self: true}
            end

          measurement = %{
            seed: seed,
            round: round,
            own: own,
            betters: betters,
            self_betters: self_betters,
            candidates: count(floats) + count(bye)
          }

          results = results(jpairs, forfeit_pct)
          {:cont, {[measurement | acc], advance(players, jpairs, results)}}

        other ->
          IO.puts("seed #{seed} round #{round}: javafo #{inspect(other)}")
          {:halt, {acc, players}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  rescue
    e ->
      [
        %{
          seed: seed,
          round: nil,
          own: {:raised, Exception.message(e)},
          betters: [],
          self_betters: [],
          candidates: 0
        }
      ]
  end

  defp count(nil), do: 0
  defp count(list) when is_list(list), do: Enum.sum(Enum.map(list, &count/1))
  defp count(%{candidates: c}), do: length(c)
  defp count(_), do: 0
end

[seeds, rounds, lo, hi] =
  case System.argv() do
    [] -> [30, 7, 12, 30]
    args -> Enum.map(args, &String.to_integer/1)
  end

bye_pct = String.to_integer(System.get_env("BYE_PCT", "8"))
forfeit_pct = String.to_integer(System.get_env("FORFEIT_PCT", "5"))

IO.puts(
  "seeds=#{seeds} rounds=#{rounds} players=#{lo}..#{hi} bye_pct=#{bye_pct} forfeit_pct=#{forfeit_pct}"
)

measurements =
  1..seeds
  |> Task.async_stream(&Judge.run(&1, rounds, lo..hi, bye_pct, forfeit_pct),
    max_concurrency: 4,
    timeout: :infinity,
    ordered: false
  )
  |> Enum.flat_map(fn {:ok, ms} -> ms end)

rounds_judged = Enum.count(measurements, &(&1.round != nil))
candidates = Enum.sum(Enum.map(measurements, & &1.candidates))
betters = Enum.flat_map(measurements, & &1.betters)
self_betters = Enum.flat_map(measurements, & &1.self_betters)
raised = Enum.filter(measurements, &match?({:raised, _}, &1.own))

IO.puts("rounds judged: #{rounds_judged}; candidates judged on JaVaFo rounds: #{candidates}")
IO.puts("engine raised: #{length(raised)} #{inspect(Enum.take(raised, 2))}")

own_kinds =
  measurements
  |> Enum.filter(&(&1.round != nil))
  |> Enum.group_by(fn m ->
    case m.own do
      :identical -> :identical
      {k, _, _, _, _} -> k
      {k, _, _} -> k
      {k, _} -> k
      other -> other
    end
  end)

IO.puts(
  "Ainalrami's own round vs JaVaFo's: " <>
    inspect(Map.new(own_kinds, fn {k, v} -> {k, length(v)} end))
)

for m <- measurements,
    match?({:worse, _, _, _, _}, m.own),
    do: IO.puts("  own WORSE: seed #{m.seed} round #{m.round} #{inspect(m.own)}")

IO.puts("\n:better verdicts on JaVaFo rounds: #{length(betters)}")

betters
|> Enum.group_by(& &1.label)
|> Enum.each(fn {label, list} ->
  own_identical = Enum.count(list, &(&1.own == :identical))

  IO.puts(
    "  #{label}: #{length(list)} (Ainalrami's own round identical to JaVaFo's in #{own_identical} of them)"
  )
end)

IO.puts("\nfirst 12, in detail:")
betters |> Enum.take(12) |> Enum.each(&IO.puts("  " <> inspect(Map.drop(&1, []))))

IO.puts(
  "\nSELF-CHECK :better verdicts on Ainalrami's OWN rounds (must be 0): #{length(self_betters)}"
)

self_betters |> Enum.take(8) |> Enum.each(&IO.puts("  " <> inspect(&1)))
