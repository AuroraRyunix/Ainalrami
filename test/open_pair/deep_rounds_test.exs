defmodule OpenPair.DeepRoundsTest do
  @moduledoc """
  Regression cover for the one failure mode that only appears when a
  tournament is run far past a normal number of rounds: the engine
  REFUSING a round that has a perfectly legal pairing.

  Found by running the bbpPairings harness at 39 rounds instead of 9. The
  "illegal" column filled up — 142 of 2126 rounds — but nothing illegal
  was ever emitted. `illegality/3` reports a raised
  `NoValidPairingError` as `:raised` and the report counts it in the same
  column, so a refusal reads as an illegal pairing. Every one of those
  142 was a refusal, and bbpPairings paired all 142 legally (checked
  independently for rematches, repeat byes and C3 clashes).

  The cause was in `repair_completion/3`. It ranked cardinality above
  everything, which finds A maximum matching but not a particular one —
  and several maximum matchings normally exist, leaving different players
  unmatched. When the one it happened to return left a C2-ineligible
  player over, `check_completion/3` correctly rejected it, and the round
  was declared impossible. The absolute criteria that constrain WHO may
  be left over (C2 eligibility, C5's bye score) are now bands of their
  own, directly under cardinality, exactly as `bye_assignee_score/2`
  already phrased them.

  The fixture is the smallest of those 142 rounds, kept as a TRF so the
  regression is deterministic and needs no reference binary.
  """

  use ExUnit.Case, async: true

  alias OpenPair.Pairing

  @fixture "test/fixtures/deep_rounds/c2-ineligible-leftover.trf"

  defp active(players) do
    played = players |> Enum.map(&length(&1.games)) |> Enum.max(fn -> 0 end)
    Enum.filter(players, &(length(&1.games) >= played))
  end

  test "a round whose only completions strand an ineligible player is still paired" do
    %{players: players} = OpenPair.Trf.parse(File.read!(@fixture))

    pairs = Pairing.pair_next_round(players, expected_rounds: 39)

    by_rank = Map.new(players, &{&1.rank, &1})
    active = active(players)
    seated = Enum.flat_map(pairs, fn {w, b} -> if b, do: [w, b], else: [w] end)

    assert Enum.sort(seated) == Enum.sort(Enum.map(active, & &1.rank)),
           "every active player must be seated exactly once"

    assert Enum.count(pairs, fn {_w, b} -> is_nil(b) end) == rem(length(active), 2)

    for {w, b} <- pairs, b != nil do
      refute Enum.any?(
               Map.fetch!(by_rank, w).games,
               &(&1.result in ~w(1 = 0) and &1.opponent_rank == b)
             ),
             "C1: #{w} and #{b} have already played"
    end

    # C2 is the criterion the old code tripped over: the player left with
    # the bye must be one who is allowed to take it.
    for {w, nil} <- pairs do
      refute Enum.any?(Map.fetch!(by_rank, w).games, &(&1.result in ~w(U F + W))),
             "C2: #{w} has already had a pairing-allocated bye or an unplayed win"
    end
  end
end
