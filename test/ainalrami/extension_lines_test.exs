defmodule Ainalrami.ExtensionLinesTest do
  @moduledoc """
  What the `XXP` and `XXA` extension lines actually do to a pairing.

  `Ainalrami.TrfTest` covers reading and writing them; this covers the only
  thing that matters afterwards — that the engine's answer CHANGES, in the
  direction real bbpPairings changes it. Every expected pairing below was
  taken from bbpPairings 6.0.0 run on the very fixture file the test reads,
  not from this engine's own output, so a test passing here means the two
  engines agree rather than that Ainalrami is self-consistent.

  Each fixture is also checked against what the engine does with the
  extension REMOVED, because a criterion that changes nothing is
  indistinguishable from one that was never read — which is exactly the
  failure this whole change exists to fix. `Ainalrami.Trf` used to parse
  `XXR` and silently discard every other `XX` line, so an arbiter's "these
  two must never meet" produced a complete, perfectly legal-LOOKING pairing
  that seated them together.
  """

  use ExUnit.Case, async: true

  alias Ainalrami.{Pairing, Trf}

  defp normalize(pairs) do
    pairs |> Enum.map(fn {a, b} -> Enum.sort_by([a, b], &(&1 || :infinity)) end) |> Enum.sort()
  end

  defp load(path) do
    %{players: players, tournament: tournament} = Trf.parse(File.read!(path))
    {players, tournament}
  end

  describe "250 round-limited acceleration" do
    # `250` is bbpPairings' fixed-column, round-limited sibling of `XXA`:
    # one line gives the same virtual points to a RANGE of players over a
    # RANGE of rounds, where `XXA` spells out one player's whole row.
    #
    # Columns per `readAccelerations250` (`trf.cpp:418-482`), 1-based and
    # inclusive: match points 5-9 (must be blank or zero), game points
    # 10-14 (must be non-zero), rounds 15-18 and 19-22, players 23-27 and
    # 28-32. Both expected pairings below came from bbpPairings 6.0.0 on
    # the same bytes.
    defp eight_player_roster do
      players =
        for r <- 1..8 do
          %{
            rank: r,
            name: "Player #{r}",
            sex: "",
            title: "",
            fide_rating: 2400 - r * 10,
            federation: "",
            fide_number: nil,
            birth_date: "",
            points: 0.0,
            games: []
          }
        end

      Trf.serialize(%{
        tournament: %{
          name: "Code 250",
          type: "swiss",
          number_of_rounds: 5,
          initial_colour: "w"
        },
        players: players
      })
    end

    defp line_250(points, first_round, last_round, first_player, last_player) do
      "250 " <>
        "     " <>
        String.pad_leading(points, 4) <>
        " " <>
        String.pad_leading(first_round, 3) <>
        " " <>
        String.pad_leading(last_round, 3) <>
        " " <>
        String.pad_leading(first_player, 4) <>
        " " <> String.pad_leading(last_player, 4) <> "\r\n"
    end

    defp pair_eight(extra) do
      parsed = Trf.parse(eight_player_roster() <> extra)

      parsed.players
      |> Pairing.pair_next_round(
        expected_rounds: parsed.tournament[:number_of_rounds],
        initial_colour: "w"
      )
      |> normalize()
    end

    test "acceleration changes the brackets, and so the pairing" do
      # Unaccelerated, round one is the plain top-half-vs-bottom-half split.
      assert pair_eight("") == [[1, 5], [2, 6], [3, 7], [4, 8]]

      # A point to players 1-4 splits the field into two score groups of
      # four, which pair within themselves.
      assert pair_eight(line_250("1.0", "1", "2", "1", "4")) ==
               [[1, 3], [2, 4], [5, 7], [6, 8]]
    end

    test "the range is expanded onto the named players only" do
      parsed = Trf.parse(eight_player_roster() <> line_250("1.0", "1", "2", "1", "4"))

      accelerated =
        parsed.players
        |> Enum.map(&{&1[:rank], &1[:accelerations]})
        |> Enum.reject(&is_nil(elem(&1, 1)))

      assert accelerated == [{1, [1.0, 1.0]}, {2, [1.0, 1.0]}, {3, [1.0, 1.0]}, {4, [1.0, 1.0]}]
    end

    test "rounds before the range pay nothing" do
      parsed = Trf.parse(eight_player_roster() <> line_250("1.0", "2", "3", "1", "2"))
      first = Enum.find(parsed.players, &(&1[:rank] == 1))

      assert first[:accelerations] == [0.0, 1.0, 1.0]
    end

    test "a malformed 250 raises rather than being skipped" do
      bad = [
        # too short to hold its own fields
        "250 short\r\n",
        # zero game points, which bbpPairings rejects outright
        line_250("0.0", "1", "2", "1", "4"),
        # inverted round range
        line_250("1.0", "3", "1", "1", "4"),
        # inverted player range
        line_250("1.0", "1", "2", "4", "1")
      ]

      for line <- bad do
        assert_raise Trf.ValidationError, fn ->
          Trf.parse(eight_player_roster() <> line)
        end
      end
    end
  end

  describe "260 round-limited forbidden pairs" do
    # `260` is bbpPairings' fixed-column, round-limited sibling of `XXP`:
    # "these players must not meet in rounds 3 to 7". It was on the
    # explicitly-not-covered list until 2026-08-17, on the reasoning that
    # `XXP` is the universal form and the one the sibling project emits.
    #
    # "Not covered" turned out to mean SILENTLY DISCARDED. A file saying 1
    # and 3 must never meet produced a complete, perfectly legal-looking
    # round that seated 1 against 3 — the exact failure `XXP` exists to
    # prevent, in a different spelling. Every expected pairing below was
    # confirmed against bbpPairings 6.0.0 run on the same bytes.
    #
    # Columns, per `readForbiddenPairs260` (`trf.cpp:519-548`): first round
    # in 5-7, last round in 9-11, then four-character starting ranks from
    # column 13 every five columns. The range is INCLUSIVE of the last
    # round (bbpPairings stores it as `[first, last + 1)`).
    defp four_player_roster do
      """
      012 Code 260\r
      062 4\r
      XXR 5\r
      152 W\r
      001    1 m  gm Alpha                            2400 BEL     1000001 1990/01/01  0.0    1\r
      001    2 m  gm Beta                             2300 BEL     1000002 1990/01/01  0.0    2\r
      001    3 m  gm Gamma                            2200 BEL     1000003 1990/01/01  0.0    3\r
      001    4 m  gm Delta                            2100 BEL     1000004 1990/01/01  0.0    4\r
      """
    end

    defp line_260(first, last, a, b) do
      "260 " <>
        String.pad_leading(first, 3) <>
        " " <>
        String.pad_leading(last, 3) <>
        " " <> String.pad_leading(a, 4) <> " " <> String.pad_leading(b, 4) <> "\r\n"
    end

    defp pair_roster(extra) do
      parsed = Trf.parse(four_player_roster() <> extra)

      parsed.players
      |> Pairing.pair_next_round(
        expected_rounds: parsed.tournament[:number_of_rounds],
        forbidden_pairs: parsed.tournament[:forbidden_pairs],
        initial_colour: "w"
      )
      |> normalize()
    end

    test "a 260 covering the round being paired keeps the pair apart" do
      # Without it the engine seats 1 against 3; bbpPairings does the same,
      # and both avoid it once the line is present.
      assert pair_roster("") == [[1, 3], [2, 4]]
      assert pair_roster(line_260("1", "3", "1", "3")) == [[1, 4], [2, 3]]
    end

    test "a 260 whose range excludes this round does nothing" do
      # The whole point of the round range, and the case a universal
      # implementation would get wrong in the safe-looking direction.
      assert pair_roster(line_260("4", "5", "1", "3")) == [[1, 3], [2, 4]]
    end

    test "the range is inclusive of its last round" do
      assert pair_roster(line_260("1", "1", "2", "4")) == [[1, 4], [2, 3]]
    end

    test "the parsed form carries the range" do
      parsed = Trf.parse(four_player_roster() <> line_260("2", "6", "1", "3"))

      assert parsed.tournament[:forbidden_pairs] == [{[1, 3], 2, 6}]
    end

    test "a malformed 260 raises rather than being skipped" do
      # Same standard as XXP and XXA: a dropped exclusion is undetectable
      # downstream, so a line that cannot be read is refused outright. Real
      # bbpPairings throws `InvalidLineException` (exit 3) on both of these.
      for bad <- ["260 1 3\r\n", "260 abc   3    1    3\r\n"] do
        assert_raise Trf.ValidationError, fn ->
          Trf.parse(four_player_roster() <> bad)
        end
      end
    end
  end

  describe "XXR and 142 are the same field" do
    # `142` is TRF16's round count and `XXR` is JaVaFo's spelling of it. A
    # file that has passed through both toolchains can carry each, and two
    # copies of the same number are perfectly ordinary.
    #
    # Two DIFFERENT numbers are not, and are refused. Every implementation
    # silently picks one and they do not agree on which: this engine used
    # to prefer `142` wherever it appeared, bbpPairings takes whichever
    # line comes last. The round count feeds the final-round exception in
    # `colour_compatible?/2` and the topscorer threshold, so the two pair
    # different final rounds from identical bytes — and the loser is a
    # complete, perfectly legal-looking round, which nothing downstream can
    # detect.
    defp roster do
      """
      012 Round counts\r
      062 4\r
      001    1 m  gm Alpha                            2400 BEL     1000001 1990/01/01  0.0    1\r
      001    2 m  gm Beta                             2300 BEL     1000002 1990/01/01  0.0    2\r
      001    3 m  gm Gamma                            2200 BEL     1000003 1990/01/01  0.0    3\r
      001    4 m  gm Delta                            2100 BEL     1000004 1990/01/01  0.0    4\r
      """
    end

    test "either spelling alone sets the round count" do
      assert Trf.parse(roster() <> "142 9\r\n").tournament[:number_of_rounds] == 9
      assert Trf.parse(roster() <> "XXR 5\r\n").tournament[:number_of_rounds] == 5
    end

    test "both spellings agreeing is fine" do
      assert Trf.parse(roster() <> "142 5\r\nXXR 5\r\n").tournament[:number_of_rounds] == 5
      assert Trf.parse(roster() <> "XXR 5\r\n142 5\r\n").tournament[:number_of_rounds] == 5
    end

    test "both spellings disagreeing is refused, in either order" do
      for text <- ["142 9\r\nXXR 5\r\n", "XXR 5\r\n142 9\r\n"] do
        assert_raise Trf.ValidationError, ~r/two different round counts/, fn ->
          Trf.parse(roster() <> text)
        end
      end
    end
  end

  describe "XXP forbidden pairings" do
    @fixture "test/fixtures/forbidden_pairs/only-legal-pairing.trf"

    # Six players, round 4, generated by `Ainalrami.Generator` at seed 3 and
    # then hunted for this property: after three rounds only TWO complete
    # rematch-free pairings exist over the field —
    #
    #     A   1-3, 2-4, 5-6
    #     B   1-5, 2-6, 3-4
    #
    # (each player has exactly two rematch-free opponents left: 1 with 3/5,
    # 2 with 4/6, 3 with 1/4, 4 with 2/3, 5 with 1/6, 6 with 2/5). Forbidding
    # 3-4 eliminates B outright, so A is the only legal answer left and the
    # `XXP` line is the sole thing that selects it.
    test "the only remaining legal pairing is the one that respects the XXP line" do
      {players, tournament} = load(@fixture)

      assert tournament[:forbidden_pairs] == [[3, 4]]

      pairs =
        Pairing.pair_next_round(players,
          expected_rounds: tournament[:number_of_rounds],
          forbidden_pairs: tournament[:forbidden_pairs]
        )

      assert normalize(pairs) == [[1, 3], [2, 4], [5, 6]],
             "real bbpPairings gives exactly this on this file"
    end

    test "and the engine seats the forbidden pair when the line is withheld" do
      {players, tournament} = load(@fixture)

      pairs = Pairing.pair_next_round(players, expected_rounds: tournament[:number_of_rounds])

      assert normalize(pairs) == [[1, 5], [2, 6], [3, 4]],
             "without the exclusion the engine picks the other legal pairing, which is " <>
               "precisely the silent violation this feature exists to prevent"
    end

    # `readForbiddenPairsXxp` (`trf.cpp:554-568`) reads a LIST, and
    # `resolveForbiddenPairs` (`tournament.cpp:100-116`) inserts the whole
    # list into every member's set — so one line of N ids forbids all
    # N*(N-1)/2 pairs inside it, not just the first two.
    #
    # The group is ordered to make that measurable rather than merely
    # asserted. Neither surviving pairing contains 3-6, the group's leading
    # pair, so an implementation that read only the first two ids would
    # leave both legal and return B — its unconstrained preference. Only
    # reading 3-4 as forbidden too eliminates B and forces A.
    test "an N-player group forbids every pair within it, not just the first two" do
      {players, tournament} = load(@fixture)

      pairs =
        Pairing.pair_next_round(players,
          expected_rounds: tournament[:number_of_rounds],
          forbidden_pairs: [[3, 6, 4]]
        )

      assert normalize(pairs) == [[1, 3], [2, 4], [5, 6]]
    end

    # An absolute criterion has to be able to say "impossible", the same
    # way the no-rematch rule does. Forbidding every edge of the only two
    # surviving pairings leaves nothing legal at all, and bbpPairings
    # answers that case with `NoValidPairingException`.
    test "an over-constrained round refuses rather than returning an illegal pairing" do
      {players, tournament} = load(@fixture)

      assert_raise Pairing.NoValidPairingError, fn ->
        Pairing.pair_next_round(players,
          expected_rounds: tournament[:number_of_rounds],
          forbidden_pairs: [[1, 3], [1, 5]]
        )
      end
    end
  end

  describe "XXA acceleration" do
    # Round 1 is where acceleration is most visible and where this engine
    # had the most to get wrong: `pair_round_one/1` assumes a single score
    # group and splits the field by rank alone, which stops being true the
    # moment half the field carries a virtual point. Eight players, top
    # four accelerated by 1.0:
    #
    #     unaccelerated   1-5  2-6  3-7  4-8     (one group, S1 vs S2)
    #     accelerated     1-3  2-4  5-7  6-8     (two groups of four)
    #
    # Both answers are real bbpPairings output on the two files.
    test "round one splits into two score groups" do
      players =
        for rank <- 1..8,
            do: %{rank: rank, name: "P#{rank}", fide_rating: 2000, points: 0.0, games: []}

      assert normalize(Pairing.pair_next_round(players, expected_rounds: 5)) ==
               [[1, 5], [2, 6], [3, 7], [4, 8]]

      accelerated =
        Enum.map(players, fn p ->
          if p.rank <= 4, do: Map.put(p, :accelerations, [1.0, 1.0, 0.5, 0.0, 0.0]), else: p
        end)

      assert normalize(Pairing.pair_next_round(accelerated, expected_rounds: 5)) ==
               [[1, 3], [2, 4], [5, 7], [6, 8]]
    end

    @mid_fixture "test/fixtures/acceleration/mid-tournament-brackets.trf"

    # Eight players, round 3 of five, Group A = ranks 1-4 on FIDE C.04.7's
    # schedule, so the value in play for this round is the half point. Real
    # scores group as 2.0={1} 1.5={3,8} 1.0={2,6} 0.5={4,7} 0.0={5};
    # accelerated they regroup as 2.5={1} 2.0={3} 1.5={2,8} 1.0={4,6}
    # 0.5={7} 0.0={5}, and the pairing follows.
    test "mid-tournament acceleration reshapes the brackets" do
      {players, tournament} = load(@mid_fixture)

      assert normalize(Pairing.pair_next_round(players, expected_rounds: 5)) ==
               [[1, 8], [2, 3], [4, 6], [5, 7]]

      assert tournament[:number_of_rounds] == 5

      unaccelerated = Enum.map(players, &Map.delete(&1, :accelerations))

      assert normalize(Pairing.pair_next_round(unaccelerated, expected_rounds: 5)) ==
               [[1, 8], [2, 3], [4, 5], [6, 7]]
    end

    @float_fixture "test/fixtures/acceleration/float-history-only.trf"

    # The subtle half of acceleration, and the reason JaVaFo's manual says
    # the `XXA` record is "mandatory ... round by round": ten players,
    # round 4 of five, Group A = ranks 1-6, and C.04.7's schedule pays
    # NOTHING in round 4. So every bracket in this round is formed on the
    # real scores and is identical either way — the only thing the
    # acceleration can still touch is the float history, which
    # `score_before/3` reconstructs with the virtual points that applied in
    # rounds 2 and 3 (`scoreWithAcceleration(tournament, roundsBack)`,
    # `tournament.h:335-359`, winds its round index back in step with the
    # score it is stripping).
    #
    # It changes three of the five boards, and bbpPairings — reading the
    # same file — makes the same three changes. Drop the `:accelerations`
    # and the engine reverts to the unaccelerated answer, which is what
    # proves the term is load-bearing rather than decorative.
    test "past rounds' virtual points still move the float history" do
      {players, tournament} = load(@float_fixture)

      assert Enum.all?(
               Enum.filter(players, &(&1.rank <= 6)),
               &(Enum.at(&1[:accelerations], 3) == 0.0)
             ),
             "round 4 itself pays no virtual points in this fixture — that is the point"

      assert normalize(Pairing.pair_next_round(players, expected_rounds: 5)) ==
               [[1, 7], [2, 4], [3, 5], [6, 10], [8, 9]]

      unaccelerated = Enum.map(players, &Map.delete(&1, :accelerations))

      assert normalize(Pairing.pair_next_round(unaccelerated, expected_rounds: 5)) ==
               [[1, 7], [2, 8], [3, 4], [5, 9], [6, 10]]

      assert tournament[:number_of_rounds] == 5
    end
  end
end
