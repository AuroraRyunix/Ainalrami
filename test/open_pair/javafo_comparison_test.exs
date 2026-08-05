defmodule OpenPair.JavafoComparisonTest do
  @moduledoc """
  Cross-checks `OpenPair.Pairing.pair_round_one/1` against the real
  `javafo.jar` (FIDE's own reference Dutch-system implementation) on many
  random synthetic rosters — same methodology as OpenPairings' own
  `cross_program_test.exs` (JaVaFo vs bbpPairings): diff who's actually
  paired with whom, not whether either engine calls its own output legal.

  Deliberately colour-blind (see `normalize/1`) — JaVaFo's own choice of
  the very first round's colour is not a function of the roster or round
  count alone (confirmed empirically: identical rosters under different
  tournament *names* produced opposite initial colours), so it can't be
  replicated without literally reverse-engineering JaVaFo's internal seed.
  `OpenPair.Pairing`'s own fixed colour convention is spec-legal but not
  expected to match JaVaFo's on every run — see that module's doc. Pairing
  *composition* is the thing under test here.

  Runs `PAIRING_FUZZ_COUNT` random rosters (default 20), player count
  uniform in 2..60, in parallel across all schedulers — each iteration
  spawns a real JVM (~0.2s), so a large count is meant to be run
  deliberately, not on every `mix test`:

      PAIRING_FUZZ_COUNT=100000 mix test --only javafo test/open_pair/javafo_comparison_test.exs
  """

  use ExUnit.Case
  alias OpenPair.{Pairing, Test.Javafo}

  @moduletag :javafo
  @moduletag timeout: :infinity

  test "OpenPair and javafo.jar agree on who plays whom in round 1, across many random rosters" do
    count = System.get_env("PAIRING_FUZZ_COUNT", "20") |> String.to_integer()

    results =
      1..count
      |> Task.async_stream(&run_one/1,
        max_concurrency: System.schedulers_online(),
        timeout: :infinity,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    disagreements = Enum.reject(results, &(&1.match? == true))

    match_count = count - length(disagreements)

    IO.puts(
      "\nJaVaFo round-1 comparison: #{match_count}/#{count} matched " <>
        "(#{Float.round(match_count / count * 100, 2)}%)"
    )

    assert disagreements == [], """
    #{length(disagreements)} disagreement(s) out of #{count} random roster(s) — a legal-but-\
    different pairing, not necessarily a bug (see this module's doc). Each needs its own look:

    #{Enum.map_join(Enum.take(disagreements, 20), "\n\n", &format_disagreement/1)}
    #{if length(disagreements) > 20, do: "\n... and #{length(disagreements) - 20} more, truncated.", else: ""}
    """
  end

  # A single tournament's transient failure (e.g. a flaky subprocess spawn)
  # must not take down the whole run — Task.async_stream propagates an
  # unhandled raise as an :exit that kills the entire stream by default, so
  # this reports the failure as its own "disagreement" instead of letting it
  # escape.
  defp run_one(seed) do
    run_one!(seed)
  rescue
    e -> %{seed: seed, player_count: nil, match?: false, openpair: nil, javafo: {:raised, e}}
  end

  defp run_one!(seed) do
    :rand.seed(:exsss, {seed, seed * 7919, seed * 104_729})
    player_count = Enum.random(2..60)
    round_count = Enum.random(1..10)

    players =
      for i <- 1..player_count do
        %{rank: i, name: "P#{i}", fide_rating: Enum.random(1000..2800), points: 0.0, games: []}
      end
      # Rating isn't necessarily rank-monotonic in a real tournament, but
      # round 1's own pairing rule (see Pairing.pair_round_one/1's doc)
      # only ever consults rank, not rating — so this needn't be sorted for
      # correctness. Left as generated (rank order == generation order,
      # ratings independently random) to also incidentally cover the
      # "ratings don't determine round-1 pairing, rank does" case.
      |> Enum.shuffle()
      |> Enum.with_index(1)
      |> Enum.map(fn {p, i} -> %{p | rank: i} end)

    trf = build_trf(players, round_count)

    openpair_pairs = Pairing.pair_round_one(players)

    case Javafo.pair(trf) do
      {:ok, javafo_pairs} ->
        %{
          seed: seed,
          player_count: player_count,
          match?: normalize(openpair_pairs) == normalize(javafo_pairs),
          openpair: Enum.sort(openpair_pairs),
          javafo: Enum.sort(javafo_pairs),
          trf: trf
        }

      {:error, {code, out}} ->
        %{
          seed: seed,
          player_count: player_count,
          match?: false,
          openpair: Enum.sort(openpair_pairs),
          javafo: {:error, code, out},
          trf: trf
        }
    end
  end

  defp build_trf(players, round_count) do
    OpenPair.Trf.serialize(%{
      tournament: %{name: "Fuzz", type: "swiss"},
      players: players
    }) <> "XXR #{round_count}\r\n"
  end

  # Colour/board-order is presentation, not the thing under test — sort
  # each pair's own two members (bye's `nil` sorts last) then the whole set.
  defp normalize(pairs) do
    pairs
    |> Enum.map(fn {a, b} -> Enum.sort_by([a, b], &(&1 || :infinity)) end)
    |> Enum.sort()
  end

  defp format_disagreement(d) do
    """
    seed #{d.seed}, #{d.player_count} players:
      OpenPair: #{inspect(d.openpair)}
      javafo:   #{inspect(d.javafo)}
    """
  end
end
