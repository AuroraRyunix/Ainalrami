defmodule Ainalrami.ExplainRoundInvariantsTest do
  @moduledoc """
  The version-2 report (`s1`/`s2`, `states`, `exclusions`) checked over every
  TRF fixture in the tree, against rules restated HERE from the regulation
  rather than read back from the engine.

  `explain_round_test.exs` checks the new fields on a six-player roster whose
  answers were worked out by hand. That proves the shape; it does not prove
  the report is consistent with itself on a real field deep into a
  tournament, which is where an arbiter reads it. So, for every fixture:

    * the engine never used a pair it reports as excluded - if it ever did,
      the exclusion list would be describing a different search than the one
      that ran;
    * S1 and S2 partition the bracket in the order the pairing saw it;
    * every player in the bracket has exactly one state, and none from
      outside it;
    * each state's `class` is what C.04.2.D gives for its colour run, and
      `difference` is the signed count the arbiter would get by hand;
    * every excluded pair is inside the bracket, and a rematch names a
      round both players actually played each other in.
  """

  use ExUnit.Case, async: true

  alias Ainalrami.{Pairing, Trf}

  @fixtures Path.wildcard("test/fixtures/**/*.trf")

  # C.04.2.D, restated. Absolute: colour difference beyond ±1, or the same
  # colour in the two latest games played. Strong: a difference of exactly
  # one. Mild: balanced, with games to alternate from. None: nothing played.
  defp fide_class([]), do: :none

  defp fide_class(colours) do
    whites = Enum.count(colours, &(&1 == "w"))
    blacks = Enum.count(colours, &(&1 == "b"))

    cond do
      abs(whites - blacks) > 1 -> :absolute
      match?([c, c], Enum.take(colours, -2)) -> :absolute
      whites != blacks -> :strong
      true -> :mild
    end
  end

  # A rematch claim, checked from the raw games rather than trusted: both
  # players must record each other as the opponent in that round.
  defp met_in?(by_rank, a, b, round) do
    game = fn rank -> by_rank |> Map.fetch!(rank) |> Map.fetch!(:games) |> Enum.at(round - 1) end

    case {game.(a), game.(b)} do
      {%{opponent_rank: ^b}, %{opponent_rank: ^a}} -> true
      _ -> false
    end
  end

  test "there are fixtures to check" do
    assert length(@fixtures) > 20
  end

  for path <- @fixtures do
    @path path

    test "#{Path.relative_to(path, "test/fixtures")}: the report agrees with itself and with FIDE" do
      parsed = @path |> File.read!() |> Trf.parse()
      opts = [expected_rounds: 11, forbidden_pairs: parsed.tournament[:forbidden_pairs]]
      by_rank = Map.new(parsed.players, &{&1.rank, &1})

      pairs = Pairing.pair_next_round(parsed.players, opts)
      report = Pairing.explain_round(parsed.players, pairs, opts)

      for bracket <- report do
        where = "bracket #{bracket.group}"

        excluded = MapSet.new(bracket.exclusions, &Enum.sort(&1.players))
        used = MapSet.new(bracket.pairs, fn {a, b} -> Enum.sort([a, b]) end)

        assert MapSet.disjoint?(excluded, used),
               "#{where}: a pair the report calls excluded was used: " <>
                 inspect(MapSet.to_list(MapSet.intersection(excluded, used)))

        assert bracket.s1 ++ bracket.s2 == bracket.order,
               "#{where}: S1 ++ S2 is not the bracket in its own order"

        assert Enum.sort(Enum.map(bracket.states, & &1.rank)) == Enum.sort(bracket.order),
               "#{where}: states do not cover the bracket exactly once"

        for state <- bracket.states do
          assert state.class == fide_class(state.colours),
                 "#{where}: ##{state.rank} #{Enum.join(state.colours)} reported #{state.class}"

          whites = Enum.count(state.colours, &(&1 == "w"))
          blacks = Enum.count(state.colours, &(&1 == "b"))
          assert state.difference == whites - blacks, "#{where}: ##{state.rank} difference"
          assert state.whites == whites and state.blacks == blacks, "#{where}: ##{state.rank} counts"
        end

        for x <- bracket.exclusions do
          [a, b] = x.players
          assert a in bracket.order and b in bracket.order, "#{where}: exclusion names an outsider"

          if x.reason == :rematch do
            assert met_in?(by_rank, a, b, x.round),
                   "#{where}: #{a} and #{b} did not meet in round #{x.round}"
          end
        end
      end
    end
  end
end
