defmodule Ainalrami.AlternativesWholeTest do
  @moduledoc """
  The `alternative` a searched candidate carries: the round its verdict is
  about, as far as it differs from the one played. Held to the forced
  search it came from on generated rounds - the search is run again here
  and the two must describe the same round - and to two rounds small
  enough to read by hand.
  """

  use ExUnit.Case, async: true

  alias Ainalrami.{Alternatives, Pairing}

  @tournaments 150
  @expected_rounds 7

  defp player(rank) do
    %{
      name: "P#{rank}",
      title: "",
      federation: "",
      sex: "",
      fide_rating: 2400 - rank * 10,
      fide_number: nil,
      birth_date: "",
      points: 0.0,
      rank: rank,
      games: []
    }
  end

  defp play(players, pairs) do
    outcome =
      Enum.reduce(pairs, %{}, fn
        {w, nil}, acc ->
          Map.put(acc, w, {%{result: "U", colour: nil, opponent_rank: nil}, 1.0})

        {w, b}, acc ->
          {rw, rb, pw, pb} =
            Enum.random([{"1", "0", 1.0, 0.0}, {"0", "1", 0.0, 1.0}, {"=", "=", 0.5, 0.5}])

          acc
          |> Map.put(w, {%{result: rw, colour: "w", opponent_rank: b}, pw})
          |> Map.put(b, {%{result: rb, colour: "b", opponent_rank: w}, pb})
      end)

    Enum.map(players, fn p ->
      {game, points} = Map.fetch!(outcome, p.rank)
      %{p | games: p.games ++ [game], points: p.points + points}
    end)
  end

  # Small fields played forward on the engine's own pairings with random
  # results, five rounds or until no round can be paired.
  defp rounds(seed) do
    :rand.seed(:exsss, {seed, 17, 29})
    field = for r <- 1..Enum.random(5..14), do: player(r)

    {_players, rounds} =
      Enum.reduce_while(1..5, {field, []}, fn _, {players, acc} ->
        try do
          pairs = Pairing.pair_next_round(players, expected_rounds: @expected_rounds)
          {:cont, {play(players, pairs), [{players, pairs} | acc]}}
        rescue
          Pairing.NoValidPairingError -> {:halt, {players, acc}}
        end
      end)

    Enum.reverse(rounds)
  end

  defp opts, do: [expected_rounds: @expected_rounds, max_candidates: :all]

  # The forced search a float candidate's verdict came from, run again.
  defp forced_float(players, pairs, group, y) do
    bracket =
      players
      |> Pairing.explain_round(pairs, expected_rounds: @expected_rounds)
      |> Enum.find(&(&1.group == group))

    forced = for m <- bracket.order, m != y, do: [y, m]
    Pairing.pair_next_round(players, expected_rounds: @expected_rounds, forbidden_pairs: forced)
  end

  defp forced_bye(players, y) do
    forced = for %{rank: m} <- players, m != y, do: [y, m]
    Pairing.pair_next_round(players, expected_rounds: @expected_rounds, forbidden_pairs: forced)
  end

  defp bye_of(pairs), do: Enum.find_value(pairs, fn {w, b} -> if is_nil(b), do: w end)

  # Everything `alternative` says, against the round it is supposed to be.
  defp assert_describes(candidate, players, pairs, alt_pairs) do
    whole = candidate.alternative
    context = "candidate #{candidate.rank}: #{inspect(whole)}"

    # Played, minus the boards it gives up, plus the boards it adds, is the
    # alternative round - every board of it, colours included.
    assert Enum.sort((pairs -- whole.played) ++ whole.pairs) == Enum.sort(alt_pairs), context
    assert whole.pairs -- pairs == whole.pairs, context
    assert whole.played -- alt_pairs == whole.played, context
    assert whole.unchanged == length(alt_pairs) - length(whole.pairs), context
    assert whole.bye == bye_of(alt_pairs), context

    # Its own board order, not the played round's.
    assert whole.pairs == Enum.filter(alt_pairs, &(&1 in whole.pairs)), context

    played = Pairing.explain_round(players, pairs, expected_rounds: @expected_rounds)
    theirs = Pairing.explain_round(players, alt_pairs, expected_rounds: @expected_rounds)
    was = Map.new(played, &{&1.group, {Enum.sort(&1.pairs), Enum.sort(&1.floats)}})

    expected =
      for b <- theirs, Map.get(was, b.group) != {Enum.sort(b.pairs), Enum.sort(b.floats)} do
        {b.group, Enum.sort(b.pairs), b.floats}
      end

    got =
      for b <- whole.brackets do
        # Complete, and seated as the alternative seats them.
        assert Enum.all?(b.pairs, &(&1 in alt_pairs)), context

        {b.group, b.pairs |> Enum.map(fn {w, k} -> Enum.min_max([w, k]) end) |> Enum.sort(),
         b.floats}
      end

    assert got == expected, context

    # The one board the record used to keep is one of them.
    case candidate.fate do
      %{opponent: nil} ->
        assert whole.bye == candidate.rank or whole.pairs == [], context

      %{opponent: o} ->
        assert {candidate.rank, o} in alt_pairs or {o, candidate.rank} in alt_pairs
    end

    case candidate.outcome do
      :same ->
        assert whole.pairs == [] and whole.played == [] and whole.brackets == [], context
        assert whole.step == nil

      :tie ->
        assert whole.step in [nil, :transposition, :exchange, :floater], context

      _ ->
        assert whole.step == nil, context
    end
  end

  test "every float candidate's alternative is the round its forced search finds" do
    for seed <- 1..@tournaments, {players, pairs} <- rounds(seed) do
      for entry <- Alternatives.float_alternatives(players, pairs, opts()),
          candidate <- entry.candidates do
        case candidate.outcome do
          :impossible ->
            refute Map.has_key?(candidate, :alternative)

          _ ->
            alt_pairs = forced_float(players, pairs, entry.group, candidate.rank)
            assert_describes(candidate, players, pairs, alt_pairs)
        end
      end
    end
  end

  test "every bye candidate's alternative is the round its forced search finds" do
    for seed <- 1..@tournaments, {players, pairs} <- rounds(seed) do
      case Alternatives.bye_alternatives(players, pairs, opts()) do
        nil ->
          :ok

        %{candidates: candidates} ->
          for candidate <- candidates do
            if candidate.outcome in [:impossible, :ineligible] do
              refute Map.has_key?(candidate, :alternative)
            else
              assert_describes(candidate, players, pairs, forced_bye(players, candidate.rank))
            end
          end
      end
    end
  end

  test "the verdict is what it was: the alternative is an added key and nothing else" do
    for seed <- 1..40, {players, pairs} <- rounds(seed) do
      with_boards = Alternatives.float_alternatives(players, pairs, opts())

      without =
        Alternatives.float_alternatives(players, pairs, [max_alternative_boards: 0] ++ opts())

      strip = fn entries ->
        Enum.map(entries, fn e ->
          %{e | candidates: Enum.map(e.candidates, &Map.delete(&1, :alternative))}
        end)
      end

      assert strip.(with_boards) == strip.(without)
    end
  end

  # Seed 6, round 2, of the generator above: twelve players, and 12 goes
  # down from the 1.0 bracket where 8 could have gone as well.
  describe "a round small enough to read" do
    setup do
      [{players, pairs} | _] = Enum.drop(rounds(6), 1)
      %{players: players, pairs: pairs}
    end

    test "a transposition: another S2 player leaves, S1 still meets S2", ctx do
      entry =
        ctx.players
        |> Alternatives.float_alternatives(ctx.pairs, opts())
        |> Enum.find(&(&1.floater == 12 and &1.group == 1.0))

      candidate = Enum.find(entry.candidates, &(&1.rank == 8))
      assert candidate.outcome == :tie
      assert candidate.differs_at.lex == :actual

      assert %{
               pairs: [{7, 12}, {4, 8}],
               played: [{7, 8}, {4, 12}],
               step: :transposition,
               bye: nil
             } = candidate.alternative

      assert candidate.alternative.unchanged == length(ctx.pairs) - 2

      # Both brackets the swap touches, whole: the one 8 now leaves and the
      # one 8 arrives in.
      assert [%{group: 1.0, floats: [8]} = upper, %{group: 0.5} = lower] =
               candidate.alternative.brackets

      assert Enum.all?(
               upper.pairs ++ lower.pairs,
               &(&1 in ((ctx.pairs -- [{7, 8}, {4, 12}]) ++ [{7, 12}, {4, 8}]))
             )

      assert {4, 8} in lower.pairs
    end
  end

  describe "the board cap" do
    test "past it the alternative is not written out, and says how many boards" do
      [{players, pairs} | _] = Enum.drop(rounds(6), 1)

      entry =
        players
        |> Alternatives.float_alternatives(pairs, [max_alternative_boards: 1] ++ opts())
        |> Enum.find(&(&1.floater == 12 and &1.group == 1.0))

      candidate = Enum.find(entry.candidates, &(&1.rank == 8))
      assert candidate.alternative == %{skipped: :too_many_boards, count: 2}
      assert candidate.outcome == :tie
    end

    test "the default is said, and the option never reaches the engine" do
      assert Alternatives.max_alternative_boards() == 40
      [{players, pairs} | _] = rounds(6)

      assert is_list(
               Alternatives.float_alternatives(players, pairs,
                 max_alternative_boards: :all,
                 expected_rounds: @expected_rounds
               )
             )

      assert Alternatives.float_alternative(players, pairs, 1.0, 99,
               max_alternative_boards: 3,
               expected_rounds: @expected_rounds
             ) == nil
    end
  end

  # An S1 player can only leave a homogeneous bracket if an S2 player takes
  # the place: seed 14, round 2, where 2 (top half of the 1.0 bracket)
  # would go down instead of 6.
  test "an exchange: a top-half player leaves the bracket" do
    [{players, pairs} | _] = Enum.drop(rounds(14), 1)

    entry =
      players
      |> Alternatives.float_alternatives(pairs, opts())
      |> Enum.find(&(&1.floater == 6 and &1.group == 1.0))

    assert %{outcome: :tie, alternative: %{step: :exchange}} =
             Enum.find(entry.candidates, &(&1.rank == 2))

    assert %{outcome: :tie, alternative: %{step: :transposition}} =
             Enum.find(entry.candidates, &(&1.rank == 4))
  end
end
