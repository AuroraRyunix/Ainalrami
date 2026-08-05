defmodule OpenPair.CLITest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  alias OpenPair.{CLI, Log, Trf}

  setup do
    on_exit(fn -> Log.set_quiet(false) end)
  end

  defp write_trf!(text) do
    path =
      Path.join(System.tmp_dir!(), "open_pair_cli_test_#{System.unique_integer([:positive])}.trf")

    File.write!(path, text)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # Built via Trf.serialize/1 rather than hand-typed fixed-width text — a
  # manually counted column offset is exactly the kind of mistake that's
  # bitten this TRF parser before (see the sibling project's own history).
  defp sample_trf do
    Trf.serialize(%{
      tournament: %{name: "CLI Test Open", type: "swiss"},
      players: [
        %{rank: 1, name: "A", fide_rating: 2000, points: 1.0, games: []},
        %{rank: 2, name: "B", fide_rating: 1900, points: 0.0, games: []}
      ]
    })
  end

  # Same roster, but round 1 has both players claiming a win — illegal per
  # `Trf`'s own result-pair validation. `Trf.serialize/1` would reject this
  # outright, so it's built by serializing a *legal* round then flipping one
  # result character afterward, the same technique the sibling project's own
  # `trf_test.exs` uses for this exact kind of fixture.
  defp illegal_result_trf do
    text =
      Trf.serialize(%{
        tournament: %{name: "Bad File", type: "swiss"},
        players: [
          %{
            rank: 1,
            name: "A",
            points: 0.0,
            games: [%{opponent_rank: 2, colour: "w", result: "1"}]
          },
          %{
            rank: 2,
            name: "B",
            points: 0.0,
            games: [%{opponent_rank: 1, colour: "b", result: "0"}]
          }
        ]
      })

    # Round 1's result column is 99 (base 92 + 7) — flip B's loss into a
    # second win.
    lines = String.split(text, "\r\n")
    p2 = Enum.find(lines, &(String.starts_with?(&1, "001") and &1 =~ "B"))
    {before, rest} = String.split_at(p2, 98)
    <<_::binary-size(1), after_::binary>> = rest
    bad_p2 = before <> "1" <> after_

    lines |> Enum.map(&if &1 == p2, do: bad_p2, else: &1) |> Enum.join("\r\n")
  end

  test "-h prints help and exits 0" do
    out = capture_io(fn -> assert CLI.run(["-h"]) == 0 end)
    assert out =~ "openpair — a FIDE Dutch-system Swiss pairing engine"
  end

  test "--version prints something and exits 0" do
    out = capture_io(fn -> assert CLI.run(["--version"]) == 0 end)
    assert String.trim(out) != ""
  end

  test "missing input file exits 1 with a usage message" do
    {out, code} = run_capturing(fn -> CLI.run(["-p"]) end)

    assert code == 1
    assert out =~ "missing input TRF file"
  end

  test "missing mode flag exits 1" do
    path = write_trf!(sample_trf())

    {out, code} = run_capturing(fn -> CLI.run([path]) end)

    assert code == 1
    assert out =~ "missing mode flag"
  end

  test "-p on a real TRF file loads and reports the roster, then exits 2 (not implemented)" do
    path = write_trf!(sample_trf())

    {out, code} = run_capturing(fn -> CLI.run([path, "-p"]) end)

    assert code == 2
    assert out =~ "Loading #{path}"
    assert out =~ "2 players, 0 teams"
    assert out =~ "#1 A"
    assert out =~ "#2 B"
  end

  test "-p reports the intended output file when one is given" do
    path = write_trf!(sample_trf())

    {out, _code} = run_capturing(fn -> CLI.run([path, "-p", "out.trf"]) end)

    assert out =~ "would have written to out.trf"
  end

  test "-p on a missing file exits 1 with a clear error" do
    {out, code} = run_capturing(fn -> CLI.run(["does-not-exist.trf", "-p"]) end)

    assert code == 1
    assert out =~ "could not read"
  end

  test "-p on an invalid TRF file exits 1 with the validation error" do
    path = write_trf!(illegal_result_trf())

    {out, code} = run_capturing(fn -> CLI.run([path, "-p"]) end)

    assert code == 1
    assert out =~ "invalid TRF file"
  end

  test "-g and -c are recognized but report not-yet-implemented, exit 2" do
    path = write_trf!(sample_trf())

    {out_g, code_g} = run_capturing(fn -> CLI.run([path, "-g"]) end)
    {out_c, code_c} = run_capturing(fn -> CLI.run([path, "-c"]) end)

    assert code_g == 2
    assert out_g =~ "Random Tournament Generator"
    assert out_g =~ "not implemented yet"

    assert code_c == 2
    assert out_c =~ "Pairings Checker"
    assert out_c =~ "not implemented yet"
  end

  test "-q suppresses the step/detail trace but not the not-implemented error" do
    path = write_trf!(sample_trf())

    {out, code} = run_capturing(fn -> CLI.run([path, "-p", "-q"]) end)

    assert code == 2
    refute out =~ "Loading"
    refute out =~ "players,"
    assert out =~ "not implemented yet"
  end

  # OpenPair.Log writes step/detail to stdout and warn/error to stderr —
  # interleaving order doesn't matter for these assertions, so this just
  # concatenates both streams into one string, plus returns the CLI's own
  # return value (the would-be exit code).
  defp run_capturing(fun) do
    ref = make_ref()
    Process.put(ref, nil)

    stdout =
      capture_io(fn ->
        stderr = capture_io(:stderr, fn -> Process.put(ref, fun.()) end)
        IO.write(stderr)
      end)

    {stdout, Process.get(ref)}
  end
end
