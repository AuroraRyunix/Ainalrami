defmodule Ainalrami.CheckFutureByeTest do
  # `-c` and `-s` on a file that holds a bye for a round nobody has paired
  # yet: a player who announced, ahead of time, that they will sit out the
  # next round. TRF26 writes it as a `240` record; the engines' spelling
  # writes the bye in the pending round's column. Either way the file's
  # places are the standings after the last PAIRED round, and the checker
  # used to rank by every column there was - the bye included - and report
  # that three of six places "do not follow" the file's own tie-breaks.
  #
  # The fixtures: six players, two rounds played, round 3 to pair, player 6
  # (no points) holding a full-point bye for round 3. Written by
  # `Ainalrami.Trf.serialize/2` in both dialects.
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Ainalrami.{CLI, Log}

  @dir Path.expand("../fixtures/future_bye", __DIR__)

  setup do
    on_exit(fn -> Log.set_quiet(false) end)
  end

  defp cli(args) do
    ref = make_ref()

    out =
      capture_io(fn ->
        capture_io(:stderr, fn -> Process.put(ref, CLI.run(args)) end) |> IO.write()
      end)

    {out, Process.get(ref)}
  end

  defp fixture(dialect), do: Path.join(@dir, "announced-full-bye-#{dialect}.trf")

  # The TRF26 fixture with its `240` changed to another kind of bye.
  defp with_bye(type) do
    text = File.read!(fixture(:trf26))
    assert text =~ "240 F 003    6"

    path =
      Path.join(
        System.tmp_dir!(),
        "ainalrami_future_bye_#{type}_#{System.unique_integer([:positive])}.trf"
      )

    File.write!(path, String.replace(text, "240 F 003    6", "240 #{type} 003    6"))
    on_exit(fn -> File.rm(path) end)
    path
  end

  for dialect <- [:trf26, :engine] do
    test "-c: the rounds match and the places follow (#{dialect})" do
      {out, code} = cli([fixture(unquote(dialect)), "-c"])

      assert out =~ "Checking 2 round(s)"
      assert out =~ "2/2 round(s) match"
      refute out =~ "do not follow"
      assert code == 0, out
    end

    test "-s: the standings are the ones after round 2 (#{dialect})" do
      {out, 0} = cli([fixture(unquote(dialect)), "-s", "-q"])

      ranked =
        out
        |> String.split(["\r\n", "\n"], trim: true)
        |> Enum.drop(1)
        |> Enum.map(fn line -> line |> String.split() |> Enum.take(2) end)

      # Player 6 lost both games: last, with nothing, not a point up.
      assert List.last(ranked) == ["6", "6"]
      assert Enum.map(ranked, &List.last/1) == ~w(1 3 2 5 4 6)
    end
  end

  for type <- ~w(H Z) do
    test "-c with a #{type} bye announced for round 3" do
      {out, code} = cli([with_bye(unquote(type)), "-c"])
      refute out =~ "do not follow"
      assert code == 0, out
    end
  end
end
