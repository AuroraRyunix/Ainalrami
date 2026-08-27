# Where does the odd-field bootstrap's time actually go?
#
# `tools/parity_bench.exs` measured `bye_assignee_score_from_field/2` at
# 6,529.6 ms, 46.2% of a 1,001-player round, against zero on an even field.
# That says WHICH pass, not WHICH PART of it, and the two have completely
# different fixes:
#
#   * If the cost is building the edge list - 500,500 iterations of
#     `legal_pair?/2` plus `colour_compatible?/2` plus the weight
#     arithmetic - the answer is a representation change, or pruning edges
#     that cannot matter, and the algorithm stays as it is.
#
#   * If the cost is `WeightedMatching.new/3` turning that list into an
#     n-by-n nested map, the answer is a different graph representation and
#     nothing about pairing changes at all.
#
#   * If the cost is the SOLVE, neither of those helps and the question
#     becomes whether C5 needs a maximum-weight matching in the first
#     place, or whether a feasibility bound per score group would settle
#     "minimise the score of the PAB assignee" without one.
#
# Same tracing approach as `parity_bench.exs`: `:erlang.trace_pattern` with
# `{:return_trace}`, so nothing in `lib/` is modified to measure it.
#
#   mix run tools/bootstrap_split.exs            # 1001 players
#   mix run tools/bootstrap_split.exs 401
#
# Reads the field cache `parity_bench.exs` writes, so run that first at the
# size you want - generating a 1,001-player round-6 field takes ~2 minutes
# and there is no reason to do it twice.

alias Ainalrami.{Pairing, WeightedMatching}

defmodule Split do
  @cache "/tmp/ainalrami_parity_bench"

  # `new/3` and `solve/1` are called once per BRACKET as well as by the
  # bootstrap, so the trace records every call and the size tells them
  # apart: the bootstrap is the only one that passes the whole field.
  @traced [
    {Pairing, :bye_assignee_score_from_field, 2},
    {WeightedMatching, :new, 3},
    {WeightedMatching, :solve, 1}
  ]

  def run(size) do
    field = load(size)
    IO.puts("#{length(field)} players, #{length(hd(field).games)} rounds played\n")

    parent = self()
    tracer = spawn(fn -> collect(parent, []) end)

    for {m, _, _} <- @traced, do: Code.ensure_loaded!(m)

    for mfa <- @traced do
      if :erlang.trace_pattern(mfa, [{:_, [], [{:return_trace}]}], [:local]) == 0 do
        IO.puts(:stderr, "warning: #{inspect(mfa)} did not match - trace is inert")
      end
    end

    :erlang.trace(self(), true, [:call, :timestamp, {:tracer, tracer}])

    {us, _pairs} =
      :timer.tc(fn ->
        Pairing.pair_next_round(field, expected_rounds: 9, initial_colour: "w")
      end)

    :erlang.trace(self(), false, [:call])
    for mfa <- @traced, do: :erlang.trace_pattern(mfa, false, [:local])

    send(tracer, {:report, self()})

    events =
      receive do
        {:events, e} -> Enum.reverse(e)
      after
        30_000 -> []
      end

    report(events, us)
  end

  # Pairs each call with its return by depth, so a nested `new/3` inside the
  # bootstrap is attributed to itself and not folded into its caller.
  defp report(events, total_us) do
    {spans, _} =
      Enum.reduce(events, {[], []}, fn
        {:call, mfa, args, ts}, {done, stack} ->
          {done, [{mfa, args, ts} | stack]}

        {:return, mfa, ts}, {done, [{mfa, args, start} | rest]} ->
          {[{mfa, arg_size(mfa, args), diff(start, ts), length(rest)} | done], rest}

        _, acc ->
          acc
      end)

    spans = Enum.reverse(spans)

    boot =
      Enum.find(spans, fn {mfa, _, _, _} ->
        mfa == {Pairing, :bye_assignee_score_from_field, 2}
      end)

    IO.puts("round total: #{ms(total_us)}")

    case boot do
      nil ->
        IO.puts("\nbootstrap NOT called - even field, whole pass skipped")

      {_, n, boot_us, boot_depth} ->
        IO.puts("bootstrap:   #{ms(boot_us)}  (#{pct(boot_us, total_us)} of the round), n=#{n}")

        inner =
          Enum.filter(spans, fn {mfa, _, _, d} ->
            mfa != {Pairing, :bye_assignee_score_from_field, 2} and d > boot_depth
          end)

        new_us = sum_for(inner, {WeightedMatching, :new, 3})
        solve_us = sum_for(inner, {WeightedMatching, :solve, 1})
        edges_us = boot_us - new_us - solve_us

        IO.puts("\n  inside the bootstrap:")
        row("building the edge list", edges_us, boot_us)
        row("WeightedMatching.new/3", new_us, boot_us)
        row("WeightedMatching.solve/1", solve_us, boot_us)

        IO.puts("\n  (edge list is the remainder: bootstrap minus new minus solve)")
        IO.puts("\n  calls inside the bootstrap:")

        for {mfa, n, us, _} <- inner do
          IO.puts("    #{inspect(mfa)} n=#{n} #{ms(us)}")
        end

        verdict(edges_us, new_us, solve_us)
    end

    others =
      spans
      |> Enum.filter(fn {mfa, _, _, d} ->
        mfa == {WeightedMatching, :solve, 1} and (boot == nil or d <= elem(boot, 3))
      end)

    if others != [] do
      total = others |> Enum.map(&elem(&1, 2)) |> Enum.sum()
      IO.puts("\n  the rest of the round: #{length(others)} bracket solve(s), #{ms(total)}")
    end
  end

  defp verdict(edges, new, solve) do
    {label, what} =
      cond do
        edges >= new and edges >= solve ->
          {"BUILDING THE EDGE LIST",
           "500,500 legal_pair?/colour_compatible? calls and the weight arithmetic.\n" <>
             "    Fix is representational or a pruning argument; the algorithm stands."}

        new >= solve ->
          {"WeightedMatching.new/3",
           "turning the edge list into the nested weight map.\n" <>
             "    Fix is a graph representation; nothing about pairing changes."}

        true ->
          {"THE SOLVE",
           "the matching itself.\n" <>
             "    Neither of the cheap fixes helps. The question becomes whether C5's\n" <>
             "    \"minimise the score of the PAB assignee\" needs a maximum-weight\n" <>
             "    matching at all, or whether a feasibility bound per score group settles it."}
      end

    IO.puts("\n  DOMINANT COST: #{label}\n    #{what}")
  end

  defp row(label, us, total) do
    IO.puts(
      "    #{String.pad_trailing(label, 26)} #{String.pad_leading(ms(us), 11)}  #{pct(us, total)}"
    )
  end

  defp sum_for(spans, mfa) do
    spans |> Enum.filter(fn {m, _, _, _} -> m == mfa end) |> Enum.map(&elem(&1, 2)) |> Enum.sum()
  end

  # The size each traced call was given, so bracket calls can be told from
  # the whole-field one.
  defp arg_size({WeightedMatching, :new, 3}, [n | _]) when is_integer(n), do: n
  defp arg_size({Pairing, :bye_assignee_score_from_field, 2}, [_, n]) when is_integer(n), do: n
  defp arg_size({WeightedMatching, :solve, 1}, [state]) when is_map(state), do: Map.get(state, :n)
  defp arg_size(_, _), do: nil

  defp collect(parent, acc) do
    receive do
      {:trace_ts, _, :call, {m, f, args}, ts} ->
        collect(parent, [{:call, {m, f, length(args)}, args, ts} | acc])

      {:trace_ts, _, :return_from, mfa, _, ts} ->
        collect(parent, [{:return, mfa, ts} | acc])

      {:report, ^parent} ->
        send(parent, {:events, acc})

      _ ->
        collect(parent, acc)
    end
  end

  defp diff({m1, s1, u1}, {m2, s2, u2}),
    do: ((m2 - m1) * 1_000_000 + (s2 - s1)) * 1_000_000 + (u2 - u1)

  defp ms(us), do: :erlang.float_to_binary(us / 1000, decimals: 1) <> " ms"

  defp pct(_, 0), do: "n/a"
  defp pct(a, b), do: :erlang.float_to_binary(a / b * 100, decimals: 1) <> "%"

  # `parity_bench.exs` caches the generated tournament as a TRF, named
  # `parity_<n>_r<rounds>_s<seed>.trf`, and reads it back with `Trf.parse/1`.
  # Same path here so the two tools share one generation - a 1,001-player
  # five-round file costs about two minutes to make.
  defp load(size) do
    case Path.wildcard(Path.join(@cache, "parity_#{size}_r*.trf")) do
      [] ->
        IO.puts(:stderr, """
        No cached #{size}-player field in #{@cache}.

        Run `mix run tools/parity_bench.exs #{size}` first - it generates the
        field and caches the TRF. Generating a 1,001-player round-6 field takes
        about two minutes and there is no reason to do it twice.
        """)

        System.halt(1)

      [path | _] ->
        IO.puts("field: #{Path.basename(path)}")
        %{players: players} = Ainalrami.Trf.parse(File.read!(path))
        players
    end
  end
end

size = System.argv() |> Enum.at(0, "1001") |> String.to_integer()
Split.run(size)
