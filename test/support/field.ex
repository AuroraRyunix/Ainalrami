defmodule OpenPair.Test.Field do
  @moduledoc """
  Which players a round is actually supposed to pair.

  The comparison harnesses use this for the legality check: that the engine
  seated exactly the players it should have, and awarded a bye only on an odd
  field. That check is only worth something if "who should have been paired"
  comes from somewhere other than the engine under test.

  ## It did not, and the moduledoc used to claim it did

  This module previously derived the answer itself, opening with: "computed
  INDEPENDENTLY of `OpenPair.Pairing`, on purpose … this deliberately
  re-implements the rule rather than calling `OpenPair.Pairing`'s own
  (private) `rounds_played/1` … if they ever disagree, that disagreement is a
  finding".

  They could not disagree. The two functions were character-for-character
  identical — same structure, same literals, same helper names — because they
  are one person's port of one C++ function, written twice. An independent
  implementation is not the same thing as a second copy, and every "zero
  illegal rounds across N million pairings" claim rested on a check that
  shared its central assumption with the code it was checking. A wrong
  `rounds_played/1` would have been invisible to it, in exactly the way the
  62 phantom illegal rounds recorded below were visible only because the
  harness's rule differed.

  ## Where the answer comes from now

  `from_reference/1` reads the active set off **bbpPairings' own pairing for
  the same TRF**. bbpPairings decides which players a round seats by its own
  `playedRounds` and `evenUpMatchHistories`, compiled from C++ this project
  did not write, and the harnesses already run it on every round — the
  information was there all along. If OpenPair seats a different set of
  players than the reference did, that is now a real finding rather than a
  tautology.

  This deliberately does NOT make legality collapse into agreement. The two
  answer different questions and the harness still asks both: agreement is
  "did we choose the same pairing", legality is "is what we produced a
  well-formed round at all" — a partition of the right players, one bye only
  when the count is odd, no rematch, no second bye, no forbidden pair. An
  engine can seat the right people and still pair two of them illegally, and
  those checks read the players' own histories, never the active set.

  `derive/1` keeps the old self-derived rule, because two of the harnesses
  (`javafo_comparison_test.exs`, `completion_repair_test.exs`) have no
  bbpPairings result in hand at the point they need it. It is honestly
  labelled now: it is the engine's rule restated, and it can only catch a
  harness that computes something cruder, which is what it was born for.

  ## The rule `derive/1` restates

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

  ## Why the second step matters

  The harnesses used to compute this as `length(player.games) < round`, from
  their own loop counter. That silently disagreed with step 2: when a whole
  small field happened to draw a pre-assigned bye for the same round, the
  harness believed nobody was active while the engine (correctly, matching
  bbpPairings byte for byte) paired the round after it. A 100,000-tournament
  run reported 62 "illegal" rounds on 4-10 player fields that were nothing of
  the sort. The harness was measuring a rule it hadn't been taught.
  """

  @doc """
  The ranks bbpPairings seated for this round, as a MapSet — the reference's
  own answer to "who is active", taken from the pairing it produced.

  `pairs` is `[{white_rank, black_rank | nil}]` as `OpenPair.Test.Bbppairings`
  returns it; a `nil` black is the pairing-allocated bye, and that player is
  active too.
  """
  def from_reference(pairs) do
    pairs
    |> Enum.flat_map(fn
      {white, nil} -> [white]
      {white, black} -> [white, black]
    end)
    |> MapSet.new()
  end

  @doc """
  The players the engine's OWN rule says to seat.

  Not independent of `OpenPair.Pairing` — see the moduledoc. Use
  `from_reference/1` wherever a bbpPairings result is available.
  """
  def derive(players) do
    played = rounds_played(players)
    Enum.filter(players, &(length(&1.games) <= played))
  end

  @doc "Deprecated alias for `derive/1`, kept so the older harnesses read the same."
  def active(players), do: derive(players)

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
