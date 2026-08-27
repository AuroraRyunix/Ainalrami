# Is the odd-field bootstrap still returning the SAME answer?
#
#   mix run tools/bootstrap_identity.exs 1001
#
# `tools/bootstrap_split.exs` says where the bootstrap's time goes. This
# says whether a change to it moved the answer, which is the only thing
# that may not happen: `bye_assignee_score_from_field/2` decides C5's score
# threshold and the C9 gate's first-bracket flag, and both are read by
# every bracket after it.
#
# Two fingerprints:
#
#   1. `{score, flag}` - the bootstrap's own return, traced with
#      `{:return_trace}` rather than by exporting the private function, so
#      lib/ is untouched and the same script runs against an older tree.
#   2. the whole round's pairings - `pair_next_round/2`'s actual output,
#      hashed and counted. `score` is only the MINIMUM of the bootstrap
#      matching's leftovers, so two different matchings can agree on the
#      tuple; the round they go on to produce is the wider net.
#
# Run it in the tree before the change and the tree after, and diff the
# output. Reads the field cache `parity_bench.exs` writes, so a 1,001-player
# field is generated once and shared by all three tools.

alias Ainalrami.Pairing

defmodule Identity do
  @cache "/tmp/ainalrami_parity_bench"
  @traced {Pairing, :bye_assignee_score_from_field, 2}

  def run(size) do
    field = load(size)
    IO.puts("#{length(field)} players, #{length(hd(field).games)} rounds played")

    parent = self()
    tracer = spawn(fn -> collect(parent, []) end)

    Code.ensure_loaded!(Pairing)

    if :erlang.trace_pattern(@traced, [{:_, [], [{:return_trace}]}], [:local]) == 0 do
      IO.puts(:stderr, "warning: #{inspect(@traced)} did not match - trace is inert")
    end

    :erlang.trace(self(), true, [:call, {:tracer, tracer}])
    pairs = Pairing.pair_next_round(field, expected_rounds: 9, initial_colour: "w")
    :erlang.trace(self(), false, [:call])
    :erlang.trace_pattern(@traced, false, [:local])

    send(tracer, {:report, self()})

    returns =
      receive do
        {:returns, r} -> Enum.reverse(r)
      after
        30_000 -> []
      end

    case returns do
      [] ->
        IO.puts("bootstrap NOT called - even field, nothing to compare")

      [{score, flag} | _] ->
        IO.puts("bootstrap return: score=#{inspect(score)} single_bye=#{inspect(flag)}")
    end

    IO.puts("bootstrap calls: #{length(returns)}")
    IO.puts("round pairs:     #{length(pairs)}")
    IO.puts("round phash2:    #{:erlang.phash2(pairs)}")
  end

  defp collect(parent, acc) do
    receive do
      {:trace, _, :return_from, @traced, value} -> collect(parent, [value | acc])
      {:report, ^parent} -> send(parent, {:returns, acc})
      _ -> collect(parent, acc)
    end
  end

  defp load(size) do
    case Path.wildcard(Path.join(@cache, "parity_#{size}_r*.trf")) do
      [] ->
        IO.puts(:stderr, "No cached #{size}-player field in #{@cache}. Run parity_bench first.")
        System.halt(1)

      [path | _] ->
        IO.puts("field: #{Path.basename(path)}")
        %{players: players} = Ainalrami.Trf.parse(File.read!(path))
        players
    end
  end
end

size = System.argv() |> Enum.at(0, "1001") |> String.to_integer()
Identity.run(size)
