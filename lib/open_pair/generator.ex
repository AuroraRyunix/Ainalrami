defmodule OpenPair.Generator do
  @moduledoc """
  Random Tournament Generator (RTG) — JaVaFo's `-g` role.

  Builds a random roster, then plays it forward: each round is paired by
  `OpenPair.Pairing` itself and given random results. That the generator
  pairs with the engine under test is deliberate and matches bbpPairings'
  own RTG (`tournament/generator.cpp` calls `computeMatching` inside its
  round loop) — the point of an RTG in FIDE's FE1 auto-test is to produce
  tournaments whose pairings a *reference checker* can then verify, so the
  pairings have to be the candidate program's own.

  ## Reproducibility

  Every tournament is generated from a seed, and the seed is recorded in
  the file so any run can be reproduced from its own output.

  bbpPairings writes the seed as the literal first line of the output,
  before generating anything, so a crash still leaves it recoverable. That
  would make the file invalid TRF, so this writes it into the tournament
  name (`012`) instead — the first line of a TRF anyway, valid, and
  carried by every parser. The recoverable-on-crash property is kept by
  choosing the seed before any generation work happens.

  ## What it varies

  Roster size, round count, ratings, and results. Optionally forfeits and
  arbiter-assigned byes, both off by default — see `generate/1`.

  Retirements are NOT modelled: a retired player is expressed as a run of
  arbiter-assigned byes to the end of the tournament, which
  `:requested_bye_pct` already produces in isolated rounds, and nothing in
  the pairing rules treats a run of them differently from single ones.
  """

  alias OpenPair.{Pairing, Trf}

  @doc """
  Generates a tournament and returns its TRF16 text.

  Options, all optional:

    * `:seed` — integer seed; a random one is chosen and reported if absent
    * `:players` — roster size (default: random 10..60)
    * `:rounds` — rounds to play (default: random 5..11, capped so the
      field can't run out of legal opponents)
    * `:forfeit_pct` — percentage of games forfeited (default 0)
    * `:requested_bye_pct` — percentage of players granted an
      arbiter-assigned half- or zero-point bye each round (default 0)

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

    final =
      Enum.reduce(1..rounds, roster(players), fn _round, current ->
        current
        |> grant_requested_byes(bye_pct)
        |> play_one_round(rounds, forfeit_pct)
      end)

    text =
      Trf.serialize(%{
        tournament: %{name: "OpenPair RTG seed=#{seed}", type: "swiss"},
        players: final
      }) <> "XXR #{rounds}\r\n"

    {text, seed}
  end

  defp roster(count) do
    for rank <- 1..count do
      %{
        rank: rank,
        name: "Player#{rank}",
        fide_rating: Enum.random(1400..2700),
        points: 0.0,
        games: []
      }
    end
  end

  # An arbiter-assigned bye is granted BEFORE the round is paired and
  # recorded in advance, which is exactly how the engine knows to leave
  # that player out — see `OpenPair.Pairing`'s `active_this_round?/2`.
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

  defp play_one_round(players, total_rounds, forfeit_pct) do
    pairs = Pairing.pair_next_round(players, expected_rounds: total_rounds)
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
