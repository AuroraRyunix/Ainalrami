defmodule Ainalrami.Acceleration do
  @moduledoc """
  Virtual points, worked out rather than read: FIDE C.04.7's Baku
  acceleration from a round count, and an arbitrary table of them.

  The pairing engine takes acceleration as data - each player's
  `:accelerations` list, one value per round, which is what an `XXA` line
  parses to (`Ainalrami.Pairing.pair_next_round/2`). It does not derive
  C.04.7's groups: the host does, and writes them down. This module is that
  derivation for a caller with no host - the standalone CLI's
  `--acceleration=baku` and `--virtual-points=` - and it is the reading
  OpenPairings and `Ainalrami.Generator` use, which the tests hold it to.

  ## Baku (C.04.7)

    * Group A is the top half of the starting list, rounded up to an even
      number: `2 * ceil(n / 4)` players, the lowest starting ranks.
    * The accelerated rounds are the first `ceil(rounds / 2)`.
    * In the first `ceil(accelerated / 2)` of those a Group A player has one
      virtual point, in the rest of them a half, afterwards none. FIDE's own
      example: nine rounds, five accelerated, 1 1 1 ½ ½.

  Group A is fixed when round one is paired. A late entrant does not grow
  it, which a program counting today's roster would get wrong - so the
  group's last starting rank can be given (`:group_a_last`), and has to be
  for a field that grew.

  bbpPairings' own Baku flag sizes Group A as `ceil(n / 2)` - 5, not 6, of
  10. That path is not this one; see `Ainalrami.Generator`.
  """

  alias Ainalrami.Trf

  @doc """
  How many players C.04.7 puts in Group A of a field of `count`.
  """
  def baku_group_size(count) when is_integer(count) and count >= 0,
    do: min(count, 2 * ceil_div(count, 4))

  @doc """
  A Group A player's virtual points for rounds `1..through` of an event of
  `total_rounds`.
  """
  def baku_points(total_rounds, through)
      when is_integer(total_rounds) and total_rounds >= 1 and is_integer(through) do
    accelerated = ceil_div(total_rounds, 2)
    full = ceil_div(accelerated, 2)

    Enum.map(1..through//1, fn round ->
      cond do
        round <= full -> 1.0
        round <= accelerated -> 0.5
        true -> 0.0
      end
    end)
  end

  @doc """
  `players` with C.04.7's virtual points on Group A, as `:accelerations`.

  Options:

    * `:group_a_last` - the last starting rank of Group A. Default: the
      rank of the `baku_group_size/1`-th player of `players` by starting
      rank, which is right for a field nobody joined late.
    * `:through` - the last round to give a value for. Default: the later
      of `total_rounds` and the round about to be paired, so every round
      the engine can ask about has one.

  Raises `ArgumentError` when a player already carries virtual points: two
  accelerations at once is a question, not an instruction.
  """
  def baku(players, total_rounds, opts \\ [])
      when is_list(players) and is_integer(total_rounds) and total_rounds >= 1 do
    refuse_existing!(players)

    last =
      case Keyword.get(opts, :group_a_last) do
        nil ->
          players
          |> Enum.map(& &1.rank)
          |> Enum.sort()
          |> Enum.at(baku_group_size(length(players)) - 1)

        rank when is_integer(rank) and rank >= 0 ->
          rank

        other ->
          raise ArgumentError, ":group_a_last must be a starting rank, got #{inspect(other)}"
      end

    through =
      Keyword.get_lazy(opts, :through, fn ->
        max(total_rounds, Trf.rounds_played(players) + 1)
      end)

    points = baku_points(total_rounds, through)

    Enum.map(players, fn player ->
      if is_integer(last) and player.rank <= last,
        do: Map.put(player, :accelerations, points),
        else: player
    end)
  end

  @doc """
  `players` with the virtual points of `table` - `%{rank => [points per
  round]}` - as `:accelerations`. Not C.04.7: whatever the organiser's
  scheme is, written out.

  Raises `ArgumentError` for a rank the roster does not have, a value that
  is not a non-negative number, and a player who already carries virtual
  points.
  """
  def virtual_points(players, table) when is_list(players) and is_map(table) do
    refuse_existing!(players)
    ranks = MapSet.new(players, & &1.rank)

    for {rank, values} <- table do
      unless MapSet.member?(ranks, rank) do
        raise ArgumentError, "virtual points name #{inspect(rank)}, which is not a starting rank"
      end

      unless is_list(values) and Enum.all?(values, &(is_number(&1) and &1 >= 0)) do
        raise ArgumentError,
              "virtual points for #{rank} must be non-negative numbers, one per round, " <>
                "got #{inspect(values)}"
      end
    end

    Enum.map(players, fn player ->
      case Map.fetch(table, player.rank) do
        {:ok, values} -> Map.put(player, :accelerations, Enum.map(values, &(&1 / 1)))
        :error -> player
      end
    end)
  end

  @doc "Whether any player carries virtual points."
  def accelerated?(players),
    do: Enum.any?(players, &(Map.get(&1, :accelerations) not in [nil, []]))

  defp refuse_existing!(players) do
    if accelerated?(players) do
      raise ArgumentError,
            "the players already carry virtual points (:accelerations, a file's XXA or 250)"
    end
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)
end
