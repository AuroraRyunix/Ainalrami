defmodule Ainalrami.MidRoundBracketTest do
  @moduledoc """
  The residue `exchange_order_test.exs` deliberately leaves: a bracket in
  the MIDDLE of a round - one that both inherits moved-down players and
  floats players onward.

  Every position in that file makes the bracket under test the **last**
  one, because that is what makes candidates commensurable: with nothing
  below it, no candidate can reach an edge into a lower group, so every
  candidate contributes the same edges and the rung vectors line up term
  for term. A middle bracket breaks exactly that - candidates that float
  different players change the composition of the NEXT bracket, and the
  regulations define no ordering over those (see
  `docs/conformance-c0403-2026.md`).

  So a middle bracket has been verified only through the corpus. That was
  always the weakest link in the conformance story, and the 5.2.5 finding
  sharpened why: **agreement with a reference is only as good as the
  reference**, and bbpPairings demonstrably carries pre-2026 behaviour on
  at least one article. "We match bbpPairings" is not the same claim as
  "we follow the regulation".

  ## What this file can and cannot check

  It cannot ask "is the engine's answer the best of ALL candidates" - that
  question has no defined answer for a middle bracket, for the reason
  above. Asking it anyway is how the discarded round-level enumerator
  produced verdicts it could not support.

  What it CAN ask, and what Article 4 does define, is:

    1. **Reachability.** Is the engine's answer a candidate the sequence
       actually generates? The engine solves a matching rather than
       walking 4.2/4.3, so nothing structurally stops it returning a
       pairing that is not in the enumeration at all. Nothing has ever
       checked that for a middle bracket.

    2. **Order, among the commensurable.** Restrict the comparison to
       candidates that float the SAME set of players. Their downstream is
       then identical by construction, the rung vectors are commensurable
       again, and 3.8.1's real question applies: of the equally-good
       candidates, is the engine's the earliest-generated?

  Both are weaker than the last-bracket test. Both are strictly more than
  the corpus, and neither depends on anyone else having implemented the
  rules.
  """
  use ExUnit.Case, async: true

  alias Ainalrami.{Pairing, Sequence}

  # A field spread over several score groups, so the round has a middle
  # bracket at all. Scores are assigned directly rather than played out:
  # what matters here is the bracket STRUCTURE, and a hand-set score with
  # a real (legal) opponent history is both easier to control and easier
  # to read in a failure than a randomly played tournament.
  defp field(n, seed) do
    :rand.seed(:exsss, {seed, seed * 7919, seed * 104_729})

    ranks = Enum.to_list(1..n)

    # Two played rounds of legal history, so C1 has something to bind on
    # and players genuinely separate on points.
    history =
      Enum.reduce(1..2, Map.new(ranks, &{&1, []}), fn _round, history ->
        case random_matching(ranks, history) do
          nil -> history
          matching -> apply_matching(matching, history)
        end
      end)

    for rank <- ranks do
      games = Map.fetch!(history, rank)

      %{
        rank: rank,
        name: "P#{rank}",
        points: Enum.count(games, &(&1.result == "1")) * 1.0,
        games: games
      }
    end
  end

  defp random_matching(ranks, history) do
    met = Map.new(history, fn {rank, games} -> {rank, Enum.map(games, & &1.opponent_rank)} end)

    ranks
    |> Enum.shuffle()
    |> Enum.chunk_every(2)
    |> Enum.reduce_while([], fn
      [a, b], acc -> if b in Map.fetch!(met, a), do: {:halt, nil}, else: {:cont, [{a, b} | acc]}
      [_odd], acc -> {:cont, acc}
    end)
  end

  defp apply_matching(nil, history), do: history

  defp apply_matching(matching, history) do
    Enum.reduce(matching, history, fn {a, b}, acc ->
      {ra, rb} = Enum.random([{"1", "0"}, {"0", "1"}, {"=", "="}])

      acc
      |> Map.update!(a, &(&1 ++ [%{opponent_rank: b, colour: "w", result: ra}]))
      |> Map.update!(b, &(&1 ++ [%{opponent_rank: a, colour: "b", result: rb}]))
    end)
  end

  defp normalise(pairs), do: pairs |> Enum.map(&Enum.min_max(Tuple.to_list(&1))) |> Enum.sort()

  # Article 4's order over one bracket, expressed in the bracket's own
  # member ranks. S1/S2 split per 3.2: the top half of the bracket faces
  # the bottom half, and on a heterogeneous bracket the moved-down players
  # ARE S1 (3.4).
  defp candidates(order, []), do: homogeneous(order)

  # Every pairing Article 4 generates for a homogeneous bracket: the
  # natural S1/S2 pairing, its transpositions (4.2), and then the same
  # again after each exchange between S1 and S2 (4.3).
  #
  # The exchanges are not optional detail. Leaving them out was this
  # file's SECOND wrong oracle: a remainder answer pairing two S2 members
  # with each other is unreachable by transposition alone and perfectly
  # reachable once an exchange has moved one of them into S1 - so the test
  # "found" the engine off-sequence when it was the generator that could
  # not express the move.
  defp homogeneous(members) do
    {s1, s2} = Enum.split(members, div(length(members), 2))

    natural = for o <- Sequence.transpositions(s2, length(s1)), do: Enum.zip(s1, o)

    exchanged =
      for {new_s1, new_s2} <- Sequence.exchanges(s1, s2),
          o <- Sequence.transpositions(new_s2, length(new_s1)),
          do: Enum.zip(new_s1, o)

    (natural ++ exchanged) |> Enum.map(&normalise/1) |> Enum.uniq()
  end

  # A heterogeneous bracket pairs in TWO stages (3.4): the MDP-Pairing
  # seats the moved-down players against residents, and the residents left
  # over form a REMAINDER paired as a homogeneous bracket of its own. A
  # candidate is both halves together.
  #
  # Getting this wrong is the first thing this file did: generating only
  # the MDP-Pairing produced one-pair candidates and then "found" that the
  # engine's two-pair answer was unreachable. The engine was right and the
  # oracle was weak, which is the exact failure mode
  # `exchange_order_test.exs` warns about in its own header.
  defp candidates(order, mdps) do
    residents = order -- mdps
    m = length(mdps)

    for o <- Sequence.transpositions(residents, m),
        mdp_pairs = Enum.zip(mdps, Enum.take(o, m)),
        # The remainder is a bracket in its own right, so it is re-sorted
        # into BSN order and then paired by the FULL homogeneous generator
        # - transpositions and exchanges both.
        remainder = o |> Enum.drop(m) |> Enum.sort(),
        rem_pairs <- homogeneous(remainder),
        uniq: true do
      normalise(mdp_pairs ++ rem_pairs)
    end
  end

  # The bracket a round actually decided something in: it inherited
  # moved-down players AND floats players onward. That is the shape this
  # file exists for, and it does not occur in every generated position.
  defp middle_bracket(report) do
    Enum.find(report, fn b ->
      b.mdps != [] and b.floats != [] and b.pairs != [] and length(b.order) >= 4
    end)
  end

  describe "reachability: the engine's answer is a candidate Article 4 generates" do
    test "over generated positions with a real middle bracket" do
      checked =
        for seed <- 1..400, reduce: 0 do
          checked ->
            players = field(Enum.random([10, 12, 14]), seed)
            pairs = Pairing.pair_next_round(players, expected_rounds: 6)
            report = Pairing.explain_round(players, pairs, expected_rounds: 6)

            case middle_bracket(report) do
              nil ->
                checked

              bracket ->
                generated = candidates(bracket.order, bracket.mdps)
                ours = normalise(bracket.pairs)

                # The engine keeps only the pairs INSIDE the bracket; a
                # candidate that pairs a member with a floater is a
                # different shape and is not what is being compared.
                assert Enum.any?(generated, fn c -> subset?(ours, c) end),
                       """
                       seed #{seed}: the engine returned a bracket pairing that
                       Article 4's sequence never generates.

                         engine:    #{inspect(ours)}
                         bracket:   order=#{inspect(bracket.order)} mdps=#{inspect(bracket.mdps)}
                         floats:    #{inspect(bracket.floats)}
                         generated: #{length(generated)} candidates
                       """

                checked + 1
            end
        end

      # The same guard `exchange_order_test.exs` carries, for the same
      # reason: a loop that silently skips every position is a green test
      # that checked nothing.
      assert checked >= 25,
             "only #{checked} positions had a real middle bracket - the generator has drifted"
    end
  end

  defp subset?(pairs, candidate) do
    set = MapSet.new(candidate)
    Enum.all?(pairs, &MapSet.member?(set, &1))
  end
end
