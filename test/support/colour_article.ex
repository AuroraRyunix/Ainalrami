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

  ## The answer is computable again

  `white_by_5_2_5/3` is back, and it is not the model that was deleted. That
  one took the parity of the fixed TPN - the reading the SPP overturned - and
  it was a MODEL of this engine's guess at a disputed article. This one calls
  `Ainalrami.Pairing.arrival_numbers/2`, which is the article as ruled, and
  which all three engines implement.

  The difference matters and is the whole reason the harness may use it. A
  test that predicts a reference's internals proves nothing when they differ.
  A test that applies an agreed rule and finds a reference breaking it has
  found a defect in the reference.

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

  @doc """
  Which of a 5.2.5 board's two players takes White, given the initial colour.

  Returns the rank of the player who should be White, or `nil` when 5.2.5 does
  not decide this board - either player holding a colour preference, or a
  player the round's numbering does not cover.

  "Higher ranked" is Article 1.2 - **score first, then TPN ascending** - and
  not the TPN alone. This function said otherwise until 2026-08-29 and was
  wrong, on a justification worth keeping as a warning: *"at 5.2.5 neither
  has played, so there is nothing to separate them on but the TPN."*

  `no_colour_preference?/1` excludes only COLOUR-FORMING games. A half-point
  bye is worth half a point and forms no colour; a zero-point bye, an
  absence and a forfeit likewise. So two players can both reach 5.2.5 and
  hold different scores, and on any such board this picked the wrong player
  and inverted the answer.

  The engine had already found and fixed exactly this in itself - see
  `Pairing.order_by_placement/2` and the comment above its call site, which
  records the same defect one article up at 5.2.4 and notes it is
  "reachable wherever a player has no PLAYED games at all, which arbiter
  byes produce routinely". This instrument reintroduced it, and because byes
  are common it fired constantly, which would have buried any real finding
  in noise.
  """
  def white_by_5_2_5({rank_a, rank_b}, by_rank, numbers, initial_white?) do
    a = Map.get(by_rank, rank_a)
    b = Map.get(by_rank, rank_b)

    cond do
      is_nil(a) or is_nil(b) ->
        nil

      not no_colour_preference?(a) ->
        nil

      not no_colour_preference?(b) ->
        nil

      true ->
        {top, bottom} = order_by_placement(a, b)

        case Map.get(numbers, top.rank) do
          nil ->
            nil

          # 5.2.5: the higher ranked player holds the initial colour on an
          # odd number and the opposite on an even one.
          number ->
            if rem(number, 2) == 1 == initial_white?, do: top.rank, else: bottom.rank
        end
    end
  end

  # Article 1.2, and deliberately the same expression as the engine's own
  # `Pairing.order_by_placement/2` rather than a second spelling of it: two
  # implementations of one rule is what put the bug here in the first place.
  defp order_by_placement(x, y) do
    if {-x.points, x.rank} <= {-y.points, y.rank}, do: {x, y}, else: {y, x}
  end

  @doc """
  The initial colour a single board IMPLIES, or `nil` if 5.2.5 does not decide
  it.

  `true` for "white was the initial colour", `false` for black.

  This is the inverse of `white_by_5_2_5/4`, and it exists because the initial
  colour is not recoverable from a position: FIDE leaves the very first colour
  to a literal drawing of lots, and an engine's own choice is not a rule
  anybody can reproduce.

  So the harness does not need to know it. Every board a round decides by
  5.2.5 implies one, and they must all agree - which turns an unknowable
  constant into a testable consistency claim.
  """
  def implied_initial_colour({white_rank, black_rank}, by_rank, numbers) do
    a = Map.get(by_rank, white_rank)
    b = Map.get(by_rank, black_rank)

    cond do
      is_nil(a) or is_nil(b) ->
        nil

      not no_colour_preference?(a) ->
        nil

      not no_colour_preference?(b) ->
        nil

      true ->
        # Article 1.2, not the TPN alone - see `white_by_5_2_5/4`, which
        # carried that defect until 2026-08-29 and inverted this answer on
        # every board where the two players held different scores.
        {top, _bottom} = order_by_placement(a, b)

        case Map.get(numbers, top.rank) do
          nil ->
            nil

          # The top player took White iff they hold the initial colour on an
          # odd number, so: odd and White means the initial colour was white;
          # odd and Black means it was black; and the even cases invert.
          number ->
            top.rank == white_rank == (rem(number, 2) == 1)
        end
    end
  end

  @doc """
  Whether one engine's answers for a round can all be explained by a single
  initial colour.

  Returns `:consistent`, `:not_applicable` (no board in the round is 5.2.5's
  to decide), or `{:inconsistent, whites, blacks}` with how many boards
  implied each - a straight count of the contradiction.

  ## Why this and not "is this board right"

  Because "right" needs the initial colour, and there is no such thing to
  know: Article 5.1 leaves it to a drawing of lots. What IS knowable is that
  5.2.5 gives one answer per board from one constant, so an engine whose
  boards imply both colours has broken the article on at least one of them,
  whatever the constant was.

  That is a real conformance claim about a reference, computed from an agreed
  rule - which is what `:reach` could not make while the article was disputed.
  """
  def article_5_2_5_consistency(boards, by_rank, numbers) do
    implied =
      boards
      |> Enum.map(&implied_initial_colour(&1, by_rank, numbers))
      |> Enum.reject(&is_nil/1)

    whites = Enum.count(implied, & &1)
    blacks = length(implied) - whites

    cond do
      implied == [] -> :not_applicable
      whites == 0 or blacks == 0 -> :consistent
      true -> {:inconsistent, whites, blacks}
    end
  end
end
