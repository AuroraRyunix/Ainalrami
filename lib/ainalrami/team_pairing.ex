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

  alias Ainalrami.TeamPairing.{Bracket, Colour, Matching, Team}

  import Bitwise

  @doc """
  Pairs one round.

  Returns `{:ok, %{pairs: [...], bye: tpn | nil, brackets: [...]}}` or
  `{:error, reason}`.

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
    * `:round` / `:expected_rounds` - both optional; together they decide
      "the last two rounds", which switch off [C7] and [C10], and "the last
      round", which switches off Type B mild preferences. Given neither, the
      engine assumes it is NOT near the end - the conservative choice, since
      it keeps criteria switched on.
    * `:max_candidates` - per-bracket search budget (see
      `Ainalrami.TeamPairing.Bracket`).

  ## Why it returns brackets too

  `brackets` reports what the procedure actually did - which teams formed
  each bracket, who upfloated into it, how many candidates 3.6 examined and
  whether that search was exhaustive. An arbiter asked to justify a pairing
  needs the bracket structure, not just the boards, and reconstructing it
  from the finished pairs is guesswork. This is the same reason the
  individual engine grew `explain_round/3`.
  """
  def pair_round(teams, opts \\ []) when is_list(teams) do
    mode = Keyword.get(opts, :score_mode, :match_points)
    round = Keyword.get(opts, :round)
    expected = Keyword.get(opts, :expected_rounds)

    last_round? = not is_nil(round) and not is_nil(expected) and round >= expected
    last_two? = not is_nil(round) and not is_nil(expected) and round >= expected - 1

    base = [
      type: Keyword.get(opts, :type, :a),
      last_round?: last_round?,
      last_two_rounds?: last_two?,
      max_candidates: Keyword.get(opts, :max_candidates, 200_000)
    ]

    with {:ok, bye, rest} <- assign_bye(teams, mode),
         {:ok, brackets} <- pair_brackets(rest, mode, base) do
      pairs =
        brackets
        |> Enum.flat_map(& &1.pairs)
        |> Enum.map(&allocate_colours(&1, teams, mode, opts, last_round?))

      {:ok, %{pairs: pairs, bye: bye && bye.tpn, brackets: brackets}}
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
    if rem(length(teams), 2) == 0 do
      {:ok, nil, teams}
    else
      eligible = Enum.reject(teams, &Team.pab_ineligible?/1)

      ordered =
        Enum.sort_by(eligible, fn t ->
          {Team.score(t, mode), -Team.matches_played(t), -t.tpn}
        end)

      case Enum.find(ordered, &leaves_legal_pairing?(&1, teams)) do
        nil ->
          # 3.3.3: "If it is impossible to complete a round-pairing, the
          # Chief Arbiter shall decide what to do." The engine's job is to
          # say so clearly, not to invent a rule.
          {:error, :no_legal_bye}

        team ->
          {:ok, team, Enum.reject(teams, &(&1.tpn == team.tpn))}
      end
    end
  end

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

  defp pair_brackets(teams, mode, base) do
    do_pair_brackets(teams, mode, base, [])
  end

  defp do_pair_brackets([], _mode, _base, acc), do: {:ok, Enum.reverse(acc)}

  defp do_pair_brackets(remaining, mode, base, acc) do
    # 3.2 - the top-scoregroup is the highest score among teams yet to pair.
    top_score = remaining |> Enum.map(&Team.score(&1, mode)) |> Enum.max()
    residents = Enum.filter(remaining, &(Team.score(&1, mode) == top_score))
    lower = Enum.reject(remaining, &(Team.score(&1, mode) == top_score))

    case select_upfloaters(residents, lower, mode, base) do
      {:ok, upfloaters} ->
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

            do_pair_brackets(still_left, mode, base, [entry | acc])

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

  [C4] and [C5] are satisfied *by construction* rather than searched for:
  the count is forced (a bracket must be even, so it is 0 or 1 more than
  parity demands... see below), and [C5] fixes which scores the upfloaters
  must have. Only then does 3.5.4's order over the remaining freedom matter.

  ## What [C4] actually forces

  The bracket must be even (1.3.2). A scoregroup with an even number of
  residents needs no upfloaters at all - and [C4] says minimise, so it takes
  none. An odd one needs at least one. It can need more than one only when
  the smaller count admits no legal pairing, which is why this returns the
  first *workable* count rather than assuming the minimum works.
  """
  def select_upfloaters(residents, lower, mode, base \\ [])

  def select_upfloaters(residents, _lower, _mode, _base) when rem(length(residents), 2) == 0,
    do: {:ok, []}

  def select_upfloaters(_residents, [], _mode, _base), do: {:error, :no_upfloaters_available}

  def select_upfloaters(residents, lower, mode, base) do
    # [C4]: try 1 upfloater, then 3, then 5... Parity means the count must be
    # odd when the residents are odd. Growing by two rather than one is not
    # an optimisation, it is the only way the bracket stays even.
    max_count = length(lower)

    1..max_count//2
    |> Enum.reduce_while({:error, :no_legal_upfloater_set}, fn count, _acc ->
      case upfloater_sets(lower, count, mode) do
        [] ->
          {:cont, {:error, :no_legal_upfloater_set}}

        sets ->
          case Enum.find(sets, &workable?(residents, &1, base)) do
            nil -> {:cont, {:error, :no_legal_upfloater_set}}
            set -> {:halt, {:ok, set}}
          end
      end
    end)
  end

  # 3.5.2 with [C5], then 3.5.3 and 3.5.4.
  #
  # [C5] - "minimise the score differences (taken in descending order) in the
  # pairs involving upfloaters, i.e. maximise the scores (taken in ascending
  # order) of the upfloaters" - fixes the multiset of SCORES the set must
  # have: the highest available. The regulation's own example makes this
  # concrete: with 2,6,8 on 3 points and 1,3,5 on 2.5, a set of three must
  # take two 3-pointers and one 2.5-pointer. So the score profile is
  # computed first, and only teams matching it are combined.
  defp upfloater_sets(lower, count, mode) do
    sorted = Enum.sort_by(lower, fn t -> {-Team.score(t, mode), t.tpn} end)
    profile = sorted |> Enum.take(count) |> Enum.map(&Team.score(&1, mode))

    profile
    |> Enum.frequencies()
    |> Enum.map(fn {score, n} ->
      lower
      |> Enum.filter(&(Team.score(&1, mode) == score))
      |> Enum.sort_by(& &1.tpn)
      |> combinations(n)
    end)
    |> cartesian()
    |> Enum.map(fn groups ->
      groups
      |> List.flatten()
      # 3.5.3 - within a set: descending score, then ascending TPN.
      |> Enum.sort_by(fn t -> {-Team.score(t, mode), t.tpn} end)
    end)
    # 3.5.4 - between sets: lexicographic by their TPNs.
    |> Enum.sort_by(fn set -> Enum.map(set, & &1.tpn) end)
  end

  # 3.5.5 - the set must produce a legal pairing, and comply with [C6] and
  # [C7].
  #
  # [C6] (2.3.3) is the only criterion that reaches FORWARD: unless the
  # following scoregroup is emptied by the upfloating, the set must be chosen
  # so that [C1], [C3] and [C4] can still be met in the bracket where that
  # scoregroup is paired. Checked here as a feasibility question about what
  # would be left, which is what it is.
  #
  # [C7] (2.3.4) - minimise upfloaters that were floaters in the previous
  # round - is a minimisation, so it cannot be a yes/no on one set. It is
  # applied in `select_upfloaters/4` by preferring, among sets that pass this
  # gate, the one 3.5.4's order reaches first; the ordering below is 3.5.4's
  # and this predicate is the gate. A stricter reading would rank sets by
  # their [C7] count first; that is recorded as an open question in
  # docs/conformance-c0406-teams.md rather than guessed at here.
  defp workable?(residents, set, _base) do
    bracket = residents ++ set
    {mask, adj} = adjacency(bracket)
    Matching.feasible?(mask, adj)
  end

  # ---------------------------------------------------------------------
  # Article 4 - colours
  # ---------------------------------------------------------------------

  defp allocate_colours({a_tpn, b_tpn}, teams, mode, opts, last_round?) do
    by_tpn = Map.new(teams, &{&1.tpn, &1})
    a = Map.fetch!(by_tpn, a_tpn)
    b = Map.fetch!(by_tpn, b_tpn)

    colour_opts = [
      initial_colour: Keyword.get(opts, :initial_colour, :white),
      score_mode: mode,
      use_secondary?: Keyword.get(opts, :use_secondary?, true),
      type: Keyword.get(opts, :type, :a),
      last_round?: last_round?
    ]

    {white, black} = Colour.allocate(a, b, colour_opts)
    {first, _} = Colour.first_team(a, b, mode, Keyword.get(opts, :use_secondary?, true))

    %{
      white: white.tpn,
      black: black.tpn,
      first_team: first.tpn,
      score_difference: abs(Team.score(a, mode) - Team.score(b, mode))
    }
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

  defp cartesian([]), do: [[]]

  defp cartesian([head | rest]) do
    for h <- head, r <- cartesian(rest), do: [h | r]
  end
end
