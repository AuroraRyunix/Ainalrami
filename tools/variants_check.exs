# The differential harness for `Pairing.pair_variants/3`: every variant the
# batch pairs is paired again on its own by `Pairing.pair_next_round/2`, in
# another process, and the two answers must be identical - the same pairs in
# the same order with the same colours, the same bye, or the same refusal
# (reason, excluded ranks, override and message).
#
#   MIX_ENV=test VAR_W=0 VAR_N=24 VAR_OUT=/tmp/variants \
#     elixir --erl "+S 1" -S mix run tools/variants_check.exs
#
# Run VAR_N workers side by side (VAR_W = 0..N-1), one scheduler each; each
# appends one line per position to VAR_OUT/w<W>.csv and resumes where it
# stopped. Summarise with `VAR_SUMMARY=VAR_OUT mix run tools/variants_check.exs`.
#
# ## A position
#
# `Ainalrami.Test.FuzzTournament` - the generator of every comparison corpus
# here - with its knobs from the environment (byes, forfeits, withdrawals,
# late entrants, acceleration, point systems, forbidden pairs), plus, from a
# separate random stream so the generator's own draws are untouched, the
# arbiter's soft pairs on a third of tournaments and organiser bye
# exclusions on a third of positions (as `tools/perf_diff.exs` draws them).
# The tournament is played forward on this engine to a random round T,
# round T is paired and its results drawn, and k of its boards are left
# OPEN: the position is round T+1 (withdrawals, late entrants and requested
# byes for it applied), and the variants are the 3^k ways the open games
# can end - 1-0, draw, 0-1 - in the order OpenPairings' preview enumerates
# them (the first game varying slowest).
#
# k is drawn from VAR_K (default 1..6). Above VAR_COMPARE_MAX (default 6)
# a position is timed only: the batch pairs every variant and
# VAR_SAMPLE (default 60) of them, drawn at random, are paired on their
# own - and compared - for the time per variant.
#
# ## Environment
#
#   VAR_W, VAR_N        worker index and count (default 0 of 1)
#   VAR_SEED_FROM       first seed (default 1); worker W takes the seeds
#                       VAR_SEED_FROM + W, + W + N, ...
#   VAR_COUNT           positions per worker (default 1000)
#   VAR_SIZES           "lo-hi:weight,..." field-size bands (default
#                       "6-40:40,41-100:25,101-200:20,201-300:15"), or a
#                       list of exact sizes "30,80,150,300"
#   VAR_K               "1-6" or a list "4,5,6"
#   VAR_OUT             output directory (default tmp/variants)
#
# ## The line
#
#   seed,n,round,k,variants,compared,mismatches,batch_us,plain_us,plain_n,
#   failures
#
# `plain_us` is the time of the `plain_n` variants paired on their own
# (all of them when k <= VAR_COMPARE_MAX), so the time per variant is
# `batch_us / variants` against `plain_us / plain_n`. A mismatch is written
# in full to VAR_OUT/mismatch_w<W>.bin (`:erlang.term_to_binary`) with
# everything needed to replay it.

alias Ainalrami.Pairing
alias Ainalrami.Test.FuzzTournament, as: Fuzz

defmodule VariantsCheck do
  alias Ainalrami.Pairing
  alias Ainalrami.Test.FuzzTournament, as: Fuzz

  def int(name, default), do: name |> System.get_env(to_string(default)) |> String.to_integer()

  def range_list(spec) do
    spec
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn part ->
      case String.split(part, "-") do
        [lo, hi] -> Enum.to_list(String.to_integer(lo)..String.to_integer(hi))
        [x] -> [String.to_integer(x)]
      end
    end)
  end

  # "lo-hi:weight,..." or a plain list of sizes.
  def size_picker(spec) do
    if String.contains?(spec, ":") do
      bands =
        spec
        |> String.split(",", trim: true)
        |> Enum.map(fn part ->
          [range, weight] = String.split(part, ":")
          [lo, hi] = String.split(range, "-") |> Enum.map(&String.to_integer/1)
          {lo..hi, String.to_integer(weight)}
        end)

      total = bands |> Enum.map(&elem(&1, 1)) |> Enum.sum()

      fn rng ->
        {roll, rng} = :rand.uniform_s(total, rng)

        {band, _} =
          Enum.reduce_while(bands, roll, fn {range, w}, left ->
            if left <= w, do: {:halt, {range, w}}, else: {:cont, left - w}
          end)
          |> case do
            {range, w} -> {range, w}
            _ -> List.last(bands)
          end

        {i, rng} = :rand.uniform_s(Enum.count(band), rng)
        {Enum.at(band, i - 1), rng}
      end
    else
      sizes = range_list(spec)
      fn rng -> pick(rng, sizes) end
    end
  end

  def pick(rng, list) do
    {i, rng} = :rand.uniform_s(length(list), rng)
    {Enum.at(list, i - 1), rng}
  end

  defp shuffle(rng, list) do
    {keyed, rng} =
      Enum.map_reduce(list, rng, fn x, rng ->
        {r, rng} = :rand.uniform_s(rng)
        {{r, x}, rng}
      end)

    {keyed |> Enum.sort() |> Enum.map(&elem(&1, 1)), rng}
  end

  # The position: `{base, opts, open, round}` or nil when the tournament
  # cannot reach one (it ended, or a round could not be paired).
  def position(seed, n, k) do
    rounds_asked = int("PAIRING_FUZZ_ROUNDS", 9)
    {rounds, player_count, forbidden, roster} = Fuzz.begin!(seed, rounds_asked, n..n)
    rng = :rand.seed_s(:exsss, {seed, 4242, 99_991})
    {soft, rng} = soft_pairs(rng, player_count)
    {position, rng} = pick(rng, [:strong, :weak])

    if rounds < 2 do
      nil
    else
      {target, rng} = pick(rng, Enum.to_list(1..(rounds - 1)))

      opts_for = fn active, rng ->
        {exclusions, rng} = bye_exclusions(rng, active)

        opts =
          [
            expected_rounds: rounds,
            forbidden_pairs: forbidden,
            initial_colour: String.downcase(Fuzz.initial_colour()),
            point_system: Fuzz.point_system()
          ]
          |> then(
            &if(soft == [], do: &1, else: &1 ++ [soft_pairs: soft, soft_position: position])
          )
          |> then(&if(exclusions == [], do: &1, else: &1 ++ [bye_exclusions: exclusions]))

        {opts, rng}
      end

      result =
        Enum.reduce_while(1..target, {roster, rng, nil}, fn round, {players, rng, _} ->
          Fuzz.withdraw_some(round, player_count)
          {active, pending} = Fuzz.reveal_late_entrants(players, round)
          active = Fuzz.assign_requested_byes(active)
          {opts, rng} = opts_for.(active, rng)

          case pair_or_override(active, opts) do
            nil ->
              {:halt, nil}

            pairs ->
              results = Fuzz.simulate_results(pairs)

              {:cont,
               {Fuzz.apply_round(active, pairs, results) ++ pending, rng, {pairs, results}}}
          end
        end)

      with {players, rng, {pairs, results}} <- result do
        # The open games: k boards of round `target` with two players.
        boards = Enum.filter(pairs, fn {_w, b} -> b != nil end)
        {boards, rng} = shuffle(rng, boards)
        open = Enum.take(boards, k)

        # Round target + 1, prepared as the generator prepares any round.
        next = target + 1
        Fuzz.withdraw_some(next, player_count)
        {active, _pending} = Fuzz.reveal_late_entrants(players, next)
        active = Fuzz.assign_requested_byes(active)
        {opts, _rng} = opts_for.(active, rng)

        if open == [] or length(active) < 2 do
          nil
        else
          {active, opts, open, target, results}
        end
      end
    end
  end

  # The real flow on a refusal the organiser's exclusions caused: pair again
  # without the overridden one, as OpenPairings offers.
  defp pair_or_override(players, opts) do
    Pairing.pair_next_round(players, opts)
  rescue
    e in Pairing.NoValidPairingError ->
      if e.reason == :bye_exclusions and e.override do
        pair_or_override(
          players,
          Keyword.update!(opts, :bye_exclusions, &List.delete(&1, e.override))
        )
      end
  end

  @outcomes [:white_win, :draw, :black_win]

  # Every combination of outcomes, the first game varying slowest.
  def worlds(0), do: [[]]
  def worlds(k), do: for(o <- @outcomes, rest <- worlds(k - 1), do: [o | rest])

  # One variant: `%{rank => player}` for the players of the open games, their
  # round-`target` result and their points as that outcome makes them.
  def variant(base_by_rank, open, world, target) do
    open
    |> Enum.zip(world)
    |> Enum.flat_map(fn {{w, b}, outcome} ->
      {wr, br} =
        case outcome do
          :white_win -> {"1", "0"}
          :black_win -> {"0", "1"}
          :draw -> {"=", "="}
        end

      [{w, wr}, {b, br}]
    end)
    |> Enum.flat_map(fn {rank, result} ->
      case Map.fetch(base_by_rank, rank) do
        {:ok, player} -> [{rank, with_result(player, target - 1, result)}]
        # A player of an open game who has left the roster (not possible
        # with the generator's withdrawals, which keep the player) is
        # simply not varied.
        :error -> []
      end
    end)
    |> Map.new()
  end

  defp with_result(player, index, result) do
    old = Enum.at(player.games, index)
    points = player.points - Fuzz.result_points(old.result) + Fuzz.result_points(result)

    %{
      player
      | points: points,
        games: List.replace_at(player.games, index, %{old | result: result})
    }
  end

  def merge(players, variant), do: Enum.map(players, &Map.get(variant, &1.rank, &1))

  def plain(players, opts) do
    {:ok, Pairing.pair_next_round(players, opts)}
  rescue
    e in Pairing.NoValidPairingError -> {:error, e}
  end

  def same?({:ok, a}, {:ok, b}), do: a == b

  def same?({:error, a}, {:error, b}),
    do:
      {a.__struct__, a.message, a.reason, a.excluded, a.override} ==
        {b.__struct__, b.message, b.reason, b.excluded, b.override}

  def same?(_a, _b), do: false

  defp soft_pairs(rng, n) do
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

  def run_one(seed, sizes, ks, compare_max, sample, mismatch_path) do
    rng = :rand.seed_s(:exsss, {seed, 777, 31_337})
    {n, rng} = sizes.(rng)
    {k, rng} = pick(rng, ks)

    case position(seed, n, k) do
      nil ->
        nil

      {base, opts, open, target, _results} ->
        k = length(open)
        by_rank = Map.new(base, &{&1.rank, &1})
        variants = Enum.map(worlds(k), &variant(by_rank, open, &1, target))

        # Warm the code paths once (the first call of a fresh VM loads code).
        _ = plain(merge(base, hd(variants)), opts)

        {batch_us, batch} = :timer.tc(fn -> Pairing.pair_variants(base, variants, opts) end)

        if System.get_env("VAR_STATS"),
          do: IO.puts(:stderr, "#{seed} n=#{n} k=#{k} #{batch_us} #{inspect(Pairing.take_cert_stats())}")

        if System.get_env("AINALRAMI_WM_PROFILE") do
          Ainalrami.WeightedMatching.Profile.dump()
          |> Enum.flat_map(fn
            {{what, site, _}, c, us, sn, se, st, _, _, _, _} when what in [:new, :solve] ->
              [{{what, site}, {c, us, sn, se, st}}]

            _ ->
              []
          end)
          |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
          |> Enum.map(fn {key, rs} ->
            {key, Enum.reduce(rs, {0, 0, 0, 0, 0}, fn {a, b, c, d, e}, {x, y, z, u, v} -> {a + x, b + y, c + z, d + u, e + v} end)}
          end)
          |> Enum.sort_by(fn {_, {_, us, _, _, _}} -> -us end)
          |> Enum.each(fn {key, {c, us, sn, se, st}} ->
            IO.puts(:stderr, "  #{div(us, 1000)} ms #{c} calls n~#{div(sn, max(c, 1))} e~#{div(se, max(c, 1))} stages~#{div(st, max(c, 1))} #{inspect(key)}")
          end)

          Ainalrami.WeightedMatching.Profile.reset()
        end

        indices =
          if k <= compare_max do
            Enum.to_list(0..(length(variants) - 1))
          else
            {shuffled, _} = shuffle(rng, Enum.to_list(0..(length(variants) - 1)))
            shuffled |> Enum.take(sample) |> Enum.sort()
          end

        # Paired on their own in another process, one after the other.
        {plain_us, plains} =
          Task.async(fn ->
            :timer.tc(fn ->
              Enum.map(indices, fn i -> plain(merge(base, Enum.at(variants, i)), opts) end)
            end)
          end)
          |> Task.await(:infinity)

        batch_t = List.to_tuple(batch)

        bad =
          indices
          |> Enum.zip(plains)
          |> Enum.reject(fn {i, p} -> same?(elem(batch_t, i), p) end)

        if bad != [] do
          dump = %{
            seed: seed,
            n: n,
            k: k,
            env:
              System.get_env()
              |> Enum.filter(fn {key, _} -> String.starts_with?(key, "PAIRING_FUZZ") end),
            base: base,
            opts: opts,
            open: open,
            target: target,
            variants: variants,
            bad: Enum.map(bad, fn {i, p} -> {i, elem(batch_t, i), p} end)
          }

          File.write!(
            mismatch_path,
            :erlang.term_to_binary(dump) |> then(&(<<byte_size(&1)::32>> <> &1)),
            [:append]
          )
        end

        failures = Enum.count(batch, &match?({:error, _}, &1))

        [
          seed,
          length(base),
          target + 1,
          k,
          length(variants),
          length(indices),
          length(bad),
          batch_us,
          plain_us,
          length(indices),
          failures
        ]
    end
  end

  def summary(dir) do
    rows =
      dir
      |> Path.join("w*.csv")
      |> Path.wildcard()
      |> Enum.flat_map(fn f -> f |> File.read!() |> String.split("\n", trim: true) end)
      |> Enum.map(fn l -> l |> String.split(",") |> Enum.map(&String.to_integer/1) end)
      |> Enum.filter(fn r -> Enum.at(r, 4) > 0 end)

    total = fn i -> rows |> Enum.map(&Enum.at(&1, i)) |> Enum.sum() end

    IO.puts(
      "positions #{length(rows)}, variants #{total.(4)}, compared #{total.(5)}, " <>
        "mismatches #{total.(6)}, refused variants #{total.(10)}"
    )

    q = fn xs, p ->
      s = Enum.sort(xs)
      Enum.at(s, min(length(s) - 1, round(p * (length(s) - 1))))
    end

    rows
    |> Enum.group_by(fn [_s, n | _] -> band(n) end)
    |> Enum.sort()
    |> Enum.each(fn {band, rs} ->
      rs
      |> Enum.group_by(&Enum.at(&1, 3))
      |> Enum.sort()
      |> Enum.each(fn {k, rs} ->
        per_b = Enum.map(rs, fn r -> Enum.at(r, 7) / Enum.at(r, 4) / 1000 end)
        per_p = Enum.map(rs, fn r -> Enum.at(r, 8) / Enum.at(r, 9) / 1000 end)
        prev_b = Enum.map(rs, fn r -> Enum.at(r, 7) / 1000 end)
        prev_p = Enum.map(rs, fn r -> Enum.at(r, 8) / Enum.at(r, 9) * Enum.at(r, 4) / 1000 end)
        speed = Enum.zip_with(prev_p, prev_b, &(&1 / max(&2, 0.001)))

        IO.puts(
          "#{inspect(band)} k=#{k} (#{length(rs)}): per variant ms batch #{f(q.(per_b, 0.5))}/#{f(q.(per_b, 0.95))} " <>
            "plain #{f(q.(per_p, 0.5))}/#{f(q.(per_p, 0.95))} | preview ms batch #{f(q.(prev_b, 0.5))}/#{f(q.(prev_b, 0.95))} " <>
            "plain #{f(q.(prev_p, 0.5))}/#{f(q.(prev_p, 0.95))} | speedup median #{f(q.(speed, 0.5))} " <>
            "sum #{f(Enum.sum(prev_p) / Enum.sum(prev_b))}"
        )
      end)
    end)
  end

  defp band(n) do
    case System.get_env("VAR_BANDS") do
      "exact" ->
        n

      _ ->
        Enum.find([{6, 40}, {41, 100}, {101, 200}, {201, 300}, {301, 100_000}], fn {lo, hi} ->
          n >= lo and n <= hi
        end)
    end
  end

  defp f(x) when is_float(x), do: :erlang.float_to_binary(x, decimals: 2)
  defp f(x), do: to_string(x)
end

case System.get_env("VAR_SUMMARY") do
  nil ->
    w = VariantsCheck.int("VAR_W", 0)
    nw = VariantsCheck.int("VAR_N", 1)
    from = VariantsCheck.int("VAR_SEED_FROM", 1)
    count = VariantsCheck.int("VAR_COUNT", 1000)

    sizes =
      VariantsCheck.size_picker(
        System.get_env("VAR_SIZES", "6-40:40,41-100:25,101-200:20,201-300:15")
      )

    ks = VariantsCheck.range_list(System.get_env("VAR_K", "1-6"))
    compare_max = VariantsCheck.int("VAR_COMPARE_MAX", 6)
    sample = VariantsCheck.int("VAR_SAMPLE", 60)
    dir = System.get_env("VAR_OUT", "tmp/variants")
    File.mkdir_p!(dir)
    out = Path.join(dir, "w#{w}.csv")
    mismatch = Path.join(dir, "mismatch_w#{w}.bin")

    done =
      case File.read(out) do
        {:ok, s} ->
          s
          |> String.split("\n", trim: true)
          |> Enum.map(&(&1 |> String.split(",") |> hd()))
          |> MapSet.new()

        _ ->
          MapSet.new()
      end

    for i <- 0..(count - 1) do
      seed = from + w + i * nw

      if not MapSet.member?(done, Integer.to_string(seed)) do
        line = VariantsCheck.run_one(seed, sizes, ks, compare_max, sample, mismatch)
        line = line || [seed, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        File.write!(out, Enum.join(line, ",") <> "\n", [:append])
      end
    end

    File.write!(out <> ".done", "")

  dir ->
    VariantsCheck.summary(dir)
end
