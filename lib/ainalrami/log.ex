defmodule Ainalrami.Log do
  @moduledoc """
  Ainalrami's trace output. Verbose is the DEFAULT, not an opt-in flag -
  unlike JaVaFo (which prints almost nothing beyond the paired result),
  every meaningful step Ainalrami takes gets printed unless `-q`/`--quiet`
  is passed. The idea: an arbiter or a developer chasing down a pairing
  decision should be able to read the run's own output top to bottom and
  see *why* a pairing came out the way it did, not just *what* it was.

  ## Levels

  Three, quietest to loudest, set once per CLI invocation:

    * `:quiet` (`-q`/`--quiet`) - warnings and errors only. For scripts and
      for the corpus harness, which runs millions of tournaments and wants
      nothing on stdout but the pairing.
    * `:normal` - the default. `step/1` and `detail/1`: the phases of the
      run and the reasoning inside them.
    * `:debug` (`-d`/`--debug`) - adds `debug/1` on top: per-bracket
      internals, the path each bracket took, candidate counts and timings.
      Reaches into the engine's own decisions rather than describing them.

  Each level is a superset of the one below it, so `--debug` still prints
  everything `:normal` does.

  ## Why debug is a separate level rather than more `detail/1`

  `detail/1` is written for somebody reading a pairing they disagree with:
  it names brackets, floats and colour decisions in the regulation's own
  vocabulary. `debug/1` is written for somebody who thinks the ENGINE is
  wrong: graph sizes, which solve path a bracket took, how long it took.
  Mixing them would make the first audience wade through the second's
  output, and the second is the rarer case by a wide margin.

  ## Where output goes

  `step/1`, `detail/1` and `debug/1` go to **stdout**; `warn/1` and
  `error/1` go to **stderr**. That split is load-bearing: `-p` with no
  output file writes the paired result to stdout, so a warning has to go
  somewhere a caller redirecting stdout to a file will still see it. It
  also means `ainalrami in.trf -p > out.txt` produces a clean file at
  `:quiet` and a file with a trace in it at any louder level - which is
  why quiet exists.

  The level is PER-PROCESS: `set_level/1` writes the calling process's
  dictionary and affects nothing else, so a host that pairs several
  tournaments concurrently gets one level per worker instead of the last
  writer deciding for everybody. It is still a stash rather than an option
  threaded through every call site, because it is set once and read from
  deep inside whatever is running.

  `Application.get_env(:ainalrami, :log_level)` remains the fallback for a
  process that never called `set_level/1` - that is how a host sets a
  default for processes it does not own - and `:normal` the fallback for
  that. Note that a spawned process does NOT inherit its parent's level;
  it falls back to the application default.
  """

  @app :ainalrami
  @key :ainalrami_log_level

  @levels %{quiet: 0, normal: 1, debug: 2}

  @doc """
  Sets the trace level to `:quiet`, `:normal` or `:debug` FOR THE CALLING
  PROCESS ONLY.
  """
  def set_level(level) when is_map_key(@levels, level) do
    Process.put(@key, level)
    :ok
  end

  @doc """
  The current level: this process's if it set one, otherwise the
  application-wide default, otherwise `:normal`.
  """
  def level do
    case Process.get(@key) do
      nil -> Application.get_env(@app, :log_level, :normal)
      level -> level
    end
  end

  @doc """
  Back-compatible switch for the two-state world this module started in.
  `true` is `:quiet`; `false` is `:normal` - note it therefore CLEARS
  `:debug`, which is the sane reading of "turn verbose off".
  """
  def set_quiet(quiet?) when is_boolean(quiet?),
    do: set_level(if(quiet?, do: :quiet, else: :normal))

  @doc "True when nothing but warnings and errors should be printed."
  def quiet?, do: level() == :quiet

  @doc "True when engine-internal tracing should be printed."
  def debug?, do: level() == :debug

  defp at_least?(minimum), do: @levels[level()] >= @levels[minimum]

  @doc "A major phase of the run. `==> message`."
  def step(message) do
    if at_least?(:normal), do: IO.puts("==> #{message}")
  end

  @doc "A line of reasoning within the current step, indented under it."
  def detail(message) do
    if at_least?(:normal), do: IO.puts("    #{message}")
  end

  @doc """
  Engine internals, shown only at `:debug`. Marked with a leading `[dbg]`
  so a trace can be grepped down to just this level, or grepped clean of
  it.

  Takes a function as well as a string: `debug(fn -> expensive() end)`
  never runs the function unless the level is `:debug`, which is what
  makes it safe to call from inside the pairing loop.
  """
  def debug(message) when is_function(message, 0) do
    if at_least?(:debug), do: IO.puts("    [dbg] #{message.()}")
  end

  def debug(message) do
    if at_least?(:debug), do: IO.puts("    [dbg] #{message}")
  end

  @doc "Always shown, whatever the level - printed to stderr so -p's output on stdout stays clean."
  def warn(message), do: IO.puts(:stderr, "warning: #{message}")

  @doc "Always shown, whatever the level - printed to stderr, same reasoning as warn/1."
  def error(message), do: IO.puts(:stderr, "error: #{message}")
end
