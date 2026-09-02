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

  ## 4.3.1 and which number its parity is taken on

  4.3.1 is the same parity rule as the individual system's 5.2.5, and this
  project once read both against the handbook's fixed TPN rather than
  against the reference implementations. The FIDE Systems of Pairings and
  Programs Commission ruled against that reading on 2026-08-27: per C.04.2
  Article 2.4, late entries "are given an appropriate TPN and paired only
  when they actually arrive", so a participant who has not arrived has no
  number at all. The parity is therefore taken on a team's position among
  the teams that have ARRIVED, and the arrivals are renumbered 1..k each
  round. `Ainalrami.Pairing`'s `arrival_numbers/2` carries the full ruling
  and the empirical work behind it.

  That number reaches `initial_colour_by_parity/2` through
  `allocate/3`'s `:parity_numbers` option, and the moduledoc used to claim
  that `initial_colour_by_parity/2` "is the single line that would change".
  It was wrong, and the correction is worth stating because the shape of
  the claim is a recurring trap: the function is a pure function of
  `(number, initial)` and the ruling does not change what it *computes*, it
  changes WHICH NUMBER is handed to it - and that number is not derivable
  from anything in scope at the call site. The real change was a chain of
  four: `Ainalrami.TeamPairing.pair_round/2` (the only place that holds the
  team list) builds the numbering, `allocate/3` takes it as an option,
  `decide/6` carries it, and only then does the parity line run.

  ## What "arrived" means for a team, and where the model runs out

  C.04.6 has no Article 2.4 of its own, and `Ainalrami.TeamPairing.Team`
  carries no per-round history: `:colours` holds played matches only,
  `:opponents` holds TPNs met, and nothing records "was entered into a
  round's pairing whose match was not played". So a team's arrival cannot
  be reconstructed from the struct the way a player's can be from their
  TRF game list.

  For a team that has NEVER arrived it does not have to be. `pair_round/2`
  pairs the entire roster it is handed - every team in that list is either
  paired or takes the PAB, none of them sits out of it - so every team in
  the list is in this round's pairing pool and has arrived by exactly the
  test the individual side uses. The numbering is therefore the 1-based
  position in ascending TPN among the teams given, which is the TPN itself
  only when the roster's TPNs happen to be a contiguous 1..N. A host that
  keeps a not-yet-arrived team in the list would have that team paired; a
  host that omits it gets the renumbering for free.

  Sitting out is expressed by leaving the team OUT of that list, which is
  where the next section starts.

  ## The divergence from the individual rule, which is a DEFECT

  A team that has ARRIVED and is then absent - sitting a round out, or
  withdrawn after playing - is numbered differently here than the same
  situation is on the individual side, and this moduledoc used to deny that
  the case could arise at all ("a host that keeps a not-yet-arrived team in
  the list would have that team paired, so the case cannot arise"). That
  sentence was true only of the NEVER-arrived team and sent the reader past
  the case that does arise.

  The individual rule numbers an arrived player forever:
  `Ainalrami.Pairing`'s `arrived_for?/2` has a second clause for exactly
  this ("participated in some round strictly before this one"), and
  `do_pair_later_round/1` builds the numbering over the FULL roster rather
  than the active field precisely so a player who sits a round out does not
  give their number back. This module numbers the list it was handed. A
  host that drops an absent team from that list therefore renumbers
  everyone below it, which is the opposite answer.

  **That is a defect, not a licensed difference between the chapters.**
  C.04.6 says nothing that would make an absent team's number behave
  differently from an absent player's; the answers differ only because the
  absent team is not in the data this module receives. It is not a corner
  either - it is reachable inside 4.3.1's own window, which needs both
  teams on zero played matches: a team that takes the PAB in round 1 has
  arrived with `matches_played == 0`, and if it is absent for round 2 it
  can still meet 4.3.1 in round 3 - by which point every team below it has
  shifted up one and flipped parity.

  It cannot be fixed here. The absent team is not in scope: `allocate/3`
  sees two teams and `parity_numbers/1` sees a list, and neither can
  reconstruct a team the caller did not pass. The fix belongs on
  `Ainalrami.TeamPairing.pair_round/2`, which would need an absentee or
  full-roster argument distinct from "the teams to pair this round", plus
  enough of a per-round record on `Ainalrami.TeamPairing.Team` to tell
  "never arrived" from "arrived, not playing today" - the struct has no
  such field today, and `:had_pab?` covers only the one arrival that leaves
  no colour behind. Pinned by a test in `team_pairing_test.exs` so the
  behaviour is recorded rather than assumed, and listed in
  `docs/conformance-c0406-teams.md`'s open questions.
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
    * `:parity_numbers` - `%{tpn => number}`, the round's arrival numbering,
      whose parity 4.3.1 reads. Built once per round by
      `Ainalrami.TeamPairing.pair_round/2` over the whole roster and passed
      down; see the moduledoc. Omitted, it defaults to a numbering over the
      two teams given, which is what a caller pairing exactly these two
      teams is entitled to - a two-team tournament numbers them 1 and 2.
      It is deliberately NOT defaulted to the raw TPN: that is the reading
      the SPP overturned, and a silent fallback to it would put the
      overturned rule back on every path that forgot the option.
  """
  def allocate(%Team{} = a, %Team{} = b, opts \\ []) do
    initial = Keyword.get(opts, :initial_colour, :white)
    mode = Keyword.get(opts, :score_mode, :match_points)
    use_secondary? = Keyword.get(opts, :use_secondary?, true)
    type = Keyword.get(opts, :type, :a)
    last_round? = Keyword.get(opts, :last_round?, false)
    numbers = validate_parity_numbers!(Keyword.get(opts, :parity_numbers), a, b)

    {first, other} = first_team(a, b, mode, use_secondary?)

    first_colour =
      decide(first, other, initial, type, last_round?, numbers)

    case first_colour do
      :white -> {first, other}
      :black -> {other, first}
    end
  end

  # 4.3.1 reads the parity off the ROUND's arrival numbering, so `decide/6`
  # takes `Map.fetch!(numbers, first.tpn)` - deliberately, because falling
  # back to the TPN would silently restore the reading the SPP overturned.
  # But `allocate/3`'s own `@doc` invites a host to build that numbering and
  # pass it in, and a numbering that does not cover this pair came back as
  # `** (KeyError) key 7 not found` out of a private function, naming
  # neither the option nor the team. Checked at the boundary instead.
  defp validate_parity_numbers!(nil, a, b), do: parity_numbers([a, b])

  defp validate_parity_numbers!(numbers, a, b) when is_map(numbers) do
    missing = Enum.reject([a.tpn, b.tpn], &Map.has_key?(numbers, &1))

    if missing == [] do
      numbers
    else
      raise ArgumentError,
            ":parity_numbers must cover both teams of the pair (Article 4.3.1) - " <>
              "no number for #{Enum.map_join(missing, " and ", &"TPN #{&1}")}"
    end
  end

  defp validate_parity_numbers!(numbers, _a, _b) do
    raise ArgumentError, ":parity_numbers must be a map of tpn => number, got #{inspect(numbers)}"
  end

  @doc """
  The round's arrival numbering: `%{tpn => number}`, teams walked in
  ascending TPN and handed consecutive integers from 1.

  4.3.1's parity is taken on this, not on the TPN - see the moduledoc for
  the ruling and for why every team handed to the pairer counts as arrived.

  Public because `Ainalrami.TeamPairing.pair_round/2` builds it once per
  round and hands it to `allocate/3` for every pair; a host driving
  `allocate/3` directly across a roster should do the same rather than let
  each call default to a two-team numbering.
  """
  def parity_numbers(teams) when is_list(teams) do
    teams
    |> Enum.sort_by(& &1.tpn)
    |> Enum.with_index(1)
    |> Map.new(fn {team, number} -> {team.tpn, number} end)
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
  defp decide(first, other, initial, type, last_round?, numbers) do
    fp = Team.preference(first, type, last_round?)
    op = Team.preference(other, type, last_round?)
    fc = Team.preferred_colour(fp)
    oc = Team.preferred_colour(op)

    cond do
      # 4.3.1 - both teams have yet to play a match.
      #
      # `fetch!`, not a fallback to `first.tpn`: the first-team of a pair
      # being allocated a colour is by definition being paired this round,
      # so it is always in the numbering. Falling back would silently
      # restore the reading the SPP overturned.
      Team.matches_played(first) == 0 and Team.matches_played(other) == 0 ->
        initial_colour_by_parity(Map.fetch!(numbers, first.tpn), initial)

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
  4.3.1: an odd number takes the initial-colour, an even one the opposite.

  The number is the first-team's ARRIVAL NUMBER (`parity_numbers/1`), not
  its TPN. The two coincide only on a contiguous 1..N roster; see the
  moduledoc for the ruling that separated them, and for why the claim that
  this function was "the single line that would change" was false.

  Kept as its own function because a reader looking for 4.3.1 should find
  it named rather than buried in a `cond`.
  """
  def initial_colour_by_parity(number, initial) when is_integer(number) do
    if rem(number, 2) == 1, do: initial, else: opposite(initial)
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
