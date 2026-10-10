defmodule Ainalrami.TeamProofXlTest do
  @moduledoc """
  C.04.6 whole rounds on fields of 100-200 teams, in the shapes real team
  events have (`Ainalrami.TeamProof.LargeEvents`): the engine against the
  exact reference, and against a checker that does not share the reference's
  argument for 3.6 (`Ainalrami.TeamProof.RoundChecker`). What each proves,
  and the measurements: `docs/team-proof-large-fields.md`, "100-200 teams".

  Three steps:

    1. at 4-10 teams, on the SAME generator's shapes: the exact reference is
       the naive one, the checker accepts the naive round, and the checker
       rejects every other legal pairing of a bracket it is shown;
    2. a smoke event at 30-40 teams (the default suite);
    3. scale mode, the long run:

           TEAM_XL_SEEDS="1..20" mix test test/ainalrami/team_proof_xl_test.exs --only whole_rounds_xl

       prints one `TEAMXL seeds=N rounds=M failures=F ...` line. A
       disagreement does NOT fail the test in scale mode: the full
       reproducer (shape, field, options, engine round, reference round,
       checker verdict) is written to `TEAM_XL_FAILURES` (default
       `failures/`), a `TEAMXL-FAIL seed=N` line is printed, the event is
       abandoned and the next seed starts. `TEAM_XL_SIZES="100..200"` sets
       the sizes drawn, `TEAM_XL_CHECK_MAX` the largest bracket the checker
       takes (default 64), and `TEAM_XL_INJECT="seed:round"` corrupts one
       engine round on purpose, to exercise the failure path.
  """
  use ExUnit.Case, async: true

  import Ainalrami.TeamProof.Events, only: [normalise: 1, reasons: 1, describe_team: 1]

  alias Ainalrami.TeamPairing
  alias Ainalrami.TeamProof.{ExactReference, LargeEvents, NaiveReference, RoundChecker}

  describe "the large generator's shapes at 4-10 teams" do
    @tag timeout: :infinity
    test "exact = naive, the checker accepts it and rejects every other pairing shown" do
      seeds = range_env("TEAM_XL_NAIVE_SEEDS", 1..150)

      {rounds, rejected} =
        for seed <- seeds, reduce: {0, 0} do
          {rounds, rejected} ->
            shape = LargeEvents.shape(seed, 4..10)
            {:ok, counter} = Agent.start_link(fn -> 0 end)

            played =
              LargeEvents.play(shape, fn round_no, field, absent, opts ->
                args = [absent: absent, initial: shape.initial, opts: opts]
                naive = NaiveReference.ref_round(field, args)
                exact = ExactReference.round(field, args)
                where = "seed #{seed}, round #{round_no}, #{length(field)} teams"

                assert exact == naive, """
                #{where}
                  exact: #{inspect(exact)}
                  naive: #{inspect(naive)}
                  field: #{inspect(Enum.map(field, &describe_team/1))}
                """

                if naive != :impossible do
                  assert {:ok, _} = RoundChecker.check(field, naive, opts),
                         "#{where}: the checker refuses the naive round #{inspect(naive)}"

                  Agent.update(counter, &(&1 + assert_swaps_rejected(field, naive, opts, where)))
                end

                case TeamPairing.pair_round(field, opts) do
                  {:ok, round} -> round
                  {:error, _} -> :stop
                end
              end)

            tried = Agent.get(counter, & &1)
            Agent.stop(counter)
            {rounds + played, rejected + tried}
        end

      assert rounds > Enum.count(seeds) * 3
      # The checker has to have been shown wrong pairings, and said so.
      assert rejected > Enum.count(seeds)

      if System.get_env("TEAM_XL_NAIVE_SEEDS"),
        do:
          IO.puts(
            "TEAMXL naive: seeds=#{Enum.count(seeds)} rounds=#{rounds} swaps_rejected=#{rejected}"
          )
    end
  end

  describe "the engine against the exact reference and the checker" do
    @tag :whole_rounds_xl
    @tag timeout: :infinity
    test "every round of every generated event" do
      {seeds, sizes, run?} =
        case System.get_env("TEAM_XL_SEEDS") do
          nil -> {1..1, 30..40, false}
          _ -> {range_env("TEAM_XL_SEEDS", nil), range_env("TEAM_XL_SIZES", 100..200), true}
        end

      check_max = String.to_integer(System.get_env("TEAM_XL_CHECK_MAX", "64"))
      dir = System.get_env("TEAM_XL_FAILURES", "failures")

      # TEAM_XL_INJECT="seed:round" turns the first match of that round
      # around after the engine paired it - a wrong round on purpose, to
      # show the failure path (reproducer, counting, carrying on) works.
      inject =
        case System.get_env("TEAM_XL_INJECT") do
          nil -> nil
          text -> text |> String.split(":") |> Enum.map(&String.to_integer/1) |> List.to_tuple()
        end

      zero = %{
        rounds: 0,
        failures: 0,
        teams: 0,
        ref: 0,
        engine: 0,
        checker: 0,
        checked: 0,
        skipped: 0,
        byes: 0
      }

      total =
        for seed <- seeds, reduce: zero do
          acc ->
            shape = LargeEvents.shape(seed, sizes)
            {:ok, stats} = Agent.start_link(fn -> zero end)

            LargeEvents.play(shape, fn round_no, field, absent, opts ->
              result =
                try do
                  one_round(field, absent, shape, opts, check_max, inject == {seed, round_no})
                rescue
                  e ->
                    {:fail, "crashed: " <> Exception.format(:error, e, __STACKTRACE__), nil, nil}
                catch
                  kind, e ->
                    {:fail, "crashed: " <> Exception.format(kind, e, __STACKTRACE__), nil, nil}
                end

              case result do
                {:ok, engine, s} ->
                  Agent.update(
                    stats,
                    &merge(&1, Map.merge(s, %{rounds: 1, teams: length(field)}))
                  )

                  engine

                :impossible ->
                  :stop

                {:fail, text, engine, reference} ->
                  Agent.update(stats, &merge(&1, %{failures: 1}))

                  unless run? do
                    flunk("seed #{seed}, round #{round_no}, #{length(field)} teams: #{text}")
                  end

                  file =
                    reproducer(dir, shape, round_no, field, absent, opts, text, engine, reference)

                  IO.puts(
                    "TEAMXL-FAIL seed=#{seed} round=#{round_no} teams=#{length(field)} file=#{file}"
                  )

                  :stop
              end
            end)

            event = Agent.get(stats, & &1)
            Agent.stop(stats)
            merge(acc, event)
        end

      if run? do
        IO.puts(
          "TEAMXL seeds=#{Enum.count(seeds)} rounds=#{total.rounds} failures=#{total.failures} " <>
            "teams=#{total.teams} byes=#{total.byes} ref_ms=#{div(total.ref, 1000)} " <>
            "engine_ms=#{div(total.engine, 1000)} checker_ms=#{div(total.checker, 1000)} " <>
            "brackets_checked=#{total.checked} brackets_skipped=#{total.skipped}"
        )
      else
        assert total.rounds >= 5
      end
    end
  end

  # One round: the engine, the exact reference and the checker. Returns
  # `{:ok, engine_round, stats}`, `:impossible` (both say so) or
  # `{:fail, text, engine, reference}`.
  defp one_round(field, absent, shape, opts, check_max, tamper?) do
    {ref_us, reference} =
      :timer.tc(fn ->
        ExactReference.round(field, absent: absent, initial: shape.initial, opts: opts)
      end)

    {engine_us, engine_result} =
      :timer.tc(fn -> TeamPairing.pair_round(field, [explain: true] ++ opts) end)

    engine_result =
      case engine_result do
        {:ok, %{pairs: [first | more]} = round} when tamper? ->
          {:ok, %{round | pairs: [%{first | white: first.black, black: first.white} | more]}}

        other ->
          other
      end

    case engine_result do
      {:ok, explained} ->
        engine = Map.delete(explained, :explanation)
        plain = normalise(engine)

        {checker_us, verdict} =
          :timer.tc(fn -> RoundChecker.check(field, plain, opts, check_max) end)

        cond do
          reference == :impossible ->
            {:fail, "the engine paired a round the reference calls impossible", explained,
             reference}

          plain != Map.take(reference, [:bye, :pairs]) ->
            {:fail, "bye or pairs are not the reference's (checker: #{inspect(verdict)})",
             explained, reference}

          reasons(explained.explanation) != reference.reasons ->
            {:fail, "the recorded reasons are not the reference's", explained, reference}

          match?({:error, _}, verdict) ->
            {:fail,
             "the checker refuses a round engine and reference agree on: #{elem(verdict, 1)}",
             explained, reference}

          true ->
            {:ok, counts} = verdict

            {:ok, engine,
             Map.merge(counts, %{
               ref: ref_us,
               engine: engine_us,
               checker: checker_us,
               byes: if(engine.bye, do: 1, else: 0)
             })}
        end

      {:error, reason} ->
        if reference == :impossible,
          do: :impossible,
          else:
            {:fail, "the engine refused (#{inspect(reason)}) a round the reference paired",
             reason, reference}
    end
  end

  defp merge(a, b), do: Map.merge(a, b, fn _k, x, y -> x + y end)

  # Everything needed to replay the round without the generator: the field
  # as the engine was given it, the options, and both answers.
  defp reproducer(dir, shape, round_no, field, absent, opts, text, engine, reference) do
    File.mkdir_p!(dir)
    file = Path.join(dir, "seed_#{shape.seed}_round_#{round_no}.txt")

    show =
      &inspect(&1,
        limit: :infinity,
        printable_limit: :infinity,
        pretty: true,
        width: 120,
        charlists: :as_lists
      )

    File.write!(file, """
    C.04.6 large-field proof: disagreement
    seed #{shape.seed}, round #{round_no}, #{length(field)} teams
    what: #{text}

    replay: TEAM_XL_SEEDS="#{shape.seed}..#{shape.seed}" TEAM_XL_SIZES="#{System.get_env("TEAM_XL_SIZES", "100..200")}" \\
            mix test test/ainalrami/team_proof_xl_test.exs --only whole_rounds_xl

    ## shape
    #{show.(shape)}

    ## options (TeamPairing.pair_round(field, [explain: true] ++ options))
    #{show.(opts)}

    ## absent (arrived, not in this round's field)
    #{show.(absent)}

    ## field (the %Team{} structs the engine was given)
    #{show.(field)}

    ## engine output
    #{show.(engine)}

    ## reference output (ExactReference.round/2)
    #{show.(reference)}
    """)

    file
  end

  # Every other legal pairing of a bracket is either worse on {C8, C10} or
  # later in 3.6's order, so the checker must refuse it. Tries each two-pair
  # swap that keeps the brackets what they were (every new pair still holds
  # a resident of the scoregroup); returns how many it tried.
  defp assert_swaps_rejected(field, round, opts, where) do
    by_tpn = Map.new(field, &{&1.tpn, &1})
    met? = fn a, b -> a in by_tpn[b].opponents or b in by_tpn[a].opponents end
    score = fn t -> by_tpn[t].match_points end
    top = fn {a, b} -> max(score.(a), score.(b)) end

    swaps =
      for {p, i} <- Enum.with_index(round.pairs),
          {q, j} <- Enum.with_index(round.pairs),
          i < j,
          top.(p) == top.(q),
          {a, b} = p,
          {c, d} = q,
          [x, y] <- [[{a, c}, {b, d}], [{a, d}, {b, c}]],
          not met?.(elem(x, 0), elem(x, 1)) and not met?.(elem(y, 0), elem(y, 1)),
          top.(x) == top.(p) and top.(y) == top.(p),
          do: [x, y | round.pairs -- [p, q]]

    for pairs <- swaps do
      assert {:error, _} = RoundChecker.check(field, %{round | pairs: pairs}, opts),
             "#{where}: the checker accepts #{inspect(pairs)}, which is not the round #{inspect(round.pairs)}"
    end

    length(swaps)
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
end
