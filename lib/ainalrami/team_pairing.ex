defmodule Ainalrami.TeamPairing do
  @moduledoc """
  FIDE Swiss Team Pairing System, C.04.6, effective 1 February 2026.

  The regulation is kept verbatim in `docs/c0406-regulation-text.md` and the
  reading notes - written before any code existed, so the reading was checked
  against the regulation rather than against an implementation - are in
  `docs/conformance-c0406-teams.md`. Every article number below cites that
  text.

  ## This is not the Dutch system applied to teams

  Article 0 says the individual rules apply *mutatis mutandis*, and then
  C.04.6 defines its own criteria set, its own bye rule and its own
  procedure. Three differences change the shape of the code:

  | | individual (C.04.3) | teams (C.04.6) |
  |---|---|---|
  | criteria | C1-C21 | C1-C3 absolute/completion, C4-C10 quality |
  | bracket | best candidate under a weight ladder | **first** candidate in a defined enumeration |
  | score | one | **two** - primary and secondary |

  The second row is the important one. `Ainalrami.WeightedMatching` - the
  whole machinery the individual engine is built on - is not used here at
  all. 3.6 defines an order and a predicate, not an optimum. Matching still
  earns its keep in one place, `Ainalrami.TeamPairing.Matching`, but only to
  answer [C3]: *can what is left still be paired?*

  ## The procedure (3.3.2)

      1. assign the pairing-allocated bye, if the field is odd  (3.4)
      2. take the top-scoregroup, add upfloaters if it is odd   (3.5)
      3. pair that bracket                                      (3.6)
      4. repeat 2-3 until every team is paired
      5. allocate colours                                       (Article 4)

  ## Usage

      teams = [%Team{tpn: 1, match_points: 2.0}, ...]
      {:ok, round} = Ainalrami.TeamPairing.pair_round(teams, expected_rounds: 9)

      round.pairs  # [%{white: 3, black: 7, first_team: 3}, ...]
      round.bye    # the TPN that got the PAB, or nil

  ## Verification, which is unusually strong here

  There is no reference implementation to diff against - bbpPairings, JaVaFo
  and Gacrux have no team code, and Swiss-Manager is closed-source Windows
  software. That removes the corpus method the individual engine's
  credibility rests on.

  The regulation hands back something better, though. For the individual
  system, "which whole-round pairing is correct" has no defined answer -
  C.04.3 specifies a sequential procedure, not a global optimum. Here 3.6
  defines the answer *as* the first element of an enumerable order. So for a
  bracket small enough to enumerate exhaustively, a test can BE the
  definition: generate every pairing, sort by identifier, filter by the
  criteria, assert the engine returns the head. That is a proof rather than a
  correlation, and `test/ainalrami/team_pairing_test.exs` does it.
  """

  alias Ainalrami.TeamPairing.{Bracket, Colour, Explanation, Matching, Team}

  import Bitwise

  # How many candidate upfloater sets of one size 3.5 may enumerate. A set of
  # one from sixty lower teams is sixty; a set of three is 34,220. Beyond this
  # the round refuses rather than grinding - see `select_upfloaters/4`.
  @default_max_upfloater_sets 200_000

  @doc """
  Pairs one round.

  Returns `{:ok, %{pairs: [...], bye: tpn | nil, brackets: [...]}}` or
  `{:error, reason}`; with `explain: true` the map also has `:explanation`.

  Each entry in `pairs` is `%{white: tpn, black: tpn, first_team: tpn,
  score_difference: n}` - colours already allocated per Article 4, and
  `first_team` carried through because 4.2 decided it and a caller printing
  a match card usually wants it.

  Options:

    * `:score_mode` - `:match_points` (default, 1.2.2) or `:game_points`.
    * `:use_secondary?` - whether 4.2.2 may break a first-team tie. Default
      true.
    * `:type` - `:a` (default) or `:b` colour preferences (1.7).
    * `:initial_colour` - `:white` (default) or `:black`, drawn by lot
      before round one (4.1).
    * `:absent` - TPNs of teams that have ARRIVED (played, or held a bye, in
      an earlier round) but are not in this round's field: sitting a round
      out, or withdrawn after playing. They are not paired, but they keep
      their place in Article 4.3.1's arrival numbering, exactly as an absent
      player does on the individual side. A team that has never arrived is
      simply left out of both lists. A TPN in both `teams` and `:absent` is
      `{:error, {:invalid_option, :absent, tpns}}`.
    * `:max_upfloater_sets` - how many candidate upfloater sets 3.5 may
      enumerate for one set size (default 200_000); beyond it the round is
      `{:error, :budget_exhausted}`.
    * `:round` / `:expected_rounds` - both optional; together they decide
      "the last two rounds", which switch off [C7] and [C10], and "the last
      round", which switches off Type B mild preferences. Given neither, the
      engine assumes it is NOT near the end - the conservative choice, since
      it keeps criteria switched on.
    * `:max_candidates` - per-bracket candidate budget, and `:max_steps` its
      walk budget (see `Ainalrami.TeamPairing.Bracket`). Exceeding the walk
      budget comes back as `{:error, :budget_exhausted}`, which is NOT
      `{:error, :no_legal_pairing}` - it means the search stopped, not that
      it finished.
    * `:explain` - when true, the result also carries `:explanation`: why
      the bye went where it did, which upfloater sets each bracket considered
      and what decided between them, and which rule of Article 4 gave each
      match its colours. Default false. Everything else in the result is
      identical either way. Shape and bound in
      `Ainalrami.TeamPairing.Explanation`.
    * `:explain_limit` - how many entries each recorded list keeps (default
      10); the rest are
      counted, not kept.

  ## Why it returns brackets too

  `brackets` reports what the procedure actually did - which teams formed
  each bracket, who upfloated into it, how many candidates 3.6 examined and
  whether that search was exhaustive. An arbiter asked to justify a pairing
  needs the bracket structure, not just the boards, and reconstructing it
  from the finished pairs is guesswork. This is the same reason the
  individual engine grew `explain_round/3`.

  `explain: true` goes the rest of the way: the REASONS, recorded where the
  decisions are made - which teams the bye passed over for 3.4.1, which
  upfloater sets were considered and rejected and the criterion that decided
  between the chosen set and the runner-up, and the Article 4 rule behind
  each board-1 colour. `Ainalrami.TeamPairing.Explanation` has the shape and
  its bound.
  """
  def pair_round(teams, opts \\ []) when is_list(teams) do
    with {:ok, mode} <- validate_score_mode(Keyword.get(opts, :score_mode, :match_points)),
         {:ok, absent} <- validate_absent(Keyword.get(opts, :absent, []), teams),
         {:ok, explain} <- validate_explain(opts) do
      do_pair_round(teams, opts, mode, absent, explain)
    end
  end

  # nil when not explaining - every recording helper is a no-op on nil, so
  # the path without `:explain` does no bookkeeping at all.
  defp validate_explain(opts) do
    limit = Keyword.get(opts, :explain_limit, Explanation.default_limit())

    cond do
      not is_integer(limit) or limit < 0 -> {:error, {:invalid_option, :explain_limit, limit}}
      Keyword.get(opts, :explain, false) == true -> {:ok, %{limit: limit}}
      true -> {:ok, nil}
    end
  end

  defp validate_absent(absent, teams) when is_list(absent) do
    if Enum.all?(absent, &is_integer/1) do
      playing = MapSet.new(teams, & &1.tpn)

      case Enum.filter(absent, &MapSet.member?(playing, &1)) do
        [] -> {:ok, Enum.uniq(absent)}
        both -> {:error, {:invalid_option, :absent, both}}
      end
    else
      {:error, {:invalid_option, :absent, absent}}
    end
  end

  defp validate_absent(absent, _teams), do: {:error, {:invalid_option, :absent, absent}}

  # `pair_round/2`'s `@doc` promises `{:ok, _} | {:error, _}`, and an unknown
  # `:score_mode` did not keep that promise: it was threaded unvalidated into
  # `Team.score/2`, which had clauses for the two modes 1.2.1 defines and no
  # third, so the caller got a FunctionClauseError from three frames down
  # naming a private helper rather than the option they had mistyped. The
  # option is a caller's, so it is checked where the caller's options arrive.
  defp validate_score_mode(mode) when mode in [:match_points, :game_points], do: {:ok, mode}
  defp validate_score_mode(mode), do: {:error, {:invalid_option, :score_mode, mode}}

  defp do_pair_round(teams, opts, mode, absent, explain) do
    round = Keyword.get(opts, :round)
    expected = Keyword.get(opts, :expected_rounds)

    last_round? = not is_nil(round) and not is_nil(expected) and round >= expected
    last_two? = not is_nil(round) and not is_nil(expected) and round >= expected - 1

    base = [
      type: Keyword.get(opts, :type, :a),
      last_round?: last_round?,
      last_two_rounds?: last_two?,
      max_candidates: Keyword.get(opts, :max_candidates, 200_000),
      max_upfloater_sets: Keyword.get(opts, :max_upfloater_sets, @default_max_upfloater_sets)
    ]

    # Forwarded only when given, so the bracket's own default stays the one
    # documented place the number lives.
    base =
      case Keyword.fetch(opts, :max_steps) do
        {:ok, max_steps} -> Keyword.put(base, :max_steps, max_steps)
        :error -> base
      end

    with {:ok, bye, rest, bye_account} <- choose_bye(teams, mode, explain),
         {:ok, brackets, bracket_accounts} <- pair_brackets(rest, mode, base, explain) do
      # Article 4.3.1's numbering, built ONCE for the round over the whole
      # roster. Per pair it would be rebuilt for every board, which is the
      # class of regression the individual engine has already paid for
      # twice - see `Ainalrami.Pairing`'s note on `score_before/3`.
      #
      # Over the teams paired AND the arrived-but-absent ones, so a team
      # sitting this round out keeps its number and nobody below it shifts
      # parity. Without `:absent` this is the list alone, as before.
      numbers = Colour.parity_numbers(teams, absent)

      allocated =
        brackets
        |> Enum.flat_map(& &1.pairs)
        |> Enum.map(&allocate_colours(&1, teams, numbers, mode, opts, last_round?))

      pairs = Enum.map(allocated, &elem(&1, 0))
      result = %{pairs: pairs, bye: bye && bye.tpn, brackets: brackets}

      if explain do
        explanation = %{
          limit: explain.limit,
          bye: bye_account,
          brackets: bracket_accounts,
          pairs:
            Enum.map(allocated, fn {pair, rules} ->
              pair |> Map.take([:white, :black, :first_team]) |> Map.merge(rules)
            end)
        }

        {:ok, Map.put(result, :explanation, explanation)}
      else
        {:ok, result}
      end
    end
  end

  # ---------------------------------------------------------------------
  # 3.4 - Pairing-Allocated-Bye assignment
  # ---------------------------------------------------------------------

  @doc """
  Assigns the pairing-allocated bye (3.4), returning `{:ok, bye_or_nil,
  remaining}`.

  The bye goes to the team that 3.4.1 leaves a legal pairing for everyone
  else, 3.4.2 has the lowest score, 3.4.3 has played the most matches,
  3.4.4 has the largest TPN.

  3.4.1 is listed first and is a *filter*, not a tie-break: a team whose
  removal strands the rest is not a candidate at all, however low its score.
  So the ordering below sorts by 3.4.2-3.4.4 and then walks the list taking
  the first team that also satisfies 3.4.1 - which is what "the team that
  [3.4.1] and [3.4.2] and ..." means when the first condition can fail.

  [C2] (2.1.2) removes teams that have already had a bye, won a match by
  forfeit, or been given a full-point bye, before any of this.
  """
  def assign_bye(teams, mode \\ :match_points)

  def assign_bye(teams, mode) do
    with {:ok, bye, rest, _account} <- choose_bye(teams, mode, nil) do
      {:ok, bye, rest}
    end
  end

  # `assign_bye/2`, recording the reasons when `explain` is not nil. One walk
  # either way: the recording reads what the walk already decided.
  defp choose_bye(teams, mode, explain) do
    if rem(length(teams), 2) == 0 do
      {:ok, nil, teams, nil}
    else
      {ineligible, eligible} = Enum.split_with(teams, &Team.pab_ineligible?/1)

      ordered =
        Enum.sort_by(eligible, fn t ->
          {Team.score(t, mode), -Team.matches_played(t), -t.tpn}
        end)

      # `Enum.find/2`'s walk, with the teams it passes recorded: each one
      # checked and found to strand the rest (3.4.1).
      {found, passed} =
        ordered
        |> Enum.with_index()
        |> Enum.reduce_while({nil, Explanation.bounded()}, fn {team, index}, {nil, passed} ->
          if leaves_legal_pairing?(team, teams) do
            {:halt, {{team, index}, passed}}
          else
            {:cont, {nil, record(passed, explain, fn -> bye_entry(team, mode) end)}}
          end
        end)

      case found do
        nil ->
          # 3.3.3: "If it is impossible to complete a round-pairing, the
          # Chief Arbiter shall decide what to do." The engine's job is to
          # say so clearly, not to invent a rule.
          {:error, :no_legal_bye}

        {team, index} ->
          account =
            explain &&
              bye_account(team, Enum.at(ordered, index + 1), ineligible, passed, mode, explain)

          {:ok, team, Enum.reject(teams, &(&1.tpn == team.tpn)), account}
      end
    end
  end

  defp bye_account(team, next, ineligible, passed, mode, explain) do
    chosen = bye_entry(team, mode)
    next = next && bye_entry(next, mode)

    ineligible =
      Enum.reduce(ineligible, Explanation.bounded(), fn t, acc ->
        reasons =
          [had_pab: t.had_pab?, won_by_forfeit: t.won_by_forfeit?]
          |> Enum.filter(&elem(&1, 1))
          |> Enum.map(&elem(&1, 0))

        Explanation.push(acc, %{tpn: t.tpn, reasons: reasons}, explain.limit)
      end)

    chosen
    |> Map.merge(%{
      ineligible: Explanation.items(ineligible),
      ineligible_omitted: Explanation.omitted(ineligible),
      passed_over: Explanation.items(passed),
      passed_over_omitted: Explanation.omitted(passed),
      next: next,
      decided_by: Explanation.bye_decided_by(chosen, next)
    })
  end

  defp bye_entry(team, mode) do
    %{tpn: team.tpn, score: Team.score(team, mode), matches_played: Team.matches_played(team)}
  end

  # Pushes `build.()` onto a bounded list when explaining; untouched (and
  # `build` never called) otherwise.
  defp record(list, nil, _build), do: list
  defp record(list, explain, build), do: Explanation.push(list, build.(), explain.limit)

  # 3.4.1 - the rest must still be pairable without a rematch. This is the
  # completion oracle, not a full pairing: we only need to know that one
  # exists.
  defp leaves_legal_pairing?(candidate, teams) do
    rest = Enum.reject(teams, &(&1.tpn == candidate.tpn))
    {mask, adj} = adjacency(rest)
    Matching.feasible?(mask, adj)
  end

  # ---------------------------------------------------------------------
  # 3.5 / 3.6 - bracket formation and pairing
  # ---------------------------------------------------------------------

  defp pair_brackets(teams, mode, base, explain) do
    do_pair_brackets(teams, mode, base, explain, {[], []})
  end

  defp do_pair_brackets([], _mode, _base, explain, {acc, accounts}),
    do: {:ok, Enum.reverse(acc), explain && Enum.reverse(accounts)}

  defp do_pair_brackets(remaining, mode, base, explain, {acc, accounts}) do
    # 3.2 - the top-scoregroup is the highest score among teams yet to pair.
    top_score = remaining |> Enum.map(&Team.score(&1, mode)) |> Enum.max()
    residents = Enum.filter(remaining, &(Team.score(&1, mode) == top_score))
    lower = Enum.reject(remaining, &(Team.score(&1, mode) == top_score))

    case select(residents, lower, mode, base, explain) do
      {:ok, upfloaters, selection} ->
        bracket = residents ++ upfloaters
        up_tpns = Enum.map(upfloaters, & &1.tpn)

        opts = Keyword.put(base, :upfloater_tpns, up_tpns)

        case Bracket.pair(bracket, opts) do
          {:ok, result} ->
            entry = %{
              score: top_score,
              residents: Enum.map(residents, & &1.tpn),
              upfloaters: up_tpns,
              pairs: result.pairs,
              criteria: result.scores,
              candidates: result.candidates,
              exhaustive?: result.exhaustive?
            }

            still_left =
              Enum.reject(lower, fn t -> t.tpn in up_tpns end)

            account =
              explain &&
                %{
                  score: top_score,
                  residents: entry.residents,
                  upfloaters: up_tpns,
                  selection: selection
                }

            do_pair_brackets(
              still_left,
              mode,
              base,
              explain,
              {[entry | acc], [account | accounts]}
            )

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Selects the set of upfloaters for the top-scoregroup (3.5).

  3.5.1 every team with a lower score is a potential upfloater. 3.5.2
  consider all sets complying with [C4] (minimise the count) and [C5]
  (maximise their scores). 3.5.3 within a set, sort by descending score then
  ascending TPN. 3.5.4 sort the sets among themselves lexicographically by
  their TPNs. 3.5.5 take the first that yields a legal pairing also
  complying with [C6] and [C7].

  `lower` is EVERY team still to be paired below the top-scoregroup, not a
  sample of it: [C3] is judged on what is left, so the residents and `lower`
  together must be an even field (the PAB already taken out). An odd one is
  `{:error, :odd_field}`.

  ## The order the criteria are applied in

  2.3 gives them "in descending priority", and that is the order here:

    1. **[C4]** - the fewest upfloaters. The bracket must be even (1.3.2), so
       the count starts at the residents' parity and grows by two, and a
       count is only accepted if some set of that size is LEGAL: the bracket
       it forms can be paired without a rematch ([C1]) and so can everything
       left below it ([C3]).
    2. **[C5]** - among the legal sets of that size, the best score profile
       (`c5_profile_key/2`, where open question 5 is isolated).
    3. **[C6]** - among those, the fewest extra upfloaters the following
       scoregroup's bracket would need (`c6_excess/4`).
    4. **[C7]** - then the fewest upfloaters that floated last round
       (`c7_previous_floaters/2`, where open question 7 is isolated).
    5. **3.5.4** - then the first set in lexicographic TPN order.

  This replaced a first cut that took the minimum count only for an ODD
  scoregroup (an even one could never float anyone in, so two residents who
  had met stopped the round), jumped to a larger set when the best-profile
  sets were illegal rather than relaxing [C5] first, never looked past the
  bracket for [C3], and applied neither [C6] nor [C7].
  """
  def select_upfloaters(residents, lower, mode, base \\ []) do
    with {:ok, set, _selection} <- select(residents, lower, mode, base, nil) do
      {:ok, set}
    end
  end

  # `select_upfloaters/4`, and with `explain` not nil the selection's account
  # (`Ainalrami.TeamPairing.Explanation`'s `selection`) as a third element.
  defp select(residents, lower, _mode, _base, _explain)
       when rem(length(residents) + length(lower), 2) == 1,
       do: {:error, :odd_field}

  defp select(residents, [], _mode, _base, _explain) when rem(length(residents), 2) == 1,
    do: {:error, :no_upfloaters_available}

  defp select(residents, lower, mode, base, explain) do
    # [C4]: the fewest upfloaters that work. The bracket must be even
    # (1.3.2), so the count starts at the residents' parity - 0 for an even
    # scoregroup, 1 for an odd one - and grows by two. An EVEN scoregroup can
    # need upfloaters too: two residents who have already met cannot be a
    # bracket on their own, and neither can a scoregroup whose pairing would
    # strand the teams below it ([C3]).
    start = rem(length(residents), 2)
    rec = new_record(explain)

    start..length(lower)//2
    # Nothing at any size: no bracket for these residents can be paired with
    # the rest still pairable, which is 3.3.3's "impossible to complete a
    # round-pairing" - the same answer `Bracket.pair/2` gives.
    |> Enum.reduce_while({{:error, :no_legal_pairing}, rec}, fn count, {acc, rec} ->
      case best_set_of_size(residents, lower, count, mode, base, rec) do
        {:ok, set, selection} -> {:halt, {{:ok, set, selection}, rec}}
        {:none, rec} -> {:cont, {acc, note_size_without_legal_set(rec, count)}}
        {:error, _} = error -> {:halt, {error, rec}}
      end
    end)
    |> elem(0)
  catch
    {__MODULE__, :budget_exhausted} -> {:error, :budget_exhausted}
  end

  # One set size ([C4] has fixed it). Every set of that size is ranked by
  # [C5], then 3.5.3/3.5.4's TPN order; the answer is the first LEGAL set
  # (the bracket can be paired, and so can everything left below it - [C1]
  # and [C3]) with the best [C5] profile any legal set has, taking among
  # those the least [C6], then the least [C7], then 3.5.4's order.
  #
  # ## Why [C5] is judged over legal sets, not all of them
  #
  # 3.5.2 reads as "[C4] and [C5] first, legality after". Taken literally
  # that leaves no answer when every set with the best score profile is
  # illegal but a set of the same size with a slightly lower profile is
  # fine - and the literal fallback, a larger set, would break [C4] to save
  # [C5], inverting their priority (2.3: "given in descending priority").
  # Judging [C5] among legal sets is the same answer whenever the literal
  # one exists, and the priority-respecting one when it does not.
  #
  # ## What the explanation adds, and what it must not change
  #
  # The walk below decides exactly as it did before explanations existed:
  # `best` moves by the same three rules, and `rec` - nil unless explaining -
  # only watches. `stop` records where the walk ended, so `runner_up/9` can
  # look past that point for the set that came second without re-walking
  # anything the choice depended on.
  defp best_set_of_size(residents, lower, count, mode, base, rec) do
    limit = Keyword.get(base, :max_upfloater_sets, @default_max_upfloater_sets)

    if binomial(length(lower), count) > limit do
      {:error, :budget_exhausted}
    else
      sorted =
        lower
        |> combinations(count)
        |> Enum.map(fn set ->
          # 3.5.3 - within a set: descending score, then ascending TPN.
          ordered = Enum.sort_by(set, fn t -> {0 - Team.score(t, mode), t.tpn} end)
          {c5_profile_key(ordered, mode), Enum.map(ordered, & &1.tpn), ordered}
        end)
        # [C5] first, then 3.5.4 - between sets, lexicographic by their TPNs.
        |> Enum.sort_by(fn {profile, tpns, _set} -> {profile, tpns} end)

      {best, rec, stop} =
        sorted
        |> Enum.with_index()
        |> Enum.reduce_while({nil, rec, :end}, fn {{profile, _tpns, set}, index},
                                                  {best, rec, :end} ->
          if best != nil and profile != best.profile do
            {:halt, {best, rec, {:profile, index}}}
          else
            case legality(residents, lower, set) do
              :legal ->
                key = {c6_excess(set, lower, mode, base), c7_previous_floaters(set, base)}
                candidate = %{profile: profile, key: key, set: set, index: index}
                rec = note_considered(rec, candidate, mode)

                cond do
                  # Nothing can beat a set that fully complies with both; being
                  # the first such set in 3.5.4's order, it is the answer.
                  key == {0, 0} ->
                    {:halt, {candidate, note_second(rec, best), {:zero, index}}}

                  best == nil or key < best.key ->
                    {:cont, {candidate, note_second(rec, best), :end}}

                  true ->
                    {:cont, {best, note_second(rec, candidate), :end}}
                end

              failed ->
                {:cont, {best, note_rejected(rec, set, failed, mode), :end}}
            end
          end
        end)

      case best do
        nil ->
          {:none, rec}

        %{set: set} ->
          {:ok, set, selection(rec, sorted, stop, best, residents, lower, mode, base)}
      end
    end
  end

  # [C1] and [C3] for a candidate set, naming which failed: `:legal`, `"C1"`
  # when the bracket it forms cannot be paired without a rematch, `"C3"` when
  # the bracket can but the teams left below it cannot. The second half is
  # what keeps the procedure from walking into a dead end two brackets later
  # - a bracket's own pairing cannot strand anyone outside it, but the choice
  # of who floats into it can. Same checks, in the same order, as the boolean
  # it replaced.
  defp legality(residents, lower, set) do
    cond do
      not feasible?(residents ++ set) -> "C1"
      not feasible?(without(lower, set)) -> "C3"
      true -> :legal
    end
  end

  # ---------------------------------------------------------------------
  # Recording the selection (only when explaining; every helper is a no-op
  # on a nil record)
  # ---------------------------------------------------------------------

  defp new_record(nil), do: nil

  defp new_record(explain) do
    %{
      limit: explain.limit,
      considered: Explanation.bounded(),
      rejected: Explanation.bounded(),
      sizes_without_legal_set: [],
      second: nil
    }
  end

  defp note_size_without_legal_set(nil, _count), do: nil

  defp note_size_without_legal_set(rec, count),
    do: %{rec | sizes_without_legal_set: rec.sizes_without_legal_set ++ [count]}

  defp note_considered(nil, _candidate, _mode), do: nil

  defp note_considered(rec, candidate, mode),
    do: %{
      rec
      | considered: Explanation.push(rec.considered, set_entry(candidate, mode), rec.limit)
    }

  defp note_rejected(nil, _set, _failed, _mode), do: nil

  defp note_rejected(rec, set, failed, mode) do
    entry = %{
      upfloaters: Enum.map(set, & &1.tpn),
      c4: length(set),
      c5: scores(set, mode),
      failed: failed
    }

    %{rec | rejected: Explanation.push(rec.rejected, entry, rec.limit)}
  end

  # The best legal set other than the eventual winner: least key, then
  # earliest in 3.5.4's order. Every legal set the walk sees has the winner's
  # profile (a different one halts the walk), so key and order are all that
  # rank them.
  defp note_second(nil, _candidate), do: nil
  defp note_second(rec, nil), do: rec

  defp note_second(%{second: second} = rec, candidate) do
    if second == nil or {candidate.key, candidate.index} < {second.key, second.index},
      do: %{rec | second: candidate},
      else: rec
  end

  defp set_entry(%{set: set, key: key}, mode) do
    {c6, c7} = key || {nil, nil}
    %{upfloaters: Enum.map(set, & &1.tpn), c4: length(set), c5: scores(set, mode), c6: c6, c7: c7}
  end

  defp scores(set, mode), do: set |> Enum.map(&Team.score(&1, mode)) |> Enum.sort()

  defp selection(nil, _sorted, _stop, _best, _residents, _lower, _mode, _base), do: nil

  defp selection(rec, sorted, stop, best, residents, lower, mode, base) do
    {rec, runner_up, complete?} = runner_up(rec, sorted, stop, best, residents, lower, mode, base)

    chosen = set_entry(best, mode)
    runner_up = runner_up && set_entry(runner_up, mode)

    %{
      c4: length(best.set),
      sizes_without_legal_set: rec.sizes_without_legal_set,
      chosen: chosen,
      runner_up: runner_up,
      decided_by: if(complete?, do: Explanation.decided_by(chosen, runner_up)),
      considered: Explanation.items(rec.considered),
      considered_omitted: Explanation.omitted(rec.considered),
      rejected: Explanation.items(rec.rejected),
      rejected_omitted: Explanation.omitted(rec.rejected)
    }
  end

  # The best other legal set of this size, `{rec, set | nil, complete?}`.
  #
  #   * the walk ran to the end: every set was examined, and the walk's own
  #     second is the answer (nil when nothing else was legal);
  #   * it halted on a profile change: every set with the winner's profile
  #     was examined, so its second is the answer if there is one, and
  #     otherwise the first legal set of a worse profile, found by looking on;
  #   * it halted on a {0, 0} winner: sets with the same profile after it
  #     were never examined, so look on through them for the least key (a
  #     {0, 0} ends it: nothing later can beat that), and past them only if
  #     none was legal.
  #
  # At most `Explanation.look_past/0` sets are examined. Running out, or a
  # budget or oracle limit, returns `complete?: false` - the account then
  # names no deciding criterion rather than a guessed one, and the round is
  # never failed for it.
  defp runner_up(rec, _sorted, :end, _best, _residents, _lower, _mode, _base),
    do: {rec, rec.second, true}

  defp runner_up(%{second: second} = rec, _sorted, {:profile, _}, _best, _r, _l, _m, _b)
       when second != nil,
       do: {rec, second, true}

  defp runner_up(rec, sorted, {:profile, index}, best, residents, lower, mode, base),
    do: look_on(rec, Enum.drop(sorted, index), index, best, residents, lower, mode, base)

  defp runner_up(rec, sorted, {:zero, index}, best, residents, lower, mode, base),
    do: look_on(rec, Enum.drop(sorted, index + 1), index + 1, best, residents, lower, mode, base)

  defp look_on(rec, rest, from, best, residents, lower, mode, base) do
    rest
    |> Enum.take(Explanation.look_past() + 1)
    |> Enum.with_index(from)
    |> Enum.reduce_while({rec, true, 0}, fn {{profile, _tpns, set}, index}, {rec, true, seen} ->
      cond do
        profile != best.profile and rec.second != nil ->
          {:halt, {rec, true, seen}}

        seen == Explanation.look_past() ->
          {:halt, {rec, false, seen}}

        true ->
          case guarded(fn ->
                 look_at(rec, profile, set, index, best, residents, lower, mode, base)
               end) do
            {:ok, {:cont, rec}} -> {:cont, {rec, true, seen + 1}}
            {:ok, {:halt, rec}} -> {:halt, {rec, true, seen + 1}}
            :aborted -> {:halt, {rec, false, seen}}
          end
      end
    end)
    |> case do
      {rec, complete?, _seen} -> {rec, rec.second, complete?}
    end
  end

  # One set past the stopping point. A legal set of the winner's profile is
  # ranked by its key; a legal set of a worse profile is the runner-up
  # outright (the walk only gets here when no same-profile set was legal), its
  # [C6]/[C7] left unworked because [C5] already decided.
  defp look_at(rec, profile, set, index, best, residents, lower, mode, base) do
    case legality(residents, lower, set) do
      :legal when profile == best.profile ->
        key = {c6_excess(set, lower, mode, base), c7_previous_floaters(set, base)}
        candidate = %{profile: profile, key: key, set: set, index: index}
        rec = rec |> note_considered(candidate, mode) |> note_second(candidate)
        if key == {0, 0}, do: {:halt, rec}, else: {:cont, rec}

      :legal ->
        candidate = %{profile: profile, key: nil, set: set, index: index}
        {:halt, %{note_considered(rec, candidate, mode) | second: candidate}}

      failed ->
        {:cont, note_rejected(rec, set, failed, mode)}
    end
  end

  # The runner-up search may not fail a round the choice already made.
  defp guarded(fun) do
    {:ok, fun.()}
  rescue
    Matching.LimitError -> :aborted
  catch
    {__MODULE__, :budget_exhausted} -> :aborted
  end

  # OPEN QUESTION 5 ([C5] against the 3.5.4 example) - the reading lives
  # here and nowhere else.
  #
  # 2.3.2: "Minimise the score differences (taken in descending order) in the
  # pairs involving upfloaters, i.e. maximise the scores (taken in ascending
  # order) of the upfloaters." So a set's [C5] quality is its upfloaters'
  # scores sorted ascending, and a lexicographically LARGER list is better.
  # Returned negated so an ascending sort puts the best profile first.
  #
  # This follows the ARTICLE, and the profile is compared only among LEGAL
  # sets (`best_set_of_size/6` never reaches a set that fails
  # `legality/3`). The example under 3.5.4 - 2, 6, 8 on 3 points, 1, 3, 5
  # on 2.5, three upfloaters - says [C5] "determines that two upfloaters must
  # have 3 points and the other 2.5". Under this reading the example is right
  # exactly when {2, 6, 8} cannot be paired with the residents (or strands
  # the rest), which it does not say but does not rule out; when {2, 6, 8}
  # can be, this takes all three.
  #
  # The research note of 2026-09-13 (docs/conformance-c0406-teams.md,
  # "Research findings") settles the reading at medium-high confidence: the
  # identical example is in the 2024 edition and in Double-Swiss C.04.5,
  # both of whose [C5] is the same maximin, and 3.5.2's own note ("This
  # SOMEHOW determines the number of upfloaters in the set and their
  # scores") and Dubov 2026 3.2.1 ("needed to obtain a legal pairing") put
  # legality inside [C4]/[C5]. It is NOT [C6]: 3.5.5 says [C4] and [C5] are
  # met "by construction" before [C6] is consulted, and the 2024 example
  # predates [C6]'s "unless ... empty" clause. Not an SPP ruling; if one says
  # the profile comes from raw scores, this function and `legality/3`'s
  # place in the walk are what change.
  #
  # `0 - score` rather than `-score`: a negated float zero is `-0.0`, which
  # compares equal but is a different term, and the profiles are compared
  # with `!=` in `best_set_of_size/6`.
  defp c5_profile_key(set, mode) do
    set
    |> Enum.map(&Team.score(&1, mode))
    |> Enum.sort()
    |> Enum.map(&(0 - &1))
  end

  # [C6] (2.3.3), as a count to minimise: how many MORE upfloaters than the
  # parity minimum the following scoregroup's bracket would need, given this
  # set. 0 means [C6] is complied with.
  #
  # "Unless all the teams in the following scoregroup became or are
  # upfloaters (thus this scoregroup is now empty), choose the set of
  # upfloaters so that criteria [C1], [C3] and [C4] ... are complied with in
  # the bracket where this (not empty) scoregroup is paired." The following
  # scoregroup is the highest score below the residents; what is left of it
  # after this set floats up will be the residents of the next bracket. [C4]
  # there is "the fewest upfloaters", so the look-ahead finds the fewest that
  # give a bracket pairable under [C1] with everything below it still
  # pairable ([C3]). Only [C1], [C3] and [C4] - not [C5]: the next bracket's
  # upfloaters are not constrained by score for this question.
  #
  # Sets with the same [C5] profile take the same number of teams out of the
  # following scoregroup, so the parity minimum is the same for every set
  # this is compared across, and "excess over it" ranks exactly as "count".
  defp c6_excess(_set, [], _mode, _base), do: 0

  defp c6_excess(set, lower, mode, base) do
    remaining = without(lower, set)
    following_score = lower |> Enum.map(&Team.score(&1, mode)) |> Enum.max()
    {following, below} = Enum.split_with(remaining, &(Team.score(&1, mode) == following_score))

    if following == [] do
      0
    else
      start = rem(length(following), 2)
      limit = Keyword.get(base, :max_upfloater_sets, @default_max_upfloater_sets)

      needed =
        Enum.find(start..length(below)//2, fn count ->
          if binomial(length(below), count) > limit, do: throw({__MODULE__, :budget_exhausted})

          below
          |> combinations(count)
          |> Enum.any?(fn up -> feasible?(following ++ up) and feasible?(without(below, up)) end)
        end)

      # `legality/3` already proved everything below the residents can be
      # paired, so some count works; the fallback is unreachable and ranks
      # worst rather than crashing if it ever is not.
      div((needed || length(lower) + 1) - start, 2)
    end
  end

  # OPEN QUESTION 7 ([C7] as a ranking in 3.5.5) - the reading lives here.
  #
  # 3.5.5 asks for "the first set that ... complies with [C6] and [C7]", and
  # [C7] (2.3.4) is a minimisation: "with the exception of the last two
  # rounds, minimise the number of upfloaters that were floaters in the
  # previous round". Read as a minimisation, a set complies by achieving the
  # least count any legal, [C6]-best set achieves, and among those 3.5.4's
  # order picks the first. That is what `best_set_of_size/6` does with the
  # number this returns.
  #
  # The two readings the SPP question names - rank by [C7] first then take
  # 3.5.4's order, or take the first set in 3.5.4's order that achieves the
  # minimum - choose the SAME set: both are "the lexicographically first
  # among the sets with the least count". The reading that actually differs
  # is the one this engine had before, which applied no [C7] at all and took
  # the first legal set. Making this function return 0 restores that.
  #
  # The research note of 2026-09-13 (docs/conformance-c0406-teams.md,
  # "Research findings") confirms this at high confidence: 2.3 applies the
  # quality criteria "as much as possible ... in descending priority" and
  # 3.5.4's order is only the final tie-break; "the first X that complies
  # with [a minimisation]" is the chapter's standing phrasing (3.6.4, the
  # 2024 edition's 2.2.5); Dubov 2026 3.2.2 says "complies at best"; and the
  # 2026 edition moved floater avoidance up into set selection, which only
  # matters if it can override the lexicographic order. Not an SPP ruling.
  defp c7_previous_floaters(set, base) do
    if Keyword.get(base, :last_two_rounds?, false) do
      0
    else
      Enum.count(set, & &1.floated_last_round?)
    end
  end

  defp feasible?(teams) do
    {mask, adj} = adjacency(teams)
    Matching.feasible?(mask, adj)
  end

  defp without(teams, removed) do
    gone = MapSet.new(removed, & &1.tpn)
    Enum.reject(teams, &MapSet.member?(gone, &1.tpn))
  end

  defp binomial(n, k) when k < 0 or k > n, do: 0
  defp binomial(_n, 0), do: 1

  defp binomial(n, k) do
    k = min(k, n - k)
    Enum.reduce(1..k//1, 1, fn i, acc -> div(acc * (n - k + i), i) end)
  end

  # ---------------------------------------------------------------------
  # Article 4 - colours
  # ---------------------------------------------------------------------

  defp allocate_colours({a_tpn, b_tpn}, teams, numbers, mode, opts, last_round?) do
    by_tpn = Map.new(teams, &{&1.tpn, &1})
    a = Map.fetch!(by_tpn, a_tpn)
    b = Map.fetch!(by_tpn, b_tpn)

    colour_opts = [
      initial_colour: Keyword.get(opts, :initial_colour, :white),
      score_mode: mode,
      use_secondary?: Keyword.get(opts, :use_secondary?, true),
      type: Keyword.get(opts, :type, :a),
      last_round?: last_round?,
      # 4.3.1's parity is taken on this, not on the TPN. Passed rather than
      # derived here: `allocate/3` would otherwise default to numbering the
      # two teams of this board alone, which is the right answer for a
      # two-team tournament and the wrong one inside a real roster.
      parity_numbers: numbers
    ]

    {white, black, rules} = Colour.allocate_explained(a, b, colour_opts)
    {first, _} = Colour.first_team(a, b, mode, Keyword.get(opts, :use_secondary?, true))

    pair = %{
      white: white.tpn,
      black: black.tpn,
      first_team: first.tpn,
      score_difference: abs(Team.score(a, mode) - Team.score(b, mode))
    }

    {pair, rules}
  end

  # ---------------------------------------------------------------------

  # Bitmask adjacency for the completion oracle: index i and j are adjacent
  # when they have not met ([C1]).
  defp adjacency(teams) do
    indexed = Enum.with_index(teams)

    adj =
      Map.new(indexed, fn {team, i} ->
        partners =
          Enum.reduce(indexed, 0, fn {other, j}, mask ->
            if i != j and not Team.met?(team, other.tpn) do
              mask ||| 1 <<< j
            else
              mask
            end
          end)

        {i, partners}
      end)

    {(1 <<< length(teams)) - 1, adj}
  end

  defp combinations(_list, 0), do: [[]]
  defp combinations([], _n), do: []

  defp combinations([h | t], n) do
    Enum.map(combinations(t, n - 1), &[h | &1]) ++ combinations(t, n)
  end
end
