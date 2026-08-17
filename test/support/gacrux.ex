defmodule Ainalrami.Test.Gacrux do
  @moduledoc """
  Thin wrapper for invoking Otto Milvang's `pairingchecker.py` (the pairing
  half of the FIDE Tie Break Server, gacrux.no) locally — the THIRD
  independent Dutch implementation this project compares against, after
  `Ainalrami.Test.Javafo` and `Ainalrami.Test.Bbppairings`.

  Worth having for two reasons the other two cannot cover.

  It implements a NEWER rulebook. `pairingdutch.py` carries

      DUTCH_RULES = { 0: "2022-01-01",
                      1: "2026-02-01" }  # Approved by FIDE Council on 01/02/2026

  and selects the 2026 one. bbpPairings 6.0.0 also implements the revised
  rules ("the 2025 rules ... effective date delayed to 2026"), but JaVaFo
  2.2 predates them, so without this there is no way to tell a genuine
  disagreement from a rulebook difference.

  And it breaks ties. Most of this engine's remaining disagreements are
  cases where several pairings satisfy every documented criterion equally
  and the reference simply picked one; with two references a tie is a
  coin-toss between them, with three it is a majority.

  NOT vendored, same reasoning as the other two — third-party source that
  is not ours to redistribute. Located via `GACRUX_DIR`, defaulting to a
  sibling checkout of <https://github.com/OttoMilvang/TieBreakServer>.
  Its only dependency is `networkx`.

  ## Output format

  Confirmed by direct invocation, not assumed: `-p -dT` writes the same
  shape javafo and bbpPairings do — a count line, then one `white black`
  per pair, `0` for a pairing-allocated bye — so `parse_output/1` is the
  same logic as theirs.
  """

  def dir_path, do: System.get_env("GACRUX_DIR", "../TieBreakServer")

  def script_path, do: Path.join(dir_path(), "pairingchecker.py")

  def python_bin, do: System.get_env("GACRUX_PYTHON", "python")

  def available?, do: File.exists?(script_path())

  @doc """
  Runs the pairing mode (`-p -dT -m dutch`) on `trf_text` and returns:

    * `{:ok, pairs}` — `[{white_rank, black_rank | nil}]`, the same
      convention the other two wrappers and `Ainalrami.Pairing` all use
    * `{:no_valid_pairing, output}` — it produced no pairs at all, which
      is how it reports a round with no legal completion
    * `{:error, {code, output}}` — anything else
  """
  def pair(trf_text) do
    dir = Path.join(System.tmp_dir!(), "ainalrami-gacrux-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    input = Path.join(dir, "input.trf")
    output = Path.join(dir, "output.txt")

    try do
      File.write!(input, trf_text)

      args = [script_path(), "-i", input, "-o", output, "-p", "-dT", "-m", "dutch"]

      case System.cmd(python_bin(), args, stderr_to_stdout: true) do
        {out, 0} ->
          case File.read(output) do
            {:ok, text} -> classify(parse_output(text), out)
            {:error, _} -> {:no_valid_pairing, out}
          end

        {out, code} ->
          {:error, {code, out}}
      end
    after
      remove_dir(dir)
    end
  end

  defp classify([], out), do: {:no_valid_pairing, out}
  defp classify(pairs, _out), do: {:ok, pairs}

  # See `Ainalrami.Test.Javafo`'s identical helper for why this retries
  # instead of a plain `File.rm_rf!/1` — same Windows transient-handle
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
    case text |> String.split(~r/\r?\n/) |> Enum.reject(&(String.trim(&1) == "")) do
      [] ->
        []

      [_count | lines] ->
        Enum.map(lines, fn line ->
          [w, b] = line |> String.trim() |> String.split(~r/\s+/)
          white = String.to_integer(w)
          black = String.to_integer(b)
          {white, if(black == 0, do: nil, else: black)}
        end)
    end
  end
end
