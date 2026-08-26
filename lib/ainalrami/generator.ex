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

  Returns `{trf_text, seed}`.
  """
  def generate(opts \\ []) do
    seed = Keyword.get_lazy(opts, :seed, fn -> :erlang.unique_integer([:positive]) end)
    :rand.seed(:exsss, {seed, seed * 7919, seed * 104_729})

    players = Keyword.get_lazy(opts, :players, fn -> Enum.random(10..60) end)

    # A round-robin exhausts the field after `players - 1` rounds, and the
    # pairing has nothing legal left. Cap rather than let the engine fail.
    rounds =
      opts
      |> Keyword.get_lazy(:rounds, fn -> Enum.random(5..11) end)
      |> min(players - 1)

    forfeit_pct = Keyword.get(opts, :forfeit_pct, 0)
    bye_pct = Keyword.get(opts, :requested_bye_pct, 0)

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
      Enum.reduce_while(1..rounds, roster(players, accelerations), fn _round_no, current ->
        try do
          next =
            current
            |> grant_requested_byes(bye_pct)
            |> play_one_round(rounds, forfeit_pct, forbidden, initial_colour)

          {:cont, next}
        rescue
          Pairing.NoValidPairingError -> {:halt, current}
        end
      end)

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
          forbidden_pairs: forbidden
        },
        players: final
      }) <> "XXR #{rounds}\r\n"

    {text, seed}
  end

  defp roster(count, accelerations) do
    for rank <- 1..count do
      player = %{
        rank: rank,
        name: "Player#{rank}",
        fide_rating: Enum.random(1400..2700),
        points: 0.0,
        games: []
      }

      case Map.get(accelerations, rank) do
        nil -> player
        values -> Map.put(player, :accelerations, values)
      end
    end
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

  defp play_one_round(players, total_rounds, forfeit_pct, forbidden, initial_colour) do
    pairs =
      Pairing.pair_next_round(players,
        expected_rounds: total_rounds,
        forbidden_pairs: forbidden,
        initial_colour: initial_colour
      )

    by_rank = Enum.reduce(pairs, %{}, &record_game(&1, &2, forfeit_pct))

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

  defp record_game({white, nil}, acc, _forfeit_pct) do
    Map.put(acc, white, {%{opponent_rank: nil, colour: nil, result: "U"}, 1.0})
  end

  defp record_game({white, black}, acc, forfeit_pct) do
    {white_result, black_result, white_points, black_points} = outcome(forfeit_pct)

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
end
