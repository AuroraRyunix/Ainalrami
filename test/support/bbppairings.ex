defmodule Ainalrami.Test.Bbppairings do
  @moduledoc """
  Thin wrapper for invoking the real `bbpPairings.exe` (Bierema Boyz
  Programming's independent, Apache-2.0-licensed Dutch-system
  implementation) locally, purely for comparison-testing Ainalrami's own
  pairing output against it - the second, genuinely independent reference
  this project has always meant to check against (see docs/engineering-log.md's
  "Cross-validation against bbpPairings"), as opposed to the earlier use
  of its SOURCE to port `Ainalrami.WeightedMatching`.

  NOT vendored into this repo, same reasoning as `Ainalrami.Test.Javafo`:
  it's a third-party binary not ours to redistribute here. Located via
  `BBPPAIRINGS_EXE`, defaulting to the sibling OpenPairings project's own
  vendored copy (`../openpairings/priv/bbppairings/bbpPairings-windows.exe`
  - same sibling-checkout convention `Ainalrami.Test.Javafo` already uses).

  ## Output format

  Confirmed by direct invocation, not assumed: `-p`'s output file is
  byte-identical in shape to javafo's own (`count\\r\\n` then one
  `white black\\r\\n` per pair, `0` for a pairing-allocated bye) - so
  `parse_output/1` is the same logic as `Ainalrami.Test.Javafo`'s.

  ## No-valid-pairing behaviour differs from javafo

  javafo emits an EMPTY pairs file (exit 0) when no legal pairing exists.
  bbpPairings instead exits with code 1 and writes NOTHING, per its own
  documented error codes ("1: ... no valid pairing exists for the current
  round"). `pair/1` surfaces this as `{:no_valid_pairing, message}`,
  distinct from `{:error, {code, out}}` (an unexpected failure) - this is
  also the exact case `Ainalrami.Pairing.NoValidPairingError` exists for;
  confirmed by direct comparison that both engines refuse the identical
  input.
  """

  def exe_path do
    System.get_env(
      "BBPPAIRINGS_EXE",
      "../openpairings/priv/bbppairings/bbpPairings-windows.exe"
    )
  end

  def available?, do: File.exists?(exe_path())

  @doc """
  Runs bbpPairings' pairing mode (`--dutch input-file -p output-file`) on
  `trf_text` and returns:

    * `{:ok, pairs}` - `[{white_rank, black_rank | nil}]`, same convention
      `Ainalrami.Test.Javafo.pair/1` and `Ainalrami.Pairing` both use
    * `{:no_valid_pairing, message}` - exit code 1, the players cannot be
      simultaneously paired while satisfying the absolute criteria
    * `{:error, {code, output}}` - anything else (a malformed TRF, a
      process failure)
  """
  def pair(trf_text) do
    dir = Path.join(System.tmp_dir!(), "ainalrami-bbp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    input = Path.join(dir, "input.trf")
    output = Path.join(dir, "output.txt")

    try do
      File.write!(input, trf_text)

      case System.cmd(exe_path(), ["--dutch", input, "-p", output], stderr_to_stdout: true) do
        {_out, 0} -> {:ok, output |> File.read!() |> parse_output()}
        {out, 1} -> {:no_valid_pairing, out}
        {out, code} -> {:error, {code, out}}
      end
    after
      remove_dir(dir)
    end
  end

  # See `Ainalrami.Test.Javafo`'s identical helper for why this retries
  # instead of a plain `File.rm_rf!/1` - same Windows transient-handle
  # cause, same fix.
  defp remove_dir(dir, attempts_left \\ 5)

  defp remove_dir(_dir, 0), do: :ok

  defp remove_dir(dir, attempts_left) do
    case File.rm_rf(dir) do
      {:ok, _} ->
        :ok

      {:error, _reason, _path} ->
        Process.sleep(20)
        remove_dir(dir, attempts_left - 1)
    end
  end

  defp parse_output(text) do
    [_count | lines] = text |> String.split(~r/\r?\n/) |> Enum.reject(&(String.trim(&1) == ""))

    Enum.map(lines, fn line ->
      [w, b] = line |> String.trim() |> String.split(~r/\s+/)
      white = String.to_integer(w)
      black = String.to_integer(b)
      {white, if(black == 0, do: nil, else: black)}
    end)
  end
end
