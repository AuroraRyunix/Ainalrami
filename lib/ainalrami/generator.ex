defmodule Ainalrami.Generator do
  @moduledoc """
  Random Tournament Generator (RTG) - JaVaFo's `-g` role.

  Builds a random roster, then plays it forward: each round is paired by
  `Ainalrami.Pairing` itself and given random results. That the generator
  pairs with the engine under test is deliberate and matches bbpPairings'
  own RTG (`tournament/generator.cpp` calls `computeMatching` inside its
  round loop) - the point of an RTG in FIDE's FE1 auto-test is to produce
  tournaments whose pairings a *reference checker* can then verify, so the
  pairings have to be the candidate program's own.

  ## Reproducibility

  Every tournament is generated from a seed, and the seed is recorded in
  the file so any run can be reproduced from its own output.

  bbpPairings writes the seed as the literal first line of the output,
  before generating anything, so a crash still leaves it recoverable. That
  would make the file invalid TRF, so this writes it into the tournament
  name (`012`) instead - the first line of a TRF anyway, valid, and
  carried by every parser. The recoverable-on-crash property is kept by
  choosing the seed before any generation work happens.

  ## What it varies

  Roster size, round count, ratings, and results. Optionally forfeits,
  arbiter-assigned byes, `XXP` forbidden pairings and `XXA` acceleration -
  all four off by default, see `generate/1`.

  Retirements are NOT modelled: a retired player is expressed as a run of
  arbiter-assigned byes to the end of the tournament, which
  `:requested_bye_pct` already produces in isolated rounds, and nothing in
  the pairing rules treats a run of them differently from single ones.
  """

  alias Ainalrami.{Pairing, Trf}

  @doc """
  Generates a tournament and returns its TRF16 text.

  Options, all optional:

    * `:seed` - integer seed; a random one is chosen and reported if absent
    * `:players` - roster size (default: random 10..60)
    * `:rounds` - rounds to play (default: random 5..11, capped so the
      field can't run out of legal opponents)
    * `:forfeit_pct` - percentage of games forfeited (default 0)
    * `:requested_bye_pct` - percentage of players granted an
      arbiter-assigned half- or zero-point bye each round (default 0)
    * `:forbidden_pct` - percentage of players given one arbiter-forbidden
      opponent, emitted as `XXP` lines (default 0)
    * `:acceleration` - `:baku` for FIDE C.04.7's virtual points, or
      `:random` for arbitrary per-player-per-round ones; emitted as `XXA`
      lines (default: none)
    * `:names` - `:ascii` (default) for `Player17`, or `:unicode` to draw
      surnames with multibyte characters

  `:players` must be a positive integer and `:rounds` a non-negative one.
  Either given otherwise raises `ArgumentError` rather than being quietly
  turned into a tournament nobody asked for - see `validate_count!/3`.

  Returns `{trf_text, seed}`.
  """
  def generate(opts \\ []) do
    seed = Keyword.get_lazy(opts, :seed, fn -> :erlang.unique_integer([:positive]) end)
    :rand.seed(:exsss, {seed, seed * 7919, seed * 104_729})

    names = validate_names!(Keyword.get(opts, :names, :ascii))

    players =
      opts
      |> Keyword.get_lazy(:players, fn -> Enum.random(10..60) end)
      |> validate_count!(:players, 1)

    # A round-robin exhausts the field after `players - 1` rounds, and the
    # pairing has nothing legal left. Cap rather than let the engine fail.
    rounds =
      opts
      |> Keyword.get_lazy(:rounds, fn -> Enum.random(5..11) end)
      |> validate_count!(:rounds, 0)
      |> min(players - 1)

    forfeit_pct = Keyword.get(opts, :forfeit_pct, 0)
    bye_pct = Keyword.get(opts, :requested_bye_pct, 0)

    # FIDE's checklist axes (VCL4THP v13 Q24-Q32), all opt-in - see
    # "Checklist options" below. With none of them given, the tournament is
    # byte-for-byte what this seed always produced.
    results = results_config(opts)
    byes = bye_config(opts)
    ratings = Keyword.get(opts, :ratings)
    tie_breaks = Keyword.get(opts, :tie_breaks)

    # Article 5.1's drawing of lots. It was always White here, implicitly:
    # nothing was passed to the engine, which defaulted, and nothing was
    # written to the file, which left a reader to infer it back. Now it is
    # an option AND is recorded, so a generated tournament states the draw
    # it was actually paired under instead of leaving it to be reconstructed.
    initial_colour = opts |> Keyword.get(:initial_colour, "w") |> String.downcase()
    forbidden = forbidden_pairs(players, Keyword.get(opts, :forbidden_pct, 0))
    accelerations = accelerations(players, rounds, Keyword.get(opts, :acceleration))

    # A round can have no legal completion at all - not the engine failing
    # to search hard enough, but a proven deadlock (`Ainalrami.Pairing`'s
    # `repair_bye_count/3` only raises `NoValidPairingError` after its own
    # maximum-weight-matching repair pass already confirmed no better
    # pairing exists). Realistic with arbiter-assigned byes stacking
    # colour-absolute exclusions on top of an already near-exhausted small
    # field. Same philosophy as the `players - 1` cap above - stop the
    # tournament at the last round that actually completed rather than
    # letting one bad round crash the whole generation.
    final =
      Enum.reduce_while(1..rounds//1, roster(players, accelerations, names, ratings), fn round_no,
                                                                                         current ->
        try do
          next =
            current
            |> grant_requested_byes(bye_pct)
            |> grant_byes(round_no, byes)
            |> play_one_round(round_no, rounds, {forfeit_pct, results}, forbidden, initial_colour)

          {:cont, next}
        rescue
          Pairing.NoValidPairingError -> {:halt, current}
        end
      end)

    {final, tie_breaks} = with_final_ranks(final, rounds, tie_breaks)

    text =
      Trf.serialize(%{
        tournament: %{
          name: "Ainalrami RTG seed=#{seed}",
          type: "swiss",
          # Written as TRF16's own `142` field AND as JaVaFo's `XXR`
          # extension below. Emitting only the latter meant a reader that
          # knew just `142` got no round count at all, which silently
          # changed the final-round pairing - see `Ainalrami.Trf`'s
          # `parse_xxr/2`.
          #
          # `rounds`, the count every round was PAIRED under, not
          # `played_rounds`, the count that actually completed. The two
          # differ whenever the reduce above halts early on a deadlocked
          # round, and this field means the tournament's intended length -
          # `expected_rounds` - not its progress. Writing the truncated
          # number handed a reader a file whose rounds were paired under
          # one round count and which declares another. It feeds exactly
          # one rule, `final_round_topscorers?/2`'s
          # `played_rounds >= expected_rounds - 1` gate, which relaxes the
          # colour constraints for the last two rounds: a nine-round
          # generation that deadlocked at seven declared seven, so a reader
          # re-pairing round 7 applied the final-round exception to a round
          # this generator had paired as an ordinary one - and the
          # disagreement looked like an engine defect rather than a
          # mislabelled file.
          number_of_rounds: rounds,
          initial_colour: initial_colour,
          forbidden_pairs: forbidden,
          tie_breaks: tie_breaks
        },
        players: final
      }) <> "XXR #{rounds}\r\n"

    {text, seed}
  end

  # `1..count//1` and `1..rounds//1` throughout, not `1..count`. Elixir's
  # two-argument range steps by -1 when its end is below its start, so
  # `1..0` was TWO rounds and `1..-5` was seven players with ranks running
  # 1, 0, -1 ... -5 - written to a file, exit 0, nothing said. The counts
  # are validated on the way in as well, because a caller who asked for -5
  # players wants to hear about it rather than get an empty roster.
  defp roster(count, accelerations, names, ratings) do
    for rank <- 1..count//1 do
      player = %{
        rank: rank,
        name: player_name(names, rank),
        fide_rating: rating(ratings, rank),
        points: 0.0,
        games: []
      }

      case Map.get(accelerations, rank) do
        nil -> player
        values -> Map.put(player, :accelerations, values)
      end
    end
  end

  defp validate_count!(value, _key, minimum) when is_integer(value) and value >= minimum,
    do: value

  defp validate_count!(value, key, minimum) do
    raise ArgumentError,
          "#{inspect(key)} must be an integer of at least #{minimum}, got #{inspect(value)}"
  end

  # ---------------------------------------------------------------------
  # Names
  # ---------------------------------------------------------------------

  # The corpus's blind spot, made visible.
  #
  # Every one of the ~488M validated pairings went through a TRF this
  # generator wrote and this engine read, and the names in it were always
  # `Player17`. So the question TRF16 actually asks - what a "column" is
  # when the name field holds multibyte characters - was never put to the
  # corpus at all. bbpPairings counts bytes, JaVaFo counts Java chars, this
  # engine counts bytes since the 2026-09-01 sweep; on ASCII all three
  # agree, and a fuzz corpus made only of ASCII cannot tell them apart.
  #
  # Off by default, deliberately and permanently: every recorded seed has to
  # keep producing the same bytes it produced before this option existed, or
  # the validated corpus stops being reproducible. `names: :unicode` is an
  # axis a run opts into.
  #
  # The list is short and chosen for coverage rather than realism - two-byte
  # Latin-1 supplements, a three-byte combining case, a Vietnamese name
  # whose diacritics stack, and one with a space in it (surnames with spaces
  # are the other thing a fixed-width name field has to survive).
  @unicode_surnames [
    "Đurić",
    "Björn",
    "Ó Súilleabháin",
    "Nguyễn",
    "Łukasiewicz",
    "Ștefănescu"
  ]

  defp validate_names!(mode) when mode in [:ascii, :unicode], do: mode

  defp validate_names!(mode) do
    raise ArgumentError, ":names must be :ascii or :unicode, got #{inspect(mode)}"
  end

  defp player_name(:ascii, rank), do: "Player#{rank}"

  defp player_name(:unicode, rank) do
    "#{Enum.at(@unicode_surnames, rem(rank - 1, length(@unicode_surnames)))} #{rank}"
  end

  # One `XXP` group of two per selected player. Groups are emitted verbatim
  # and may overlap, which is fine and realistic - an arbiter separating a
  # family of three writes three lines (or one of three ids, which
  # `Ainalrami.Trf` also reads).
  #
  # Deliberately allowed to make the tournament unpairable. bbpPairings
  # answers that with its own no-valid-pairing exit and the comparison
  # harness ends the tournament there, so an over-constrained field is a
  # measured case rather than a generator bug - and the alternative,
  # filtering the pairs down to a provably-satisfiable set, would build the
  # very rule under test into the fixture.
  defp forbidden_pairs(_count, pct) when pct <= 0, do: []

  defp forbidden_pairs(count, _pct) when count < 2, do: []

  defp forbidden_pairs(count, pct) do
    for rank <- 1..count, :rand.uniform(100) <= pct do
      other = Enum.random(Enum.reject(1..count, &(&1 == rank)))
      Enum.sort([rank, other])
    end
    |> Enum.uniq()
  end

  # FIDE C.04.7's Baku acceleration, or arbitrary virtual points.
  #
  # The `:baku` shape is the FIDE text as the sibling project's own
  # `acceleration_lines/4` reads it: Group A is the top `2 * ceil(n/4)`
  # players by starting rank, the accelerated rounds are the first
  # `ceil(rounds/2)`, and within those the first `ceil(accelerated/2)` pay
  # a full virtual point and the rest a half.
  #
  # Worth recording that bbpPairings' OWN Baku (`applyBakuAcceleration`,
  # `trf.cpp:708-753`) sizes Group A differently - `(n - 1) / 2` as a
  # 0-based last rank, i.e. `ceil(n/2)` players, so 5 rather than 6 on a
  # 10-player field - while agreeing exactly on the round split. That path
  # is only reached through its own Baku flag, never through `XXA`, so it
  # cannot make the two engines disagree here: both read the identical
  # `XXA` lines out of the identical file. The generator follows the
  # sibling's reading because that is what Ainalrami will actually be handed
  # in production.
  defp accelerations(_count, _rounds, nil), do: %{}

  defp accelerations(count, rounds, :baku) do
    group_a = 2 * ceil_div(count, 4)
    accelerated = ceil_div(rounds, 2)
    full = ceil_div(accelerated, 2)

    values =
      Enum.map(1..rounds//1, fn round ->
        cond do
          round <= full -> 1.0
          round <= accelerated -> 0.5
          true -> 0.0
        end
      end)

    Map.new(1..min(group_a, count)//1, &{&1, values})
  end

  defp accelerations(count, rounds, :random) do
    Map.new(1..count//1, fn rank ->
      {rank, Enum.map(1..rounds//1, fn _ -> Enum.random([0.0, 0.0, 0.5, 1.0]) end)}
    end)
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)

  # An arbiter-assigned bye is granted BEFORE the round is paired and
  # recorded in advance, which is exactly how the engine knows to leave
  # that player out - see `Ainalrami.Pairing`'s `active_this_round?/2`.
  defp grant_requested_byes(players, 0), do: players

  defp grant_requested_byes(players, pct) do
    Enum.map(players, fn player ->
      if :rand.uniform(100) <= pct do
        {result, points} = Enum.random([{"H", 0.5}, {"Z", 0.0}])

        %{
          player
          | points: player.points + points,
            games: player.games ++ [%{opponent_rank: nil, colour: nil, result: result}]
        }
      else
        player
      end
    end)
  end

  # Everybody already sat this round out on a bye granted before the
  # pairing. Nobody then looks absent to the engine, which would pair the
  # NEXT round - two rounds written for one, and a file with one round more
  # than its `142` says (found by the tie-break comparison, seed 1002432).
  defp play_one_round(players, round_no, total_rounds, outcomes, forbidden, initial_colour) do
    if Enum.all?(players, &(length(&1.games) >= round_no)),
      do: players,
      else: pair_and_play(players, total_rounds, outcomes, forbidden, initial_colour)
  end

  defp pair_and_play(players, total_rounds, outcomes, forbidden, initial_colour) do
    pairs =
      Pairing.pair_next_round(players,
        expected_rounds: total_rounds,
        forbidden_pairs: forbidden,
        initial_colour: initial_colour
      )

    ratings = Map.new(players, &{&1.rank, &1.fide_rating})
    by_rank = Enum.reduce(pairs, %{}, &record_game(&1, &2, outcomes, ratings))

    Enum.map(players, fn player ->
      case Map.fetch(by_rank, player.rank) do
        {:ok, {game, points}} ->
          %{player | points: player.points + points, games: player.games ++ [game]}

        # Sat this round out on a bye granted before the pairing.
        :error ->
          player
      end
    end)
  end

  defp record_game({white, nil}, acc, _outcomes, _ratings) do
    Map.put(acc, white, {%{opponent_rank: nil, colour: nil, result: "U"}, 1.0})
  end

  defp record_game({white, black}, acc, {forfeit_pct, results}, ratings) do
    {white_result, black_result, white_points, black_points} =
      case results do
        nil -> outcome(forfeit_pct)
        config -> checklist_outcome(forfeit_pct, config, ratings[white], ratings[black])
      end

    acc
    |> Map.put(white, {%{opponent_rank: black, colour: "w", result: white_result}, white_points})
    |> Map.put(black, {%{opponent_rank: white, colour: "b", result: black_result}, black_points})
  end

  defp outcome(forfeit_pct) do
    if forfeit_pct > 0 and :rand.uniform(100) <= forfeit_pct do
      Enum.random([
        {"+", "-", 1.0, 0.0},
        {"-", "+", 0.0, 1.0},
        {"-", "-", 0.0, 0.0}
      ])
    else
      Enum.random([
        {"1", "0", 1.0, 0.0},
        {"0", "1", 0.0, 1.0},
        {"=", "=", 0.5, 0.5}
      ])
    end
  end

  # ---------------------------------------------------------------------
  # Checklist options (VCL4THP v13 Q24-Q32)
  # ---------------------------------------------------------------------
  #
  # Every one of these is opt-in and none of them draws a random number
  # unless given: the validated corpus is reproduced from seeds, so a seed
  # that produced a file before these options existed has to produce the
  # same bytes now. `generator_checklist_test.exs` holds default generation
  # to a checked-in digest for that reason.

  # Q27-Q29: ratings given, bounded, stepped, or - the default - random.
  #   * a list: the rating of each TPN in order (Q27)
  #   * `{:range, min, max}`: uniform in the range (Q28)
  #   * `{:step, top, step}` / `{:step, top, step, sigma}`: TPN 1 rated
  #     `top`, each next one `step` lower, plus normal noise of `sigma` if
  #     given (Q28) - TieBreakServer's generator parametrises it the same way
  defp rating(nil, _rank), do: Enum.random(1400..2700)

  defp rating(ratings, rank) when is_list(ratings) do
    case Enum.at(ratings, rank - 1) do
      r when is_integer(r) and r >= 0 -> r
      other -> raise ArgumentError, ":ratings has no rating for TPN #{rank} (#{inspect(other)})"
    end
  end

  defp rating({:range, low, high}, _rank) when low <= high, do: Enum.random(low..high)
  defp rating({:step, top, step}, rank), do: max(top - (rank - 1) * step, 0)

  defp rating({:step, top, step, sigma}, rank),
    do: max(round(top - (rank - 1) * step + :rand.normal() * sigma), 0)

  defp rating(other, _rank), do: raise(ArgumentError, "unknown :ratings #{inspect(other)}")

  # Q32 and Q24's result axes. nil - the old uniform draw, untouched - unless
  # one of them is given.
  @result_keys [:results, :draw_rate, :forfeit_win_pct, :double_forfeit_pct, :odd_results_pct]

  defp results_config(opts) do
    if Enum.any?(@result_keys, &Keyword.has_key?(opts, &1)) do
      mode = Keyword.get(opts, :results, :uniform)

      unless mode in [:uniform, :fide],
        do: raise(ArgumentError, ":results must be :uniform or :fide, got #{inspect(mode)}")

      %{
        mode: mode,
        draw_rate: Keyword.get(opts, :draw_rate, 0.3),
        forfeit_win_pct: Keyword.get(opts, :forfeit_win_pct, 0),
        double_forfeit_pct: Keyword.get(opts, :double_forfeit_pct, 0),
        odd_results_pct: Keyword.get(opts, :odd_results_pct, 0)
      }
    end
  end

  defp checklist_outcome(forfeit_pct, config, white_rating, black_rating) do
    cond do
      forfeit_pct > 0 and :rand.uniform(100) <= forfeit_pct ->
        outcome(100)

      config.forfeit_win_pct > 0 and :rand.uniform(100) <= config.forfeit_win_pct ->
        Enum.random([{"+", "-", 1.0, 0.0}, {"-", "+", 0.0, 1.0}])

      config.double_forfeit_pct > 0 and :rand.uniform(100) <= config.double_forfeit_pct ->
        {"-", "-", 0.0, 0.0}

      # Q24's "unusual over-the-board results": a game played, scored
      # 1/2-0, 0-1/2 or 0-0 by the arbiter.
      config.odd_results_pct > 0 and :rand.uniform(100) <= config.odd_results_pct ->
        Enum.random([{"=", "0", 0.5, 0.0}, {"0", "=", 0.0, 0.5}, {"0", "0", 0.0, 0.0}])

      config.mode == :fide ->
        fide_result(white_rating, black_rating, config.draw_rate)

      true ->
        outcome(0)
    end
  end

  # Q32: results whose expectation is FIDE's expected score. With E the
  # white player's expected score from the rating table and d the draw
  # rate, White wins with probability E - d/2 and draws with d, so the
  # expected score is exactly E - over many tournaments a player's rating
  # change averages zero, which is what the checklist asks. d is capped at
  # 2 min(E, 1 - E) so neither probability goes negative.
  defp fide_result(white_rating, black_rating, draw_rate) do
    e = Ainalrami.Tiebreaks.Rating.expected_hundredths(white_rating, black_rating) / 100
    d = min(draw_rate, 2 * min(e, 1 - e))
    u = :rand.uniform()

    cond do
      u < e - d / 2 -> {"1", "0", 1.0, 0.0}
      u < e + d / 2 -> {"=", "=", 0.5, 0.5}
      true -> {"0", "1", 0.0, 1.0}
    end
  end

  # Q24's bye axes: each player, each round, may be given a full-point,
  # half-point or zero-point bye, at separate percentages. Before the round
  # is paired, like `grant_requested_byes/2`, and never a second one in the
  # same round.
  defp bye_config(opts) do
    config = %{
      full: Keyword.get(opts, :full_bye_pct, 0),
      half: Keyword.get(opts, :half_bye_pct, 0),
      zero: Keyword.get(opts, :zero_bye_pct, 0)
    }

    if Enum.all?(Map.values(config), &(&1 <= 0)), do: nil, else: config
  end

  defp grant_byes(players, _round_no, nil), do: players

  defp grant_byes(players, round_no, config) do
    Enum.map(players, fn player ->
      if length(player.games) >= round_no do
        player
      else
        bye =
          cond do
            config.full > 0 and :rand.uniform(100) <= config.full -> {"F", 1.0}
            config.half > 0 and :rand.uniform(100) <= config.half -> {"H", 0.5}
            config.zero > 0 and :rand.uniform(100) <= config.zero -> {"Z", 0.0}
            true -> nil
          end

        case bye do
          nil ->
            player

          {code, points} ->
            %{
              player
              | points: player.points + points,
                games: player.games ++ [%{opponent_rank: nil, colour: nil, result: code}]
            }
        end
      end
    end)
  end

  # Q31: with a tie-break list, the file carries it (`202`) and the final
  # standings it gives (columns 86-89), computed by `Ainalrami.Tiebreaks`.
  # Players still tied after the whole list are placed in TPN order - the
  # order a drawing of lots would have to settle, and one the checker
  # accepts.
  defp with_final_ranks(players, _rounds, nil), do: {players, nil}

  defp with_final_ranks(players, rounds, tie_breaks) do
    event =
      Ainalrami.Tiebreaks.Event.from_trf(%{
        players: players,
        tournament: %{number_of_rounds: rounds}
      })

    case Ainalrami.Tiebreaks.rank(event, ["PTS" | List.wrap(tie_breaks)]) do
      {:ok, standings} ->
        place = standings |> Enum.with_index(1) |> Map.new(fn {row, i} -> {row.id, i} end)
        {Enum.map(players, &Map.put(&1, :final_rank, place[&1.rank])), tie_breaks}

      {:error, reason} ->
        raise ArgumentError, ":tie_breaks - #{reason}"
    end
  end
end
