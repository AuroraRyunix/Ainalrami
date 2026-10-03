defmodule Ainalrami.BergerTest do
  use ExUnit.Case, async: true

  alias Ainalrami.Berger

  # FIDE Competition Rules, C.05 Annex 1, as printed.
  @tables %{
    4 => [
      [{1, 4}, {2, 3}],
      [{4, 3}, {1, 2}],
      [{2, 4}, {3, 1}]
    ],
    6 => [
      [{1, 6}, {2, 5}, {3, 4}],
      [{6, 4}, {5, 3}, {1, 2}],
      [{2, 6}, {3, 1}, {4, 5}],
      [{6, 5}, {1, 4}, {2, 3}],
      [{3, 6}, {4, 2}, {5, 1}]
    ],
    8 => [
      [{1, 8}, {2, 7}, {3, 6}, {4, 5}],
      [{8, 5}, {6, 4}, {7, 3}, {1, 2}],
      [{2, 8}, {3, 1}, {4, 7}, {5, 6}],
      [{8, 6}, {7, 5}, {1, 4}, {2, 3}],
      [{3, 8}, {4, 2}, {5, 1}, {6, 7}],
      [{8, 7}, {1, 6}, {2, 5}, {3, 4}],
      [{4, 8}, {5, 3}, {6, 2}, {7, 1}]
    ]
  }

  for {n, table} <- @tables, {expected, r} <- Enum.with_index(table, 1) do
    test "#{n} participants, round #{r}" do
      {:ok, pairs, nil} = Berger.round(unquote(n), 1, unquote(r))
      assert Enum.sort(pairs) == Enum.sort(unquote(Macro.escape(expected)))
    end
  end

  test "an odd field plays the next even table, the dummy's opponent free" do
    for r <- 1..5 do
      {:ok, six, nil} = Berger.round(6, 1, r)
      {:ok, five, free} = Berger.round(5, 1, r)
      [{w, b}] = Enum.filter(six, fn {w, b} -> w == 6 or b == 6 end)
      assert free == if(w == 6, do: b, else: w)
      assert Enum.sort(five) == Enum.sort(six -- [{w, b}])
    end
  end

  test "a second cycle repeats the table with the colours reversed" do
    for r <- 1..5 do
      {:ok, first, _} = Berger.round(6, 2, r)
      {:ok, second, _} = Berger.round(6, 2, r + 5)
      assert Enum.sort(second) == Enum.sort(Enum.map(first, fn {w, b} -> {b, w} end))
    end

    assert Berger.total_rounds(6, 2) == 10
    assert Berger.round(6, 2, 11) == {:error, {:all_rounds_paired, 10}}
    assert Berger.total_rounds(5, 1) == 5
  end
end
