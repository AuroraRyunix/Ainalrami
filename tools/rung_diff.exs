# Dumps explain_round/3's per-bracket rungs for two pairings of the same
# position, side by side, so a verdict can be checked rather than trusted.
#
#   mix run tools/rung_diff.exs test/fixtures/fe1_disputes/seed735265-r7-p10.trf

[path | _] = System.argv()
%{players: players} = OpenPair.Trf.parse(File.read!(path))

ours = OpenPair.Pairing.pair_next_round(players, expected_rounds: 9)
theirs = [{7, 5}, {8, 1}, {2, 9}, {3, nil}]

IO.puts("ours:   #{inspect(Enum.sort(ours))}")
IO.puts("theirs: #{inspect(Enum.sort(theirs))}\n")

o = OpenPair.Pairing.explain_round(players, ours, expected_rounds: 9)
t = OpenPair.Pairing.explain_round(players, theirs, expected_rounds: 9)

Enum.zip(o, t)
|> Enum.with_index()
|> Enum.each(fn {{ob, tb}, i} ->
  same_pairs? = Enum.sort(ob.pairs) == Enum.sort(tb.pairs)
  same_floats? = Enum.sort(ob.floats) == Enum.sort(tb.floats)

  IO.puts(
    "bracket #{i} (score #{ob.group})#{if same_pairs? and same_floats?, do: " — identical", else: ""}"
  )

  IO.puts("  ours   pairs=#{inspect(ob.pairs)} floats=#{inspect(ob.floats)}")
  IO.puts("  theirs pairs=#{inspect(tb.pairs)} floats=#{inspect(tb.floats)}")

  unless same_pairs? and same_floats? do
    Enum.zip(ob.rungs, tb.rungs)
    |> Enum.each(fn {{label, ov}, {_l, tv}} ->
      mark =
        cond do
          ov == tv -> "   "
          ov > tv -> " > "
          true -> " < "
        end

      if ov != tv do
        IO.puts("      #{String.pad_trailing(label, 32)} ours=#{ov}#{mark}theirs=#{tv}")
      end
    end)
  end

  IO.puts("")
end)
