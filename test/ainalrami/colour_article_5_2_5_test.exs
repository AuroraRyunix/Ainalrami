defmodule Ainalrami.ColourArticle525Test do
  @moduledoc """
  Article 5.2.5's answer, computed rather than modelled.

  The harness could not do this while the article was disputed: computing it
  meant predicting a reference's internals, which proves nothing when they
  differ. The SPP settled the reading on 2026-08-27, all three engines
  implement it, and applying an agreed rule to a reference's output is what a
  conformance test IS.

  The awkward part is that 5.2.5's answer depends on the initial colour, and
  there is no such thing to look up - Article 5.1 leaves the very first colour
  to a literal drawing of lots. So the testable claim is not "this board is
  right" but "every board this round decides by 5.2.5 implies the SAME initial
  colour". An engine whose boards imply both has broken the article on at
  least one of them, whatever the constant was.
  """
  use ExUnit.Case, async: true

  alias Ainalrami.Pairing
  alias Ainalrami.Test.ColourArticle

  # A player who has never played: no games, so no colour preference, so
  # inside 5.2.5's reach.
  defp fresh(rank), do: %{rank: rank, points: 0.0, games: []}

  # One who has, so 5.2.5 is not deciding their board.
  defp played(rank),
    do: %{rank: rank, points: 1.0, games: [%{opponent: 99, colour: "w", result: "1"}]}

  # The case that broke this. A half-point bye is worth half a point and
  # forms no colour, so this player is INSIDE 5.2.5's reach while outscoring
  # a fresh one - which is what makes "neither has played, so rank is all we
  # have" false.
  defp half_bye(rank),
    do: %{rank: rank, points: 0.5, games: [%{opponent: nil, colour: nil, result: "H"}]}

  defp roster(players), do: Map.new(players, &{&1.rank, &1})

  defp numbers(players, round), do: Pairing.arrival_numbers(players, round)

  describe "when 5.2.5 decides a board at all" do
    test "it does when neither player has played" do
      players = Enum.map(1..4, &fresh/1)

      assert ColourArticle.implied_initial_colour({1, 2}, roster(players), numbers(players, 1)) !=
               nil
    end

    test "it does not when either player has" do
      players = [fresh(1), played(2), fresh(3), fresh(4)]
      by_rank = roster(players)
      nums = numbers(players, 1)

      # A bye or a forfeit allocates no colour, so those leave a player inside
      # 5.2.5's reach - only a PLAYED game takes them out of it.
      assert ColourArticle.implied_initial_colour({1, 2}, by_rank, nums) == nil
      assert ColourArticle.implied_initial_colour({3, 4}, by_rank, nums) != nil
    end

    test "nor for a player the round's numbering does not cover" do
      players = Enum.map(1..4, &fresh/1)

      # A rank nobody in the roster holds. Reaching for a missing number must
      # not fall back to the rank - that is the distinction the ruling drew.
      assert ColourArticle.implied_initial_colour({1, 99}, roster(players), numbers(players, 1)) ==
               nil
    end
  end

  describe "the answer, and its inverse" do
    setup do
      players = Enum.map(1..6, &fresh/1)
      {:ok, players: players, by_rank: roster(players), numbers: numbers(players, 1)}
    end

    test "an odd-numbered top player takes the initial colour", ctx do
      # Rank 1 is arrival 1, which is odd.
      assert ColourArticle.white_by_5_2_5({1, 2}, ctx.by_rank, ctx.numbers, true) == 1
      assert ColourArticle.white_by_5_2_5({1, 2}, ctx.by_rank, ctx.numbers, false) == 2
    end

    test "an even-numbered one takes the opposite", ctx do
      # Rank 2 is arrival 2. Every player here is on the same score, so the
      # TPN is what separates them - see the describe block below for why
      # that is a property of this fixture and not of Article 5.2.5.
      assert ColourArticle.white_by_5_2_5({2, 3}, ctx.by_rank, ctx.numbers, true) == 3
      assert ColourArticle.white_by_5_2_5({2, 3}, ctx.by_rank, ctx.numbers, false) == 2
    end

    test "and the two are inverses of each other", ctx do
      for {a, b} <- [{1, 2}, {2, 3}, {3, 4}, {1, 6}], initial <- [true, false] do
        white = ColourArticle.white_by_5_2_5({a, b}, ctx.by_rank, ctx.numbers, initial)
        black = if white == a, do: b, else: a

        assert ColourArticle.implied_initial_colour({white, black}, ctx.by_rank, ctx.numbers) ==
                 initial
      end
    end
  end

  describe "\"higher ranked\" is Article 1.2, not the TPN alone" do
    # The defect this block exists to keep out, found on Photon 2026-08-29.
    #
    # `white_by_5_2_5/4` took the lower TPN as the higher ranked player, on
    # the stated reasoning that a player inside 5.2.5's reach has never
    # played and so has no score to compare. That reasoning is false:
    # `no_colour_preference?/1` excludes only COLOUR-FORMING games, and a
    # half-point bye is worth half a point while forming no colour. Byes
    # produce this constantly, so the wrong player got the parity rule on a
    # large share of bye-heavy rounds - and the check fired 53 times in
    # fifteen minutes of one axis, which would have buried any real finding.
    #
    # The engine had already found and fixed the identical defect in itself
    # one article up, at 5.2.4: see `Pairing.order_by_placement/2` and the
    # comment above its call site, which says in as many words that it is
    # "reachable wherever a player has no PLAYED games at all, which arbiter
    # byes produce routinely".
    setup do
      # Rank 3 outscores rank 1 on a half-point bye, so score order and rank
      # order disagree. Both hold ODD arrival numbers (1 and 3), which is
      # what makes the two readings give different answers rather than
      # cancelling: on a mixed-parity board, swapping the top player also
      # swaps the parity and the error hides itself.
      players = [fresh(1), fresh(2), half_bye(3), fresh(4)]
      {:ok, by_rank: roster(players), numbers: numbers(players, 2)}
    end

    test "the higher-SCORED player is the top one, not the lower rank", ctx do
      assert ctx.numbers[1] == 1
      assert ctx.numbers[3] == 3

      # Rank 3 holds more points, so rank 3 is higher ranked and takes the
      # initial colour on its odd number. Comparing TPN alone answers rank 1
      # to both of these.
      assert ColourArticle.white_by_5_2_5({1, 3}, ctx.by_rank, ctx.numbers, true) == 3
      assert ColourArticle.white_by_5_2_5({1, 3}, ctx.by_rank, ctx.numbers, false) == 1
    end

    test "and the implied colour follows the same player", ctx do
      assert ColourArticle.implied_initial_colour({3, 1}, ctx.by_rank, ctx.numbers) == true
      assert ColourArticle.implied_initial_colour({1, 3}, ctx.by_rank, ctx.numbers) == false
    end

    test "a board of equal scores still turns on the TPN", ctx do
      # The original reading was not wrong about this case, only about
      # believing it was the only case.
      assert ColourArticle.white_by_5_2_5({1, 2}, ctx.by_rank, ctx.numbers, true) == 1
    end

    test "so a round mixing the two is consistent, not a finding", ctx do
      # The shape that fired on Photon: one board of equal scores and one
      # straddling a score group. Read correctly they agree, and an
      # instrument that called this an inconsistency was reporting its own
      # arithmetic as a reference defect.
      boards = [{1, 2}, {3, 4}]

      assert ColourArticle.article_5_2_5_consistency(boards, ctx.by_rank, ctx.numbers) ==
               :consistent
    end
  end

  describe "a round's consistency" do
    setup do
      players = Enum.map(1..6, &fresh/1)
      {:ok, by_rank: roster(players), numbers: numbers(players, 1)}
    end

    test "boards that all follow one initial colour are consistent", ctx do
      boards =
        for {a, b} <- [{1, 2}, {3, 4}, {5, 6}] do
          white = ColourArticle.white_by_5_2_5({a, b}, ctx.by_rank, ctx.numbers, true)
          {white, if(white == a, do: b, else: a)}
        end

      assert ColourArticle.article_5_2_5_consistency(boards, ctx.by_rank, ctx.numbers) ==
               :consistent
    end

    test "so are boards that all follow the other one", ctx do
      boards =
        for {a, b} <- [{1, 2}, {3, 4}, {5, 6}] do
          white = ColourArticle.white_by_5_2_5({a, b}, ctx.by_rank, ctx.numbers, false)
          {white, if(white == a, do: b, else: a)}
        end

      assert ColourArticle.article_5_2_5_consistency(boards, ctx.by_rank, ctx.numbers) ==
               :consistent
    end

    test "a round that implies both has broken the article somewhere", ctx do
      # This is the finding the instrument exists to make. It does not say
      # WHICH board is wrong - that needs the initial colour, which nobody can
      # know - only that at least one of them must be.
      one = ColourArticle.white_by_5_2_5({1, 2}, ctx.by_rank, ctx.numbers, true)
      other = ColourArticle.white_by_5_2_5({3, 4}, ctx.by_rank, ctx.numbers, false)

      boards = [
        {one, if(one == 1, do: 2, else: 1)},
        {other, if(other == 3, do: 4, else: 3)}
      ]

      assert {:inconsistent, 1, 1} =
               ColourArticle.article_5_2_5_consistency(boards, ctx.by_rank, ctx.numbers)
    end

    test "a round with no 5.2.5 board makes no claim either way" do
      players = Enum.map(1..4, &played/1)
      by_rank = roster(players)
      nums = numbers(players, 2)

      # Not "consistent" - there is nothing to be consistent about, and
      # reporting a pass for a round the article never touched would inflate
      # every rate this instrument feeds.
      assert ColourArticle.article_5_2_5_consistency([{1, 2}, {3, 4}], by_rank, nums) ==
               :not_applicable
    end
  end
end
