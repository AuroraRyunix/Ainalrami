defmodule Ainalrami.ExchangeOrderTest do
  @moduledoc """
  Article 4.3, the last structural gap between this engine and the
  regulations as written.

  The regulations pair a bracket by *enumeration*: try the natural S1/S2
  pairing, then transpositions of S2 (4.2), and when those are exhausted,
  exchange players between S1 and S2 and start over (4.3), taking the first
  candidate that works. `Ainalrami.Pairing` solves a maximum-weight matching
  instead, which reaches the same optimum without enumerating — so the two
  can only part company over candidates that tie on every criterion, where
  the regulations' tie-break is generation order.

  `tiebreak_order_test.exs` settles the 4.2 half: `transposition_key/3` is
  proven to induce Article 4.2's order exactly. This file is the 4.3 half,
  which had no test at all.

  ## Why it has to be a whole bracket, not a whole round

  An earlier attempt enumerated every legal ROUND-pairing and asked which
  scored best. That question has no answer: the rules define no global
  optimum over rounds, only a sequential per-bracket procedure, and two
  round-pairings float different players and so produce incommensurable
  bracket structures. See `docs/conformance-c0403-2026.md`.

  So every position here makes the bracket under test the **last** one,
  with nothing below it. No candidate can then reach an edge into a lower
  group, every candidate contributes the same edges, and the rung vectors
  are commensurable.

  Most positions are a single homogeneous bracket holding the whole field.
  The last describe block is **heterogeneous** — one moved-down player plus
  seven residents — which is where 3.7.2 alters the MDP-Pairing and which
  was carried as the uncovered residue of this gap until 2026-08-18.

  ## Keeping the oracle honest

  The other way this test goes wrong is a weak legality check. The discarded
  round-level enumerator tested C1 and neither C2 nor C3, so it "found"
  legal pairings the engine had refused — it had admitted illegal ones.

  These positions are built so that **C1 is provably the only binding
  criterion**, and that is asserted rather than assumed: no player is ever
  short of a legal opponent on colour (`no_absolute_colour_clash/1`), and
  with an even field on one score there is no PAB to engage C2 at all.
  """

  use ExUnit.Case, async: true

  alias Ainalrami.{Pairing, Sequence}

  describe "Article 4.3's generation order" do
    test "the engine returns the first candidate the sequence reaches" do
      players = forced_exchange_field()

      # The position: 1-4 have each played all of 5-8, so every one of the
      # 16 S1xS2 pairs is a rematch and no TRANSPOSITION can produce a legal
      # candidate — a transposition only ever re-orders S2, so it can never
      # pair two S1 members together. Only an exchange reaches the legal
      # pairings, which makes 4.3 the sole decider.
      assert every_cross_pair_met?(players)
      assert no_intra_half_pair_met?(players)
      assert no_absolute_colour_clash(players)

      s1 = [1, 2, 3, 4]
      s2 = [5, 6, 7, 8]

      first_legal =
        s1
        |> candidates_in_article_4_order(s2)
        |> Enum.find(&legal?(&1, players))

      assert first_legal, "the sequence must reach a legal candidate"

      ours = Pairing.pair_next_round(players, expected_rounds: 5) |> normalise()

      assert ours == normalise(first_legal),
             """
             the engine's answer is not the first candidate Article 4.3 generates.

               engine:   #{inspect(ours)}
               article:  #{inspect(normalise(first_legal))}
             """
    end

    test "and that candidate is the size-2 exchange 4.3.2 orders first" do
      # Stated independently of the engine AND of the search above, so a bug
      # in `candidates_in_article_4_order/2` cannot make the previous test
      # pass vacuously by agreeing with a wrong engine.
      #
      # Only intra-half pairs are legal here, so a candidate exists only when
      # S1 holds as many original-top players as S2 does — which needs an
      # exchange of exactly 2. Among size-2 exchanges 4.3.2 ranks by the
      # smallest difference between the sums moved each way: out {3,4} (7)
      # against in {5,6} (11) is the closest available, at 4.
      exchanges = Sequence.exchanges([1, 2, 3, 4], [5, 6, 7, 8])

      first_size_two =
        Enum.find(exchanges, fn {new_s1, _} ->
          length(new_s1 -- [1, 2, 3, 4]) == 2
        end)

      assert first_size_two == {[1, 2, 5, 6], [3, 4, 7, 8]}

      # Whose natural (identity) pairing is already legal, so the sequence
      # stops there and never reaches a transposition of it.
      assert normalise([{1, 3}, {2, 4}, {5, 7}, {6, 8}]) ==
               normalise(Enum.zip([1, 2, 5, 6], [3, 4, 7, 8]))
    end

    test "a size-1 exchange is generated first and is correctly passed over" do
      # 4.3.1 exchanges the fewest players first, so every size-1 exchange
      # precedes every size-2 one. None can yield a legal candidate here:
      # after swapping one player each way, S1 holds 3 original-top and 1
      # original-bottom while S2 holds 1 and 3, so at least two S1 members
      # are left needing the same single legal opponent.
      #
      # Pinned because "the engine skipped the first exchange" would
      # otherwise look like a violation of 4.3 rather than the article
      # working as written.
      players = forced_exchange_field()
      exchanges = Sequence.exchanges([1, 2, 3, 4], [5, 6, 7, 8])

      {size_one, size_two} =
        Enum.split_with(exchanges, fn {new_s1, _} -> length(new_s1 -- [1, 2, 3, 4]) == 1 end)

      assert length(size_one) == 16, "4x4 single swaps"
      assert hd(exchanges) in size_one, "4.3.1 orders fewest-exchanged first"

      for {new_s1, new_s2} <- size_one,
          ordering <- Sequence.transpositions(new_s2, length(new_s1)) do
        refute legal?(Enum.zip(new_s1, ordering), players),
               "no size-1 exchange can produce a legal candidate in this position"
      end

      assert Enum.any?(size_two, fn {new_s1, new_s2} ->
               legal?(Enum.zip(new_s1, new_s2), players)
             end)
    end
  end

  describe "over randomly generated brackets" do
    @tag timeout: 300_000
    test "the engine's answer is the earliest-generated of the best candidates" do
      # The general claim, rather than the one constructed position above.
      #
      # 3.8.1 says: take the best candidate on the criteria, and break a
      # remaining tie by which was GENERATED EARLIER. So the engine's answer
      # must be the first candidate, in Article 4's order, that ties for the
      # best rung vector. Scoring uses the engine's own ladder — that half is
      # not independent and is not meant to be. What is independent is the
      # ORDER, which comes from `Ainalrami.Sequence`, and the order is the
      # entire question 4.3 raises.
      checked =
        for seed <- 1..250, reduce: 0 do
          checked ->
            :rand.seed(:exsss, {seed, seed * 7919, seed * 104_729})
            n = Enum.random([6, 8])
            players = random_single_score_field(n, Enum.random(2..3))

            # Only positions where C1 is provably the only binding criterion
            # are usable, for the reason in this module's doc. The rest are
            # skipped rather than papered over.
            if players && no_absolute_colour_clash(players) do
              s1 = Enum.to_list(1..div(n, 2))
              s2 = Enum.to_list((div(n, 2) + 1)..n)

              legal =
                s1
                |> candidates_in_article_4_order(s2)
                |> Enum.filter(&legal?(&1, players))
                |> Enum.uniq_by(&normalise/1)

              if legal == [] do
                checked
              else
                scored = Enum.map(legal, &{&1, score_of(players, &1)})
                best = scored |> Enum.map(&elem(&1, 1)) |> Enum.max()
                {expected, _} = Enum.find(scored, fn {_, rungs} -> rungs == best end)

                ours = Pairing.pair_next_round(players, expected_rounds: 6) |> normalise()

                assert ours == normalise(expected),
                       """
                       seed #{seed}, #{n} players: the engine did not return the
                       earliest-generated best candidate.

                         engine:   #{inspect(ours)}
                         expected: #{inspect(normalise(expected))}
                         position: #{inspect(Enum.map(players, &{&1.rank, Enum.map(&1.games, fn g -> g.opponent_rank end)}))}
                       """

                checked + 1
              end
            else
              checked
            end
        end

      # Guards against the whole loop silently skipping everything, which
      # would leave a green test that checked nothing at all — the failure
      # mode this project has already hit once, with an XXP regression test
      # that asserted two players were not paired in a round where they
      # could never have met.
      #
      # 250 seeds currently yield 40 usable positions; most are rejected for
      # leaving somebody with an absolute colour preference. The floor is set
      # well below that so ordinary drift does not fail the build, but a
      # generator that stops producing positions at all will.
      assert checked >= 20, "only #{checked} usable positions — the generator has drifted"
    end
  end

  describe "a HETEROGENEOUS bracket, where 3.7.2 alters the MDP-Pairing" do
    # The residue the homogeneous cases deliberately leave. A bracket
    # carrying moved-down players pairs in two stages (3.4): the
    # MDP-Pairing seats the MDPs against residents, and the leftover
    # residents form a remainder paired as a homogeneous bracket of its
    # own. 3.7 alters the REMAINDER first and only then the MDP-Pairing,
    # so the MDP-Pairing is the outer loop of the sequence.
    #
    # It is testable here for one reason: this bracket is the LAST one.
    # Nothing sits below it, so no candidate can reach an edge into a next
    # group, every candidate contributes the same four edges, and the rung
    # vectors are commensurable — the condition that makes a per-bracket
    # comparison meaningful at all.
    test "the engine returns the first candidate the sequence reaches" do
      players = heterogeneous_field()

      assert no_absolute_colour_clash(players)

      [_top, bracket] = Pairing.explain_round(players, pair_raw(players), expected_rounds: 5)

      assert bracket.mdps == [1], "one moved-down player"
      assert bracket.residents == [2, 3, 4, 5, 6, 7, 8]
      assert bracket.floats == [], "nothing below, so nothing floats out"

      first_legal =
        [1]
        |> heterogeneous_candidates([2, 3, 4, 5, 6, 7, 8])
        |> Enum.find(&legal?(&1, players))

      assert first_legal

      assert normalise(pair_raw(players)) == normalise(first_legal),
             """
             the engine's answer is not the first candidate Article 4 generates
             for a heterogeneous bracket.

               engine:   #{inspect(normalise(pair_raw(players)))}
               article:  #{inspect(normalise(first_legal))}
             """
    end

    test "and the remainder is altered before the MDP-Pairing, per 3.7" do
      # Pinned so the ORDER of the two loops is explicit rather than
      # implied by the result. The MDP takes resident 2 — the first
      # transposition of S2 — and it is the REMAINDER that has to move,
      # because 3v6 and 4v7 are both rematches. Had the loops been nested
      # the other way, the sequence would have reached "give the MDP a
      # different opponent" before "re-order the remainder", and the
      # engine's answer would pair 1 with somebody other than 2.
      players = heterogeneous_field()
      pairs = normalise(pair_raw(players))

      assert [1, 2] in pairs, "the MDP keeps the first resident 4.2 offers"

      met = met_map(players)
      assert 6 in Map.fetch!(met, 3), "3v6 is a rematch, so the remainder must move"
      assert 7 in Map.fetch!(met, 4), "and so is 4v7"

      # Which makes [7, 6, 8] the first legal ordering of the remainder's
      # own S2, giving 3v7, 4v6, 5v8.
      assert [3, 7] in pairs and [4, 6] in pairs and [5, 8] in pairs
    end
  end

  describe "when a transposition already works, exchanges are never reached" do
    test "an unobstructed bracket takes the identity pairing" do
      # The control. Nobody has met anybody, so S1[i] vs S2[i] is legal and
      # 3.3's very first candidate stands — if the engine reached for an
      # exchange here it would be generating out of order in the other
      # direction, which the forced position above cannot detect.
      players = for rank <- 1..8, do: player(rank, 0.0, [])

      ours = Pairing.pair_next_round(players, expected_rounds: 5) |> normalise()

      assert ours == normalise(Enum.zip([1, 2, 3, 4], [5, 6, 7, 8]))
    end
  end

  ## ---------- the position for the heterogeneous case ----------

  # Eight players, one round played, arranged so the field falls into
  # exactly TWO score groups and the lower one is the last bracket.
  #
  # Player 1 takes a full-point bye and stands alone on 1.0, so they
  # downfloat as the sole MDP. Players 2-7 draw in three pairs and player 8
  # takes a half-point bye, putting all seven on 0.5. One MDP plus seven
  # residents is eight, so the bracket pairs completely and floats nobody.
  #
  # The round-one pairs are chosen so that the remainder's NATURAL pairing
  # is illegal: 3 has met 6 and 4 has met 7, which is what forces the
  # sequence past its first candidate and makes the test say something.
  defp heterogeneous_field do
    [
      player(1, 1.0, [bye("F")]),
      player(2, 0.5, [played(5, "w")]),
      player(3, 0.5, [played(6, "w")]),
      player(4, 0.5, [played(7, "w")]),
      player(5, 0.5, [played(2, "b")]),
      player(6, 0.5, [played(3, "b")]),
      player(7, 0.5, [played(4, "b")]),
      player(8, 0.5, [bye("H")])
    ]
  end

  defp played(opponent, colour),
    do: %{opponent_rank: opponent, colour: colour, result: "="}

  defp bye(code), do: %{opponent_rank: nil, colour: nil, result: code}

  defp pair_raw(players) do
    Pairing.pair_next_round(players, expected_rounds: 5, initial_colour: "w")
  end

  # Article 3.4 and 3.7 for a bracket carrying moved-down players: the
  # MDP-Pairing seats the MDPs against residents, the leftover residents
  # form the remainder, and 3.7 exhausts the remainder's own sequence
  # before altering the MDP-Pairing. So MDP-Pairing is the OUTER loop.
  defp heterogeneous_candidates(mdps, residents) do
    n = length(mdps)

    for ordering <- Sequence.transpositions(residents, n),
        opponents = Enum.take(ordering, n),
        remainder = residents -- opponents,
        remainder_pairing <- homogeneous_candidates(remainder) do
      Enum.zip(mdps, opponents) ++ remainder_pairing
    end
  end

  # A homogeneous sub-bracket's own sequence: split in half per 3.2, then
  # transpositions and exchanges exactly as `candidates_in_article_4_order/2`.
  defp homogeneous_candidates(members) do
    sorted = Enum.sort(members)
    {s1, s2} = Enum.split(sorted, div(length(sorted), 2))

    candidates_in_article_4_order(s1, s2)
  end

  ## ---------- the sequence, per Article 4 ----------

  # Every candidate for one bracket, in the order 3.5-3.7 reach them:
  # transpositions of the natural composition first (4.2), then each
  # exchange in 4.3 order, each with its own transpositions.
  defp candidates_in_article_4_order(s1, s2) do
    natural =
      for ordering <- Sequence.transpositions(s2, length(s1)),
          do: Enum.zip(s1, ordering)

    exchanged =
      for {new_s1, new_s2} <- Sequence.exchanges(s1, s2),
          ordering <- Sequence.transpositions(new_s2, length(new_s1)),
          do: Enum.zip(new_s1, ordering)

    natural ++ exchanged
  end

  ## ---------- scoring one candidate ----------

  # The engine's own C1-C21 ladder for a candidate, via `explain_round/3`.
  # The field is a single score group, so there is exactly one bracket and
  # its rung vector is the whole answer. Every candidate pairs the entire
  # field, so `edge_count` is constant across them and the vectors are
  # commensurable — the condition the adjudicator's `incomparable` verdict
  # exists to detect when it does not hold.
  defp score_of(players, pairs) do
    [bracket] = Pairing.explain_round(players, pairs, expected_rounds: 6)
    bracket.rungs
  end

  # A field on one score with a random legal history. All results are draws,
  # so nobody separates on points and the whole field stays one bracket.
  # Colours go to whoever currently has fewer Whites, which keeps colour
  # differences near zero; positions where that still leaves an absolute
  # preference are rejected by the caller rather than fixed up here.
  defp random_single_score_field(n, rounds) do
    ranks = Enum.to_list(1..n)

    Enum.reduce_while(1..rounds, Map.new(ranks, &{&1, []}), fn _round, history ->
      case random_matching(ranks, history) do
        nil -> {:halt, nil}
        matching -> {:cont, apply_matching(matching, history)}
      end
    end)
    |> case do
      nil ->
        nil

      history ->
        for rank <- ranks do
          games = Map.fetch!(history, rank)
          player(rank, length(games) * 0.5, games)
        end
    end
  end

  # A perfect matching over `ranks` avoiding every pair already played.
  defp random_matching(ranks, history) do
    met = Map.new(history, fn {rank, games} -> {rank, Enum.map(games, & &1.opponent_rank)} end)

    Enum.reduce_while(1..40, nil, fn _attempt, _acc ->
      case try_matching(Enum.shuffle(ranks), met, []) do
        nil -> {:cont, nil}
        matching -> {:halt, matching}
      end
    end)
  end

  defp try_matching([], _met, acc), do: acc

  defp try_matching([a | rest], met, acc) do
    case Enum.find(rest, &(&1 not in Map.fetch!(met, a))) do
      nil -> nil
      b -> try_matching(rest -- [b], met, [{a, b} | acc])
    end
  end

  defp apply_matching(matching, history) do
    Enum.reduce(matching, history, fn {a, b}, acc ->
      last = fn rank -> acc |> Map.fetch!(rank) |> List.last() |> then(&(&1 && &1.colour)) end
      whites = fn rank -> acc |> Map.fetch!(rank) |> Enum.count(&(&1.colour == "w")) end

      # Alternation first, since repeating a colour is what creates an
      # ABSOLUTE preference (1.7.1) and an absolute preference is what makes
      # C3 bind — which would leave C1 no longer the only binding criterion
      # and the position unusable. Colour balance only breaks the tie.
      {white, black} =
        case {last.(a), last.(b)} do
          {"b", "w"} -> {a, b}
          {"w", "b"} -> {b, a}
          _ -> if whites.(a) <= whites.(b), do: {a, b}, else: {b, a}
        end

      acc
      |> Map.update!(white, &(&1 ++ [%{opponent_rank: black, colour: "w", result: "="}]))
      |> Map.update!(black, &(&1 ++ [%{opponent_rank: white, colour: "b", result: "="}]))
    end)
  end

  ## ---------- legality, independent of the engine ----------

  # C1 only, which is sound HERE because the positions assert away
  # everything else: an even field on a single score has no PAB (C2), and
  # `no_absolute_colour_clash/1` rules out C3.
  defp legal?(pairs, players) do
    met = met_map(players)

    Enum.all?(pairs, fn {a, b} -> b not in Map.fetch!(met, a) end)
  end

  defp met_map(players) do
    Map.new(players, fn p -> {p.rank, Enum.map(p.games, & &1.opponent_rank)} end)
  end

  defp every_cross_pair_met?(players) do
    met = met_map(players)
    Enum.all?(1..4, fn a -> Enum.all?(5..8, fn b -> b in Map.fetch!(met, a) end) end)
  end

  defp no_intra_half_pair_met?(players) do
    met = met_map(players)

    Enum.all?([{1, 2}, {1, 3}, {1, 4}, {2, 3}, {2, 4}, {3, 4}], fn {a, b} ->
      b not in Map.fetch!(met, a)
    end)
  end

  # Article 1.7.1: an absolute preference is a colour difference outside
  # ±1, or the same colour in the two latest rounds played. C3 forbids two
  # players with the SAME absolute preference from meeting, so if nobody
  # holds one, C3 cannot make any pair illegal and C1 stands alone.
  #
  # Only PLAYED games count (1.7.4 via `points_for`-style results): a bye
  # carries no colour and cannot create or break a run. Written to hold for
  # short histories too — a player with one game or none has a colour
  # difference of at most one and no repeated pair, so they never hold an
  # absolute preference.
  defp no_absolute_colour_clash(players) do
    Enum.all?(players, fn p ->
      colours =
        p.games |> Enum.filter(&(&1.result in ~w(1 = 0))) |> Enum.map(& &1.colour)

      whites = Enum.count(colours, &(&1 == "w"))
      diff = whites - (length(colours) - whites)
      last_two = colours |> Enum.reverse() |> Enum.take(2)

      abs(diff) <= 1 and not match?([x, x], last_two)
    end)
  end

  ## ---------- the position ----------

  # Eight players, four rounds, arranged so every 1-4 x 5-8 pair has already
  # been played and no pair inside either half has. Everyone finishes on 2.0,
  # so round five is a single homogeneous bracket. Colours alternate, so no
  # player holds an absolute preference and C3 never binds.
  defp forced_exchange_field do
    rounds = [
      [{1, 5}, {2, 6}, {3, 7}, {4, 8}],
      [{6, 1}, {5, 2}, {8, 3}, {7, 4}],
      [{1, 7}, {2, 8}, {3, 5}, {4, 6}],
      [{8, 1}, {7, 2}, {6, 3}, {5, 4}]
    ]

    # Top half wins rounds 1-2, bottom half rounds 3-4, so all reach 2.0.
    winner_of = fn round, white, black ->
      if round <= 2 do
        if white <= 4, do: white, else: black
      else
        if white <= 4, do: black, else: white
      end
    end

    games =
      rounds
      |> Enum.with_index(1)
      |> Enum.reduce(%{}, fn {pairs, round}, acc ->
        Enum.reduce(pairs, acc, fn {white, black}, inner ->
          won = winner_of.(round, white, black)

          inner
          |> add_game(white, black, "w", if(won == white, do: "1", else: "0"))
          |> add_game(black, white, "b", if(won == black, do: "1", else: "0"))
        end)
      end)

    for rank <- 1..8 do
      history = Map.fetch!(games, rank)
      player(rank, Enum.count(history, &(&1.result == "1")) * 1.0, history)
    end
  end

  defp add_game(acc, rank, opponent, colour, result) do
    Map.update(
      acc,
      rank,
      [%{opponent_rank: opponent, colour: colour, result: result}],
      &(&1 ++ [%{opponent_rank: opponent, colour: colour, result: result}])
    )
  end

  defp normalise(pairs) do
    pairs
    |> Enum.map(fn {a, b} -> Enum.sort([a, b]) end)
    |> Enum.sort()
  end

  defp player(rank, points, games) do
    %{
      rank: rank,
      name: "P#{rank}",
      sex: "",
      title: "",
      federation: "",
      fide_rating: 2000 - rank,
      fide_number: nil,
      birth_date: "",
      points: points,
      games: games
    }
  end
end
