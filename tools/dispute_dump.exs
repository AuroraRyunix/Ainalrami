# Decodes the FE1 dispute position into something readable, and states which
# players are eligible for the pairing-allocated bye and why.
#
#   mix run tools/dispute_dump.exs

path = "test/fixtures/fe1_disputes/seed735265-r7-p10.trf"
%{players: players, tournament: t} = OpenPair.Trf.parse(File.read!(path))

played =
  players
  |> Enum.map(fn p ->
    p.games
    |> Enum.with_index(1)
    |> Enum.filter(fn {g, _} -> not is_nil(g.opponent_rank) or g.result in ["U", "+"] end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.max(fn -> 0 end)
  end)
  |> Enum.max()

IO.puts("rounds played: #{played}, tournament length: #{inspect(t[:number_of_rounds])}\n")

active = Enum.filter(players, &(length(&1.games) <= played))

IO.puts(
  String.pad_trailing("SR", 4) <>
    String.pad_trailing("pts", 6) <>
    String.pad_trailing("active", 8) <>
    String.pad_trailing("bye-eligible", 14) <> "history"
)

for p <- Enum.sort_by(players, & &1.rank) do
  history =
    p.games
    |> Enum.map(fn g ->
      case g.opponent_rank do
        nil -> "  --#{g.result}"
        opp -> String.pad_leading("#{opp}#{g.colour}#{g.result}", 5)
      end
    end)
    |> Enum.join(" ")

  disqualifying = Enum.filter(p.games, &(&1.result in ~w(U F +)))
  eligible? = disqualifying == []

  why =
    if eligible?,
      do: "yes",
      else: "NO (#{Enum.map_join(disqualifying, ",", & &1.result)})"

  IO.puts(
    String.pad_trailing("#{p.rank}", 4) <>
      String.pad_trailing("#{p.points}", 6) <>
      String.pad_trailing(if(p in active, do: "yes", else: "-"), 8) <>
      String.pad_trailing(if(p in active, do: why, else: "-"), 14) <> history
  )
end

IO.puts("\nactive: #{Enum.map_join(Enum.sort_by(active, & &1.rank), ", ", &"#{&1.rank}(#{&1.points})")}")

eligible =
  active |> Enum.reject(fn p -> Enum.any?(p.games, &(&1.result in ~w(U F +))) end)

IO.puts("bye-eligible among them: #{Enum.map_join(eligible, ", ", &"#{&1.rank}")}")

IO.puts("\nOpenPair:    #{inspect(OpenPair.Pairing.pair_next_round(players, expected_rounds: 9))}")
IO.puts("bbpPairings: [{7, 5}, {8, 1}, {2, 9}, {3, nil}]   (run directly, exit 0)")
