defmodule Ainalrami.TeamProofLargeTest do
  @moduledoc """
  C.04.6 whole rounds on fields of 11-80 teams, against an EXACT reference.

  `Ainalrami.TeamProof.ExactReference` computes the naive reference's
  definition (`Ainalrami.TeamProof.NaiveReference`, feasible to ~10 teams)
  with minimum-cost perfect matchings instead of enumeration, sharing no code
  with the engine. Method and results: `docs/team-proof-large-fields.md`.

  Two steps, in order:

    1. the exact reference agrees with the naive one on every round the
       whole-round generator plays at 4-10 teams - what makes it a
       reference rather than a second opinion;
    2. the engine agrees with the exact reference on played events of 11-80
       teams: bye, pairs, colours and the recorded reasons.

  ## Scale mode

  Step 2 is also the long run's large-field axis:

      TEAM_PROOF_SEEDS="1..500" mix test test/ainalrami/team_proof_large_test.exs --only whole_rounds_large

  prints `TEAMPROOF seeds=N rounds=M` and keeps no per-round statistics.
  A failure message starts with the seed (`seed N,`), as the whole-round
  runner expects. `TEAM_PROOF_SIZES="20,40"` restricts the field sizes drawn
  and `TEAM_PROOF_TIMINGS=1` prints rounds and reference time per ten-team
  band (outside scale mode); `TEAM_PROOF_ENGINE_MAX_CANDIDATES` passes the
  engine a 3.6 candidate budget, which it has ignored since its 3.6 became
  exact (2026-09-25). Step 1's seeds are `TEAM_PROOF_NAIVE_SEEDS`
  (default 1..300) and its sizes `TEAM_PROOF_NAIVE_SIZES` (default 4..10).
  """
  use ExUnit.Case, async: true

  import Ainalrami.TeamProof.Events

  alias Ainalrami.TeamPairing
  alias Ainalrami.TeamProof.{ExactReference, NaiveReference}

  describe "the exact reference is the naive reference (4-10 teams)" do
    @tag timeout: :infinity
    test "every generated round, reasons included" do
      seeds = range_env("TEAM_PROOF_NAIVE_SEEDS", 1..300)
      # 4..10 is the whole-round test's own range (and with it the same
      # events, seed for seed). TEAM_PROOF_NAIVE_SIZES="11..12" pushes the
      # naive reference as far as it will go, for a one-off run.
      naive_sizes = range_env("TEAM_PROOF_NAIVE_SIZES", 4..10)

      checked =
        for seed <- seeds, reduce: 0 do
          acc ->
            # The whole-round test's generator, seed for seed.
            :rand.seed(:exsss, {seed, 2 * seed + 1, 7 * seed + 3})
            size = Enum.random(naive_sizes)
            rounds = Enum.random(3..6)
            initial = Enum.random([:white, :black])

            acc +
              play_event(size, rounds, initial, fn round_no, field, absent, opts ->
                args = [absent: absent, initial: initial, opts: opts]
                naive = NaiveReference.ref_round(field, args)
                exact = ExactReference.round(field, args)

                assert exact == naive, """
                seed #{seed}, round #{round_no}, #{length(field)} teams
                  exact: #{inspect(exact)}
                  naive: #{inspect(naive)}
                  field: #{inspect(Enum.map(field, &describe_team/1))}
                """

                # Advance the event with the engine, as the whole-round test does.
                case TeamPairing.pair_round(field, opts) do
                  {:ok, round} -> round
                  {:error, _} -> :stop
                end
              end)
        end

      assert checked > Enum.count(seeds) * 3

      if System.get_env("TEAM_PROOF_NAIVE_SEEDS"),
        do: IO.puts("TEAMPROOF naive agreement: seeds=#{Enum.count(seeds)} rounds=#{checked}")
    end
  end

  describe "the engine against the exact reference (11-80 teams)" do
    @tag :whole_rounds_large
    @tag timeout: :infinity
    test "every round of every generated event matches the exact reference" do
      {seeds, run?} =
        case System.get_env("TEAM_PROOF_SEEDS") do
          nil -> {1..12, false}
          _ -> {range_env("TEAM_PROOF_SEEDS", nil), true}
        end

      # TEAM_PROOF_ENGINE_MAX_CANDIDATES passes the engine a 3.6 candidate
      # budget. It looked past the old budget disagreement; since 2026-09-25
      # the engine's 3.6 is exact and ignores it.
      engine_opts =
        case System.get_env("TEAM_PROOF_ENGINE_MAX_CANDIDATES") do
          nil -> []
          n -> [max_candidates: String.to_integer(n), max_steps: 1_000_000_000]
        end

      sizes =
        case System.get_env("TEAM_PROOF_SIZES") do
          nil -> Enum.to_list(11..80)
          list -> list |> String.split(",") |> Enum.map(&String.to_integer(String.trim(&1)))
        end

      checked =
        for seed <- seeds, reduce: 0 do
          acc ->
            :rand.seed(:exsss, {seed, 3 * seed + 11, 5 * seed + 17})
            size = Enum.random(sizes)
            rounds = Enum.random(3..9)
            initial = Enum.random([:white, :black])

            acc +
              play_event(size, rounds, initial, fn round_no, field, absent, opts ->
                where =
                  "seed #{seed}, round #{round_no}, #{length(field)} teams, absent #{inspect(absent)}"

                {micros, reference} =
                  :timer.tc(fn ->
                    ExactReference.round(field, absent: absent, initial: initial, opts: opts)
                  end)

                run? || send(self(), {:timing, length(field), micros})

                {engine_micros, engine_result} =
                  :timer.tc(fn ->
                    TeamPairing.pair_round(field, [explain: true] ++ opts ++ engine_opts)
                  end)

                run? || send(self(), {:engine_timing, length(field), engine_micros})

                case engine_result do
                  {:ok, explained} ->
                    engine = Map.delete(explained, :explanation)

                    # The engine says so when a bracket's 3.6 search was cut
                    # short. Since 2026-09-25 it never is (3.6 is exact); the
                    # check stays so a regression names itself.
                    where =
                      case Enum.reject(engine.brackets, & &1.exhaustive?) do
                        [] ->
                          where

                        cut ->
                          "#{where}, engine 3.6 search NOT exhaustive (candidate budget) in the #{Enum.map_join(cut, ", ", & &1.score)}-point bracket"
                      end

                    assert reference != :impossible,
                           "#{where}: the engine paired a round the reference calls impossible"

                    assert normalise(engine) == Map.take(reference, [:bye, :pairs]),
                           """
                           #{where}
                             engine:    #{inspect(normalise(engine))}
                             reference: #{inspect(Map.take(reference, [:bye, :pairs]))}
                             field:     #{inspect(Enum.map(field, &describe_team/1))}
                           """

                    assert reasons(explained.explanation) == reference.reasons,
                           """
                           #{where}: the recorded reasons are not the reference's
                             engine:    #{inspect(reasons(explained.explanation))}
                             reference: #{inspect(reference.reasons)}
                             field:     #{inspect(Enum.map(field, &describe_team/1))}
                           """

                    engine

                  {:error, reason} ->
                    assert reference == :impossible,
                           "#{where}: engine refused (#{inspect(reason)}) but the reference paired it"

                    :stop
                end
              end)
        end

      if run? do
        IO.puts("TEAMPROOF seeds=#{Enum.count(seeds)} rounds=#{checked}")
      else
        assert checked > 40
        if System.get_env("TEAM_PROOF_TIMINGS"), do: report_timings()
      end
    end
  end

  defp range_env(name, default) do
    case System.get_env(name) do
      nil ->
        default

      range ->
        [first, last] = range |> String.split("..") |> Enum.map(&String.to_integer/1)
        first..last
    end
  end

  # Outside scale mode: rounds and mean reference and engine time per
  # ten-team band (the engine timed with `explain: true`).
  defp report_timings do
    {timings, engine} = collect({[], []})
    engine = Enum.group_by(engine, fn {size, _} -> div(size, 10) * 10 end, fn {_, us} -> us end)

    timings
    |> Enum.group_by(fn {size, _} -> div(size, 10) * 10 end, fn {_, us} -> us end)
    |> Enum.sort()
    |> Enum.each(fn {band, us} ->
      IO.puts(
        "TEAMPROOF band #{band}-#{band + 9}: #{length(us)} rounds, " <>
          "reference mean #{div(Enum.sum(us), length(us) * 1000)} ms, max #{div(Enum.max(us), 1000)} ms; " <>
          engine_line(Map.get(engine, band, []))
      )
    end)
  end

  defp engine_line([]), do: "engine -"

  defp engine_line(us),
    do:
      "engine mean #{div(Enum.sum(us), length(us) * 1000)} ms, max #{div(Enum.max(us), 1000)} ms"

  defp collect({ref, engine}) do
    receive do
      {:timing, size, us} -> collect({[{size, us} | ref], engine})
      {:engine_timing, size, us} -> collect({ref, [{size, us} | engine]})
    after
      0 -> {ref, engine}
    end
  end
end
