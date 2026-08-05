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

    * Within a bracket, this finds *a* maximum legal matching (preferring
      the natural top-half-vs-bottom-half structure first, only deviating
      to avoid a rematch or an odd bracket size) via a greedy
      pair-or-float search with one level of lookahead per player, not a
      true global maximum-matching search — not necessarily FIDE's own
      canonically-preferred pairing among several equally-legal options.
      Replicating that exactly means implementing the specific
      transposition/exchange search order Articles 3.3-3.5 specify, which
      this doesn't attempt. See `match_bracket/1`'s doc for the exact
      trade-off.
    * Colour is a simple "alternate from your own last game" rule, not
      the full preference-strength computation in Article 5.2.1/5.2.2 —
      reasonable given colour isn't the thing under test (see
      `pair_round_one/1`'s doc on why colour-matching JaVaFo exactly isn't
      a goal even for round 1).
    * The "no player receives the pairing-allocated bye twice" absolute
      criterion (Article 1's C2) isn't enforced — the floating/bye logic
      here doesn't check bye history at all yet.
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
    cascade_brackets(rest, unpaired, pairs ++ new_pairs)
  end

  # The common case first: if the plain top-half-vs-bottom-half split (same
  # structure round 1 uses) is already fully legal, skip the search
  # entirely — this is what most brackets hit, and the general search below
  # is the expensive path only a real rematch conflict or an odd bracket
  # size should ever reach.
  defp pair_bracket(ranked) do
    {pairs, unpaired} =
      case natural_split_pairing(ranked) do
        {:ok, pairs} -> {pairs, []}
        nil -> match_bracket(ranked)
      end

    {Enum.map(pairs, &assign_colour_with_history/1), unpaired}
  end

  defp natural_split_pairing(players) when rem(length(players), 2) != 0, do: nil

  defp natural_split_pairing(players) do
    half = div(length(players), 2)
    {s1, s2} = Enum.split(players, half)
    pairs = Enum.zip(s1, s2)

    if Enum.all?(pairs, fn {a, b} -> legal_pair?(a, b) end), do: {:ok, pairs}, else: nil
  end

  # General search: the largest legal matching within this bracket, i.e.
  # the fewest players left unpaired (floating to the next bracket) — and
  # among equally-sized matchings, the one whose unpaired set is the
  # worst-ranked available, since floating a stronger player when a
  # weaker one could have floated instead has no justification and FIDE's
  # own quality criteria bias toward keeping better-ranked players paired
  # within their own bracket.
  #
  # This tries EVERY legal partner for `p` (not just the first one that
  # happens to lead somewhere), recursively solving the rest for each, and
  # keeps whichever choice (pairing p with some partner, or floating p)
  # scores best by `unpaired_score/1` below — real backtracking, not a
  # greedy first-fit. It's still not a true global maximum-matching search
  # (each level commits to its own player's best local choice without
  # revisiting once a deeper level reveals a better structure elsewhere),
  # so it isn't guaranteed to find THE maximum matching in every possible
  # bracket, and even when it does, not necessarily FIDE's own
  # canonically-preferred one among several equally-sized options — see
  # `pair_later_round/1`'s doc. Good enough for the bracket sizes a real
  # tournament produces.
  defp match_bracket([]), do: {[], []}

  defp match_bracket([p | rest]) do
    {pairs_without, unpaired_without} = match_bracket(rest)
    without = {pairs_without, [p | unpaired_without]}

    candidates =
      rest
      |> Enum.filter(&legal_pair?(p, &1))
      |> Enum.map(fn partner ->
        {pairs, unpaired} = match_bracket(List.delete(rest, partner))
        {[{p, partner} | pairs], unpaired}
      end)

    Enum.min_by([without | candidates], &option_score/1)
  end

  # Fewer unpaired first; among equal counts, prefer the option whose
  # unpaired players have the HIGHEST rank numbers (i.e. are the
  # worst-ranked available) — the negated rank sum makes a higher-ranked
  # (worse) unpaired set sort as "smaller", so `Enum.min_by` picks it. A
  # third tie-break, only reached when two options leave the exact same
  # players unpaired (typically both leave nobody unpaired at all —
  # several different complete matchings can exist): prefer the option
  # whose formed pairs have the LARGEST total rank distance, matching the
  # natural top-half-vs-bottom-half structure (which pairs far-apart
  # ranks) over one that incidentally pairs two closely-ranked players
  # together when a wider legal option was also available.
  defp option_score({pairs, unpaired}) do
    {length(unpaired), -Enum.sum(Enum.map(unpaired, & &1.rank)), -pair_spread(pairs)}
  end

  defp pair_spread(pairs), do: Enum.sum(Enum.map(pairs, fn {a, b} -> abs(a.rank - b.rank) end))

  defp legal_pair?(p1, p2), do: not Enum.any?(p1.games, &(&1.opponent_rank == p2.rank))

  # Alternates each player from their own most recent coloured game;
  # falls back to the round-1 fixed convention when there's a genuine
  # clash (both "want" the same colour) or neither has a colour history
  # yet (e.g. a late entrant paired for the first time in a later round).
  defp assign_colour_with_history({a, b}) do
    case {last_colour(a), last_colour(b)} do
      {:white, :black} ->
        {b.rank, a.rank}

      {:black, :white} ->
        {a.rank, b.rank}

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
