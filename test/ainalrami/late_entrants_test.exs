defmodule Ainalrami.LateEntrantsTest do
  @moduledoc """
  Unit coverage for `PAIRING_FUZZ_LATE_PCT` and the generator functions it
  drives - independent of any reference binary, so this runs in `mix test`
  with no setup. The bbpPairings-backed comparison lives in
  `bbppairings_comparison_test.exs` under the `late_entrants` tag.
  """
  use ExUnit.Case, async: false

  import Ainalrami.Test.FuzzTournament

  setup do
    on_exit(fn ->
      System.delete_env("PAIRING_FUZZ_LATE_PCT")
      System.delete_env("PAIRING_FUZZ_LATE_BYE_TYPE")
      System.delete_env("PAIRING_FUZZ_ROUNDS_MAX")
      System.delete_env("PAIRING_FUZZ_MIN_PLAYERS")
      System.delete_env("PAIRING_FUZZ_MAX_PLAYERS")

      Enum.each(
        [
          :fuzz_late_entrants,
          :fuzz_late_bye_type,
          :fuzz_initial_colour,
          :fuzz_accel,
          :fuzz_numeric,
          :fuzz_rating_mode,
          :fuzz_withdrawn,
          :fuzz_point_system
        ],
        &Process.delete/1
      )
    end)

    :ok
  end

  describe "PAIRING_FUZZ_LATE_PCT validation" do
    test "an out-of-range value stops the run rather than silently emptying it" do
      System.put_env("PAIRING_FUZZ_LATE_PCT", "101")

      assert_raise ArgumentError, ~r/PAIRING_FUZZ_LATE_PCT/, fn ->
        begin!(1, 9, 4..4)
      end
    end

    test "a negative value stops the run" do
      System.put_env("PAIRING_FUZZ_LATE_PCT", "-1")

      assert_raise ArgumentError, ~r/PAIRING_FUZZ_LATE_PCT/, fn ->
        begin!(1, 9, 4..4)
      end
    end

    test "unset defaults to no late entrants at all" do
      {_rounds, _count, _forbidden, _roster} = begin!(1, 9, 20..20)
      assert late_entrant_map() == %{}
    end

    test "PAIRING_FUZZ_LATE_BYE_TYPE rejects anything but Z or H" do
      System.put_env("PAIRING_FUZZ_LATE_PCT", "50")
      System.put_env("PAIRING_FUZZ_LATE_BYE_TYPE", "bogus")

      assert_raise ArgumentError, ~r/PAIRING_FUZZ_LATE_BYE_TYPE/, fn ->
        begin!(1, 9, 20..20)
      end
    end
  end

  describe "100% late produces the construct on every player" do
    setup do
      System.put_env("PAIRING_FUZZ_LATE_PCT", "100")
      :ok
    end

    test "every late entrant's recorded entry round is between 2 and the middle of the event" do
      {rounds, count, _forbidden, _roster} = begin!(1, 11, 30..30)
      late = late_entrant_map()

      assert map_size(late) == count

      Enum.each(late, fn {_rank, entry_round} ->
        assert entry_round >= 2
        assert entry_round <= div(rounds, 2) + 1
        assert entry_round <= rounds
      end)
    end

    test "TPNs are reassigned so late entrants sort after everyone else, with no gaps" do
      {_rounds, count, _forbidden, roster} = begin!(6, 9, 20..20)
      late = late_entrant_map()

      assert Enum.map(roster, & &1.rank) |> Enum.sort() == Enum.to_list(1..count)
      # Every rank in the late map is strictly greater than every rank not in it.
      not_late_ranks = for r <- 1..count, not Map.has_key?(late, r), do: r
      late_ranks = Map.keys(late)

      if not_late_ranks != [] and late_ranks != [] do
        assert Enum.max(not_late_ranks) < Enum.min(late_ranks)
      end
    end

    test "a late entrant has no games at all before its entry round" do
      {_rounds, _count, _forbidden, roster} = begin!(2, 9, 10..10)
      late = late_entrant_map()

      {active_r1, pending_r1} = reveal_late_entrants(roster, 1)
      # Round 1 never has a late entrant: 2.4's "only taken into account
      # for the pairing of rounds after the first" leaves round 1 to
      # whoever is not late, and this axis draws entry >= 2 for everyone.
      assert length(pending_r1) == map_size(late)
      assert Enum.all?(active_r1, &(&1.games == []))
    end

    test "on its entry round, a late entrant's missed rounds are backfilled as Z, not blank" do
      {_rounds, _count, _forbidden, roster} = begin!(3, 9, 12..12)
      late = late_entrant_map()
      {rank, entry_round} = Enum.min_by(late, fn {_r, e} -> e end)

      # Walk every round up to entry, revealing and re-merging exactly as
      # the comparison harness does, without ever asking a pairing engine.
      final =
        Enum.reduce(1..entry_round, roster, fn round, players ->
          {active, pending} = reveal_late_entrants(players, round)
          active ++ pending
        end)

      player = Enum.find(final, &(&1.rank == rank))
      assert length(player.games) == entry_round - 1
      assert Enum.all?(player.games, &(&1.result == "Z" and &1.opponent_rank == nil))
      assert player.points == 0.0
    end

    test "PAIRING_FUZZ_LATE_BYE_TYPE=H backfills half-point byes instead" do
      System.put_env("PAIRING_FUZZ_LATE_BYE_TYPE", "H")
      {_rounds, _count, _forbidden, roster} = begin!(4, 9, 12..12)
      late = late_entrant_map()
      {rank, entry_round} = Enum.min_by(late, fn {_r, e} -> e end)

      final =
        Enum.reduce(1..entry_round, roster, fn round, players ->
          {active, pending} = reveal_late_entrants(players, round)
          active ++ pending
        end)

      player = Enum.find(final, &(&1.rank == rank))
      assert Enum.all?(player.games, &(&1.result == "H"))
      assert player.points == (entry_round - 1) * 0.5
    end
  end

  describe "the generated TRF round-trips through Ainalrami's own reader" do
    test "a backfilled late entrant survives serialize/parse with Z rounds intact" do
      System.put_env("PAIRING_FUZZ_LATE_PCT", "100")
      {rounds, _count, forbidden, roster} = begin!(5, 9, 10..10)
      late = late_entrant_map()
      {rank, entry_round} = Enum.min_by(late, fn {_r, e} -> e end)

      revealed =
        Enum.reduce(1..entry_round, roster, fn round, players ->
          {active, pending} = reveal_late_entrants(players, round)
          active ++ pending
        end)

      trf = build_trf(revealed, rounds, forbidden)
      parsed = Ainalrami.Trf.parse(trf)

      player = Enum.find(parsed.players, &(&1.rank == rank))
      recorded = Enum.take(player.games, entry_round - 1)

      assert length(recorded) == entry_round - 1
      assert Enum.all?(recorded, &(&1.result == "Z"))
      assert_in_delta player.points, 0.0, 1.0e-9
    end
  end
end
