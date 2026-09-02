defmodule Ainalrami.GacruxTimeoutTest do
  @moduledoc """
  Sweep 2026-09-01, L4. `GACRUX_TIMEOUT` is the one value the three-way
  harness splices into its `sh -c` string; everything else in that call goes
  through `"$0" "$@"`.
  """
  use ExUnit.Case, async: false

  alias Ainalrami.Test.Gacrux

  setup do
    previous = System.get_env("GACRUX_TIMEOUT")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("GACRUX_TIMEOUT")
        value -> System.put_env("GACRUX_TIMEOUT", value)
      end
    end)

    :ok
  end

  test "the default is the documented 180 seconds, as an integer" do
    System.delete_env("GACRUX_TIMEOUT")
    assert Gacrux.timeout_seconds() == 180
  end

  test "a whole number is accepted" do
    System.put_env("GACRUX_TIMEOUT", "600")
    assert Gacrux.timeout_seconds() == 600
  end

  test "anything that is not a positive whole number is refused" do
    for bad <- ["3m", "0", "-5", "180; rm -rf /", "", "1.5"] do
      System.put_env("GACRUX_TIMEOUT", bad)

      assert_raise ArgumentError, ~r/GACRUX_TIMEOUT/, fn -> Gacrux.timeout_seconds() end
    end
  end
end
