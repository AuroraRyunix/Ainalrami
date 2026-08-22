defmodule Ainalrami.InitialColourTest do
  @moduledoc """
  Article 5.2.5, and which number its parity is taken on.

  > **5.2.5** If the higher ranked player has an odd TPN, give them the
  > initial-colour; otherwise, give them the opposite colour.

  The article defers the meaning of TPN to C.04.2 Article 2, which fixes it
  for the tournament:

  > **2.3** This ranking is used to determine the participant's Tournament
  > Pairing Number ("TPN"); the highest ranked participant gets #1 etc. […]
  > No modification of a TPN for this reason is allowed after the fourth
  > round has been paired.

  The only two things that move a TPN are a correction to the ranking data
  (2.3) and the closing of the participant list after late entries (2.5).
  **Nothing renumbers TPNs around players who are not paired in a given
  round**, and this file exists because both reference implementations do
  exactly that - see `docs/dispute-initial-colour.md`.

  The distinction is invisible on a full field, where position and TPN
  coincide. It appears the moment anyone sits a round out, which is why
  every one of these cases has a bye in it.
  """

  use ExUnit.Case, async: true

  alias Ainalrami.Pairing

  describe "5.2.5 takes the parity of the fixed TPN" do
    test "a full field alternates the initial colour down the ranking" do
      pairs = Pairing.pair_next_round(field(10), expected_rounds: 5, initial_colour: "w")

      # Board by board: the higher-ranked player of each pair takes White on
      # an odd TPN and Black on an even one. This is the uncontroversial
      # case - both references agree here, and it is pinned so a change that
      # breaks it cannot be mistaken for the dispute below.
      for {white, black} <- pairs, black != nil do
        [top, bottom] = Enum.sort([white, black])
        expected_white = if rem(top, 2) == 1, do: top, else: bottom

        assert white == expected_white,
               "board #{top}v#{bottom}: TPN #{top} is " <>
                 "#{if rem(top, 2) == 1, do: "odd, so it takes White", else: "even, so it takes Black"}"
      end
    end

    test "a player sitting out does NOT renumber the players below them" do
      # TPN 1 takes a bye. TPN 2 is now the first player actually paired,
      # but their TPN is still 2 - an even number - so they take the
      # opposite of the initial colour, exactly as on a full field.
      #
      # Both references answer White here, by numbering from the first
      # player being paired rather than from the TPN. That is the whole
      # dispute, reduced to one board.
      pairs = Pairing.pair_next_round(field(10, [1]), expected_rounds: 5, initial_colour: "w")

      {white, black} = Enum.find(pairs, fn {w, b} -> 2 in [w, b] and b != nil end)

      assert black == 2,
             "TPN 2 is even, so 5.2.5 gives them the opposite of the " <>
               "initial colour - their position among the players being " <>
               "paired is not the TPN"

      refute white == 2
    end

    test "only players whose own TPN parity is unaffected keep their colour" do
      # TPNs 1 and 3 sit out, so the players being paired are
      # 2,4,5,6,7,8,9,10. Under the references' renumbering those become
      # positions 1..8, which flips the parity of TPN 2 (position 1) and
      # leaves 4, 5 and 6 alone (positions 2, 3, 4).
      #
      # So this field disagrees with them on exactly one board and agrees on
      # the rest - a sharper signature than "the colours are all wrong", and
      # the one actually measured against the real binary.
      pairs = Pairing.pair_next_round(field(10, [1, 3]), expected_rounds: 5, initial_colour: "w")

      for {white, black} <- pairs, black != nil do
        [top, _bottom] = Enum.sort([white, black])
        assert rem(top, 2) == 1 == (white == top), "TPN #{top} took the wrong colour"
      end
    end

    test "the initial colour is read, not assumed: 152 B mirrors everything" do
      white_draw = Pairing.pair_next_round(field(10), expected_rounds: 5, initial_colour: "w")
      black_draw = Pairing.pair_next_round(field(10), expected_rounds: 5, initial_colour: "b")

      # Key each board by its two ranks so the two runs are compared board
      # for board. Sorting the pairs themselves would not do it: flipping a
      # colour rewrites `{3, 8}` as `{8, 3}`, which sorts to a different
      # position, and zipping the two sorted lists would then line up
      # boards that are not the same board.
      by_board = fn pairs ->
        for {w, b} <- pairs, b != nil, into: %{}, do: {Enum.sort([w, b]), w}
      end

      whites = by_board.(white_draw)
      blacks = by_board.(black_draw)

      assert Map.keys(whites) |> Enum.sort() == Map.keys(blacks) |> Enum.sort(),
             "the drawing of lots decides colours, never who plays whom"

      for {board, white_under_w} <- whites do
        refute Map.fetch!(blacks, board) == white_under_w,
               "board #{inspect(board)} must flip when the draw flips"
      end
    end
  end

  describe "inferring the drawing of lots from a file that omits 152" do
    test "round one's own colours are the record of the draw" do
      # A file with no `152` has not lost the draw: 5.2.5 wrote it into
      # round one. TPN 1 is odd, so whatever colour they hold IS the
      # initial colour.
      played = played_field(8, "w")
      assert Pairing.pair_next_round(played, expected_rounds: 5) == pair_with(played, "w")

      flipped = played_field(8, "b")
      assert Pairing.pair_next_round(flipped, expected_rounds: 5) == pair_with(flipped, "b")
    end

    test "an explicit 152 always wins over the inference" do
      played = played_field(8, "w")

      assert Pairing.pair_next_round(played, expected_rounds: 5, initial_colour: "b") ==
               pair_with(played, "b"),
             "a file that states the draw is not second-guessed by reading it back"
    end
  end

  defp pair_with(players, colour) do
    Pairing.pair_next_round(players, expected_rounds: 5, initial_colour: colour)
  end

  # A field where round one has been played under `initial`, so the draw is
  # recoverable from the colours alone.
  defp played_field(n, initial) do
    half = div(n, 2)

    for rank <- 1..n do
      {opponent, colour} =
        if rank <= half do
          {rank + half, if(rem(rank, 2) == 1, do: initial, else: invert(initial))}
        else
          top = rank - half
          {top, if(rem(top, 2) == 1, do: invert(initial), else: initial)}
        end

      %{
        player(rank)
        | points: 0.5,
          games: [%{opponent_rank: opponent, colour: colour, result: "="}]
      }
    end
  end

  defp invert("w"), do: "b"
  defp invert("b"), do: "w"

  defp field(n, byes \\ []) do
    for rank <- 1..n do
      if rank in byes do
        %{player(rank) | games: [%{opponent_rank: nil, colour: nil, result: "Z"}]}
      else
        player(rank)
      end
    end
  end

  defp player(rank) do
    %{
      rank: rank,
      name: "P#{rank}",
      sex: "",
      title: "",
      federation: "",
      fide_rating: 2400 - rank * 10,
      fide_number: nil,
      birth_date: "",
      points: 0.0,
      games: []
    }
  end
end
