defmodule Ainalrami.WeightedMatching.Profile do
  @moduledoc false

  # Where the weighted matcher's time goes, by call site. Off unless
  # `AINALRAMI_WM_PROFILE=1` is set when the first solve of the VM runs;
  # off, it costs `Ainalrami.WeightedMatching` one `:persistent_term` read
  # per `new/3` and per `solve/1`, and a process-dictionary counter or two
  # per stage and per blossom expansion.
  #
  # On, every `new/3` and `solve/1` is timed and attributed to the first
  # frame of its caller outside the matcher (`{module, function, arity}`),
  # with the context it ran in - `:alts` under `Ainalrami.Alternatives`,
  # `:explain` under an explanation, `:team` for the team engine, `:pair`
  # otherwise - and to a size bucket. Per key: calls, microseconds, the sum
  # and maximum of the vertex count, the edge count, stages, grow steps,
  # blossoms formed and expanded, and how many solves ran on weights past
  # the BEAM's small-integer range (60 bits). `dump/0` returns the table;
  # `reset/0` clears it.

  @key {__MODULE__, :on}
  @table :ainalrami_wm_profile

  def on? do
    case :persistent_term.get(@key, :unset) do
      :unset ->
        on = System.get_env("AINALRAMI_WM_PROFILE") in ["1", "true"]
        if on, do: start()
        :persistent_term.put(@key, on)
        on

      on ->
        on
    end
  end

  defp start do
    :erlang.system_flag(:backtrace_depth, 64)

    if Process.whereis(:ainalrami_wm_profile_owner) == nil do
      parent = self()

      pid =
        spawn(fn ->
          try do
            Process.register(self(), :ainalrami_wm_profile_owner)
            :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
            send(parent, {:wm_profile_ready, self()})
            owner(nil)
          rescue
            _ -> send(parent, {:wm_profile_ready, self()})
          end
        end)

      receive do
        {:wm_profile_ready, ^pid} -> :ok
      end
    end
  end

  # The table's owner, and the writer of `AINALRAMI_WM_CAPTURE`'s file: one
  # process, so records from concurrent solves never interleave.
  defp owner(file) do
    receive do
      {:capture, bin} ->
        file = file || File.open!(System.fetch_env!("AINALRAMI_WM_CAPTURE"), [:append, :binary])
        IO.binwrite(file, <<byte_size(bin)::32, bin::binary>>)
        owner(file)

      {:flush, from} ->
        if file, do: File.close(file)
        send(from, :wm_profile_flushed)
        owner(nil)
    end
  end

  # `AINALRAMI_WM_CAPTURE=<file>` (with the profile on): every
  # `AINALRAMI_WM_CAPTURE_EVERY`-th call (default 1) of `new/3` and of
  # `solve/1` is written to the file, inputs only, as length-prefixed
  # external terms - `{:new, site, n, edges, opts}` and `{:solve, site,
  # state}` - for replaying the matcher offline.
  def capture(term) do
    case System.get_env("AINALRAMI_WM_CAPTURE") do
      nil ->
        :ok

      _ ->
        every = String.to_integer(System.get_env("AINALRAMI_WM_CAPTURE_EVERY", "1"))
        k = :ets.update_counter(@table, :capture_seq, {2, 1}, {:capture_seq, 0})

        if rem(k, every) == 0 do
          send(:ainalrami_wm_profile_owner, {:capture, :erlang.term_to_binary(term)})
        end

        :ok
    end
  end

  def flush do
    case Process.whereis(:ainalrami_wm_profile_owner) do
      nil ->
        :ok

      pid ->
        send(pid, {:flush, self()})

        receive do
          :wm_profile_flushed -> :ok
        end
    end
  end

  # A script's switch: `set(false)` around the work it does not want counted.
  def set(on) when is_boolean(on) do
    if on, do: start()
    :persistent_term.put(@key, on)
  end

  def reset, do: if(:ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table))

  def dump do
    if :ets.whereis(@table) == :undefined, do: [], else: :ets.tab2list(@table)
  end

  # The caller outside the matcher, and the context it runs in.
  def site do
    {:current_stacktrace, frames} = Process.info(self(), :current_stacktrace)
    mods = for {m, f, a, _} <- frames, do: {m, f, a}

    caller =
      Enum.find(mods, {:unknown, :unknown, 0}, fn {m, _, _} ->
        m not in [__MODULE__, Ainalrami.WeightedMatching, Process]
      end)

    ctx =
      cond do
        Enum.any?(mods, fn {m, _, _} -> m == Ainalrami.Alternatives end) -> :alts
        Enum.any?(mods, fn {m, f, _} -> m == Ainalrami.Pairing and explain?(f) end) -> :explain
        Enum.any?(mods, fn {m, _, _} -> team?(m) end) -> :team
        true -> :pair
      end

    {ctx, caller}
  end

  defp explain?(f), do: String.starts_with?(Atom.to_string(f), "explain")
  defp team?(m), do: String.starts_with?(Atom.to_string(m), "Elixir.Ainalrami.TeamPairing")

  def bucket(n) when n <= 16, do: 16
  def bucket(n) when n <= 32, do: 32
  def bucket(n) when n <= 64, do: 64
  def bucket(n) when n <= 128, do: 128
  def bucket(n) when n <= 256, do: 256
  def bucket(n) when n <= 512, do: 512
  def bucket(_), do: 1024

  # `what` is `:new` or `:solve`; `info` the counts of one call.
  def record(what, site, n, us, info) do
    key = {what, site, bucket(n)}
    edges = Map.get(info, :edges, 0)
    big = if Map.get(info, :bits, 0) > 59, do: 1, else: 0

    # calls, us, sum_n, sum_edges, stages, grow, formed, expanded, big
    incr = [
      {2, 1},
      {3, us},
      {4, n},
      {5, edges},
      {6, Map.get(info, :stages, 0)},
      {7, Map.get(info, :grow, 0)},
      {8, Map.get(info, :formed, 0)},
      {9, Map.get(info, :expanded, 0)},
      {10, big}
    ]

    :ets.update_counter(@table, key, incr, {key, 0, 0, 0, 0, 0, 0, 0, 0, 0})
    # The largest vertex count: read and written without a lock, which can
    # lose a maximum to a concurrent writer - a profile, not a proof.
    max_key = {:max_n, key}

    case :ets.lookup(@table, max_key) do
      [{_, m}] when m >= n -> :ok
      _ -> :ets.insert(@table, {max_key, n})
    end

    :ok
  end
end
