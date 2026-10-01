# The matcher's real calls, replayed against an earlier release of it
# (docs/performance.md, "The blossom fallback").
#
#   # capture: every call of new/3 and solve/1, inputs only
#   AINALRAMI_WM_CAPTURE=calls.bin MIX_ENV=test mix run tools/matching_profile.exs ...
#
#   # replay: the same inputs through REPLAY_REF's matcher and this tree's
#   REPLAY_FILES=calls.bin REPLAY_REF=7932e41 REPLAY_REPS=3 \
#     MIX_ENV=test elixir --erl "+S 1" -S mix run tools/matching_replay.exs
#
# For every captured call, both matchers run on the same input and must
# return the same matching and leave the same observable state (the fields
# tools/matching_lockstep.exs compares); each side's time is the least of
# REPLAY_REPS runs. Prints the calls that differ (there should be none),
# and both sides' time in all and by call site and size. A captured state
# is from the build that captured it; `WeightedMatching.__upgrade__/1`
# brings it to this build's internal form (only the per-solve caches can
# differ, and a solve rebuilds them on entry).

ref = System.get_env("REPLAY_REF", "7932e41")
{source, 0} = System.cmd("git", ["show", "#{ref}:lib/ainalrami/weighted_matching.ex"])

source
|> String.replace(
  "defmodule Ainalrami.WeightedMatching do",
  "defmodule Ainalrami.WeightedMatchingReference do"
)
|> String.replace(
  "alias Ainalrami.WeightedMatching.Profile",
  "alias Ainalrami.WeightedMatchingReference.Profile"
)
|> Code.compile_string("weighted_matching_reference.ex")

defmodule Ainalrami.WeightedMatchingReference.Profile do
  @moduledoc false
  def on?, do: false
end

defmodule MatchingReplay do
  import Bitwise
  alias Ainalrami.WeightedMatching, as: New
  alias Ainalrami.WeightedMatchingReference, as: Ref

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

  def read(path) do
    Stream.resource(
      fn -> File.open!(path, [:read, :binary, :raw, {:read_ahead, 1 <<< 20}]) end,
      fn f ->
        with {:ok, <<len::32>>} <- :file.read(f, 4),
             {:ok, rec} when byte_size(rec) == len <- :file.read(f, len) do
          {[:erlang.binary_to_term(rec)], f}
        else
          _ -> {:halt, f}
        end
      end,
      &File.close/1
    )
  end

  defp time(fun, reps) do
    runs = for _ <- 1..reps, do: :timer.tc(fun)
    {runs |> Enum.map(&elem(&1, 0)) |> Enum.min(), elem(hd(runs), 1)}
  end

  def run({:new, site, n, edges, opts}, reps) do
    {tr, a} = time(fn -> Ref.new(n, edges, opts) end, reps)
    {tn, b} = time(fn -> New.new(n, edges, opts) end, reps)
    {:new, site, n, tr, tn, view(a) == view(b)}
  end

  def run({:solve, site, state}, reps) do
    upgraded = New.__upgrade__(state)
    {tr, {a, ma}} = time(fn -> Ref.solve(state) end, reps)
    {tn, {b, mb}} = time(fn -> New.solve(upgraded) end, reps)
    {:solve, site, state.n, tr, tn, ma == mb and view(a) == view(b)}
  end
end

Ainalrami.WeightedMatching.Profile.set(false)
files = System.fetch_env!("REPLAY_FILES") |> String.split(",", trim: true)
reps = String.to_integer(System.get_env("REPLAY_REPS", "3"))

results =
  files
  |> Stream.flat_map(&MatchingReplay.read/1)
  |> Enum.map(&MatchingReplay.run(&1, reps))

bad = Enum.reject(results, &elem(&1, 5))
IO.puts("calls replayed: #{length(results)}, differing: #{length(bad)}")
for b <- Enum.take(bad, 10), do: IO.puts("  DIFF #{inspect(Tuple.delete_at(b, 5))}")

sum = fn rs ->
  {rs |> Enum.map(&elem(&1, 3)) |> Enum.sum(), rs |> Enum.map(&elem(&1, 4)) |> Enum.sum()}
end

{r, n} = sum.(results)

IO.puts(
  "in all: #{ref} #{div(r, 1000)} ms, this tree #{div(n, 1000)} ms " <>
    "(#{Float.round(r / max(n, 1), 2)}x)"
)

results
|> Enum.group_by(fn {what, {ctx, {_m, f, _a}}, n, _, _, _} ->
  {what, ctx, f, Ainalrami.WeightedMatching.Profile.bucket(n)}
end)
|> Enum.map(fn {k, rs} -> {k, length(rs), sum.(rs)} end)
|> Enum.sort_by(fn {_, _, {r, _}} -> -r end)
|> Enum.take(30)
|> Enum.each(fn {{what, ctx, f, b}, c, {r, n}} ->
  IO.puts(
    "  #{what}/#{ctx}/#{f} n<=#{b}: #{c} calls, #{div(r, 1000)} -> #{div(n, 1000)} ms " <>
      "(#{Float.round(r / max(n, 1), 2)}x)"
  )
end)

if bad != [], do: System.halt(1)
