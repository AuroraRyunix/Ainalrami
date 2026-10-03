defmodule Ainalrami.RoundRobinGenerator do
  @moduledoc """
  Random individual round robins - `ainalrami -g --roundrobin`. The
  players are seated by the Berger tables (`Ainalrami.Berger`) in
  starting-rank order, results are drawn from the rating table, and the
  file is written as TRF26 with its `192` code (`BERGER_ROUNDROBIN_G1`,
  `BERGER_ROUNDROBIN_G2` or `FIDE_DOUBLEROUNDROBIN` - the first cycle's last
  two rounds reversed), so `-c` checks it and `-p` on any copy cut back to
  before a round gives that round.

  Options (all drawn from the seed when left out): `:seed`, `:players`
  (3-16), `:cycles` (1, or 2 one time in four), `:rounds` (default the
  whole table), `:forfeit_pct` (games forfeited, 0/0/3), `:draw_rate`
  (0.3), `:rating_range` (`{low, high}`, 1400-2700), `:tie_breaks` (codes
  after the score, `202`, with the final ranks they give - never BH, FB or
  AOB, which C.07 bars from round robins). In an odd field the player
  meeting the dummy has a zero-point bye (`Z`), as OpenPairings records it.

  Returns `{text, seed}`; `run/1` adds `:pairings`, each round's
  `{boards, free}` as the table gave them.
  """

  alias Ainalrami.{Berger, Tiebreaks, Trf}

  @points %{"1" => 1.0, "=" => 0.5, "0" => 0.0, "+" => 1.0, "-" => 0.0, "Z" => 0.0}

  def generate(opts \\ []) do
    %{text: text, seed: seed} = run(opts)
    {text, seed}
  end

  def run(opts \\ []) do
    seed = Keyword.get_lazy(opts, :seed, &fresh_seed/0)
    :rand.seed(:exsss, {seed, seed * 31 + 7, seed * 7919 + 1})

    n = Keyword.get_lazy(opts, :players, fn -> Enum.random(3..16) end)

    unless is_integer(n) and n >= 2,
      do: raise(ArgumentError, ":players must be at least 2, not #{inspect(n)}")

    cycles = Keyword.get_lazy(opts, :cycles, fn -> if :rand.uniform(4) == 1, do: 2, else: 1 end)

    unless is_integer(cycles) and cycles >= 1,
      do: raise(ArgumentError, ":cycles must be at least 1, not #{inspect(cycles)}")

    reverse? = cycles == 2 and :rand.uniform(2) == 1

    code =
      cond do
        reverse? -> "FIDE_DOUBLEROUNDROBIN"
        true -> "BERGER_ROUNDROBIN_G#{cycles}"
      end

    total = Berger.total_rounds(n, cycles)
    rounds = opts |> Keyword.get(:rounds, total) |> min(total) |> max(0)
    forfeit_pct = Keyword.get_lazy(opts, :forfeit_pct, fn -> Enum.random([0, 0, 3]) end)
    draw_rate = Keyword.get(opts, :draw_rate, 0.3)
    {low, high} = Keyword.get(opts, :rating_range, {1400, 2700})

    tie_breaks =
      case Keyword.fetch(opts, :tie_breaks) do
        {:ok, list} -> list
        :error -> if :rand.uniform(2) == 1, do: Enum.take_random(~w(SB DE WIN KS), 2)
      end

    ratings =
      for(_ <- 1..n, do: Enum.random(low..high))
      |> Enum.sort(:desc)
      |> Enum.with_index(1)
      |> Map.new(fn {r, i} -> {i, r} end)

    {games, pairings} =
      Enum.reduce(1..rounds//1, {Map.new(1..n, &{&1, []}), %{}}, fn r, {games, pairings} ->
        {:ok, pairs, free} = Berger.round(n, cycles, r, reverse_last_two?: reverse?)

        games =
          Enum.reduce(pairs, games, fn {w, b}, games ->
            {rw, rb} = result(ratings[w], ratings[b], forfeit_pct, draw_rate)

            games
            |> Map.update!(w, &(&1 ++ [%{opponent_rank: b, colour: "w", result: rw}]))
            |> Map.update!(b, &(&1 ++ [%{opponent_rank: w, colour: "b", result: rb}]))
          end)

        games =
          if free,
            do:
              Map.update!(games, free, &(&1 ++ [%{opponent_rank: nil, colour: nil, result: "Z"}])),
            else: games

        boards = Enum.sort_by(pairs, fn {w, b} -> min(w, b) end)
        {games, Map.put(pairings, r, %{boards: boards, free: free})}
      end)

    players =
      for i <- 1..n do
        g = games[i]

        %{
          rank: i,
          name: "Player #{i}",
          fide_rating: ratings[i],
          points: g |> Enum.map(&@points[&1.result]) |> Enum.sum(),
          games: g
        }
      end

    tournament = %{
      name: "Ainalrami round robin RTG seed=#{seed}",
      type: "Round Robin",
      type_code: code,
      number_of_rounds: total
    }

    {players, tournament} = with_ranks(players, tournament, tie_breaks)
    text = Trf.serialize(%{tournament: tournament, players: players}, dialect: :trf26)
    %{text: text, seed: seed, players: n, cycles: cycles, rounds: rounds, pairings: pairings}
  end

  defp result(ra, rb, forfeit_pct, draw_rate) do
    if :rand.uniform(100) <= forfeit_pct do
      Enum.random([{"+", "-"}, {"-", "+"}])
    else
      e = 1 / (1 + :math.pow(10, (rb - ra) / 400))
      x = :rand.uniform()

      cond do
        x < draw_rate -> {"=", "="}
        x < draw_rate + (1 - draw_rate) * e -> {"1", "0"}
        true -> {"0", "1"}
      end
    end
  end

  defp with_ranks(players, tournament, nil), do: {players, tournament}

  defp with_ranks(players, tournament, codes) do
    event = Tiebreaks.Event.from_trf(%{players: players, tournament: tournament})

    case Tiebreaks.rank(event, ["PTS" | codes]) do
      {:ok, standings} ->
        place =
          standings
          |> Enum.sort_by(&{&1.rank, &1.id})
          |> Enum.with_index(1)
          |> Map.new(fn {row, i} -> {row.id, i} end)

        {Enum.map(players, &Map.put(&1, :final_rank, place[&1.rank])),
         Map.put(tournament, :tie_breaks, codes)}

      {:error, reason} ->
        raise ArgumentError, ":tie_breaks - #{reason}"
    end
  end

  defp fresh_seed do
    {seed, _state} = :rand.uniform_s(0xFFFFFFFF, :rand.seed_s(:exsss))
    seed
  end
end
