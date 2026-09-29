defmodule Ainalrami.CLIByePreferencesTest do
  @moduledoc """
  The CLI's bye preference flags (`--bye-want`, `--bye-want-soft`,
  `--bye-avoid`, `--bye-avoid-soft`): they reach the engine, the departure
  from FIDE is announced on stderr, what each did is reported, and a
  malformed or misplaced one is refused rather than dropped.
  """

  use ExUnit.Case
  import ExUnit.CaptureIO

  alias Ainalrami.{CLI, Log, Trf}

  setup do
    on_exit(fn -> Log.set_quiet(false) end)
  end

  @warning "not a pure FIDE pairing"

  test "without a flag: no warning, the FIDE pairing" do
    {stdout, stderr, code} = run([round_two_trf(), "-p"])
    assert code == 0
    refute stderr =~ @warning
    assert bye(stdout) == 5
  end

  test "--bye-want gives the player the bye and warns on stderr" do
    {stdout, stderr, code} = run([round_two_trf(), "-p", "--bye-want=4"])
    assert code == 0
    assert stderr =~ @warning
    assert stderr =~ "the bye preferences changed this round: without them the bye goes to #5"
    assert stdout =~ "#4 (must get the bye): receives the pairing-allocated bye"
    assert bye(stdout) == 4
  end

  test "--bye-want-soft and --bye-avoid-soft stay on the bye score" do
    {stdout, stderr, 0} = run([round_two_trf(), "-p", "--bye-want-soft=1"])
    assert bye(stdout) == 5
    assert stderr =~ "#1 (rather gets the bye): not applied"

    {stdout, _stderr, 0} = run([round_two_trf(), "-p", "--bye-avoid-soft=5"])
    assert bye(stdout) == 4
  end

  test "--bye-avoid is the bye exclusion" do
    {stdout, stderr, 0} = run([round_two_trf(), "-p", "--bye-avoid=5"])
    assert bye(stdout) == 4
    assert stderr =~ @warning
  end

  test "rounds after @: a setting for another round changes nothing, but still warns" do
    {stdout, stderr, 0} = run([round_two_trf(), "-p", "--bye-want=4@3-5+7"])
    assert bye(stdout) == 5
    assert stderr =~ @warning

    {stdout, _stderr, 0} = run([round_two_trf(), "-p", "--bye-want=1,4@2"])
    assert bye(stdout) == 4, "two hard wants, and C5 picks the lower score"
  end

  test "a conflict is reported" do
    {stdout, stderr, 0} = run([round_two_trf(), "-p", "--bye-want=4", "--bye-avoid=4"])
    assert bye(stdout) == 5

    assert stderr =~
             "#4 (must get the bye): not applied: the same player is also set to must not get the bye"
  end

  test "-x explains the round it paired, preferences resolved" do
    {stdout, stderr, 0} = run([round_two_trf(), "-x", "--bye-want-soft=4"])
    assert stderr =~ @warning
    assert stdout =~ "Round 2"
  end

  test "malformed values and the wrong modes are refused" do
    for bad <- ["--bye-want=x", "--bye-want=4@", "--bye-want=4@3-2", "--bye-avoid-soft=0"] do
      {_stdout, stderr, code} = run([round_two_trf(), "-p", bad])
      assert code == 1, bad
      assert stderr =~ "takes starting ranks", bad
    end

    {_stdout, stderr, 1} = run([round_two_trf(), "-c", "--bye-want=4"])
    assert stderr =~ "apply to -p and -x only"

    {_stdout, stderr, 1} = run(["-g", "--bye-avoid=2"])
    assert stderr =~ "apply to -p and -x only"
  end

  test "the help lists them" do
    {stdout, _stderr, 0} = run(["--help"])

    for flag <- ~w(--bye-want= --bye-want-soft= --bye-avoid= --bye-avoid-soft=) do
      assert stdout =~ flag
    end
  end

  # Five players after round one: 1 beat 4, 2 beat 5, 3 had the bye.
  defp round_two_trf do
    game = fn opp, colour, result -> %{opponent_rank: opp, colour: colour, result: result} end

    text =
      Trf.serialize(%{
        tournament: %{name: "Bye Preference Open", type: "swiss"},
        players: [
          %{rank: 1, name: "A", fide_rating: 2400, points: 1.0, games: [game.(4, "w", "1")]},
          %{rank: 2, name: "B", fide_rating: 2300, points: 1.0, games: [game.(5, "b", "1")]},
          %{rank: 3, name: "C", fide_rating: 2200, points: 1.0, games: [game.(nil, nil, "U")]},
          %{rank: 4, name: "D", fide_rating: 2100, points: 0.0, games: [game.(1, "b", "0")]},
          %{rank: 5, name: "E", fide_rating: 2000, points: 0.0, games: [game.(2, "w", "0")]}
        ]
      }) <> "XXR 5\n"

    path =
      Path.join(System.tmp_dir!(), "ainalrami_byepref_#{System.unique_integer([:positive])}.trf")

    File.write!(path, text)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp run(argv) do
    ref = make_ref()

    stdout =
      capture_io(fn ->
        stderr = capture_io(:stderr, fn -> Process.put(ref, CLI.run(argv)) end)
        Process.put({ref, :stderr}, stderr)
      end)

    {stdout, Process.get({ref, :stderr}), Process.get(ref)}
  end

  # The board list's bye line, "N 0".
  defp bye(stdout) do
    Enum.find_value(String.split(stdout, ~r/\r?\n/), fn line ->
      case Regex.run(~r/^(\d+) 0$/, line) do
        [_, rank] -> String.to_integer(rank)
        _ -> nil
      end
    end)
  end
end
