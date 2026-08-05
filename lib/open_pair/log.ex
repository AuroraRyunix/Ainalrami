defmodule OpenPair.Log do
  @moduledoc """
  OpenPair's trace output. Verbose is the DEFAULT, not an opt-in flag —
  unlike JaVaFo (which prints almost nothing beyond the paired result),
  every meaningful step OpenPair takes gets printed unless `-q`/`--quiet`
  is passed. The idea: an arbiter or a developer chasing down a pairing
  decision should be able to read the run's own output top to bottom and
  see *why* a pairing came out the way it did, not just *what* it was —
  this matters even more once the actual Dutch-system engine lands, where
  "why did board 3 downfloat instead of board 5" is exactly the question
  worth a trace for.

  Three levels, cheapest to loudest:

    * `step/1` — a major phase of the run (loading input, pairing round N,
      writing output). Always numbered/marked so a long trace stays
      scannable. Shown unless quiet.
    * `detail/1` — a line of reasoning within the current step (a
      criterion check, a bracket formed, a colour decision). The bulk of
      the eventual pairing engine's trace will be this level. Shown
      unless quiet.
    * `warn/1` / `error/1` — always shown, quiet or not; these are things
      the user needs to see regardless of verbosity preference.

  Quiet mode is process-global for the lifetime of one CLI invocation (set
  once, read many times from deep inside whatever's currently running) —
  an `Application.env` flag rather than threading an option through every
  call site, since a single escript run is single-purpose and
  single-threaded from the caller's perspective.
  """

  @app :open_pair

  def set_quiet(quiet?) when is_boolean(quiet?) do
    Application.put_env(@app, :quiet, quiet?)
  end

  def quiet?, do: Application.get_env(@app, :quiet, false)

  @doc "A major phase of the run. `==> message`."
  def step(message) do
    unless quiet?(), do: IO.puts("==> #{message}")
  end

  @doc "A line of reasoning within the current step, indented under it."
  def detail(message) do
    unless quiet?(), do: IO.puts("    #{message}")
  end

  @doc "Always shown, quiet or not — printed to stderr so -p's TRF output on stdout stays clean."
  def warn(message), do: IO.puts(:stderr, "warning: #{message}")

  @doc "Always shown, quiet or not — printed to stderr, same reasoning as warn/1."
  def error(message), do: IO.puts(:stderr, "error: #{message}")
end
