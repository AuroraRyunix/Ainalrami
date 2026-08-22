defmodule Ainalrami.PairingLaterRoundTest do
  use ExUnit.Case, async: true

  alias Ainalrami.Pairing

  defp p(rank, points, games) do
    %{rank: rank, name: "P#{rank}", points: points, games: games}
  end

  defp game(opponent_rank, colour, result) do
    %{opponent_rank: opponent_rank, colour: colour, result: result}
  end

  defp as_pair_sets(pairs) do
    pairs
    |> Enum.map(fn {a, b} -> Enum.sort_by([a, b], &(&1 || :infinity)) end)
    |> Enum.sort()
  end

  # Round 2 after round 1's standard 8-player split (1v5, 2v6, 3v7, 4v8) -
  # 1, 3, 6, 8 won (1.0 pts); 2, 4, 5, 7 lost (0.0 pts). Two even brackets,
  # neither hits a rematch, but the plain top-half-vs-bottom-half split
  # ISN'T what gets chosen: within {1,3,6,8}, round-1 colours were
  # 1="w",3="b",6="w",8="b", so preferences (opposite) are 1:b, 3:w, 6:b,
  # 8:w. The natural split (1v6, 3v8) pairs two same-preference players
  # both times (1&6 both want black, 3&8 both want white) - zero
  # preferences granted. Swapping to (1v8, 3v6) grants BOTH preferences
  # (1 gets black vs 8's white, 3 gets white vs 6's black), which
  # `option_score/1`'s colour-preference criterion prefers. Same story for
  # {2,4,5,7} (colours 2="b",4="w",5="b",7="w"): natural (2v5,4v7) clashes
  # twice; (2v7,4v5) grants both.
  test "colour-preference-optimal pairing is chosen over the plain top/bottom split" do
    winners = [
      p(1, 1.0, [game(5, "w", "1")]),
      p(3, 1.0, [game(7, "b", "1")]),
      p(6, 1.0, [game(2, "w", "1")]),
      p(8, 1.0, [game(4, "b", "1")])
    ]

    losers = [
      p(2, 0.0, [game(6, "b", "0")]),
      p(4, 0.0, [game(8, "w", "0")]),
      p(5, 0.0, [game(1, "b", "0")]),
      p(7, 0.0, [game(3, "w", "0")])
    ]

    pairs = Pairing.pair_next_round(winners ++ losers)

    assert as_pair_sets(pairs) == [[1, 8], [2, 7], [3, 6], [4, 5]]
  end

  # Same winners bracket {1,3,6,8}, but this time the natural split (1v6,
  # 3v8) would replay 1 vs 6's... no -- force an ACTUAL rematch: 1 already
  # played 6 in round 1 (instead of 5), so the natural pairing is illegal
  # and the backtracking search must find the only other legal option.
  test "falls back to backtracking when the natural split would replay round 1's pairing" do
    winners = [
      p(1, 1.0, [game(6, "w", "1")]),
      p(3, 1.0, [game(7, "b", "1")]),
      p(6, 1.0, [game(1, "b", "1")]),
      p(8, 1.0, [game(4, "b", "1")])
    ]

    pairs = Pairing.pair_next_round(winners)

    # Natural split would be 1v6 (rematch, illegal) and 3v8 -- the only
    # other legal complete pairing swaps to 1v8 and 3v6.
    assert as_pair_sets(pairs) == [[1, 8], [3, 6]]
  end

  # A bracket with an odd number of residents (3 players tied at 1.0)
  # floats its lowest-ranked member down to merge with the next bracket.
  test "an odd bracket floats its lowest-ranked resident down to the next bracket" do
    top_bracket = [
      p(1, 1.0, [game(4, "w", "1")]),
      p(2, 1.0, [game(5, "b", "1")]),
      p(3, 1.0, [game(6, "w", "1")])
    ]

    bottom_bracket = [
      p(4, 0.0, [game(1, "b", "0")]),
      p(5, 0.0, [game(2, "w", "0")]),
      p(6, 0.0, [game(3, "b", "0")])
    ]

    pairs = Pairing.pair_next_round(top_bracket ++ bottom_bracket)

    # Top bracket {1,2,3}: 1(pref b) and 2(pref w) pair - complementary,
    # legal, and the only floater choice that keeps a preference-granting
    # pair intact - so 3 floats down. Merged with {4,5,6} (sorted
    # 3,4,5,6 - 3 is the only 1.0-scorer left, so it's ranked first;
    # prefs 3:b, 4:w, 5:b, 6:w): pairing is NOT restricted to a bipartite
    # "better half vs worse half" split (confirmed wrong at real-`javafo.jar`
    # scale - see docs/engineering-log.md), so 3v4 is a legal candidate pairing even
    # though both are nominally in the "same half" - and it's the
    # colour-optimal choice (3v4 and 5v6 both grant each player's
    # preference; 3v5+4v6 would clash on both).
    assert as_pair_sets(pairs) == [[1, 2], [3, 4], [5, 6]]
  end

  test "the very last bracket's genuinely unpairable odd player gets the bye" do
    players = [
      p(1, 1.0, [game(2, "w", "1")]),
      p(2, 0.0, [game(1, "b", "0")]),
      p(3, 0.0, [])
    ]

    pairs = Pairing.pair_next_round(players)

    {bye_pairs, real_pairs} = Enum.split_with(pairs, fn {_w, b} -> is_nil(b) end)

    # Bracket{1} (score 1.0, alone) floats 1 down to merge with {2,3}
    # (score 0.0): natural split pairs 1v2 (no prior meeting -- 1 played
    # 2 already though!). 1 and 2 already met, so backtracking pairs 1v3
    # instead, leaving 2 as the odd one out -- but 2 has no legal partner
    # left (only 1 and 3 exist, 1 is taken, 3 already paired) so 2 floats
    # to a bracket of its own and gets the bye.
    assert as_pair_sets(real_pairs) == [[1, 3]]
    assert bye_pairs == [{2, nil}]
  end

  test "a late entrant with no game history is treated as score 0.0 and pairs normally" do
    seasoned = [
      p(1, 1.0, [game(2, "w", "1")]),
      p(2, 0.0, [game(1, "b", "0")])
    ]

    late_entrant = p(3, 0.0, [])

    pairs = Pairing.pair_next_round(seasoned ++ [late_entrant])

    {bye_pairs, real_pairs} = Enum.split_with(pairs, fn {_w, b} -> is_nil(b) end)
    assert as_pair_sets(real_pairs) == [[1, 3]]
    assert bye_pairs == [{2, nil}]
  end
end
