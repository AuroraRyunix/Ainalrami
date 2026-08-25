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

  ## Three axes Gacrux cannot take, and why they are refused rather than run

  `PAIRING_FUZZ_FORBIDDEN_PCT`, `PAIRING_FUZZ_NUMERIC_EXT` and
  `PAIRING_FUZZ_ACCEL` raise here instead of being quietly ignored.

  Gacrux has **no forbidden-pairs concept at all** - no `XXP`, no `260`,
  nothing in `trf2json.py` that reads one - and it does not read `250`
  either. Handing it a file with those lines does not fail; it produces a
  perfectly good pairing of a tournament with different rules, and every
  round where the constraint bit would be recorded as a three-way
  disagreement. That reads exactly like the references contradicting each
  other, which is the one thing this harness exists to measure, so a silent
  skip here would corrupt the only number it produces.

  **Acceleration is now the third, and it was added the hard way.** This
  moduledoc used to say acceleration was passed through because Gacrux
  parses `XXA`, and it ended with a prediction:

  > If a run shows disagreement concentrated on accelerated tournaments,
  > suspect the reader before the rules.

  It happened. The 2026-08-24 run put the accelerated axis at **42.23%**
  bbpPairings-vs-Gacrux over 98,323 rounds, against 100.00% on every axis
  without acceleration, and dragged the combined `everything` axis down to
  49.96%. It is not a rules disagreement. On
  `dumps/3way-everything/seed30700002_r1_p20.trf` - a round-1 position with
  Baku acceleration - bbpPairings and Ainalrami both pair inside the
  accelerated groups while Gacrux produces the textbook UNACCELERATED
  top-half-against-bottom-half pairing. Gacrux is pairing a different
  tournament, so the number measures its reader, not the rules, exactly as
  with `250`/`260`. Run this axis two-way.

  Note what the prediction bought: because it was written down before the
  run, the 42% was diagnosed in one position instead of being reported as
  the references contradicting each other on half of all accelerated rounds.

  ## A crashed reference is missing data, not a disagreement

  Gacrux reports failure INSIDE its output file with exit status 0, and
  `### Error 510` is its catch-all for "an exception escaped the checker".
  `Ainalrami.Test.Gacrux` used to map that to "no legal pairing", which is
  wrong, and this harness is where the wrongness showed: 203 of the 234
  exhaustion splits the 2026-08-24 run dumped were 510 crashes rather than
  Gacrux refusing a position - one single bug, `crosstabledutch.py:253`
  `KeyError: 'n'`, in every one of the 60 sampled.

  A `{:crashed, _}` round is now its own kind. It is counted, reported and
  dumped, and it is excluded from every rate, because a reference that fell
  over is evidence for neither side. The crash count is printed on its own
  line whether or not it is zero, so a future run cannot quietly turn
  crashes back into disagreements the way this one did.

  ## Cost

  Gacrux is a Python script, ~750ms per round against bbpPairings' ~21ms,
  so this is roughly 35x the cost of the two-way harness and is excluded
  from the default suite. It parallelises cleanly - 36 cores put it at
  ~25 rounds/s at 4-40 players.

      PAIRING_FUZZ_COUNT=200 PAIRING_FUZZ_ROUNDS=9 mix test --only three_way

  Same tunables as the other harnesses, minus the three above.
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
    {crashes, rest} = Enum.split_with(rest, &(&1.kind == :reference_crash))
    {splits, compared} = Enum.split_with(rest, &(&1.kind == :exhaustion_split))

    report(compared, splits, crashes, errors)
    dump(compared, splits, crashes)

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
    accel = System.get_env("PAIRING_FUZZ_ACCEL")

    if accel not in [nil, "", "0", "false"] do
      raise """
      PAIRING_FUZZ_ACCEL=#{accel} cannot be measured three-way.

      Gacrux parses `XXA` but does not ACT on it: on an accelerated round-1
      position it pairs top-half against bottom-half as though the
      acceleration were not there, while bbpPairings and Ainalrami both pair
      inside the accelerated groups. Measured 2026-08-24 at 42.23%
      bbpPairings-vs-Gacrux over 98,323 accelerated rounds, against 100.00%
      on every unaccelerated axis.

      Every one of those is Gacrux pairing a DIFFERENT tournament, not the
      references contradicting each other. Run this axis two-way.
      """
    end

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

          # Gacrux fell over. That is not a refusal and not a disagreement -
          # it is one missing answer - so the round is recorded as a crash,
          # left out of every rate, and the TOURNAMENT CONTINUES on
          # bbpPairings' pairing. Truncating here is what the old
          # no-valid-pairing reading did, and it silently biased the corpus
          # towards short tournaments: crashes need a last round, so every
          # one of them cut a tournament off at exactly the point the
          # topscorer rules start to matter.
          {{:ok, bbp}, {:crashed, detail}} ->
            row = Map.merge(base, %{kind: :reference_crash, who: :gacrux, detail: detail})
            {:cont, {[row | acc], apply_round(ps, bbp, simulate_results(bbp))}}

          # Nothing left to continue on, so this one does stop - but it is
          # still a crash rather than a split, because Gacrux never answered.
          {_, {:crashed, detail}} ->
            row = Map.merge(base, %{kind: :reference_crash, who: :gacrux, detail: detail})
            {:halt, {[row | acc], ps}}

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

  defp report(compared, splits, crashes, errors) do
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

    # PRINTED WHETHER OR NOT IT IS ZERO, and deliberately so. The 510
    # crashes spent a whole validation run disguised as exhaustion splits
    # because nothing ever counted them; a line that only appears when the
    # count is nonzero is a line a reader never learns to look for.
    crashed = length(crashes)
    attempted = n + length(splits) + crashed

    IO.puts(
      "
  Gacrux crashed on #{crashed}/#{attempted} attempted round(s)  " <>
        "#{Float.round(crashed * 100 / max(attempted, 1), 4)}% - " <>
        "excluded from every rate above, being neither a pairing nor a refusal"
    )

    crashes
    |> Enum.frequencies_by(& &1.detail)
    |> Enum.sort_by(fn {_detail, k} -> -k end)
    |> Enum.take(3)
    |> Enum.each(fn {detail, k} ->
      IO.puts("    #{k}x #{detail |> String.split(~r/\r?\n/) |> List.first()}")
    end)

    # The same shape as the two-way harness' resource-starvation warning:
    # past a few percent the surviving rounds are a filtered sample, and a
    # rate computed on them is not the rate that was asked for.
    if crashed > 0 and crashed * 100 / max(attempted, 1) > 5.0 do
      IO.puts(
        "    WARNING: that is over 5% of attempted rounds. The rates above are " <>
          "computed on the rounds Gacrux survived, which is not a random sample " <>
          "of positions - treat them as untrustworthy until the crash is understood."
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
  defp dump(compared, splits, crashes) do
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
        {kept_crashes, dropped_crashes} = Enum.split(crashes, limit)

        Enum.each(kept_disputes, &write_dispute(dir, &1))
        Enum.each(kept_splits, &write_split(dir, &1))
        Enum.each(kept_crashes, &write_crash(dir, &1))

        total = length(kept_disputes) + length(kept_splits) + length(kept_crashes)
        dropped = length(dropped_disputes) + length(dropped_splits) + length(dropped_crashes)

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

  defp write_crash(dir, r) do
    base = Path.join(dir, "crash_seed#{r.seed}_r#{r.round}_p#{r.player_count}")
    File.write!(base <> ".trf", r.trf)

    File.write!(base <> ".txt", """
    seed #{r.seed}, round #{r.round}, #{r.player_count} players

    #{r.who} raised inside the checker and wrote `### Error 510` to its own
    output file, exiting 0. It gave no answer for this position, so this
    round is in NO rate - it is not a refusal and not a disagreement.

    #{r.detail}

    Reproduce (`-v` makes it re-raise instead of swallowing):
      python3 $GACRUX_DIR/pairingchecker.py -i #{Path.basename(base)}.trf \\
        -o /tmp/out.txt -p -dT -m dutch -v
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
