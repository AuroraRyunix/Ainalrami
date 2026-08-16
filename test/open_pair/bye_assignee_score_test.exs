defmodule OpenPair.ByeAssigneeScoreTest do
  @moduledoc """
  Regression cover for a crash found by a 100,000-tournament overnight
  run (`PAIRING_FUZZ_BYE_PCT=15` — see TODO.md's account, and
  `crash_reports/seed4886-r5-p5.trf`, the original repro this fixture is
  copied from).

  `bye_assignee_score/2`'s bootstrap matching built its edge list over
  `0..(n - 2)`, where `n` is how many players are still candidates for
  the round's pairing-allocated bye. That's fine when `n >= 2`, but this
  fixture is the case where exactly ONE candidate is left (everyone else
  in the round already resolved elsewhere) — `n == 1` makes the range
  `0..-1`, and Elixir's default step for a descending range walks
  `0, -1`: `elem(arr, -1)` is an invalid tuple index, so the whole round
  raised `ArgumentError` instead of pairing. Confirmed with real
  bbpPairings on the same input: it pairs this round fine and assigns
  the bye to rank 3, which is what this test asserts OpenPair also does
  now — not just "doesn't crash".

  102 illegal rounds (0.012%) turned up in that overnight run's larger
  839,776-round sample; 95 were this exact crash. Every smaller sample
  ever run against this engine (up to ~5,500 rounds) had shown zero
  illegal rounds, which is the reason this fixture exists as an explicit
  regression test rather than trusting the fuzz harness to hit it again
  — at a roughly 1-in-8,800-round rate, relying on a fresh random sample
  to keep catching it would be exactly the kind of luck this project's
  own history warns against.
  """

  use ExUnit.Case, async: true

  alias OpenPair.Pairing

  @fixture "test/fixtures/bye_assignee_score/one-candidate-left.trf"

  test "a round where exactly one player is left needing the bye does not crash" do
    %{players: players} = OpenPair.Trf.parse(File.read!(@fixture))

    pairs = Pairing.pair_next_round(players, expected_rounds: 9)

    assert {3, nil} in pairs, "rank 3 should get the bye, matching real bbpPairings on this input"

    active = Enum.filter(players, &(length(&1.games) < 5))
    seated = Enum.flat_map(pairs, fn {w, b} -> if b, do: [w, b], else: [w] end)

    assert Enum.sort(seated) == Enum.sort(Enum.map(active, & &1.rank)),
           "every active player must be seated exactly once"
  end

  @c9_fixture "test/fixtures/bye_assignee_score/top-score-group-tiebreak.trf"

  # The same bootstrap matching, but for the OTHER thing it produces:
  # `isSingleDownfloaterTheByeAssignee`, the C9 gate for the FIRST bracket
  # (dutch.cpp:851-870). See `bye_assignee_score_from_field/2`'s `tie_unit`
  # comment for the missing third field this covers.
  #
  # Copied from `/root/triage/seed940641-r4-p5.trf`, one of the 40 residual
  # disagreements catalogued in TODO.md. Five players, round 4, score
  # groups 2.0 = {3,4,5}, 1.5 = {1}, 1.0 = {2}. The bootstrap matching has
  # a genuine three-way tie on eligibility and score — leaving out 4 or 5
  # scores identically, and `{1-5, 2-3}` ties them both — and only the
  # top-score-group field separates them. Without it the matcher happened
  # to return `{1-5, 2-3}`, whose top-group player 3 is tentatively matched
  # BELOW the top group, so the gate scan cleared the flag and C9 was dead
  # for the whole first bracket. bbpPairings and Gacrux both bye rank 4,
  # who has played all three rounds, over rank 5, who sat out round 1 —
  # which is C9 exactly.
  test "the C9 gate survives a tie in the bootstrap matching" do
    %{players: players} = OpenPair.Trf.parse(File.read!(@c9_fixture))

    pairs = Pairing.pair_next_round(players, expected_rounds: 9)

    assert {4, nil} in pairs,
           "rank 4 has no unplayed games and rank 5 has one, so C9 puts the bye on 4 — " <>
             "the answer real bbpPairings and Gacrux both give"

    assert Enum.sort(Enum.map(pairs, fn {w, b} -> {min(w, b || w), b && max(w, b)} end)) ==
             [{1, 2}, {3, 5}, {4, nil}]
  end
end
