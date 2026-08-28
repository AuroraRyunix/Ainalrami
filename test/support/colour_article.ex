defmodule Ainalrami.Test.ColourArticle do
  @moduledoc """
  When is a board's colour Article 5.2.5's to decide? The one question about
  Article 5 the comparison harnesses still ask.

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
  private copies of "what is a played code" deleted in one commit.

  ## What used to be here, and why it is gone

  This module also modelled 5.2.5's ANSWER - `white_by_5_2_5/3`, plus the
  `decided_by_5_2_5?/3` and `score_at/2` that existed to serve it. That
  model took the parity of the fixed TPN, which is the reading the FIDE
  Systems of Pairings and Programs Commission overturned on 2026-08-27:
  5.2.5's parity is taken on a player's position among the players who have
  ARRIVED, and `Ainalrami.Pairing`'s `arrival_numbers/2` carries the ruling.

  The harnesses used that model to file a colour difference against a
  reference as "the known dispute" rather than as a defect. With this engine
  now taking the same reading both references take, that test would have
  become flat equality - a board where we differ from a reference would be
  "explained" by our differing from it - so both harnesses dropped it, and
  the model went with them. Deleted rather than kept for a caller that might
  come back: a fourth copy of the overturned parity rule sitting in the test
  tree is exactly the drift this moduledoc's second paragraph is about.

  ## The rule that is left

  > **5.2.5** If the higher ranked player has an odd TPN, give them the
  > initial-colour; otherwise, give them the opposite colour.

  It is the last resort of Article 5.2, reached only where NEITHER player
  holds a colour preference - which by Article 1.7.4 means neither has
  played a game. That is the whole of what `no_colour_preference?/1` tests,
  and it is a statement about the two players' histories, not about any
  engine's numbering. It survives the ruling untouched.
  """

  @doc """
  Article 1.7.4: a player with no games has no colour preference. Only a
  PLAYED game counts - a bye or a forfeit allocates no colour, so it leaves
  the player still inside 5.2.5's reach.
  """
  def no_colour_preference?(player) do
    Enum.all?(player.games, &(&1.result not in ~w(1 = 0)))
  end
end
