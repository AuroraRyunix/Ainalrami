defmodule Ainalrami.EventFormat do
  @moduledoc """
  The two shapes of a Swiss that OpenPairings pairs with this engine and
  that the Dutch system itself does not describe: the match format and
  pairing by category. `pair_next_round/2` takes `Ainalrami.Pairing`'s
  options plus these two, and is what `ainalrami -p`, `-x` and `-c` pair
  with when a file (`XXM`, `XXG` - see `Ainalrami.Trf`) or a flag
  (`--match-format`, `--groups=`) asks for either. Without them it is
  `Ainalrami.Pairing.pair_next_round/2`, call for call.

  ## Match format (`match_format: true`)

  Every match is two games in a row, colours reversed in the second - the
  Swiss sibling of a round robin's match format (OpenPairings'
  `swiss_match_format`). The odd rounds are paired by the Dutch system from
  the whole history, both legs of every earlier match included; an even
  round replays the round before it board for board with the colours
  turned round, and a pairing-allocated bye in the first leg is a
  pairing-allocated bye again in the second. That is OpenPairings'
  `create_mirrored_leg/5`: the second leg is never paired, it is copied.

  The boards keep the first leg's order. A file does not record board
  numbers, so the first leg is paired again from the history before it;
  when that gives the recorded first leg, its order is the order (as it is
  for every first leg this engine paired), and otherwise the boards are
  ordered by the higher score before the first leg, then the sum of both,
  then the higher-ranked player.

  A player seated in the first leg who already has a result for the
  second, and a player who sat the first leg out but is in the second,
  leave no second leg to copy: `Ainalrami.EventFormat.Error`. OpenPairings
  never writes either - a player away for a match is away for both legs.

  ## Pairing groups (`groups: [[rank, ...], ...]`)

  Each group is paired on its own, as OpenPairings pairs a tournament by
  category (`pair_by_category`): the group's players by the Dutch system
  with every other player sitting the round out (a zero-point bye for the
  pairing only - nobody's history is changed), so scores, colours, floats
  and byes are all the group's own. The groups are paired in the order
  given and their boards follow one another in that order; players named
  in no group make a last group of their own. A group with one player in
  the round gives them the pairing-allocated bye without a pairing, and a
  group with nobody in the round gives nothing - both as OpenPairings does.
  Every option applies to every group: forbidden and soft pairs across two
  groups never meet anyway, and a bye exclusion or preference for a player
  not in the group's round is ignored by the engine.

  OpenPairings does not pair a tournament by category in match format, and
  neither does this: both options together raise
  `Ainalrami.EventFormat.Error`.
  """

  alias Ainalrami.{Pairing, Trf}
  alias Ainalrami.EventFormat.Error

  @zero_bye %{opponent_rank: nil, colour: nil, result: "Z"}

  @doc """
  Pairs the next round: `[{white, black}]` in board order, `black` nil for
  the pairing-allocated bye. `opts` are `Ainalrami.Pairing.pair_next_round/2`'s
  plus `:match_format` (a boolean) and `:groups` (a list of rank lists) -
  see the moduledoc.
  """
  def pair_next_round(players, opts \\ []) do
    {match?, groups, engine_opts} = split_opts!(opts)
    round = Trf.rounds_played(players) + 1

    cond do
      match? and groups != [] ->
        raise Error,
              "match format and pairing groups together are not paired - OpenPairings " <>
                "refuses pairing by category in match format too"

      match? and leg(round) == :second ->
        second_leg(players, round, engine_opts)

      groups != [] ->
        by_groups(players, groups, engine_opts)

      true ->
        Pairing.pair_next_round(players, engine_opts)
    end
  end

  @doc """
  What `pair_next_round/2` will do with the next round of `players`:
  `:second_leg` (copied from the round before), `{:groups, fields}` (each
  `{ranks, field}`, `field` the players as the group's own pairing sees
  them - see `group_fields/2`) or `:plain`.
  """
  def kind(players, opts) do
    {match?, groups, _engine_opts} = split_opts!(opts)
    round = Trf.rounds_played(players) + 1

    cond do
      match? and groups == [] and leg(round) == :second -> :second_leg
      groups != [] and not match? -> {:groups, group_fields(players, groups)}
      true -> :plain
    end
  end

  @doc "Which leg of a match round `round` is under the match format."
  def leg(round) when is_integer(round) and round >= 1,
    do: if(rem(round, 2) == 1, do: :first, else: :second)

  @doc """
  The groups in pairing order - those given, then everybody named in none -
  each as `{ranks, field}`: `ranks` the group's starting ranks in the
  round, `field` every player, the ones outside the group sitting this
  round out. Groups with nobody in the round are left out.
  """
  def group_fields(players, groups) do
    played = Trf.rounds_played(players)
    known = MapSet.new(players, & &1.rank)
    named = Enum.map(groups, fn group -> Enum.filter(group, &MapSet.member?(known, &1)) end)
    listed = named |> List.flatten() |> MapSet.new()
    rest = for p <- players, not MapSet.member?(listed, p.rank), do: p.rank

    (named ++ [rest])
    |> Enum.map(fn group ->
      members = MapSet.new(group)
      ranks = for p <- players, MapSet.member?(members, p.rank), active?(p, played), do: p.rank

      field =
        Enum.map(
          players,
          &if(MapSet.member?(members, &1.rank), do: &1, else: sit_out(&1, played))
        )

      {ranks, field}
    end)
    |> Enum.reject(fn {ranks, _field} -> ranks == [] end)
  end

  @doc """
  The players as they stood immediately before `round` was paired: every
  earlier game, plus this round's own entry for anyone who did not take
  part in its pairing (a bye recorded in advance), the points recounted
  under `point_system` (nil for the standard one). What `-c` replays from.
  """
  def before_round(players, round, point_system \\ nil) do
    points = point_system || Trf.default_point_system()

    Enum.map(players, fn player ->
      earlier = Enum.take(player.games, round - 1)

      games =
        case Enum.at(player.games, round - 1) do
          nil -> earlier
          game -> if Trf.participated_in_pairing?(game), do: earlier, else: earlier ++ [game]
        end

      %{
        player
        | games: games,
          points: Enum.sum(Enum.map(games, &Trf.points_for_game(&1, points)))
      }
    end)
  end

  @doc """
  The pairing the players' games record for `round`, as `[{white, black}]`
  with `black` nil for a pairing-allocated bye - each game claimed by its
  White (the lower rank when no colour is written).
  """
  def recorded(players, round) do
    Enum.flat_map(players, fn player ->
      case Enum.at(player.games, round - 1) do
        nil ->
          []

        game ->
          cond do
            not Trf.participated_in_pairing?(game) -> []
            is_nil(game.opponent_rank) -> [{player.rank, nil}]
            game.colour == "w" -> [{player.rank, game.opponent_rank}]
            game.colour == "b" -> []
            player.rank < game.opponent_rank -> [{player.rank, game.opponent_rank}]
            true -> []
          end
      end
    end)
  end

  # ---- options ---------------------------------------------------------------

  defp split_opts!(opts) do
    unless Keyword.keyword?(opts), do: raise(ArgumentError, "opts must be a keyword list")

    match? =
      case Keyword.get(opts, :match_format, false) do
        m when is_boolean(m) -> m
        nil -> false
        other -> raise ArgumentError, ":match_format must be a boolean, got #{inspect(other)}"
      end

    groups =
      case Keyword.get(opts, :groups) do
        nil ->
          []

        groups when is_list(groups) ->
          Enum.each(groups, fn
            group when is_list(group) ->
              unless Enum.all?(group, &is_integer/1),
                do: raise(ArgumentError, ":groups must be lists of starting ranks")

            _ ->
              raise ArgumentError, ":groups must be lists of starting ranks"
          end)

          all = List.flatten(groups)

          case all -- Enum.uniq(all) do
            [] -> Enum.reject(groups, &(&1 == []))
            [rank | _] -> raise ArgumentError, ":groups puts #{rank} in two groups"
          end

        other ->
          raise ArgumentError, ":groups must be a list of rank lists, got #{inspect(other)}"
      end

    {match?, groups, Keyword.drop(opts, [:match_format, :groups])}
  end

  # ---- pairing groups -------------------------------------------------------

  defp by_groups(players, groups, opts) do
    players
    |> group_fields(groups)
    |> Enum.flat_map(fn
      {[only], _field} -> [{only, nil}]
      {_ranks, field} -> Pairing.pair_next_round(field, opts)
    end)
  end

  defp active?(player, played), do: length(player.games) <= played

  # Out of this group's round: a zero-point bye in the round being paired,
  # after zero-point byes for any round the player's line stops short of -
  # so the bye lands in this round's column. Only the pairing sees it.
  defp sit_out(player, played) do
    if active?(player, played) do
      %{
        player
        | games: player.games ++ List.duplicate(@zero_bye, played + 1 - length(player.games))
      }
    else
      player
    end
  end

  # ---- the second leg of a match --------------------------------------------

  defp second_leg(players, round, opts) do
    first = round - 1
    leg1 = recorded(players, first)
    played = Trf.rounds_played(players)
    by_rank = Map.new(players, &{&1.rank, &1})
    seated = leg1 |> Enum.flat_map(fn {w, b} -> [w, b] end) |> Enum.reject(&is_nil/1)

    case Enum.find(seated, &(not active?(Map.fetch!(by_rank, &1), played))) do
      nil ->
        :ok

      rank ->
        raise Error,
              "round #{round} is the second leg of the match begun in round #{first}, but " <>
                "##{rank}, seated in round #{first}, already has a result for round #{round}"
    end

    seated_set = MapSet.new(seated)

    case Enum.find(players, &(active?(&1, played) and not MapSet.member?(seated_set, &1.rank))) do
      nil ->
        :ok

      player ->
        raise Error,
              "round #{round} is the second leg of the match begun in round #{first}, but " <>
                "##{player.rank} sat round #{first} out and has no result for round #{round} - " <>
                "a player away for a match is away for both of its legs"
    end

    players
    |> first_leg_order(first, leg1, opts)
    |> Enum.map(fn
      {w, nil} -> {w, nil}
      {w, b} -> {b, w}
    end)
  end

  # The first leg in its board order - see the moduledoc.
  defp first_leg_order(players, first, leg1, opts) do
    before = before_round(players, first, opts[:point_system])

    replayed =
      try do
        Pairing.pair_next_round(before, opts)
      rescue
        _ -> nil
      end

    if replayed != nil and Enum.sort(replayed) == Enum.sort(leg1) do
      replayed
    else
      points = Map.new(before, &{&1.rank, &1.points})

      Enum.sort_by(leg1, fn
        {w, nil} ->
          {1, 0, 0, w}

        {w, b} ->
          {0, -max(points[w], points[b]), -(points[w] + points[b]), min(w, b)}
      end)
    end
  end
end
