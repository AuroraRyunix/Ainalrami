defmodule Ainalrami.Test.Javafo do
  @moduledoc """
  Thin wrapper for invoking the real `javafo.jar` (FIDE's own reference
  Dutch-system implementation) locally, purely for comparison-testing
  Ainalrami's own pairing output against it. NOT vendored into this repo -
  it's a third-party binary not ours to redistribute (same reasoning as the
  sibling project OpenPairings' own `test_helper.exs`) - located via
  `JAVAFO_JAR`, defaulting to that sibling project's own vendored copy
  (`../openpairings/priv/javafo/javafo.jar`, i.e. this repo and
  `openpairings` checked out as sibling directories).
  """

  def jar_path do
    System.get_env("JAVAFO_JAR", "../openpairings/priv/javafo/javafo.jar")
  end

  def available?, do: File.exists?(jar_path())

  @doc """
  Runs javafo.jar's pairing mode (`-p`) on `trf_text` (a full TRF file,
  including any `XXR`/`XXA`/`XXP` extension lines the caller wants) and
  returns `{:ok, pairs}` where each pair is `{white_rank, black_rank | nil}`
  - `nil` for a pairing-allocated bye (javafo's own `0`), same convention
  `Ainalrami.Pairing` uses.
  """
  def pair(trf_text) do
    dir = Path.join(System.tmp_dir!(), "ainalrami-javafo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    input = Path.join(dir, "input.trf")
    output = Path.join(dir, "output.txt")

    try do
      File.write!(input, trf_text)

      case System.cmd("java", ["-jar", jar_path(), input, "-p", output], stderr_to_stdout: true) do
        {_out, 0} -> {:ok, output |> File.read!() |> parse_output()}
        {out, code} -> {:error, {code, out}}
      end
    after
      remove_dir(dir)
    end
  end

  # Plain File.rm_rf!/1 raises "file already exists" under Windows when many
  # of these run concurrently (confirmed at real scale, PAIRING_FUZZ_COUNT
  # in the tens of thousands: an antivirus/indexer transiently holding a
  # handle on a just-closed file is the likely cause, not a bug in the
  # directory-naming scheme - `System.unique_integer/1` already guarantees
  # each run gets its own dir). A failed cleanup only leaks a few KB of temp
  # files, so it's worth a couple of retries but never worth crashing the
  # whole comparison run over.
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
