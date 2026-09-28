# Times the alternatives' forced searches before and after the incremental
# path (`Ainalrami.Pairing.Replay`), on `tools/perf_bench.exs`'s large
# tournaments, the old engine compiled beside this one in the same VM and
# timed alternately round by round.
#
#   ELIXIR_ERL_OPTIONS="+S 2:2" mix run tools/alt_bench.exs
#   ALT_REF=083ec3d ALT_SIZES=450,600 mix run tools/alt_bench.exs
#
# Two measurements per round:
#
#   * `search` - every forced search `float_alternatives/3` and
#     `bye_alternatives/3` make at the default cap, one at a time: the full
#     re-pairing on the reference engine, and `Pairing.pair_forced/4` on
#     this one, from a recording of the round made once (its time reported
#     on its own). Both answers are compared, and whether each search was
#     answered incrementally or fell back is counted.
#   * `click` - `float_alternatives/3` and `bye_alternatives/3` as
#     OpenPairings calls them, on each engine, with this engine's default
#     (a recording from three searches up), the answers compared.
#
# Environment: ALT_REF (default origin/perf-large-fields), ALT_SIZES
# (default 450,600), ALT_TOURNAMENTS (default 2), ALT_OUT (CSV of the raw
# timings), PERF_CORPUS as in perf_bench.exs.

defmodule AltBench.Reference do
  @files ~w(log trf weighted_matching pairing alternatives)

  def load(ref) do
    for file <- @files do
      {source, 0} = System.cmd("git", ["show", "#{ref}:lib/ainalrami/#{file}.ex"])

      source
      |> String.replace("Ainalrami.", "AinalramiRef.")
      |> Code.compile_string("#{ref}:lib/ainalrami/#{file}.ex")
    end

    %{pairing: AinalramiRef.Pairing, alternatives: AinalramiRef.Alternatives}
  end
end

defmodule AltBench do
  alias Ainalrami.{Alternatives, Pairing, Trf}

  def corpus_dir, do: System.get_env("PERF_CORPUS", "bench_corpus")

  def tournament(size, index) do
    rounds = if size >= 450, do: 11, else: 9
    path = Path.join(corpus_dir(), "p#{size}_r#{rounds}_s#{size * 1000 + index}.trf")
    unless File.exists?(path), do: raise("#{path} missing - run tools/perf_bench.exs once to generate it")
    Trf.parse(File.read!(path))
  end

  def state_before_round(parsed, round) do
    points = parsed.tournament[:point_system] || Trf.default_point_system()

    Enum.map(parsed.players, fn player ->
      earlier = Enum.take(player.games, round - 1)

      games =
        case Enum.at(player.games, round - 1) do
          nil -> earlier
          game -> if Trf.participated_in_pairing?(game), do: earlier, else: earlier ++ [game]
        end

      %{player | games: games, points: Enum.sum(Enum.map(games, &Trf.points_for_game(&1, points)))}
    end)
  end

  def opts(parsed) do
    [
      expected_rounds: parsed.tournament[:number_of_rounds],
      forbidden_pairs: parsed.tournament[:forbidden_pairs],
      initial_colour: parsed.tournament[:initial_colour]
    ]
  end

  # The forcings `Alternatives` makes at its default cap.
  def forcings(players, pairs, opts) do
    cap = Alternatives.max_candidates()
    report = Pairing.explain_round(players, pairs, Keyword.put(opts, :bye_passed_over, false))
    bye = Enum.find_value(pairs, fn {w, b} -> if b == nil, do: w end)

    floats =
      for bracket <- report,
          floater <- bracket.floats,
          floater != bye,
          candidates = bracket.order -- [floater],
          length(candidates) <= cap,
          y <- candidates,
          do: {:float, for(m <- bracket.order, m != y, do: [y, m])}

    byes =
      case bye do
        nil ->
          []

        holder ->
          bracket = Enum.find(report, &(holder in &1.order)) || List.last(report)
          candidates = bracket.order -- [holder]
          eligibility = Pairing.bye_eligibility(players, opts)
          everyone = Enum.map(players, & &1.rank)

          if length(candidates) > cap,
            do: [],
            else:
              for(
                y <- candidates,
                is_nil(Map.get(eligibility, y)),
                do: {:bye, for(m <- everyone, m != y, do: [y, m])}
              )
      end

    floats ++ byes
  end

  def ms(fun) do
    {us, value} = :timer.tc(fun)
    {us / 1000, value}
  end

  def full(pairing, players, forced_opts) do
    {:ok, pairing.pair_next_round(players, forced_opts)}
  rescue
    e -> {:raised, Exception.message(e)}
  end

  def percentile([], _p), do: nil

  def percentile(values, p) do
    sorted = Enum.sort(values)
    Enum.at(sorted, min(length(sorted) - 1, round(p / 100 * (length(sorted) - 1))))
  end

  def mean([]), do: nil
  def mean(values), do: Enum.sum(values) / length(values)

  def fmt(nil), do: "-"
  def fmt(ms) when ms >= 1000, do: "#{Float.round(ms / 1000, 2)} s"
  def fmt(ms), do: "#{round(ms)} ms"
end

ref = System.get_env("ALT_REF", "origin/perf-large-fields")
reference = AltBench.Reference.load(ref)
sizes = System.get_env("ALT_SIZES", "450,600") |> String.split(",") |> Enum.map(&String.to_integer/1)
tournaments = String.to_integer(System.get_env("ALT_TOURNAMENTS", "2"))
Ainalrami.Log.set_level(:quiet)
Application.put_env(:ainalrami, :log_level, :quiet)

IO.puts("schedulers online: #{System.schedulers_online()}, reference #{ref}")

rows =
  for size <- sizes, index <- 1..tournaments do
    parsed = AltBench.tournament(size, index)
    opts = AltBench.opts(parsed)
    played = parsed.players |> Enum.map(&length(&1.games)) |> Enum.max()

    for round <- 2..played do
      players = AltBench.state_before_round(parsed, round)
      pairs = Ainalrami.Pairing.pair_next_round(players, opts)
      forcings = AltBench.forcings(players, pairs, opts)

      # The click: both calls, as OpenPairings makes them.
      click = fn engine ->
        AltBench.ms(fn ->
          {engine.alternatives.float_alternatives(players, pairs, opts),
           engine.alternatives.bye_alternatives(players, pairs, opts)}
        end)
      end

      {click_before, a} = click.(reference)
      {click_after, b} = click.(%{alternatives: Ainalrami.Alternatives})
      if a != b, do: raise("click answers differ: #{size} t#{index} r#{round}")

      {record_ms, recording} =
        if forcings == [],
          do: {nil, nil},
          else: AltBench.ms(fn -> Ainalrami.Pairing.alternatives_recording(players, opts) end)

      searches =
        for {kind, forced} <- forcings do
          forced_opts = Keyword.put(opts, :forbidden_pairs, (opts[:forbidden_pairs] || []) ++ forced)
          {before, full} = AltBench.ms(fn -> AltBench.full(reference.pairing, players, forced_opts) end)

          {after_ms, fast} =
            AltBench.ms(fn ->
              if recording,
                do: Ainalrami.Pairing.pair_forced(players, forced_opts, forced, recording),
                else: {:fallback, :no_recording}
            end)

          # A fallback is then the full re-pairing on this engine: its cost
          # is added, since that is what the caller pays.
          {after_ms, answer, how} =
            case fast do
              {:ok, pairs, _info} ->
                {after_ms, {:ok, pairs}, :incremental}

              {:fallback, _} ->
                {extra, answer} = AltBench.ms(fn -> AltBench.full(Ainalrami.Pairing, players, forced_opts) end)
                {after_ms + extra, answer, :fallback}
            end

          if answer != full, do: raise("search answers differ: #{size} t#{index} r#{round} #{inspect(forced)}")
          %{kind: kind, before: before, after: after_ms, how: how}
        end

      n = length(searches)
      inc = Enum.count(searches, &(&1.how == :incremental))

      IO.puts(
        "  p#{size} t#{index} r#{round}: #{n} searches (#{inc} incremental), " <>
          "search mean #{AltBench.fmt(AltBench.mean(Enum.map(searches, & &1.before)))} -> " <>
          "#{AltBench.fmt(AltBench.mean(Enum.map(searches, & &1.after)))}, recording #{AltBench.fmt(record_ms)}; " <>
          "click #{AltBench.fmt(click_before)} -> #{AltBench.fmt(click_after)}"
      )

      %{
        size: size,
        tournament: index,
        round: round,
        searches: searches,
        record: record_ms,
        click_before: click_before,
        click_after: click_after
      }
    end
  end
  |> List.flatten()

IO.puts("\n## Per forced search\n")
IO.puts("| field | searches | incremental | fell back | p50 before | after | p95 before | after | mean before | after | speed-up | recording (mean, once a batch) |")
IO.puts("|---|---|---|---|---|---|---|---|---|---|---|---|")

for {size, rs} <- Enum.group_by(rows, & &1.size) |> Enum.sort() do
  s = Enum.flat_map(rs, & &1.searches)
  b = Enum.map(s, & &1.before)
  a = Enum.map(s, & &1.after)
  inc = Enum.count(s, &(&1.how == :incremental))
  rec = rs |> Enum.map(& &1.record) |> Enum.reject(&is_nil/1)

  IO.puts(
    "| #{size} | #{length(s)} | #{inc} (#{Float.round(100 * inc / max(length(s), 1), 1)}%) | #{length(s) - inc} | " <>
      "#{AltBench.fmt(AltBench.percentile(b, 50))} | #{AltBench.fmt(AltBench.percentile(a, 50))} | " <>
      "#{AltBench.fmt(AltBench.percentile(b, 95))} | #{AltBench.fmt(AltBench.percentile(a, 95))} | " <>
      "#{AltBench.fmt(AltBench.mean(b))} | #{AltBench.fmt(AltBench.mean(a))} | " <>
      "#{Float.round(Enum.sum(b) / max(Enum.sum(a), 0.001), 1)}x | #{AltBench.fmt(AltBench.mean(rec))} |"
  )
end

IO.puts("\n## The alternatives of a click (float + bye, default cap)\n")
IO.puts("| field | rounds | searches | total before | after | per search before | after | worst round before | after | speed-up |")
IO.puts("|---|---|---|---|---|---|---|---|---|---|")

for {size, rs} <- Enum.group_by(rows, & &1.size) |> Enum.sort() do
  n = rs |> Enum.map(&length(&1.searches)) |> Enum.sum()
  b = Enum.map(rs, & &1.click_before)
  a = Enum.map(rs, & &1.click_after)

  IO.puts(
    "| #{size} | #{length(rs)} | #{n} | #{AltBench.fmt(Enum.sum(b))} | #{AltBench.fmt(Enum.sum(a))} | " <>
      "#{AltBench.fmt(Enum.sum(b) / max(n, 1))} | #{AltBench.fmt(Enum.sum(a) / max(n, 1))} | " <>
      "#{AltBench.fmt(Enum.max(b))} | #{AltBench.fmt(Enum.max(a))} | " <>
      "#{Float.round(Enum.sum(b) / max(Enum.sum(a), 0.001), 1)}x |"
  )
end

if out = System.get_env("ALT_OUT") do
  File.write!(
    out,
    ["size,tournament,round,kind,before_ms,after_ms,how\n"] ++
      for r <- rows, s <- r.searches do
        "#{r.size},#{r.tournament},#{r.round},#{s.kind},#{s.before},#{s.after},#{s.how}\n"
      end
  )
end
