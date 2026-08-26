defmodule Ainalrami.TeamPairing.Colour do
  @moduledoc """
  Article 4 - colour allocation for a paired team match.

  Runs after the whole round is paired (3.3.2's last step), never during.
  Nothing in Articles 2 or 3 can be decided by a colour, which is the
  regulation's own design: Article 0 says "the colour will never be a factor
  so decisive as to prevent two teams from playing against each other.
  Therefore, there are no absolute colour preferences outlined in these
  regulations." [C8]/[C9] count unfulfilled preferences to *rank* pairings,
  but no pairing is ever illegal for a colour reason.

  The colour decided here is board one's. The rest of the boards alternate
  from it, and that is the host application's job - it depends on the team's
  board order, which C.04.6 deliberately leaves to the competition.

  ## 4.3.1 and the open dispute

  4.3.1 is the same TPN-parity rule as the individual system's 5.2.5, and
  this project reads that rule against the handbook rather than against the
  reference implementations - see `docs/dispute-initial-colour.md`. The
  reading is applied consistently here: **the parity is the TPN's**, the
  number Article 1.1 fixes for the tournament, not a position within a
  bracket. Whatever the SPP answers about 5.2.5 applies here too, and
  `initial_colour_by_parity/2` is the single line that would change.
  """

  alias Ainalrami.TeamPairing.Team

  @doc """
  Allocates colours for one pair.

  Returns `{white_team, black_team}` - the pair re-ordered, not a decoration
  on it, so a caller cannot forget to apply the answer.

  Options:

    * `:initial_colour` - `:white` (default) or `:black`, drawn by lot
      before round one (4.1). Only 4.3.1 reads it.
    * `:score_mode` - `:match_points` (default) or `:game_points`; which is
      the primary score (1.2).
    * `:use_secondary?` - whether the secondary score breaks a 4.2 tie
      (1.2.1: "and whether the other is used for colour allocation").
      Defaults to true, per 1.2.2.
    * `:type` - `:a` (default) or `:b` colour preferences (1.7).
    * `:last_round?` - affects Type B mild preferences only.
  """
  def allocate(%Team{} = a, %Team{} = b, opts \\ []) do
    initial = Keyword.get(opts, :initial_colour, :white)
    mode = Keyword.get(opts, :score_mode, :match_points)
    use_secondary? = Keyword.get(opts, :use_secondary?, true)
    type = Keyword.get(opts, :type, :a)
    last_round? = Keyword.get(opts, :last_round?, false)

    {first, other} = first_team(a, b, mode, use_secondary?)

    first_colour =
      decide(first, other, initial, type, last_round?)

    case first_colour do
      :white -> {first, other}
      :black -> {other, first}
    end
  end

  @doc """
  The first-team of a pair (4.2), and the other one.

  4.2.1 higher primary score; else 4.2.2 higher secondary score (unless the
  competition says not to use it); else 4.2.3 smaller TPN. TPN is unique
  (1.1.1), so there is no fourth case and this always decides.
  """
  def first_team(%Team{} = a, %Team{} = b, mode \\ :match_points, use_secondary? \\ true) do
    cond do
      Team.score(a, mode) != Team.score(b, mode) ->
        if Team.score(a, mode) > Team.score(b, mode), do: {a, b}, else: {b, a}

      use_secondary? and Team.secondary_score(a, mode) != Team.secondary_score(b, mode) ->
        if Team.secondary_score(a, mode) > Team.secondary_score(b, mode),
          do: {a, b},
          else: {b, a}

      true ->
        if a.tpn < b.tpn, do: {a, b}, else: {b, a}
    end
  end

  # Article 4.3, in descending priority. Returns the FIRST-TEAM's colour.
  #
  # Written as one ordered `cond` rather than a chain of functions on
  # purpose: the article is an ordered list of nine rules where the first
  # applicable one decides, and a `cond` is that, in the same order, checkable
  # against the text line by line. Splitting it into named steps would read
  # better and make the ordering - the only thing that matters here - implicit.
  defp decide(first, other, initial, type, last_round?) do
    fp = Team.preference(first, type, last_round?)
    op = Team.preference(other, type, last_round?)
    fc = Team.preferred_colour(fp)
    oc = Team.preferred_colour(op)

    cond do
      # 4.3.1 - both teams have yet to play a match.
      Team.matches_played(first) == 0 and Team.matches_played(other) == 0 ->
        initial_colour_by_parity(first.tpn, initial)

      # 4.3.2 - only one team has a colour preference; grant it.
      not is_nil(fc) and is_nil(oc) ->
        fc

      is_nil(fc) and not is_nil(oc) ->
        opposite(oc)

      # 4.3.3 - opposite preferences; grant them both.
      not is_nil(fc) and not is_nil(oc) and fc != oc ->
        fc

      # 4.3.4 - Type B only: only one has a STRONG preference; grant it.
      # Reached only when both want the same colour (4.3.3 took the opposite
      # case), so granting one is refusing the other either way.
      type == :b and Team.strong?(fp) and not Team.strong?(op) ->
        fc

      type == :b and Team.strong?(op) and not Team.strong?(fp) ->
        opposite(oc)

      # 4.3.5 - White to the team with the LOWER colour difference. The
      # article's own note: -2 is lower than -1; +1 is lower than +2. That is
      # ordinary numeric order, spelled out because "lower" invites reading it
      # as "smaller in magnitude", which it is not.
      Team.colour_difference(first) != Team.colour_difference(other) ->
        if Team.colour_difference(first) < Team.colour_difference(other),
          do: :white,
          else: :black

      # 4.3.6 - alternate the colours to the most recent time one team had
      # White and the other Black.
      true ->
        case most_recent_split(first, other) do
          {:first_had, colour} ->
            opposite(colour)

          :none ->
            cond do
              # 4.3.7 - grant the first-team's preference.
              not is_nil(fc) ->
                fc

              # 4.3.8 - alternate the first-team's colour from its last
              # played round.
              (last = List.last(first.colours)) != nil ->
                opposite(last)

              # 4.3.9 - alternate the other team's colour from its last
              # played round.
              (last = List.last(other.colours)) != nil ->
                last

              # Both teams have played matches (4.3.1 did not fire) yet
              # neither has a colour: unreachable, since a played match has a
              # colour by 1.6.1. Fall back to the initial colour rather than
              # crash - a pairing must always produce an allocation.
              true ->
                initial
            end
        end
    end
  end

  @doc """
  4.3.1: an odd TPN takes the initial-colour, an even one the opposite.

  Kept as its own function because it is the line the open 5.2.5 dispute
  would change, and a reader looking for it should find it named rather than
  buried in a `cond`.
  """
  def initial_colour_by_parity(tpn, initial) when is_integer(tpn) do
    if rem(tpn, 2) == 1, do: initial, else: opposite(initial)
  end

  # 4.3.6 - walk both teams' played matches from the most recent backwards
  # and find the first round where they held opposite colours; report which
  # colour the FIRST-team held there, so the caller can hand it the other one
  # now.
  #
  # Indexing is from the END of each list, not by round number: `:colours`
  # holds only played matches, so two teams with different numbers of played
  # matches have their "most recent" at different absolute rounds. The
  # article says "the most recent time in which one team had White and the
  # other Black" - a time, walked back through what each team actually
  # played. Its note points at General Handling 3.4, which is the same
  # counting-played-games-only convention.
  defp most_recent_split(first, other) do
    a = Enum.reverse(first.colours)
    b = Enum.reverse(other.colours)

    Enum.zip(a, b)
    |> Enum.find_value(:none, fn {fc, oc} ->
      if fc != oc, do: {:first_had, fc}, else: nil
    end)
  end

  defp opposite(:white), do: :black
  defp opposite(:black), do: :white
end
