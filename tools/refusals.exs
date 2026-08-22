# Are there rounds bbpPairings REFUSES that a legal pairing exists for?
#
# bbpPairings proves a complete matching exists before it pairs and
# throws NoValidPairingException otherwise (dutch.cpp:828); Gacrux
# constrains bracket choices with precomputed feasibility; Ainalrami
# repairs after the fact. All three are meant to answer "is this round
# pairable at all" identically - this checks whether they do.
#
# Plays tournaments forward on bbpPairings' own answers. When bbpPairings
# refuses a round, Ainalrami is asked the same question and its answer is
# checked for legality independently: every active player paired exactly
# once, no rematch, and the right number of byes going to someone C2
# allows. Deep Swisses in a small field are where refusals happen, so
# that is what it generates.
#
#   mix run tools/refusals.exs [tournaments] [rounds] [min] [max]

args = System.argv()
count = Enum.at(args, 0, "150") |> String.to_integer()
rounds = Enum.at(args, 1, "13") |> String.to_integer()
min_p = Enum.at(args, 2, "8") |> String.to_integer()
max_p = Enum.at(args, 3, "14") |> String.to_integer()

alias Ainalrami.{Pairing, Test.Bbppairings}

defmodule Ref do
  def roster(n) do
    for i <- 1..n do
      %{rank: i, name: "P#{i}", fide_rating: Enum.random(1000..2800), points: 0.0, games: []}
    end
    |> Enum.shuffle()
    |> Enum.with_index(1)
    |> Enum.map(fn {p, i} -> %{p | rank: i} end)
  end

  def trf(players, rounds) do
    Ainalrami.Trf.serialize(%{tournament: %{name: "Refusals", type: "swiss"}, players: players}) <>
      "152 W\r\nXXR #{rounds}\r\n"
  end

  # Independent of either engine: does this pairing obey the absolute
  # criteria for the players who should be playing?
  def legal?(pairs, active, players) do
    by_rank = Map.new(players, &{&1.rank, &1})
    seated = Enum.flat_map(pairs, fn {w, b} -> if b, do: [w, b], else: [w] end)
    byes = for {w, nil} <- pairs, do: w

    rematch? =
      Enum.any?(pairs, fn
        {_w, nil} ->
          false

        {w, b} ->
          Enum.any?(Map.fetch!(by_rank, w).games, &(&1.result in ~w(1 = 0) and &1.opponent_rank == b))
      end)

    bad_bye? =
      Enum.any?(byes, fn w ->
        Enum.any?(Map.fetch!(by_rank, w).games, &(&1.result in ~w(U F + W)))
      end)

    Enum.sort(seated) == Enum.sort(Enum.map(active, & &1.rank)) and
      length(byes) == rem(length(active), 2) and not rematch? and not bad_bye?
  end

  def apply_round(players, pairs) do
    games =
      Enum.reduce(pairs, %{}, fn
        {w, nil}, acc ->
          Map.put(acc, w, {%{opponent_rank: nil, colour: nil, result: "U"}, 1.0})

        {w, b}, acc ->
          {rw, rb, pw, pb} =
            case Enum.random([:w, :b, :d]) do
              :w -> {"1", "0", 1.0, 0.0}
              :b -> {"0", "1", 0.0, 1.0}
              :d -> {"=", "=", 0.5, 0.5}
            end

          acc
          |> Map.put(w, {%{opponent_rank: b, colour: "w", result: rw}, pw})
          |> Map.put(b, {%{opponent_rank: w, colour: "b", result: rb}, pb})
      end)

    Enum.map(players, fn p ->
      case Map.fetch(games, p.rank) do
        {:ok, {game, pts}} -> %{p | points: p.points + pts, games: p.games ++ [game]}
        :error -> p
      end
    end)
  end
end

results =
  1..count
  |> Task.async_stream(
    fn seed ->
      :rand.seed(:exsss, {seed, seed * 7919, seed * 104_729})
      roster = Ref.roster(Enum.random(min_p..max_p))

      Enum.reduce_while(1..rounds, {roster, []}, fn round, {players, acc} ->
        active = Enum.filter(players, &(length(&1.games) < round))

        case Bbppairings.pair(Ref.trf(players, rounds)) do
          {:ok, pairs} ->
            {:cont, {Ref.apply_round(players, pairs), acc}}

          {:no_valid_pairing, _} ->
            ours =
              try do
                Pairing.pair_next_round(players, expected_rounds: rounds)
              rescue
                _ -> :refused
              end

            verdict =
              cond do
                ours == :refused -> :both_refuse
                Ref.legal?(ours, active, players) -> :we_pair_it_legally
                true -> :we_emit_illegal
              end

            {:halt, {players, [{seed, round, verdict} | acc]}}

          _ ->
            {:halt, {players, acc}}
        end
      end)
      |> elem(1)
    end,
    max_concurrency: System.schedulers_online(),
    timeout: :infinity,
    ordered: false
  )
  |> Enum.flat_map(fn {:ok, rows} -> rows end)

IO.puts("\n#{length(results)} round(s) where bbpPairings refused to pair:\n")

results
|> Enum.group_by(fn {_s, _r, v} -> v end)
|> Enum.sort_by(fn {_k, v} -> -length(v) end)
|> Enum.each(fn {verdict, cases} ->
  IO.puts("  #{String.pad_trailing(to_string(verdict), 22)} #{length(cases)}")

  cases
  |> Enum.sort()
  |> Enum.take(5)
  |> Enum.each(fn {s, r, _} -> IO.puts("      seed #{s}, round #{r}") end)
end)

IO.puts("")
