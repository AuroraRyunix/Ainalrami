defmodule Ainalrami.PairingInput do
  @moduledoc """
  What a caller with a file and no host has to do by hand before it can ask
  for a round: turn the organiser's options from text into the engine's
  options, record the byes requested for the round, and re-score a roster
  under another point system.

  OpenPairings does all three from its database and hands the engine the
  result. The standalone CLI has a TRF and a command line, so it does them
  here - and so can any other caller, which is why this is a module and not
  two hundred lines inside `Ainalrami.CLI`.

  ## The organiser's options as text

  One spelling, used by the command line's flags and by the `XXO`
  extension records (`Ainalrami.Trf`, "The organiser's records"):

    * rounds - `3`, `3-5`, and several joined by `+`: `3-4+7`
      (`parse_rounds/1`);
    * a player with the rounds a setting applies to - `12`, `12@3-4+7`
      (`parse_ranked/1`);
    * a group of players for a range of rounds - `2 9 12` or `2,9,12`,
      optionally `@3-5` (`parse_group/1`), which is the engine's own
      `{ranks, first_round, last_round}`.

  ## Not FIDE

  Soft pairs, bye exclusions and bye preferences are the organiser's, not
  the Dutch system's (`Ainalrami.Pairing`, `Ainalrami.ByePreference`). This
  module only carries them; whoever pairs with them says so.
  """

  alias Ainalrami.Trf

  @bye_kinds [
    {"want", :want_hard},
    {"want-soft", :want_soft},
    {"avoid", :avoid_hard},
    {"avoid-soft", :avoid_soft}
  ]

  @doc """
  The four bye preferences as `{word, setting}`, the word being what an
  `XXO bye-WORD` record and a `--bye-WORD` flag call it.
  """
  def bye_kinds, do: @bye_kinds

  # ---- text ----------------------------------------------------------------

  @doc """
  `"3"`, `"3-5"`, `"3-4+7"` as a sorted list of round numbers, or `:error`.
  """
  def parse_rounds(text) when is_binary(text) do
    parts = String.split(text, "+")

    spans =
      Enum.map(parts, fn part ->
        case String.split(part, "-") do
          [n] ->
            with n when is_integer(n) <- positive(n), do: [n]

          [a, b] ->
            with a when is_integer(a) <- positive(a),
                 b when is_integer(b) and b >= a <- positive(b) do
              Enum.to_list(a..b)
            else
              _ -> :error
            end

          _ ->
            :error
        end
      end)

    if spans == [] or Enum.any?(spans, &(&1 == :error)),
      do: :error,
      else: {:ok, spans |> List.flatten() |> Enum.uniq() |> Enum.sort()}
  end

  @doc "The inverse of `parse_rounds/1`: `[3, 4, 7]` as `\"3-4+7\"`."
  def format_rounds(rounds) when is_list(rounds) do
    rounds
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.chunk_while(
      [],
      fn
        n, [] -> {:cont, [n]}
        n, [last | _] = run when n == last + 1 -> {:cont, [n | run]}
        n, run -> {:cont, Enum.reverse(run), [n]}
      end,
      fn
        [] -> {:cont, []}
        run -> {:cont, Enum.reverse(run), []}
      end
    )
    |> Enum.map_join("+", fn
      [n] -> "#{n}"
      run -> "#{hd(run)}-#{List.last(run)}"
    end)
  end

  @doc """
  `"12"` as `{:ok, 12, :all}` and `"12@3-4+7"` as `{:ok, 12, [3, 4, 7]}`,
  or `:error`.
  """
  def parse_ranked(token) when is_binary(token) do
    case String.split(token, "@") do
      [rank] ->
        with rank when is_integer(rank) <- positive(rank), do: {:ok, rank, :all}

      [rank, rounds] ->
        with rank when is_integer(rank) <- positive(rank),
             {:ok, rounds} <- parse_rounds(rounds) do
          {:ok, rank, rounds}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  @doc "The inverse of `parse_ranked/1`."
  def format_ranked(rank, :all), do: "#{rank}"
  def format_ranked(rank, rounds) when is_list(rounds), do: "#{rank}@#{format_rounds(rounds)}"

  @doc """
  A group of two or more starting ranks, separated by commas or blanks,
  optionally followed by `@ROUND` or `@FIRST-LAST`: `{:ok, ranks}` or
  `{:ok, {ranks, first, last}}` - the two shapes `:forbidden_pairs` and
  `:soft_pairs` take - or `:error`.
  """
  def parse_group(text) when is_binary(text) do
    case String.split(text, "@") do
      [ranks] ->
        with {:ok, ranks} <- ranks(ranks), do: {:ok, ranks}

      [ranks, span] ->
        with {:ok, ranks} <- ranks(ranks),
             {:ok, first, last} <- span(String.trim(span)) do
          {:ok, {ranks, first, last}}
        end

      _ ->
        :error
    end
  end

  @doc "The inverse of `parse_group/1`, ranks separated by `separator`."
  def format_group(group, separator \\ " ")

  def format_group({ranks, first, last}, separator) do
    span = if first == last, do: "#{first}", else: "#{first}-#{last}"
    Enum.join(ranks, separator) <> if(separator == " ", do: " @", else: "@") <> span
  end

  def format_group(ranks, separator) when is_list(ranks), do: Enum.join(ranks, separator)

  defp ranks(text) do
    ranks = text |> String.split([",", " ", "\t"], trim: true) |> Enum.map(&positive/1)

    if length(ranks) >= 2 and Enum.all?(ranks, &is_integer/1) and ranks == Enum.uniq(ranks),
      do: {:ok, ranks},
      else: :error
  end

  defp span(text) do
    case String.split(text, "-") do
      [n] ->
        with n when is_integer(n) <- positive(n), do: {:ok, n, n}

      [a, b] ->
        with a when is_integer(a) <- positive(a),
             b when is_integer(b) and b >= a <- positive(b) do
          {:ok, a, b}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp positive(text) do
    case Integer.parse(String.trim(text)) do
      {n, ""} when n >= 1 -> n
      _ -> :error
    end
  end

  # ---- the engine's options ------------------------------------------------

  @doc """
  Whether a parsed tournament carries any of the organiser's records
  (`XXO` soft pairs and bye settings).
  """
  def organiser?(tournament) do
    Enum.any?(
      [:soft_pairs, :bye_exclusions, :bye_preferences],
      &(Map.get(tournament, &1) not in [nil, []])
    )
  end

  @doc """
  The organiser's options of a parsed tournament - what its `XXO` lines
  parse to - as `Ainalrami.Pairing.pair_next_round/2` takes them for
  `round`: `:soft_pairs` with `:soft_position`, `:bye_exclusions` (the
  ranks excluded in this round) and `:bye_preferences`. A key is there only
  when the tournament has something for it, so a tournament with none gives
  `[]` and is paired with exactly the options it always was.
  """
  def organiser_opts(tournament, round) when is_integer(round) do
    soft =
      case Map.get(tournament, :soft_pairs) do
        [_ | _] = groups ->
          [soft_pairs: groups, soft_position: Map.get(tournament, :soft_position) || :strong]

        _ ->
          []
      end

    excluded =
      case bye_exclusions(Map.get(tournament, :bye_exclusions), round) do
        [] -> []
        ranks -> [bye_exclusions: ranks]
      end

    preferences =
      case Map.get(tournament, :bye_preferences) do
        [_ | _] = prefs -> [bye_preferences: prefs]
        _ -> []
      end

    soft ++ excluded ++ preferences
  end

  @doc """
  The ranks of `entries` - each a rank, or `{rank, rounds}` with `rounds` a
  list or `:all` - that are excluded from the bye in `round`, sorted.
  """
  def bye_exclusions(entries, round) do
    (entries || [])
    |> Enum.flat_map(fn
      rank when is_integer(rank) -> [rank]
      {rank, :all} -> [rank]
      {rank, rounds} when is_list(rounds) -> if round in rounds, do: [rank], else: []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # ---- byes requested for the round ----------------------------------------

  @doc """
  Records a bye for the round about to be paired: `byes` is a list of
  `{rank, "H" | "Z" | "F"}` - a half-point, zero-point or full-point bye
  the player asked for, or an absence. Exactly what a TRF26 `240` record,
  or the letter in the player's own column, says: the entry is appended to
  the player's games (after blanks for any round the line left off) and
  its points are credited, so the engine leaves the player out.

  `played` is the number of rounds already paired, for a caller who knows
  better than `Ainalrami.Trf.rounds_played/1` (a team file whose last round
  was all forfeited matches).

  Raises `ArgumentError` for a rank the roster does not have, a type other
  than the three, and a player who already has an entry for the round.
  """
  def request_byes(players, byes, point_system \\ nil, played \\ nil)
      when is_list(players) and is_list(byes) do
    system = point_system || Trf.default_point_system()
    played = played || Trf.rounds_played(players)
    wanted = Map.new(byes)
    known = MapSet.new(players, & &1.rank)

    for {rank, type} <- byes do
      unless MapSet.member?(known, rank) do
        raise ArgumentError, "a bye for #{inspect(rank)}, which is not a starting rank"
      end

      unless type in ["H", "Z", "F"] do
        raise ArgumentError,
              "a requested bye is \"H\", \"Z\" or \"F\", got #{inspect(type)} for #{rank}"
      end
    end

    if map_size(wanted) != length(byes) do
      [rank | _] = Enum.map(byes, &elem(&1, 0)) -- Map.keys(wanted)
      raise ArgumentError, "two byes for starting rank #{rank} in one round"
    end

    Enum.map(players, fn player ->
      case Map.fetch(wanted, player.rank) do
        :error ->
          player

        {:ok, type} ->
          games = player[:games] || []

          if length(games) > played do
            raise ArgumentError,
                  "starting rank #{player.rank} already has an entry for round #{played + 1}"
          end

          blank = %{opponent_rank: nil, colour: nil, result: nil}
          padding = List.duplicate(blank, played - length(games))
          bye = %{opponent_rank: nil, colour: nil, result: type}

          player
          |> Map.put(:games, games ++ padding ++ [bye])
          |> Map.put(:points, (player[:points] || 0.0) + Trf.points_for(type, system))
      end
    end)
  end

  # ---- another point system ------------------------------------------------

  @doc """
  `players` with their totals moved from the point system `from` to `to`.

  A total that is exactly what the games give under `from` becomes exactly
  what they give under `to`; one that is not (free points, an arbiter's
  correction) keeps its difference.
  """
  def rescore(players, from, to) when is_list(players) do
    from = from || Trf.default_point_system()

    Enum.map(players, fn player ->
      games = player[:games] || []
      old = Enum.sum(Enum.map(games, &Trf.points_for_game(&1, from)))
      new = Enum.sum(Enum.map(games, &Trf.points_for_game(&1, to)))
      points = player[:points] || 0.0
      extra = points - old

      Map.put(player, :points, if(abs(extra) < 1.0e-9, do: new / 1, else: new + extra))
    end)
  end
end
