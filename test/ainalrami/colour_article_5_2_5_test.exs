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
  defp fresh(rank), do: %{rank: rank, games: []}

  # One who has, so 5.2.5 is not deciding their board.
  defp played(rank), do: %{rank: rank, games: [%{opponent: 99, colour: "w", result: "1"}]}

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
      # Rank 2 is arrival 2. Ranks are what decides who is "higher ranked" at
      # 5.2.5: neither has played, so Article 1.2 has nothing but the TPN.
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
