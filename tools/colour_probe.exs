# Finds concrete colour disagreements against bbpPairings and prints enough
# of each to say WHICH article decides it.
#
#   mix run tools/colour_probe.exs [count] [rounds]
#
# Article 5.2, in priority order:
#   5.2.1 grant both preferences
#   5.2.2 grant the stronger; if both absolute, the wider colour difference
#   5.2.3 alternate to the most recent round where one had White, other Black
#   5.2.4 grant the higher ranked player's preference
#   5.2.5 higher ranked player: odd TPN gets the initial colour, else opposite

args = System.argv()
count = args |> Enum.at(0, "40") |> String.to_integer()
rounds = args |> Enum.at(1, "8") |> String.to_integer()
exe = System.get_env("BBPPAIRINGS_EXE", "../openpairings/priv/bbppairings/bbpPairings-windows.exe")

defmodule Probe do
  def colours(p), do: p.games |> Enum.filter(&(&1.result in ~w(1 = 0))) |> Enum.map(& &1.colour)

  def cd(p) do
    c = colours(p)
    Enum.count(c, &(&1 == "w")) - Enum.count(c, &(&1 == "b"))
  end

  def preference(p) do
    c = colours(p)
    diff = cd(p)
    last2 = c |> Enum.reverse() |> Enum.take(2)

    cond do
      c == [] -> {nil, "none (never played)"}
      diff > 1 -> {"b", "ABSOLUTE (CD #{diff})"}
      diff < -1 -> {"w", "ABSOLUTE (CD #{diff})"}
      match?([x, x] when is_binary(x), last2) -> {invert(hd(last2)), "ABSOLUTE (same colour twice)"}
      diff == 1 -> {"b", "strong (CD +1)"}
      diff == -1 -> {"w", "strong (CD -1)"}
      true -> {invert(hd(last2)), "mild (CD 0)"}
    end
  end

  defp invert("w"), do: "b"
  defp invert("b"), do: "w"
  defp invert(_), do: nil

  # 5.2.3: walk both colour histories back in step, most recent first, and
  # report the first round where they differ.
  def most_recent_difference(a, b) do
    Enum.zip(Enum.reverse(colours(a)), Enum.reverse(colours(b)))
    |> Enum.find(fn {x, y} -> x != y end)
  end
end

results =
  Enum.flat_map(1..count, fn seed ->
    n = 4 + rem(seed * 13, 37)
    {text, _} = Ainalrami.Generator.generate(players: n, rounds: rounds - 1, seed: seed)
    %{players: players} = Ainalrami.Trf.parse(text)

    path = Path.join(System.tmp_dir!(), "cp_#{seed}.trf")
    out = Path.join(System.tmp_dir!(), "cp_#{seed}_out.txt")
    File.write!(path, text)

    case System.cmd(exe, ["--dutch", path, "-p", out], stderr_to_stdout: true) do
      {_, 0} ->
        theirs =
          out
          |> File.read!()
          |> String.split(~r/\r?\n/)
          |> Enum.reject(&(String.trim(&1) == ""))
          |> tl()
          |> Enum.map(fn l ->
            [w, b] = l |> String.trim() |> String.split(~r/\s+/)
            {String.to_integer(w), String.to_integer(b)}
          end)

        ours =
          try do
            Ainalrami.Pairing.pair_next_round(players, expected_rounds: rounds)
          rescue
            _ -> []
          end

        by_rank = Map.new(players, &{&1.rank, &1})
        theirs_set = MapSet.new(theirs)

        for {w, b} <- ours,
            b != nil,
            MapSet.member?(theirs_set, {b, w}),
            not MapSet.member?(theirs_set, {w, b}) do
          %{seed: seed, ours: {w, b}, a: Map.fetch!(by_rank, w), b: Map.fetch!(by_rank, b)}
        end

      _ ->
        []
    end
  end)

IO.puts("\n#{length(results)} colour disagreement(s) in #{count} positions\n")

results
|> Enum.take(8)
|> Enum.each(fn r ->
  {pa, wa} = Probe.preference(r.a)
  {pb, wb} = Probe.preference(r.b)
  {w, b} = r.ours

  IO.puts("seed #{r.seed}: we say #{w} White / #{b} Black; bbp says the reverse")
  IO.puts("  ##{r.a.rank}  colours=#{inspect(Probe.colours(r.a))}  prefers #{pa} — #{wa}")
  IO.puts("  ##{r.b.rank}  colours=#{inspect(Probe.colours(r.b))}  prefers #{pb} — #{wb}")

  decider =
    cond do
      pa != pb -> "5.2.1 (different preferences — both grantable)"
      wa != wb -> "5.2.2 (one preference is stronger)"
      Probe.most_recent_difference(r.a, r.b) -> "5.2.3 (histories differ at some round)"
      true -> "5.2.4 / 5.2.5 (identical histories)"
    end

  IO.puts("  most recent differing round: #{inspect(Probe.most_recent_difference(r.a, r.b))}")
  IO.puts("  article that should decide:  #{decider}\n")
end)
