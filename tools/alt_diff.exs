# The differential net for the alternatives' incremental searches
# (`Ainalrami.Pairing.Replay`): every forced search the Alternatives module
# runs, answered both ways, over generated tournaments.
#
#   MIX_ENV=test mix run tools/alt_diff.exs corpus small DIR     # a named set
#   MIX_ENV=test mix run tools/alt_diff.exs compare BASE NEW     # two dirs
#
# ## What is checked, round by round
#
# For every round of every tournament, with the round's own pairing:
#
#   * EVERY forced search `float_alternatives/3` and `bye_alternatives/3`
#     make - every floater's every candidate and every bye candidate C.2
#     allows, at the default cap, and uncapped on fields of 24 or fewer -
#     is run twice: as the full re-pairing (`Pairing.pair_next_round/2` with
#     the forcing added) and incrementally, from a recording of the round
#     (`Pairing.pair_forced/4`). The incremental answer must be the full
#     re-pairing's, pairs and colours in order - or, where the search is
#     impossible, a fallback (the incremental path never answers a round the
#     full one refuses). Any other outcome is a MISMATCH and is written out
#     in full. The line records how many searches there were, how many were
#     answered incrementally, and how many fell back.
#
#   * the public answer, `float_alternatives/3` and `bye_alternatives/3`
#     (and at `:all` on small fields), with `AINALRAMI_ALT_REPLAY=always` so
#     that every batch goes through the recording, fingerprinted - to be
#     compared with the same tool run in a checkout of the release, whose
#     engine has no incremental path at all.
#
# The tournaments are `tools/perf_diff.exs`'s: `Ainalrami.Test.FuzzTournament`
# played forward on the engine under test, with the same soft-pair and
# bye-exclusion extras, over the same axes (see `AltDiff.Corpus`).
#
# ## Environment
#
#   DIFF_ROUNDS, DIFF_EXTRAS, PAIRING_FUZZ_*   as in perf_diff.exs
#   ALT_SMALL_ALL    fields up to this size also run uncapped (default 24)
#   ALT_SCALE        percent of each corpus axis's tournaments (default 100)
#   ALT_COUNT        tournaments per corpus axis, overriding the table
#   ALT_AXES         comma-separated axes of the set to run (default all)

alias Ainalrami.{Alternatives, Pairing}
alias Ainalrami.Test.FuzzTournament, as: Fuzz

defmodule AltDiff do
  alias Ainalrami.{Alternatives, Pairing}
  alias Ainalrami.Test.FuzzTournament, as: Fuzz

  def int(name, default), do: name |> System.get_env(to_string(default)) |> String.to_integer()

  def digest(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  def incremental?, do: function_exported?(Pairing, :pair_forced, 4)

  def run(seed, rounds_asked, range, extras?, mismatches) do
    {rounds, player_count, forbidden, roster} = Fuzz.begin!(seed, rounds_asked, range)
    rng = :rand.seed_s(:exsss, {seed, 4242, 99_991})

    {soft, rng} = soft_pairs(rng, player_count, extras?)
    {position, rng} = pick(rng, [:strong, :weak])

    {lines, _, _} =
      Enum.reduce_while(1..rounds, {[], roster, rng}, fn round, {acc, players, rng} ->
        Fuzz.withdraw_some(round, player_count)
        {active, pending} = Fuzz.reveal_late_entrants(players, round)
        active = Fuzz.assign_requested_byes(active)

        {exclusions, rng} = bye_exclusions(rng, active, extras?)

        opts =
          [
            expected_rounds: rounds,
            forbidden_pairs: forbidden,
            initial_colour: String.downcase(Fuzz.initial_colour()),
            point_system: Fuzz.point_system()
          ]
          |> then(&if(soft == [], do: &1, else: &1 ++ [soft_pairs: soft, soft_position: position]))
          |> then(&if(exclusions == [], do: &1, else: &1 ++ [bye_exclusions: exclusions]))

        {pair_result, pairs, opts} = pair(active, opts)

        case pairs do
          nil ->
            {:halt, {[[round, length(active), digest(pair_result), "-", "-"] | acc], players, rng}}

          pairs ->
            public = public(active, pairs, opts)

            counts =
              if incremental?(),
                do: both_ways(seed, round, active, pairs, opts, mismatches),
                else: "-"

            line = [round, length(active), digest(pair_result), digest(public), counts]
            next = Fuzz.apply_round(active, pairs, Fuzz.simulate_results(pairs))
            {:cont, {[line | acc], next ++ pending, rng}}
        end
      end)

    lines
    |> Enum.reverse()
    |> Enum.map(fn [round | rest] -> [seed, round | rest] end)
  end

  defp pair(players, opts) do
    pairs = Pairing.pair_next_round(players, opts)
    {{:ok, pairs}, pairs, opts}
  rescue
    e in Pairing.NoValidPairingError ->
      refusal = {:raised, e.reason, e.excluded, e.override, e.message}

      if e.reason == :bye_exclusions and e.override do
        opts = Keyword.update!(opts, :bye_exclusions, &List.delete(&1, e.override))
        {retry, pairs, opts} = pair(players, opts)
        {{refusal, retry}, pairs, opts}
      else
        {refusal, nil, opts}
      end
  end

  defp safely(fun) do
    fun.()
  rescue
    e -> {:raised, e.__struct__, Exception.message(e)}
  end

  defp small_all, do: int("ALT_SMALL_ALL", 24)

  defp public(players, pairs, opts) do
    all = Keyword.put(opts, :max_candidates, :all)
    small? = length(players) <= small_all()

    {
      safely(fn -> Alternatives.float_alternatives(players, pairs, opts) end),
      safely(fn -> Alternatives.bye_alternatives(players, pairs, opts) end),
      small? && safely(fn -> Alternatives.float_alternatives(players, pairs, all) end),
      small? && safely(fn -> Alternatives.bye_alternatives(players, pairs, all) end)
    }
  end

  # Every forcing the two calls above make, laid out as `Alternatives`
  # lays them out: each floater's bracket-mates, each bye candidate C.2
  # allows. Capped at the module's own cap unless the field is small.
  def forcings(players, pairs, opts) do
    cap = if length(players) <= small_all(), do: :all, else: Alternatives.max_candidates()
    report = Pairing.explain_round(players, pairs, Keyword.put(opts, :bye_passed_over, false))
    bye = Enum.find_value(pairs, fn {w, b} -> if b == nil, do: w end)
    over? = fn candidates -> cap != :all and length(candidates) > cap end

    floats =
      for bracket <- report,
          floater <- bracket.floats,
          floater != bye,
          candidates = bracket.order -- [floater],
          not over?.(candidates),
          y <- candidates,
          do: for(m <- bracket.order, m != y, do: [y, m])

    byes =
      case bye do
        nil ->
          []

        holder ->
          bracket = Enum.find(report, &(holder in &1.order)) || List.last(report)
          candidates = bracket.order -- [holder]
          eligibility = Pairing.bye_eligibility(players, opts)
          everyone = Enum.map(players, & &1.rank)

          if over?.(candidates),
            do: [],
            else:
              for(
                y <- candidates,
                is_nil(Map.get(eligibility, y)),
                do: for(m <- everyone, m != y, do: [y, m])
              )
      end

    Enum.uniq(floats ++ byes)
  end

  defp both_ways(seed, round, players, pairs, opts, mismatches) do
    forcings = forcings(players, pairs, opts)

    if forcings == [] do
      "0/0/0/0"
    else
      recording = Pairing.alternatives_recording(players, opts)

      {inc, fell, bad} =
        Enum.reduce(forcings, {0, 0, 0}, fn forced, {inc, fell, bad} ->
          forced_opts =
            Keyword.put(opts, :forbidden_pairs, (Keyword.get(opts, :forbidden_pairs) || []) ++ forced)

          full = safely(fn -> {:ok, Pairing.pair_next_round(players, forced_opts)} end)

          fast =
            if recording,
              do: Pairing.pair_forced(players, forced_opts, forced, recording),
              else: {:fallback, :no_recording}

          case {full, fast} do
            {{:ok, same}, {:ok, same, _info}} ->
              {inc + 1, fell, bad}

            {_, {:fallback, reason}} when not is_tuple(reason) or elem(reason, 0) != :raised ->
              kind = if is_tuple(reason), do: Enum.join(Tuple.to_list(Tuple.delete_at(reason, 2)), "."), else: reason
              IO.write(mismatches, "fallback	#{seed}	#{round}	#{kind}
")
              {inc, fell + 1, bad}

            _ ->
              IO.write(
                mismatches,
                inspect({:mismatch, seed, round, forced, full, fast}, limit: :infinity) <> "\n"
              )

              {inc, fell, bad + 1}
          end
        end)

      "#{length(forcings)}/#{inc}/#{fell}/#{bad}"
    end
  end

  defp soft_pairs(rng, _n, false), do: {[], rng}

  defp soft_pairs(rng, n, true) do
    {roll, rng} = :rand.uniform_s(3, rng)

    if roll != 1 or n < 4 do
      {[], rng}
    else
      groups = max(1, div(n, 8))

      Enum.reduce(1..groups, {[], rng}, fn _, {acc, rng} ->
        {size, rng} = :rand.uniform_s(3, rng)
        size = if size == 3, do: 3, else: 2

        {members, rng} =
          Enum.reduce(1..size, {[], rng}, fn _, {m, rng} ->
            {r, rng} = :rand.uniform_s(n, rng)
            {[r | m], rng}
          end)

        members = Enum.uniq(members)
        {if(length(members) >= 2, do: [members | acc], else: acc), rng}
      end)
    end
  end

  defp bye_exclusions(rng, _active, false), do: {[], rng}

  defp bye_exclusions(rng, active, true) do
    {roll, rng} = :rand.uniform_s(3, rng)

    if roll != 1 or active == [] do
      {[], rng}
    else
      {k, rng} = :rand.uniform_s(3, rng)

      {ranks, rng} =
        Enum.reduce(1..k, {[], rng}, fn _, {acc, rng} ->
          {p, rng} = pick(rng, active)
          {[p.rank | acc], rng}
        end)

      {Enum.sort(Enum.uniq(ranks)), rng}
    end
  end

  defp pick(rng, list) do
    {i, rng} = :rand.uniform_s(length(list), rng)
    {Enum.at(list, i - 1), rng}
  end
end

defmodule AltDiff.Corpus do
  @moduledoc false

  # `tools/perf_diff.exs`'s axes, on seeds of their own (offset 20,000,000),
  # every round running every alternative.
  @base %{"DIFF_ROUNDS" => "9"}

  @small [
    {"s_plain", 4000, %{}},
    {"s_byes", 4000,
     %{
       "PAIRING_FUZZ_BYE_PCT" => "10",
       "PAIRING_FUZZ_FORFEIT_PCT" => "6",
       "PAIRING_FUZZ_WITHDRAW_PCT" => "2"
     }},
    {"s_forbid_accel", 4000,
     %{"PAIRING_FUZZ_FORBIDDEN_PCT" => "10", "PAIRING_FUZZ_ACCEL" => "mixed"}},
    {"s_late", 3000,
     %{
       "PAIRING_FUZZ_LATE_PCT" => "15",
       "PAIRING_FUZZ_BYE_PCT" => "5",
       "PAIRING_FUZZ_FORFEIT_PCT" => "3"
     }},
    {"s_points", 3000,
     %{
       "PAIRING_FUZZ_POINT_SYSTEM" => "mixed",
       "PAIRING_FUZZ_INITIAL_COLOUR" => "mixed",
       "PAIRING_FUZZ_RATING_MODE" => "mixed",
       "PAIRING_FUZZ_BYE_PCT" => "5"
     }},
    {"s_combined", 5000,
     %{
       "PAIRING_FUZZ_ROUNDS_MAX" => "13",
       "DIFF_ROUNDS" => "5",
       "PAIRING_FUZZ_BYE_PCT" => "8",
       "PAIRING_FUZZ_FORFEIT_PCT" => "5",
       "PAIRING_FUZZ_FORBIDDEN_PCT" => "5",
       "PAIRING_FUZZ_ACCEL" => "mixed",
       "PAIRING_FUZZ_WITHDRAW_PCT" => "2",
       "PAIRING_FUZZ_LATE_PCT" => "5",
       "PAIRING_FUZZ_POINT_SYSTEM" => "mixed",
       "PAIRING_FUZZ_INITIAL_COLOUR" => "mixed",
       "PAIRING_FUZZ_RATING_MODE" => "mixed"
     }},
    {"s_tiny_deep", 4000,
     %{
       "PAIRING_FUZZ_MIN_PLAYERS" => "4",
       "PAIRING_FUZZ_MAX_PLAYERS" => "12",
       "DIFF_ROUNDS" => "5",
       "PAIRING_FUZZ_ROUNDS_MAX" => "11",
       "PAIRING_FUZZ_BYE_PCT" => "10",
       "PAIRING_FUZZ_FORFEIT_PCT" => "5",
       "PAIRING_FUZZ_FORBIDDEN_PCT" => "8"
     }},
    {"s_late_half", 2000,
     %{
       "PAIRING_FUZZ_LATE_PCT" => "20",
       "PAIRING_FUZZ_LATE_BYE_TYPE" => "H",
       "PAIRING_FUZZ_ACCEL" => "baku"
     }}
  ]

  @flags [
    {"f_nofast", 2000,
     %{
       "AINALRAMI_NOFAST" => "1",
       "PAIRING_FUZZ_MAX_PLAYERS" => "60",
       "PAIRING_FUZZ_BYE_PCT" => "8",
       "PAIRING_FUZZ_FORFEIT_PCT" => "5",
       "PAIRING_FUZZ_FORBIDDEN_PCT" => "5",
       "PAIRING_FUZZ_ACCEL" => "mixed"
     }},
    {"f_strand", 2000,
     %{
       "AINALRAMI_FORCE_STRAND" => "1",
       "PAIRING_FUZZ_BYE_PCT" => "8",
       "PAIRING_FUZZ_FORFEIT_PCT" => "5"
     }},
    {"f_completion", 1500,
     %{"AINALRAMI_COMPLETION" => "eligibility", "PAIRING_FUZZ_BYE_PCT" => "8"}}
  ]

  @large [
    {"l_60_120", 300,
     %{
       "PAIRING_FUZZ_MIN_PLAYERS" => "60",
       "PAIRING_FUZZ_MAX_PLAYERS" => "120",
       "PAIRING_FUZZ_BYE_PCT" => "5",
       "PAIRING_FUZZ_FORFEIT_PCT" => "4",
       "PAIRING_FUZZ_FORBIDDEN_PCT" => "2",
       "PAIRING_FUZZ_ACCEL" => "mixed",
       "PAIRING_FUZZ_WITHDRAW_PCT" => "1"
     }},
    {"l_150_250", 80,
     %{
       "PAIRING_FUZZ_MIN_PLAYERS" => "150",
       "PAIRING_FUZZ_MAX_PLAYERS" => "250",
       "PAIRING_FUZZ_ROUNDS_MAX" => "11",
       "PAIRING_FUZZ_BYE_PCT" => "4",
       "PAIRING_FUZZ_FORFEIT_PCT" => "3",
       "PAIRING_FUZZ_FORBIDDEN_PCT" => "1",
       "PAIRING_FUZZ_POINT_SYSTEM" => "mixed",
       "PAIRING_FUZZ_LATE_PCT" => "3"
     }},
    {"l_300_600", 16,
     %{
       "PAIRING_FUZZ_MIN_PLAYERS" => "300",
       "PAIRING_FUZZ_MAX_PLAYERS" => "600",
       "DIFF_ROUNDS" => "11",
       "PAIRING_FUZZ_BYE_PCT" => "3",
       "PAIRING_FUZZ_FORFEIT_PCT" => "2",
       "PAIRING_FUZZ_FORBIDDEN_PCT" => "1",
       "PAIRING_FUZZ_ACCEL" => "mixed"
     }}
  ]

  def set("small"), do: @small
  def set("flags"), do: @flags
  def set("large"), do: @large

  def run(name, dir, run_axis) do
    File.mkdir_p!(dir)
    only = System.get_env("ALT_AXES")

    set(name)
    |> Enum.with_index()
    |> Enum.filter(fn {{axis, _, _}, _} -> only == nil or axis in String.split(only, ",") end)
    |> Enum.each(fn {{axis, count, env}, index} ->
      env = Map.merge(@base, env)
      previous = Map.new(env, fn {k, _} -> {k, System.get_env(k)} end)
      Enum.each(env, fn {k, v} -> System.put_env(k, v) end)
      offset = %{"small" => 20_000_000, "flags" => 25_000_000, "large" => 29_000_000}[name]
      seed_from = offset + index * 100_000 + 1
      count = AltDiff.int("ALT_COUNT", max(1, div(count * AltDiff.int("ALT_SCALE", 100), 100)))

      try do
        run_axis.(axis, seed_from, count, Path.join(dir, axis <> ".log"))
      after
        Enum.each(previous, fn
          {k, nil} -> System.delete_env(k)
          {k, v} -> System.put_env(k, v)
        end)
      end
    end)
  end
end

run_axis = fn axis, seed_from, count, out ->
  rounds = AltDiff.int("DIFF_ROUNDS", 9)
  extras? = System.get_env("DIFF_EXTRAS", "1") != "0"
  range = AltDiff.int("PAIRING_FUZZ_MIN_PLAYERS", 4)..AltDiff.int("PAIRING_FUZZ_MAX_PLAYERS", 40)

  Ainalrami.Log.set_level(:quiet)
  Application.put_env(:ainalrami, :log_level, :quiet)
  System.put_env("AINALRAMI_ALT_REPLAY", "always")
  File.rm(out)
  file = File.open!(out, [:append, :utf8])
  mismatches = File.open!(out <> ".mismatches", [:write, :utf8])
  started = System.monotonic_time(:millisecond)

  total =
    seed_from..(seed_from + count - 1)
    |> Task.async_stream(
      fn seed -> AltDiff.run(seed, rounds, range, extras?, mismatches) end,
      max_concurrency: System.schedulers_online(),
      timeout: :infinity,
      ordered: false
    )
    |> Enum.reduce(0, fn {:ok, lines}, n ->
      for line <- lines, do: IO.write(file, Enum.join([axis | line], "\t") <> "\n")
      n + length(lines)
    end)

  File.close(file)
  File.close(mismatches)
  secs = (System.monotonic_time(:millisecond) - started) / 1000
  IO.puts("#{axis}: #{count} tournaments, #{total} rounds in #{Float.round(secs, 1)} s -> #{out}")
end

case System.argv() do
  ["corpus", name, dir] ->
    AltDiff.Corpus.run(name, dir, run_axis)

  ["compare", a, b] ->
    logs = fn dir -> dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".log")) end

    read = fn dir ->
      logs.(dir)
      |> Enum.flat_map(&File.stream!(Path.join(dir, &1)))
      |> Stream.map(&String.trim_trailing/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.map(fn line ->
        [axis, seed, round, n, pair, public, counts] = String.split(line, "\t")
        {{axis, String.to_integer(seed), String.to_integer(round)}, {n, pair, public, counts}}
      end)
      |> Map.new()
    end

    base = read.(a)
    new = read.(b)
    keys = MapSet.union(MapSet.new(Map.keys(base)), MapSet.new(Map.keys(new)))

    {same, differ, missing} =
      Enum.reduce(keys, {0, [], []}, fn key, {same, differ, missing} ->
        case {Map.get(base, key), Map.get(new, key)} do
          {nil, _} -> {same, differ, [key | missing]}
          {_, nil} -> {same, differ, [key | missing]}
          {{n, p, x, _}, {n, p, x, _}} -> {same + 1, differ, missing}
          {l, r} -> {same, [{key, l, r} | differ], missing}
        end
      end)

    # The incremental check's own tallies, from the new side.
    {searches, incremental, fallback, mismatch, rounds_searched} =
      Enum.reduce(new, {0, 0, 0, 0, 0}, fn {_k, {_, _, _, counts}}, {s, i, f, m, r} ->
        case String.split(counts, "/") do
          [a1, b1, c1, d1] ->
            a1 = String.to_integer(a1)
            {s + a1, i + String.to_integer(b1), f + String.to_integer(c1),
             m + String.to_integer(d1), r + if(a1 > 0, do: 1, else: 0)}

          _ ->
            {s, i, f, m, r}
        end
      end)

    by_axis = new |> Map.keys() |> Enum.frequencies_by(&elem(&1, 0))
    IO.puts("rounds: #{map_size(new)} #{inspect(Enum.sort(by_axis))}")
    IO.puts("rounds identical to the base (pairing and public alternatives): #{same}")
    IO.puts("rounds differing: #{length(differ)}")
    IO.puts("rounds missing on one side: #{length(missing)}")
    IO.puts("rounds with forced searches: #{rounds_searched}")
    IO.puts("forced searches: #{searches}")
    IO.puts("  incremental, equal to the full re-pairing: #{incremental}")
    IO.puts("  fell back to the full re-pairing: #{fallback}")
    IO.puts("  MISMATCHES: #{mismatch}")

    for {key, l, r} <- differ |> Enum.sort() |> Enum.take(30),
        do: IO.puts("  DIFF #{inspect(key)}\n    #{inspect(l)}\n    #{inspect(r)}")

    for key <- missing |> Enum.sort() |> Enum.take(30), do: IO.puts("  MISSING #{inspect(key)}")
    if differ != [] or missing != [] or mismatch > 0, do: System.halt(1)

  _ ->
    run_axis.(
      System.get_env("DIFF_AXIS", "axis"),
      AltDiff.int("DIFF_SEED_FROM", 1),
      AltDiff.int("DIFF_COUNT", 50),
      System.get_env("DIFF_OUT", "alt_diff.log")
    )
end
