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
      one is not where this question gets asked at pairing time. A caller
      with the arbiter knowingly waiting passes `max_candidates: :all`.

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

  # The cap is an option too - `max_candidates: n | :all` - so a page that
  # showed "not worked out" can offer to work it out, with the arbiter
  # waiting on it knowingly. Popped before the options reach the engine,
  # which has no such key.
  defp pop_cap(opts), do: Keyword.pop(opts, :max_candidates, @max_candidates)

  defp over_cap?(_candidates, :all), do: false
  defp over_cap?(candidates, cap) when is_integer(cap), do: length(candidates) > cap

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
        case Enum.find(Enum.zip(o.rungs, t.rungs), fn {{label, ov}, {_, tv}} ->
               ov != tv and criterial?(label)
             end) do
          nil -> {:tie, o.group, lex_pick(o, t)}
          {{label, ov}, {_, tv}} when tv > ov -> {:better, o.group, label, ov, tv}
          {{label, ov}, {_, tv}} -> {:worse, o.group, label, ov, tv}
        end
    end
  end

  # The completion rung is not compared. Its weight per edge is
  # `1 + [a is no bye candidate] + [b is no bye candidate]`: the `1`s count
  # edges, which `edge_count` above already holds equal, and the eligibility
  # part is how the search steers the bye within a WINDOW - this bracket and
  # the next - so a float edge's share of it depends on whom the floater
  # meets below, which is the next bracket's decision. Attributed to this
  # bracket alone it is accounting, not a criterion.
  #
  # Seed 5, round 7 of a JaVaFo-judging run
  # (test/fixtures/alternatives/float_edge_window.trf): the engine's own
  # round scored 8 here in the 2.5 bracket against a legal alternative's 9,
  # the whole difference being that the alternative's floater met a player
  # who had already had a bye. The window sums were equal, the search had
  # tied them - and a page reported that the engine would have preferred
  # the alternative to its own round. C.2 itself is held by `violations/1`,
  # C.5 by the edge count; the comparison starts at C6.
  defp criterial?("C2/" <> _completion), do: false
  defp criterial?(_label), do: true

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
  `max_candidates/0` (or the `:max_candidates` option - an integer, or
  `:all` for no cap), `%{group:, floater:, skipped: :too_many, count: n}`.
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
    {cap, opts} = pop_cap(opts)
    actual = Pairing.explain_round(players, pairs, opts)
    bye = bye_holder(pairs)

    for bracket <- actual, floater <- bracket.floats, floater != bye do
      candidates = bracket.order -- [floater]

      if over_cap?(candidates, cap) do
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
  candidates: [...]}` (or `skipped:` past the cap, which the
  `:max_candidates` option overrides as in `float_alternatives/3`), each
  candidate as in
  `float_alternatives/3` except that one C.2 cannot allow is
  `%{rank:, outcome: :ineligible, reason: :pairing_bye | :forfeit_win |
  :full_point_bye}` and is not searched.
  """
  def bye_alternatives(players, pairs, opts \\ []) do
    case bye_holder(pairs) do
      nil ->
        nil

      holder ->
        {cap, opts} = pop_cap(opts)
        actual = Pairing.explain_round(players, pairs, opts)
        eligibility = Pairing.bye_eligibility(players, opts)
        bracket = Enum.find(actual, &(holder in &1.order)) || List.last(actual)
        candidates = bracket.order -- [holder]
        everyone = Enum.map(players, & &1.rank)

        if over_cap?(candidates, cap) do
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

  @doc """
  "What if `a` played `b`?" - answered properly: the best round in which
  they meet, found by forbidding each of them every other opponent and
  pairing again, then judged against what was played.

    * `%{outcome: :illegal, reason: ...}` - they cannot meet at all; the
      reason is the absolute rule (rematch, colour, forbidden) that says so.
    * `%{outcome: :impossible, reason: message}` - they could meet, but no
      legal round contains that pair.
    * otherwise `outcome` is `:worse`, `:tie`, `:same` or `:better` as
      `compare/2` names it, with `differs_at`, the alternative `pairs`, and
      `changed` - how many boards differ from what was played. That number
      is the answer to "and what would it have cost everybody else".
  """
  def force_pair(players, pairs, a, b, opts \\ []) do
    # The pair itself first. Forcing an illegal pair leaves the search with
    # no legal round at all, and "no legal round" is the wrong answer to
    # "why can't 1 play 5" when the true one is "they met in round 2".
    case direct_reason(players, pairs, a, b, opts) do
      nil -> force_legal_pair(players, pairs, a, b, opts)
      reason -> %{outcome: :illegal, reason: reason, pairs: nil}
    end
  end

  defp force_legal_pair(players, pairs, a, b, opts) do
    actual = Pairing.explain_round(players, pairs, opts)
    ranks = Enum.map(players, & &1.rank)

    forced =
      for m <- ranks, m not in [a, b], group <- [[a, m], [b, m]], do: group

    forced_opts =
      Keyword.put(opts, :forbidden_pairs, (Keyword.get(opts, :forbidden_pairs) || []) ++ forced)

    try do
      alt_pairs = Pairing.pair_next_round(players, forced_opts)

      if paired_together?(alt_pairs, a, b) do
        alt = Pairing.explain_round(players, alt_pairs, opts)
        verdict = compare(actual, alt)

        %{
          outcome: outcome(verdict),
          differs_at: differs_at(verdict),
          pairs: alt_pairs,
          changed: changed_boards(pairs, alt_pairs),
          violations: violations(alt)
        }
      else
        # Legal as a pair, but no legal round seats them together: one of
        # them had to float or take the bye for the rest to work out.
        %{outcome: :impossible, reason: "no legal round seats them together", pairs: nil}
      end
    rescue
      e in Pairing.NoValidPairingError ->
        %{outcome: :impossible, reason: Exception.message(e), pairs: nil}
    end
  end

  @doc """
  A player did not turn up. What is the least disruptive legal fix?

  `absent` is their rank; `pairs` the round as announced. Returns
  `%{needed: false, why: :had_bye | :not_seated}` when there is nothing to
  fix, else:

      %{
        needed: true, absent:, opponent:,
        full_repair: %{pairs:, affected: [ranks]},
        options: [%{pairs:, affected: [ranks], outcome:, differs_at:}, ...]
      }

  `full_repair` is the engine pairing the reduced field from scratch - the
  best round, and usually the one that moves the most people. `options` are
  the small fixes: the stranded opponent takes the bye, or plays the bye
  holder, or takes over one board whose displaced player then takes the
  bye or the bye holder. Each is legal (illegal ones are dropped), lists
  exactly who else is affected, and carries its verdict against the full
  repair - `:same` means the small fix IS the best round. Sorted by how
  many people it touches, then by that verdict.

  Advisory. Nothing here changes a pairing; the arbiter does, by hand.
  """
  def no_show(players, pairs, absent, opts \\ []) do
    case opponent_of(pairs, absent) do
      :not_seated ->
        %{needed: false, why: :not_seated}

      nil ->
        %{needed: false, why: :had_bye}

      opponent ->
        players = mark_absent(players, absent)
        remaining = Enum.reject(pairs, fn {x, y} -> absent in [x, y] end)
        full_pairs = Pairing.pair_next_round(players, opts)
        full = Pairing.explain_round(players, full_pairs, opts)
        holder = bye_holder(remaining)

        options =
          (small_fixes(remaining, opponent, holder) ++ board_fixes(remaining, opponent, holder))
          |> Enum.flat_map(fn {candidate, affected} ->
            for coloured <- colour_variants(candidate, remaining),
                report = Pairing.explain_round(players, coloured, opts),
                violations(report) == [] do
              verdict = compare(full, report)

              %{
                pairs: coloured,
                affected: Enum.sort(affected),
                outcome: outcome(verdict),
                differs_at: differs_at(verdict)
              }
            end
          end)
          |> Enum.sort_by(&{length(&1.affected), outcome_rank(&1.outcome)})
          |> Enum.uniq_by(& &1.affected)

        %{
          needed: true,
          absent: absent,
          opponent: opponent,
          full_repair: %{
            pairs: full_pairs,
            affected: affected_by(pairs, full_pairs, [absent, opponent])
          },
          options: options
        }
    end
  end

  # The stranded opponent alone: takes the bye holder's game, or the bye.
  defp small_fixes(remaining, opponent, nil), do: [{remaining ++ [{opponent, nil}], []}]

  defp small_fixes(remaining, opponent, holder),
    do: [{replace_bye(remaining, holder, {opponent, holder}), [holder]}]

  # The stranded opponent takes over a board; the player it displaces goes
  # to the bye holder, or to the bye.
  defp board_fixes(remaining, opponent, holder) do
    for {x, y} <- remaining, not is_nil(y), {take, displaced} <- [{x, y}, {y, x}] do
      others = List.delete(remaining, {x, y})

      case holder do
        nil ->
          {others ++ [{opponent, take}, {displaced, nil}], [x, y]}

        h ->
          {others |> replace_bye(h, {displaced, h}) |> Kernel.++([{opponent, take}]), [x, y, h]}
      end
    end
  end

  defp replace_bye(pairs, holder, pair) do
    Enum.map(pairs, fn
      {^holder, nil} -> pair
      other -> other
    end)
  end

  # A hand-built pair has no colour decision behind it, so every new pair
  # is tried both ways round and the ladder picks - C10-C13 are exactly the
  # rungs that know which way is right.
  defp colour_variants(candidate, original) do
    known = MapSet.new(original)

    candidate
    |> Enum.reduce([[]], fn
      {_w, nil} = pair, acc ->
        Enum.map(acc, &[pair | &1])

      {w, b} = pair, acc ->
        if MapSet.member?(known, pair),
          do: Enum.map(acc, &[pair | &1]),
          else: Enum.flat_map(acc, &[[{w, b} | &1], [{b, w} | &1]])
    end)
    |> Enum.map(&Enum.reverse/1)
  end

  defp outcome_rank(:same), do: 0
  defp outcome_rank(:tie), do: 1
  defp outcome_rank(:better), do: 2
  defp outcome_rank(:worse), do: 3
  defp outcome_rank(_), do: 4

  # Everyone (other than `except`) whose opponent differs between two rounds.
  defp affected_by(before, after_pairs, except) do
    partners = fn pairs ->
      Enum.reduce(pairs, %{}, fn
        {w, nil}, acc -> Map.put(acc, w, nil)
        {w, b}, acc -> acc |> Map.put(w, b) |> Map.put(b, w)
      end)
    end

    was = partners.(before)
    now = partners.(after_pairs)

    (Map.keys(was) ++ Map.keys(now))
    |> Enum.uniq()
    |> Enum.reject(&(&1 in except))
    |> Enum.filter(&(Map.get(was, &1, :absent) != Map.get(now, &1, :absent)))
    |> Enum.sort()
  end

  # Marked the way a TRF marks a player sitting a round out - a zero-point
  # bye for the round being paired - which `active_this_round?/2` reads and
  # `rounds_played/1` does not advance on.
  defp mark_absent(players, rank) do
    Enum.map(players, fn
      %{rank: ^rank} = p ->
        %{p | games: p.games ++ [%{result: "Z", colour: nil, opponent_rank: nil}]}

      p ->
        p
    end)
  end

  defp opponent_of(pairs, rank) do
    Enum.find_value(pairs, :not_seated, fn
      {^rank, other} -> {:found, other}
      {other, ^rank} -> {:found, other}
      _ -> nil
    end)
    |> case do
      {:found, other} -> other
      :not_seated -> :not_seated
    end
  end

  defp paired_together?(pairs, a, b), do: Enum.any?(pairs, &(&1 in [{a, b}, {b, a}]))

  defp changed_boards(pairs, alt_pairs) do
    unordered = fn list -> MapSet.new(list, fn {x, y} -> Enum.sort([x, y]) end) end
    MapSet.size(MapSet.difference(unordered.(alt_pairs), unordered.(pairs)))
  end

  # Why `a` and `b` cannot meet: seat them directly (their opponents then
  # meeting each other) and read the violation off that pairing.
  defp direct_reason(players, pairs, a, b, opts) do
    alt =
      case opponent_of(pairs, a) do
        ^b ->
          pairs

        nil ->
          Enum.map(pairs, fn
            {^a, nil} -> {a, b}
            {^b, c} -> {c, nil}
            {c, ^b} -> {c, nil}
            pair -> pair
          end)

        :not_seated ->
          pairs

        oa ->
          Enum.map(pairs, fn {w, k} -> {swap_seat(w, b, oa), swap_seat(k, b, oa)} end)
      end

    players
    |> Pairing.explain_round(alt, opts)
    |> violations()
    |> Enum.find(&(Enum.sort(&1.players) == Enum.sort([a, b])))
  end

  defp swap_seat(rank, x, y) when rank == x, do: y
  defp swap_seat(rank, x, y) when rank == y, do: x
  defp swap_seat(rank, _x, _y), do: rank

  defp bye_holder(pairs) do
    Enum.find_value(pairs, fn
      {w, nil} -> w
      _ -> nil
    end)
  end
end
