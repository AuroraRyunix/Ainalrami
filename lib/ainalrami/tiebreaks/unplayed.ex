defmodule Ainalrami.Tiebreaks.Unplayed do
  @moduledoc """
  C.07 Article 16: how unplayed rounds count in Buchholz, Sonneborn-Berger
  and their variants in a Swiss event.

  Three things, each one article:

    * `category/3` - which of 16.2's five categories an unplayed round is.
      The only subtle one is a requested bye (a half- or zero-point bye,
      16.1.1): it is 16.2.3 when at least one later round was not a
      voluntary unplayed round, and 16.2.5 when every later round was one,
      or it is the last round.
    * `adjusted_score/2` - the participant's score as their OPPONENTS' tie-
      breaks see it (16.3): everything as awarded, except 16.2.5 rounds,
      which count as draws. A player who withdraws after round 5 of 9 is,
      to the people they played, a player who drew their last four.
    * `dummy_score/4` - the participant's OWN unplayed rounds are games
      against a dummy (16.4) whose score is the participant's own score,
      capped: at the scheduled opponent's adjusted score for a forfeit, at a
      draw's points times the number of rounds for anything else.

  None of this applies to events with pairings fixed in advance: Article
  15.2 treats their forfeits as games, and the callers take that branch
  before reaching here.
  """

  alias Ainalrami.Tiebreaks.Event.Round

  @vur_kinds [:half_bye, :zero_bye, :forfeit_loss]

  @doc "Whether a round is a voluntary unplayed round (16.1.2)."
  def vur?(%Round{kind: kind}), do: kind in @vur_kinds

  @doc """
  The 16.2 category of round `r` in `rounds` (a participant's round map),
  as the article's last digit: 1 (pairing-allocated or full-point bye),
  2 (forfeit win), 3 (requested bye followed by a round that is not a VUR),
  4 (forfeit loss), 5 (requested bye followed only by VURs, or in the last
  round). `nil` for a game played over the board.
  """
  def category(rounds, r, last_round) do
    case rounds[r].kind do
      :played -> nil
      kind when kind in [:pab, :full_bye] -> 1
      :forfeit_win -> 2
      :forfeit_loss -> 4
      kind when kind in [:half_bye, :zero_bye] -> requested_bye_category(rounds, r, last_round)
    end
  end

  defp requested_bye_category(rounds, r, last_round) do
    later = for later <- (r + 1)..last_round//1, do: rounds[later]
    if later != [] and Enum.any?(later, &(not vur?(&1))), do: 3, else: 5
  end

  @doc """
  16.3: the score an opponent's tie-break counts for this participant.
  """
  def adjusted_score(rounds, %{rounds: last_round, points: points}) do
    Enum.reduce(1..last_round//1, 0.0, fn r, acc ->
      round = rounds[r]

      acc +
        case category(rounds, r, last_round) do
          5 -> points.draw
          _ -> round.points
        end
    end)
  end

  @doc """
  16.4: the dummy's score for the participant's unplayed round `r`.

  `own_score` is the participant's score (reading 5 in
  docs/conformance-c07-tiebreaks.md: the actual score, not the adjusted
  one); `adjusted` maps every participant to their adjusted score, for the
  forfeit cap.
  """
  def dummy_score(rounds, r, own_score, adjusted, %{rounds: last_round, points: points}) do
    round = rounds[r]

    cap =
      case category(rounds, r, last_round) do
        c when c in [2, 4] -> Map.fetch!(adjusted, round.opponent)
        _ -> points.draw * last_round
      end

    min(own_score, cap)
  end
end
