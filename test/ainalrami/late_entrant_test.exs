defmodule Ainalrami.LateEntrantTest do
  @moduledoc """
  Late entrants (C.04.2 Article 2.4) - a participant admitted after round
  one, whose early rounds carry no entry at all.

  > **2.4** A Late Entry is a participant who is only taken into account
  > for the pairing of rounds after the first. If admitted to the
  > tournament, late entries receive no points for unplayed rounds (unless
  > the rules of the tournament say otherwise), and are given an
  > appropriate TPN and paired only when they actually arrive.

  This was carried on the harness-widening list as an unmeasured axis. It
  is not one, and this file is the reason why: **a blank early round is
  indistinguishable from a zero-point bye**, everywhere the engine looks.

  - `points_for/1` - a blank result and `Z` are both worth nothing, which
    is 2.4's "no points for unplayed rounds".
  - `participated_in_pairing?/1` - false for both, so neither counts as
    having been paired.
  - Article 1.4.3 - a downfloat is given to a player who scores more than a
    loss without playing. Both score zero, so neither floats.
  - C2 - `~w(U F +)` disqualifies from a pairing-allocated bye. Neither
    blank nor `Z` is in it.

  So a generated late-entrant axis would re-run the arbiter-bye axis under
  a different name. That is worth pinning rather than merely concluding:
  the equivalence is a consequence of four separate rules agreeing, and a
  change to any one of them would break it silently.

  What is genuinely NOT modelled here is 2.5 - TPNs are provisional until
  the participant list closes, so a real late entry can renumber everyone.
  This engine takes TPNs as given in the file and never assigns them, so
  that is the caller's job and out of scope.

  ## The other half of 2.4, which this file does not test

  Read the quotation above again, because it is also the sentence the FIDE
  Systems of Pairings and Programs Commission ruled on for Article 5.2.5,
  on 2026-08-27 - and it ruled AGAINST this engine. Anyone who arrives at
  2.4 through this file needs to know which way, because this file used to
  send them the other way: it closed by citing
  `docs/dispute-initial-colour.md` "where the fixedness of a TPN is the
  whole argument", and that argument is the one that lost.

  Both sides argued from these same words. This engine read "given an
  appropriate TPN and paired only when they actually arrive" as granting
  the number up front and making only the pairing wait. The SPP reads it as
  withholding the number until the arrival - so 5.2.5's parity is taken on
  a player's position among those who have arrived, and a late entrant
  shifts everyone below them the moment they turn up. The engine has been
  changed to match.

  None of that touches the four equivalences pinned below. They are about
  SCORING and FLOATING a blank round, not numbering one, and all four still
  hold - the ruling changed which number 5.2.5's parity is taken on, not
  what a blank round is worth. But 2.4 is now quoted here for one purpose
  and famous for another, so the citation is worth keeping straight.
  `Ainalrami.Pairing`'s `arrival_numbers/2` carries the ruling in full, and
  `Ainalrami.InitialColourTest` is the numbering's own test file.
  """

  use ExUnit.Case, async: true

  alias Ainalrami.Pairing

  @blank %{opponent_rank: nil, colour: nil, result: nil}
  @zero_bye %{opponent_rank: nil, colour: nil, result: "Z"}

  describe "a blank early round and a zero-point bye" do
    test "produce the same pairing" do
      assert pair(field(@blank)) == pair(field(@zero_bye))
    end

    test "and the same pairing on an odd field, where one of them takes the bye" do
      assert pair(odd_field(@blank)) == pair(odd_field(@zero_bye))
    end

    test "are both worth nothing" do
      assert Ainalrami.Trf.points_for(nil) == 0.0
      assert Ainalrami.Trf.points_for("Z") == 0.0
    end

    test "neither counts as having been paired" do
      refute Ainalrami.Trf.participated_in_pairing?(@blank)
      refute Ainalrami.Trf.participated_in_pairing?(@zero_bye)
    end

    test "and a half-point bye is NOT equivalent, which is the control" do
      # H scores half a point, so it separates the player on score and can
      # change the brackets. If this ever matched too, the test above would
      # be passing because the engine ignores early rounds entirely rather
      # than because blank and Z genuinely coincide.
      half = %{opponent_rank: nil, colour: nil, result: "H"}

      refute pair(field(@blank)) == pair(field(half))
    end
  end

  describe "the late entrant is paired once they arrive" do
    test "and is seated in the round after the blank one" do
      # `pair/1` normalises each board to a sorted list, with 0 standing in
      # for the bye, so flattening gives everyone seated.
      seated = @blank |> field() |> pair() |> List.flatten()

      assert 9 in seated and 10 in seated,
             "a late entrant who has arrived is an ordinary player"
    end
  end

  defp pair(players) do
    players
    |> Pairing.pair_next_round(expected_rounds: 5, initial_colour: "w")
    |> Enum.map(fn {w, b} -> Enum.sort([w, b || 0]) end)
    |> Enum.sort()
  end

  # Ten players. 1-8 play round one; 9 and 10 are not in the tournament yet
  # and carry `marker` for it. Everyone plays round two. All draws, so the
  # only thing separating anyone is the round the latecomers missed.
  defp field(marker) do
    round_one = [{1, 5}, {2, 6}, {3, 7}, {4, 8}]
    round_two = [{1, 9}, {2, 10}, {3, 4}, {5, 6}, {7, 8}]

    histories =
      round_one
      |> Enum.reduce(%{}, fn {w, b}, acc ->
        acc |> Map.put(w, [game(b, "w")]) |> Map.put(b, [game(w, "b")])
      end)
      |> Map.put(9, [marker])
      |> Map.put(10, [marker])

    histories =
      Enum.reduce(round_two, histories, fn {w, b}, acc ->
        acc
        |> Map.update!(w, &(&1 ++ [game(b, "b")]))
        |> Map.update!(b, &(&1 ++ [game(w, "w")]))
      end)

    build(1..10, histories)
  end

  # Nine players, so the round being paired must allocate a bye - the path
  # where C2 and C5 engage and a latecomer could be treated differently
  # from a bye-taker if the two shapes were not equivalent.
  defp odd_field(marker) do
    round_one = [{1, 5}, {2, 6}, {3, 7}]

    histories =
      round_one
      |> Enum.reduce(%{}, fn {w, b}, acc ->
        acc |> Map.put(w, [game(b, "w")]) |> Map.put(b, [game(w, "b")])
      end)
      |> Map.put(4, [marker])
      |> Map.put(8, [marker])
      |> Map.put(9, [marker])

    round_two = [{1, 4}, {2, 8}, {3, 9}, {5, 6}]

    histories =
      Enum.reduce(round_two, histories, fn {w, b}, acc ->
        acc
        |> Map.update!(w, &(&1 ++ [game(b, "b")]))
        |> Map.update!(b, &(&1 ++ [game(w, "w")]))
      end)

    histories =
      Map.update!(histories, 7, &(&1 ++ [%{opponent_rank: nil, colour: nil, result: "Z"}]))

    build(1..9, histories)
  end

  defp build(ranks, histories) do
    for rank <- ranks do
      games = Map.fetch!(histories, rank)

      %{
        rank: rank,
        name: "P#{rank}",
        sex: "",
        title: "",
        federation: "",
        fide_rating: 2400 - rank * 10,
        fide_number: nil,
        birth_date: "",
        points: Enum.reduce(games, 0.0, &(&2 + Ainalrami.Trf.points_for(&1.result))),
        games: games
      }
    end
  end

  defp game(opponent, colour), do: %{opponent_rank: opponent, colour: colour, result: "="}
end
