defmodule Ainalrami.RoundRobin do
  @moduledoc """
  An individual round robin read from a TRF: `ainalrami file.trf -p` gives
  the next round of the Berger table, `-c` compares every round with it,
  `-x` says the table fixed the round. The system is the file's `192` code
  (`BERGER_ROUNDROBIN_Gn`, `BERGER_ROUNDROBIN`, `FIDE_ROUNDROBIN`,
  `BERGER_DOUBLEROUNDROBIN`, `FIDE_DOUBLEROUNDROBIN`) or a `092` type
  naming a round robin, played as many times as its rounds need.

  ## The table, and how it is seated

  `Ainalrami.Berger` - the tables of the Competition Rules (C.05 Annex 1),
  repeated `n` times with the colours reversed in every second cycle, and
  for `FIDE_DOUBLEROUNDROBIN` the first cycle's last two rounds played in
  reverse order. The players are numbered for the table in starting-rank
  order (the `001` ranks, 1..N in a file OpenPairings writes - its frozen
  pairing numbers); in an odd field the player meeting the dummy has the
  round free (OpenPairings records a zero-point bye, `Z`).

  This is OpenPairings' own schedule (`PairingsEngine.RoundRobin.schedule/3`)
  board for board: `test/fixtures/round_robin/openpairings_berger.txt` holds
  its boards for 3-16 players, one and two cycles, and the tests hold this
  module to them.

  ## Output (`-p`)

  JaVaFo's pairing list, as for a Swiss: a count line, then `WHITE BLACK`
  per board in OpenPairings' board order (lowest number first), and the
  free player last as `PLAYER 0`.
  """

  alias Ainalrami.{Berger, Trf}

  @doc "A one-line description of the settings, for the trace."
  def describe(%{games: games} = s) do
    times = if games == 1, do: "once", else: "#{games} times"

    order =
      if s[:reverse_last_two?], do: ", the first cycle's last two rounds reversed", else: ""

    source =
      if s.code,
        do: " (192 #{s.code})",
        else: " (092 round robin, no 192: #{times} by the rounds)"

    "a round robin by the Berger tables (C.05 Annex 1), every game played #{times}#{order}" <>
      source
  end

  @doc "The starting ranks in Berger-number order."
  def numbers(parsed), do: parsed.players |> Enum.map(& &1.rank) |> Enum.sort()

  @doc """
  How many cycles a round robin known only from its `092` type plays: as
  many as its rounds need.
  """
  def cycles_played(parsed) do
    n = length(parsed.players)
    rounds = parsed.players |> Enum.map(&length(&1.games)) |> Enum.max(fn -> 0 end)
    per_cycle = if n < 2, do: 1, else: Berger.total_rounds(n, 1)
    max(1, div(rounds + per_cycle - 1, per_cycle))
  end

  @doc "The last round anybody was paired in, 0 if none."
  def paired_rounds(parsed) do
    parsed.players
    |> Enum.flat_map(fn p ->
      for {g, r} <- Enum.with_index(p.games, 1), Trf.participated_in_pairing?(g), do: r
    end)
    |> Enum.max(fn -> 0 end)
  end

  @doc """
  The Berger table's round `round` in starting ranks: `{:ok, boards,
  free}` with `boards` as `[{white, black}]` in board order, `free` the
  player with the round off (nil in an even field), or `{:error, reason}`.
  """
  def schedule(parsed, settings, round) do
    numbers = numbers(parsed)
    n = length(numbers)

    if n < 2 do
      {:error, :too_few_players}
    else
      rank = fn number -> Enum.at(numbers, number - 1) end
      opts = [reverse_last_two?: Map.get(settings, :reverse_last_two?, false)]

      with {:ok, pairs, free} <- Berger.round(n, settings.games, round, opts) do
        boards =
          pairs
          |> Enum.map(fn {w, b} -> {rank.(w), rank.(b)} end)
          |> Enum.sort_by(fn {w, b} -> min(w, b) end)

        {:ok, boards, free && rank.(free)}
      end
    end
  end

  @doc "The next round: `{:ok, round, boards, free}` or `{:error, reason}`."
  def next_round(parsed, settings) do
    round = paired_rounds(parsed) + 1

    with {:ok, boards, free} <- schedule(parsed, settings, round) do
      {:ok, round, boards, free}
    end
  end

  @doc "The pairing list `-p` writes - see the moduledoc."
  def format(boards, free) do
    lines =
      Enum.map(boards, fn {w, b} -> "#{w} #{b}" end) ++
        if(free, do: ["#{free} 0"], else: [])

    Enum.map_join(["#{length(lines)}" | lines], "", &(&1 <> "\r\n"))
  end

  @doc """
  The games the file records for `round`: `[{white, black, colour_known?}]`,
  each game once (claimed by its White, or by the lower rank when no
  colour is written).
  """
  def recorded(parsed, round) do
    parsed.players
    |> Enum.flat_map(fn p ->
      case Enum.at(p.games, round - 1) do
        %{opponent_rank: opp} = g when is_integer(opp) ->
          cond do
            g.colour == "w" -> [{p.rank, opp, true}]
            g.colour == "b" -> []
            p.rank < opp -> [{p.rank, opp, false}]
            true -> []
          end

        _ ->
          []
      end
    end)
    |> Enum.sort()
  end

  @doc """
  Compares round `round` with the table: `%{result:, file:, engine:,
  differing:, missing:}` - `result` `:ok`, `:colours` (every game
  scheduled, the colours of `differing` reversed), `:differs` (a game the
  table does not have) or `:beyond` (no such round); `missing` the
  scheduled games the file records nothing for.
  """
  def check_round(parsed, round, settings) do
    games = recorded(parsed, round)
    file = Enum.map(games, fn {w, b, _} -> {w, b} end)

    case schedule(parsed, settings, round) do
      {:ok, boards, _free} ->
        by_pair = Map.new(boards, fn {w, b} -> {Enum.sort([w, b]), {w, b}} end)

        unscheduled =
          Enum.reject(games, fn {w, b, _} -> Map.has_key?(by_pair, Enum.sort([w, b])) end)

        seen = MapSet.new(games, fn {w, b, _} -> Enum.sort([w, b]) end)
        missing = for {w, b} <- boards, not MapSet.member?(seen, Enum.sort([w, b])), do: {w, b}

        differing =
          for {w, b, true} <- games, Map.get(by_pair, Enum.sort([w, b])) == {b, w}, do: {w, b}

        result =
          cond do
            unscheduled != [] -> :differs
            differing != [] -> :colours
            true -> :ok
          end

        %{result: result, file: file, engine: boards, differing: differing, missing: missing}

      {:error, _} ->
        %{result: :beyond, file: file, engine: [], differing: [], missing: []}
    end
  end
end
