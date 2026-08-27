defmodule Ainalrami.Test.ColourArticle do
  @moduledoc """
  Article 5.2.5 as the comparison harnesses need it: given a board both
  engines formed, which player does the article say takes White?

  ## Why this is a module rather than a copy in each harness

  The same reason `Ainalrami.Test.FuzzTournament` is. This rule was written
  down twice - once in `Ainalrami.BbppairingsComparisonTest` when the
  two-way harness learned to look at colours at all, and again in
  `Ainalrami.ThreeWayComparisonTest` on 2026-08-27 when the three-way one
  did. The second copy was carried across character for character and the
  two had not drifted, which is the only reason this extraction is a
  refactor rather than a bug fix.

  It would not have stayed that way. The same rule written down twice,
  drifting, is the shape behind almost every real defect this project has
  found: `played?/1` recognising three result codes where the shared table
  recognised six, a bye scored from its TRF letter in one place and its
  kind in another, `NbParties` counting four played codes against nine, two
  private copies of "what is a played code" deleted in one commit. A drift
  here would be worse than most, because it would be SILENT in a specific
  way - each harness would file the same board differently, one calling it
  the known Article 5.2.5 dispute and the other calling it an unexplained
  conformance failure, and neither would complain.

  ## The rule

  > **5.2.5** If the higher ranked player has an odd TPN, give them the
  > initial-colour; otherwise, give them the opposite colour.

  "Higher ranked" is Article 1.2's order - score first, then TPN ascending -
  and the score is the one the engine actually pairs on, which includes
  virtual points from acceleration.

  The article only reaches a board where NEITHER player has a colour
  preference, which by Article 1.7.4 means neither has played a game. That
  is what `no_colour_preference?/1` tests, and it is why these harnesses can
  file a colour difference as "expected" rather than as a defect: this
  engine reads 5.2.5 against the fixed TPN and both references renumber
  around players who are not being paired, so the three can disagree on a
  first-round-style board and all be following their own reading. See
  `docs/dispute-initial-colour.md`.
  """

  alias Ainalrami.Test.FuzzTournament

  @doc """
  The rank Article 5.2.5 gives White on a board between `a` and `b`, in a
  round where neither player has a colour preference.

  Callers must establish that themselves with `no_colour_preference?/1`;
  this function does not check, because one caller needs the predicate
  separately and asking twice would be the more confusing arrangement.
  """
  def white_by_5_2_5(a, b, round) do
    # Using RAW points here mis-filed a board on the two-way harness's
    # accelerated axis: a player on 0.0 carrying 1.0 of acceleration ties
    # with one on 1.0, so the tie falls to TPN and the lower number is the
    # higher ranked player. Judged on raw points the ordering inverts, and
    # with it the expected colour.
    {top, bottom} =
      if {-score_at(a, round), a.rank} < {-score_at(b, round), b.rank},
        do: {a, b},
        else: {b, a}

    initial_white? = String.downcase(FuzzTournament.initial_colour()) == "w"
    top_takes_initial? = rem(top.rank, 2) == 1

    if top_takes_initial? == initial_white?, do: top.rank, else: bottom.rank
  end

  @doc """
  Whether Article 5.2.5 decides this board AND `white` is the answer it
  gives. The form the two-way harness wants: a board that satisfies this is
  the known dispute rather than a conformance failure.
  """
  def decided_by_5_2_5?({white, black}, players, round) do
    by_rank = Map.new(players, &{&1.rank, &1})
    a = Map.get(by_rank, white)
    b = Map.get(by_rank, black)

    if a && b && no_colour_preference?(a) && no_colour_preference?(b) do
      white == white_by_5_2_5(a, b, round)
    else
      false
    end
  end

  @doc """
  The score the engine pairs on: the recorded total plus this round's
  virtual points, if the file carries any.

  A roster generated without the acceleration axis has no `:accelerations`
  key at all, which is why this reads through `Access` rather than with a
  dot.
  """
  def score_at(player, round) do
    accel =
      case player[:accelerations] do
        nil -> 0.0
        values -> Enum.at(values, round - 1) || 0.0
      end

    player.points + accel
  end

  @doc """
  Article 1.7.4: a player with no games has no colour preference. Only a
  PLAYED game counts - a bye or a forfeit allocates no colour, so it leaves
  the player still inside 5.2.5's reach.
  """
  def no_colour_preference?(player) do
    Enum.all?(player.games, &(&1.result not in ~w(1 = 0)))
  end
end
