defmodule Ainalrami.RuleDeltaTest do
  @moduledoc """
  The eight positions where the 2022 and 2026 Dutch rulebooks actually
  disagree, pinned as fixtures.

  They were found by running JaVaFo 2.2 (2022 rules) against bbpPairings
  6.0.0 and Gacrux 1.9.57 (both 2026) over 324 rounds and keeping every
  round where the two 2026 engines agreed with each other and JaVaFo
  differed. That filter is what makes them valuable: bbpPairings and
  Gacrux are independent implementations and agree on 100% of those 324
  rounds, so a round where they agree and JaVaFo does not is the rule
  change itself showing through, not one engine's quirk.

  Both answers are frozen into `manifest.exs`, so this runs in the DEFAULT
  suite: unlike the javafo/bbppairings/gacrux comparison harnesses it needs
  no JVM, no .exe and no Python, and it takes milliseconds. It is tagged
  `:rule_delta` only so it can be run alone (`mix test --only rule_delta`)
  when working on a criterion.

  ## The ratchet

  This engine targets the 2026 rulebook (see `docs/fide-criteria.md`), so
  every fixture should eventually pair the 2026 way. It does not yet:
  `@matches_2026_floor` records how many currently do, and the test fails
  if that number drops. Raise the floor whenever a criterion lands — the
  point is that progress is recorded and regressions are caught, not that
  the target is already met.

  History of the floor, so the trend is legible:

    * 2 of 8 — after C5 (the PAB Criterion) was enforced absolutely. C5
      alone fixed fixture 2, a 5-player round-2 case where the bye had to
      move from a 0.5 player to a 0.0 one.

  Of the six that still pair the 2022 way, four (fixtures 1, 4, 6, 7)
  share a shape: the 2026 answer keeps adjacent top seeds together
  ([1,2] or [2,3]) where JaVaFo splits them across the field. Pairing the
  top two changes WHICH players downfloat, which is what C8 governs — so
  they are the natural test of C8 once it stops being approximated.
  """
  use ExUnit.Case, async: true

  @moduletag :rule_delta

  @fixture_dir "test/fixtures/rule_delta"

  # Raise this as criteria land. Never lower it to make a change pass.
  @matches_2026_floor 2

  setup_all do
    manifest =
      @fixture_dir
      |> Path.join("manifest.exs")
      |> File.read!()
      |> Code.eval_string()
      |> elem(0)

    {:ok, manifest: manifest}
  end

  test "pairs the 2026 way on at least the fixtures already retargeted", %{manifest: manifest} do
    results =
      Enum.map(manifest, fn entry ->
        trf = File.read!(Path.join(@fixture_dir, entry.file))
        %{players: players} = Ainalrami.Trf.parse(trf)

        actual =
          players
          |> Ainalrami.Pairing.pair_next_round(expected_rounds: expected_rounds(trf))
          |> normalise()

        verdict =
          cond do
            actual == entry.rules_2026 -> :rules_2026
            actual == entry.rules_2022 -> :rules_2022
            true -> :neither
          end

        {entry.file, verdict}
      end)

    tally = results |> Enum.map(&elem(&1, 1)) |> Enum.frequencies()
    matched = Map.get(tally, :rules_2026, 0)

    detail =
      Enum.map_join(results, "\n", fn {file, verdict} -> "  #{file} — #{verdict}" end)

    assert matched >= @matches_2026_floor, """
    #{matched}/#{length(manifest)} fixtures pair the 2026 way, below the recorded floor of \
    #{@matches_2026_floor}.

    This engine targets the 2026 rulebook, so a drop here means a change moved it back \
    toward the superseded 2022 behaviour. See docs/fide-criteria.md.

    #{detail}
    """

    # Not an assertion — the run is the report.
    IO.puts(
      "\n  rule-delta fixtures: #{inspect(tally)} (floor #{@matches_2026_floor})\n#{detail}"
    )
  end

  # `parse/1` keeps the roster; the round count lives in the TRF's own XXR
  # line and `colour_compatible?/2`'s final-round exception needs it.
  defp expected_rounds(trf) do
    case Regex.run(~r/^XXR\s+(\d+)/m, trf) do
      [_, n] -> String.to_integer(n)
      nil -> nil
    end
  end

  defp normalise(pairs) do
    pairs |> Enum.map(fn {a, b} -> Enum.sort([a, b]) end) |> Enum.sort()
  end
end
