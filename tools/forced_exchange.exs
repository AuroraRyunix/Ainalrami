# An adversarial position that FORCES Article 4.3 to decide.
#
# Exchanges are only reached when no transposition of the natural S1/S2 gives
# a usable candidate (3.6). A transposition can only ever re-order S2, so it
# can never pair two S1 members with each other. Therefore: build a bracket
# where every S1 x S2 pair is already illegal, and the only legal pairings are
# within the halves -- reachable exclusively through an exchange.
#
# Eight players, four rounds, arranged so:
#
#   * each of 1-4 has played each of 5-8, so all 16 cross pairs are rematches;
#   * nobody has played inside their own half, so those pairs are all legal;
#   * every player is on 2.0, so round 5 is one homogeneous bracket;
#   * colours alternate, so 1-4 all hold a mild preference for White and 5-8
#     for Black -- no ABSOLUTE clash (which would make pairs illegal rather
#     than merely imperfect), but any legal pairing must disregard exactly one
#     preference per pair.
#
# So all nine legal pairings (three ways to pair 1-4, times three for 5-8)
# tie on every criterion, and only the generation order of 4.3 separates them.
#
#   mix run tools/forced_exchange.exs

rounds = [
  # {white, black} per round -- 1-4 meet 5-8 in every combination
  [{1, 5}, {2, 6}, {3, 7}, {4, 8}],
  [{6, 1}, {5, 2}, {8, 3}, {7, 4}],
  [{1, 7}, {2, 8}, {3, 5}, {4, 6}],
  [{8, 1}, {7, 2}, {6, 3}, {5, 4}]
]

# Top half wins rounds 1-2, bottom half wins 3-4, so everyone lands on 2.0.
winners = fn
  round, {w, b} when round <= 2 -> if w <= 4, do: {w, b}, else: {b, w}
  _round, {w, b} -> if w <= 4, do: {b, w}, else: {w, b}
end

games =
  Enum.reduce(Enum.with_index(rounds, 1), %{}, fn {pairs, round}, acc ->
    Enum.reduce(pairs, acc, fn {white, black}, inner ->
      {winner, _loser} = winners.(round, {white, black})

      inner
      |> Map.update(
        white,
        [%{opponent_rank: black, colour: "w", result: if(winner == white, do: "1", else: "0")}],
        &(&1 ++ [%{opponent_rank: black, colour: "w", result: if(winner == white, do: "1", else: "0")}])
      )
      |> Map.update(
        black,
        [%{opponent_rank: white, colour: "b", result: if(winner == black, do: "1", else: "0")}],
        &(&1 ++ [%{opponent_rank: white, colour: "b", result: if(winner == black, do: "1", else: "0")}])
      )
    end)
  end)

players =
  for rank <- 1..8 do
    g = Map.fetch!(games, rank)

    %{
      rank: rank,
      name: "P#{rank}",
      sex: "",
      title: "",
      fide_rating: 2000 - rank,
      federation: "",
      fide_number: nil,
      birth_date: "",
      points: Enum.count(g, &(&1.result == "1")) * 1.0,
      games: g
    }
  end

IO.puts("scores: #{Enum.map_join(players, " ", &"#{&1.rank}=#{&1.points}")}")

met =
  for p <- players, into: %{} do
    {p.rank, p.games |> Enum.map(& &1.opponent_rank) |> Enum.sort()}
  end

IO.puts("\nopponents so far:")
for rank <- 1..8, do: IO.puts("  #{rank}: #{inspect(met[rank])}")

cross_all_met? =
  Enum.all?(1..4, fn a -> Enum.all?(5..8, fn b -> b in met[a] end) end)

intra_none_met? =
  Enum.all?([{1, 2}, {1, 3}, {1, 4}, {2, 3}, {2, 4}, {3, 4}], fn {a, b} -> b not in met[a] end)

IO.puts("\nevery S1 x S2 pair already met? #{cross_all_met?}")
IO.puts("no S1 pair has met?            #{intra_none_met?}")

trf =
  OpenPair.Trf.serialize(%{
    tournament: %{name: "Forced exchange", number_of_players: 8, number_of_rounds: 5},
    players: players
  })

path = Path.join(File.cwd!(), "forced_exchange.trf")
File.write!(path, trf)
IO.puts("\nwrote #{path}")

IO.puts("\nOpenPair: #{inspect(Enum.sort(OpenPair.Pairing.pair_next_round(players, expected_rounds: 5)))}")
