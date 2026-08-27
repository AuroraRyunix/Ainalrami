# Times one round at BOTH field parities, because every timing this project
# has recorded was taken at a parity that skips its most quadratic pass.
#
#   mix run tools/parity_bench.exs
#   mix run tools/parity_bench.exs 209,401,1001
#
# ## The hole
#
# `bye_assignee_score/2` is called as
#
#     bye_assignee_score(brackets, rem(length(field), 2))
#
# and its first clause is `bye_assignee_score(_brackets, 0), do: {nil, false}`.
# On an EVEN field it returns immediately. On an odd one it runs
# `bye_assignee_score_from_field/2`, which builds a COMPLETE graph over the
# whole active field - `Enum.flat_map(0..(n - 2), ...)` over
# `(i + 1)..(n - 1)`, with a `legal_pair?/2` and a `colour_compatible?/2` call
# per pair and an edge emitted on BOTH branches of the `if` (the else branch
# returns `[{i, j, tie_unit}]`, deliberately, so the graph stays complete the
# way dutch.cpp:768-791 has it) - and hands it to `WeightedMatching.new/3`,
# which builds an n-by-n nested weight map on top. At 1,001 players that is
# 500,500 edges. At 1,000 it is zero.
#
# The engineering log's recorded sizes are 209 (odd), 400 (even) and 1,000
# (even). So this pass has been measured at 209 and nowhere else, and the
# log's own bracket table marks the bootstrap row "n/a (even field)" for 400.
# The 2026-08-19 entry that removed the idle first bracket says the quiet part
# outright: "That gate opens with `ctx.odd_field?`, and 400 is even, so the
# answer was unobservable."
#
# ## Parity changes four things, not one
#
# The bootstrap is the expensive one, but it is not the only one, and the
# other three are why an even-field profile is misleading rather than merely
# incomplete. Each was read out of `lib/ainalrami/pairing.ex` for this script:
#
#   1. `bye_candidate?/2` switches clause. With a nil bye score it reads
#      `eligible_for_bye?(player) and player.points <= 0`; with a real one it
#      reads `player.points <= bye_score`. That feeds `completion_rung/4`,
#      which is the TOP rung of the ladder, so the edge weights themselves
#      differ between parities - not just the time to compute them.
#
#   2. `c9_rank/3` becomes live. `unplayed_rank/2` compares
#      `player.points == ctx.bye_score`, which no player satisfies when the
#      score is nil, and the C9 rung is gated on `single_bye?` besides. On an
#      even field the rung is a constant zero. The table it reads is not even
#      built: `unplayed_ranks(_field, nil), do: %{}` is the whole even-field
#      case, against a pass over the field on the odd one. So an odd field
#      pays to build the map AND pays a live lookup per edge evaluation.
#
#   3. `idle_bracket?/4` stops firing. It skips a `nsgb < 2` bracket only when
#      `c9_gate_live?/4` is false, and that function's FIRST conjunct is
#      `ctx.odd_field?`. On an even field a lone leader is always skipped -
#      the 2026-08-19 fix, worth 660 ms of a 1,334 ms round at 400 players. On
#      an odd field the skip is available only when the three remaining
#      conjuncts fail, so the same lone leader can go back to solving the
#      whole field.
#
#   4. `local_eligible?/4` - the local-graph fast path, the change that took
#      1,000 players from 76.7 s to 27.6 s - admits a bracket only if every
#      member of its window passes a parity-dependent test:
#
#        if ctx.odd_field?,
#          do: not is_nil(ctx.bye_score) and p.points > ctx.bye_score,
#          else: not bye_candidate?(p, nil)
#
#      These are different predicates over different populations. The
#      even-field one excludes eligible players on zero points; the odd-field
#      one excludes everyone at or below the bye score, which in a large Swiss
#      is a whole score group rather than a handful of players. Any bracket it
#      turns away falls back to the full field graph.
#
# So (3) and (4) can both push brackets off the cheap paths that every
# optimisation since 2026-08-19 was tuned on, while (1) and (2) change what
# the matcher is optimising. The ratio this script prints is the question:
# is 1001 a slightly bigger 1000, or a different workload?
#
# ## What it does
#
# Modelled on `tools/colour_probe.exs` for input - `Ainalrami.Generator`
# `generate(players: n, rounds: r, seed: s)`, then `Ainalrami.Trf.parse/1`,
# then `Ainalrami.Pairing.pair_next_round/2` - which is the only field
# construction any tool in `tools/` uses. Rounds and the pairing target match
# the log's own 1,000-player benchmark: five rounds played, round six paired.
#
# The two parities come from ONE generated tournament each, not two. An odd
# field is generated, and the even one is the same file with the last-ranked
# player withheld: a single non-participating game (`opponent_rank: nil`,
# `result: "Z"`) appended in memory, which makes
# `active_this_round?/2`'s `length(player.games) <= rounds_played` false for
# that player alone. It does not move `rounds_played/1`, because
# `paired_through/1` counts only rounds where `participated_in_pairing?/1`
# holds and a `Z` with no opponent does not, and because the `base + 1` branch
# needs EVERY player to have more games than base. So 209 and 208 are the same
# roster with the same history, differing in one absentee - the ratio isolates
# parity instead of carrying the noise of two unrelated rosters. It also
# halves the generation bill, which matters: the log records 229 s to generate
# a 1,000-player 5-round file, and that generator pairs with the engine under
# test, so an ODD field pays the bootstrap on every generated round too.
# Generated files are cached; delete the cache dir to regenerate.
#
# Best of three, in a cold process per timing, which is this project's
# convention - stated at the 2026-08-21 re-measurement ("all three engines on
# the same input, best of three, cold process") and again at the 2026-08-19
# start-up-floor correction, which threw out an earlier table precisely for
# comparing cold processes against warm in-process numbers. The driver here
# re-invokes this same script under `mix run` for each timing; the reported
# number is `:timer.tc/1` around `pair_next_round/2` alone, so BEAM start-up
# and any recompile never enter it.
#
# ## Attribution
#
#   PARITY_BENCH_TRACE=1
#
# adds one extra (untimed) run per parity that puts a local trace on
# `Ainalrami.Pairing.bye_assignee_score_from_field/2` and reports its call
# count, its `n`, its edge count and its own wall time. The function is
# private, so this uses `:erlang.trace_pattern/3` with `:local` rather than
# editing `pairing.ex` - nothing in `lib/` is touched. Tracing is off during
# the timed runs because it is not free. Edge count is `n * (n - 1) / 2`
# exactly, not an estimate: both branches of the emitting `if` return a
# one-element list, so the complete graph is the only graph.
#
# Knobs, all optional:
#
#   PARITY_BENCH_ROUNDS    rounds played before the timed one (default 5)
#   PARITY_BENCH_TOTAL     the event's declared length (default 9). Kept well
#                          above the paired round on purpose: `colour_compatible?/2`
#                          relaxes on `played_rounds >= expected_rounds - 1`,
#                          and a relaxed final round is a different workload
#                          again. Five of nine keeps it out of the measurement.
#   PARITY_BENCH_REPEATS   timings per cell (default 3)
#   PARITY_BENCH_SEED      generator seed base (default 20260827)
#   PARITY_BENCH_CACHE     where generated TRFs live (default: tmp dir)

alias Ainalrami.{Generator, Log, Pairing, Trf}

rounds = System.get_env("PARITY_BENCH_ROUNDS", "5") |> String.to_integer()
total_rounds = System.get_env("PARITY_BENCH_TOTAL", "9") |> String.to_integer()
repeats = System.get_env("PARITY_BENCH_REPEATS", "3") |> String.to_integer()
seed_base = System.get_env("PARITY_BENCH_SEED", "20260827") |> String.to_integer()

cache_dir =
  System.get_env("PARITY_BENCH_CACHE") ||
    Path.join(System.tmp_dir!(), "ainalrami_parity_bench")

defmodule ParityBench do
  @moduledoc false

  # `bye_assignee_score_from_field/2` is a `defp`. Local trace patterns reach
  # private functions, which is the whole reason this is a trace and not a
  # patch: the instrumentation lives in tools/ where it belongs and cannot
  # perturb the code it is measuring when the flag is off.
  @bootstrap {Ainalrami.Pairing, :bye_assignee_score_from_field, 2}

  @doc """
  Withholds the last-ranked player, flipping the active field's parity.

  The lowest-ranked player is the natural absentee and is also, in a Swiss
  five rounds in, near the bottom of the standings - so the bye score the odd
  run computes is not distorted by removing someone from the top.
  """
  def withhold_last(players) do
    victim = Enum.max_by(players, & &1.rank)

    Enum.map(players, fn p ->
      if p.rank == victim.rank do
        %{p | games: p.games ++ [%{opponent_rank: nil, colour: nil, result: "Z"}]}
      else
        p
      end
    end)
  end

  # `Pairing.rounds_played/1` and `active_this_round?/2` are both private, so
  # the row label is computed here the same way they compute it - including the
  # `base + 1` branch, which does not fire for these inputs but would be an
  # off-by-one in the printed player count if it ever did.
  def active_count(players) do
    base =
      players
      |> Enum.map(fn p ->
        p.games
        |> Enum.with_index(1)
        |> Enum.filter(fn {g, _r} -> Trf.participated_in_pairing?(g) end)
        |> Enum.map(fn {_g, r} -> r end)
        |> Enum.max(fn -> 0 end)
      end)
      |> Enum.max(fn -> 0 end)

    played =
      if players != [] and Enum.all?(players, &(length(&1.games) > base)),
        do: base + 1,
        else: base

    Enum.count(players, &(length(&1.games) <= played))
  end

  @doc """
  Runs `fun` with a local call trace on the bootstrap matching.

  Returns `{result, calls}` where each call is `{n, microseconds}`. An empty
  list means the bootstrap never ran, which on an even field is the expected
  answer and the point of the exercise.
  """
  def with_bootstrap_trace(fun) do
    parent = self()
    tracer = spawn(fn -> collect(parent, []) end)

    # Modules load lazily, and `trace_pattern` matches nothing in a module the
    # VM has not loaded yet - it would return 0 and the trace would be silently
    # inert. Nothing has called into `Pairing` at this point in the worker.
    {module, _fun, _arity} = @bootstrap
    Code.ensure_loaded!(module)

    matched = :erlang.trace_pattern(@bootstrap, [{:_, [], [{:return_trace}]}], [:local])

    if matched == 0 do
      IO.puts(:stderr, "warning: #{inspect(@bootstrap)} did not match - trace is inert")
    end

    :erlang.trace(self(), true, [:call, :timestamp, {:tracer, tracer}])
    result = fun.()
    :erlang.trace(self(), false, [:call])
    :erlang.trace_pattern(@bootstrap, false, [:local])

    send(tracer, {:report, self()})

    calls =
      receive do
        {:bootstrap_calls, calls} -> calls
      after
        5_000 -> []
      end

    {result, calls}
  end

  # `:call` carries the arguments, so `n` is read straight off the second one
  # rather than inferred from the field size - the two are equal today but the
  # trace should report what the function was actually handed. The field
  # itself is dropped immediately; at 1,001 players it is a large message and
  # there is no reason to hold it.
  defp collect(parent, acc) do
    receive do
      {:trace_ts, _pid, :call, {_m, _f, [_field, n]}, ts} ->
        collect(parent, [{:open, n, ts} | acc])

      {:trace_ts, _pid, :return_from, {_m, _f, 2}, _ret, ts} ->
        case acc do
          [{:open, n, t0} | rest] -> collect(parent, [{:done, n, :timer.now_diff(ts, t0)} | rest])
          _ -> collect(parent, acc)
        end

      {:report, from} ->
        done = for {:done, n, us} <- Enum.reverse(acc), do: {n, us}
        send(from, {:bootstrap_calls, done})
    end
  end

  # Both branches of the edge-emitting `if` return a single-element list, so
  # the graph is complete and the count is closed-form.
  def edge_count(n), do: div(n * (n - 1), 2)

  def commas(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  def ms(us), do: :erlang.float_to_binary(us / 1000, decimals: 1)
end

# ---------------------------------------------------------------------------
# Worker roles. Each runs in its own cold process, spawned by the driver.
# ---------------------------------------------------------------------------

# Verbose is Ainalrami.Log's DEFAULT, not an opt-in. A 1,001-player round
# would otherwise spend a large and variable share of its wall clock writing
# to stdout, which is not the thing being measured.
Log.set_quiet(true)

argv = System.argv()

generate_file = fn n, path ->
  File.mkdir_p!(Path.dirname(path))
  {text, seed} = Generator.generate(players: n, rounds: rounds, seed: seed_base + n)
  File.write!(path, text)
  {seed, text}
end

case argv do
  ["gen", n, path] ->
    n = String.to_integer(n)
    {us, {seed, _text}} = :timer.tc(fn -> generate_file.(n, path) end)
    IO.puts("PARITYBENCH gen n=#{n} seed=#{seed} us=#{us}")

  ["time", path, parity] ->
    %{players: players} = Trf.parse(File.read!(path))

    field =
      case parity do
        "odd" -> players
        "even" -> ParityBench.withhold_last(players)
      end

    active = ParityBench.active_count(field)

    pair = fn ->
      Pairing.pair_next_round(field, expected_rounds: total_rounds, initial_colour: "w")
    end

    if System.get_env("PARITY_BENCH_TRACE") in [nil, "", "0"] do
      {us, pairs} = :timer.tc(pair)
      IO.puts("PARITYBENCH time parity=#{parity} active=#{active} us=#{us} pairs=#{length(pairs)}")
    else
      {{us, _pairs}, calls} =
        ParityBench.with_bootstrap_trace(fn -> :timer.tc(pair) end)

      total = calls |> Enum.map(&elem(&1, 1)) |> Enum.sum()
      ns = calls |> Enum.map(&elem(&1, 0)) |> Enum.map(&Integer.to_string/1) |> Enum.join(",")
      edges = calls |> Enum.map(fn {n, _} -> ParityBench.edge_count(n) end) |> Enum.sum()

      IO.puts(
        "PARITYBENCH trace parity=#{parity} active=#{active} us=#{us} " <>
          "calls=#{length(calls)} ns=#{ns} edges=#{edges} bootstrap_us=#{total}"
      )
    end

  _ ->
    # -----------------------------------------------------------------------
    # Driver.
    # -----------------------------------------------------------------------
    odd_sizes =
      case argv do
        [list | _] ->
          unless list =~ ~r/^\d+(,\d+)*$/ do
            IO.puts(:stderr, "usage: mix run tools/parity_bench.exs [odd,sizes,...]")
            System.halt(2)
          end

          list |> String.split(",") |> Enum.map(&String.to_integer/1)

        [] ->
          [209, 401, 1001]
      end

    for n <- odd_sizes, rem(n, 2) == 0 do
      IO.puts(:stderr, "warning: #{n} is even; sizes are the ODD member of each pair")
    end

    script = Path.join("tools", Path.basename(__ENV__.file))
    mix = System.find_executable("mix") || "mix"
    root = File.cwd!()

    # `mix run` may print compile output ahead of the worker's own line, so
    # the marker is searched for rather than assumed to be the last thing on
    # stdout.
    fields = fn line ->
      line
      |> String.split(" ")
      |> Enum.drop(2)
      |> Map.new(fn kv ->
        [k, v] = String.split(kv, "=", parts: 2)
        {k, v}
      end)
    end

    # The flag is exported by the user's own shell, so it is inherited by every
    # child unless it is explicitly cleared. Left alone it would put the THREE
    # TIMED runs into trace mode too, and the timings would then be measuring
    # the instrument.
    untraced = [{"PARITY_BENCH_TRACE", "0"}]
    traced = [{"PARITY_BENCH_TRACE", "1"}]

    run = fn args, env ->
      {out, code} =
        System.cmd(mix, ["run", script] ++ args,
          cd: root,
          env: env,
          stderr_to_stdout: true
        )

      line =
        out
        |> String.split(~r/\r?\n/)
        |> Enum.find(&String.starts_with?(&1, "PARITYBENCH "))

      tail = String.slice(out, max(String.length(out) - 600, 0), 600)

      cond do
        line != nil -> {:ok, fields.(line)}
        code != 0 -> {:error, tail}
        true -> {:error, "no PARITYBENCH line in output:\n" <> tail}
      end
    end

    IO.puts("""
    Parity benchmark - #{repeats} timings per cell, best of #{repeats}, cold process each.
    #{rounds} rounds played, pairing round #{rounds + 1} of a #{total_rounds}-round event.
    Cache: #{cache_dir}
    """)

    results =
      Enum.flat_map(odd_sizes, fn n ->
        path = Path.join(cache_dir, "parity_#{n}_r#{rounds}_s#{seed_base + n}.trf")

        unless File.exists?(path) do
          IO.puts("generating #{n} players x #{rounds} rounds (this is the slow part) ...")

          case run.(["gen", Integer.to_string(n), path], untraced) do
            {:ok, m} -> IO.puts("  seed #{m["seed"]}, #{ParityBench.ms(String.to_integer(m["us"]))} ms")
            {:error, why} -> IO.puts("  GENERATION FAILED: #{why}")
          end
        end

        if File.exists?(path) do
          Enum.map(["even", "odd"], fn parity ->
            timings =
              for _ <- 1..repeats do
                case run.(["time", path, parity], untraced) do
                  {:ok, m} -> {String.to_integer(m["us"]), String.to_integer(m["active"])}
                  {:error, why} -> {:error, why}
                end
              end

            case Enum.reject(timings, &match?({:error, _}, &1)) do
              [] ->
                {:error, why} = hd(timings)
                IO.puts(:stderr, "#{n} #{parity}: #{why}")
                %{pair: n, parity: parity, active: nil, us: nil}

              ok ->
                {best, active} = Enum.min_by(ok, &elem(&1, 0))
                IO.puts("  #{active} players (#{parity}): #{ParityBench.ms(best)} ms")
                %{pair: n, parity: parity, active: active, us: best}
            end
          end)
        else
          []
        end
      end)

    IO.puts("\n  players  parity  best of #{repeats}")
    IO.puts("  -------  ------  -----------")

    for r <- results, r.us do
      IO.puts(
        "  #{String.pad_leading(Integer.to_string(r.active), 7)}" <>
          "  #{String.pad_trailing(r.parity, 6)}" <>
          "  #{String.pad_leading(ParityBench.ms(r.us), 9)} ms"
      )
    end

    # The headline. The whole question is whether an odd field of size n costs
    # materially more than an even one of size n-1, so the ratio is printed on
    # its own line and nothing else competes with it for attention.
    IO.puts("")

    ratios =
      for n <- odd_sizes,
          e = Enum.find(results, &(&1.pair == n and &1.parity == "even")),
          o = Enum.find(results, &(&1.pair == n and &1.parity == "odd")),
          e.us && o.us && e.us > 0 do
        {e.active, o.active, o.us / e.us}
      end

    if ratios == [] do
      IO.puts("PARITY RATIO   no complete pair measured")
    else
      IO.puts(
        "PARITY RATIO (odd / even)   " <>
          Enum.map_join(ratios, "   ", fn {even, odd, r} ->
            "#{even}->#{odd}: #{:erlang.float_to_binary(r, decimals: 2)}x"
          end)
      )

      # A ratio near 1.0 says one extra player costs one extra player. Anything
      # else says the odd path is a different workload, and the table above
      # then has to be read as covering half the cases it looked like it did.
      worst = ratios |> Enum.map(&elem(&1, 2)) |> Enum.max()

      if worst >= 1.5 do
        IO.puts(
          "  ^ one extra player costs up to " <>
            "#{:erlang.float_to_binary(worst, decimals: 1)}x the whole round. " <>
            "Re-run with PARITY_BENCH_TRACE=1 to attribute it."
        )
      end
    end

    if System.get_env("PARITY_BENCH_TRACE") not in [nil, "", "0"] do
      IO.puts("\nBootstrap matching (traced, untimed run - tracing is not free):")

      for n <- odd_sizes, parity <- ["even", "odd"] do
        path = Path.join(cache_dir, "parity_#{n}_r#{rounds}_s#{seed_base + n}.trf")

        if File.exists?(path) do
          case run.(["time", path, parity], traced) do
            {:ok, m} ->
              calls = String.to_integer(m["calls"])

              if calls == 0 do
                IO.puts("  #{m["active"]} (#{parity}): not called - allowed_byes = 0, whole pass skipped")
              else
                edges = String.to_integer(m["edges"])
                boot = String.to_integer(m["bootstrap_us"])
                round_us = String.to_integer(m["us"])
                share = :erlang.float_to_binary(100 * boot / round_us, decimals: 1)

                IO.puts(
                  "  #{m["active"]} (#{parity}): #{calls} call(s), n=#{m["ns"]}, " <>
                    "#{ParityBench.commas(edges)} edges, #{ParityBench.ms(boot)} ms " <>
                    "(#{share}% of the traced round)"
                )
              end

            {:error, why} ->
              IO.puts(:stderr, "  #{n} #{parity} trace: #{why}")
          end
        end
      end
    end
end
