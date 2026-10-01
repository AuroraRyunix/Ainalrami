# The matcher, held to its previous release step by step.
#
#   mix run tools/matching_lockstep.exs            # 2,000 random sessions
#   LOCKSTEP_SESSIONS=20000 LOCKSTEP_REF=v0.33.0 mix run tools/matching_lockstep.exs
#   LOCKSTEP_LARGE=1 ...                           # graphs of up to 400 vertices
#
# `tools/matching_baseline.exs` and `tools/matching_incremental.exs` check
# that `Ainalrami.WeightedMatching` finds A maximum-weight matching. That
# is the right test for a change that is allowed to pick a different one
# of several optima. It is the wrong test for a PERFORMANCE change, which
# is not allowed to change anything at all: the pairing engine runs this
# matcher incrementally, hundreds of solves per round, and which optimum a
# solve returns - and the duals and blossoms it leaves behind for the next
# one - decides ties several stages later.
#
# So this compiles the matcher as it stood at `LOCKSTEP_REF` (default
# `v0.33.0`) under another module name, drives both through the same
# random session - `new/3`, `solve/1`, `set_weight/4`, `finalize_pair/3`,
# `shift_and_set/3`, `neighbours/2`, `edge_weight/3`, `mate_of/2` - and
# requires, after EVERY call, the same return value and the same
# persistent state: duals, matches, blossom structure, connectors,
# weights. The caches a solve rebuilds from scratch on entry are not
# compared (a representation change there is allowed); everything a later
# call can observe is.
#
# Sessions are shaped like the engine's: packed bignum weights with a
# nearness term (the round matcher), the same at the engine's own widths -
# six criteria bands packed into 150-700-bit weights with few distinct
# values (`:wide`) - small plain weights with heavy ties (the oracle, the
# team matcher), complete graphs with per-vertex duals (the bye bootstrap),
# and batches of edits that prepare one vertex, a row, or everything at
# once (stage 4 on the field graph). Each session also reads what the
# engine reads off a solved state - `dual_context/1` and
# `possible_partners/3`, `certificate_hint/1`, `vertex_duals/1` - and
# sometimes scales it (`scale/2`), and one in four starts with a one-shot
# `solve/2` of its graph, compared as well.
#
# `LOCKSTEP_LARGE=1` draws the vertex count up to 400 (sparse above 100),
# for the graphs the round matcher and the local brackets solve.

ref = System.get_env("LOCKSTEP_REF", "v0.33.0")
sessions = String.to_integer(System.get_env("LOCKSTEP_SESSIONS", "2000"))
seed_from = String.to_integer(System.get_env("LOCKSTEP_SEED_FROM", "1"))

{source, 0} = System.cmd("git", ["show", "#{ref}:lib/ainalrami/weighted_matching.ex"])

source
|> String.replace(
  "defmodule Ainalrami.WeightedMatching do",
  "defmodule Ainalrami.WeightedMatchingReference do"
)
|> Code.compile_string("weighted_matching_reference.ex")

defmodule Lockstep do
  alias Ainalrami.WeightedMatching, as: New
  alias Ainalrami.WeightedMatchingReference, as: Ref

  # Everything a later call can observe. The label map, the forest's edges
  # and the delta-scan caches are rebuilt by every `solve/1` before they are
  # read, so they are left out.
  @observable [
    :n,
    :max_w,
    :gcd,
    :weight,
    :dual,
    :mate,
    :in_blossom,
    :children,
    :vertices_of,
    :parent_of,
    :base,
    :blossom_match,
    :connectors,
    :next_blossom_id
  ]

  def view(state), do: Map.take(state, @observable)

  def check!(where, a, b) do
    if a != b do
      raise "lockstep: #{inspect(where)} differs"
    end
  end

  def same_state!(where, {:ok, a}, {:ok, b}), do: same_state!(where, a, b)
  def same_state!(_where, :error, :error), do: :ok
  def same_state!(where, %{} = a, %{} = b), do: check!(where, view(a), view(b))
  def same_state!(where, a, b), do: check!(where, a, b)

  def run(seed) do
    :rand.seed(:exsss, {seed, seed * 7919, seed * 104_729})

    n =
      if System.get_env("LOCKSTEP_LARGE") == "1",
        do: Enum.random([2, 3, 5, 8, 13, 24, 40, 65, 90, 120, 160, 200, 260, 330, 400]),
        else: Enum.random([2, 3, 4, 5, 6, 8, 11, 16, 24, 40, 65, 90])

    shape = Enum.random([:packed, :wide, :plain, :ties, :complete])
    shape = if shape == :complete and n > 120, do: :wide, else: shape
    {edges, opts, draw} = graph(shape, n)

    if shape != :complete and :rand.uniform(4) == 1 do
      plain = Enum.map(edges, fn {i, j, w} -> {i, j, w} end)
      check!({seed, :solve2}, New.solve(n, plain), Ref.solve(n, plain))
    end

    a = New.new(n, edges, opts)
    b = Ref.new(n, edges, opts)
    same_state!({seed, :new}, a, b)

    steps = if n > 120, do: Enum.random(4..16), else: Enum.random(4..40)

    Process.put(:lockstep_calls, 0)

    Enum.reduce(1..steps, {a, b}, fn step, {a, b} ->
      Process.put(:lockstep_calls, Process.get(:lockstep_calls) + 1)
      where = {seed, shape, n, step}

      case op(n) do
        :solve ->
          {a, ma} = New.solve(a)
          {b, mb} = Ref.solve(b)
          check!({where, :matching}, ma, mb)
          same_state!({where, :solve}, a, b)
          {a, b}

        {:edit, batch} ->
          changes = changes(batch, n, draw, a.gcd)

          {a, b} =
            Enum.reduce(changes, {a, b}, fn {u, v, w}, {a, b} ->
              {New.set_weight(a, u, v, w), Ref.set_weight(b, u, v, w)}
            end)

          same_state!({where, :set_weight}, a, b)
          {a, b}

        :finalize ->
          case Enum.find(Map.to_list(a.mate), fn {u, v} -> u < v end) do
            nil ->
              {a, b}

            {u, v} ->
              ra = New.finalize_pair(a, u, v)
              rb = Ref.finalize_pair(b, u, v)
              same_state!({where, :finalize}, ra, rb)

              case {ra, rb} do
                {{:ok, a}, {:ok, b}} -> {a, b}
                _ -> {a, b}
              end
          end

        :shift ->
          vs = Enum.take_random(0..(n - 1)//1, min(n, Enum.random(1..4)))
          shifts = Map.new(vs, &{&1, 2 * Enum.random(0..3)})

          edges =
            for u <- vs,
                v <- Enum.take_random(0..(n - 1)//1, 2),
                u != v,
                do: {min(u, v), max(u, v), draw.() * a.gcd}

          ra = New.shift_and_set(a, shifts, edges)
          rb = Ref.shift_and_set(b, shifts, edges)
          same_state!({where, :shift}, ra, rb)

          case {ra, rb} do
            {{:ok, a}, {:ok, b}} -> {a, b}
            _ -> {a, b}
          end

        :read ->
          v = Enum.random(0..(n - 1)//1)
          u = Enum.random(0..(n - 1)//1)

          check!(
            {where, :neighbours},
            Enum.sort(New.neighbours(a, v)),
            Enum.sort(Ref.neighbours(b, v))
          )

          check!({where, :edge_weight}, New.edge_weight(a, v, u), Ref.edge_weight(b, v, u))
          check!({where, :mate_of}, New.mate_of(a, v), Ref.mate_of(b, v))
          check!({where, :vertex_duals}, New.vertex_duals(a), Ref.vertex_duals(b))
          check!({where, :certificate_hint}, New.certificate_hint(a), Ref.certificate_hint(b))

          ca = New.dual_context(a)
          cb = Ref.dual_context(b)
          check!({where, :dual_context}, ca, cb)

          if ca != :invalid do
            check!(
              {where, :possible_partners},
              New.possible_partners(a, ca, v),
              Ref.possible_partners(b, cb, v)
            )
          end

          {a, b}

        :scale ->
          k = Enum.random(2..5)
          a = New.scale(a, k)
          b = Ref.scale(b, k)
          same_state!({where, :scale}, a, b)
          {a, b}
      end
    end)

    {:ok, n, shape, Process.get(:lockstep_calls)}
  end

  defp op(n) do
    case :rand.uniform(20) do
      x when x <= 7 -> :solve
      x when x <= 10 -> {:edit, :one}
      x when x <= 12 -> {:edit, :few}
      13 -> {:edit, :row}
      14 -> if n <= 40, do: {:edit, :all}, else: {:edit, :few}
      x when x <= 17 -> :finalize
      18 -> :shift
      19 -> if :rand.uniform(4) == 1, do: :scale, else: :read
      _ -> :read
    end
  end

  # Weight shapes. Every one returns `{edges, new_opts, draw}` where `draw`
  # produces a weight on the same scale for later edits.
  defp graph(:packed, n) do
    # Criteria packed into a bignum band, times the nearness scale, plus a
    # nearness term - the round matcher's `edge_weigher/3` shape.
    band = Integer.pow(n + 1, 12) * 64
    p = n * n + 1
    base = fn -> :rand.uniform(4) * band + :rand.uniform(6) end
    density = if n > 100, do: Enum.random([3, 8, 15, 50]), else: Enum.random([35, 70, 100])

    edges =
      for i <- 0..(n - 2)//1, j <- (i + 1)..(n - 1)//1, :rand.uniform(100) <= density do
        {i, j, base.() * p + n - abs(j - i - div(n, 2))}
      end

    ceiling = 8 * band * p + p

    draw = fn ->
      if :rand.uniform(5) == 1, do: 0, else: base.() * p + :rand.uniform(n)
    end

    {edges, [max_weight: ceiling, gcd: 1], draw}
  end

  defp graph(:wide, n) do
    # The engine's widths: six criteria packed into bands of 24-110 bits
    # each, a few values per criterion (so many edges share a weight and
    # optima tie), times a nearness scale, plus the nearness term.
    bits = Enum.random([24, 40, 64, 110])
    span = Integer.pow(2, bits)
    p = n * n + 1

    base = fn ->
      Enum.reduce(1..6, 0, fn _, acc -> acc * span + Enum.random([0, 1, 1, 2, 3]) end) + 1
    end

    density = if n > 100, do: Enum.random([3, 8, 15, 50]), else: Enum.random([30, 70, 100])

    edges =
      for i <- 0..(n - 2)//1, j <- (i + 1)..(n - 1)//1, :rand.uniform(100) <= density do
        {i, j, base.() * p + n - abs(j - i - div(n, 2))}
      end

    ceiling = 8 * Integer.pow(span, 6) * p + p

    draw = fn ->
      if :rand.uniform(5) == 1, do: 0, else: base.() * p + :rand.uniform(n)
    end

    {edges, [max_weight: ceiling, gcd: 1], draw}
  end

  defp graph(:plain, n) do
    density = if n > 100, do: Enum.random([3, 8, 15, 50]), else: Enum.random([30, 60, 100])

    edges =
      for i <- 0..(n - 2)//1,
          j <- (i + 1)..(n - 1)//1,
          :rand.uniform(100) <= density,
          do: {i, j, :rand.uniform(50)}

    {edges, [max_weight: 60, gcd: 1],
     fn -> if :rand.uniform(5) == 1, do: 0, else: :rand.uniform(50) end}
  end

  defp graph(:ties, n) do
    density = if n > 100, do: Enum.random([3, 8, 15, 50]), else: 70

    edges =
      for i <- 0..(n - 2)//1,
          j <- (i + 1)..(n - 1)//1,
          :rand.uniform(100) <= density,
          do: {i, j, Enum.random([10, 10, 10, 12])}

    {edges, [max_weight: 20, gcd: 1], fn -> Enum.random([0, 10, 10, 12]) end}
  end

  defp graph(:complete, n) do
    # Per-vertex decomposable weights on a complete graph with the duals
    # handed in - `bye_assignee_score_from_field/2`'s bootstrap shape.
    vertex = Map.new(0..(n - 1)//1, &{&1, 2 * :rand.uniform(6)})

    adjacency =
      Map.new(0..(n - 1)//1, fn i ->
        {i,
         Map.new(Enum.reject(0..(n - 1)//1, &(&1 == i)), fn j ->
           {j, Map.fetch!(vertex, i) + Map.fetch!(vertex, j)}
         end)}
      end)

    duals = Map.new(vertex, fn {v, w} -> {v, w} end)
    max = 2 * Enum.max(Map.values(vertex), fn -> 2 end)

    {[], [adjacency: adjacency, duals: duals, max_weight: max],
     fn -> if :rand.uniform(4) == 1, do: 0, else: :rand.uniform(max) end}
  end

  defp changes(:one, n, draw, gcd), do: pairs(1, n, draw, gcd)
  defp changes(:few, n, draw, gcd), do: pairs(Enum.random(2..10), n, draw, gcd)

  defp changes(:row, n, draw, gcd) do
    v = Enum.random(0..(n - 1)//1)
    for u <- 0..(n - 1)//1, u != v, do: {v, u, scale(draw.(), gcd)}
  end

  defp changes(:all, n, draw, gcd) do
    for u <- 0..(n - 2)//1,
        v <- (u + 1)..(n - 1)//1,
        :rand.uniform(3) == 1,
        do: {u, v, scale(draw.(), gcd)}
  end

  defp pairs(k, n, draw, gcd) do
    for _ <- 1..k, n > 1 do
      u = Enum.random(0..(n - 1)//1)
      v = Enum.random(0..(n - 1)//1)
      if u == v, do: nil, else: {u, v, scale(draw.(), gcd)}
    end
    |> Enum.reject(&is_nil/1)
  end

  defp scale(0, _gcd), do: 0
  defp scale(w, gcd), do: max(w - rem(w, gcd), gcd)
end

started = System.monotonic_time(:millisecond)

results =
  seed_from..(seed_from + sessions - 1)
  |> Task.async_stream(
    fn seed ->
      try do
        Lockstep.run(seed)
      rescue
        e -> {:failed, seed, Exception.message(e)}
      end
    end,
    max_concurrency: System.schedulers_online(),
    timeout: :infinity
  )
  |> Enum.map(fn {:ok, r} -> r end)

failures = Enum.reject(results, &match?({:ok, _, _, _}, &1))
passed = for {:ok, n, shape, calls} <- results, do: {n, shape, calls}

by_size =
  passed
  |> Enum.group_by(fn {n, _, _} ->
    cond do
      n <= 16 -> "2-16"
      n <= 64 -> "17-64"
      n <= 128 -> "65-128"
      true -> "129-400"
    end
  end)
  |> Enum.map(fn {k, v} -> {k, length(v)} end)
  |> Enum.sort()

IO.puts("sessions by vertex count: #{inspect(by_size)}")

IO.puts(
  "sessions by shape: #{inspect(passed |> Enum.frequencies_by(&elem(&1, 1)) |> Enum.sort())}"
)

IO.puts("calls compared: #{passed |> Enum.map(&elem(&1, 2)) |> Enum.sum()}")

secs = (System.monotonic_time(:millisecond) - started) / 1000
IO.puts("#{sessions} sessions against #{ref} in #{Float.round(secs, 1)} s")

case failures do
  [] ->
    IO.puts("LOCKSTEP: every call returned the same value and left the same state")

  _ ->
    IO.puts("#{length(failures)} FAILURES")
    for f <- Enum.take(failures, 10), do: IO.puts("  #{inspect(f)}")
    System.halt(1)
end
