# Times large rounds, the way an arbiter's click actually runs them.
#
#   mix run tools/perf_bench.exs                       # the default grid
#   PERF_SIZES=150,300 PERF_TOURNAMENTS=1 mix run tools/perf_bench.exs
#   ELIXIR_ERL_OPTIONS="+S 2:2" mix run tools/perf_bench.exs   # the VPS
#
# ## What it measures
#
# For every round of a set of deterministic large tournaments, the three
# things OpenPairings' "Pair round" asks of this engine
# (`PairingsEngine.Pairing.run_ainalrami/5`), each timed on its own:
#
#   * `pair`    - `Pairing.pair_next_round/2`, the pairing itself
#   * `explain` - `Pairing.explain_round/3` on the pairing just made
#   * `alts`    - `Alternatives.float_alternatives/3` and
#                 `Alternatives.bye_alternatives/3`, the "why him and not
#                 me" answers stored with every round, at their default cap
#
# and reports p50 / p95 / max per field size and per round number. The
# second pairing OpenPairings runs when the arbiter has soft wishes is a
# `pair` at the same cost and is not repeated here.
#
# ## The corpus
#
# `Ainalrami.Generator` with realistic settings rather than its uniform
# defaults: ratings falling with the starting rank plus noise, results
# drawn from FIDE's expected score (so the strong players really do
# collect at the top), a few forfeits and requested byes every round, and
# a handful of forbidden pairs. A tournament is played forward by the
# engine itself and each round is then re-paired from the state the file
# records just before it - `Ainalrami.CLI`'s `-c` replay - so every round
# is timed on exactly the input it was paired from.
#
# Generation is the slow part at 600 players and the answer never changes,
# so each generated file is kept under `bench_corpus/` (gitignored) and
# reused. Delete the directory to regenerate.
#
# ## Environment
#
#   PERF_SIZES        field sizes (default 150,300,450,600)
#   PERF_TOURNAMENTS  tournaments per size (default 2)
#   PERF_ROUNDS       rounds per tournament (default 9; 11 from 450 up)
#   PERF_PARTS        which parts to time (default pair,explain,alts)
#   PERF_OUT          also write the raw per-round timings here (CSV)
#   PERF_CORPUS       where generated tournaments are cached (default
#                     bench_corpus/) - point a baseline checkout at the
#                     same directory to time both on identical files

alias Ainalrami.{Alternatives, Generator, Pairing, Trf}

defmodule PerfBench do
  alias Ainalrami.{Alternatives, Generator, Pairing, Trf}

  defp corpus_dir, do: System.get_env("PERF_CORPUS", "bench_corpus")

  def sizes do
    "PERF_SIZES"
    |> System.get_env("150,300,450,600")
    |> String.split(",", trim: true)
    |> Enum.map(&String.to_integer(String.trim(&1)))
  end

  def rounds_for(size) do
    case System.get_env("PERF_ROUNDS") do
      nil -> if size >= 450, do: 11, else: 9
      raw -> String.to_integer(raw)
    end
  end

  def parts do
    "PERF_PARTS"
    |> System.get_env("pair,explain,alts")
    |> String.split(",", trim: true)
    |> Enum.map(&String.to_existing_atom/1)
  end

  # One tournament, generated once and cached. The seed is a function of
  # the size and the index only, so the file is the same on every machine.
  def tournament(size, index) do
    rounds = rounds_for(size)
    seed = size * 1000 + index
    File.mkdir_p!(corpus_dir())
    path = Path.join(corpus_dir(), "p#{size}_r#{rounds}_s#{seed}.trf")

    unless File.exists?(path) do
      {us, {text, ^seed}} =
        :timer.tc(fn ->
          Generator.generate(
            seed: seed,
            players: size,
            rounds: rounds,
            forfeit_pct: 2,
            requested_bye_pct: 3,
            forbidden_pct: 1,
            results: :fide,
            draw_rate: 0.35,
            ratings: {:step, 2650, 1400 / size, 60}
          )
        end)

      File.write!(path, text)
      IO.puts("  generated #{path} in #{Float.round(us / 1_000_000, 1)} s")
    end

    Trf.parse(File.read!(path))
  end

  # Replay input: the field exactly as it stood before `round` was paired,
  # arbiter-assigned byes for that round already on record. `Ainalrami.CLI`'s
  # own `state_before_round/3`.
  def state_before_round(parsed, round) do
    points = parsed.tournament[:point_system] || Trf.default_point_system()

    Enum.map(parsed.players, fn player ->
      earlier = Enum.take(player.games, round - 1)

      games =
        case Enum.at(player.games, round - 1) do
          nil -> earlier
          game -> if Trf.participated_in_pairing?(game), do: earlier, else: earlier ++ [game]
        end

      %{
        player
        | games: games,
          points: Enum.sum(Enum.map(games, &Trf.points_for_game(&1, points)))
      }
    end)
  end

  def opts(parsed) do
    [
      expected_rounds: parsed.tournament[:number_of_rounds],
      forbidden_pairs: parsed.tournament[:forbidden_pairs],
      initial_colour: parsed.tournament[:initial_colour]
    ]
  end

  def time(fun) do
    {us, value} = :timer.tc(fun)
    {us / 1000, value}
  end

  def run_round(players, opts, parts) do
    {pair_ms, pairs} = time(fn -> Pairing.pair_next_round(players, opts) end)

    explain_ms =
      if :explain in parts,
        do: elem(time(fn -> Pairing.explain_round(players, pairs, opts) end), 0)

    alts_ms =
      if :alts in parts do
        elem(
          time(fn ->
            Alternatives.float_alternatives(players, pairs, opts)
            Alternatives.bye_alternatives(players, pairs, opts)
          end),
          0
        )
      end

    %{pair: pair_ms, explain: explain_ms, alts: alts_ms}
  end

  def percentile([], _p), do: nil

  def percentile(values, p) do
    sorted = Enum.sort(values)
    index = min(length(sorted) - 1, round(p / 100 * (length(sorted) - 1)))
    Enum.at(sorted, index)
  end

  def fmt(nil), do: "-"
  def fmt(ms) when ms >= 1000, do: "#{Float.round(ms / 1000, 2)} s"
  def fmt(ms), do: "#{round(ms)} ms"

  def summary(label, rows, parts) do
    cells =
      Enum.flat_map(parts, fn part ->
        values = rows |> Enum.map(&Map.fetch!(&1, part)) |> Enum.reject(&is_nil/1)
        [fmt(percentile(values, 50)), fmt(percentile(values, 95)), fmt(Enum.max(values, fn -> nil end))]
      end)

    IO.puts("| #{label} | #{length(rows)} | " <> Enum.join(cells, " | ") <> " |")
  end
end

parts = PerfBench.parts()
tournaments = String.to_integer(System.get_env("PERF_TOURNAMENTS", "2"))
out = System.get_env("PERF_OUT")

IO.puts(
  "schedulers online: #{System.schedulers_online()}, " <>
    "OTP #{System.otp_release()}, parts: #{Enum.join(parts, ",")}"
)

all =
  for size <- PerfBench.sizes(), index <- 1..tournaments do
    parsed = PerfBench.tournament(size, index)
    opts = PerfBench.opts(parsed)
    played = parsed.players |> Enum.map(&length(&1.games)) |> Enum.max()

    for round <- 1..played do
      players = PerfBench.state_before_round(parsed, round)
      timing = PerfBench.run_round(players, opts, parts)
      active = Enum.count(players, &(length(&1.games) < round))
      IO.puts(
        "  p#{size} t#{index} r#{round} active=#{active}: " <>
          Enum.map_join(parts, " ", &"#{&1}=#{PerfBench.fmt(timing[&1])}")
      )

      Map.merge(timing, %{size: size, tournament: index, round: round, active: active})
    end
  end
  |> List.flatten()

header =
  "| field | rounds | " <>
    Enum.map_join(parts, " | ", &"#{&1} p50 | #{&1} p95 | #{&1} max") <> " |"

IO.puts("\n## By field size\n")
IO.puts(header)
IO.puts("|" <> String.duplicate("---|", 2 + 3 * length(parts)))

for {size, rows} <- Enum.group_by(all, & &1.size) |> Enum.sort() do
  PerfBench.summary("#{size}", rows, parts)
end

IO.puts("\n## By field size and round\n")
IO.puts(header)
IO.puts("|" <> String.duplicate("---|", 2 + 3 * length(parts)))

for {{size, round}, rows} <- Enum.group_by(all, &{&1.size, &1.round}) |> Enum.sort() do
  PerfBench.summary("#{size} r#{round}", rows, parts)
end

if out do
  File.write!(
    out,
    ["size,tournament,round,active,pair_ms,explain_ms,alts_ms\n"] ++
      Enum.map(all, fn r ->
        "#{r.size},#{r.tournament},#{r.round},#{r.active},#{r.pair},#{r.explain},#{r.alts}\n"
      end)
  )
end
