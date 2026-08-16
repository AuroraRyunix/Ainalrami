defmodule OpenPair.Test.Field do
  @moduledoc """
  Which players a round is actually supposed to pair — computed
  INDEPENDENTLY of `OpenPair.Pairing`, on purpose.

  The comparison harnesses use this to check legality: that the engine
  seated exactly the players it should have, and awarded a bye only on an
  odd field. Those checks are only worth anything if "who should have been
  paired" is derived without asking the engine under test, so this
  deliberately re-implements the rule rather than calling
  `OpenPair.Pairing`'s own (private) `rounds_played/1`. Both are ports of
  the same primary source, cited below; if they ever disagree, that
  disagreement is a finding, not an inconvenience to paper over.

  ## The rule

  bbpPairings derives the round to pair in two steps.

  1. `trf.cpp:339-342` — `playedRounds` only advances for a game the player
     PARTICIPATED IN THE PAIRING for: a real opponent, or a `U`
     (pairing-allocated bye) / `+` (forfeit win, which still occupied a
     pairing slot). An arbiter-recorded `H`/`Z` bye does NOT advance it, so
     one player's pre-recorded bye cannot drag the round number forward and
     strand everyone else.
  2. `trf.cpp:646-684` (`evenUpMatchHistories`) — then, in pairing mode
     (`main.cpp:452` passes `includesUnpairedRound = true`), if EVERY valid
     player already holds a game for the trailing column, that column is a
     round already fully decided, so it counts as played and the round to
     pair is the one after it.

  A player is then paired this round iff they don't already have a result
  for it (`dutch.cpp:658`'s `player.matches.size() <= playedRounds`).

  ## Why this module exists

  The harnesses used to compute this as `length(player.games) < round`,
  from their own loop counter. That silently disagreed with step 2: when a
  whole small field happened to draw a pre-assigned bye for the same round,
  the harness believed nobody was active while the engine (correctly,
  matching bbpPairings byte for byte) paired the round after it. A
  100,000-tournament run reported 62 "illegal" rounds on 4-10 player fields
  that were nothing of the sort — every one of them agreed with
  bbpPairings exactly. The harness was measuring a rule it hadn't been
  taught.
  """

  @doc "The players a correct engine should seat in the next round."
  def active(players) do
    played = rounds_played(players)
    Enum.filter(players, &(length(&1.games) <= played))
  end

  @doc "How many rounds are already complete — see the moduledoc."
  def rounds_played(players) do
    base = players |> Enum.map(&paired_through/1) |> max_or_zero()

    if players != [] and Enum.all?(players, &(length(&1.games) > base)) do
      base + 1
    else
      base
    end
  end

  defp paired_through(player) do
    player.games
    |> Enum.with_index(1)
    |> Enum.filter(fn {game, _round} -> participated_in_pairing?(game) end)
    |> Enum.map(fn {_game, round} -> round end)
    |> max_or_zero()
  end

  defp participated_in_pairing?(game) do
    not is_nil(game.opponent_rank) or game.result in ["U", "+"]
  end

  defp max_or_zero([]), do: 0
  defp max_or_zero(values), do: Enum.max(values)
end
