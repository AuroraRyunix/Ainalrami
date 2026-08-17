defmodule OpenPair.Trf.ValidationError do
  @moduledoc """
  Raised by `OpenPair.Trf` when a player's round-by-round game data contains
  an illegal FIDE result: an unrecognized result code, or a result that is
  inconsistent with the opponent's own recorded result for the same round
  (e.g. both sides claim a win, or both sides are marked forfeit-win).
  """
  defexception [:message]
end

defmodule OpenPair.Trf do
  @moduledoc """
  FIDE TRF16 (Tournament Report File) serializer and parser, per the official
  specification: https://www.fide.com/FIDE/handbook/C04Annex2_TRF16.pdf

  All column positions are 1-indexed and inclusive, exactly as printed in the
  spec. This is OpenPair's file format for both directions: the roster/result
  history it's asked to pair, and the paired output it writes back — same
  format JaVaFo itself reads and writes, so a TRF file built for one engine
  works unmodified for the other.

  Both `serialize/1` and `parse/1` validate every player's per-round result
  codes before returning, raising `OpenPair.Trf.ValidationError` on an
  unrecognized code or an illegal combination between two opponents (see
  `validate_games!/2`). Validation only cross-checks a pairing when both
  sides are present in the given player set and mutually reference each
  other for that round — a lone/dangling reference is not itself an error.

  Ported from the sibling project (`AuroraRyunix/openpairings`)'s own
  `PairingsEngine.Trf`, which fixed two real bugs against FIDE's actual
  archived TRF06 specs (Annexure-B/2006, Annexure-C/2016) — the
  `allow_dangling_playing_code` tolerance and the `parse_games/1` blank-round
  handling below both come directly from that work, not reinvented here.

  ## The `XX*` extension lines

  Three of JaVaFo's own `XX` extension codes are read and written:

    * `XXR n` — the round count (see `parse_xxr/2`).
    * `XXP a b [c ...]` — a mutually-forbidden GROUP of players
      (see `parse_xxp/2`), surfaced as `tournament[:forbidden_pairs]`.
    * `XXA` — per-player acceleration/virtual points, round by round
      (see `parse_xxa/2`), surfaced as each player's `:accelerations`.

  Anything else beginning `XX` still falls through `parse_header_line/3`'s
  `nil -> acc` clause and is ignored. That silent-discard behaviour is
  correct for a genuinely unknown code and was WRONG for these two: an
  arbiter's `XXP` "these two must never meet" was dropped on the floor and
  the engine then returned a complete, perfectly legal-looking pairing that
  seated them together, with nothing downstream able to detect it. That is
  why the sibling project had to refuse to pair any TRF carrying a
  non-`XXR` `XX` line at all.

  For the same reason, a MALFORMED `XXP`/`XXA` line raises
  `OpenPair.Trf.ValidationError` rather than being skipped — see
  `parse_xxp/2`. bbpPairings does the same (`InvalidLineException`, exit
  code 3); `parse_xxr/2`'s shrug is the exception, and it can afford one
  because a missing round count has a fallback and a missing exclusion
  does not.
  """

  alias OpenPair.Trf.ValidationError

  @player_cols %{
    code: {1, 3},
    starting_rank: {5, 8},
    sex: {10, 10},
    title: {11, 13},
    name: {15, 47},
    fide_rating: {49, 52},
    federation: {54, 56},
    fide_number: {58, 68},
    birth_date: {70, 79},
    points: {81, 84},
    rank: {86, 89}
  }

  @team_cols %{code: {1, 3}, name: {5, 36}}

  @header_codes %{
    name: "012",
    city: "022",
    federation: "032",
    start_date: "042",
    end_date: "052",
    number_of_players: "062",
    number_of_rated_players: "072",
    number_of_teams: "082",
    type: "092",
    chief_arbiter: "102",
    deputy_arbiter: "112",
    time_control: "122",
    # Not in the official TRF16 spec, but real-world precedent from
    # Swiss-Manager (which already emits both) — optional/additive, an
    # unrecognized header code is already silently ignored by
    # `parse_header_line/3`, so including them never breaks a TRF16-only
    # reader.
    number_of_rounds: "142",
    round_dates: "132",
    generator: "182"
  }

  @type_labels %{
    "swiss" => "Individual: Swiss System",
    "roundrobin" => "Individual: Round Robin System",
    "team-swiss" => "Team: Swiss System",
    "team-roundrobin" => "Team: Round Robin System"
  }

  @result_codes %{
    win: "1",
    draw: "=",
    loss: "0",
    forfeit_win: "+",
    forfeit_loss: "-",
    half_point_bye: "H",
    full_point_bye: "F",
    pairing_allocated_bye: "U",
    zero_point_bye: "Z"
  }

  def result_codes, do: @result_codes

  @doc """
  What a single result code is worth under the standard 1 / ½ / 0 system.

  Byes differ: a pairing-allocated bye (`U`), a full-point bye (`F`) and a
  forfeit win (`+`) all pay a full point, a half-point bye (`H`) pays a
  half, and a zero-point bye (`Z`) or forfeit loss (`-`) pays nothing.
  """
  def points_for(result) when result in ~w(1 + F U W), do: 1.0
  def points_for(result) when result in ~w(= H D), do: 0.5
  def points_for(_result), do: 0.0

  @doc """
  Whether the player took part in the PAIRING for this game, as opposed to
  having a result recorded for them without being paired.

  This is what distinguishes an arbiter-assigned bye (half-point,
  zero-point, full-point — granted before the round is paired, so the
  player is left out of it) from a pairing-allocated bye, which the
  pairing itself produced. bbpPairings expresses the same test as
  `opponent != id || resultChar == 'U' || resultChar == '+'`
  (`fileformats/trf.cpp:303`).
  """
  def participated_in_pairing?(game) do
    not is_nil(game.opponent_rank) or game.result in ~w(U +)
  end

  # TRF16 result codes for an actually-contested game (win/draw/loss/forfeit)
  # vs. an unpaired round (byes of every kind). A forfeit is legally
  # "unplayed" per FIDE Art. 16, but it still occupies a pairing slot (an
  # opponent), unlike a bye — so the two groups get different validation.
  @playing_codes ~w(1 = 0 + -)
  @bye_codes ~w(H F U Z)

  # Legal opponent-result for each of this player's playing codes. A win
  # ("1") only pairs with a loss ("0"); a played "0-0" (both players lose,
  # e.g. both defaulted after making moves) is two losses, so "0" also
  # legally pairs with "0". A double forfeit is "-"/"-"; a single forfeit is
  # "+"/"-". A draw ("=") also legally pairs with a loss ("0") — an
  # asymmetric ½-0/0-½ (an arbiter's disciplinary point adjustment on an
  # otherwise-drawn game, not a chess outcome the TRF spec itself
  # distinguishes with its own code — it's still just "=" and "0" per
  # player, only no longer required to mirror). Anything else (both win,
  # both forfeit-win, a win against a draw, etc.) is impossible and
  # rejected.
  @legal_result_pairs %{
    "1" => ["0"],
    "0" => ["1", "0", "="],
    "=" => ["=", "0"],
    "+" => ["-"],
    "-" => ["+", "-"]
  }

  # Round blocks repeat every 10 columns starting at column 92 (round 1):
  # opponent id at base..base+3, colour at base+5, result at base+7.
  defp round_cols(round) do
    base = 92 + (round - 1) * 10
    %{id: {base, base + 3}, colour: {base + 5, base + 5}, result: {base + 7, base + 7}}
  end

  # The "132" round-dates line uses the same cadence with 8-char YY/MM/DD slots.
  defp round_date_cols(round) do
    base = 92 + (round - 1) * 10
    {base, base + 7}
  end

  # Team player slots repeat every 5 columns starting at column 37.
  defp team_player_cols(slot) do
    base = 37 + (slot - 1) * 5
    {base, base + 3}
  end

  # `XXA` is FIXED-COLUMN, unlike the free-form `XXR`/`XXP` extension lines
  # next to it, and the columns are not negotiable in either direction.
  #
  # bbpPairings' `readPlayerAccelerationsXxa` (`trf.cpp:487-514`) reads the
  # starting rank from `line[4]..line[8)` — 0-indexed, so columns 5-8 — and
  # then walks `startIndex = 9; startIndex += 5`, reading four characters at
  # each stop: columns 10-13, 15-18, 20-23, i.e. `10 + 5*(r-1)` for round
  # `r`, with a single separator column between fields. That is exactly the
  # JaVaFo 2.2 Advanced User Manual's own spec ("XXA NNNN pp.p pp.p ...",
  # `NNNN` at column 5, each `pp.p` at column `10 + 5*(r-1)`).
  #
  # The sibling project confirmed by direct experiment that free-form `XXA`
  # crashes real javafo with a bare NullPointerException while the
  # fixed-column form runs clean — see `acceleration_lines/4`'s docs in
  # `../openpairings`. Its own emitter, however, right-aligns the rank in a
  # FIVE-column field (cols 5-9) and each value in a five-column field
  # (10-14, 15-19, ...), which is one column wider than the spec at every
  # stop; javafo evidently tolerates that, bbpPairings does not (it reads
  # four blanks where the rank should be). The widths below are the spec's,
  # and are what bbpPairings actually round-trips.
  @xxa_rank_cols {5, 8}

  defp xxa_points_cols(round) do
    base = 10 + (round - 1) * 5
    {base, base + 3}
  end

  ## ---------- Serializing ----------

  @doc """
  Serializes to TRF16 text.

      serialize(%{
        tournament: %{name: ..., city: ..., type: "swiss", ...},
        players: [%{rank: 1, name: ..., points: 2.5,
                    games: [%{opponent_rank: 2, colour: "w", result: "1"}]}],
        teams: [%{name: ..., player_ranks: [1, 2]}]
      })

  `opts[:column_legend]`: when true, inserts the ruler/field-code lines
  Swiss-Manager prepends to its own TRF exports (a `DDD SSSS sTTT NNN...`
  legend plus two column-position rulers) right before the player rows —
  purely a human-readability courtesy, no header code of its own, and
  safely ignored by any TRF16 reader (including `parse/1`, since these
  lines don't start with a recognized 3-digit code). Off by default.

  A player carrying `:accelerations` (a list of virtual-point values, one
  per round from round 1) gets an `XXA` line, and
  `tournament[:forbidden_pairs]` (a list of mutually-forbidden starting-rank
  GROUPS) becomes one `XXP` line per group. Both are emitted after the
  player/team rows, and both round-trip through `parse/1`.
  """
  def serialize(data, opts \\ [])

  def serialize(%{tournament: t, players: players} = data, opts) do
    validate_games!(players)
    teams = Map.get(data, :teams, [])
    max_round = Enum.reduce(players, 0, &max(&2, length(&1[:games] || [])))

    header_lines(t, players, teams)
    |> Kernel.++(legend_lines(opts[:column_legend], max_round))
    |> Kernel.++(Enum.map(players, &player_line/1))
    |> Kernel.++(Enum.map(teams, &team_line/1))
    |> Kernel.++(acceleration_lines(players))
    |> Kernel.++(forbidden_pair_lines(t[:forbidden_pairs]))
    |> Enum.map_join("", &(&1 <> "\r\n"))
  end

  defp acceleration_lines(players) do
    players
    |> Enum.filter(&(&1[:accelerations] not in [nil, []]))
    |> Enum.map(&acceleration_line/1)
  end

  defp acceleration_line(player) do
    player[:accelerations]
    |> Enum.with_index(1)
    |> Enum.reduce(
      [] |> place({1, 3}, "XXA") |> place(@xxa_rank_cols, player[:rank], align: :right),
      fn {points, round}, acc ->
        place(acc, xxa_points_cols(round), format_points(points), align: :right)
      end
    )
    |> render()
  end

  # Free-form, matching `readForbiddenPairsXxp` (`trf.cpp:554-568`): it
  # takes `line.substr(3)` and tokenizes on space/tab, so the whole line
  # after the code is just a list of starting ranks. A group of N ids
  # forbids every pair WITHIN it, not merely the first two.
  defp forbidden_pair_lines(nil), do: []

  defp forbidden_pair_lines(groups) do
    groups
    |> Enum.reject(&(length(&1) < 2))
    |> Enum.map(&("XXP " <> Enum.join(&1, " ")))
  end

  defp legend_lines(true, max_round) when max_round > 0 do
    legend = legend_line(max_round)
    width = String.length(legend)
    ["", ruler_line(width, :tens), ruler_line(width, :units), legend]
  end

  defp legend_lines(_, _), do: []

  defp legend_line(max_round) do
    []
    |> place(@player_cols.code, "DDD")
    |> place(@player_cols.starting_rank, "SSSS")
    |> place(@player_cols.sex, "s")
    |> place(@player_cols.title, "TTT")
    |> place(@player_cols.name, String.duplicate("N", 33))
    |> place(@player_cols.fide_rating, "RRRR")
    |> place(@player_cols.federation, "FFF")
    |> place(@player_cols.fide_number, String.duplicate("I", 11))
    |> place(@player_cols.birth_date, "BBBB/BB/BB")
    |> place(@player_cols.points, "PPPP")
    |> place(@player_cols.rank, "RRRR")
    |> legend_games(max_round)
    |> render()
  end

  defp legend_games(acc, max_round) do
    Enum.reduce(1..max_round, acc, fn round, acc ->
      cols = round_cols(round)
      digit = round |> Integer.to_string() |> String.last()

      acc
      |> place(cols.id, String.duplicate(digit, 4))
      |> place(cols.colour, digit)
      |> place(cols.result, digit)
    end)
  end

  # `:tens` marks every 10th column with its running count (e.g. "1" ending
  # at column 10, "18" ending at column 180); `:units` repeats "1234567890"
  # across the full width — together, a standard fixed-width column ruler.
  defp ruler_line(width, :tens) do
    Enum.reduce(10..width//10, List.duplicate(" ", width), fn col, acc ->
      label = col |> div(10) |> Integer.to_string()
      start = col - String.length(label)

      label
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {ch, i}, acc2 -> List.replace_at(acc2, start + i, ch) end)
    end)
    |> Enum.join()
  end

  defp ruler_line(width, :units) do
    1..width |> Enum.map_join("", &Integer.to_string(rem(&1, 10)))
  end

  defp header_lines(t, players, teams) do
    [
      header(:name, t[:name]),
      header(:city, t[:city]),
      header(:federation, t[:federation]),
      header(:start_date, slash_date(t[:start_date])),
      header(:end_date, slash_date(t[:end_date])),
      header(:number_of_players, length(players)),
      t[:number_of_rated_players] && header(:number_of_rated_players, t[:number_of_rated_players]),
      # Always emitted (082), even 0 for an individual tournament.
      header(:number_of_teams, length(teams)),
      header(:type, t[:type] && Map.get(@type_labels, t[:type], t[:type])),
      header(:chief_arbiter, t[:chief_arbiter])
    ]
    |> Kernel.++(Enum.map(t[:deputy_arbiters] || [], &header(:deputy_arbiter, &1)))
    |> Kernel.++([
      header(:time_control, t[:time_control]),
      header(:number_of_rounds, t[:number_of_rounds]),
      round_dates_line(t[:round_dates]),
      header(:generator, t[:generator])
    ])
    |> Enum.reject(&(&1 in [nil, false]))
  end

  defp header(_field, value) when value in [nil, ""], do: nil
  defp header(field, value), do: String.trim_trailing("#{@header_codes[field]} #{value}")

  defp round_dates_line(nil), do: nil
  defp round_dates_line([]), do: nil

  defp round_dates_line(dates) do
    # Only emit the line at all if at least one round actually has a date —
    # a list of all-nil/blank entries means "no round dates", same as [].
    if Enum.all?(dates, &(&1 in [nil, ""])) do
      nil
    else
      dates
      |> Enum.with_index(1)
      |> Enum.reduce(place([], {1, 3}, "132"), fn {date, i}, acc ->
        place(acc, round_date_cols(i), short_slash_date(date))
      end)
      |> render()
    end
  end

  defp player_line(p) do
    games = p[:games] || []

    []
    |> place(@player_cols.code, "001")
    |> place(@player_cols.starting_rank, p[:rank], align: :right)
    |> place(@player_cols.sex, trf_sex(p[:sex]))
    |> place(@player_cols.title, p[:title])
    |> place(@player_cols.name, p[:name])
    |> place(@player_cols.fide_rating, blank_if_falsy(p[:fide_rating]), align: :right)
    |> place(@player_cols.federation, p[:federation])
    |> place(@player_cols.fide_number, blank_if_falsy(p[:fide_number]), align: :right)
    |> place(@player_cols.birth_date, slash_date(p[:birth_date]))
    |> place(@player_cols.points, format_points(p[:points]), align: :right)
    |> place(@player_cols.rank, p[:rank], align: :right)
    |> place_games(games)
    |> render()
  end

  defp place_games(acc, games) do
    games
    |> Enum.with_index(1)
    |> Enum.reduce(acc, fn {g, i}, acc ->
      cols = round_cols(i)

      acc
      |> place(cols.id, g[:opponent_rank] || "0000", align: :right)
      |> place(cols.colour, g[:colour] || "-")
      |> place(cols.result, g[:result] || "")
    end)
  end

  defp team_line(t) do
    (t[:player_ranks] || [])
    |> Enum.with_index(1)
    |> Enum.reduce(
      [] |> place(@team_cols.code, "013") |> place(@team_cols.name, t[:name]),
      fn {rank, slot}, acc -> place(acc, team_player_cols(slot), rank, align: :right) end
    )
    |> render()
  end

  # Placements are collected as {start_col, text} and rendered in one pass.
  defp place(placements, {start_col, end_col}, value, opts \\ []) do
    width = end_col - start_col + 1

    text =
      (value || "")
      |> to_string()
      |> strip_controls()
      |> String.slice(0, width)
      |> then(fn s ->
        if opts[:align] == :right,
          do: String.pad_leading(s, width),
          else: String.pad_trailing(s, width)
      end)

    [{start_col, text} | placements]
  end

  # TRF is line- and column-oriented: a newline, carriage return or tab
  # inside a field (a player name has no format check beyond length) would
  # split or shift the fixed-width row — control characters are flattened
  # to spaces before the value is placed.
  defp strip_controls(text), do: String.replace(text, ~r/[\x00-\x1F\x7F]/, " ")

  defp render(placements) do
    placements
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({[], 1}, fn {start, text}, {io, pos} ->
      {[io, String.duplicate(" ", max(start - pos, 0)), text], start + String.length(text)}
    end)
    |> elem(0)
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
  end

  defp trf_sex(s) when s in ["w", "W", "f", "F"], do: "w"
  defp trf_sex(s) when s in [nil, ""], do: ""
  defp trf_sex(_), do: "m"

  defp blank_if_falsy(v) when v in [nil, 0, ""], do: ""
  defp blank_if_falsy(v), do: v

  defp format_points(nil), do: "0.0"
  defp format_points(points), do: :erlang.float_to_binary(points / 1, decimals: 1)

  # yyyy-mm-dd -> yyyy/mm/dd
  defp slash_date(nil), do: nil
  defp slash_date(""), do: nil
  defp slash_date(date), do: String.replace(date, "-", "/")

  # yyyy-mm-dd -> yy/mm/dd (required for the "132" round-dates line)
  defp short_slash_date(date) do
    case String.split(date || "", "-") do
      [y, m, d] -> "#{String.slice(y, -2, 2)}/#{m}/#{d}"
      _ -> ""
    end
  end

  ## ---------- Result validation ----------

  # Validates every player's per-round result code, raising ValidationError
  # naming the player and round on the first illegal one found. Games with
  # no result yet (nil/"") are skipped. A code is checked two ways:
  #   1. It must be a recognized TRF16 result code at all.
  #   2. If it's a "playing" code (win/draw/loss/forfeit) and the opponent
  #      for that round is resolvable in `players` *and* mutually references
  #      this player back, the two codes must be a legal pair (see
  #      `@legal_result_pairs`). An unresolvable/dangling opponent reference
  #      is not itself flagged — the caller may be validating a partial
  #      roster.
  #
  # `opts[:allow_dangling_playing_code]` relaxes the "opponent 0000 needs a
  # bye code (F/H/Z/U)" rule below — those four codes didn't exist before
  # TRF16 (FIDE's Annexure-B, the 2006 spec: only 1/=/0/+/-/blank, a bye
  # represented as a dangling playing code against 0000, no dedicated bye
  # code at all). That rule protects OUR OWN pairing-output construction (a
  # dangling playing code there is a real crash risk downstream), which only
  # matters on the way OUT (`serialize/1`); a file we're reading FROM
  # someone else, possibly TRF06-vintage, is exactly what this option
  # exists for — `parse/1` passes it, `serialize/1` never does.
  defp validate_games!(players, opts \\ []) do
    by_rank = Map.new(players, &{&1[:rank], &1})

    for player <- players,
        {game, round} <- Enum.with_index(player[:games] || [], 1) do
      validate_game!(player, round, game, by_rank, opts)
    end

    :ok
  end

  defp validate_game!(_player, _round, %{result: result}, _by_rank, _opts)
       when result in [nil, ""],
       do: :ok

  defp validate_game!(player, round, %{result: result} = game, by_rank, opts) do
    cond do
      result not in (@playing_codes ++ @bye_codes) ->
        raise ValidationError,
          message:
            "#{player_label(player)}, round #{round}: unrecognized TRF result code #{inspect(result)}"

      result in @playing_codes and is_nil(game[:opponent_rank]) and
          !opts[:allow_dangling_playing_code] ->
        raise ValidationError,
          message:
            "#{player_label(player)}, round #{round}: opponent 0000 cannot carry played-game result " <>
              "#{inspect(result)} — opponentless games must use a bye code (F/H/Z/U)"

      result in @playing_codes ->
        validate_playing_pair!(player, round, game, by_rank, result)

      true ->
        :ok
    end
  end

  defp validate_playing_pair!(player, round, game, by_rank, result) do
    with opp_rank when not is_nil(opp_rank) <- game[:opponent_rank],
         opponent when not is_nil(opponent) <- Map.get(by_rank, opp_rank),
         opp_game when not is_nil(opp_game) <- Enum.at(opponent[:games] || [], round - 1),
         true <- opp_game[:opponent_rank] == player[:rank],
         opp_result when opp_result not in [nil, ""] <- opp_game[:result] do
      unless opp_result in Map.get(@legal_result_pairs, result, []) do
        raise ValidationError,
          message:
            "#{player_label(player)} vs #{player_label(opponent)}, round #{round}: " <>
              "illegal result combination '#{result}' / '#{opp_result}'"
      end
    else
      _ -> :ok
    end
  end

  defp player_label(p), do: to_string(p[:name] || p[:rank])

  ## ---------- Parsing ----------

  @doc """
  Inverse of serialize/1: returns %{tournament: ..., players: ..., teams: ...}.

  Tolerates a TRF06-vintage file (FIDE's Annexure-B, 2006): before TRF16
  added the F/H/U/Z bye codes, a bye was just a dangling playing code
  against opponent 0000 (see `validate_games!/2`'s
  `allow_dangling_playing_code` option) — column positions are otherwise
  byte-identical between the two versions, so no separate TRF06 parser is
  needed, just this one relaxed rule.

  `XXP` lines land in `tournament[:forbidden_pairs]`, and `XXA` lines
  attach an `:accelerations` list to the player they name. Neither key is
  added at all when the file carries no such line, so a plain TRF parses
  to exactly the same shape it always did. A malformed one of either
  raises `OpenPair.Trf.ValidationError` — see the moduledoc.
  """
  def parse(text) do
    lines =
      text
      |> String.split(~r/\r?\n/)
      |> Enum.reject(&(String.trim(&1) == ""))

    empty = %{tournament: %{deputy_arbiters: []}, players: [], teams: [], accelerations: %{}}

    result =
      Enum.reduce(lines, empty, fn line, acc ->
        case String.slice(line, 0, 3) do
          "001" -> update_in(acc.players, &(&1 ++ [parse_player_line(line)]))
          "013" -> update_in(acc.teams, &(&1 ++ [parse_team_line(line)]))
          "132" -> put_in(acc.tournament[:round_dates], parse_round_dates(line))
          "XXR" -> parse_xxr(acc, line)
          "XXP" -> parse_xxp(acc, line)
          "XXA" -> parse_xxa(acc, line)
          code -> parse_header_line(acc, code, line)
        end
      end)

    validate_games!(result.players, allow_dangling_playing_code: true)
    attach_accelerations(result)
  end

  # An `XXA` line may legally precede the `001` line of the player it names
  # — bbpPairings handles the same ordering problem by pre-sizing
  # `tournament.players` in `readPlayerAccelerationsXxa` and then MOVING the
  # accelerations onto the real player record when its `001` line arrives
  # (`trf.cpp:369-372`). Collecting them in a rank-keyed map and merging at
  # the end is the same thing without the resize dance.
  #
  # The key is only added to players that actually have one, so a file with
  # no `XXA` at all parses to the identical map it did before.
  defp attach_accelerations(%{accelerations: accelerations} = result) do
    players =
      if accelerations == %{} do
        result.players
      else
        Enum.map(result.players, fn player ->
          case Map.fetch(accelerations, player[:rank]) do
            {:ok, values} -> Map.put(player, :accelerations, values)
            :error -> player
          end
        end)
      end

    result |> Map.put(:players, players) |> Map.delete(:accelerations)
  end

  # `XXR n` is JaVaFo's own extension for the number of rounds, and it is
  # what JaVaFo actually consumes — plenty of real files carry it INSTEAD
  # of TRF16's `142`, not as well as. Read as a fallback so both spellings
  # land in the same field; an explicit `142` always wins.
  #
  # Missing this was a real defect, not a tidiness issue. The round count
  # feeds the final-round exception in `OpenPair.Pairing`'s
  # `colour_compatible?/2`, so a file carrying only `XXR` was paired with a
  # round count and re-checked without one — the two disagreeing on
  # exactly the last round, and no other. Found by fuzzing `-g` output
  # through `-c`: 4 failures in 250, every one of them the final round.
  defp parse_xxr(acc, line) do
    case line |> String.slice(3..-1//1) |> String.trim() |> Integer.parse() do
      {rounds, _rest} ->
        update_in(acc.tournament, fn t -> Map.put_new(t, :number_of_rounds, rounds) end)

      :error ->
        acc
    end
  end

  # `XXP a b [c ...]` — a mutually-forbidden GROUP of players, JaVaFo's own
  # extension for an arbiter's "these must never meet" (family members, the
  # same club, a federation exclusion rule).
  #
  # A port of `readForbiddenPairsXxp` (`trf.cpp:554-568`), which takes
  # `line.substr(3)` and tokenizes on space/tab into a LIST of player ids.
  # So one line is an N-player group in which EVERY pair is forbidden, not
  # just a pair — the sibling project only ever emits two ids per line, but
  # the general form is what the reference reads and so is what this reads.
  # bbpPairings then files each list under rounds `[0, expectedRounds)`
  # (`trf.cpp:1344-1347`), i.e. universally, which is why no round range is
  # kept here; its round-limited sibling is the `260` line, not this one.
  #
  # An unreadable id RAISES, where `parse_xxr/2` next door merely shrugs.
  # That difference is deliberate and is the whole point of this commit:
  # `XXR` has a safe fallback (the `142` header, or no round count at all),
  # while a dropped `XXP` produces a complete, perfectly legal-LOOKING
  # pairing that seats two players an arbiter said must never meet, with
  # nothing downstream able to tell. bbpPairings takes the same view —
  # `readPlayerId` throws `InvalidLineException` and the whole file is
  # rejected (exit code 3, confirmed by direct invocation).
  #
  # A line naming fewer than two players is accepted and then dropped, not
  # raised on: bbpPairings accepts it too (an empty or one-element deque
  # inserts a player into their own forbidden set at most, and nobody is
  # ever a candidate opponent for themselves).
  defp parse_xxp(acc, line) do
    ids =
      line
      |> String.slice(3..-1//1)
      |> String.split([" ", "\t"], trim: true)
      |> Enum.map(fn token ->
        parse_int(token) ||
          raise ValidationError,
            message: "XXP line names #{inspect(token)}, which is not a starting rank: #{line}"
      end)

    if length(ids) < 2 do
      acc
    else
      update_in(acc.tournament[:forbidden_pairs], &((&1 || []) ++ [ids]))
    end
  end

  # `XXA` — per-player acceleration ("virtual points", FIDE C.04.7 Baku
  # Acceleration and anything else an arbiter chooses to hand out), one
  # value per round from round 1. Fixed-column; see `@xxa_rank_cols`.
  #
  # A port of `readPlayerAccelerationsXxa` (`trf.cpp:487-514`). Its loop
  # condition is `startIndex + 4 <= line.size()`, so a round's slot counts
  # only when all four of its characters are actually present, and a slot
  # that is present but blank reads as zero rather than ending the line.
  #
  # An unreadable rank or value RAISES, for the reason `parse_xxp/2` gives:
  # silently discarding it changes which bracket a player is paired in and
  # produces a wrong answer that looks entirely well-formed. It is also
  # the concrete way a caller finds out its `XXA` columns are wrong, which
  # is not hypothetical — the sibling project's own emitter is one column
  # wide at every field, and bbpPairings rejects those lines outright
  # (`Invalid line "XXA     1  1.0 ..."`, exit 3, reproduced directly).
  # Reading the rank out of columns 5-8 of such a line finds four blanks,
  # so this raises where a tolerant parser would have quietly paired an
  # unaccelerated tournament and said nothing.
  defp parse_xxa(acc, line) do
    rank =
      parse_int(read(line, @xxa_rank_cols)) ||
        raise ValidationError,
          message:
            "XXA line has no starting rank in columns 5-8 (see OpenPair.Trf's " <>
              "@xxa_rank_cols for the fixed-column layout): #{inspect(line)}"

    # APPENDS rather than replaces, matching `push_back` onto a player's
    # existing `accelerations` (`trf.cpp:510`) — `tournament.players[id]`
    # persists between lines, so two `XXA` lines for one player continue
    # the same record rather than the second one winning.
    update_in(acc.accelerations[rank], &((&1 || []) ++ parse_xxa_points(line)))
  end

  defp parse_xxa_points(line) do
    length = String.length(line)
    {_round1_start, round1_end} = xxa_points_cols(1)

    round_count =
      if length < round1_end do
        0
      else
        div(length - round1_end, 5) + 1
      end

    Enum.map(1..round_count//1, fn round ->
      case read(line, xxa_points_cols(round)) do
        "" ->
          0.0

        field ->
          parse_float(field) ||
            raise ValidationError,
              message:
                "XXA line, round #{round}: #{inspect(field)} is not a virtual-point " <>
                  "value: #{inspect(line)}"
      end
    end)
  end

  defp read(line, {start_col, end_col}) do
    line |> String.slice(start_col - 1, end_col - start_col + 1) |> String.trim()
  end

  defp parse_header_line(acc, code, line) do
    field = Enum.find_value(@header_codes, fn {f, c} -> if c == code, do: f end)
    value = line |> String.slice(4..-1//1) |> String.trim()

    case field do
      nil ->
        acc

      :round_dates ->
        acc

      :deputy_arbiter ->
        update_in(acc.tournament.deputy_arbiters, &(&1 ++ [value]))

      f when f in [:start_date, :end_date] ->
        put_in(acc.tournament[f], String.replace(value, "/", "-"))

      f
      when f in [
             :number_of_players,
             :number_of_rated_players,
             :number_of_teams,
             :number_of_rounds
           ] ->
        put_in(acc.tournament[f], parse_int(value) || 0)

      f ->
        put_in(acc.tournament[f], value)
    end
  end

  defp parse_player_line(line) do
    %{
      rank: parse_int(read(line, @player_cols.starting_rank)),
      sex: line |> read(@player_cols.sex) |> String.downcase(),
      title: read(line, @player_cols.title),
      name: read(line, @player_cols.name),
      fide_rating: parse_int(read(line, @player_cols.fide_rating)) || 0,
      federation: read(line, @player_cols.federation),
      fide_number: parse_int(read(line, @player_cols.fide_number)),
      birth_date: line |> read(@player_cols.birth_date) |> iso_date(),
      points: parse_float(read(line, @player_cols.points)) || 0.0,
      games: parse_games(line)
    }
  end

  # Stops on where the line's real content actually ends, not on the first
  # blank round — a fully-blank round block (FIDE's own "not paired", see
  # Annexure-B, the 2006 TRF06 spec) is a real, legal "no game recorded this
  # round" for a late entrant, and can legitimately be followed by real
  # games in later rounds. Stopping at the first one silently drops every
  # game after it.
  defp parse_games(line) do
    trimmed_length = line |> String.trim_trailing() |> String.length()
    {round1_start, _} = round_cols(1).id

    round_count =
      if trimmed_length < round1_start do
        0
      else
        div(trimmed_length - round1_start, 10) + 1
      end

    Enum.map(1..round_count//1, &parse_game_at_round(line, &1))
  end

  defp parse_game_at_round(line, round) do
    cols = round_cols(round)
    id_raw = read(line, cols.id)
    colour = read(line, cols.colour)
    result = read(line, cols.result)

    %{
      opponent_rank: if(id_raw in ["", "0000"], do: nil, else: parse_int(id_raw)),
      colour: if(colour in ["", "-"], do: nil, else: colour),
      result: normalize_result(result)
    }
  end

  # "W", "D" and "L" are TRF16's letter spellings of "1", "=" and "0", and are
  # normalised to those on the way in, so one code means one thing everywhere
  # downstream: the validation tables above, `points_for/1`, the engine's own
  # `result_points/1`, and every criterion that reads a result.
  #
  # They are NOT "unplayed" results, which is what this file assumed by
  # omitting them. Checked against bbpPairings' own reader rather than
  # inferred: it sets `gameWasPlayed = false` for exactly "+", "-", "H", "F",
  # "U", "Z" and space (`trf.cpp:278-286`) — W/D/L are absent, so they are
  # played games against a real opponent — and it scores them through the
  # same WIN/DRAW/LOSS branch as "1"/"="/"0" (`trf.cpp:252-270`). Omitting
  # them meant `parse/1` raised `ValidationError` on a legal TRF16 file.
  #
  # A blank result column is also legal and means a loss, but this parser
  # already maps a blank to `nil` above; that is a separate question from a
  # code it fails to recognise, and is left alone deliberately.
  defp normalize_result("W"), do: "1"
  defp normalize_result("D"), do: "="
  defp normalize_result("L"), do: "0"
  defp normalize_result(""), do: nil
  defp normalize_result(result), do: result

  defp parse_team_line(line, slot \\ 1, ranks \\ []) do
    cols = team_player_cols(slot)
    {start, _} = cols

    cond do
      String.length(line) < start ->
        %{name: read(line, @team_cols.name), player_ranks: Enum.reverse(ranks)}

      read(line, cols) == "" ->
        %{name: read(line, @team_cols.name), player_ranks: Enum.reverse(ranks)}

      true ->
        parse_team_line(line, slot + 1, [parse_int(read(line, cols)) | ranks])
    end
  end

  defp parse_round_dates(line, round \\ 1, acc \\ []) do
    cols = round_date_cols(round)
    {start, _} = cols

    if String.length(line) < start or read(line, cols) == "" do
      Enum.reverse(acc)
    else
      date =
        case String.split(read(line, cols), "/") do
          [y, m, d] when byte_size(y) == 2 -> "20#{y}-#{m}-#{d}"
          [y, m, d] -> "#{y}-#{m}-#{d}"
          _ -> nil
        end

      parse_round_dates(line, round + 1, [date | acc])
    end
  end

  defp iso_date(""), do: ""
  defp iso_date("0000" <> _), do: ""
  defp iso_date(slash), do: String.replace(slash, "/", "-")

  defp parse_int(""), do: nil

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_float(""), do: nil

  defp parse_float(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> nil
    end
  end
end
