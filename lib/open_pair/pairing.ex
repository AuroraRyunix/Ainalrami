defmodule OpenPair.Pairing do
  @moduledoc """
  The actual Dutch-system pairing algorithm. Implemented incrementally —
  see TODO.md for the staged plan and its documented simplifications
  (`pair_next_round/1`'s doc lists exactly which parts of the real FIDE
  procedure aren't faithfully implemented yet).

  A pairing is represented as `{white_rank, black_rank | nil}` — `nil` for
  a pairing-allocated bye, the same convention `OpenPair.Trf`'s parsed game
  records use (`opponent_rank: nil`), rather than JaVaFo's own text-output
  convention of a literal `0` (that translation happens only at the
  CLI/output-formatting boundary).

  A player is `%{rank:, points:, games: [%{opponent_rank:, colour:, result:}]}`
  — the shape `OpenPair.Trf.parse/1` returns.
  """

  alias OpenPair.Matching

  @doc """
  Pairs the next round, dispatching to `pair_round_one/1` when no game
  history exists yet, or the bracket cascade below otherwise.
  """
  def pair_next_round(players) do
    if Enum.all?(players, &(&1.games == [])) do
      pair_round_one(players)
    else
      pair_later_round(players)
    end
  end

  @doc """
  Pairs the very first round.

  Per FIDE C.04.3 Article 1: split the full field into two equal halves by
  rank (S1 = top half, S2 = bottom half — everyone is tied on 0 points, so
  rank order alone determines the split); an odd field first removes the
  lowest-ranked player for the pairing-allocated bye, then splits the
  remaining even field. Pair S1[i] against S2[i].

  Confirmed against real `javafo.jar` output for 7/8/9/10/11/12/13-player
  fields, not assumed from the spec text alone.

  Colours (Article 5.1/5.2.5): FIDE leaves the very first colour to a
  literal "drawing of lots" — there is no deterministic rule to replicate.
  This picks a fixed, documented convention rather than JaVaFo's own
  choice, which is empirically NOT a function of the roster/round-count
  alone: pairing the identical 8-player roster and round count under two
  different tournament *names* produced opposite initial colours from
  JaVaFo — strong evidence it's seeded from something incidental (a hash
  of the input file, most likely), not a reproducible rule. Colour output
  will legitimately not always match JaVaFo's own for this reason; pairing
  *composition* (who plays whom) is the thing that should match, and does
  — see the comparison harness in `test/open_pair/javafo_comparison_test.exs`.
  """
  def pair_round_one(players) do
    sorted = Enum.sort_by(players, & &1.rank)

    {bye, field} =
      if rem(length(sorted), 2) == 1 do
        {List.last(sorted), List.delete_at(sorted, -1)}
      else
        {nil, sorted}
      end

    half = div(length(field), 2)
    {s1, s2} = Enum.split(field, half)

    pairs =
      s1 |> Enum.zip(s2) |> Enum.map(fn {top, bottom} -> assign_colour_round_one(top, bottom) end)

    if bye, do: pairs ++ [{bye.rank, nil}], else: pairs
  end

  # `top` is always the better-ranked (lower rank number) of the pair, since
  # both halves are traversed in ascending rank order before zipping.
  #
  # Our fixed initial-colour convention is White — an odd rank for the
  # better-ranked player gets White (the initial colour), an even rank gets
  # Black (the opposite). If this convention ever needs to be the other way
  # round, flip the branches here directly rather than reintroducing a
  # switchable constant — with only one convention ever in use, that
  # abstraction was dead code the compiler rightly flagged.
  defp assign_colour_round_one(top, bottom) do
    if rem(top.rank, 2) == 1 do
      {top.rank, bottom.rank}
    else
      {bottom.rank, top.rank}
    end
  end

  @doc """
  Pairs a round from existing score/game history.

  Forms score brackets (Article 1.2: ranked by score, then TPN ascending)
  in descending order and pairs bracket by bracket, floating players down
  to merge with the next bracket when a bracket can't be fully paired
  (Articles 1.3.3/3.2/3.3 — a "heterogeneous" bracket, floaters ranked
  ahead of the new bracket's own residents per their higher score, which
  falls out of re-sorting the merged group by Article 1.2 directly).

  **Known simplifications versus the full FIDE procedure** — documented,
  not hidden, and not yet cross-checked against `javafo.jar` at the same
  scale round 1 was (see TODO.md):

    * Pairing within a bracket uses `OpenPair.Matching`'s general
      (non-bipartite) maximum-weight matching, scored by
      `pair_weight/2`/`float_weight/1` — a curated set of criteria (no
      rematches, colour-preference satisfaction, rank spread, floating
      the worst-ranked player when a choice exists) rather than FIDE's
      own specific transposition/exchange search (Articles 3.3-3.5) or
      bbpPairings'/JaVaFo's own full bit-packed criteria list
      (float-history minimisation, among others). See `pair_weight/2`'s
      doc for exactly what's scored and in what priority order.
    * The "no player receives the pairing-allocated bye twice" absolute
      criterion (Article 1's C2) isn't enforced — floating doesn't check
      bye history at all yet.

  This went through two earlier, real-comparison-driven revisions before
  landing here (see TODO.md for the full history, worth reading before
  changing this again): an unrestricted exhaustive backtracking search
  with no bound on redundant re-exploration (confirmed to take 194ms at
  12 players and not finish within 60 seconds at 16), then a *bipartite*
  reformulation (split each bracket into a better/worse half, pair only
  across the split) that fixed the hang but was confirmed WRONG at scale
  (10.7% match against real `javafo.jar` over 2000 random histories,
  including a regression on a case that matched exactly before) — real
  FIDE-family pairing engines don't hard-restrict to that split, per
  bbpPairings' own source. The current version restores general
  (non-bipartite) matching, keeping it tractable via memoization
  (`OpenPair.Matching`) instead of via a structural restriction that
  turned out to be incorrect.
  """
  def pair_later_round(players) do
    brackets =
      players
      |> Enum.group_by(& &1.points)
      |> Enum.sort_by(fn {score, _} -> -score end)
      |> Enum.map(fn {_score, members} -> members end)

    {pairs, leftover} = cascade_brackets(brackets, [], [])

    pairs ++ Enum.map(leftover, &{&1.rank, nil})
  end

  defp cascade_brackets([], floaters, pairs), do: {pairs, floaters}

  defp cascade_brackets([residents | rest], floaters, pairs) do
    bracket = (floaters ++ residents) |> Enum.sort_by(&{-&1.points, &1.rank})
    {new_pairs, unpaired} = pair_bracket(bracket)
    # Stamped on the way OUT, not the way in: `unpaired` mixes players who
    # already carried the flag (floated into THIS bracket from above) with
    # ones floating for the first time (this bracket's own residents) —
    # both must enter the NEXT bracket already marked, so `float_weight/1`
    # can tell "floated already" from "floating for the first time" at
    # every level, not just the first.
    marked_unpaired = Enum.map(unpaired, &Map.put(&1, :already_floated, true))
    cascade_brackets(rest, marked_unpaired, pairs ++ new_pairs)
  end

  defp pair_bracket(ranked) do
    {pairs, floaters} = Matching.max_weight_matching(ranked, &pair_weight/2, &float_weight/1)
    {Enum.map(pairs, &assign_colour_with_history/1), floaters}
  end

  # `nil` (infeasible) for a rematch — the absolute criterion `Matching`
  # can never violate. Otherwise: colour-preference satisfaction first
  # (see `pair_later_round/1`'s doc for why, and the TODO.md entry this
  # came from), then the widest rank spread as a tie-break, mimicking the
  # natural top-half-vs-bottom-half structure over incidentally pairing
  # two closely-ranked players when a wider legal option was equally
  # colour-optimal. The colour term is multiplied well above any possible
  # rank-spread value so it always dominates regardless of roster size.
  defp pair_weight(a, b) do
    if legal_pair?(a, b) do
      colour_bonus = if complementary_preference?(a, b), do: 1, else: 0
      colour_bonus * 100_000 + abs(a.rank - b.rank)
    end
  end

  # Deeply negative so any legal pairing (see `pair_weight/2`, always >= 0)
  # is preferred over floating anyone — floating only ever happens when a
  # player has no legal partner left in the bracket at all. `player.rank`
  # is added (not subtracted) so a WORSE-ranked (higher-numbered) player's
  # float weight is less negative, i.e. preferred, whenever the matcher
  # has an actual choice of who floats.
  #
  # A player who already floated into this bracket from a higher one
  # (`:already_floated`, stamped by `cascade_brackets/3`) gets a much more
  # negative base — confirmed against a real `javafo.jar` disagreement
  # (two bracket levels down, both engines agreed exactly one player had
  # to float twice, but picked a different one): javafo strongly prefers
  # floating a bracket's own fresh resident over floating the same player
  # down two levels in a row when a choice exists, matching bbpPairings'
  # own "minimise downfloaters" quality criterion (`dutch.cpp`).
  defp float_weight(player) do
    base = if Map.get(player, :already_floated, false), do: -20_000_000, else: -10_000_000
    base + player.rank
  end

  defp complementary_preference?(a, b) do
    pref_a = colour_preference(a)
    pref_b = colour_preference(b)
    pref_a != nil and pref_b != nil and pref_a != pref_b
  end

  # A player's colour preference is simply the opposite of their own most
  # recent coloured game — see `assign_colour_with_history/1`'s doc on why
  # this is a simplified stand-in for FIDE's full preference-strength
  # computation (absolute/strong/mild preference from accumulated colour
  # imbalance and repeated colours), not the real thing. Games carry
  # colour as "w"/"b" (`OpenPair.Trf`'s own convention), not atoms.
  defp colour_preference(player) do
    case last_colour(player) do
      "w" -> "b"
      "b" -> "w"
      nil -> nil
    end
  end

  defp legal_pair?(p1, p2), do: not Enum.any?(p1.games, &(&1.opponent_rank == p2.rank))

  # Grants each player's colour preference (opposite of their own most
  # recent coloured game) when they're complementary; falls back to the
  # round-1 fixed convention when there's a genuine clash (both "want" the
  # same colour) or neither has a colour history yet (e.g. a late entrant
  # paired for the first time in a later round).
  defp assign_colour_with_history({a, b}) do
    case {colour_preference(a), colour_preference(b)} do
      {"w", "b"} ->
        {a.rank, b.rank}

      {"b", "w"} ->
        {b.rank, a.rank}

      _ ->
        # assign_colour_round_one/2 expects {better_ranked, worse_ranked}.
        {top, bottom} = if a.rank < b.rank, do: {a, b}, else: {b, a}
        assign_colour_round_one(top, bottom)
    end
  end

  defp last_colour(player) do
    player.games |> Enum.reverse() |> Enum.find_value(& &1.colour)
  end
end
