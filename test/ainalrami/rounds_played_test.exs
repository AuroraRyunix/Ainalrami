defmodule Ainalrami.RoundsPlayedTest do
  @moduledoc """
  Regression cover for the last of the illegal rounds left over from the
  100,000-tournament overnight run (`PAIRING_FUZZ_BYE_PCT=15` — see
  TODO.md, and `crash_reports/seed4385-r5-p4.trf`, the repro this fixture
  is copied from).

  `rounds_played/1` implemented only half of bbpPairings' rule. The half
  it had is real and still there: `playedRounds` only advances for games
  the player actually PARTICIPATED IN THE PAIRING for (`trf.cpp:339-342`),
  so one player's pre-recorded half-point bye doesn't drag the round
  number forward and strand everyone else.

  The missing half is `evenUpMatchHistories` (`trf.cpp:646-684`), which
  runs after parsing and can advance `playedRounds` once more. Pairing
  mode passes `includesUnpairedRound = true` (`main.cpp:452`, under
  `if (doPairings)`; the checker's own read at `main.cpp:347` passes
  false), which reduces its XOR to: increment exactly when EVERY player
  already carries a game for the trailing column. A column that is filled
  in for the whole field is a round that is already fully decided, so it
  counts as played and the round to pair is the one after it.

  This fixture is that case — all four players hold a round-5 bye
  (`Z`/`Z`/`Z`/`H`). Ainalrami used to compute `rounds_played` as 4, find
  nobody active for round 5 (every player's history is already longer
  than 4), and return `{:ok, []}` — no pairing at all, for a field with a
  perfectly legal one. Real bbpPairings on this same file pairs round 6
  and returns `4 1` / `2 3`, which is what this test asserts Ainalrami now
  produces too — not merely "returns something non-empty".

  Worth stating plainly because TODO.md recorded it the other way round:
  this case was filed as the ONE confirmed-genuine remaining bug, with
  four sibling cases dismissed as degenerate fuzz artifacts on the
  grounds that their whole field was pre-byed. That grouping was
  backwards — a fully pre-byed field is precisely the input this rule
  exists to handle, bbpPairings handles it deterministically, and all
  five were the same missing rule.

  The `every`-not-`any` distinction is what keeps this safe, and the
  second test pins it: one player holding a pre-recorded bye for the next
  round must NOT advance the count, or the ordinary arbiter-bye case
  would skip the round everyone else is waiting to play.
  """

  use ExUnit.Case, async: true

  alias Ainalrami.Pairing

  @fixture "test/fixtures/rounds_played/trailing-round-complete.trf"

  test "a trailing round every player already holds a bye for counts as played" do
    %{players: players} = Ainalrami.Trf.parse(File.read!(@fixture))

    pairs = Pairing.pair_next_round(players, expected_rounds: 9, quiet: true)

    assert Enum.sort(pairs) == [{2, 3}, {4, 1}],
           "should pair the round after the fully-byed one, matching real " <>
             "bbpPairings on this input (`4 1` / `2 3`)"
  end

  test "one player's pre-recorded bye does not advance the round for everyone else" do
    # Four players, round 1 played (1 beat 2, 3 beat 4). Only rank 4
    # holds a pre-recorded half-point bye for round 2 — the ordinary
    # "arbiter grants one player a bye" case. Ranks 1-3 are still owed
    # round 2, so the count must stay at 1 and pair them, leaving rank 4
    # out. Built as plain structs rather than fixed-column TRF text
    # because that's all `pair_next_round/2` consumes, and it keeps what
    # the case actually IS readable.
    #
    # Deliberately no `U` anywhere in this history: an earlier draft of
    # this test reused the main fixture's players, where rank 1 already
    # held a pairing-allocated bye and so was barred from taking a second
    # one (C2) — with the only legal pair among the three being {2,3},
    # that position is genuinely unpairable, and the engine was right to
    # refuse it. The bug being pinned here is about the ROUND NUMBER, so
    # the position has to be otherwise pairable for the assertion to mean
    # anything.
    players = [
      player(1, 1.0, [game("1", "w", 2)]),
      player(2, 0.0, [game("0", "b", 1)]),
      player(3, 1.0, [game("1", "w", 4)]),
      player(4, 0.5, [game("0", "b", 3), bye("H")])
    ]

    pairs = Pairing.pair_next_round(players, expected_rounds: 9, quiet: true)

    seated = Enum.flat_map(pairs, fn {w, b} -> if b, do: [w, b], else: [w] end)

    assert 4 not in seated,
           "the player holding a pre-recorded round-2 bye must not be paired into round 2"

    assert Enum.sort(seated) == [1, 2, 3],
           "the other three are still owed round 2 and must be paired (one taking the bye)"
  end

  defp player(rank, points, games) do
    %{
      name: "P#{rank}",
      title: "",
      federation: "",
      sex: "",
      fide_rating: 2000 - rank * 100,
      fide_number: nil,
      birth_date: "",
      points: points,
      rank: rank,
      games: games
    }
  end

  defp game(result, colour, opponent_rank),
    do: %{result: result, colour: colour, opponent_rank: opponent_rank}

  defp bye(result), do: %{result: result, colour: nil, opponent_rank: nil}
end
