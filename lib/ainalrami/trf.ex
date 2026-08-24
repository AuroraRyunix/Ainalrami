defmodule Ainalrami.Trf.ValidationError do
  @moduledoc """
  Raised by `Ainalrami.Trf` when a player's round-by-round game data contains
  an illegal FIDE result: an unrecognized result code, or a result that is
  inconsistent with the opponent's own recorded result for the same round
  (e.g. both sides claim a win, or both sides are marked forfeit-win).
  """
  defexception [:message]
end

defmodule Ainalrami.Trf do
  @moduledoc """
  FIDE TRF16 (Tournament Report File) serializer and parser, per the official
  specification: https://www.fide.com/FIDE/handbook/C04Annex2_TRF16.pdf

  All column positions are 1-indexed and inclusive, exactly as printed in the
  spec. This is Ainalrami's file format for both directions: the roster/result
  history it's asked to pair, and the paired output it writes back - same
  format JaVaFo itself reads and writes, so a TRF file built for one engine
  works unmodified for the other.

  Both `serialize/1` and `parse/1` validate every player's per-round result
  codes before returning, raising `Ainalrami.Trf.ValidationError` on an
  unrecognized code or an illegal combination between two opponents (see
  `validate_games!/2`). Validation only cross-checks a pairing when both
  sides are present in the given player set and mutually reference each
  other for that round - a lone/dangling reference is not itself an error.

  Ported from the sibling project (`AuroraRyunix/openpairings`)'s own
  `PairingsEngine.Trf`, which fixed two real bugs against FIDE's actual
  archived TRF06 specs (Annexure-B/2006, Annexure-C/2016) - the
  `allow_dangling_playing_code` tolerance and the `parse_games/1` blank-round
  handling below both come directly from that work, not reinvented here.

  ## The `XX*` extension lines

  Three of JaVaFo's own `XX` extension codes are read; two of them are written:

    * `XXR n` - the round count (see `parse_xxr/2`), which is the same field
      as TRF16's `142`. A file may carry both spellings, but they must
      AGREE: two different counts are refused rather than silently resolved,
      since every implementation resolves them differently. READ ONLY:
      `serialize/1` emits the count as the standard `142` header, so a file
      that came in with `XXR` goes out with `142`. The value round-trips;
      the spelling does not.
    * `XXP a b [c ...]` - a mutually-forbidden GROUP of players
      (see `parse_xxp/2`), surfaced as `tournament[:forbidden_pairs]`.
    * `XXA` - per-player acceleration/virtual points, round by round
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
  `Ainalrami.Trf.ValidationError` rather than being skipped - see
  `parse_xxp/2`. bbpPairings does the same (`InvalidLineException`, exit
  code 3); a MALFORMED `XXR` is the exception, and can afford to be
  ignored, because a missing round count has a fallback and a missing
  exclusion does not. A CONTRADICTED round count is a different thing
  again and does raise - see `check_round_count_agreement!/2`.
  """

  alias Ainalrami.Trf.ValidationError

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
    # Swiss-Manager (which already emits both) - optional/additive, an
    # unrecognized header code is already silently ignored by
    # `parse_header_line/3`, so including them never breaks a TRF16-only
    # reader.
    number_of_rounds: "142",
    round_dates: "132",
    # TRF-2026's initial-piece-colour field: the colour drawn by lot before
    # round 1 (C.04.3 5.1), which 5.2.5 hands to the higher ranked player of
    # a pair when neither holds a preference. Parsed as `"w"`/`"b"` into
    # `tournament[:initial_colour]`.
    #
    # It was not read at all until 2026-08-17: the engine assumed White
    # unconditionally, so a file specifying Black was paired with every
    # no-preference colour inverted, and no test could see it because the
    # harness only ever wrote `152 W`.
    initial_colour: "152",
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

  @bb_codes ~w(BBW BBD BBL BBZ BBF BBU)

  @bb_fields %{
    "BBW" => :win,
    "BBD" => :draw,
    "BBL" => :loss,
    "BBZ" => :zero_point_bye,
    "BBF" => :forfeit_loss,
    "BBU" => :pairing_allocated_bye
  }

  @doc """
  The standard 1 / ½ / 0 point system, and what every caller gets unless a
  file says otherwise.

  `pairing_allocated_bye` is separate from `win` even though both are 1.0
  here, because it is the one an organiser is most likely to move: FIDE
  permits valuing the bye at a half point, and bbpPairings exposes it as
  its own `BBU` directive for exactly that reason.
  """
  def default_point_system do
    %{
      win: 1.0,
      draw: 0.5,
      loss: 0.0,
      pairing_allocated_bye: 1.0,
      forfeit_loss: 0.0,
      zero_point_bye: 0.0
    }
  end

  @doc """
  What a single result code is worth.

  With one argument, under the standard 1 / ½ / 0 system. With a point
  system (see `default_point_system/0`), under that one.

  The split follows bbpPairings' `getPoints` (`tournament.h:310-322`)
  exactly, because the two engines have to agree on a player's SCORE before
  they can agree on a bracket:

    * `1` `W` `+` `F` - a win, a forfeit win, and an arbiter's full-point
      bye all pay `:win`. `F` looks like a bye but is not the pairing's:
      its `participatedInPairing` is false, so it misses the
      pairing-allocated branch and falls through to the ordinary win.
    * `U` - the PAIRING's own bye, and the only code that pays
      `:pairing_allocated_bye`.
    * `=` `D` `H` - a draw and a half-point bye are the same value; there is
      no separate half-point-bye setting in this system.
    * `0` `L` - a played loss pays `:loss`.
    * `-` - a forfeit loss pays `:forfeit_loss`, which an organiser may set
      above zero even though a played loss is zero.
    * anything else, `Z` and a blank included - `:zero_point_bye`.
  """
  def points_for(result), do: points_for(result, default_point_system())

  def points_for(result, points) when result in ~w(1 + F W), do: points.win
  def points_for("U", points), do: points.pairing_allocated_bye
  def points_for(result, points) when result in ~w(= H D), do: points.draw
  def points_for(result, points) when result in ~w(0 L), do: points.loss
  def points_for("-", points), do: points.forfeit_loss
  def points_for(_result, points), do: points.zero_point_bye

  @doc """
  Whether a result code represents a game that was actually PLAYED.

  bbpPairings sets `gameWasPlayed = false` for exactly `+ - H F U Z` and a
  blank (`trf.cpp:278-286`); `W`, `D` and `L` are absent from that list, so
  they are letter spellings of ordinary played results rather than unplayed
  ones. Several rules turn on this distinction, C2's bye eligibility among
  them.
  """
  def game_was_played?(nil), do: false

  def game_was_played?(result),
    do: result not in ~w(+ - H F U Z) and String.trim(result) != ""

  @doc """
  Whether the player took part in the PAIRING for this game, as opposed to
  having a result recorded for them without being paired.

  This is what distinguishes an arbiter-assigned bye (half-point,
  zero-point, full-point - granted before the round is paired, so the
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
  # opponent), unlike a bye - so the two groups get different validation.
  @playing_codes ~w(1 = 0 + -)
  @bye_codes ~w(H F U Z)

  # Legal opponent-result for each of this player's playing codes. A win
  # ("1") only pairs with a loss ("0"); a played "0-0" (both players lose,
  # e.g. both defaulted after making moves) is two losses, so "0" also
  # legally pairs with "0". A double forfeit is "-"/"-"; a single forfeit is
  # "+"/"-". A draw ("=") also legally pairs with a loss ("0") - an
  # asymmetric ½-0/0-½ (an arbiter's disciplinary point adjustment on an
  # otherwise-drawn game, not a chess outcome the TRF spec itself
  # distinguishes with its own code - it's still just "=" and "0" per
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
  # starting rank from `line[4]..line[8)` - 0-indexed, so columns 5-8 - and
  # then walks `startIndex = 9; startIndex += 5`, reading four characters at
  # each stop: columns 10-13, 15-18, 20-23, i.e. `10 + 5*(r-1)` for round
  # `r`, with a single separator column between fields. That is exactly the
  # JaVaFo 2.2 Advanced User Manual's own spec ("XXA NNNN pp.p pp.p ...",
  # `NNNN` at column 5, each `pp.p` at column `10 + 5*(r-1)`).
  #
  # The sibling project confirmed by direct experiment that free-form `XXA`
  # crashes real javafo with a bare NullPointerException while the
  # fixed-column form runs clean - see `acceleration_lines/4`'s docs in
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
  legend plus two column-position rulers) right before the player rows -
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
    |> Kernel.++(point_system_lines(t[:point_system]))
    |> Kernel.++(legend_lines(opts[:column_legend], max_round))
    |> Kernel.++(Enum.map(players, &player_line/1))
    |> Kernel.++(Enum.map(teams, &team_line/1))
    |> Kernel.++(extension_lines(t, players, max_round, opts[:numeric_extensions]))
    |> Enum.map_join("", &(&1 <> "\r\n"))
  end

  # Written as `BB*` rather than as a `162` line: the `BB` directives are one
  # value per line, so a file carrying them says exactly which settings were
  # deliberate, and a reader that supports only some of them fails on the
  # line it cannot take rather than misreading a packed record.
  #
  # Only the values that DIFFER from the standard system are emitted, so an
  # ordinary tournament serialises byte-identically to before this existed.
  # `BBU` comes last on purpose - `BBW` drags the pairing-allocated bye with
  # it unless the bye has already been pinned, which is the reference's own
  # `usePairingAllocatedByeScore` behaviour and depends on the file's order.
  defp point_system_lines(nil), do: []

  defp point_system_lines(system) do
    default = default_point_system()

    order = [
      {:win, "BBW"},
      {:draw, "BBD"},
      {:loss, "BBL"},
      {:zero_point_bye, "BBZ"},
      {:forfeit_loss, "BBF"},
      {:pairing_allocated_bye, "BBU"}
    ]

    for {field, code} <- order,
        value = Map.get(system, field),
        value != Map.fetch!(default, field) do
      # Fixed columns, not free-form. `readPoints` (trf.cpp:637-644) demands
      # a line of at least 8 characters and reads the value from column 5
      # onwards, so `BBW 2.0` - the obvious spelling, and 7 characters - is
      # rejected outright as an invalid line. Right-aligned in columns 5-8,
      # matching how every other point field in TRF16 is written.
      code <> " " <> String.pad_leading(:erlang.float_to_binary(value / 1, decimals: 1), 4)
    end
  end

  # `XXA`/`XXP` are JaVaFo's spellings and what the sibling project emits,
  # so they stay the default. `250`/`260` are bbpPairings' own fixed-column,
  # round-limited siblings - and it is the implementation that DEFINES them,
  # which is exactly why generating them matters. Until now they were
  # covered by unit tests written from its source, and never by a file the
  # real binary had to read back.
  defp extension_lines(t, players, max_round, true) do
    rounds = t[:number_of_rounds] || max_round

    numeric_acceleration_lines(players) ++
      numeric_forbidden_lines(t[:forbidden_pairs], max(rounds, max_round + 1))
  end

  defp extension_lines(t, players, _max_round, _) do
    acceleration_lines(players) ++ forbidden_pair_lines(t[:forbidden_pairs])
  end

  # One `250` per player per round carrying non-zero virtual points.
  #
  # A `250` says "these players, over these rounds, get these points", so a
  # single line can cover a whole accelerated group - but only when that
  # group is contiguous by rank AND flat across the rounds, which is true of
  # Baku and false of the random axis. The degenerate range (one player, one
  # round) is correct for both, and for a corpus that is the better trade:
  # it puts MORE lines through the parser, not fewer.
  defp numeric_acceleration_lines(players) do
    for player <- players,
        {points, round} <- Enum.with_index(player[:accelerations] || [], 1),
        points != 0 do
      # Widths taken from `readAccelerations250` (trf.cpp:418) rather than
      # from `parse_250/2` below, and they are NOT the same. The C++ reads
      # half-open 0-based ranges - [4,8) match points, [9,13) game points,
      # [14,17) and [18,21) the rounds, [22,26) and [27,31) the players -
      # so every field is separated from the next by one blank column.
      #
      # `parse_250/2` reads each field one column wider, swallowing that
      # separator, which is harmless on the way IN because `read/2` trims.
      # On the way OUT it is fatal: right-aligning into the wider field puts
      # the digit in the separator, and the real binary then reads a blank
      # round and rejects the line. Verified by feeding both to
      # bbpPairings - the wide form is `Invalid line`, this one pairs.
      #
      # Same shape as the `XXA` column bug: a field written one column too
      # wide, tolerated by the reader we happened to test against and
      # rejected by the one that defines the format.
      []
      |> place({1, 3}, "250")
      # 5-8 is MATCH points and must stay blank; bbpPairings rejects a `250`
      # that carries any, and `parse_250/2` enforces the same on the way in.
      |> place({10, 13}, format_points(points), align: :right)
      |> place({15, 17}, round, align: :right)
      |> place({19, 21}, round, align: :right)
      |> place({23, 26}, player[:rank], align: :right)
      |> place({28, 31}, player[:rank], align: :right)
      |> render()
    end
  end

  # One `260` per forbidden group, spanning every round.
  #
  # `XXP` carries no round limit at all - it means "never pair these" - so
  # the equivalent `260` has to name a range that outlives the tournament,
  # not just the rounds already played. Bounding it at `number_of_rounds`
  # is the subtle version of getting this wrong: on a file whose declared
  # round count is behind the round actually being paired, the ban expires
  # exactly when it is needed and the two spellings pair differently.
  # Caught by diffing bbpPairings' own output on both forms of one
  # tournament, which is the only way it shows up - each file is
  # individually valid and parses without complaint.
  defp numeric_forbidden_lines(nil, _rounds), do: []
  defp numeric_forbidden_lines([], _rounds), do: []

  defp numeric_forbidden_lines(groups, rounds) do
    last = max(rounds, 1)

    for group <- groups, ids = group_ids(group), length(ids) >= 2 do
      ids
      |> Enum.with_index()
      |> Enum.reduce(
        []
        |> place({1, 3}, "260")
        |> place({5, 7}, 1, align: :right)
        |> place({9, 11}, last, align: :right),
        fn {id, i}, acc ->
          start = 13 + i * 5
          place(acc, {start, start + 3}, id, align: :right)
        end
      )
      |> render()
    end
  end

  # A group is either a bare list of ranks (`XXP`) or the round-limited
  # `{ids, first, last}` a `260` parses into. Writing either back out has to
  # accept both, so that a file read as `260` and written as `260`
  # round-trips rather than losing its groups.
  defp group_ids({ids, _first, _last}) when is_list(ids), do: ids
  defp group_ids(ids) when is_list(ids), do: ids
  defp group_ids(_), do: []

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
  # across the full width - together, a standard fixed-width column ruler.
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
      initial_colour_line(t[:initial_colour]),
      round_dates_line(t[:round_dates]),
      header(:generator, t[:generator])
    ])
    |> Enum.reject(&(&1 in [nil, false]))
  end

  # Article 5.1's drawing of lots. Parsed since 2026-08-17 but never
  # written until now, so `serialize/2` silently dropped it and a
  # round-trip lost the draw - and a file with no round one played has
  # nothing to infer it back from, which real bbpPairings treats as fatal
  # rather than guessable ("Please configure the initial piece colors",
  # exit 3). Round one is exactly when the field decides every board.
  #
  # FIXED WIDTH, unlike every other header here: `trf.cpp:1181` rejects
  # the line outright unless it is exactly five characters, so this is
  # built directly rather than through `header/2`, whose trailing trim
  # would be harmless but whose lowercase value would not.
  defp initial_colour_line(nil), do: nil
  defp initial_colour_line(colour) when colour in ["w", "W"], do: "152 W"
  defp initial_colour_line(colour) when colour in ["b", "B"], do: "152 B"

  defp header(_field, value) when value in [nil, ""], do: nil
  defp header(field, value), do: String.trim_trailing("#{@header_codes[field]} #{value}")

  defp round_dates_line(nil), do: nil
  defp round_dates_line([]), do: nil

  defp round_dates_line(dates) do
    # Only emit the line at all if at least one round actually has a date -
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
  # split or shift the fixed-width row - control characters are flattened
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
  #      is not itself flagged - the caller may be validating a partial
  #      roster.
  #
  # `opts[:allow_dangling_playing_code]` relaxes the "opponent 0000 needs a
  # bye code (F/H/Z/U)" rule below - those four codes didn't exist before
  # TRF16 (FIDE's Annexure-B, the 2006 spec: only 1/=/0/+/-/blank, a bye
  # represented as a dangling playing code against 0000, no dedicated bye
  # code at all). That rule protects OUR OWN pairing-output construction (a
  # dangling playing code there is a real crash risk downstream), which only
  # matters on the way OUT (`serialize/1`); a file we're reading FROM
  # someone else, possibly TRF06-vintage, is exactly what this option
  # exists for - `parse/1` passes it, `serialize/1` never does.
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
              "#{inspect(result)} - opponentless games must use a bye code (F/H/Z/U)"

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
  `allow_dangling_playing_code` option) - column positions are otherwise
  byte-identical between the two versions, so no separate TRF06 parser is
  needed, just this one relaxed rule.

  `XXP` lines land in `tournament[:forbidden_pairs]`, and `XXA` lines
  attach an `:accelerations` list to the player they name. Neither key is
  added at all when the file carries no such line, so a plain TRF parses
  to exactly the same shape it always did. A malformed one of either
  raises `Ainalrami.Trf.ValidationError` - see the moduledoc.
  """
  def parse(text) do
    lines =
      text
      # All three line endings, not just the two anyone expects. Real
      # bbpPairings writes its generated TRFs with a BARE `\r` and no `\n`
      # at all -- 212 of them in a 209-player file, zero newlines -- so
      # `\r?\n` matched nothing, the whole file parsed as a single line,
      # and `parse/1` returned zero players without complaint.
      #
      # That made this engine unable to read the reference implementation's
      # own output, which no test could see: the comparison harness only
      # ever feeds OUR files to THEM. Found by generating a tournament with
      # `bbpPairings --dutch -g -o` and reading it back.
      #
      # `\r\n` has to be first in the alternation so a CRLF is consumed as
      # one separator rather than as two.
      |> String.split(~r/\r\n|\n|\r/)
      |> Enum.reject(&(String.trim(&1) == ""))

    empty = %{
      tournament: %{deputy_arbiters: []},
      players: [],
      teams: [],
      accelerations: %{},
      acceleration_ranges: []
    }

    result =
      Enum.reduce(lines, empty, fn line, acc ->
        case String.slice(line, 0, 3) do
          "001" -> update_in(acc.players, &(&1 ++ [parse_player_line(line)]))
          "013" -> update_in(acc.teams, &(&1 ++ [parse_team_line(line)]))
          "132" -> put_in(acc.tournament[:round_dates], parse_round_dates(line))
          "XXR" -> parse_xxr(acc, line)
          "XXP" -> parse_xxp(acc, line)
          "XXA" -> parse_xxa(acc, line)
          "250" -> parse_250(acc, line)
          "260" -> parse_260(acc, line)
          "162" -> parse_point_system(acc, line)
          code when code in @bb_codes -> parse_bb_points(acc, code, line)
          code -> parse_header_line(acc, code, line)
        end
      end)

    validate_games!(result.players, allow_dangling_playing_code: true)
    attach_accelerations(result)
  end

  # bbpPairings' point-system directives (`trf.cpp:1203-1232`) plus TRF16's
  # own `162` line, which says the same thing in fixed columns.
  #
  # ## Why an engine needs these at all
  #
  # They set what a result is WORTH, and a player's score is what decides
  # which bracket they are paired in. Every score group in the Dutch system
  # is built from these numbers, so an engine that ignores them does not
  # merely report the wrong totals - it pairs a different tournament. The
  # one an organiser is most likely to change is `BBU`: FIDE permits valuing
  # the pairing-allocated bye at half a point rather than a full one, and
  # that moves its recipient into a different score group for every
  # remaining round.
  #
  # Unread until 2026-08-24, which meant they fell through to the header
  # parser and were silently discarded - the same failure mode `250`/`260`
  # had, and with the same consequence: a legal-looking round paired on
  # scores the file did not ask for.
  defp parse_bb_points(acc, code, line) do
    value = read_points!(String.slice(line, 3..-1//1), line)
    field = Map.fetch!(@bb_fields, code)

    acc
    |> put_point(field, value)
    |> then(fn acc ->
      # `BBW` moves the pairing-allocated bye with it unless `BBU` has
      # already pinned it - bbpPairings' `usePairingAllocatedByeScore` flag.
      # Order matters, and it is the FILE's order, not ours.
      if field == :win and not Map.get(acc, :pab_pinned?, false) do
        put_point(acc, :pairing_allocated_bye, value)
      else
        acc
      end
    end)
    |> then(fn acc ->
      if field == :pairing_allocated_bye, do: Map.put(acc, :pab_pinned?, true), else: acc
    end)
  end

  # `162 <char><score> <char><score> ...`, nine columns per entry starting at
  # column 6 (`readPointSystem`, trf.cpp:573-631). `A` is a synonym for `Z`
  # and sets the forfeit loss along with it; `X` is explicitly unsupported by
  # the reference, so it is refused here rather than guessed at.
  defp parse_point_system(acc, line) do
    line
    |> String.slice(5..-1//1)
    |> to_string()
    |> chunk_point_entries()
    |> Enum.reduce(acc, fn {char, score_text}, acc ->
      score = read_points!(score_text, line)

      case char do
        "W" ->
          acc = put_point(acc, :win, score)

          if Map.get(acc, :pab_pinned?, false),
            do: acc,
            else: put_point(acc, :pairing_allocated_bye, score)

        "D" ->
          put_point(acc, :draw, score)

        "L" ->
          put_point(acc, :loss, score)

        c when c in ["Z", "A"] ->
          acc |> put_point(:zero_point_bye, score) |> put_point(:forfeit_loss, score)

        "P" ->
          acc |> put_point(:pairing_allocated_bye, score) |> Map.put(:pab_pinned?, true)

        "X" ->
          raise ValidationError,
            message: "162 line uses symbol X, which no reference implements: #{line}"

        other ->
          raise ValidationError,
            message: "162 line has unknown result symbol #{inspect(other)}: #{line}"
      end
    end)
  end

  defp chunk_point_entries(rest) do
    rest
    |> String.graphemes()
    |> Enum.chunk_every(9)
    |> Enum.map(&Enum.join/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.map(fn entry ->
      {String.slice(entry, 0, 1), String.slice(entry, 1, 4)}
    end)
  end

  defp put_point(acc, field, value) do
    system = acc.tournament[:point_system] || default_point_system()
    put_in(acc.tournament[:point_system], Map.put(system, field, value))
  end

  defp read_points!(text, line) do
    case text |> to_string() |> String.trim() |> Float.parse() do
      {value, ""} when value >= 0 -> value
      _ -> raise ValidationError, message: "unreadable point value: #{line}"
    end
  end

  # An `XXA` line may legally precede the `001` line of the player it names
  # - bbpPairings handles the same ordering problem by pre-sizing
  # `tournament.players` in `readPlayerAccelerationsXxa` and then MOVING the
  # accelerations onto the real player record when its `001` line arrives
  # (`trf.cpp:369-372`). Collecting them in a rank-keyed map and merging at
  # the end is the same thing without the resize dance.
  #
  # The key is only added to players that actually have one, so a file with
  # no `XXA` at all parses to the identical map it did before.
  defp attach_accelerations(%{accelerations: accelerations, acceleration_ranges: ranges} = result) do
    # `250` ranges are expanded first, then `XXA` rows are APPENDED to
    # them rather than laid over them.
    #
    # Appending looks odd and is what the reference does:
    # `readPlayerAccelerationsXxa` (`trf.cpp:487-514`) calls `push_back` on
    # the player's acceleration vector, so an `XXA` line lands after
    # whatever a `250` already filled in - round 3 onwards, not round 1.
    # This engine's own `parse_xxa/2` already appends when two `XXA` lines
    # name the same player, so the two are consistent.
    #
    # Overwriting instead put `XXA`'s values at rounds 1-2 and produced a
    # different bracket from bbpPairings on the same bytes. A file carrying
    # both forms is exotic - `XXA` is JaVaFo's spelling and `250` is
    # bbpPairings' - but "exotic" is not a reason to diverge silently.
    expanded = Enum.reduce(ranges, %{}, &expand_acceleration_range/2)

    merged =
      Map.merge(expanded, accelerations, fn _rank, from_250, from_xxa ->
        from_250 ++ from_xxa
      end)

    players =
      if merged == %{} do
        result.players
      else
        Enum.map(result.players, fn player ->
          case Map.fetch(merged, player[:rank]) do
            {:ok, values} -> Map.put(player, :accelerations, values)
            :error -> player
          end
        end)
      end

    result
    |> Map.put(:players, players)
    |> Map.delete(:accelerations)
    |> Map.delete(:acceleration_ranges)
  end

  # One `250` line covers players `first_player..last_player` for rounds
  # `first_round..last_round`, both inclusive. Rounds before the range pay
  # nothing, which is the `accelerations.resize(roundStart)` zero-fill in
  # `readAccelerations250`.
  defp expand_acceleration_range({points, first_round, last_round, first, last}, acc) do
    row = for round <- 1..last_round, do: if(round >= first_round, do: points, else: 0.0)

    Enum.reduce(first..last, acc, fn rank, inner ->
      Map.update(inner, rank, row, &merge_acceleration_rows(&1, row))
    end)
  end

  # Two ranges can overlap in rounds; the later line wins for the rounds it
  # names, and anything it does not reach keeps the earlier value.
  defp merge_acceleration_rows(existing, new) do
    length = max(length(existing), length(new))

    for index <- 0..(length - 1)//1 do
      value = Enum.at(new, index)

      if is_nil(value) or value == 0.0 do
        Enum.at(existing, index, 0.0)
      else
        value
      end
    end
  end

  # `XXR n` is JaVaFo's own extension for the number of rounds, and it is
  # what JaVaFo actually consumes - plenty of real files carry it INSTEAD
  # of TRF16's `142`, not as well as. Read as a fallback so both spellings
  # land in the same field; an explicit `142` always wins.
  #
  # Missing this was a real defect, not a tidiness issue. The round count
  # feeds the final-round exception in `Ainalrami.Pairing`'s
  # `colour_compatible?/2`, so a file carrying only `XXR` was paired with a
  # round count and re-checked without one - the two disagreeing on
  # exactly the last round, and no other. Found by fuzzing `-g` output
  # through `-c`: 4 failures in 250, every one of them the final round.
  defp parse_xxr(acc, line) do
    case line |> String.slice(3..-1//1) |> String.trim() |> Integer.parse() do
      {rounds, _rest} ->
        check_round_count_agreement!(acc.tournament[:number_of_rounds], rounds)
        update_in(acc.tournament, fn t -> Map.put_new(t, :number_of_rounds, rounds) end)

      :error ->
        acc
    end
  end

  # A file may carry both spellings - `142` is TRF16's, `XXR` is JaVaFo's,
  # and a file that has passed through both toolchains can hold each. Two
  # copies of the same number are fine; two DIFFERENT numbers are not, and
  # this refuses rather than picking one.
  #
  # Picking one is what every implementation does and they do not agree:
  # this engine preferred `142` regardless of position, bbpPairings takes
  # whichever line comes LAST (`trf.cpp:1117-1124` assigns
  # `expectedRounds` from either prefix, so the later assignment wins). On
  # `142 9` followed by `XXR 5` the two therefore pair different final
  # rounds from the same bytes.
  #
  # It has to be a refusal for the reason `parse_xxp/2` raises: the round
  # count feeds the final-round exception in `colour_compatible?/2` and the
  # topscorer threshold in `final_round_topscorers?/2`, so the wrong value
  # yields a complete, perfectly legal-LOOKING round that applies the
  # last-round rules to the wrong round - with nothing downstream able to
  # tell. A self-contradictory file has no correct pairing, only two
  # plausible ones.
  defp check_round_count_agreement!(nil, _rounds), do: :ok
  defp check_round_count_agreement!(same, same), do: :ok

  defp check_round_count_agreement!(existing, rounds) do
    raise ValidationError,
          "the file gives two different round counts (#{existing} and #{rounds}); " <>
            "`142` and `XXR` are the same field and must agree"
  end

  # `XXP a b [c ...]` - a mutually-forbidden GROUP of players, JaVaFo's own
  # extension for an arbiter's "these must never meet" (family members, the
  # same club, a federation exclusion rule).
  #
  # A port of `readForbiddenPairsXxp` (`trf.cpp:554-568`), which takes
  # `line.substr(3)` and tokenizes on space/tab into a LIST of player ids.
  # So one line is an N-player group in which EVERY pair is forbidden, not
  # just a pair - the sibling project only ever emits two ids per line, but
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
  # nothing downstream able to tell. bbpPairings takes the same view -
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

  # `250` - bbpPairings' ROUND-LIMITED acceleration, the fixed-column
  # sibling of `XXA`. One line hands the same number of virtual points to a
  # RANGE of players over a RANGE of rounds, where `XXA` spells out one
  # player's whole row.
  #
  # A port of `readAccelerations250` (`trf.cpp:418-482`). Columns, all
  # 1-based here and inclusive: match points in 5-9, which must be blank or
  # zero; game points in 10-14, which must be non-zero; the round range in
  # 15-18 and 19-22; the player range in 23-27 and 28-32. Shorter than 31
  # characters, either range inverted, or a zero round index, and the line
  # is refused - every one of those is an `InvalidLineException` there.
  #
  # Silently discarding it was the same defect `260` had: acceleration
  # changes a player's score for bracketing purposes, so a dropped line
  # produces a complete, well-formed round paired on the wrong scores.
  # bbpPairings' own Baku pass measured that at 66.12% of rounds when
  # `XXA` was being dropped.
  defp parse_250(acc, line) do
    if String.length(line) < 31 do
      raise ValidationError, message: "250 line is too short: #{line}"
    end

    match_points = read(line, {5, 9})

    if match_points not in ["", "0", "0.0"] do
      raise ValidationError,
        message: "250 line must not carry match points, got #{inspect(match_points)}: #{line}"
    end

    points =
      case line |> read({10, 14}) |> parse_float() do
        nil ->
          raise ValidationError, message: "250 line has unreadable game points: #{line}"

        value ->
          if value == 0.0 do
            raise ValidationError, message: "250 line has zero game points: #{line}"
          end

          value
      end

    first_round = round_field!(line, {15, 18}, line)
    last_round = round_field!(line, {19, 22}, line)
    first_player = round_field!(line, {23, 27}, line)
    last_player = round_field!(line, {28, 32}, line)

    if first_round > last_round or first_player > last_player do
      raise ValidationError, message: "250 line has an inverted range: #{line}"
    end

    update_in(
      acc.acceleration_ranges,
      &(&1 ++ [{points, first_round, last_round, first_player, last_player}])
    )
  end

  # `260` - bbpPairings' ROUND-LIMITED forbidden pairs, the fixed-column
  # sibling of `XXP`. Same meaning, but confined to a range of rounds:
  # "these players must not meet in rounds 3 to 7".
  #
  # A port of `readForbiddenPairs260` (`trf.cpp:519-548`): the first round
  # is read from columns 5-7, the last from 9-11, and the ids follow from
  # column 13 in four-character fields every five columns. bbpPairings
  # stores the range as `[first, last + 1)`, i.e. the last round is
  # INCLUSIVE, and rejects the line outright if it is shorter than 18
  # characters or carries anything but spaces after the final id.
  #
  # This was on the "deliberately not covered" list until 2026-08-17, on
  # the reasoning that `XXP` is the universal form and the one the sibling
  # project emits. That reasoning was wrong in a specific and dangerous
  # way: "not covered" meant the line fell through to `parse_header_line/3`
  # and was SILENTLY DISCARDED, so a file saying "1 and 3 must never meet"
  # produced a complete, perfectly legal-looking round that seated 1
  # against 3. That is precisely the failure `parse_xxp/2` exists to
  # prevent, in a different spelling, and it was verified happening before
  # this was written.
  defp parse_260(acc, line) do
    if String.length(line) < 18 do
      raise ValidationError, message: "260 line is too short to hold a round range: #{line}"
    end

    first = round_field!(line, {5, 7}, line)
    last = round_field!(line, {9, 11}, line)

    ids = read_260_ids(line, 13, [])

    if length(ids) < 2 do
      acc
    else
      update_in(
        acc.tournament[:forbidden_pairs],
        &((&1 || []) ++ [{ids, first, last}])
      )
    end
  end

  # Round numbers in the file are 1-based, and `readRoundIndex`
  # (`trf.cpp:113-140`) rejects a round index of 0 outright before
  # converting to its own 0-based form. This keeps the 1-based value, since
  # that is what the engine compares against the round being paired.
  defp round_field!(line, cols, whole) do
    case line |> read(cols) |> Integer.parse() do
      {value, ""} when value > 0 ->
        value

      _ ->
        raise ValidationError,
          message: "260 line has an unreadable round number in columns #{inspect(cols)}: #{whole}"
    end
  end

  # Ids sit in four-character fields every five columns from 13. The loop
  # takes a field only when all four characters are present, matching
  # bbpPairings' `startIndex <= line.size() - 4` condition; a trailing
  # partial field is not silently swallowed but caught below.
  defp read_260_ids(line, start, acc) do
    if start + 3 <= String.length(line) do
      case line |> read({start, start + 3}) |> Integer.parse() do
        {id, ""} ->
          read_260_ids(line, start + 5, [id | acc])

        _ ->
          if line |> String.slice((start - 1)..-1//1) |> String.trim() == "" do
            Enum.reverse(acc)
          else
            raise ValidationError,
              message: "260 line has an unreadable starting rank at column #{start}: #{line}"
          end
      end
    else
      Enum.reverse(acc)
    end
  end

  # `XXA` - per-player acceleration ("virtual points", FIDE C.04.7 Baku
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
  # is not hypothetical - the sibling project's own emitter is one column
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
            "XXA line has no starting rank in columns 5-8 (see Ainalrami.Trf's " <>
              "@xxa_rank_cols for the fixed-column layout): #{inspect(line)}"

    # APPENDS rather than replaces, matching `push_back` onto a player's
    # existing `accelerations` (`trf.cpp:510`) - `tournament.players[id]`
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

      :initial_colour ->
        case String.downcase(value) do
          "w" -> put_in(acc.tournament[:initial_colour], "w")
          "b" -> put_in(acc.tournament[:initial_colour], "b")
          _ -> acc
        end

      :deputy_arbiter ->
        update_in(acc.tournament.deputy_arbiters, &(&1 ++ [value]))

      f when f in [:start_date, :end_date] ->
        put_in(acc.tournament[f], String.replace(value, "/", "-"))

      :number_of_rounds ->
        rounds = parse_int(value) || 0
        check_round_count_agreement!(acc.tournament[:number_of_rounds], rounds)
        put_in(acc.tournament[:number_of_rounds], rounds)

      f
      when f in [
             :number_of_players,
             :number_of_rated_players,
             :number_of_teams
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
  # blank round - a fully-blank round block (FIDE's own "not paired", see
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
  # "U", "Z" and space (`trf.cpp:278-286`) - W/D/L are absent, so they are
  # played games against a real opponent - and it scores them through the
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
