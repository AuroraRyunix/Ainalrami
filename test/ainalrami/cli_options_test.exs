defmodule Ainalrami.CliOptionsTest do
  @moduledoc """
  The CLI refuses what it does not understand.

  It used to accept it silently, which produced three commands that appear to
  work and do the wrong thing:

    * `--player=30` (singular) ran with a RANDOM roster size;
    * `--initial-colour=x` quietly picked White;
    * `ainalrami -g out.trf --seed 42` - a space instead of an equals sign -
      wrote the file and ignored the seed.

  The last is the worst. The generator's whole argument for existing is that a
  run is reproducible from its seed, and that command produces a tournament
  that can never be produced again while saying nothing.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Ainalrami.CLI, as: Cli

  # Both streams: the complaint goes to stderr (`Log.error/1`) and the usage
  # text to stdout, and a test that read only one of them would pass on an
  # exit code while proving nothing about what the user was told.
  defp run(argv) do
    help =
      capture_io(fn ->
        complaint = capture_io(:stderr, fn -> send(self(), {:code, Cli.run(argv)}) end)
        send(self(), {:stderr, complaint})
      end)

    assert_received {:code, code}
    assert_received {:stderr, complaint}

    {code, complaint <> help}
  end

  describe "flags it does not have" do
    test "a misspelt valued option is named back" do
      {code, output} = run(["-g", "--player=30"])

      assert code == 1
      # Named, because the mistake is almost always a plural or a spelling and
      # "unknown option" alone leaves somebody re-reading their own command.
      assert output =~ "--player"
    end

    test "a bare one too" do
      {code, output} = run(["-g", "--verbose"])

      assert code == 1
      assert output =~ "verbose"
    end

    test "and the complaint comes before --help would have swallowed it" do
      # Otherwise a typo alongside --help prints usage and exits 0, which
      # looks exactly like the help somebody asked for.
      {code, _output} = run(["--help", "--player=30"])

      assert code == 1
    end
  end

  describe "a value written with a space" do
    test "is refused, and says why" do
      {code, output} = run(["-g", "out.trf", "--seed", "42"])

      assert code == 1
      assert output =~ "equals sign"
      # The shell has already split it, so the value is sitting in the
      # positional arguments looking like a file name. Worth saying.
      assert output =~ "file name"
    end

    test "for every valued option, not just the seed" do
      for flag <- ~w(--players --rounds --forfeit-pct --acceleration --initial-colour) do
        {code, _} = run(["-g", flag, "8"])
        assert code == 1, "#{flag} with a space was accepted"
      end
    end
  end

  describe "values it cannot use" do
    test "a seed that is not a number" do
      # Silently defaulting is the same unreproducible run as the space was.
      {code, output} = run(["-g", "--seed=fourty2"])

      assert code == 1
      assert output =~ "whole number"
    end

    test "an acceleration this program does not implement" do
      {code, output} = run(["-g", "--acceleration=bakku"])

      assert code == 1
      assert output =~ "baku or random"
    end

    test "a colour that is neither" do
      {code, output} = run(["-g", "--initial-colour=x"])

      assert code == 1
      assert output =~ "white/w or black/b"
    end
  end

  describe "what still works" do
    test "the bare flags" do
      assert {0, _} = run(["--help"])
      assert {0, _} = run(["--version"])
    end

    test "both spellings of the colour option, and both its values" do
      # American and British, white and black - all four were accepted before
      # and must stay accepted.
      for flag <- ~w(--initial-colour --initial-color), value <- ~w(w white b black) do
        {code, _} = run(["-g", "--rounds=1", "--players=4", "#{flag}=#{value}"])
        assert code == 0, "#{flag}=#{value} was refused"
      end
    end
  end
end
