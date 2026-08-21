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

  describe "levels" do
    test "defaults to :normal" do
      Application.delete_env(:ainalrami, :log_level)
      assert Log.level() == :normal
      refute Log.quiet?()
      refute Log.debug?()
    end

    test ":debug is a superset of :normal" do
      Log.set_level(:debug)

      out = capture_io(fn -> Log.step("s") end) <> capture_io(fn -> Log.detail("d") end)

      assert out =~ "==> s"
      assert out =~ "    d"
      assert capture_io(fn -> Log.debug("internals") end) =~ "[dbg] internals"
    end

    test "debug output is suppressed at :normal and :quiet" do
      for level <- [:normal, :quiet] do
        Log.set_level(level)
        assert capture_io(fn -> Log.debug("internals") end) == ""
      end
    end

    # The engine calls Log.debug/1 from inside the bracket loop, so the
    # message must not be BUILT unless it is going to be printed.
    test "the function form is not evaluated below :debug" do
      Log.set_level(:normal)
      me = self()

      capture_io(fn -> Log.debug(fn -> send(me, :evaluated) && "x" end) end)

      refute_received :evaluated

      Log.set_level(:debug)
      capture_io(fn -> Log.debug(fn -> send(me, :evaluated) && "x" end) end)
      assert_received :evaluated
    end

    test "set_quiet/1 still works, and false clears :debug" do
      Log.set_level(:debug)
      Log.set_quiet(false)

      assert Log.level() == :normal
      assert capture_io(fn -> Log.debug("internals") end) == ""

      Log.set_quiet(true)
      assert Log.quiet?()
    end
  end
end
