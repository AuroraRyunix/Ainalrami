defmodule Ainalrami.Alternatives do
  @moduledoc """
  Answers to "why not THAT instead" - the questions an arbiter is actually
  asked at the board, which `Ainalrami.Pairing.explain_round/3` on its own
  cannot answer because it describes one pairing and says nothing about the
  ones that were not chosen.

  Every answer here is built the same way: construct the alternative, score
  it with `explain_round/3` under the real rules, and compare it with what
  was played. That makes each verdict a fact about the criteria rather than
  a reconstruction of the search - the alternative either breaks an absolute
  rule (`violations/1` names the pair and why), or scores lower on a named
  rung (`compare/2` names it), or ties, in which case FIDE section 3's
  transposition order decided and the report says which way.

  Three questions, three shapes of alternative:

    * **A swap, or "pair X with Y".** The arbiter names the pairing they had
      in mind. It is a complete pairing, so it is scored directly -
      `judge/4`. Cheap, exact, and the one that runs live on a page.

    * **"Why did HE float and not me."** For each other member of the
      bracket, the best pairing in which THAT player leaves the bracket
      instead - obtained by forbidding them every partner inside it and
      pairing again - `float_alternatives/3`. One full search per candidate,
      so it is computed once when the round is paired and stored, and capped
      (see `@max_candidates`); a top bracket of a hundred players in round
      one is not where this question gets asked.

    * **"Why did HE get the bye and not me."** The same, forcing each
      candidate to be unpairable - `bye_alternatives/3` - after first asking
      C.2 whether the rule allowed them a bye at all.

  ## What "worse" means, and what it does not

  A candidate marked `:worse` on rung C14 lost to the actual pairing on the
  first criterion that separated them, in ladder order. That is the
  regulation's own notion of better - and it is exactly as strong as the
  ladder this engine implements. Where the two disagree with bbpPairings the
  verdict is the engine's, not FIDE's; the comparison corpus in
  `docs/engineering-log.md` is where that gap is measured.

  `:better` should never appear for an alternative of the engine's own
  pairing. If it does, the search missed a pairing its own ladder prefers,
  and that is a bug report, which is why it is reported rather than hidden.
  """

  alias Ainalrami.Pairing

  # Candidates per float or bye above which the search is skipped rather
  # than run. Twelve is a generous late-round bracket; round one's single
  # bracket of everyone is the case being excluded.
  @max_candidates 12

  @doc "The cap on candidates per question, for callers that want to say so."
  def max_candidates, do: @max_candidates

  @doc """
  The first bracket where two `explain_round/3` reports differ, and the
  first rung inside it that separates them.

  Ported from `tools/adjudicate.exs`, which used this rule to file every
  verdict in the engineering log; the two must not drift.

    * `:identical` - the same pairs and floats in every bracket.
    * `{:worse, group, label, actual, alternative}` - the alternative scores
      LOWER on `label`, the first rung that differs. Higher is better on
      every rung.
    * `{:better, group, label, actual, alternative}` - the alternative scores
      higher. For an alternative to the engine's own answer this means the
      search missed it.
    * `{:tie, group, :actual | :alternative | :tie}` - different pairs,
      every rung identical, so FIDE section 3's transposition order decides;
      the third element is which one it picks.
    * `{:incomparable, group}` - the two answers put different numbers of
      edges in that bracket's window, so every rung differs by accounting
      alone and none of it is criterial. See `explain_round/3`'s "What it
      cannot see".
  """
  def compare(actual, alternative) do
    by_group = Map.new(alternative, &{&1.group, &1})

    Enum.find_value(actual, :identical, fn o ->
      case Map.get(by_group, o.group) do
        nil ->
          {:incomparable, o.group}

        t ->
          if Enum.sort(o.pairs) == Enum.sort(t.pairs) and
               Enum.sort(o.floats) == Enum.sort(t.floats) do
            nil
          else
            differing_rung(o, t)
          end
      end
    end)
  end

  defp differing_rung(o, t) do
    cond do
      Map.get(o, :edge_count) != Map.get(t, :edge_count) ->
        {:incomparable, o.group}

      true ->
        case Enum.find(Enum.zip(o.rungs, t.rungs), fn {{_, ov}, {_, tv}} -> ov != tv end) do
          nil -> {:tie, o.group, lex_pick(o, t)}
          {{label, ov}, {_, tv}} when tv > ov -> {:better, o.group, label, ov, tv}
          {{label, ov}, {_, tv}} -> {:worse, o.group, label, ov, tv}
        end
    end
  end

  defp lex_pick(o, t) do
    cond do
      o.lex == t.lex -> :tie
      o.lex < t.lex -> :actual
      true -> :alternative
    end
  end

  @doc """
  The pairs in a report that the absolute criteria forbid, each with the
  reason - the exclusions a bracket lists that its own pairs then use.

  `explain_round/3` scores whatever pairing it is handed, legal or not,
  which is what makes it usable on an arbiter's proposal; this is the check
  that says whether the proposal was legal in the first place. Every real
  pair lands inside exactly one bracket of the reconstruction (a floater is
  a member of the bracket it floats into), so a bracket's `exclusions`
  cover every pair it keeps.
  """
  def violations(report) do
    Enum.flat_map(report, fn bracket ->
      kept = MapSet.new(bracket.pairs, fn {x, y} -> Enum.sort([x, y]) end)

      bracket.exclusions
      |> Enum.filter(&MapSet.member?(kept, Enum.sort(&1.players)))
      |> Enum.map(&Map.put(&1, :group, bracket.group))
    end)
  end

  @doc """
  Judges a complete alternative pairing against the one that was played.

  Returns `%{verdict:, violations:, report:}` - `compare/2`'s verdict, the
  alternative's absolute-rule violations, and its full `explain_round/3`
  report for a caller that wants to show the bracket it changed.
  """
  def judge(players, actual_pairs, alternative_pairs, opts \\ []) do
    actual = Pairing.explain_round(players, actual_pairs, opts)
    alternative = Pairing.explain_round(players, alternative_pairs, opts)

    %{
      verdict: compare(actual, alternative),
      violations: violations(alternative),
      report: alternative
    }
  end

  @doc """
  For every player who floated out of a bracket, what would have happened
  had each other member floated instead.

  One entry per floater: `%{group:, floater:, candidates: [...]}` or, past
  `max_candidates/0`, `%{group:, floater:, skipped: :too_many, count: n}`.
  Each candidate is `%{rank:, outcome:, ...}` with `outcome` one of
  `:impossible` (no legal pairing has them leave this bracket), `:worse`,
  `:tie`, `:better`, `:incomparable` or `:same`, plus `differs_at` (the
  rung, as `compare/2` names it), `fate` (whom they would have played, and
  at what score) and `floater_stayed?` - whether the forced alternative
  actually kept the original floater in the bracket, which it need not.

  The pairing-allocated bye is not a float and is not analysed here; see
  `bye_alternatives/3`.
  """
  def float_alternatives(players, pairs, opts \\ []) do
    actual = Pairing.explain_round(players, pairs, opts)
    bye = bye_holder(pairs)

    for bracket <- actual, floater <- bracket.floats, floater != bye do
      candidates = bracket.order -- [floater]

      if length(candidates) > @max_candidates do
        %{group: bracket.group, floater: floater, skipped: :too_many, count: length(candidates)}
      else
        %{
          group: bracket.group,
          floater: floater,
          candidates:
            Enum.map(candidates, fn y ->
              forced = for m <- bracket.order, m != y, do: [y, m]
              attempt(players, opts, actual, y, forced, floater)
            end)
        }
      end
    end
  end

  @doc """
  For the player who received the pairing-allocated bye, what would have
  happened had each other member of their bracket received it instead -
  after asking C.2 whether they could have.

  `nil` when the round has no bye. Otherwise `%{holder:, group:,
  candidates: [...]}` (or `skipped:` past the cap), each candidate as in
  `float_alternatives/3` except that one C.2 cannot allow is
  `%{rank:, outcome: :ineligible, reason: :pairing_bye | :forfeit_win |
  :full_point_bye}` and is not searched.
  """
  def bye_alternatives(players, pairs, opts \\ []) do
    case bye_holder(pairs) do
      nil ->
        nil

      holder ->
        actual = Pairing.explain_round(players, pairs, opts)
        eligibility = Pairing.bye_eligibility(players, opts)
        bracket = Enum.find(actual, &(holder in &1.order)) || List.last(actual)
        candidates = bracket.order -- [holder]
        everyone = Enum.map(players, & &1.rank)

        if length(candidates) > @max_candidates do
          %{holder: holder, group: bracket.group, skipped: :too_many, count: length(candidates)}
        else
          %{
            holder: holder,
            group: bracket.group,
            candidates:
              Enum.map(candidates, fn y ->
                case Map.get(eligibility, y) do
                  nil ->
                    forced = for m <- everyone, m != y, do: [y, m]
                    attempt(players, opts, actual, y, forced, holder)

                  reason ->
                    %{rank: y, outcome: :ineligible, reason: reason}
                end
              end)
          }
        end
    end
  end

  # One forced search: pair again with `forced` added to the forbidden
  # pairs, then score the result under the REAL options - the forcing is how
  # the alternative is reached, not a rule it should be judged by.
  defp attempt(players, opts, actual, y, forced, displaced) do
    forced_opts =
      Keyword.put(opts, :forbidden_pairs, (Keyword.get(opts, :forbidden_pairs) || []) ++ forced)

    try do
      alt_pairs = Pairing.pair_next_round(players, forced_opts)
      alt = Pairing.explain_round(players, alt_pairs, opts)
      verdict = compare(actual, alt)

      %{
        rank: y,
        outcome: outcome(verdict),
        differs_at: differs_at(verdict),
        fate: fate(alt_pairs, players, y),
        floater_stayed?: stayed?(alt, displaced)
      }
    rescue
      e in Pairing.NoValidPairingError ->
        %{rank: y, outcome: :impossible, reason: Exception.message(e)}
    end
  end

  defp outcome(:identical), do: :same
  defp outcome({:worse, _, _, _, _}), do: :worse
  defp outcome({:better, _, _, _, _}), do: :better
  defp outcome({:tie, _, _}), do: :tie
  defp outcome({:incomparable, _}), do: :incomparable

  defp differs_at({:worse, group, label, ov, tv}),
    do: %{group: group, label: label, actual: ov, alternative: tv}

  defp differs_at({:better, group, label, ov, tv}),
    do: %{group: group, label: label, actual: ov, alternative: tv}

  defp differs_at({:tie, group, pick}), do: %{group: group, label: nil, lex: pick}
  defp differs_at({:incomparable, group}), do: %{group: group, label: nil}
  defp differs_at(:identical), do: nil

  # Whom `y` played in the alternative, and at what score - "you would have
  # played Smit, a point below you" is the sentence the arbiter says next.
  defp fate(alt_pairs, players, y) do
    points = Map.new(players, &{&1.rank, &1.points})

    opponent =
      Enum.find_value(alt_pairs, fn
        {^y, other} -> {:ok, other}
        {other, ^y} -> {:ok, other}
        _ -> nil
      end)

    case opponent do
      {:ok, nil} -> %{opponent: nil, score: nil}
      {:ok, other} -> %{opponent: other, score: Map.get(points, other)}
      nil -> %{opponent: nil, score: nil}
    end
  end

  # Whether the player the question is about (the actual floater, or the
  # actual bye holder) was kept in their bracket by the alternative. Forcing
  # `y` out does not guarantee it: the matcher may float both.
  defp stayed?(alt_report, rank) do
    Enum.any?(alt_report, fn bracket ->
      rank in bracket.order and rank not in bracket.floats
    end)
  end

  defp bye_holder(pairs) do
    Enum.find_value(pairs, fn
      {w, nil} -> w
      _ -> nil
    end)
  end
end
