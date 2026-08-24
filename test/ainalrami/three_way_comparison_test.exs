defmodule Ainalrami.ThreeWayComparisonTest do
  @moduledoc """
  Asks all three engines the same question, every round.

  ## Why this exists

  This project has been steering by agreement with bbpPairings, on the
  strength of one earlier measurement: bbpPairings and Gacrux agreed with
  each other on **324 comparable rounds, zero disagreements**. That was
  used to justify treating either as ground truth.

  324 rounds with zero disagreements does not establish that. Zero
  observed failures in n trials bounds the true rate at roughly `3/n` with
  95% confidence - here about **0.9%**. So the references could disagree
  with each other on nearly one round in a hundred and that measurement
  would very likely still have come back clean.

  That mattered little when this engine was at 90% of exact rounds: the
  error being measured was ten times larger than the uncertainty in the
  ruler. It matters now. At 100% over 2.5 billion pairings, "ainalrami is
  wrong" and "the reference is wrong" are not distinguishable by a two-way
  comparison at all, and the precision of every headline number in
  `docs/validation.md` is really the precision of this measurement.

  So this runs all three, at whatever scale is asked for, and reports the
  pairwise rates plus the three-way split. Two things come out of it: a
  tight bound on how far the references actually agree, and - for the
  rounds where this engine differs - whether the other two agree with each
  other (this engine is wrong) or disagree (nobody's ground truth).

  ## It generates what the two-way harness generates

  Until 2026-08-24 it did not, and that was the flaw worth fixing before
  running it at scale. This harness had its own generator producing plain
  tournaments: uniform ratings, no byes, no forfeits, a fixed round count.
  The two-way harness had long since moved on to byes, forfeits,
  acceleration, withdrawals, five rating shapes and a variable round count.

  Bounding the references' agreement on plain tournaments would have been
  close to worthless, because **both known disputes in 2.5 billion pairings
  are about byes** - the one construct the old generator never produced. A
  ruler verified only where nobody doubted it is not a verified ruler.

  Both harnesses now generate through `Ainalrami.Test.FuzzTournament`, so
  an axis added for one is available to the other.

  ## Two axes Gacrux cannot take, and why they are refused rather than run

  `PAIRING_FUZZ_FORBIDDEN_PCT` and `PAIRING_FUZZ_NUMERIC_EXT` raise here
  instead of being quietly ignored.

  Gacrux has **no forbidden-pairs concept at all** - no `XXP`, no `260`,
  nothing in `trf2json.py` that reads one - and it does not read `250`
  either. Handing it a file with those lines does not fail; it produces a
  perfectly good pairing of a tournament with different rules, and every
  round where the constraint bit would be recorded as a three-way
  disagreement. That reads exactly like the references contradicting each
  other, which is the one thing this harness exists to measure, so a silent
  skip here would corrupt the only number it produces.

  Acceleration IS passed through: Gacrux parses `XXA`. If a run shows
  disagreement concentrated on accelerated tournaments, suspect the reader
  before the rules.

  ## Cost

  Gacrux is a Python script, ~750ms per round against bbpPairings' ~21ms,
  so this is roughly 35x the cost of the two-way harness and is excluded
  from the default suite. It parallelises cleanly - 36 cores put it at
  ~25 rounds/s at 4-40 players.

      PAIRING_FUZZ_COUNT=200 PAIRING_FUZZ_ROUNDS=9 mix test --only three_way

  Same tunables as the other harnesses, minus the two above.
  """

  use ExUnit.Case
  alias Ainalrami.{Pairing, Test.Bbppairings, Test.Gacrux}

  import Ainalrami.Test.FuzzTournament

  @moduletag :three_way
  @moduletag timeout: :infinity

  test "bbpPairings, Gacrux and Ainalrami on identical positions" do
    refuse_unsupported_axes!()

    count = env_int("PAIRING_FUZZ_COUNT", 20)
    rounds = env_int("PAIRING_FUZZ_ROUNDS", 5)
    players = env_int("PAIRING_FUZZ_MIN_PLAYERS", 4)..env_int("PAIRING_FUZZ_MAX_PLAYERS", 40)
    seed_from = env_int("PAIRING_FUZZ_SEED_FROM", 1)

    rows =
      seed_from..(seed_from + count - 1)
      |> Task.async_stream(&run_tournament(&1, rounds, players),
        max_concurrency: System.schedulers_online(),
        timeout: :infinity,
        ordered: false
      )
      |> Enum.flat_map(fn {:ok, r} -> r end)

    {errors, rest} = Enum.split_with(rows, &(&1.kind == :error))
    {splits, compared} = Enum.split_with(rest, &(&1.kind == :exhaustion_split))

    report(compared, splits, errors)
    dump(compared, splits)

    assert errors == [], """
    #{length(errors)} round(s) where a reference engine failed to run at all.

    This is not a pairing result and none of the rates above include it. The
    usual cause is the environment rather than the tournament: Gacrux needs
    `networkx`, and GACRUX_PYTHON must point at the interpreter that has it.
    A run reporting these is measuring its own setup, so it fails here rather
    than quoting a bound derived from whatever survived.

    #{Enum.map_join(Enum.take(errors, 3), "

", &format_error/1)}
    """

    assert compared != [], "no comparable rounds were produced"
  end

  # The measurement is only meaningful on files all three engines read the
  # same way. See the moduledoc - this is a wrong-answer guard, not a
  # capability check.
  defp refuse_unsupported_axes! do
    forbidden = env_int("PAIRING_FUZZ_FORBIDDEN_PCT", 0)
    numeric = System.get_env("PAIRING_FUZZ_NUMERIC_EXT")

    if forbidden != 0 do
      raise """
      PAIRING_FUZZ_FORBIDDEN_PCT=#{forbidden} cannot be measured three-way.

      Gacrux implements no forbidden-pairs concept, so it would pair a
      DIFFERENT tournament and every constrained round would be counted as
      the two references contradicting each other. Run this axis two-way.
      """
    end

    if numeric not in [nil, "0", "false"] do
      raise """
      PAIRING_FUZZ_NUMERIC_EXT=#{numeric} cannot be measured three-way.

      `250`/`260` are bbpPairings' own fixed-column extension lines. Gacrux
      reads neither, so acceleration written that way would reach it as an
      unaccelerated tournament. Run this axis two-way.
      """
    end
  end

  defp run_tournament(seed, rounds, player_range) do
    {rounds, player_count, forbidden, roster} = begin!(seed, rounds, player_range)

    {rows, _} =
      Enum.reduce_while(1..rounds, {[], roster}, fn round, {acc, ps} ->
        withdraw_some(round, player_count)
        ps = assign_requested_byes(ps)
        trf = build_trf(ps, rounds, forbidden)

        base = %{seed: seed, round: round, player_count: player_count, trf: trf}

        # Both are asked before anything is decided, because WHICH of them
        # refuses is itself a measurement. An earlier version used a `with`
        # that treated every non-`{:ok, _}` the same and simply stopped the
        # tournament - so a Gacrux that could not start at all (a missing
        # `networkx` is enough) looked exactly like a field running out of
        # legal opponents, and the run would report a confident bound
        # computed from almost no rounds.
        case {Bbppairings.pair(trf), Gacrux.pair(trf)} do
          {{:ok, bbp}, {:ok, gac}} ->
            ours = safely_pair(ps, rounds, forbidden)

            row =
              Map.merge(base, %{
                kind: :compared,
                bbp: bbp,
                gac: gac,
                ours: ours,
                bbp_gac: same?(bbp, gac),
                ours_bbp: same?(ours, bbp),
                ours_gac: same?(ours, gac)
              })

            {:cont, {[row | acc], apply_round(ps, bbp, simulate_results(bbp))}}

          # One reference says the round has no legal pairing and the other
          # produced one. That is the two of them contradicting each other
          # about whether the position is pairable at all - the strongest
          # form of the disagreement this harness exists to find, and one no
          # two-way run against either engine could ever report.
          {{:no_valid_pairing, _}, {:ok, gac}} ->
            {:halt,
             {[Map.merge(base, %{kind: :exhaustion_split, refused: :bbp, gac: gac}) | acc], ps}}

          {{:ok, bbp}, {:no_valid_pairing, _}} ->
            {:halt,
             {[Map.merge(base, %{kind: :exhaustion_split, refused: :gacrux, bbp: bbp}) | acc], ps}}

          {{:no_valid_pairing, _}, {:no_valid_pairing, _}} ->
            {:halt, {acc, ps}}

          {bbp_result, gac_result} ->
            row =
              Map.merge(base, %{
                kind: :error,
                bbp: bbp_result,
                gac: gac_result
              })

            {:halt, {[row | acc], ps}}
        end
      end)

    Enum.reverse(rows)
  end

  defp safely_pair(players, rounds, forbidden) do
    Pairing.pair_next_round(players,
      expected_rounds: rounds,
      forbidden_pairs: forbidden,
      initial_colour: String.downcase(initial_colour()),
      # `nil` on every run that does not set the axis, which is what
      # `Pairing` already defaults to - so this changes nothing until a file
      # carries `BB*` lines saying otherwise.
      point_system: point_system()
    )
  rescue
    _ -> :raised
  end

  defp same?(:raised, _), do: false
  defp same?(_, :raised), do: false
  defp same?(a, b), do: normalize(a) == normalize(b)

  defp report(compared, splits, errors) do
    n = length(compared)
    pct = fn k -> "#{Float.round(k * 100 / max(n, 1), 4)}%" end

    bbp_gac = Enum.count(compared, & &1.bbp_gac)
    ours_bbp = Enum.count(compared, & &1.ours_bbp)
    ours_gac = Enum.count(compared, & &1.ours_gac)

    IO.puts("
three-way comparison over #{n} compared round(s):
")
    IO.puts("  bbpPairings vs Gacrux       #{bbp_gac}/#{n}  #{pct.(bbp_gac)}")
    IO.puts("  Ainalrami   vs bbpPairings  #{ours_bbp}/#{n}  #{pct.(ours_bbp)}")
    IO.puts("  Ainalrami   vs Gacrux       #{ours_gac}/#{n}  #{pct.(ours_gac)}")

    # The reason for running three: when this engine differs, is it
    # outvoted or is there simply no majority to be outvoted by?
    ours_differs = Enum.reject(compared, &(&1.ours_bbp and &1.ours_gac))

    outvoted = Enum.count(ours_differs, & &1.bbp_gac)
    no_majority = Enum.count(ours_differs, &(not &1.bbp_gac))

    IO.puts("
  of the #{length(ours_differs)} round(s) where Ainalrami differs from either:")
    IO.puts("    references agree, so Ainalrami is the odd one out    #{outvoted}")
    IO.puts("    references disagree too, so there is no ground truth #{no_majority}")

    # Counted apart from the rates: one engine refused the position entirely,
    # so there is no pairing to compare, but the two references have still
    # contradicted each other about whether it can be paired.
    if splits != [] do
      by_who = Enum.frequencies_by(splits, & &1.refused)

      IO.puts(
        "
  #{length(splits)} round(s) where one reference found NO legal pairing and " <>
          "the other paired it: bbpPairings refused #{Map.get(by_who, :bbp, 0)}, " <>
          "Gacrux refused #{Map.get(by_who, :gacrux, 0)}"
      )
    end

    if errors != [] do
      IO.puts("
  #{length(errors)} round(s) where a reference failed to run - see the failure below")
    end

    # Rule of three: zero observed failures in n trials bounds the true
    # rate at about 3/n with 95% confidence. The denominator is compared
    # rounds only, and an exhaustion split is an observed disagreement, so
    # it disqualifies the clean-bound branch.
    cond do
      n == 0 ->
        :ok

      bbp_gac == n and splits == [] ->
        IO.puts(
          "
  references never disagreed; that bounds their true disagreement " <>
            "rate at about #{Float.round(300 / n, 5)}% (95%), not at zero"
        )

      true ->
        IO.puts(
          "
  references disagreed on #{n - bbp_gac + length(splits)} round(s) - " <>
            "dumped for adjudication"
        )
    end

    IO.puts("")
  end

  # The rounds worth keeping are the ones where the REFERENCES differ from
  # each other. Those are the whole point: each is a case where the two
  # implementations this project calls ground truth cannot both be right,
  # and no two-way harness can ever surface one.
  defp dump(compared, splits) do
    case System.get_env("PAIRING_FUZZ_DUMP") do
      nil ->
        :ok

      dir ->
        disputes = Enum.reject(compared, & &1.bbp_gac)
        File.mkdir_p!(dir)

        # Capped, and the cap reports what it dropped - a directory listing
        # gets read as the finding, so it must not quietly be a sample.
        limit = env_int("PAIRING_FUZZ_DUMP_LIMIT", 200)
        {kept_disputes, dropped_disputes} = Enum.split(disputes, limit)
        {kept_splits, dropped_splits} = Enum.split(splits, limit)

        Enum.each(kept_disputes, &write_dispute(dir, &1))
        Enum.each(kept_splits, &write_split(dir, &1))

        total = length(kept_disputes) + length(kept_splits)
        dropped = length(dropped_disputes) + length(dropped_splits)

        if total > 0 do
          IO.puts("  #{total} reference dispute(s) written to #{dir}")
        end

        if dropped > 0 do
          IO.puts("  #{dropped} further dispute(s) NOT dumped (limit #{limit} per kind)")
        end
    end
  end

  defp write_dispute(dir, r) do
    base = Path.join(dir, "seed#{r.seed}_r#{r.round}_p#{r.player_count}")
    File.write!(base <> ".trf", r.trf)

    File.write!(base <> ".txt", """
    seed #{r.seed}, round #{r.round}, #{r.player_count} players

    bbpPairings: #{inspect(Enum.sort(r.bbp))}
    Gacrux:      #{inspect(Enum.sort(r.gac))}
    Ainalrami:   #{inspect(summarise(r.ours))}

    agreement: ainalrami/bbp #{r.ours_bbp}, ainalrami/gacrux #{r.ours_gac}
    """)
  end

  defp write_split(dir, r) do
    base = Path.join(dir, "split_seed#{r.seed}_r#{r.round}_p#{r.player_count}")
    File.write!(base <> ".trf", r.trf)
    paired = if r.refused == :bbp, do: r.gac, else: r.bbp

    File.write!(base <> ".txt", """
    seed #{r.seed}, round #{r.round}, #{r.player_count} players

    #{r.refused} found NO legal pairing for this position.
    The other reference paired it as: #{inspect(Enum.sort(paired))}

    One of the two is wrong about whether this round is pairable at all.
    """)
  end

  defp format_error(r) do
    """
    seed #{r.seed}, round #{r.round}, #{r.player_count} players
      bbpPairings: #{inspect(r.bbp)}
      Gacrux:      #{inspect(r.gac)}
    """
  end

  defp summarise(:raised), do: :raised
  defp summarise(pairs), do: Enum.sort(pairs)
end
