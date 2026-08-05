defmodule OpenPair.CLI do
  @moduledoc """
  Command-line entry point. Deliberately mirrors JaVaFo's own invocation
  shape — `java -jar javafo.jar input.trf -p output.txt` (confirmed against
  the sibling project's real `System.cmd` call, not guessed) — as
  `openpair input.trf -p output.trf`, so a caller that already knows how to
  drive JaVaFo only has to swap the executable name, not rewrite its
  argument-building code. Same idea extends to the other two JaVaFo modes,
  `-g` (Random Tournament Generator) and `-c` (Pairings Checker), even
  though neither has a real implementation yet (see TODO.md) — the flag
  exists and gives a clear "not built yet" answer rather than an
  unknown-flag error, so the CLI's shape is already stable for whoever
  starts building those next.

  Verbose trace is the default (see `OpenPair.Log`); pass `-q`/`--quiet` to
  suppress it.

  `run/1` does the real work and returns a plain exit code, deliberately
  never calling `System.halt/1` itself — that would kill the test VM if
  called from ExUnit. `main/1` (the actual escript entry point) is the only
  place that halts.
  """

  alias OpenPair.{Log, Pairing, Trf}

  @doc false
  def main(argv), do: argv |> run() |> System.halt()

  @doc "Runs the CLI and returns an exit code, without halting the VM — see moduledoc."
  def run(argv) do
    {flags, positional} = split_flags(argv)

    Log.set_quiet("-q" in flags or "--quiet" in flags)

    cond do
      "-h" in flags or "--help" in flags -> print_help_and_ok()
      "--version" in flags -> print_version_and_ok()
      true -> dispatch(positional, flags)
    end
  end

  defp split_flags(argv) do
    known_bare_flags = ~w(-p -g -c -q --quiet -h --help --version)
    Enum.split_with(argv, &(&1 in known_bare_flags))
  end

  # `input.trf -p [output.trf]` — input file is always the first positional
  # argument, exactly like JaVaFo; the mode flag then decides what happens
  # to the rest.
  defp dispatch([input | rest], flags) do
    cond do
      "-p" in flags -> pair(input, rest)
      "-g" in flags -> not_implemented("Random Tournament Generator (-g)")
      "-c" in flags -> not_implemented("Pairings Checker (-c)")
      true -> usage_error("missing mode flag: one of -p, -g, -c")
    end
  end

  defp dispatch([], _flags), do: usage_error("missing input TRF file")

  defp pair(input_path, positional_rest) do
    Log.step("Loading #{input_path}")

    with {:ok, text} <- read_input(input_path),
         {:ok, parsed} <- parse_input(text) do
      round_count = report_roster(parsed)

      Log.step("Pairing engine")

      Log.detail(
        if round_count == 0, do: "pairing round 1", else: "pairing round #{round_count + 1}"
      )

      pairs = Pairing.pair_next_round(parsed.players)
      write_pairs(pairs, positional_rest)

      0
    else
      {:error, :halt} -> 1
    end
  end

  defp write_pairs(pairs, positional_rest) do
    for {white, black} <- pairs do
      Log.detail(board_description(white, black))
    end

    output_text = format_pairs(pairs)

    case positional_rest do
      [output_path | _] ->
        File.write!(output_path, output_text)
        Log.detail("wrote #{output_path}")

      [] ->
        IO.write(output_text)
    end
  end

  defp board_description(white, nil), do: "##{white} — pairing-allocated bye"
  defp board_description(white, black), do: "##{white} (white) vs. ##{black} (black)"

  # Same shape as javafo.jar's own output file: a count line, then one
  # "white black" line per pair (0 for a bye), CRLF throughout — confirmed
  # against a real javafo.jar run, not assumed.
  defp format_pairs(pairs) do
    header = "#{length(pairs)}\r\n"
    body = Enum.map_join(pairs, "", fn {w, b} -> "#{w} #{b || 0}\r\n" end)
    header <> body
  end

  defp read_input(input_path) do
    case File.read(input_path) do
      {:ok, text} ->
        {:ok, text}

      {:error, reason} ->
        Log.error("could not read #{input_path}: #{:file.format_error(reason)}")
        {:error, :halt}
    end
  end

  defp parse_input(text) do
    {:ok, Trf.parse(text)}
  rescue
    e in Trf.ValidationError ->
      Log.error("invalid TRF file: #{Exception.message(e)}")
      {:error, :halt}
  end

  defp report_roster(parsed) do
    round_count = parsed.players |> Enum.map(&length(&1.games)) |> Enum.max(fn -> 0 end)

    Log.detail("#{length(parsed.players)} players, #{length(parsed.teams)} teams")
    Log.detail("#{round_count} round(s) of history in the file")

    for p <- parsed.players do
      Log.detail("##{p.rank} #{p.name} (#{format_rating(p.fide_rating)}) — #{p.points} pts")
    end

    round_count
  end

  defp format_rating(0), do: "unrated"
  defp format_rating(rating), do: "#{rating}"

  defp not_implemented(mode) do
    Log.error("#{mode} is not implemented yet — see TODO.md")
    2
  end

  defp usage_error(message) do
    Log.error(message)
    print_help()
    1
  end

  defp print_help_and_ok do
    print_help()
    0
  end

  defp print_version_and_ok do
    print_version()
    0
  end

  defp print_help do
    IO.puts("""
    openpair — a FIDE Dutch-system Swiss pairing engine

    Usage:
      openpair <input.trf> -p [<output.trf>]   Pair the next round (writes to
                                                stdout if <output.trf> is omitted)
      openpair <input.trf> -g                  Random Tournament Generator (not yet implemented)
      openpair <input.trf> -c                  Pairings Checker (not yet implemented)

    Options:
      -q, --quiet    Suppress the step-by-step trace (verbose is the default)
      -h, --help     Show this help
          --version  Show the version number
    """)
  end

  defp print_version do
    case Application.spec(:open_pair, :vsn) do
      nil -> IO.puts("unknown")
      vsn -> IO.puts(List.to_string(vsn))
    end
  end
end
