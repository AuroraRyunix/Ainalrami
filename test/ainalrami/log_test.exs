defmodule Ainalrami.LogTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  alias Ainalrami.Log

  setup do
    on_exit(fn -> Log.set_quiet(false) end)
  end

  test "step/1 and detail/1 print to stdout by default" do
    out =
      capture_io(fn ->
        Log.step("Loading input.trf")
        Log.detail("12 players, 3 rounds")
      end)

    assert out =~ "==> Loading input.trf"
    assert out =~ "12 players, 3 rounds"
  end

  test "step/1 and detail/1 are silent once quiet mode is set" do
    Log.set_quiet(true)

    out =
      capture_io(fn ->
        Log.step("Loading input.trf")
        Log.detail("12 players, 3 rounds")
      end)

    assert out == ""
  end

  test "warn/1 and error/1 are never silenced, even in quiet mode" do
    Log.set_quiet(true)

    out =
      capture_io(:stderr, fn ->
        Log.warn("something looks off")
        Log.error("something is wrong")
      end)

    assert out =~ "warning: something looks off"
    assert out =~ "error: something is wrong"
  end
end
