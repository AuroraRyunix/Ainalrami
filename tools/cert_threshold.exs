# Where the certified shortcuts start paying: every round of a fuzz
# tournament is paired under several engine modes, each answer checked
# equal to the first mode's, and (optionally) each timed.
#
#   MIX_ENV=test CT_W=0 CT_N=16 CT_SIZES=10,20,30,40,60,80,100,150 \
#     CT_MODES=off,on,force CT_TIME=1 CT_OUT=OUT \
#     elixir --erl "+S 1" -S mix run tools/cert_threshold.exs
#
# A mode is a set of engine environment flags, applied around each call
# (each worker is its own OS process, so the environment is its own):
#
#   off    AINALRAMI_CERT=off - the reference search at every size
#   plain  nothing set - the build's default
#   on     AINALRAMI_CERT_MIN=0 - the shortcuts at every size, soft pairs
#          or not, their own small-solve thresholds kept
#   force  AINALRAMI_CERT=force - the same with those thresholds lifted
#   old    AINALRAMI_CERT_MIN=100 - the rule before the threshold study
#          (from 100 players, soft pairs or not)
#   min<N> AINALRAMI_CERT_MIN=<N> - from N players up, soft pairs or not
#
# The tournament is played forward on the first mode's answers; every
# other mode must give the identical answer (pairs in order, colours, bye;
# or the same refusal), and any difference is written in full to
# CT_OUT/diff_<seed>.bin.
#
# The tournaments: `Ainalrami.Test.FuzzTournament` at exactly the given
# size, with the mixed knobs below unless the environment sets them, plus
# the arbiter's soft pairs on a third of tournaments and organiser bye
# exclusions on a third of rounds (as `tools/perf_diff.exs` draws them).
#
# ## Environment
#
#   CT_W, CT_N      worker index and count (default 0 of 1)
#   CT_SIZES        exact field sizes, or "lo-hi" ranges (default as above);
#                   tournament i of a worker takes size i mod length
#   CT_COUNT        tournaments per worker (default 100)
#   CT_SEED_FROM    first seed (default 1); worker W takes SEED_FROM + W,
#                   + W + N, ...
#   CT_ROUNDS       rounds per tournament (default 9)
#   CT_FROM_ROUND   first round compared/timed (default 3)
#   CT_MODES        comma-separated modes (default "plain,on")
#   CT_TIME         "1": time each mode (min of CT_REPS calls, modes in a
#                   shuffled order per round); otherwise one call each
#   CT_REPS         calls per mode when timing (default 2)
#   CT_OUT          output directory (default tmp/cert_threshold)
#   CT_SOFT         "all" / "none": soft pairs on every tournament / none
#                   (default: a third, the same third for every run)
#
# ## The line (CT_OUT/w<W>.csv)
#
#   seed,size,round,active,equal,us_<mode>...
#
# Summarise with `CT_SUMMARY=DIR mix run tools/cert_threshold.exs`.

alias Ainalrami.Pairing
alias Ainalrami.Test.FuzzTournament, as: Fuzz

defmodule CertThreshold do
  alias Ainalrami.Pairing
  alias Ainalrami.Test.FuzzTournament, as: Fuzz

  @knobs %{
    "PAIRING_FUZZ_BYE_PCT" => "8",
    "PAIRING_FUZZ_FORFEIT_PCT" => "5",
    "PAIRING_FUZZ_FORBIDDEN_PCT" => "3",
    "PAIRING_FUZZ_WITHDRAW_PCT" => "2",
    "PAIRING_FUZZ_LATE_PCT" => "4",
    "PAIRING_FUZZ_ACCEL" => "mixed",
    "PAIRING_FUZZ_POINT_SYSTEM" => "mixed",
    "PAIRING_FUZZ_INITIAL_COLOUR" => "mixed",
    "PAIRING_FUZZ_RATING_MODE" => "mixed"
  }

  @engine_flags ~w(AINALRAMI_CERT AINALRAMI_CERT_MIN)

  def int(name, default), do: name |> System.get_env(to_string(default)) |> String.to_integer()

  def sizes(spec) do
    spec
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn part ->
      case String.split(part, "-") do
        [lo, hi] -> [String.to_integer(lo)..String.to_integer(hi)]
        [x] -> [String.to_integer(x)..String.to_integer(x)]
      end
    end)
  end

  def set_knobs do
    Enum.each(@knobs, fn {k, v} -> if System.get_env(k) == nil, do: System.put_env(k, v) end)
  end

  defp mode_env("off"), do: %{"AINALRAMI_CERT" => "off"}
  defp mode_env("plain"), do: %{}
  defp mode_env("on"), do: %{"AINALRAMI_CERT_MIN" => "0"}
  defp mode_env("old"), do: %{"AINALRAMI_CERT_MIN" => "100"}
  defp mode_env("force"), do: %{"AINALRAMI_CERT" => "force"}
  defp mode_env("min" <> n), do: %{"AINALRAMI_CERT_MIN" => n}

  defp with_mode(mode, fun) do
    env = mode_env(mode)
    Enum.each(@engine_flags, &System.delete_env/1)
    Enum.each(env, fn {k, v} -> System.put_env(k, v) end)

    try do
      fun.()
    after
      Enum.each(@engine_flags, &System.delete_env/1)
    end
  end

  # The pairing or the refusal; an exclusion refusal is answered the way
  # OpenPairings answers it, so the tournament goes on.
  defp pair(players, opts) do
    pairs = Pairing.pair_next_round(players, opts)
    {{:ok, pairs}, pairs}
  rescue
    e in Pairing.NoValidPairingError ->
      refusal = {:raised, e.reason, e.excluded, e.override, e.message}

      if e.reason == :bye_exclusions and e.override do
        opts = Keyword.update!(opts, :bye_exclusions, &List.delete(&1, e.override))
        {retry, pairs} = pair(players, opts)
        {{refusal, retry}, pairs}
      else
        {refusal, nil}
      end
  end

  defp timed(mode, players, opts, reps) do
    with_mode(mode, fn ->
      Enum.reduce(1..reps, {nil, nil, nil}, fn _, {best, _, _} ->
        {us, {result, pairs}} = :timer.tc(fn -> pair(players, opts) end)
        {if(best == nil, do: us, else: min(best, us)), result, pairs}
      end)
    end)
  end

  def run(seed, size_range, cfg) do
    {rounds, player_count, forbidden, roster} = Fuzz.begin!(seed, cfg.rounds, size_range)
    rng = :rand.seed_s(:exsss, {seed, 4242, 99_991})
    {soft, rng} = soft_pairs(rng, player_count)
    {position, rng} = pick(rng, [:strong, :weak])
    [lead | others] = cfg.modes

    Enum.reduce_while(1..rounds, {[], [], roster, rng}, fn round, {lines, diffs, players, rng} ->
      Fuzz.withdraw_some(round, player_count)
      {active, pending} = Fuzz.reveal_late_entrants(players, round)
      active = Fuzz.assign_requested_byes(active)
      {exclusions, rng} = bye_exclusions(rng, active)

      opts =
        [
          expected_rounds: rounds,
          forbidden_pairs: forbidden,
          initial_colour: String.downcase(Fuzz.initial_colour()),
          point_system: Fuzz.point_system()
        ]
        |> then(&if(soft == [], do: &1, else: &1 ++ [soft_pairs: soft, soft_position: position]))
        |> then(&if(exclusions == [], do: &1, else: &1 ++ [bye_exclusions: exclusions]))

      measured? = round >= cfg.from_round

      {results, rng} =
        if measured? do
          reps = if cfg.time?, do: cfg.reps, else: 1
          {order, rng} = shuffle(rng, cfg.modes, cfg.time?)

          results =
            order
            |> Enum.map(fn mode -> {mode, timed(mode, active, opts, reps)} end)
            |> Map.new()

          {results, rng}
        else
          {%{lead => timed(lead, active, opts, 1)}, rng}
        end

      {_, lead_result, pairs} = results[lead]

      {lines, diffs} =
        if measured? do
          bad =
            Enum.reject(others, fn m -> elem(results[m], 1) == lead_result end)

          diffs =
            if bad == [],
              do: diffs,
              else: [
                %{
                  seed: seed,
                  round: round,
                  players: active,
                  opts: opts,
                  results: Map.new(results, fn {m, {_, r, _}} -> {m, r} end)
                }
                | diffs
              ]

          line =
            [seed, player_count, round, length(active), if(bad == [], do: 1, else: 0)] ++
              Enum.map(cfg.modes, fn m -> elem(results[m], 0) end)

          {[Enum.join(line, ",") | lines], diffs}
        else
          {lines, diffs}
        end

      case pairs do
        nil ->
          {:halt, {lines, diffs, players, rng}}

        pairs ->
          next = Fuzz.apply_round(active, pairs, Fuzz.simulate_results(pairs))
          {:cont, {lines, diffs, next ++ pending, rng}}
      end
    end)
    |> then(fn {lines, diffs, _, _} -> {Enum.reverse(lines), diffs} end)
  end

  defp shuffle(rng, modes, false), do: {modes, rng}

  defp shuffle(rng, modes, true) do
    {keyed, rng} =
      Enum.map_reduce(modes, rng, fn m, rng ->
        {x, rng} = :rand.uniform_s(rng)
        {{x, m}, rng}
      end)

    {keyed |> Enum.sort() |> Enum.map(&elem(&1, 1)), rng}
  end

  defp soft_pairs(rng, n) do
    {roll, rng} = :rand.uniform_s(3, rng)

    roll =
      case System.get_env("CT_SOFT") do
        "all" -> 1
        "none" -> 0
        _ -> roll
      end

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

  defp bye_exclusions(rng, active) do
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

  # ---- summary ----

  def summary(dir) do
    rows =
      dir
      |> Path.join("w*.csv")
      |> Path.wildcard()
      |> Enum.flat_map(&File.stream!/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> Enum.map(fn l -> l |> String.split(",") |> Enum.map(&String.to_integer/1) end)

    modes =
      case dir |> Path.join("modes") |> File.read() do
        {:ok, m} -> m |> String.trim() |> String.split(",")
        _ -> ["plain", "on"]
      end

    unequal = Enum.count(rows, fn [_, _, _, _, eq | _] -> eq == 0 end)
    IO.puts("rows #{length(rows)}, unequal #{unequal}, modes #{Enum.join(modes, ",")}")

    [lead | others] = modes

    rows
    |> Enum.group_by(fn [_, size | _] -> size end)
    |> Enum.sort()
    |> Enum.each(fn {size, rs} ->
      times = fn i -> Enum.map(rs, &(Enum.at(&1, 5 + i) / 1000)) end
      lead_t = times.(0)

      cols =
        others
        |> Enum.with_index(1)
        |> Enum.map(fn {m, i} ->
          t = times.(i)
          ratios = Enum.zip_with(lead_t, t, fn a, b -> a / max(b, 0.001) end)
          slower = Enum.count(Enum.zip(lead_t, t), fn {a, b} -> b > a * 1.2 and b - a > 2 end)

          "#{m}: med #{f(pct(t, 50))} p95 #{f(pct(t, 95))} p99 #{f(pct(t, 99))} max #{f(Enum.max(t))} | " <>
            "speedup med #{f(pct(ratios, 50))} p5 #{f(pct(ratios, 5))} p1 #{f(pct(ratios, 1))} " <>
            "min #{f(Enum.min(ratios))} all #{f(Enum.sum(lead_t) / Enum.sum(t))} slower>20%&2ms #{slower}"
        end)

      IO.puts(
        "n=#{size} pos=#{length(rs)} #{lead}: med #{f(pct(lead_t, 50))} p95 #{f(pct(lead_t, 95))} " <>
          "p99 #{f(pct(lead_t, 99))} max #{f(Enum.max(lead_t))}"
      )

      Enum.each(cols, &IO.puts("    " <> &1))
    end)
  end

  defp pct(list, p) do
    s = Enum.sort(list)
    Enum.at(s, min(length(s) - 1, trunc(p / 100 * length(s))))
  end

  defp f(x), do: :erlang.float_to_binary(x / 1, decimals: 2)
end

case System.get_env("CT_SUMMARY") do
  nil ->
    CertThreshold.set_knobs()
    w = CertThreshold.int("CT_W", 0)
    n = CertThreshold.int("CT_N", 1)
    count = CertThreshold.int("CT_COUNT", 100)
    seed_from = CertThreshold.int("CT_SEED_FROM", 1)
    sizes = CertThreshold.sizes(System.get_env("CT_SIZES", "10,20,30,40,60,80,100,150"))
    out = System.get_env("CT_OUT", "tmp/cert_threshold")
    File.mkdir_p!(out)

    cfg = %{
      rounds: CertThreshold.int("CT_ROUNDS", 9),
      from_round: CertThreshold.int("CT_FROM_ROUND", 3),
      modes: System.get_env("CT_MODES", "plain,on") |> String.split(","),
      time?: System.get_env("CT_TIME") == "1",
      reps: CertThreshold.int("CT_REPS", 2)
    }

    File.write!(Path.join(out, "modes"), Enum.join(cfg.modes, ","))
    csv = Path.join(out, "w#{w}.csv")

    done =
      case File.read(csv) do
        {:ok, body} ->
          body
          |> String.split("\n", trim: true)
          |> Enum.map(fn l -> l |> String.split(",") |> hd() end)
          |> MapSet.new()

        _ ->
          MapSet.new()
      end

    for i <- 0..(count - 1) do
      seed = seed_from + w + i * n
      size = Enum.at(sizes, rem(i, length(sizes)))

      unless MapSet.member?(done, "#{seed}") do
        {lines, diffs} = CertThreshold.run(seed, size, cfg)

        if diffs != [] do
          File.write!(Path.join(out, "diff_#{seed}.bin"), :erlang.term_to_binary(diffs))
          IO.puts("DIFF seed #{seed}")
        end

        if lines != [], do: File.write!(csv, Enum.join(lines, "\n") <> "\n", [:append])
      end
    end

    IO.puts("worker #{w} done")

  dir ->
    CertThreshold.summary(dir)
end

_ = {Pairing, Fuzz}
