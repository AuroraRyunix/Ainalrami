defmodule Ainalrami.TeamReplay do
  @moduledoc """
  The checker's round replay (`ainalrami input.trf -c`) for a team event:
  each team round re-paired with `Ainalrami.TeamPairing` (C.04.6) from the
  history the file records before it, and compared with the pairing the
  file actually has.

  The individual replay lives in `Ainalrami.CLI` and pairs players with
  `Ainalrami.Pairing`; on a team file that compared the players' boards
  with a Dutch-system pairing of individuals, found every round different
  and exited 1. This module is the team half, and `system/1` is what tells
  the two apart.

  ## Which files are team events (`system/1`)

  A file with team records (`013`, or TRF26 `310`) is not necessarily a team
  event: an individual open routinely lists club teams in `013` lines for a
  team prize. So the `192` type code decides when the file has one:

    * a team Swiss code (`FIDE_TEAM`, `FIDE_TEAM_TYPEA_MP_GP`, ...) - the
      team replay, with the settings the code names (below);
    * a team code this checker cannot replay - a round robin
      (`*_TEAM_ROUNDROBIN`, `*_TEAM_DOUBLEROUNDROBIN`, `BERGER_TEAM_*`), a
      Scheveningen or Schiller (`FIDE_SCHEVENINGEN*`, `FIDE_SCHILLER*`,
      `CUSTOM_*`), a knockout, a custom team Swiss (`CUSTOM_TEAM_SWISS*`) or
      an accelerated one (`*_BAKU`: `Ainalrami.TeamPairing` has no
      acceleration) - `{:unreplayable, reason}`;
    * any other code (an individual system) - the individual replay, the
      team records being a team competition inside an individual event.

  With no `192` the `092` type is read for a round robin, Scheveningen,
  Schiller or knockout (unreplayable, as above), and otherwise the games
  decide: the file is a team event when, in every round, all the players
  of a team who met somebody met players of one and the same other team,
  and that team's players met theirs. An individual event with team
  records does not look like that past its first board.

  ## What a team Swiss code says (reading R1)

  TRF26's Tournament Type Code Table names the team Swiss variants
  `FIDE_TEAM[_TYPEA|_TYPEB][_MP|_GP][_MP|_GP][_BAKU]`. Read here as:

    * `TYPEA` / `TYPEB` - Article 1.7's colour preference type. Without
      either, Type A, which 1.7 makes the default ("Type A colour
      preferences are used unless the rules of the team competition
      specify ...").
    * the first of `MP`/`GP` - the primary score (1.2.1); the second, when
      present, the secondary score used for colour allocation (4.2.2); a
      single one means the secondary score is not used. Without either,
      1.2.2's default: match points primary, game points for colours.

  The table is not in this repository and its descriptions have not been
  checked against this reading. The one alternative that would matter is a
  code without `TYPEA`/`TYPEB` meaning 1.7's third option, "colour
  preferences are not to be used at all", which `Ainalrami.TeamPairing`
  does not implement.

  ## What the file's history says (`history/1`)

  Per team and round, read from the players' games in `310`/`013` order
  (the first player of a team who met somebody is its board 1, as
  `Ainalrami.Tiebreaks.Team.from_trf/2` numbers the boards):

    * **a match** against the team whose players they met. It was *played*
      when at least one board was played over the board; a match where
      every board was forfeited, or a TRF26 `330` record with no board
      records, was paired but not played (C.04.2 3.5: such teams "may be
      paired together in a future round", so it is not an opponent for
      [C1]). The team's colour is its board-1 player's (1.6.1), and a
      `330` record's white and black teams for a match with no boards.
    * **the pairing-allocated bye** - its players' `U` (or `+` with no
      opponent), or the team named for the round in a `320` record.
    * **out** of the round's pairing otherwise - sat it out, not yet
      arrived, or withdrawn.

  Match and game points are `Ainalrami.Tiebreaks.Team.from_trf/2`'s, the
  same reading the standings check uses (`362`, `320`, `330`). A team
  "won a match by forfeit" ([C2]) when that reading makes it a forfeit win -
  no board played and more game points, or a `330` record - OpenPairings'
  reading of open question 6. A team whose players all hold an `F` has a
  full-point bye, which [C2] also bars from the pairing-allocated bye.

  ## Replaying a round (`check_round/4`)

  The field is the teams the file pairs in that round (a match or the
  bye). A team out of the round that was paired in an earlier one is
  passed as `:absent`, keeping its place in 4.3.1's numbering. Each team's
  `%Ainalrami.TeamPairing.Team{}`: points so far, opponents of played
  matches, board-1 colours of played matches, whether it had the bye or won
  a match by forfeit, and whether it floated in the previous round -
  paired, played or not, against a team on a different primary score
  (1.5). The round number and the file's `142` round count switch [C7],
  [C10] and Type B's mild preferences off at the end, as the engine does.

  A round is compared in composition (who meets whom, who has the bye) and
  in colours (the team with White on board 1). Unlike the individual
  replay, a colour difference counts: Article 4 decides every team colour
  from the initial colour, and the initial colour is the file's `152`, or,
  when it has none, the one of White and Black that reproduces more of
  round 1's colours (4.3.1 gives round 1's colours from it alone).
  """

  alias Ainalrami.TeamPairing
  alias Ainalrami.TeamPairing.Team
  alias Ainalrami.Tiebreaks

  @type settings :: %{
          type: :a | :b,
          score_mode: :match_points | :game_points,
          use_secondary?: boolean(),
          code: String.t() | nil
        }

  @defaults %{type: :a, score_mode: :match_points, use_secondary?: true, code: nil}

  # ---- which replay --------------------------------------------------------

  @doc """
  How the checker replays this parsed file: `:individual`,
  `{:team, settings}` or `{:unreplayable, reason}`. See the moduledoc.
  """
  def system(%{teams: []}), do: :individual

  def system(%{tournament: tournament} = parsed) do
    code =
      case tournament[:type_code] do
        code when is_binary(code) and code != "" -> code |> String.trim() |> String.upcase()
        _ -> nil
      end

    cond do
      is_nil(code) -> system_without_code(parsed, tournament[:type])
      reason = unreplayable(code) -> {:unreplayable, reason}
      settings = team_swiss(code) -> {:team, settings}
      true -> :individual
    end
  end

  defp system_without_code(parsed, type) do
    type = String.downcase(to_string(type || ""))

    cond do
      String.contains?(type, "robin") ->
        {:unreplayable,
         "the file's type (092) is a round robin, whose pairings are predetermined"}

      String.contains?(type, "scheveningen") or String.contains?(type, "schiller") ->
        {:unreplayable,
         "the file's type (092) is a Scheveningen or Schiller event, whose pairings are " <>
           "predetermined"}

      String.contains?(type, "knock") ->
        {:unreplayable, "the file's type (092) is a knockout, which is not a Swiss"}

      team_structured?(parsed) ->
        {:team, @defaults}

      true ->
        :individual
    end
  end

  # The codes this checker recognises as team events it cannot replay, and
  # why. nil for anything else.
  defp unreplayable(code) do
    cond do
      Regex.match?(~r/^(FIDE|BERGER|CUSTOM)_TEAM_(DOUBLE)?ROUNDROBIN/, code) ->
        "#{code} is a team round robin, whose pairings are predetermined (Berger tables), " <>
          "not paired round by round"

      String.starts_with?(code, "FIDE_SCHEVENINGEN") or code == "CUSTOM_SCHEVENINGEN" or
          String.starts_with?(code, "FIDE_DOUBLESCHEVENINGEN") ->
        "#{code} is a Scheveningen event, whose pairings are predetermined"

      String.starts_with?(code, "FIDE_SCHILLER") or code == "CUSTOM_SCHILLER" ->
        "#{code} is a Schiller event, whose pairings are predetermined"

      code == "CUSTOM_TEAM_KNOCKOUT" ->
        "#{code} is a knockout, not a Swiss"

      String.starts_with?(code, "CUSTOM_TEAM_SWISS") ->
        "#{code} is a custom team Swiss - a system of the competition's own, not C.04.6"

      String.starts_with?(code, "FIDE_TEAM") and String.ends_with?(code, "_BAKU") ->
        "#{code} is an accelerated team Swiss, and the C.04.6 engine has no acceleration"

      true ->
        nil
    end
  end

  # `FIDE_TEAM[_TYPEA|_TYPEB][_MP|_GP][_MP|_GP]` - reading R1 in the moduledoc.
  defp team_swiss(code) do
    case Regex.run(~r/^FIDE_TEAM(?:_TYPE([AB]))?(?:_(MP|GP))?(?:_(MP|GP))?$/, code) do
      nil ->
        nil

      [_ | groups] ->
        [type, first, second] = groups ++ List.duplicate("", 3 - length(groups))

        if first != "" and first == second do
          nil
        else
          %{
            type: if(type == "B", do: :b, else: :a),
            score_mode: if(first == "GP", do: :game_points, else: :match_points),
            use_secondary?: first == "" or second != "",
            code: code
          }
        end
    end
  end

  @doc "A one-line description of `settings`, for the trace."
  def describe(%{} = s) do
    {primary, secondary} =
      case s.score_mode do
        :match_points -> {"match points", "game points"}
        :game_points -> {"game points", "match points"}
      end

    colours =
      if s.use_secondary?,
        do: "#{secondary} for colours",
        else: "no secondary score for colours"

    type = if s.type == :b, do: "Type B", else: "Type A"
    source = if s.code, do: " (192 #{s.code})", else: " (no 192: the C.04.6 defaults)"

    "C.04.6, #{type} colour preferences, #{primary} primary, #{colours}#{source}"
  end

  # Every round's matches are team against team - see the moduledoc.
  defp team_structured?(parsed) do
    {rosters, team_of} = rosters(parsed)
    by_rank = Map.new(parsed.players, &{&1.rank, &1})
    rounds = parsed.players |> Enum.map(&length(&1.games)) |> Enum.max(fn -> 0 end)

    opponents =
      for r <- 1..rounds//1, {team, ranks} <- rosters, into: %{} do
        met =
          for rank <- ranks,
              player = by_rank[rank],
              player != nil,
              game = Enum.at(player.games, r - 1),
              game != nil,
              is_integer(game.opponent_rank),
              do: team_of[game.opponent_rank]

        {{team, r}, Enum.uniq(met)}
      end

    matches = Enum.count(opponents, fn {_key, met} -> met != [] end)

    matches > 0 and
      Enum.all?(opponents, fn
        {_key, []} ->
          true

        {{team, r}, [other]} when is_integer(other) and other != team ->
          opponents[{other, r}] == [team]

        _ ->
          false
      end)
  end

  # `310` teams keep their number; `013` teams are numbered in file order,
  # as `Tiebreaks.Team.from_trf/2` numbers them.
  defp rosters(parsed) do
    rosters =
      parsed.teams
      |> Enum.with_index(1)
      |> Enum.map(fn {team, index} -> {Map.get(team, :number) || index, team.player_ranks} end)

    team_of = for {id, ranks} <- rosters, rank <- ranks, into: %{}, do: {rank, id}
    {rosters, team_of}
  end

  # ---- the file's history --------------------------------------------------

  @doc """
  Every team's rounds as the file records them: `%{tpn => %{round => record}}`,
  a record being `%{kind: :match | :pab | :out, opponent:, played?:,
  colour: :white | :black | nil, mp:, gp:, forfeit_win?:, full_bye?:}`.
  See the moduledoc.
  """
  def history(parsed) do
    {rosters, team_of} = rosters(parsed)
    event = Tiebreaks.Team.from_trf(parsed)
    individual = Tiebreaks.Event.from_trf(parsed, rounds: event.rounds)
    tournament = parsed.tournament

    declared =
      for f <- tournament[:forfeited_matches] || [],
          is_integer(f[:round]) and is_integer(f[:white]) and is_integer(f[:black]),
          do: f

    pab_by_round = get_in(tournament, [:team_pab, :teams]) || []

    Map.new(rosters, fn {team, ranks} ->
      rounds =
        Map.new(1..event.rounds//1, fn r ->
          rounds =
            for rank <- ranks,
                participant = individual.participants[rank],
                participant != nil,
                do: participant.rounds[r]

          points = event.teams[team].rounds[r]

          record =
            read_round(rounds, team, r, team_of, declared, Enum.at(pab_by_round, r - 1))
            |> Map.merge(%{
              mp: points.mp * 1.0,
              gp: points.gp * 1.0,
              forfeit_win?: points.kind == :forfeit_win
            })

          {r, record}
        end)

      {team, rounds}
    end)
  end

  defp read_round(rounds, team, r, team_of, declared, pab_team) do
    # A game against a player on no team's roster says nothing about which
    # team this one met.
    met = Enum.filter(rounds, &(&1.opponent != nil and Map.has_key?(team_of, &1.opponent)))

    base = %{kind: :out, opponent: nil, played?: false, colour: nil, full_bye?: false}

    case met do
      [] ->
        found =
          Enum.find_value(declared, fn
            %{round: ^r, white: ^team, black: other} -> {other, :white}
            %{round: ^r, white: other, black: ^team} -> {other, :black}
            _ -> nil
          end)

        cond do
          found ->
            {other, colour} = found
            %{base | kind: :match, opponent: other, colour: colour}

          pab_team == team or Enum.any?(rounds, &(&1.kind == :pab)) ->
            %{base | kind: :pab}

          rounds != [] and Enum.all?(rounds, &(&1.kind == :full_bye)) ->
            %{base | full_bye?: true}

          true ->
            base
        end

      _ ->
        opponent =
          met
          |> Enum.frequencies_by(&team_of[&1.opponent])
          |> Enum.max_by(fn {_team, n} -> n end)
          |> elem(0)

        %{
          base
          | kind: :match,
            opponent: opponent,
            played?: Enum.any?(met, &(&1.kind == :played)),
            colour: Enum.find_value(met, & &1.colour)
        }
    end
  end

  @doc "The last round in which the file pairs any team, 0 if none."
  def paired_rounds(history) do
    history
    |> Enum.flat_map(fn {_team, rounds} ->
      for {r, %{kind: kind}} <- rounds, kind in [:match, :pab], do: r
    end)
    |> Enum.max(fn -> 0 end)
  end

  # ---- one round -----------------------------------------------------------

  @doc """
  The file's pairing of `round`: `{pairs, bye}`, each pair
  `{white, black, colour_known?}` (lower number first when the colours are
  not known).
  """
  def recorded(history, round) do
    records = Map.new(history, fn {team, rounds} -> {team, rounds[round]} end)

    pairs =
      records
      |> Enum.filter(fn {_team, rec} -> rec.kind == :match end)
      |> Enum.map(fn {team, rec} ->
        theirs = records[rec.opponent]

        cond do
          rec.colour == :white and (theirs == nil or theirs.colour != :white) ->
            {team, rec.opponent, true}

          rec.colour == :black and (theirs == nil or theirs.colour != :black) ->
            {rec.opponent, team, true}

          rec.colour == nil and theirs != nil and theirs.colour == :black ->
            {team, rec.opponent, true}

          rec.colour == nil and theirs != nil and theirs.colour == :white ->
            {rec.opponent, team, true}

          true ->
            {min(team, rec.opponent), max(team, rec.opponent), false}
        end
      end)
      |> Enum.uniq_by(fn {a, b, _} -> Enum.sort([a, b]) end)
      |> Enum.sort()

    bye = Enum.find_value(records, fn {team, rec} -> if rec.kind == :pab, do: team end)

    {pairs, bye}
  end

  @doc """
  The engine's input for `round`: `{teams, absent}` - the
  `%Ainalrami.TeamPairing.Team{}` of every team the file pairs in the
  round, and the teams paired earlier but out of this round.
  """
  def state_before(history, round, settings) do
    field =
      for {team, rounds} <- history, rounds[round].kind in [:match, :pab], do: team

    teams =
      for team <- Enum.sort(field) do
        earlier = earlier(history[team], round)
        played = Enum.filter(earlier, &(&1.kind == :match and &1.played?))

        %Team{
          tpn: team,
          match_points: total(earlier, :mp),
          game_points: total(earlier, :gp),
          opponents: Enum.map(played, & &1.opponent),
          colours: played |> Enum.map(& &1.colour) |> Enum.reject(&is_nil/1),
          matches_played: length(played),
          had_pab?: Enum.any?(earlier, &(&1.kind == :pab)),
          won_by_forfeit?: Enum.any?(earlier, &(&1.forfeit_win? or &1.full_bye?)),
          floated_last_round?: floated?(history, team, round - 1, settings.score_mode)
        }
      end

    absent =
      for {team, rounds} <- history,
          team not in field,
          Enum.any?(earlier(rounds, round), &(&1.kind in [:match, :pab])),
          do: team

    {teams, Enum.sort(absent)}
  end

  defp earlier(rounds, round),
    do: for(r <- 1..(round - 1)//1, rec = rounds[r], rec != nil, do: rec)

  defp total(records, key), do: records |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sum() |> tidy()

  defp tidy(x), do: Float.round(x * 1.0, 6)

  # 1.5: paired in `previous` against a team on a different score before
  # it - the pairing floats a team, whether the match was then played.
  defp floated?(_history, _team, previous, _mode) when previous < 1, do: false

  defp floated?(history, team, previous, mode) do
    case history[team][previous] do
      %{kind: :match, opponent: other} when is_map_key(history, other) ->
        key = if mode == :game_points, do: :gp, else: :mp
        score = fn t -> total(earlier(history[t], previous), key) end
        score.(team) != score.(other)

      _ ->
        false
    end
  end

  @doc """
  Replays `round` and compares it with the file. Returns

    * `{:ok, file}` - same pairing, same colours;
    * `{:colours, file, engine, differing}` - same pairing, the colours of
      the `differing` matches (the file's `{white, black}`) not;
    * `{:differs, file, engine}` - a different pairing;
    * `{:no_pairing, reason}` - the engine refused the round.

  `file` and `engine` are `[{white, black}]` plus `{bye, nil}`, sorted.
  Options: `:initial_colour` (`:white` default), `:expected_rounds`.
  """
  def check_round(history, round, settings, opts \\ []) do
    {teams, absent} = state_before(history, round, settings)
    {pairs, bye} = recorded(history, round)

    engine_opts = [
      score_mode: settings.score_mode,
      use_secondary?: settings.use_secondary?,
      type: settings.type,
      initial_colour: Keyword.get(opts, :initial_colour, :white),
      absent: absent,
      round: round,
      expected_rounds: Keyword.get(opts, :expected_rounds)
    ]

    file = Enum.sort(Enum.map(pairs, fn {w, b, _} -> {w, b} end) ++ bye_entry(bye))

    case TeamPairing.pair_round(teams, engine_opts) do
      {:ok, result} ->
        engine =
          Enum.sort(Enum.map(result.pairs, &{&1.white, &1.black}) ++ bye_entry(result.bye))

        if composition(file) != composition(engine) do
          {:differs, file, engine}
        else
          engine_set = MapSet.new(engine)

          differing =
            for {w, b, true} <- pairs, not MapSet.member?(engine_set, {w, b}), do: {w, b}

          if differing == [], do: {:ok, file}, else: {:colours, file, engine, differing}
        end

      {:error, reason} ->
        {:no_pairing, reason}
    end
  end

  defp bye_entry(nil), do: []
  defp bye_entry(team), do: [{team, nil}]

  defp composition(pairs) do
    pairs
    |> Enum.map(fn {a, b} -> Enum.sort_by([a, b], &(&1 || :infinity)) end)
    |> Enum.sort()
  end

  @doc """
  The initial colour (4.1) to replay with: the file's `152` when it has
  one (`{colour, :file}`), else whichever of White and Black reproduces
  more of round 1's colours (`{colour, :inferred}`), White on a tie.
  """
  def initial_colour(history, tournament, settings, opts \\ []) do
    case tournament[:initial_colour] do
      c when c in ["w", "W"] ->
        {:white, :file}

      c when c in ["b", "B"] ->
        {:black, :file}

      _ ->
        misses = fn colour ->
          case check_round(history, 1, settings, Keyword.put(opts, :initial_colour, colour)) do
            {:ok, _} -> 0
            {:colours, _, _, differing} -> length(differing)
            _ -> :infinity
          end
        end

        if paired_rounds(history) >= 1 and misses.(:black) < misses.(:white),
          do: {:black, :inferred},
          else: {:white, :inferred}
    end
  end
end
