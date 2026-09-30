defmodule Ainalrami.ByePreference.RefusedError do
  @moduledoc """
  Raised by `Ainalrami.ByePreference.pair/2` (and so by
  `Ainalrami.Pairing.pair_next_round/2` with `:bye_preferences`) when a
  "must get the bye" (`:want_hard`) applies to a round that has a
  pairing-allocated bye, for a player C.04.3 [C2] rules out of it: a second
  pairing-allocated bye, or one after a win without playing or a full-point
  bye. The round is not paired - silently pairing it without the wish would
  hide that the organiser asked for something the FIDE rules forbid.

  ## Fields

    * `:players` - one entry per such player, in rank order:
      `%{rank:, reason:, round:}`, `reason` being `:pairing_bye`,
      `:forfeit_win` or `:full_point_bye` and `round` the round of the game
      that rules them out (the earliest).
    * `:round` - the round that was being paired.
  """
  defexception [:message, players: [], round: nil]

  @doc false
  def reason_words(:pairing_bye), do: "already had the pairing-allocated bye"
  def reason_words(:forfeit_win), do: "already won a game without playing"
  def reason_words(:full_point_bye), do: "already had a full-point bye"
  def reason_words(other), do: to_string(other)
end
