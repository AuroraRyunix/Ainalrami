# Scores both engines' answers with Ainalrami's own C1-C21 ladder and
# reports, per case, the first bracket where they differ and which rung
# decided it. See `Ainalrami.Pairing.explain_round/3`.
#
# Classifying a disagreement says WHAT differs; this says WHO IS RIGHT by
# our own rules, which is the part that tells you where to look:
#
#   * reference scores better - our search failed to reach a pairing our
#     own ladder prefers.
#   * we score better - the LADDER is wrong, since the reference would
#     not violate a criterion it implements.
#   * they tie - the criteria cannot separate them and something below
#     decides (FIDE section 3's transposition order).
#
# Get the dumps first, then adjudicate them:
#
#   PAIRING_FUZZ_DUMP=/tmp/dump PAIRING_FUZZ_COUNT=200 \
#     PAIRING_FUZZ_ROUNDS=9 mix test --only bbppairings
#   mix run tools/adjudicate.exs /tmp/dump
#
# Add AINALRAMI_GLOBAL=1 to both to adjudicate the global cascade instead
# (which is the path whose ladder this scorer actually shares). Set
# VERBOSE_STEM=seedN-rM-pP to dump one case rung by rung, and
# AINALRAMI_TRACE=1 with tools/trace_one.exs to watch a single case move
# through the eight refinement stages.

[dir | rest] = System.argv()

verbose =
  case rest do
    ["--verbose", stem] -> stem
    _ -> nil
  end

defmodule Adj do
  def parse_pairs(line) do
    Regex.scan(~r/\{(\d+), (\d+|nil)\}/, line)
    |> Enum.map(fn
      [_, w, "nil"] -> {String.to_integer(w), nil}
      [_, w, b] -> {String.to_integer(w), String.to_integer(b)}
    end)
  end

  # First bracket where the two reports differ, and the highest-priority
  # rung that differs inside it. `nil` when every bracket agrees.
  def first_difference(ours, theirs) do
    Enum.zip(ours, theirs)
    |> Enum.find_value(fn {o, t} ->
      cond do
        Enum.sort(o.pairs) != Enum.sort(t.pairs) or Enum.sort(o.floats) != Enum.sort(t.floats) ->
          # Rungs are sums over this bracket's edges, so they can only be
          # compared when both answers contribute the same NUMBER of edges.
          # Where they do not, every rung differs for that reason and none of
          # the differences are criterial -- reporting one as the deciding
          # criterion is how `seed735265-r7-p10` came to be filed under
          # "C2/C4/C5 bye-eligibility" by an accounting difference.
          rung =
            if Map.get(o, :edge_count) == Map.get(t, :edge_count) do
              Enum.zip(o.rungs, t.rungs)
              |> Enum.find(fn {{_l, ov}, {_l2, tv}} -> ov != tv end)
            else
              {{"incomparable: #{Map.get(o, :edge_count)} vs #{Map.get(t, :edge_count)} edges in this bracket",
                :incomparable}, {"", :incomparable}}
            end

          {:ok, o.group, rung, o, t}

        true ->
          nil
      end
    end)
  end
end

files = Path.wildcard(Path.join(dir, "*.txt")) |> Enum.sort()

results =
  Enum.map(files, fn path ->
    stem = Path.basename(path, ".txt")
    text = File.read!(path)
    trf = File.read!(Path.join(dir, stem <> ".trf"))

    ours = text |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "Ainalrami:")) |> Adj.parse_pairs()
    theirs = text |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "bbpPairings:")) |> Adj.parse_pairs()

    %{players: players} = Ainalrami.Trf.parse(trf)
    rounds = 9

    o = Ainalrami.Pairing.explain_round(players, ours, expected_rounds: rounds)
    t = Ainalrami.Pairing.explain_round(players, theirs, expected_rounds: rounds)

    # Self-test: the reconstruction must account for every pair exactly
    # once. If it does not, the per-bracket verdicts below describe a
    # bracket decomposition the engine never used, and are worthless.
    for {label, report, given} <- [{"ours", o, ours}, {"theirs", t, theirs}] do
      reconstructed = report |> Enum.map(&length(&1.pairs)) |> Enum.sum()
      actual = Enum.count(given, fn {_w, b} -> b != nil end)

      if reconstructed != actual do
        IO.puts(
          "  !! #{stem} #{label}: reconstruction has #{reconstructed} pairs, pairing has #{actual}"
        )
      end
    end

    verdict =
      case Adj.first_difference(o, t) do
        nil ->
          {:identical, nil, nil}

        {:ok, group, nil, ob, tb} ->
          # Different pairs, every criterion total identical: the ladder
          # cannot separate them, so FIDE section 3's transposition order
          # is what decides. Which of the two does that rule pick?
          who =
            cond do
              ob.lex == tb.lex -> "lex ALSO ties"
              ob.lex < tb.lex -> "lex picks OURS"
              true -> "lex picks THEIRS"
            end

          {:tie_on_all_rungs, group, who}

        {:ok, group, {{label, ov}, {_l, tv}}, _o, _t} ->
          cond do
            # The two answers put different numbers of edges in this
            # bracket's window, so every rung differs by that accounting and
            # none of it is criterial. Its own verdict, not folded into
            # "ours" -- which is where it landed at first, turning one
            # misreport into another.
            ov == :incomparable -> {:incomparable, group, label}
            tv > ov -> {:theirs_scores_better, group, label}
            true -> {:ours_scores_better, group, label}
          end
      end

    if stem == System.get_env("VERBOSE_STEM") do
      IO.puts("\n=== #{stem} ===")

      case Adj.first_difference(o, t) do
        {:ok, group, _rung, ob, tb} ->
          IO.puts("first differing bracket: score #{group}")
          IO.puts("  order     #{inspect(ob.order, charlists: :as_lists)}")
          IO.puts("  MDPs      #{inspect(ob.mdps, charlists: :as_lists)}   residents #{inspect(ob.residents, charlists: :as_lists)}")
          IO.puts("  ours   pairs #{inspect(ob.pairs, charlists: :as_lists)} floats #{inspect(ob.floats, charlists: :as_lists)} lex #{inspect(ob.lex, charlists: :as_lists)}")
          IO.puts("  theirs pairs #{inspect(tb.pairs, charlists: :as_lists)} floats #{inspect(tb.floats, charlists: :as_lists)} lex #{inspect(tb.lex, charlists: :as_lists)}")
          IO.puts("\n  #{String.pad_trailing("rung", 32)} ours  theirs")

          Enum.zip(ob.rungs, tb.rungs)
          |> Enum.each(fn {{label, ov}, {_l, tv}} ->
            flag = if ov != tv, do: "  <-- differs", else: ""

            IO.puts(
              "  #{String.pad_trailing(label, 32)}#{String.pad_leading(to_string(ov), 5)}#{String.pad_leading(to_string(tv), 8)}#{flag}"
            )
          end)

        _ ->
          IO.puts("no differing bracket found")
      end

      IO.puts("")
    end

    {stem, verdict}
  end)

IO.puts("\nadjudication of #{length(results)} disagreements:\n")

results
|> Enum.group_by(fn {_s, {v, _g, _l}} -> v end)
|> Enum.sort_by(fn {_k, v} -> -length(v) end)
|> Enum.each(fn {verdict, cases} ->
  pct = Float.round(length(cases) * 100 / length(results), 1)
  IO.puts("  #{String.pad_trailing(to_string(verdict), 24)} #{String.pad_leading(to_string(length(cases)), 4)}  #{pct}%")

  cases
  |> Enum.group_by(fn {_s, {_v, _g, l}} -> l end)
  |> Enum.sort_by(fn {_k, v} -> -length(v) end)
  |> Enum.each(fn {label, sub} ->
    IO.puts("      #{String.pad_trailing(to_string(label), 32)} #{String.pad_leading(to_string(length(sub)), 4)}")
    IO.puts("        e.g. #{sub |> Enum.take(4) |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")}")
  end)
end)

IO.puts("")

if verbose do
  IO.puts("(set VERBOSE_STEM=#{verbose} to dump that case)")
end
