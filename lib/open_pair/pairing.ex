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

  Pairing within a bracket is a general (non-bipartite) maximum-weight
  matching over that bracket (`OpenPair.Matching`), scored by
  `pair_weight/3` and `float_weight/1`. **99.75% composition match against
  real `javafo.jar`** over 2,000 random round-1 outcomes — see TODO.md for
  the measured history of how each scoring term got there.

  **Known simplifications versus the full FIDE procedure**:

    * The scoring terms are a curated set (no rematches, colour-preference
      satisfaction, MDP displacement, rank spread, float protection)
      rather than FIDE's own transposition/exchange search (Articles
      3.3-3.5) or bbpPairings'/JaVaFo's full bit-packed criteria list.
      Notably absent: the float-history criteria that look two rounds
      back, which almost certainly accounts for part of the remaining
      0.25%.
    * The "no player receives the pairing-allocated bye twice" absolute
      criterion (Article 1's C2) isn't enforced.

  **Do not "simplify" the scoring terms without re-measuring** — three
  separate plausible-sounding changes here were each measured WORSE and
  reverted (see TODO.md): a bipartite S1-vs-S2 restriction (10.7%), and
  replacing the rank-spread tie-break with a whole-bracket
  natural-correspondence deviation metric, which was retested after every
  other fix landed and still measured 64.95% against this version's
  99.75%. The terms below are empirical, not derived.
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
    natural = natural_partner_map(ranked)

    indexed =
      ranked
      |> Enum.with_index()
      |> Enum.map(fn {p, i} ->
        p |> Map.put(:bracket_pos, i) |> Map.put(:colour_stats, colour_stats(p))
      end)

    {pairs, floaters} =
      Matching.max_weight_matching(
        indexed,
        &pair_weight(&1, &2, natural, spans(indexed)),
        &float_weight/1
      )

    {Enum.map(pairs, &assign_colour_with_history/1), floaters}
  end

  # Upper bounds for the two non-boolean criteria, so `ranked/1` can pack
  # them without one bleeding into the next. Computed per bracket rather
  # than as global constants because both are bounded by the bracket, and
  # a fixed constant that's too small silently corrupts the ordering.
  defp spans(indexed) do
    %{
      deviation: length(indexed) + 1,
      spread: Enum.max(Enum.map(indexed, & &1.rank)) + 1
    }
  end

  # The pairing each bracket would get with no constraints at all, as a
  # position -> position involution — what Articles 3.2/3.3 call pairing
  # S1[i] against S2[i]. Everything else is scored as deviation from this
  # (see `pair_weight/3`), so getting the S1/S2 split itself right matters
  # more than any tie-break on top of it.
  #
  # The split is NOT simply "top half vs bottom half" in general. That's
  # only the homogeneous case (every player on the same score). A
  # HETEROGENEOUS bracket — one that floaters (moved-down players, MDPs)
  # joined from a higher score group — puts the MDPs alone in S1 and ALL
  # the residents in S2 (Article 3.3.1): the MDPs pair against the
  # best-ranked residents first, and only the residents left over
  # ("the remainder", Article 3.3.3) then split into halves among
  # themselves. Confirmed against real `javafo.jar`: an 8-player bracket
  # of one MDP + seven residents paired the MDP with the FIRST resident
  # whose colour preference was compatible, not with the resident a
  # half-split would have given it.
  defp natural_partner_map(ranked) do
    n = length(ranked)
    resident_score = ranked |> Enum.map(& &1.points) |> Enum.min()
    mdp_count = Enum.count(ranked, &(&1.points > resident_score))

    if mdp_count > 0 and 2 * mdp_count <= n do
      mdp_map = for i <- 0..(mdp_count - 1), into: %{}, do: {i, mdp_count + i}
      inverse = for {k, v} <- mdp_map, into: %{}, do: {v, k}

      mdp_map
      |> Map.merge(inverse)
      |> Map.merge(half_split_map(2 * mdp_count, n - 2 * mdp_count))
      |> Map.put(:mdp_count, mdp_count)
    else
      Map.put(half_split_map(0, n), :mdp_count, 0)
    end
  end

  defp half_split_map(_offset, count) when count < 2, do: %{}

  defp half_split_map(offset, count) do
    half = div(count, 2)

    Enum.reduce(0..(half - 1), %{}, fn i, acc ->
      a = offset + i
      b = offset + half + i
      acc |> Map.put(a, b) |> Map.put(b, a)
    end)
  end

  # `nil` (infeasible) for a rematch — the absolute criterion `Matching`
  # can never violate. Otherwise: colour-preference satisfaction first
  # (see `pair_later_round/1`'s doc for why), then the SMALLEST deviation
  # from the bracket's natural S1[i]-vs-S2[i] correspondence (see
  # `natural_partner_map/1`).
  #
  # That deviation term replaced an earlier "prefer the widest rank
  # spread" tie-break, which was a guess extrapolated from round 1's own
  # top-half-vs-bottom-half shape and produced real disagreements with
  # `javafo.jar`. FIDE's actual procedure (Articles 3.3-3.5) works by
  # applying the SMALLEST transposition of the natural order that
  # satisfies the criteria — so when several pairings all satisfy colour
  # equally, the one closest to the natural correspondence wins, which is
  # not the same thing as the widest-spread one. Both cases that
  # originally exposed this (a clean 4-player bracket, and an 8-player
  # heterogeneous one) are explained by this rule and were not explained
  # by the spread rule.
  defp pair_weight(a, b, %{mdp_count: mdp_count} = natural, spans) do
    if legal_pair?(a, b) do
      # bbpPairings passes (higherPlayer, lowerPlayer) by bracket order, and
      # the absolute-preference tie-break in `colour_criteria/2` is not
      # symmetric in the two, so the roles have to be assigned the same way
      # here rather than taking `a`/`b` as the matcher happens to give them.
      {higher, lower} = if a.bracket_pos <= b.bracket_pos, do: {a, b}, else: {b, a}
      {c1, c2, c3, c4} = colour_criteria(higher, lower)
      deviation = mdp_deviation(a, b, natural, mdp_count)

      ranked([
        {bit(c1), 2},
        {bit(c2), 2},
        {bit(c3), 2},
        {bit(c4), 2},
        {spans.deviation - 1 - deviation, spans.deviation},
        {abs(a.rank - b.rank), spans.spread}
      ])
    end
  end

  # Pack ranked criteria, highest priority first, the same way bbpPairings'
  # `computeEdgeWeight` does with successive left-shifts: each criterion is
  # worth more than every lower-priority criterion combined, so a better
  # value on an earlier term can never be outvoted by later ones. Passing
  # explicit spans rather than hard-coded decimal magnitudes is what makes
  # that guarantee hold — the previous `* 1_000_000` / `* 1_000` scheme was
  # only safe as long as nobody looked at a bracket big enough to overflow
  # the gap between two of its terms.
  defp ranked(components) do
    Enum.reduce(components, 0, fn {value, span}, acc -> acc * span + value end)
  end

  defp bit(true), do: 1
  defp bit(false), do: 0

  # Deviation from the natural correspondence, applied ONLY to pairs that
  # involve a moved-down player in a heterogeneous bracket (Article 3.3.1's
  # "M1 MDPs from S1 against M1 residents from S2"). Measured and weighted
  # separately from the general rank-spread tie-break below it because the
  # two genuinely disagree, and only this one is confirmed: replacing the
  # spread tie-break with a whole-bracket version of this deviation metric
  # was measured at 33.9% against real `javafo.jar` versus the spread
  # rule's 66.24% on the identical 2,000-history comparison set, so the
  # general case keeps spread. Restricting the deviation term to MDP pairs
  # is what actually fixed the traced heterogeneous-bracket cases (seeds 1
  # and 5) without giving that back.
  defp mdp_deviation(_a, _b, _natural, 0), do: 0

  defp mdp_deviation(a, b, natural, mdp_count) do
    i = a.bracket_pos
    j = b.bracket_pos

    # Measured from the MDP's side ONLY, not summed symmetrically over
    # both. Summing both sides made genuinely different options tie: for a
    # single MDP at position 0 whose natural partner is position 1,
    # pairing it with position 2 scored |2-1| + |0-natural[2]| and pairing
    # it with position 5 scored |5-1| + |0-natural[5]| — both 6, because
    # the resident's own half-split partner distance drowned out the MDP's.
    # The resident's natural partner is irrelevant here: Article 3.3.1's
    # rule is about which resident the MDP takes, so only the MDP's own
    # displacement counts.
    cond do
      i < mdp_count -> abs(j - Map.get(natural, i, j))
      j < mdp_count -> abs(i - Map.get(natural, j, i))
      true -> 0
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
  #
  # A player who already has an unplayed round in their history (a bye, or
  # a forfeit) is also strongly protected from downfloating — traced from a
  # real `javafo.jar` disagreement on a 3-player top bracket
  # {1, 2, 7} where 7 had taken round 1's bye: the natural S1/S2 split
  # pairs 1-2 and floats the worst-ranked player (7), which is what this
  # engine did, but javafo paired 1-7 and floated 2 instead. Colour
  # satisfaction was identical either way, so the bye history is the only
  # thing distinguishing the two players.
  defp float_weight(player) do
    base = if Map.get(player, :already_floated, false), do: -20_000_000, else: -10_000_000
    base - unplayed_rounds(player) * 1_000 + player.rank
  end

  defp unplayed_rounds(player) do
    Enum.count(player.games, &is_nil(&1.opponent_rank))
  end

  # A player's full colour state, ported from bbpPairings'
  # `tournament.cpp` `computePlayerData`. This replaces a one-line
  # stand-in ("preference is the opposite of your last colour") that was
  # only ever right for round 2, which is exactly why round 2 measured
  # 99.85% and round 3 fell off a cliff: after two games a player can be
  # two colours out of balance, or have had the same colour twice running,
  # and both produce an ABSOLUTE preference that the old rule couldn't
  # represent at all.
  #
  # Unplayed games (byes, forfeits) are excluded entirely — they carry no
  # colour and must not break a run of repeated colours either.
  defp colour_stats(player) do
    played = Enum.filter(player.games, &(&1.colour in ["w", "b"]))
    whites = Enum.count(played, &(&1.colour == "w"))
    blacks = Enum.count(played, &(&1.colour == "b"))
    imbalance = abs(whites - blacks)
    consecutive = trailing_run(played)

    last =
      case List.last(played) do
        nil -> nil
        game -> game.colour
      end

    # Ties go to White, matching bbpPairings' own `gamesAsWhite >
    # gamesAsBlack ? BLACK : WHITE` — not a coin flip.
    lower_colour = if whites > blacks, do: "b", else: "w"

    # The ladder's order matters: an imbalance of 2+ outranks a repeated
    # colour, which outranks an imbalance of 1, which outranks plain
    # alternation.
    preference =
      cond do
        imbalance > 1 -> lower_colour
        consecutive > 1 -> invert(last)
        imbalance > 0 -> lower_colour
        consecutive > 0 -> invert(last)
        true -> nil
      end

    repeated = if consecutive > 1, do: last, else: nil
    absolute_imbalance? = imbalance > 1
    absolute? = absolute_imbalance? or not is_nil(repeated)

    %{
      preference: preference,
      imbalance: imbalance,
      repeated: repeated,
      absolute_imbalance?: absolute_imbalance?,
      absolute?: absolute?,
      strong?: not absolute? and imbalance > 0
    }
  end

  # How many games at the END of the list share the same colour.
  defp trailing_run([]), do: 0

  defp trailing_run(played) do
    [last | earlier] = Enum.reverse(played)
    1 + Enum.count(Enum.take_while(earlier, &(&1.colour == last.colour)))
  end

  defp invert("w"), do: "b"
  defp invert("b"), do: "w"
  defp invert(nil), do: nil

  # The four separately-ranked colour criteria of bbpPairings'
  # `insertColorBits`, in its own priority order (highest first). The old
  # engine had only the third of these — a single "are the preferences
  # compatible" boolean — which cannot distinguish a clash between two
  # absolute preferences (near-unpairable) from a clash between two mild
  # ones (a routine tie-break). All four sit ABOVE every float-history
  # criterion in bbpPairings' bit layout, so colour errors dominate float
  # errors whenever the two disagree.
  defp colour_criteria(higher, lower) do
    p = lower.colour_stats
    o = higher.colour_stats
    clash? = not is_nil(p.preference) and p.preference == o.preference

    {
      not (p.absolute_imbalance? and o.absolute_imbalance? and clash?),
      not (p.absolute? and o.absolute? and clash?) or absolute_tiebreak(p, o),
      not clash?,
      (not p.strong? and not p.absolute?) or (not o.strong? and not o.absolute?) or
        (p.absolute? and o.absolute?) or not clash?
    }
  end

  # Reached only when both players hold an absolute preference for the SAME
  # colour, i.e. one of them is definitely going to be denied. It decides
  # which such clash is the least bad: prefer the one where the player who
  # is *less* out of balance isn't the one whose repeated colour would be
  # extended.
  defp absolute_tiebreak(p, o) do
    if p.imbalance == o.imbalance do
      is_nil(p.repeated) or p.repeated != o.repeated
    else
      less_imbalanced = if p.imbalance > o.imbalance, do: o, else: p
      less_imbalanced.repeated != invert(p.preference)
    end
  end

  defp legal_pair?(p1, p2), do: not Enum.any?(p1.games, &(&1.opponent_rank == p2.rank))

  defp assign_colour_with_history({a, b}) do
    case choose_colour(a, b) do
      "w" ->
        {a.rank, b.rank}

      "b" ->
        {b.rank, a.rank}

      nil ->
        # assign_colour_round_one/2 expects {better_ranked, worse_ranked}.
        {top, bottom} = if a.rank < b.rank, do: {a, b}, else: {b, a}
        assign_colour_round_one(top, bottom)
    end
  end

  # The colour `player` gets against `opponent` — a port of bbpPairings'
  # `choosePlayerNeutralColor` (`swisssystems/common.cpp`), which is
  # Article 5.2 in full: grant the preference outright when they don't
  # clash, otherwise let the stronger preference win (absolute over strong
  # over mild, and within absolute, the larger imbalance), and only when
  # they are genuinely equal fall back to alternating from the most recent
  # round in which the two players actually had different colours.
  #
  # `nil` means "still undecided" and leaves the caller on the fixed
  # round-1 convention. Note this affects only which of the two players is
  # printed as White; the comparison harness is colour-blind, so nothing
  # here moves the match rate. It's correctness, not score.
  defp choose_colour(player, opponent) do
    p = player.colour_stats
    o = opponent.colour_stats

    cond do
      is_nil(p.preference) or is_nil(o.preference) or p.preference != o.preference ->
        p.preference || invert(o.preference)

      p.absolute? and (p.imbalance > o.imbalance or not o.absolute?) ->
        p.preference

      o.absolute? and (o.imbalance > p.imbalance or not p.absolute?) ->
        invert(o.preference)

      p.strong? and not o.strong? ->
        p.preference

      o.strong? and not p.strong? ->
        invert(o.preference)

      true ->
        case first_colour_difference(player, opponent) do
          {nil, _} -> nil
          {_, nil} -> nil
          {_players_colour, opponents_colour} -> opponents_colour
        end
    end
  end

  # The colours the two players had in the most recent round where they
  # differed, walking both histories back in step and skipping unplayed
  # games on either side independently.
  defp first_colour_difference(a, b) do
    walk_back(played_colours(a), played_colours(b))
  end

  defp played_colours(player) do
    player.games |> Enum.map(& &1.colour) |> Enum.filter(&(&1 in ["w", "b"])) |> Enum.reverse()
  end

  defp walk_back([x | xs], [y | ys]) when x == y, do: walk_back(xs, ys)
  defp walk_back([x | _], [y | _]), do: {x, y}
  defp walk_back([], [y | _]), do: {nil, y}
  defp walk_back([x | _], []), do: {x, nil}
  defp walk_back([], []), do: {nil, nil}
end
