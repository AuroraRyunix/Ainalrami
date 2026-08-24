defmodule Ainalrami.Pairing.NoValidPairingError do
  @moduledoc """
  Raised when the active players cannot be simultaneously paired while
  satisfying the absolute criteria (no rematch, no double colour-absolute
  clash) - not a search failure, a proven structural deadlock.

  Direct analogue of bbpPairings' own `NoValidPairingException`
  (`swisssystems/dutch.cpp`'s `matchingIsComplete`/`compatible`): it
  computes ONE matching over the whole field and throws rather than ever
  emitting more byes than `rem(active_count, 2)`. `Ainalrami.Pairing`
  matches that: `global_cascade/2`'s `:infeasible` result
  (`repair_completion/3`'s whole-field maximum-weight matching) only
  reaches this if the true maximum itself still leaves too many players
  unmatched - proof no legal
  completion exists, not evidence the search didn't try hard enough. A
  small field deep into a Swiss (colour-absolute exclusions stacking on
  top of near-exhausted rematch-free opponents) is the realistic way to
  hit this, not a bug in the matcher.
  """
  defexception [:message]
end

defmodule Ainalrami.Pairing do
  @moduledoc """
  The actual Dutch-system pairing algorithm. Implemented incrementally -
  see docs/engineering-log.md for the staged plan and its documented simplifications
  (`pair_next_round/1`'s doc lists exactly which parts of the real FIDE
  procedure aren't faithfully implemented yet).

  A pairing is represented as `{white_rank, black_rank | nil}` - `nil` for
  a pairing-allocated bye, the same convention `Ainalrami.Trf`'s parsed game
  records use (`opponent_rank: nil`), rather than JaVaFo's own text-output
  convention of a literal `0` (that translation happens only at the
  CLI/output-formatting boundary).

  A player is `%{rank:, points:, games: [%{opponent_rank:, colour:, result:}]}`
  - the shape `Ainalrami.Trf.parse/1` returns.
  """

  alias Ainalrami.Log
  alias Ainalrami.WeightedMatching

  # This engine used to carry a second pairing path - a per-bracket
  # cascade with a backtracking search over alternative matchings, tuned
  # by five module attributes that lived here. It is gone, along with
  # ~950 lines, because `global_cascade/2` beat it at every field size and
  # then stopped falling back to it at all.
  #
  # The note those attributes carried is still worth keeping, because it
  # predicted this: a no-backtracking version of the OLD cascade measured
  # 97.19% -> 81.99% of pairs, and the reason given was that bbpPairings
  # needs no backtracking only because its weights are richer - locality
  # graded rather than partitioned, plus an exchange-minimisation
  # refinement. That is exactly what the current path implements, and it
  # needs no backtracking either.
  @bye_score_key :ainalrami_bye_score
  @expected_rounds_key :ainalrami_expected_rounds
  # dutch.cpp:845-870's `isSingleDownfloaterTheByeAssignee` as it stands
  # when the FIRST bracket is paired. It is read off the same bootstrap
  # whole-field matching that determines `byeAssigneeScore`, so it is
  # computed there (`bye_assignee_score/2`) and stashed here rather than
  # threaded through, exactly like the bye score itself.
  @first_single_bye_key :ainalrami_first_single_bye
  # `resolveForbiddenPairs`' answer for the round being paired
  # (`tournament.cpp:100-116`), as `%{rank => MapSet.t(rank)}`, or nil when
  # the tournament has no `XXP` line at all. Stashed for the same reason
  # `@expected_rounds_key` is: `legal_pair?/2` is reached from four call
  # sites deep inside the cascade and the matcher, none of which carry a
  # tournament-level context, and threading one through purely for a rule
  # that is usually absent would touch every weight function on the way.
  @forbidden_key :ainalrami_forbidden_pairs
  # The TOURNAMENT's played-round count, stashed for the same reason as the
  # keys above. `final_round_topscorers?/2` used `length(a.games)` - that
  # player's own game count - which is the precise indexing bug this module
  # was deliberately converted away from everywhere else (see
  # `float_direction/4`, where it was worth +10 points on the bye axis). A
  # player carrying a pre-recorded bye for the round being paired has one
  # game MORE than the tournament has played, so the final-round exception
  # could fire a round early for them; a late entrant has fewer, so it could
  # fail to fire when it should.
  @played_key :ainalrami_played_rounds
  # One WeightedMatching state for the whole round, carried across every
  # bracket of the cascade: `{matcher, field_index_of_rank, previous_edges,
  # field_size}`. Set by `global_cascade/2`, consumed by `solve/1`, cleared
  # with the rest of the round-scoped keys.
  @round_matcher_key :ainalrami_round_matcher
  @dirty_key :ainalrami_dirty_edges
  # The round.s completability oracle -- see `build_oracle/3`. Set by
  # `global_cascade/2`, consulted by `attempt_local/7`, cleared with the
  # rest of the round-scoped keys.
  @oracle_key :ainalrami_oracle
  # C.04.3 5.1's initial colour -- the one drawn by lot before round 1, which
  # 5.2.5 gives to the higher ranked player of a pair when neither holds a
  # preference. Defaults to White, which is what this engine assumed
  # unconditionally until the TRF's `152` field was read at all.
  @initial_colour_key :ainalrami_initial_colour

  # What a result is WORTH. Stashed for the same reason as the others: it is
  # read deep in the historic-score reconstruction, which the bracket cascade
  # reaches from several directions.
  #
  # This is not cosmetic. Score decides bracket, and bracket decides
  # everything, so an engine running the standard 1/=/0 against a file that
  # says otherwise does not report the wrong totals - it pairs a different
  # tournament and reports it confidently.
  @point_system_key :ainalrami_point_system

  @doc """
  Pairs the next round, dispatching to `pair_round_one/1` when no game
  history exists yet, or the bracket cascade below otherwise.

  `opts[:forbidden_pairs]` is a list of mutually-forbidden starting-rank
  GROUPS, exactly as `Ainalrami.Trf.parse/1` reports a file's `XXP` lines in
  `tournament[:forbidden_pairs]`. Acceleration needs no option: it rides on
  the players themselves, as each player's `:accelerations` list - again
  the shape `Ainalrami.Trf.parse/1` produces from `XXA`.
  """
  def pair_next_round(players, opts \\ []) do
    # The tournament's total round count, when the caller knows it (a
    # TRF's `XXR`/`142`). Only one rule needs it - the final-round
    # exception in `colour_compatible?/2` - so it is optional rather than
    # a required argument, and stashed rather than threaded through the
    # cascade, matching how the search budget is already carried.
    Process.put(@expected_rounds_key, opts[:expected_rounds])

    Process.put(
      @initial_colour_key,
      opts[:initial_colour] || infer_initial_colour(players) || "w"
    )

    Process.put(@point_system_key, opts[:point_system] || Ainalrami.Trf.default_point_system())

    try do
      played = rounds_played(players)

      # After `played`, not before: a `260` group is confined to a range of
      # rounds, so the map cannot be built until the round being paired is
      # known.
      Process.put(@forbidden_key, forbidden_map(opts[:forbidden_pairs], played + 1))

      active = Enum.filter(players, &active_this_round?(&1, played))

      # `pair_round_one/1` is a shortcut: it knows the whole field is tied
      # on zero, so rank order alone decides the split and nothing has to
      # be searched. Both of this commit's features break that assumption -
      # acceleration means round 1 is NOT a single score group, and a
      # forbidden pair means the S1[i]-vs-S2[i] answer may not be legal -
      # and bbpPairings has no round-one special case for either to be
      # compared against: `computeMatching` runs the same bracket machinery
      # from round 1 on. So when either is in play, so does this.
      if Enum.all?(active, &(&1.games == [])) and is_nil(Process.get(@forbidden_key)) and
           not Enum.any?(active, &(acceleration_at(&1, played) != 0.0)) do
        pair_round_one(active)
      else
        # The FULL roster, not just the active players - float direction
        # has to look up opponents' scores, and an opponent may be one of
        # the players sitting this round out.
        pair_later_round(players)
      end
    after
      Process.delete(@expected_rounds_key)
      Process.delete(@initial_colour_key)
      Process.delete(@point_system_key)
      Process.delete(@played_key)
      Process.delete(@forbidden_key)
    end
  end

  # `resolveForbiddenPairs` (`tournament.cpp:100-116`): each group is
  # inserted WHOLE into every member's own forbidden set, so an N-player
  # `XXP` line forbids all N*(N-1)/2 pairs within it. A player ends up in
  # their own set, exactly as in the C++ - harmless, since nobody is ever a
  # candidate opponent for themselves.
  #
  # nil rather than an empty map when there is nothing to forbid, so
  # `forbidden_pair?/2`'s hot path is a single process-dictionary read
  # returning nil rather than a map lookup per candidate edge.
  defp forbidden_map(groups, _round) when groups in [nil, []], do: nil

  # A group is either a plain list of starting ranks - `XXP`'s universal
  # form, forbidden for the whole tournament - or `{ranks, first, last}`
  # from a `260` line, forbidden only for rounds `first..last` inclusive.
  # Round-limited groups outside the round being paired are dropped here
  # rather than filtered at every lookup, so the map the cascade sees is
  # always simply "who may this player not meet, now".
  defp forbidden_map(groups, round) do
    map =
      Enum.reduce(groups, %{}, fn group, acc ->
        case applicable(group, round) do
          nil ->
            acc

          ranks ->
            members = MapSet.new(ranks)

            Enum.reduce(
              ranks,
              acc,
              &Map.update(&2, &1, members, fn set -> MapSet.union(set, members) end)
            )
        end
      end)

    if map == %{}, do: nil, else: map
  end

  defp applicable({ranks, first, last}, round) when round >= first and round <= last, do: ranks
  defp applicable({_ranks, _first, _last}, _round), do: nil
  defp applicable(ranks, _round) when is_list(ranks), do: ranks

  @doc """
  Scores an ALREADY-CHOSEN pairing against this engine's own C1-C21
  ladder, bracket by bracket. A diagnostic, not part of pairing.

  `pairs` is `[{white_rank, black_rank | nil}]` - any complete pairing of
  `players`, including one produced by a different engine. The brackets a
  pairing implies are reconstructed from it: score groups top-down, with
  each bracket's unpaired members carried into the next as its MDPs.

  Returns one map per bracket, `%{group:, mdps:, residents:, floats:,
  rungs: [{label, total}]}`, where each total is that criterion summed
  over the pairs the bracket keeps.

  The point is to adjudicate a disagreement rather than guess at it.
  Score both engines' answers and compare the first bracket where they
  differ:

    * the reference scores BETTER - this engine's search or tie-break
      failed to reach a pairing its own ladder prefers.
    * this engine scores better - then the ladder itself is wrong, since
      the reference would not violate a criterion it implements.
    * identical - the difference is below the criteria entirely, i.e.
      transposition/exchange ordering.

  ## What it cannot see

  **Rungs are only comparable between two answers when the bracket's
  `edge_count` matches.** Each bracket's rungs are a sum over the pairs it
  keeps plus the pairs reaching into the next score group, and the top rung
  counts one per edge. Where one answer pairs a player inside a bracket and
  the other floats them onward, the two windows hold different numbers of
  edges and EVERY rung differs by that accounting alone - including the top
  one, whose label names bye eligibility and whose difference in that case
  has nothing to do with bye eligibility. This misled a real adjudication:
  `seed735265-r7-p10` was recorded as `theirs_scores_better` on
  "C2/C4/C5 bye-eligibility" when the two answers simply placed one and two
  edges in the compared bracket. `edge_count` is reported per bracket so a
  caller can tell the two apart.

  It scores only the pairs a bracket KEEPS, so the two C8 rungs - which
  grade what a pairing leaves reachable in the brackets BELOW - are always
  zero here. C8 outranks every colour and float criterion, so a verdict of
  "this engine scores better on C12" may really mean "the reference is
  better on C8, which this cannot measure". Treat a C12 verdict as a lead,
  not a conclusion, and check the bracket below by hand.

  Verified against `colour_stats/1`, which is a faithful port of
  `computePlayerData` (tournament.cpp:43) rung for rung - including that a
  perfectly balanced player still has a MILD preference for the opposite
  of their last colour, and only a player who has never played has none.
  So a C12 verdict is not evidence of a bug in the colour model.
  """
  def explain_round(players, pairs, opts \\ []) do
    Process.put(@expected_rounds_key, opts[:expected_rounds])

    Process.put(
      @initial_colour_key,
      opts[:initial_colour] || infer_initial_colour(players) || "w"
    )

    try do
      played = rounds_played(players)
      Process.put(@played_key, played)
      Process.put(@forbidden_key, forbidden_map(opts[:forbidden_pairs], played + 1))

      field =
        players
        # Same two stamps, in the same order and over the same whole roster,
        # as `pair_later_round/1` - see its own comment for why float history
        # has to precede acceleration and cannot be scoped to the active
        # field. This used to skip `with_float_history/2` entirely, which
        # silently zeroed C14-C21 on BOTH sides of every verdict this
        # function produced: a round genuinely decided on a float rung was
        # reported as tying there and surfacing further down the ladder. It
        # could never invent a disagreement (both sides were equally blank),
        # only misattribute one, which is the harder failure to notice.
        |> with_float_history(played)
        |> with_acceleration(played)
        |> Enum.filter(&active_this_round?(&1, played))
        |> Enum.sort_by(&{-&1.points, &1.rank})
        |> Enum.map(&Map.put(&1, :colour_stats, colour_stats(&1)))

      brackets = field |> Enum.group_by(& &1.points) |> Enum.map(fn {_s, m} -> m end)

      {bye_score, first_single_bye?} = bye_assignee_score(brackets, rem(length(field), 2))
      Process.put(@bye_score_key, bye_score)
      Process.put(@first_single_bye_key, first_single_bye?)

      partner = partner_map(pairs)
      ctx = global_context(field)

      groups = Enum.chunk_by(field, & &1.points)
      points = Map.new(field, &{&1.rank, &1.points})

      groups
      |> Enum.with_index()
      |> Enum.reduce({[], [], ctx.first_single_bye?}, fn {group, i}, {acc, mdps, single_bye?} ->
        next_group = Enum.at(groups, i + 1, [])

        {report, floated} =
          explain_bracket(mdps ++ group, group, next_group, field, partner, ctx, single_bye?)

        {[report | acc], floated, next_single_bye?(ctx, next_group, floated, partner, points)}
      end)
      |> elem(0)
      |> Enum.reverse()
    after
      Process.delete(@expected_rounds_key)
      Process.delete(@initial_colour_key)
      Process.delete(@played_key)
      Process.delete(@forbidden_key)
      Process.delete(@bye_score_key)
      Process.delete(@round_matcher_key)
      Process.delete(@oracle_key)
      Process.delete(@dirty_key)
      Process.delete(@first_single_bye_key)
    end
  end

  # The same shape as `bracket_loop/6`'s own gate (dutch.cpp:1608-1643),
  # reconstructed from a finished pairing. The one thing this cannot have
  # is the TENTATIVE match a floating player carried at the moment the
  # bracket closed - that only exists inside the live cascade's persistent
  # matching. It substitutes the FINAL partner, which is the same player
  # whenever the float ends up paired where the tentative match said it
  # would, and a bye-taker reports their own score (an unmatched vertex is
  # its own partner in bbpPairings' convention, dutch.cpp:1637).
  #
  # This replaces a much cruder stand-in (odd field, and an even number of
  # players below the bracket) that ignored both the `byeAssigneeScore >=
  # next group` precondition and the clearing step entirely, and so could
  # score C9 in brackets where the engine itself does not.
  defp next_single_bye?(_ctx, [], _floated, _partner, _points), do: false

  defp next_single_bye?(ctx, next_group, floated, partner, points) do
    next_score = hd(next_group).points

    ctx.odd_field? and not is_nil(ctx.bye_score) and ctx.bye_score >= next_score and
      Enum.all?(floated, fn p ->
        case Map.get(partner, p.rank) do
          nil -> p.points >= next_score
          other -> Map.get(points, other, p.points) >= next_score
        end
      end)
  end

  defp partner_map(pairs) do
    Enum.reduce(pairs, %{}, fn
      {w, nil}, acc -> Map.put(acc, w, nil)
      {w, b}, acc -> acc |> Map.put(w, b) |> Map.put(b, w)
    end)
  end

  defp explain_bracket(bracket, group, next_group, field, partner, ctx, single_bye?) do
    ranks = MapSet.new(bracket, & &1.rank)
    score = hd(group).points

    # A bracket member is kept here when their partner is also in it;
    # everyone else floats on and becomes the next bracket's MDP.
    {kept, floated} =
      Enum.split_with(bracket, fn p ->
        case Map.get(partner, p.rank) do
          nil -> false
          other -> MapSet.member?(ranks, other)
        end
      end)

    by_rank = Map.new(bracket, &{&1.rank, &1})

    edges =
      kept
      |> Enum.map(fn p -> Enum.min_max([p.rank, Map.fetch!(partner, p.rank)]) end)
      |> Enum.uniq()

    # The C8 rungs grade what a bracket leaves reachable BELOW it, so they
    # are scored over the pairs that reach from this bracket into the next
    # score group - exactly the edges the real matcher sees with
    # `in_current` false. Leaving them out was this diagnostic's blind
    # spot: C8 outranks every colour and float criterion, so two answers
    # differing only there used to come back as "tie on every rung", and
    # the C12 verdict below them was then read as a colour bug.
    next_ranks = MapSet.new(next_group, & &1.rank)
    cross_by_rank = Map.new(bracket ++ next_group, &{&1.rank, &1})

    cross_edges =
      bracket
      |> Enum.flat_map(fn p ->
        case Map.get(partner, p.rank) do
          nil -> []
          other -> if MapSet.member?(next_ranks, other), do: [{p.rank, other}], else: []
        end
      end)
      |> Enum.uniq()

    # Sized over the WHOLE FIELD, exactly as the engine sizes it
    # (`pair_bracket/6`: `score_places(combined)`, `count_span = m + 1`).
    #
    # This used `bracket ++ next_group`, which broke comparability twice
    # over. Against the engine: rung values that depend on `places` -- C7,
    # C8, C18-C21 -- sat on a different radix here than in the weights they
    # are supposed to explain, so an `explain_round` number could never be
    # held against an engine weight. And between two ANSWERS: the bracket
    # composition depends on which players each answer floats, so two reports
    # of the same position were scaled differently from each other, which is
    # the thing an adjudicator does nothing but compare.
    {places, place_span} = score_places(field)
    count_span = length(field) + 1

    bands = %{
      places: places,
      place_span: place_span,
      count_span: count_span,
      reserve: 2 * count_span * count_span * count_span
    }

    kept_rungs =
      Enum.map(edges, fn {x, y} ->
        {a, b} = order_by_placement(Map.fetch!(by_rank, x), Map.fetch!(by_rank, y))
        edge_rungs(a, b, 0, ctx, bands, single_bye?)
      end)

    cross_rungs =
      Enum.map(cross_edges, fn {x, y} ->
        {a, b} = order_by_placement(Map.fetch!(cross_by_rank, x), Map.fetch!(cross_by_rank, y))
        edge_rungs(a, b, 1, ctx, bands, single_bye?)
      end)

    rungs = sum_rungs(kept_rungs ++ cross_rungs)

    {%{
       group: score,
       # The same rungs, before they were summed: one entry per edge, in the
       # order `pairs ++ the cross edges the floats leave on`. A bracket's
       # `rungs` are exactly the column-wise sum of these, so a caller can
       # say WHICH pair carries a criterion's cost rather than only that the
       # bracket paid it.
       #
       # These were computed and thrown away for as long as this function has
       # existed; keeping them costs nothing and answers the question an
       # arbiter actually asks, which is never "why did this bracket score
       # 6" but "why is THIS board like that".
       #
       # Caveat for anyone rendering them: the top rung counts one per edge,
       # so every pair contributes exactly one there and it discriminates
       # nothing per-pair. It is the bracket-level total that means
       # something.
       edge_rungs: per_edge_rungs(edges ++ cross_edges, kept_rungs ++ cross_rungs),
       mdps: bracket |> Enum.filter(&(&1.points > score)) |> Enum.map(& &1.rank),
       residents: Enum.map(group, & &1.rank),
       pairs: edges,
       floats: Enum.map(floated, & &1.rank),
       rungs: rungs,
       # How many edges this bracket's rungs were summed over. Every rung
       # here is a SUM over `kept ++ cross`, and the leading term of the top
       # rung is one per edge -- so when two answers put different numbers of
       # edges in the same bracket's window, every rung differs for that
       # reason alone and none of the differences are criterial. Two answers
       # are only comparable rung by rung when this number matches; the
       # adjudicator reads it to say so rather than reporting a verdict it
       # cannot support. See `explain_round/3`'s "What it cannot see".
       edge_count: length(edges) + length(cross_edges),
       order: Enum.map(bracket, & &1.rank),
       lex: transposition_key(bracket, group, partner)
     }, floated}
  end

  # FIDE section 3's transposition order, as a comparable key.
  #
  # Articles 3.3-3.5 pick the SMALLEST transposition of the natural order,
  # and "smallest" is lexicographic over S2 - which member of S2 faces
  # S1[0], then S1[1], and so on, with the identity permutation smallest.
  # So the key is the S2 INDEX of each S1 member's opponent, in S1 order,
  # and a smaller key wins.
  #
  # Getting this wrong is easy and was: a first attempt keyed on absolute
  # bracket position, which makes the natural pairing (0 vs k, 1 vs k+1)
  # look large and the adjacent pairing (0 vs 1) look smallest - the
  # opposite of the Dutch structure. It is also why `spread` in
  # `within_bracket_weight/4` is load-bearing rather than decorative:
  # maximising rank distance is what produces the S1-vs-S2 halving in the
  # first place, and removing it measured 90.29% -> 42.21% of rounds.
  @doc """
  Article 4.2's transposition order for one bracket, as a comparable key.

  Returns, for each S1 member in Article 1.2 order, the INDEX in S2 of the
  player they face (or `length(s2)` when they are unpaired). Smaller wins,
  compared lexicographically.

  **This is 4.2.2's ordering exactly, not an approximation of it.** The
  article sorts transpositions by "the lexicographic value of their first N1
  BSN(s)" - the BSNs of the players facing S1[0], S1[1], … S2 is sorted by
  Article 1.2 and BSNs are assigned in that same order (4.1.1), so a member's
  index in S2 and their BSN rank within S2 increase together. Lexicographic
  comparison over indices therefore induces the identical order as
  lexicographic comparison over BSNs. `sequence_test.exs` checks this against
  `Ainalrami.Sequence.transpositions/2` rather than leaving it as an argument.

  What it does NOT cover is Article 4.3. Once every transposition of a given
  S1/S2 has been tried, the regulations *exchange* players between the two
  subgroups and start the sequence again, reaching candidates no transposition
  can. Those candidates are still considered here - the matcher searches every
  matching - but ties among them are not ranked by generation order, and that
  is the whole of the remaining divergence from 3.8.1.
  """
  def transposition_key(bracket, group, partner) do
    score = hd(group).points
    {mdps, residents} = Enum.split_with(bracket, &(&1.points > score))

    {s1, s2} =
      if mdps == [] do
        Enum.split(bracket, div(length(bracket), 2))
      else
        {mdps, residents}
      end

    s2_index = s2 |> Enum.map(& &1.rank) |> Enum.with_index() |> Map.new()
    unpaired = length(s2)

    Enum.map(s1, fn p ->
      case Map.get(partner, p.rank) do
        nil -> unpaired
        other -> Map.get(s2_index, other, unpaired)
      end
    end)
  end

  defp order_by_placement(x, y) do
    if {-x.points, x.rank} <= {-y.points, y.rank}, do: {x, y}, else: {y, x}
  end

  # Pairs each edge with its own rung vector, dropping the internal span
  # term that only `sum_rungs/1` and the weight model need. Returned as a
  # list rather than a map because an edge is a tuple, and a caller that
  # wants it keyed can do that itself.
  defp per_edge_rungs(edges, per_edge) do
    Enum.zip_with(edges, per_edge, fn edge, rungs ->
      {edge, Enum.map(rungs, fn {label, value, _span} -> {label, value} end)}
    end)
  end

  defp sum_rungs([]), do: []

  defp sum_rungs([first | _] = per_edge) do
    Enum.with_index(first)
    |> Enum.map(fn {{label, _v, _span}, i} ->
      {label, Enum.sum(Enum.map(per_edge, fn rungs -> elem(Enum.at(rungs, i), 1) end))}
    end)
  end

  @doc """
  Pairs the very first round.

  Per FIDE C.04.3 Article 1: split the full field into two equal halves by
  rank (S1 = top half, S2 = bottom half - everyone is tied on 0 points, so
  rank order alone determines the split); an odd field first removes the
  lowest-ranked player for the pairing-allocated bye, then splits the
  remaining even field. Pair S1[i] against S2[i].

  Confirmed against real `javafo.jar` output for 7/8/9/10/11/12/13-player
  fields, not assumed from the spec text alone.

  Colours (Article 5.1/5.2.5): FIDE leaves the very first colour to a
  literal "drawing of lots" - there is no deterministic rule to replicate.
  This picks a fixed, documented convention rather than JaVaFo's own
  choice, which is empirically NOT a function of the roster/round-count
  alone: pairing the identical 8-player roster and round count under two
  different tournament *names* produced opposite initial colours from
  JaVaFo - strong evidence it's seeded from something incidental (a hash
  of the input file, most likely), not a reproducible rule. Colour output
  will legitimately not always match JaVaFo's own for this reason; pairing
  *composition* (who plays whom) is the thing that should match, and does
  - see the comparison harness in `test/ainalrami/javafo_comparison_test.exs`.
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

  # Article 5.1 leaves the initial colour to a drawing of lots taken before
  # round one, and TRF's `152` is where that draw is recorded. When a file
  # omits it, the draw is NOT unknown and must not be guessed at: round
  # one's own colours ARE the record of it, and reconstructing the draw from
  # them is reading the data rather than assuming a convention.
  #
  # Assuming White cost 1954 disagreeing boards per 600 bye-heavy
  # tournaments and none at all without byes, which is the signature of
  # exactly this: the assumption only breaks when the players who would have
  # revealed the draw sat round one out.
  #
  # This is 5.2.5 run backwards, and it uses 5.2.5's own number - the
  # player's TPN - rather than their position among whoever happened to
  # play. A player with an odd TPN held the initial colour, so their colour
  # IS the draw; an even TPN held its opposite, so invert. Applying it to a
  # renumbered position instead would make the inference disagree with the
  # allocation it is inverting, on exactly the fields where somebody sat a
  # round out.
  #
  # Returns nil when the file records no colours at all - before round one
  # there is genuinely nothing to infer from, which real bbpPairings treats
  # as fatal rather than guessable.
  defp infer_initial_colour(players) do
    ranked = Enum.sort_by(players, & &1.rank)

    first_coloured =
      ranked
      |> Enum.flat_map(fn p ->
        p.games |> Enum.with_index() |> Enum.filter(&(elem(&1, 0).colour != nil))
      end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.min(fn -> nil end)

    if first_coloured do
      Enum.find_value(ranked, fn p ->
        case Enum.at(p.games, first_coloured) do
          %{colour: c} when c in ["w", "b"] ->
            if rem(p.rank, 2) == 1, do: c, else: invert(c)

          _ ->
            nil
        end
      end)
    end
  end

  # `top` is always the better-ranked (lower rank number) of the pair, since
  # both halves are traversed in ascending rank order before zipping.
  defp assign_colour_round_one(top, bottom) do
    # 5.2.5: `top` holds the initial colour on an odd TPN and the opposite on
    # an even one. The initial colour comes from the file's `152` field, or
    # is reconstructed by `infer_initial_colour/1` when the file is silent.
    initial_white? = Process.get(@initial_colour_key, "w") == "w"
    top_takes_initial? = rem(top.rank, 2) == 1

    if top_takes_initial? == initial_white? do
      {top.rank, bottom.rank}
    else
      {bottom.rank, top.rank}
    end
  end

  @doc """
  Pairs a round from existing score/game history.

  `opts` are the same as `pair_next_round/2`'s: `:expected_rounds` (the
  tournament's total, which the final-round colour exception needs) and
  `:forbidden_pairs` (groups of mutually-forbidden starting ranks, from a
  TRF's `XXP` lines). Prefer `pair_next_round/2`, which also handles the
  round-one case; this is the later-round path on its own.

  Forms score brackets (Article 1.2: ranked by score, then TPN ascending)
  in descending order and pairs them in one continuous solve. Every
  unfinalised player in the field is a vertex in every bracket's matching;
  weights are bracket-flavoured, so a pair two or more score groups away
  scores only the completion rung and C9 - which is exactly the weight
  bbpPairings leaves on its own out-of-window edges. Players a bracket
  cannot pair float down and merge with the next one (Articles
  1.3.3/3.2/3.3), ranked ahead of that bracket's residents by their higher
  score, which falls out of re-sorting by Article 1.2 directly.

  The matcher is `Ainalrami.WeightedMatching.solve/2` - a Galil/Micali/Gabow
  primal-dual maximum-weight general matching. The criteria and their
  priority order are ported from bbpPairings' `computeEdgeWeight`
  (`swisssystems/dutch.cpp`) and packed into one integer per edge by
  `edge_rungs/6`: completion and bye eligibility, C6/C7 (pairs and scores
  within the bracket), C8 (the same one bracket down), C9 (the bye
  assignee's unplayed games), C10-C13 (colour), C14-C17 (float history) and
  C18-C21 (score-weighted float history).

  ## Accuracy

  Against **bbpPairings 6.0.0**, which implements the same 2026 rules this
  engine targets: **100.00% of rounds and of individual pairs** across
  roughly 4.3 million tournaments and 195 million pairings, over axes
  varying field size (4-120), round count (6-10), arbiter byes, forfeits,
  `XXP` exclusions and `XXA` acceleration. One disagreement in that whole
  corpus, `seed735265-r7-p10`, where Gacrux - a third independent
  implementation - sides with this engine.

  Against **javafo.jar** it measures ~96%, and that gap is the control
  rather than an error: javafo implements the 2022 rules, so an engine
  agreeing with all three at once would mean the comparison was measuring
  nothing. See docs/engineering-log.md for the measured history.

  ## Do not "simplify" the scoring terms without re-measuring

  Several plausible-sounding changes have each been measured WORSE and
  reverted (see docs/engineering-log.md): a bipartite S1-vs-S2 restriction (10.7%), a
  whole-bracket natural-correspondence deviation metric (64.95%),
  subordinating the float protections to the pair criteria (-7 points), and
  emitting the next-bracket lookahead as real cross-bracket pairs
  (86.40% -> 43.82% of rounds). The terms are empirical, not derived.

  Two of the criteria are invisible outside the final round by
  construction: `bracket_edge_weight/8` only creates an edge where
  `colour_compatible?/2` holds, which already rejects a same-absolute-colour
  clash, so the C10/C11 rungs are constant across candidate matchings except
  where `final_round_topscorers?/2` admits such a pair.
  """
  def pair_later_round(players, opts \\ []) do
    # Public, and it sets none of the process-dictionary state the rules read
    # - so calling it directly used to ignore every `XXP` line and never fire
    # the final-round colour exception, silently producing a pairing that
    # looks entirely legal. That is the exact failure the whole forbidden-pair
    # feature exists to prevent, reachable by anyone following the docs.
    #
    # `pair_next_round/2` sets both before delegating here, and re-setting
    # them from the same keyword list is idempotent, so this costs that path
    # nothing while making the direct one safe.
    Process.put(@expected_rounds_key, opts[:expected_rounds] || Process.get(@expected_rounds_key))

    Process.put(
      @forbidden_key,
      (opts[:forbidden_pairs] &&
         forbidden_map(opts[:forbidden_pairs], rounds_played(players) + 1)) ||
        Process.get(@forbidden_key)
    )

    do_pair_later_round(players)
  end

  defp do_pair_later_round(players) do
    played = rounds_played(players)
    Process.put(@played_key, played)

    field =
      players
      # Float history first, over the WHOLE roster: `float_direction/4`
      # compares against the opponent's score at the time, and that
      # opponent may be sitting this round out. It runs BEFORE
      # `with_acceleration/2` on purpose - `score_before/3` reconstructs a
      # historic score by subtracting later results from the current one,
      # so it needs the REAL score to subtract from, and adds that round's
      # own acceleration itself.
      |> with_float_history(played)
      |> with_acceleration(played)

    active = Enum.filter(field, &active_this_round?(&1, played))

    brackets =
      active
      |> Enum.group_by(& &1.points)
      |> Enum.sort_by(fn {score, _} -> -score end)
      |> Enum.map(fn {_score, members} -> members end)

    # Exactly one pairing-allocated bye in an odd field, none in an even
    # one. Counted over the ACTIVE players - a field of even size with one
    # player sitting out needs a bye, and one of odd size with one sitting
    # out does not.
    allowed_byes = rem(length(active), 2)

    {bye_score, first_single_bye?} = bye_assignee_score(brackets, allowed_byes)
    Process.put(@bye_score_key, bye_score)
    Process.put(@first_single_bye_key, first_single_bye?)

    try do
      case global_cascade(brackets, allowed_byes) do
        {:ok, pairs, leftover} ->
          # `global_cascade/2` returns `:ok` only after `check_completion/3`
          # has passed on exactly these pairs and this leftover, so the round
          # is already known legal here: bye count, C2 eligibility and the C5
          # bye score. A `repair_bye_count/3` pass used to follow, guarded by
          # a `bye_legal?/3` that restated two of those three tests over the
          # same set - provably true whenever it was reached, so its repair
          # branch, and with it every use of `Ainalrami.Blossom`, could not
          # run. Both are gone; see docs/engineering-log.md.
          pairs ++ Enum.map(leftover, &{&1.rank, nil})

        :infeasible ->
          # `global_cascade/2` only reports this once its own completion
          # repair - a whole-field maximum matching - has also failed to
          # pair everyone, which means no legal round exists at all.
          # bbpPairings answers the same case the same way, with
          # `NoValidPairingException`.
          raise Ainalrami.Pairing.NoValidPairingError,
                "no legal pairing exists for #{length(active)} active player(s)"
      end
    after
      Process.delete(@bye_score_key)
      Process.delete(@round_matcher_key)
      Process.delete(@oracle_key)
      Process.delete(@dirty_key)
      Process.delete(@first_single_bye_key)
    end
  end

  # How many rounds the tournament has actually completed.
  #
  # Neither the minimum nor the maximum games count works. The minimum
  # breaks on a late entrant, who has no games at all and would make
  # everyone else look like they'd already been paired - measured, it
  # emptied the pairing entirely. The maximum breaks on a pre-recorded
  # bye, which is the very thing being detected.
  #
  # bbpPairings resolves it by only advancing `playedRounds` for games the
  # player PARTICIPATED IN THE PAIRING for (`trf.cpp:339-342`): a real
  # game, or a pairing-allocated bye, but not an arbiter-assigned one. So
  # the round number is the furthest any player has been genuinely paired
  # to, and a half-point bye recorded in advance doesn't move it.
  #
  # That is only HALF of bbpPairings' rule, and the missing half was a real
  # bug - see `evenUpMatchHistories` (`trf.cpp:646-684`), which runs after
  # parsing and can advance `playedRounds` once more:
  #
  #     forwardRoundIsComplete = includesUnpairedRound            // true here
  #     for (valid player)
  #       if (includesUnpairedRound ^ (matches.size() > playedRounds))
  #         forwardRoundIsComplete = !includesUnpairedRound
  #     if (playersByRank.size() && forwardRoundIsComplete) ++playedRounds
  #
  # Pairing mode passes `includesUnpairedRound = true` (`main.cpp:452`,
  # under `if (doPairings)` - "compute the pairings of the next round";
  # the checker's own read at `main.cpp:347` passes false), so that XOR
  # reduces to "clear the flag for any player whose history is NOT longer
  # than playedRounds", i.e. the increment happens exactly when EVERY
  # player already carries a game for the trailing column. Then that
  # column is a round that is already fully decided - everyone in it is
  # accounted for - so it counts as PLAYED, and the round to pair is the
  # one after it.
  #
  # The distinction that makes this safe is "every" vs "any": one player
  # holding a pre-recorded half-point bye for the next round leaves
  # everyone else's history shorter, the flag clears, and nothing
  # advances - so the ordinary arbiter-bye case still pairs the round
  # those other players are waiting for, exactly as `active_this_round?/2`
  # below describes and as javafo was measured to do. Only a trailing
  # column that is complete for the WHOLE field advances the count.
  #
  # Found via `crash_reports/seed4385-r5-p4.trf`, where all four players
  # carry a round-5 bye: this engine returned `{:ok, []}` (nobody active
  # for round 5) where bbpPairings pairs round 6 cleanly. docs/engineering-log.md had
  # recorded the four sibling cases as degenerate fuzz artifacts and this
  # one as an unexplained genuine bug; they are all this single rule.
  defp rounds_played(players) do
    base = players |> Enum.map(&paired_through/1) |> max_or_zero()

    if players != [] and Enum.all?(players, &(length(&1.games) > base)) do
      base + 1
    else
      base
    end
  end

  defp paired_through(player) do
    player.games
    |> Enum.with_index(1)
    |> Enum.filter(fn {game, _round} -> participated_in_pairing?(game) end)
    |> Enum.map(fn {_game, round} -> round end)
    |> max_or_zero()
  end

  # bbpPairings' `opponent != id || resultChar == 'U' || resultChar == '+'`
  # - a bye counts as having been paired only when it's the
  # pairing-allocated one (or a forfeit win, which still occupied a slot).
  defp participated_in_pairing?(game) do
    not is_nil(game.opponent_rank) or game.result in ["U", "+"]
  end

  defp max_or_zero([]), do: 0
  defp max_or_zero(values), do: Enum.max(values)

  # A player is paired this round only if they don't already have a result
  # for it. bbpPairings has exactly this test - `if (player.matches.size()
  # <= tournament.playedRounds)` before pushing onto `sortedPlayers`
  # (`dutch.cpp:658`) - and it's the mechanism by which requested
  # half-point byes, zero-point byes and retirements work at all: the
  # arbiter records the result in advance, and the engine then leaves that
  # player out of the pairing.
  #
  # This engine paired them anyway, which meant a player who had asked for
  # a bye got a game. Confirmed against javafo on a six-player case where
  # player 6 held a pre-recorded half-point bye: javafo paired the other
  # five and gave the odd one out the pairing-allocated bye, while this
  # engine paired player 6 with player 4.
  defp active_this_round?(player, rounds_played), do: length(player.games) <= rounds_played

  # Fold each player's acceleration for the round about to be paired INTO
  # their `:points`, so every score read below this line is the accelerated
  # one.
  #
  # That is not a shortcut, it is the port. Inside `dutch.cpp` there is
  # essentially no other kind of score: bracket formation
  # (`dutch.cpp:680`, 698-701), the bye assignee (846, 882), the C9 gate
  # (852-865), the bracket loop's own score reads (1114-1126, 1611-1640),
  # `bye_candidate?`'s eligibility (220), the float criteria's score
  # comparisons (295-457) and even `compatible`'s final-round exception
  # (63-65) ALL go through `scoreWithAcceleration`. The only reads of
  # `scoreWithoutAcceleration` in the whole engine are in `common.cpp`'s
  # `sortResults` (180-206), which orders the OUTPUT and is not pairing.
  # So rather than auditing every `.points` in this module one at a time,
  # the accelerated score is what `.points` means from here on, and the two
  # places that genuinely need the real score take it before this runs:
  # `with_float_history/2` above, and the caller's own standings.
  #
  # The whole list is returned untouched when no player carries an
  # `:accelerations` key at all, which is every tournament without an `XXA`
  # line - the ordinary case pays one `Enum.any?` and allocates nothing.
  defp with_acceleration(players, played) do
    if Enum.any?(players, &Map.has_key?(&1, :accelerations)) do
      Enum.map(players, fn p -> %{p | points: p.points + acceleration_at(p, played)} end)
    else
      players
    end
  end

  # `accelerations[roundIndex]`, with `roundIndex >= size` reading as zero
  # (`tournament.h:346-348`). The index is the TOURNAMENT's played-round
  # count, 0-based, so the value that applies to the round about to be
  # paired is the one at `played` - `accelerations[0]` is round 1's.
  defp acceleration_at(_player, round_index) when round_index < 0, do: 0.0

  defp acceleration_at(player, round_index) do
    case player do
      %{accelerations: values} -> Enum.at(values, round_index) || 0.0
      _ -> 0.0
    end
  end

  # Stamp each player's float direction for the last two rounds, once per
  # round rather than per candidate pair - `float_direction/4` needs every
  # player (it compares against the OPPONENT's score at the time), which
  # `pair_weight/4` doesn't have and shouldn't need.
  defp with_float_history(players, played) do
    by_rank = Map.new(players, &{&1.rank, &1})

    Enum.map(players, fn player ->
      Map.put(player, :floats, %{
        1 => float_direction(player, 1, by_rank, played),
        2 => float_direction(player, 2, by_rank, played)
      })
    end)
  end

  # Which way a player was floated `rounds_back` rounds ago - a port of
  # bbpPairings' `getFloat` (`dutch.cpp`). A float isn't recorded anywhere
  # in a TRF; it's *derived*, by comparing what the two players' scores
  # were when they were paired. Outscoring your opponent that round means
  # you were floated DOWN to meet them.
  #
  # An unplayed round counts as a downfloat whenever it scored better than
  # a loss, so a pairing-allocated bye is a downfloat - which is what makes
  # this criterion bite in odd-sized tournaments.
  # Indexed by the TOURNAMENT's played-round count, not by the player's own
  # game count - bbpPairings reads `player.matches[tournament.playedRounds
  # - roundsBack]`. The two are the same only while every player has an
  # entry per round, which arbiter-assigned byes break: a player carrying a
  # pre-recorded bye for the round about to be paired has one game MORE
  # than the tournament has played, so `length(games) - 1` pointed at that
  # future bye instead of their last real round, and every float criterion
  # C14-C21 then read a fabricated history for them.
  defp float_direction(player, rounds_back, by_rank, played) do
    index = played - rounds_back

    if index < 0 or index >= length(player.games) do
      :none
    else
      game = Enum.at(player.games, index)

      cond do
        not played?(game) ->
          if result_points(game.result) > 0.0, do: :down, else: :none

        not is_map_key(by_rank, game.opponent_rank) ->
          :none

        true ->
          mine = score_before(player, rounds_back, played)
          theirs = score_before(Map.fetch!(by_rank, game.opponent_rank), rounds_back, played)

          cond do
            mine > theirs -> :down
            mine < theirs -> :up
            true -> :none
          end
      end
    end
  end

  # A player's score as it stood after round `played - rounds_back` -
  # current score minus what every later round paid out. bbpPairings keeps
  # the same thing as `scoreWithAcceleration(tournament, roundsBack)`.
  #
  # Counted from the TOURNAMENT's round number for the same reason
  # `float_direction/4` is: a player holding a pre-recorded bye has an
  # extra game, and taking "the last `rounds_back`" off their own list
  # then subtracts the wrong rounds.
  #
  # The acceleration term is that round's, not this one's:
  # `scoreWithAcceleration` (`tournament.h:335-359`) winds `roundIndex`
  # back in step with the score it is stripping and then adds
  # `accelerations[roundIndex]`. A float direction is therefore judged on
  # the scores as the two players' brackets saw them AT THE TIME, virtual
  # points included - which is precisely why JaVaFo's manual insists the
  # `XXA` line carry the full round-by-round record rather than just the
  # current round's value.
  defp score_before(player, rounds_back, played) do
    from = max(played - rounds_back, 0)

    # A SLICE of the played rounds, not everything from `from` onwards.
    # `scoreWithAcceleration` (tournament.h:335-359) winds back exactly
    # `roundsBack` steps from `playedRounds`, so a game recorded for a round
    # beyond that - a pre-recorded bye for the round being paired - is never
    # one of the subtractions. It is handled once, in the base, by
    # `reconciled_points/2`.
    #
    # Dropping to the end instead happened to agree while the base was the
    # raw total: the future round was included there and subtracted here, and
    # the two cancelled. Reconciling the base without narrowing this
    # subtracted it twice - measured at 88.19% of rounds against 100.00%,
    # which is what caught it.
    player.games
    |> Enum.slice(from, played - from)
    |> Enum.reduce(reconciled_points(player, played), fn game, score ->
      score - result_points(game.result)
    end)
    |> Kernel.+(acceleration_at(player, played - rounds_back))
  end

  # The player's total as a base to wind BACK from, reconciled against the
  # games they actually hold.
  #
  # This used `player.points` raw, which is the TRF's own columns 81-84 and
  # not derived from the games at all. Where the two disagree - an arbiter's
  # point adjustment, a total that already includes the acceleration, a
  # pre-recorded bye for the round being paired that has already been
  # credited - every reconstructed historic score was wrong by that much, and
  # therefore every float criterion C14-C21 for that player, silently.
  #
  # bbpPairings does not trust the field either. `trf.cpp:885-925` sums the
  # matches and, when the stored total disagrees, tries subtracting the
  # acceleration and then the points of a round beyond `playedRounds`,
  # keeping whichever reconciles. That is what this ports. When nothing
  # reconciles the file is simply inconsistent, and the stored value is kept
  # - bbpPairings' own final fallback, and the conservative one, since the
  # arbiter's recorded total is the authority on a hand-adjusted score.
  defp reconciled_points(player, played) do
    played_sum =
      player.games
      |> Enum.take(played)
      |> Enum.reduce(0.0, fn game, sum -> sum + result_points(game.result) end)

    future_sum =
      player.games
      |> Enum.drop(played)
      |> Enum.reduce(0.0, fn game, sum -> sum + result_points(game.result) end)

    acceleration = acceleration_at(player, played)

    Enum.find(
      [
        player.points,
        player.points - acceleration,
        player.points - future_sum,
        player.points - acceleration - future_sum
      ],
      player.points,
      &same_score?(&1, played_sum)
    )
  end

  # Scores are halves, so they are exact in binary floating point and could be
  # compared directly - but they arrive via subtraction chains, and a
  # tolerance costs nothing and removes the question.
  defp same_score?(a, b), do: abs(a - b) < 0.001

  # Delegates rather than restating. This was a second copy of the same
  # mapping, and the duplication cost something concrete: adding TRF16's
  # letter result codes meant editing BOTH tables, separately, on the same
  # day -- exactly the drift `Trf.points_for/1` existing at all is supposed
  # to prevent. `Pairing` aliases nothing from `Trf` by design (the engine
  # runs on plain maps and does not require a parsed file), so this is the
  # one call rather than a module-wide alias.
  defp result_points(result) do
    case Process.get(@point_system_key) do
      nil -> Ainalrami.Trf.points_for(result)
      system -> Ainalrami.Trf.points_for(result, system)
    end
  end

  defp point_system do
    Process.get(@point_system_key) || Ainalrami.Trf.default_point_system()
  end

  defp float_of(player, rounds_back) do
    player |> Map.get(:floats, %{}) |> Map.get(rounds_back, :none)
  end

  # bbpPairings' bracket algorithm, ported stage for stage from
  # `dutch.cpp` 1011-1649. This replaces an earlier port that solved each
  # score level once; see "Why one matching is not enough" below.
  #
  # ## The graph is the current bracket plus the next score group
  #
  # `playersByIndex` holds the current bracket followed by the whole of
  # the NEXT score group, and nothing else - every other player has no
  # edge at all. Local indices, in the field's own `(-points, rank)`
  # order:
  #
  #     [0, sgb)      MDPs - moved down from a bracket above
  #     [sgb, nsgb)   residents - this bracket's own score group
  #     [nsgb, m)     the next score group, present only to be pairable
  #
  # `computeBaseEdgeWeights` (dutch.cpp:607) only builds an edge when the
  # LARGER index is at least `sgb`, so two MDPs never have an edge: a
  # moved-down player is paired against a resident or not at all.
  #
  # The first port put the ENTIRE remaining field in one graph and threw
  # the far pairs away afterwards. By then the matcher had already traded
  # a good internal pair for two of them - the discard happens after the
  # optimum is chosen, not before.
  #
  # ## Why one matching is not enough
  #
  # A maximum-weight matching decides everything at once and may return
  # any optimum. bbpPairings does not let it: it calls `computeMatching()`
  # seven times per bracket, each call re-solving the SAME graph after a
  # targeted nudge that forces exactly one decision, which is then frozen
  # with `finalizePair` before the next question is asked. The stages, in
  # order, are `stage_select_mdps/1` (which moved-down players get paired
  # at all), `stage_mdp_opponents/1` (who each one plays),
  # `stage_build_remainder/1` and `stage_exchange_weights/1` (what is left
  # and how it splits), the two exchange-selection loops, the reset pass,
  # and `stage_first_group_partners/1`.
  #
  # Those last five are FIDE C.04.3 §3's transposition and exchange
  # procedure, done properly. The per-bracket cascade approximates it with
  # two invented terms, `deviation` and `spread`, which is the divergence
  # docs/fide-criteria.md calls "the largest remaining gap". They are
  # deliberately absent from this ladder: the exchange stages ARE the
  # mechanism they stand in for, and keeping both would let a stand-in
  # outvote the real thing.
  #
  # ## Arithmetic
  #
  # `computeEdgeWeight` leaves `3 * scoreGroupSizeBits + 1` bits of
  # RESERVED low space (dutch.cpp:462-469) that the stages write into, so
  # a nudge can break a tie without ever outranking a real criterion.
  # `bands.reserve` is that space, and every stage addend lives inside it.
  #
  # `edgeWeightComputer`'s addend goes NEGATIVE (dutch.cpp:1076 subtracts
  # from a value that is zero whenever its guard bit is clear). In C++
  # that is unsigned wraparound; here it is just subtraction, which is
  # what the wraparound computes. It borrows into the criterion above,
  # but can never invert an ordering: the borrow is under `2 * s`, and one
  # unit of the lowest criterion is `reserve = 2 * s^3`.
  #
  # ## What it measures, and why it is still not the default
  #
  # 200 tournaments x 9 rounds against bbpPairings, same harness the other
  # figures in docs/engineering-log.md come from:
  #
  #     this cascade, before the stages     60.51% rounds / 93.6% pairs
  #     this cascade, stages ported         90.11% rounds / 96.82% pairs
  #     the per-bracket cascade (default)   90.29% rounds / 97.21% pairs
  #
  # So the architecture is vindicated - the missing 30 points really were
  # the refinement, exactly as predicted - but it lands on PARITY, three
  # rounds in 1689 behind the thing it was meant to beat, and it is still
  # behind on pairs. It stays off until it actually wins.
  #
  # Where the two differ is informative. This cascade is BETTER in the
  # middle rounds (3: 97.00 vs 93.50, 4: 97.40 vs 95.83, 5: 94.79 vs
  # 92.19) and worse in the late ones (7: 83.15 vs 84.24, 8: 80.24 vs
  # 82.04, 9: 66.47 vs 69.46). Late rounds are where legal pairings get
  # scarce, which is where the per-bracket cascade's backtracking earns
  # its keep - measured at 15 points of pairs on its own. This cascade has
  # no backtracking at all, by design, because bbpPairings has none.
  # Closing the remaining gap most likely means the whole-field
  # feasibility pre-pass bbpPairings runs first (dutch.cpp:825-837), which
  # is what lets it commit to a bracket decision without ever needing to
  # revisit one.
  #
  # ## Two things measured as INERT, and one of them removed
  #
  # The canonical lexicographic tie-break this engine relies on everywhere
  # else (`lex_scale/1`) was carried here too at first, below the reserved
  # space. It makes no difference whatever: removing it, and even
  # INVERTING it, both reproduce 1522/1689 and the same disagreement set,
  # byte for byte. The switch was verified to be live before believing
  # that - a bad value raises `CaseClauseError` from inside the run. So it
  # is gone from this path, which is also what makes the bignums small
  # enough to solve a bracket eight times over without cost.
  #
  # That is a real result, not a null one: a tie-break exists to choose
  # among equally-optimal matchings, and having nothing left to choose is
  # the claim bbpPairings' design makes for its own staged refinement.
  #
  # C9's rung measured inert on THIS fixture set, which runs at a 0% bye
  # rate and so barely exercises it. With byes it matters a great deal,
  # and its gate has to be ported in full to help rather than hurt: see
  # `bracket_loop/6`, where the dutch.cpp:1636-1643 clearing step lives.
  # Half-ported it measured WORSE than having no C9 rung at all.

  # THE pairing path. There is no longer a second one.
  #
  # A per-bracket cascade with backtracking used to sit behind this as a
  # fallback, and for a while it was the default. It is gone: this beat it
  # on every field size measured, and once the bracket loop stopped ending
  # a round early (see `bracket_loop/6`) the fallback stopped being
  # reached at all - zero times in ~1700 rounds, with byes and forfeits
  # on. Keeping ~950 lines of a second engine warm for a path nothing
  # takes is worse than not having it.
  #
  # What replaced it as the safety net is `repair_completion/3`, which is
  # part of THIS engine rather than a different one: if the staged
  # refinement leaves anyone unpairable, one whole-field matching fixes
  # the completion while keeping as much of the cascade's answer as it
  # can. Only when that also fails does `pair_later_round/1` raise
  # `NoValidPairingError`, which at that point is the truth - a
  # whole-field maximum matching could not pair everyone either.
  defp global_cascade(brackets, allowed_byes) do
    field =
      brackets
      |> List.flatten()
      |> Enum.sort_by(&{-&1.points, &1.rank})
      |> Enum.map(&Map.put(&1, :colour_stats, colour_stats(&1)))

    ctx = global_context(field)

    # Vertex ids for the round.s field matcher are positions in `field`,
    # which every bracket.s vertex set is a subsequence of. The matcher
    # itself is created lazily by the first field-graph `solve/1`, and
    # rebuilt after any bracket the local graph answered.
    Process.put(@round_matcher_key, {nil, ctx.field_index, length(field)})
    # Whole-field and round-scoped, like the matcher: see `build_oracle/3`.
    Process.put(@oracle_key, build_oracle(field, allowed_byes, ctx))

    {pairs, leftover} = run_brackets(field, ctx)

    # The staged refinement is not told how many byes are legal, so the
    # result is checked rather than assumed. Falling back to the
    # backtracking cascade beats emitting an illegal round.
    case check_completion(pairs, leftover, allowed_byes) do
      :ok ->
        {:ok, pairs, leftover}

      {:incomplete, reason} ->
        # The staged refinement finalises pairs one at a time and locks
        # them, so a bracket can in principle commit a pair that leaves
        # someone further down unpairable.
        #
        # The three engines guard this differently. bbpPairings proves a
        # complete matching exists before it starts and throws if not
        # (dutch.cpp:828 - a CHECK, with no repair anywhere), then trusts
        # its incremental matcher to preserve completeness. Gacrux
        # precomputes per-level feasibility ("hamilton") and uses it to
        # reject a bracket choice that would strand the rest. This one
        # repairs after the fact instead.
        if System.get_env("AINALRAMI_TRACE_FALLBACK"), do: IO.puts("[repair] #{reason}")

        case repair_completion(field, pairs, allowed_byes) do
          {:ok, repaired, repaired_leftover} = ok ->
            case check_completion(repaired, repaired_leftover, allowed_byes) do
              :ok -> ok
              {:incomplete, r} -> trace_fallback("repair failed: #{r} (was #{reason})")
            end

          :infeasible ->
            trace_fallback("no complete matching exists (#{reason})")
        end
    end
  end

  defp check_completion(_pairs, leftover, allowed_byes) do
    cond do
      length(leftover) > allowed_byes ->
        {:incomplete, "stranded #{length(leftover)}, allowed #{allowed_byes}"}

      not Enum.all?(leftover, &eligible_for_bye?/1) ->
        {:incomplete, "bye assignee is C2-ineligible"}

      not Enum.all?(leftover, &bye_score_ok?/1) ->
        {:incomplete, "bye assignee's score is above the C5 minimum"}

      true ->
        :ok
    end
  end

  # One whole-field matching that must (a) pair as many players as
  # possible, then (b) keep as much of the cascade's own answer as it can,
  # then (c) prefer pairing equal scores where it has to choose.
  #
  # (a) strictly above (b) is the point: the cascade's answer is already
  # the criteria-best one it could find, so the ONLY reason to overrule it
  # is that it left someone unpairable. Ranking cardinality first means
  # this breaks exactly as many of its pairs as completion requires and no
  # more - usually one, since the shortfall is usually a single pair.
  defp repair_completion(field, pairs, allowed_byes) do
    n = length(field)

    if n < 2 do
      :infeasible
    else
      arr = List.to_tuple(field)
      chosen = MapSet.new(pairs, fn {w, b} -> Enum.min_max([w, b]) end)

      # Five strictly-ordered bands. Cardinality first, so the repair
      # breaks exactly as many of the cascade's pairs as completion
      # demands - usually one, since the shortfall is usually one pair.
      #
      # Then the two ABSOLUTE criteria that constrain who may be left
      # over, both phrased the way `bye_assignee_score/2` phrases them:
      # pairing a player who may NOT take the bye is preferred, so
      # whoever ends up unmatched is someone C2 and C5 allow. Cardinality
      # alone does not pin this down - several maximum matchings usually
      # exist and they do not leave the same vertex out - so without
      # these bands the repair would hand `check_completion/3` a complete
      # matching whose leftover is a player who has already had a bye,
      # and the whole round was then refused as impossible. That was the
      # entire "illegal" column at high round counts: 142 rounds out of
      # 2126 at 39 rounds, every one of which bbpPairings paired legally.
      #
      # Preservation fourth, so among the completions that satisfy all of
      # the above it keeps as much as it can of the criteria-best answer
      # the cascade already found. The criteria themselves last, to
      # settle WHICH of several equally preserving completions to take:
      # without that the choice falls to the matcher's arbitrary
      # tie-break, and an arbitrary choice measurably loses rounds the
      # cascade had right.
      s = n + 1
      criteria_span = Integer.pow(s, 9)
      preserve = criteria_span * s
      bye_score_band = preserve * s
      eligibility_band = bye_score_band * s
      cardinality = eligibility_band * s

      edges =
        Enum.flat_map(0..(n - 2), fn i ->
          a = elem(arr, i)

          Enum.flat_map((i + 1)..(n - 1), fn j ->
            b = elem(arr, j)

            if legal_pair?(a, b) and colour_compatible?(a, b) do
              keep =
                if MapSet.member?(chosen, Enum.min_max([a.rank, b.rank])), do: preserve, else: 0

              eligibility = bit(not eligible_for_bye?(a)) + bit(not eligible_for_bye?(b))
              bye_score = bit(not bye_score_ok?(a)) + bit(not bye_score_ok?(b))

              weight =
                cardinality + eligibility * eligibility_band + bye_score * bye_score_band +
                  keep + repair_criteria(a, b, s)

              [{i, j, weight}]
            else
              []
            end
          end)
        end)

      matching = WeightedMatching.solve(n, edges)
      leftover = for i <- 0..(n - 1), not is_map_key(matching, i), do: elem(arr, i)

      if length(leftover) > allowed_byes do
        :infeasible
      else
        repaired =
          for {i, j} <- matching,
              i < j,
              do: assign_colour_with_history({elem(arr, i), elem(arr, j)})

        {:ok, repaired, leftover}
      end
    end
  end

  # The subset of the ladder that still means something with no brackets
  # to speak of: keep equal scores together (C6/C7's whole purpose),
  # satisfy colour (C10-C13), and respect float history (C14-C17). The
  # bracket-relative rungs - C8's reach, C9's bye gate - have no referent
  # in a whole-field matching and are left out rather than faked.
  defp repair_criteria(a, b, s) do
    {higher, lower} = order_by_placement(a, b)
    {c1, c2, c3, c4} = colour_criteria(higher, lower)
    {f1, f2, f3, f4} = float_criteria(higher, lower)

    ranked([
      {bit(a.points == b.points), s},
      {bit(c1), s},
      {bit(c2), s},
      {bit(c3), s},
      {bit(c4), s},
      {f1, s},
      {f2, s},
      {f3, s},
      {f4, s}
    ])
  end

  defp trace_fallback(reason) do
    if System.get_env("AINALRAMI_TRACE_FALLBACK"), do: IO.puts("[fallback] #{reason}")
    :infeasible
  end

  # Everything the ladder needs that is genuinely round-wide. The spans
  # themselves are per bracket - see `pair_bracket/6`.
  defp global_context(field) do
    bye_score = Process.get(@bye_score_key)

    # The weight bands, computed ONCE over the whole field and shared by
    # every bracket of the round. They used to be re-derived per bracket
    # from `combined` (`m + 1`, the scores present in the bracket's graph),
    # which rescaled every edge weight whenever the bracket changed -- and
    # that is what made each bracket boundary a cold solve: a matcher
    # cannot be carried across a boundary when every weight in it changes.
    #
    # bbpPairings computes `scoreGroupSizeBits` once over `sortedPlayers`
    # and never re-derives it (dutch.cpp:684-730), and `explain_round/3`
    # here already sized its bands over the field for exactly the reason
    # its comment gives: per-bracket scaling made rung values incomparable.
    # A radix is a radix; a span wider than any bracket needs only leaves
    # headroom in each band, never changes an ordering.
    {places, place_span} = score_places(field)
    count_span = length(field) + 1

    %{
      bye_score: bye_score,
      unplayed_ranks: unplayed_ranks(field, bye_score),
      odd_field?: rem(length(field), 2) == 1,
      first_single_bye?: Process.get(@first_single_bye_key, false),
      # Rank -> position in the round.s field: the vertex ids of the round
      # matcher and the oracle.
      field_index: field |> Enum.with_index() |> Map.new(fn {p, i} -> {p.rank, i} end),
      bands: %{
        places: places,
        place_span: place_span,
        count_span: count_span,
        reserve: 2 * count_span * count_span * count_span
      }
    }
  end

  # dutch.cpp:879-892. Rank the played-game counts of everyone who could
  # take the bye, most games played first, so a rung that MAXIMISES weight
  # prefers PAIRING the player with the most unplayed games - which is how
  # you leave the bye to someone with the fewest. Equal counts collapse
  # onto the last rank written, exactly as the C++ map assignment does.
  defp unplayed_ranks(_field, nil), do: %{}

  defp unplayed_ranks(field, bye_score) do
    field
    |> Enum.filter(&(&1.points == bye_score))
    |> Enum.map(&played_games/1)
    |> Enum.sort(:desc)
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {played, rank}, acc -> Map.put(acc, played, rank) end)
  end

  defp played_games(player), do: Enum.count(player.games, &played?/1)

  # dutch.cpp:981 - keep going while a bracket still has two players to
  # pair OR there is another score group to bring in.
  defp run_brackets(field, ctx) do
    case Enum.chunk_by(field, & &1.points) do
      [] -> {[], []}
      [first | rest] -> bracket_loop(first, 0, rest, ctx, [])
    end
  end

  # The FIRST bracket's C9 flag is not a bracket property at all - it is
  # read off the bootstrap whole-field matching that also produced the bye
  # assignee's score (dutch.cpp:851-870, ported in `first_single_bye?/4`).
  # Two earlier readings lived here: a hardcoded `true`, which is only
  # right for a field that is a single score group, and then "odd field
  # with an even number of players below", which was a guess at the same
  # thing without the matching to read it from.
  defp bracket_loop(by_index, sgb, rest_groups, ctx, pairs) do
    bracket_loop(by_index, sgb, rest_groups, ctx, pairs, ctx.first_single_bye?)
  end

  defp bracket_loop(by_index, _sgb, [], _ctx, pairs, _single_bye?) when length(by_index) <= 1 do
    {pairs, by_index}
  end

  defp bracket_loop(by_index, sgb, rest_groups, ctx, pairs, single_bye?) do
    nsgb = length(by_index)

    {next_group, rest} =
      case rest_groups do
        [] -> {[], []}
        [group | tail] -> {group, tail}
      end

    # The graph is the WHOLE remaining field - see `peek_groups/3`. Only
    # the current bracket and the next score group (`wsgb` players, the
    # exact analogue of bbpPairings' `playersByIndex`) are consumed or can
    # be finalised; everything past `wsgb` is visible to the matcher and
    # goes back to `rest` untouched.
    peek = peek_groups(rest, peek_budget(), [])
    wsgb = nsgb + length(next_group)

    {new_pairs, carried_all, new_sgb, carried_partner_scores} =
      pair_bracket(by_index ++ next_group ++ peek, sgb, nsgb, wsgb, ctx, single_bye?)

    peeked = MapSet.new(peek, & &1.rank)
    carried = Enum.reject(carried_all, &MapSet.member?(peeked, &1.rank))

    # dutch.cpp:1607-1643, computed at the END of a bracket for the NEXT
    # one. C9 applies only where a bracket downfloats exactly one player
    # and that player takes the bye, so the preliminary test (odd field, a
    # next group exists, and the bye's score is at or above it) is then
    # CLEARED if any carried player is already tentatively matched below
    # that group - because then the float runs deeper than one bracket and
    # the criterion does not apply.
    #
    # Leaving that clearing step out is not harmless. With it missing the
    # rung fired in brackets bbpPairings excludes, and measured WORSE than
    # having no C9 rung at all: 83.14% against 83.73% of exact rounds at
    # an 8% bye rate.
    #
    # ## Why the clearing step only started working once the matching went
    # ## whole-field
    #
    # `carried_partner_scores` is the score of each carried player's
    # TENTATIVE match. bbpPairings reads that off its one persistent
    # matcher over the entire remaining field, so the clearing player can
    # be tentatively matched to somebody several score groups away who has
    # nothing to do with this bracket. Instrumented C++ trace of
    # `seed1253-r7-p13`'s score-3.0 bracket:
    #
    #     DBG float id=9 tentative_match=10 match_score=1.5
    #                    next_group_score=3.0 gate_was=1
    #     DBG   -> gate CLEARED by this float
    #
    # Rank 10 has 1.5 points and is not a member of the 3.0 bracket at
    # all. A per-bracket solve scoped to a bracket-plus-peek window cannot
    # produce that tentative match, so it computed the gate as `true`,
    # applied C9, and landed on a different pairing.
    #
    # A parity stand-in used to sit here - "an even number of players
    # below the next bracket" - reasoning that an odd remainder forces the
    # next bracket to float two players and so cannot have a single bye
    # assignee. It was a proxy for exactly this clearing step, added when
    # the step could not be evaluated properly, and it is dropped now that
    # it can: bbpPairings has no such term (dutch.cpp:1608-1643 is the
    # whole rule), and keeping both means suppressing C9 in brackets the
    # reference scores it in.
    next_single_bye? =
      ctx.odd_field? and not is_nil(ctx.bye_score) and next_group != [] and
        ctx.bye_score >= hd(next_group).points and
        Enum.all?(carried_partner_scores, &(&1 >= hd(next_group).points))

    # bbpPairings loops unconditionally because by this point it has
    # already PROVED a complete legal matching exists - its whole-field
    # pre-pass throws `NoValidPairingException` otherwise (dutch.cpp:828).
    # This engine deliberately carries on when that pre-pass finds nothing
    # (`bye_assignee_score/2` returns nil rather than aborting), so a last
    # bracket whose players simply cannot play each other would spin here
    # forever: no pairs made, nothing consumed, same arguments next time.
    #
    # The test is whether a group was CONSUMED, not whether any are left.
    # An earlier version stopped on `rest == []`, which is the state after
    # popping the final group - so the round ended on the very iteration
    # that first brought that group in, before the players it carried had
    # any chance to pair with it. They were reported stranded and the
    # round was handed to the fallback engine. That single wrong condition
    # was most of the fallbacks.
    # `AINALRAMI_FORCE_STRAND=1` restores the old, wrong condition on
    # purpose. `repair_completion/3` is the engine's only completion
    # safety net and it never fires in normal running - measured zero
    # times across every configuration - which would leave it as untested
    # emergency code. This is the fault injection that tests it: with the
    # flag on, roughly a tenth of rounds strand, and the suite asserts
    # every one of them still comes out legal.
    stop? =
      if System.get_env("AINALRAMI_FORCE_STRAND"),
        do: rest == [] and new_pairs == [],
        else: next_group == [] and new_pairs == []

    if stop? do
      {pairs, carried}
    else
      bracket_loop(carried, new_sgb, rest, ctx, pairs ++ new_pairs, next_single_bye?)
    end
  end

  # How many score groups BEYOND the next one to put in the bracket's
  # graph. They are visible to the matcher and to C8, never consumed, and
  # nothing in them can be finalised.
  #
  # This is the single largest correction in the port. `dutch.cpp` appends
  # exactly one score group, and read literally that is what the C8 rungs
  # score - but C8 is "choose the set of downfloaters so that in the
  # FOLLOWING bracket every criterion from C1 to C7 is complied with", and
  # a bracket cannot check that against players it cannot see. Both
  # confirmed anomalies in `test/fixtures/open_questions/` have exactly
  # that signature: an identical current+next graph answering differently
  # depending on what lies below it.
  #
  # Global cascade, 200x9 against bbpPairings:
  #
  #     depth 0 (one group, the literal reading)  90.29% / 96.89%
  #     depth 1                                   94.14% / 98.17%
  #     depth 2                                   95.62% / 98.52%
  #     depth 3                                   95.91% / 98.63%
  #     depth 4                                   95.97% / 98.64%
  #     depth 6 and unbounded                     95.97% / 98.64%
  #
  # Zero illegal rounds at every depth, and it saturates at 4 (unbounded
  # measures identically, for more time).
  #
  # Budgeted in PLAYERS rather than groups, because groups are the wrong
  # unit: a 4-40 field has score groups of one to three, so four of them
  # is a handful of players and depth genuinely buys accuracy; a 60-120
  # field has groups big enough that ONE already supplies the same
  # context. Measured - 60-80 and 90-120 both score identically at depth
  # 1 and depth 4, while depth 4 costs 2.7x and 2.6x the time:
  #
  #     60-80 players    depth 1  99.44% / 99.97%   21s
  #                      depth 4  99.44% / 99.97%   57s
  #     90-120 players   depth 1  98.61% / 99.87%   64s
  #                      depth 4  98.61% / 99.87%  166s
  #
  # A player budget gets the small field's depth and the large field's
  # speed from one rule, and it is the same reasoning `depth_for/1` and
  # `per_count_limit/1` already use: a big bracket has more ways to pair,
  # so it needs less help.
  #
  # Note what this does NOT contradict: docs/engineering-log.md's "do not read the
  # lookahead as a licence to pair across brackets" still holds, and is
  # still enforced - `collect_bracket/1` keeps a pair only when both ends
  # are below `nsgb`. Seeing further and finalising further are different
  # things, and it was only ever the second one that measured badly.
  #
  # ## Why it is now UNBOUNDED
  #
  # bbpPairings' `matchingComputer` is one persistent matcher over the
  # whole remaining field, built once (dutch.cpp:738) and re-solved as
  # brackets are locked in. That is not the same object as a wide peek -
  # but the difference collapses, because `finalizePair` (common.h:164)
  # locks a pair by leaving its two vertices exactly one usable edge each
  # and zeroing every other edge incident on them. A vertex with a single
  # positive edge to a partner in the same state is ISOLATED: any matching
  # either takes that edge or leaves both ends unmatched, and taking it is
  # strictly better and blocks nothing. So a finalised pair contributes
  # nothing to the rest of the optimisation, and dropping those vertices
  # from the graph - which is what carrying only the unpaired players
  # forward already does - gives the identical matching on the identical
  # remaining vertices.
  #
  # What is left is the SCOPE, and that is what an unbounded peek supplies:
  # every unfinalised player is a vertex, so a player floating out of this
  # bracket gets a real tentative match against the field below it instead
  # of no match at all. `bracket_loop/6`'s C9 gate is derived from exactly
  # those tentative matches, and could not be evaluated correctly while
  # the graph stopped a few groups down.
  #
  # A wide peek ALONE was measured earlier and changed nothing (docs/engineering-log.md:
  # `AINALRAMI_PEEK=999` left the disputed cases exactly as they were),
  # which is consistent: without the gate reading the wider matching, the
  # extra vertices had nothing to say. The two halves only work together.
  #
  # The weights stay bracket-flavoured throughout, and that is faithful
  # rather than a shortcut. `reach_table/3` grades every visible player by
  # how far below the bracket they sit, `in_current` is `reach == 0` and
  # C8 is `reach == 1`, so a pair two or more groups down scores only the
  # completion rung and C9 - exactly the weight bbpPairings leaves on its
  # own out-of-window edges (`computeEdgeWeight` with both
  # `lowerPlayerInCurrentBracket` and `lowerPlayerInNextBracket` false,
  # dutch.cpp:766-786's bootstrap). The one knowing difference: bbpPairings
  # never REFRESHES those out-of-window edges, so they keep the C9 gate
  # value the bootstrap pass computed, where these are recomputed with the
  # current bracket's gate.
  @peek_budget :unbounded

  defp peek_budget do
    case System.get_env("AINALRAMI_PEEK") do
      nil -> @peek_budget
      n -> String.to_integer(n)
    end
  end

  # Whole score groups, never a partial one - a bracket that could see
  # half of a group would score C8 against a fiction. `:unbounded` takes
  # everything that is left, which is the default; the numeric budget is
  # kept so `AINALRAMI_PEEK=<n>` can still narrow the graph for measurement.
  defp peek_groups([], _budget, acc), do: List.flatten(Enum.reverse(acc))
  defp peek_groups(rest, :unbounded, acc), do: List.flatten(Enum.reverse([rest | acc]))
  defp peek_groups(_rest, budget, acc) when budget <= 0, do: List.flatten(Enum.reverse(acc))

  defp peek_groups([group | rest], budget, acc) do
    peek_groups(rest, budget - length(group), [group | acc])
  end

  # `sgb` is where the residents start (everything before it is a
  # moved-down player), `nsgb` where the bracket ends, and `wsgb` where the
  # NEXT SCORE GROUP ends - bbpPairings' `playersByIndex.size()`. Anything
  # from `wsgb` on is visible to the matcher only: it can never be
  # finalised, consumed, or exchanged into, and it exists so that players
  # leaving this bracket get a realistic tentative match (see
  # `peek_groups/3`).
  # A bracket is paired on one of two graphs.
  #
  # The FIELD graph is the whole remaining field, one matcher for the
  # round, the eight stages re-solving it at every step -- bbpPairings'
  # design, and the one every number in docs/validation.md was measured
  # on. It is exact and it is n^3 a round: 85 s for 1,000 players.
  #
  # The LOCAL graph is the bracket alone. It is exact too, but only under
  # conditions this function checks first, and the argument for it goes
  # like this. Suppose the bracket has an even number of members, every one
  # of them a non-candidate for the bye, and suppose (a) the bracket has a
  # perfect internal matching on legal edges and (b) the rest of the field
  # can be perfectly matched among themselves (leaving the one bye, if any,
  # on a bye candidate). Then every matching that is optimal on the ladder
  # pairs the bracket internally: the completion rung is maximal with the
  # bracket internal, by (a) and (b), and C6 -- pairs inside the bracket,
  # which outranks everything below it -- is maximal ONLY with the bracket
  # internal. An internal bracket shares no edge with the rest, so the
  # optimum splits: the bracket's part is the optimum over the bracket's
  # own edges with the bracket's own weights, which is what the local graph
  # computes, and the rest's part is constant across every candidate. The
  # eight stages only ever add to bracket-internal edges, in the reserve
  # band below every rung, so none of them can break (a)'s internality
  # either, and each stage's optimum is again the local one.
  #
  # (a) is what the local graph's own first solve establishes -- the
  # completion rung is the top rung, so its maximum-weight matching is a
  # maximum-cardinality one, and it is perfect or it is not. (b) is what
  # `oracle_completable?/2` establishes: a sparse maximum-cardinality
  # matching over the field with this bracket removed, sound in the
  # direction that matters (a matching it finds is real; one it misses
  # costs a fall back to the field graph, never a wrong answer). The
  # non-candidate condition is what makes the completion rung's per-vertex
  # terms a constant for the bracket and keeps C9 and the C9 gate out of
  # it -- see `local_eligible?/4`.
  #
  # What the local graph does NOT claim is the tie-break. When two
  # matchings tie on every rung and on the nearness term, the two graphs
  # could in principle settle it differently; the stages are built to
  # leave no such tie, and the corpus is the judge.
  # Two paths only so the debug trace can time and label a bracket without
  # costing anything when it is switched off: `Log.debug?/0` is one
  # application-env read per bracket, and the timing wrapper is not built
  # at all otherwise. See `Ainalrami.Log`.
  defp pair_bracket(combined, sgb, nsgb, wsgb, ctx, single_bye?) do
    if Log.debug?() do
      {us, {path, result}} =
        :timer.tc(fn -> pair_bracket_solve(combined, sgb, nsgb, wsgb, ctx, single_bye?) end)

      Log.debug(fn -> bracket_trace(combined, sgb, nsgb, wsgb, path, us) end)
      result
    else
      {_path, result} = pair_bracket_solve(combined, sgb, nsgb, wsgb, ctx, single_bye?)
      result
    end
  end

  # `path` says which of the three routes the bracket took, which is the
  # first thing worth knowing when one is slow or wrong: `idle` did no
  # work, `local` solved the bracket on its own graph, `field` fell back to
  # the whole remaining field. See `pair_bracket/6`'s own comment and
  # docs/engineering-log.md, "The local graph".
  defp pair_bracket_solve(combined, sgb, nsgb, wsgb, ctx, single_bye?) do
    m = length(combined)

    with false <- idle_bracket?(combined, nsgb, wsgb, ctx),
         true <- local_eligible?(combined, nsgb, wsgb, ctx),
         {:ok, result} <- attempt_local(combined, m, sgb, nsgb, wsgb, ctx, single_bye?) do
      {:local, result}
    else
      :idle ->
        {:idle, {[], combined, nsgb, Enum.map(Enum.take(combined, min(wsgb, m)), & &1.points)}}

      _ ->
        {:field, attempt_field(combined, m, sgb, nsgb, wsgb, ctx, single_bye?)}
    end
  end

  # `nsgb` is the bracket's own size and `sgb` its moved-down count, which
  # are the two numbers that actually predict cost -- not `length(combined)`,
  # which includes the peek and is routinely the whole field on a cheap
  # bracket.
  defp bracket_trace(combined, sgb, nsgb, wsgb, path, us) do
    score =
      case combined do
        [%{points: p} | _] -> :erlang.float_to_binary(p / 1, decimals: 1)
        _ -> "?"
      end

    "bracket score=#{score} size=#{nsgb} mdps=#{sgb} window=#{wsgb} " <>
      "combined=#{length(combined)} path=#{path} #{us}us"
  end

  # A bracket with fewer than two members cannot finalise a pair at all --
  # `collect_bracket/1` records one only when BOTH ends are inside the
  # bracket -- so the whole solve exists for its tentative matching, and
  # the only thing downstream reads that for is `carried_partner_scores`,
  # which feeds `bracket_loop/6`.s C9 gate and nothing else. When that
  # gate.s own preconditions do not hold, the solve has no observable
  # effect and is skipped: the bracket carries everyone forward, its
  # members counted as this round.s downfloaters, and every carried player
  # reports their own score, which is what an unmatched vertex reports
  # anyway (bbpPairings reads one as matched to itself).
  #
  # This is not a rare shape. A lone leader at the top of a large Swiss is
  # the FIRST bracket of the round, so the graph it was solving was the
  # whole field: 660 ms of a 1,334 ms round at 400 players, for nothing.
  defp idle_bracket?(combined, nsgb, wsgb, ctx) do
    if nsgb < 2, do: not c9_gate_live?(combined, nsgb, wsgb, ctx) && :idle, else: false
  end

  # The first four conjuncts of `bracket_loop/6`.s `next_single_bye?`, the
  # ones that do not depend on the tentative matching. False here and the
  # gate is false whatever the carried players report.
  defp c9_gate_live?(combined, nsgb, wsgb, ctx) do
    ctx.odd_field? and not is_nil(ctx.bye_score) and wsgb > nsgb and
      ctx.bye_score >= Enum.at(combined, nsgb).points
  end

  # The bracket can be paired on its own graph only if its members are all
  # non-candidates for the bye -- which on an odd field means everyone in
  # the window scores above `bye_score`, and on an even one means nobody in
  # the window is an eligible player on zero points (`bye_candidate?/2`'s
  # even-field reading). That is what keeps three things out of the local
  # computation: the completion rung's `!isByeCandidate` terms are then the
  # same for every bracket member; `c9_rank/3` is zero for everyone in it;
  # and `bracket_loop/6`'s C9 gate for the NEXT bracket cannot fire, since
  # it needs the bye score to reach the next group. The local path's
  # tentative matching says nothing about the field below, which is fine
  # precisely because nothing downstream reads it here.
  #
  # An ODD bracket floats one member, and who floats is decided jointly
  # with the field below. The local graph stands the next score group in
  # with ONE vertex (`local_graph_length/1`), and that is exact when two
  # things hold -- see `stand_in_edges/7` for the argument:
  #
  #   * every member of the bracket has at least one legal, colour-
  #     compatible partner in the next group, so every one of them can
  #     take the C8 float and none is forced deeper; and
  #   * the next group is large enough that taking any one member out of
  #     it leaves it as well off as taking any other -- its internal
  #     matching number unchanged, its own float (if the parity forces
  #     one) still placeable below. That is a property of a DENSE group,
  #     and `@local_min_next_group` is where "dense enough" is drawn: a
  #     group that size with the legality a real event has is never
  #     fragile, and brackets over smaller groups are cheap on the field
  #     graph anyway, since the field below them is small.
  #
  # The second condition is the one that is not certified term by term,
  # and it is the one the corpus is asked to judge: the small-field axes
  # put every bracket on the field graph, and the 60-120 and 150-250
  # axes put the large ones here.
  @local_min_next_group 16

  defp local_eligible?(combined, nsgb, wsgb, ctx) do
    window = Enum.take(combined, min(wsgb, length(combined)))

    System.get_env("AINALRAMI_NOFAST") == nil and nsgb >= 2 and
      Enum.all?(window, fn p ->
        if ctx.odd_field?,
          do: not is_nil(ctx.bye_score) and p.points > ctx.bye_score,
          else: not bye_candidate?(p, nil)
      end) and
      (rem(nsgb, 2) == 0 or floats_placeable?(combined, nsgb, wsgb))
  end

  defp floats_placeable?(combined, nsgb, wsgb) do
    {bracket, rest} = Enum.split(combined, nsgb)
    next_group = Enum.take(rest, wsgb - nsgb)

    length(next_group) >= @local_min_next_group and
      Enum.all?(bracket, fn a ->
        Enum.any?(next_group, fn b -> legal_pair?(a, b) and colour_compatible?(a, b) end)
      end)
  end

  # The local graph is the bracket -- plus, for an odd bracket, one vertex
  # at position `nsgb` standing in for the whole next score group.
  defp local_graph_length(nsgb), do: nsgb + rem(nsgb, 2)

  # The stand-in's edges: one per bracket member that has a legal,
  # colour-compatible partner in the next group, weighted as that member's
  # float edge.
  #
  # Why one vertex is exact. Under the eligibility conditions an odd
  # bracket's optimum has exactly one member F floating into the next
  # group: C6 wants the other (b-1)/2 pairs internal, and C8 and its score
  # term put the float in the NEXT group rather than deeper, which
  # `floats_placeable?/3` says it always can be. The float edge (F, G)
  # scores the completion rung, C8 and C8's score term and nothing else --
  # every other rung is gated on `in_current`, and under `local_eligible?/4`
  # the completion rung's per-vertex terms are the same for every G -- so
  # its weight depends on F alone and is the same for every legal G. What
  # the field below is worth once G is gone is, by the density condition,
  # the same whichever G it was. So what decides F is the bracket's
  # internal optimum without F plus F's own float weight: the local graph
  # with the stand-in, exactly. The stand-in's weight for F is computed
  # against F's first legal partner in the group, which by the above is
  # the weight against any of them.
  #
  # The stand-in also carries the right tie-break. The nearness term on a
  # real float edge (F, G) is `n - (G - F)`; two bracket members compare
  # on it by `F - F'` whatever G is, and that is what a stand-in at a fixed
  # position gives them too.
  defp stand_in_edges(base, arr, sgb, nsgb, wsgb, ctx, bands, single_bye?) do
    if rem(nsgb, 2) == 0 do
      base
    else
      Enum.reduce(0..(nsgb - 1)//1, base, fn i, acc ->
        a = elem(arr, i)

        g =
          Enum.find(nsgb..(wsgb - 1)//1, fn j ->
            b = elem(arr, j)
            legal_pair?(a, b) and colour_compatible?(a, b)
          end)

        case g && bracket_edge_weight(a, elem(arr, g), nsgb, sgb, 1, ctx, bands, single_bye?) do
          nil -> acc
          w -> Map.put(acc, {i, nsgb}, w)
        end
      end)
    end
  end

  defp attempt_local(combined, m, sgb, nsgb, wsgb, ctx, single_bye?) do
    wl = local_graph_length(nsgb)
    st = new_bracket(:local, combined, m, sgb, nsgb, wsgb, wl, ctx, single_bye?) |> solve()

    if map_size(st.matching) == wl do
      {pairs, _, _, _} = result = st |> run_stages() |> collect_bracket()

      # Condition (b): with this bracket's finalised players gone, the rest
      # -- the floater included, on an odd bracket -- can still be paired.
      positions =
        Enum.flat_map(pairs, fn {w, b} ->
          [Map.fetch!(ctx.field_index, w), Map.fetch!(ctx.field_index, b)]
        end)

      case oracle_completable?(Process.get(@oracle_key), positions) do
        {:ok, oracle} ->
          # The bracket is out of the field for good, for the oracle and
          # for the field matcher alike: the next field-graph bracket
          # rebuilds its matcher from the players that remain.
          Process.put(@oracle_key, oracle)
          {_, field_index, field_size} = Process.get(@round_matcher_key)
          Process.put(@round_matcher_key, {nil, field_index, field_size})
          {:ok, result}

        :no ->
          :field
      end
    else
      :field
    end
  end

  defp attempt_field(combined, m, sgb, nsgb, wsgb, ctx, single_bye?) do
    {pairs, _, _, _} =
      result =
      new_bracket(:field, combined, m, sgb, nsgb, wsgb, m, ctx, single_bye?)
      |> solve()
      |> run_stages()
      |> flush_live()
      |> collect_bracket()

    # Keep the oracle in step: whoever this bracket finalised is out of the
    # field for every later bracket's (b).
    positions =
      Enum.flat_map(pairs, fn {w, b} ->
        [Map.fetch!(ctx.field_index, w), Map.fetch!(ctx.field_index, b)]
      end)

    Process.put(@oracle_key, oracle_remove(Process.get(@oracle_key), positions))
    result
  end

  defp new_bracket(mode, combined, m, sgb, nsgb, wsgb, wl, ctx, single_bye?) do
    arr = List.to_tuple(combined)
    Process.delete(@dirty_key)

    # Field-wide and constant for the round -- see `global_context/2`. That
    # is what bbpPairings does too: `scoreGroupSizeBits`/`scoreGroupShifts`
    # are computed once over `sortedPlayers` and never re-derived per
    # bracket (dutch.cpp:684-730). It is also what makes the weights
    # commensurable: one solve mixes edges scored for this bracket with
    # edges scored as plain completability, and two differently-scaled
    # radices cannot be compared.
    bands = ctx.bands

    # The field graph scores the whole field only when it is about to BUILD
    # the round matcher from it; once built, a bracket boundary is the
    # window's edges changing on an existing graph.
    {round_matcher, _, _} = Process.get(@round_matcher_key)

    base =
      case mode do
        :local ->
          arr
          |> base_edge_weights(m, sgb, nsgb, nsgb, ctx, bands, single_bye?)
          |> stand_in_edges(arr, sgb, nsgb, wsgb, ctx, bands, single_bye?)

        :field ->
          scored = if round_matcher != nil, do: min(wsgb, m), else: m
          base_edge_weights(arr, m, sgb, nsgb, scored, ctx, bands, single_bye?)
      end

    %{
      mode: mode,
      arr: arr,
      m: m,
      wl: wl,
      sgb: sgb,
      nsgb: nsgb,
      wsgb: wsgb,
      ctx: ctx,
      bands: bands,
      base: base,
      live: base,
      wm: nil,
      synced: false,
      transposition: transposition_terms(m, sgb, nsgb),
      # Any value above every real weight will do: `finalize_pair/3`
      # leaves the two vertices exactly one usable edge each, so the pair
      # is forced regardless of magnitude.
      max_w: 1 + (base |> Map.values() |> Enum.max(fn -> 0 end)),
      matched: MapSet.new(),
      matching: %{},
      remainder: [],
      remainder_pairs: 0,
      exchange_count: 0
    }
  end

  defp run_stages(st) do
    st
    |> trace_stage("initial solve")
    |> stage_select_mdps()
    |> trace_stage("1 select MDPs")
    |> stage_mdp_opponents()
    |> trace_stage("2 MDP opponents")
    |> stage_build_remainder()
    |> trace_stage("3 remainder")
    |> stage_exchange_weights()
    |> trace_stage("4 exchange weights")
    |> stage_exchange_lower_from_higher()
    |> trace_stage("5 lower-from-higher")
    |> stage_exchange_higher_from_lower()
    |> trace_stage("6 higher-from-lower")
    |> stage_reset_exchange_bits()
    |> trace_stage("7 reset bits")
    |> stage_first_group_partners()
    |> trace_stage("8 first-group partners")
  end

  # How many pairs the bracket would KEEP if it stopped here. Set
  # AINALRAMI_TRACE=1 to watch it across the eight stages: the count should
  # never fall, and a stage where it does is dropping a pair the criteria
  # say it should have kept.
  defp trace_stage(st, label) do
    if System.get_env("AINALRAMI_TRACE") do
      kept =
        Enum.count(0..(st.m - 1)//1, fn i ->
          p = partner(st, i)
          i < st.nsgb and p != i and p < st.nsgb and i < p
        end)

      ranks = st.arr |> Tuple.to_list() |> Enum.map(& &1.rank)

      matched =
        for i <- 0..(st.m - 1)//1,
            p = partner(st, i),
            p != i and i < p,
            do: {Enum.at(ranks, i), Enum.at(ranks, p)}

      IO.puts(
        "    [trace] m=#{st.m} sgb=#{st.sgb} nsgb=#{st.nsgb} #{label}: #{kept} internal" <>
          " | #{inspect(ranks, charlists: :as_lists)} -> #{inspect(matched, charlists: :as_lists)}"
      )
    end

    st
  end

  ## ---------- the graph ----------

  defp put_w(weights, i, j, w) when i < j, do: Map.put(weights, {i, j}, w)
  defp put_w(weights, i, j, w), do: Map.put(weights, {j, i}, w)

  defp get_w(weights, i, j) when i < j, do: Map.get(weights, {i, j}, 0)
  defp get_w(weights, i, j), do: Map.get(weights, {j, i}, 0)

  # `put_w/4` for the LIVE weights: the same write, plus a note of which
  # vertex was modified. `i` is the modified vertex and `j` its neighbour,
  # in that order, at every call site -- the same order `dutch.cpp` passes
  # them to `setEdgeWeight(modifiedVertex, neighbor)`, and for the same
  # reason: the matcher re-prepares exactly the modified end of each
  # changed edge, and the cost of the next solve is proportional to how
  # many DISTINCT vertices were modified (computer.cpp:69-71: "after calls
  # to setEdgeWeight using at most k different values for modifiedVertex,
  # the subsequent computeMatching() operation will take O(k n^2) time").
  # A whole-map diff of `live` cannot recover that vertex, and preparing
  # the lower-indexed end instead made `finalize_pair/3` prepare every
  # earlier vertex the pair still had an edge to: ~10.7 stages per
  # in-bracket solve where the reference's contract needs two or three.
  defp set_live(live, i, j, w) do
    Process.put(@dirty_key, [{i, j} | Process.get(@dirty_key, [])])
    put_w(live, i, j, w)
  end

  defp solve(%{mode: :local} = st), do: solve_local(st)
  defp solve(st), do: solve_field(st)

  # The LOCAL graph: the bracket's own `nsgb` vertices, bracket-local
  # indices, one fresh matcher per bracket, the full ladder on every edge.
  # See `pair_bracket/6` for when this is exact. The weights carry the
  # same nearness term as the field graph's (`edge_weigher/3`), on the
  # same positions -- the bracket is a prefix of `arr` -- so the two graphs
  # agree on every tie the term can break.
  defp solve_local(st) do
    weigh = edge_weigher(st, & &1, st.m)
    dirty = Process.get(@dirty_key, [])
    Process.delete(@dirty_key)

    wm =
      case st.wm do
        nil ->
          # The same bound `solve_field/1` uses, minus the round scale: the
          # transposition tie-break's scale is per bracket and this matcher
          # is too.
          s = st.bands.count_span
          ps = st.bands.place_span
          span_product = Integer.pow(s, 12) * Integer.pow(ps, 6) * Integer.pow(s, 4) * 64

          ceiling =
            2 * span_product * st.bands.reserve * st.transposition.scale * s *
              (st.m * st.m + 1)

          list = for {{i, j}, w} <- st.live, w > 0, j < st.wl, do: {i, j, weigh.(i, j, w)}
          WeightedMatching.new(st.wl, list, max_weight: ceiling, gcd: 1)

        wm ->
          {wm, _seen} =
            Enum.reduce(dirty, {wm, MapSet.new()}, fn {i, j} = key, {acc, seen} ->
              cond do
                i >= st.wl or j >= st.wl ->
                  {acc, seen}

                MapSet.member?(seen, key) ->
                  {acc, seen}

                true ->
                  want = weigh.(i, j, get_w(st.live, i, j))

                  acc =
                    if WeightedMatching.edge_weight(acc, i, j) == want,
                      do: acc,
                      else: WeightedMatching.set_weight(acc, i, j, want)

                  {acc, MapSet.put(seen, key)}
              end
            end)

          wm
      end

    {wm, matching} = WeightedMatching.solve(wm)
    %{st | wm: wm, matching: matching}
  end

  ## ------------------------------------------- the completability oracle
  #
  # One question, asked once per bracket that wants the local graph: with
  # this bracket taken out, can everyone who is left still be paired --
  # leaving the one bye, if any, on a bye candidate? That is condition (b)
  # of `pair_bracket/6`, and it is a MAXIMUM-CARDINALITY question with a
  # per-vertex preference, which two things make cheap:
  #
  #   * **Sparse.** Each player keeps only their `@oracle_degree` nearest
  #     legal, colour-compatible opponents below them in the field order
  #     (and inherits the same from above), so the graph is O(n) edges
  #     rather than O(n^2). Sound in the direction that matters: a
  #     matching of a subgraph is a matching of the graph. A false NEGATIVE
  #     is possible -- the sparse graph may miss a matching the dense one
  #     has -- and it costs a fall back to the field graph for that
  #     bracket, never a wrong answer.
  #
  #   * **Small weights.** `B + K*(noncand(i) + noncand(j)) + (n - |i-j|)`
  #     with `B > n*K + n^2 > K > n^2/2`: one more pair beats any number
  #     of matched non-candidates, one more matched non-candidate beats
  #     any amount of nearness, and the nearness term breaks the ties that
  #     would otherwise make every edge tight. So maximum weight is maximum
  #     cardinality, then most non-candidates matched -- the shape of the
  #     completion rung exactly -- then nearest.
  #
  # Removing a bracket is edge removal on a persistent map, so the
  # pre-removal oracle is kept for free and simply discarded when the
  # answer is good.
  @oracle_degree 12

  defp build_oracle(field, allowed_byes, ctx) do
    arr = List.to_tuple(field)
    n = length(field)

    noncand =
      for i <- 0..(n - 1)//1, into: %{} do
        {i, bit(not bye_candidate?(elem(arr, i), ctx.bye_score))}
      end

    edges =
      for i <- 0..(n - 1)//1,
          j <-
            Enum.reduce_while((i + 1)..(n - 1)//1, {[], 0}, fn j, {acc, taken} ->
              cond do
                taken >= @oracle_degree ->
                  {:halt, {acc, taken}}

                legal_pair?(elem(arr, i), elem(arr, j)) and
                    colour_compatible?(elem(arr, i), elem(arr, j)) ->
                  {:cont, {[j | acc], taken + 1}}

                true ->
                  {:cont, {acc, taken}}
              end
            end)
            |> elem(0),
          do: {i, j, oracle_weight(i, j, n, noncand)}

    %{
      state: WeightedMatching.new(n, edges, max_weight: oracle_ceiling(n), gcd: 1),
      n: n,
      allowed_byes: allowed_byes,
      noncand: noncand,
      gone: MapSet.new()
    }
  end

  defp oracle_weight(i, j, n, noncand) do
    k = n * n
    b = n * k + n * n + 1
    b + k * (Map.fetch!(noncand, i) + Map.fetch!(noncand, j)) + (n - abs(j - i))
  end

  defp oracle_ceiling(n), do: n * n * n + 4 * n * n + n + 1

  # Condition (b) for `positions` as the bracket: take them out, re-solve,
  # and look at who is left unmatched among the players still in the field.
  # `{:ok, oracle}` carries the state with the bracket gone, to keep if the
  # bracket is accepted.
  defp oracle_completable?(oracle, positions) do
    oracle = oracle_remove(oracle, positions)

    unmatched =
      for v <- 0..(oracle.n - 1)//1,
          not MapSet.member?(oracle.gone, v),
          WeightedMatching.mate_of(oracle.state, v) == nil,
          do: v

    if length(unmatched) <= oracle.allowed_byes and
         Enum.all?(unmatched, &(Map.fetch!(oracle.noncand, &1) == 0)),
       do: {:ok, oracle},
       else: :no
  end

  # `positions` leave the field: every edge at each of them goes, and the
  # matching is re-solved around the hole.
  defp oracle_remove(oracle, []), do: oracle

  defp oracle_remove(oracle, positions) do
    state =
      Enum.reduce(positions, oracle.state, fn v, acc ->
        acc
        |> WeightedMatching.neighbours(v)
        |> Enum.reduce(acc, fn {u, _w}, acc -> WeightedMatching.set_weight(acc, v, u, 0) end)
      end)

    {state, _} = WeightedMatching.solve(state)
    %{oracle | state: state, gone: MapSet.union(oracle.gone, MapSet.new(positions))}
  end

  # The FIELD graph: the whole remaining field, one matcher for the round,
  # carried across every bracket.
  defp solve_field(st) do
    {round_matcher, field_index, field_size} = Process.get(@round_matcher_key)
    to_field = fn i -> Map.fetch!(field_index, elem(st.arr, i).rank) end
    weigh = edge_weigher(st, to_field, field_size)
    dirty = Process.get(@dirty_key, [])
    Process.delete(@dirty_key)

    # One matcher for the whole ROUND, carried across every bracket.
    #
    # Every bracket's vertex set is a subsequence of the round's field
    # order, and the bands are field-wide and constant (`global_context/1`),
    # so a bracket boundary is a set of edge changes on one graph rather
    # than a new graph. Vertex ids are positions in `field`; bracket-local
    # indices are translated on the way in and back on the way out.
    #
    # Three ways in:
    #
    #   * no matcher yet -- the round's first bracket builds it;
    #   * a bracket's FIRST solve -- its `live` is a fresh
    #     `base_edge_weights/7`, so the matcher's edges on this bracket's
    #     vertices are diffed against it and the differences applied. The
    #     far edges are frozen (`:far_weights`), so that diff is the new
    #     bracket's own pairs and its edges into the next group, not the
    #     whole graph;
    #   * every later solve of the same bracket -- exactly the edges the
    #     stages wrote through `set_live/4`, each prepared at its modified
    #     vertex, as `setEdgeWeight` would have been called.
    matcher =
      cond do
        round_matcher == nil ->
          # Ceiling for the ROUND -- must exceed every weight ANY bracket can
          # produce, not just this one's. `st.max_w` is per bracket and a later
          # bracket's can be larger (different sgb/MDP structure, same bands),
          # which the guard caught as "weight exceeds the initial dual" on
          # 4-player fields where the first bracket is trivial.
          #
          # A safe bound from the packing itself: `ranked/1` packs rungs as
          # `acc * span + value` with every span from the field-wide `bands`,
          # so the product of the spans bounds any base weight; times the
          # reserve band the stages add into; times the largest transposition
          # scale any bracket can reach, `(n + 2)^(n/2 + 1)`, when that
          # tie-break is switched on; doubled for room. Too LARGE is
          # harmless -- it is only the initial dual, and bbpPairings'
          # `aboveMaxEdgeWeight` is likewise a bound, not exact.
          n = field_size
          s = st.bands.count_span
          ps = st.bands.place_span
          span_product = Integer.pow(s, 12) * Integer.pow(ps, 6) * Integer.pow(s, 4) * 64

          round_scale =
            if st.transposition.scale == 1, do: 1, else: Integer.pow(n + 2, div(n, 2) + 1)

          round_ceiling = 2 * span_product * st.bands.reserve * round_scale * s * (n * n + 1)

          list =
            for {{i, j}, w} <- st.live, w > 0 do
              {to_field.(i), to_field.(j), weigh.(i, j, w)}
            end

          WeightedMatching.new(field_size, list, max_weight: round_ceiling, gcd: 1)

        not st.synced ->
          # Bracket boundary. For every vertex of the WINDOW (the bracket and
          # the next score group -- see `base_edge_weights/8`), the matcher's
          # edges to other window vertices must become exactly `live`'s.
          # Everything else stays: edges into the far field are the frozen
          # completability weights set with the first bracket, and edges to
          # finalised players were zeroed when they were finalised. Applied
          # lower-index first, which is also the near-minimal set of vertices
          # to prepare: the changes are a clique on the new bracket's
          # residents plus their edges into the next group.
          last = min(st.wsgb, st.m) - 1
          here = Map.new(0..last//1, fn i -> {to_field.(i), i} end)

          Enum.reduce(0..last//1, round_matcher, fn i, acc ->
            fi = to_field.(i)

            # Edges the matcher has from `fi` into this graph that `live`
            # does not have, or has at a different weight.
            acc =
              Enum.reduce(WeightedMatching.neighbours(acc, fi), acc, fn {fj, cur}, acc ->
                case Map.get(here, fj) do
                  nil ->
                    acc

                  j when j < i ->
                    acc

                  j ->
                    want = weigh.(i, j, get_w(st.live, i, j))
                    if want == cur, do: acc, else: WeightedMatching.set_weight(acc, fi, fj, want)
                end
              end)

            # Edges `live` has from `i` that the matcher lacks.
            Enum.reduce((i + 1)..last//1, acc, fn j, acc ->
              case get_w(st.live, i, j) do
                0 ->
                  acc

                w ->
                  fj = to_field.(j)
                  want = weigh.(i, j, w)

                  if WeightedMatching.edge_weight(acc, fi, fj) == want,
                    do: acc,
                    else: WeightedMatching.set_weight(acc, fi, fj, want)
              end
            end)
          end)

        true ->
          apply_dirty(round_matcher, st, dirty, to_field, weigh)
      end

    {matcher, matching_f} = WeightedMatching.solve(matcher)

    # Back to bracket-local indices; anything matched outside this
    # bracket's vertex set is another bracket's business.
    from_field = Map.new(0..(st.m - 1)//1, fn i -> {to_field.(i), i} end)

    matching =
      Enum.reduce(matching_f, %{}, fn {a, b}, acc ->
        case {Map.get(from_field, a), Map.get(from_field, b)} do
          {nil, _} -> acc
          {_, nil} -> acc
          {i, j} -> Map.put(acc, i, j)
        end
      end)

    Process.put(@round_matcher_key, {matcher, field_index, field_size})
    %{st | matching: matching, synced: true}
  end

  # The stages' writes since the last solve, most recent first. Each
  # `{modified, neighbour}` pair is applied once, at `live`'s current (final)
  # value; a write that left the matcher's weight as it was is skipped,
  # which prepares nothing the reference would not also have left
  # untouched in effect.
  defp apply_dirty(matcher, st, dirty, to_field, weigh) do
    {matcher, _seen} =
      Enum.reduce(dirty, {matcher, MapSet.new()}, fn {i, j} = key, {acc, seen} ->
        if MapSet.member?(seen, key) do
          {acc, seen}
        else
          fi = to_field.(i)
          fj = to_field.(j)
          want = weigh.(i, j, get_w(st.live, i, j))

          acc =
            if WeightedMatching.edge_weight(acc, fi, fj) == want,
              do: acc,
              else: WeightedMatching.set_weight(acc, fi, fj, want)

          {acc, MapSet.put(seen, key)}
        end
      end)

    matcher
  end

  # Push the stages' writes since the last solve into the round matcher
  # WITHOUT solving -- called once at the end of every bracket, so that the
  # next bracket's boundary diff starts from a matcher whose edges equal
  # this bracket's final `live`. Without it the last `finalize_pair/3` of a
  # bracket (which always follows its last solve) would be lost, and the
  # finalised pair's stale edges into the next bracket would still be in
  # the graph.
  defp flush_live(st) do
    case Process.get(@round_matcher_key) do
      {nil, _, _} ->
        st

      {matcher, field_index, field_size} ->
        dirty = Process.get(@dirty_key, [])
        Process.delete(@dirty_key)
        to_field = fn i -> Map.fetch!(field_index, elem(st.arr, i).rank) end

        matcher =
          apply_dirty(matcher, st, dirty, to_field, edge_weigher(st, to_field, field_size))

        Process.put(@round_matcher_key, {matcher, field_index, field_size})
        st
    end
  end

  # The weight the matcher sees for a `live` weight `w` on `{i, j}`.
  #
  # Two things sit on top of the criteria weight, both strictly below it
  # and below every stage addend:
  #
  #   * the transposition tie-break, only when switched on (see
  #     `transposition_terms/3`), scales `w` to make room for its term;
  #   * always, a NEARNESS term: the whole thing is scaled by `n^2 + 1` and
  #     `n - |fi - fj|` is added, `fi`/`fj` being the two players' positions
  #     in the round's field. Among matchings of equal criteria weight the
  #     one pairing nearer positions wins; a sum of fewer than n/2 such
  #     terms cannot reach `n^2 + 1`, so it can never overturn a one-unit
  #     difference in anything above it.
  #
  # The nearness term is not there for the pairing. The refinement stages
  # settle every tie the criteria leave, and the corpus is identical with
  # it on or off. It is there for the SEARCH. The far edges -- most of the
  # graph on a large field -- carry only the completability weight, and
  # with thousands of them equal, every one of them is TIGHT at the
  # optimum: the alternating forest of each stage then grows across the
  # entire field, at a row walk per vertex, before it can augment, and
  # odd cycles of tight edges form blossoms by the thousand. With each
  # edge's weight made distinct by a canonical term, the optimum leaves
  # few edges tight, the forest grows only where it must, and a
  # 400-player round ran 14.2 s -> 9.0 s on that alone: 23,470 -> 13,405
  # tree growths and 9,142 -> 4,525 blossom formations. Nearness in
  # particular, rather than any other canonical term, because the greedy
  # start (`WeightedMatching.new/3`) matches mutually-heaviest pairs and
  # nearest neighbours are mutual, so the cold solve stays short.
  #
  # Field positions, not bracket positions, so that a far edge's weight is
  # the same in every bracket that sees it and the round matcher never has
  # to be told about it twice.
  # The distance the tie-break prefers between two bracket members: half the
  # bracket, which is where Article 3.3 puts S1[i] against S2[i] and where
  # stage 4 (fewest exchanges) and stage 8 (highest remaining partner for
  # each S1 player in turn) will push the matching anyway. Starting the
  # search there instead of at adjacent pairs means those stages find the
  # matching already in shape and augment a handful of times rather than
  # half the bracket. Zero outside the bracket, where adjacent is right:
  # the far edges only need SOME canonical order, and the greedy start
  # pairs adjacent far vertices in one pass.
  defp natural_gap(st, i, j) do
    if i < st.nsgb and j < st.nsgb, do: div(st.nsgb, 2), else: 0
  end

  defp edge_weigher(st, to_field, field_size) do
    scale = st.transposition.scale
    terms = st.transposition.terms
    reserve = st.bands.reserve
    p = field_size * field_size + 1

    criteria =
      cond do
        scale == 1 and map_size(terms) == 0 ->
          fn _i, _j, w -> w end

        System.get_env("AINALRAMI_TRANS_ABOVE") != nil ->
          # Split `w` back into its criteria part and the refinement
          # stages' reserved addend, and slot the transposition order
          # BETWEEN them: criteria still win, but FIDE's order now
          # outranks a stage nudge instead of the other way round.
          fn i, j, w ->
            term = Map.get(terms, {min(i, j), max(i, j)}, 0)
            div(w, reserve) * scale * reserve + term * reserve + rem(w, reserve)
          end

        true ->
          fn i, j, w -> w * scale + Map.get(terms, {min(i, j), max(i, j)}, 0) end
      end

    fn
      _i, _j, 0 ->
        0

      i, j, w ->
        criteria.(i, j, w) * p + field_size -
          abs(abs(to_field.(j) - to_field.(i)) - natural_gap(st, i, j))
    end
  end

  # FIDE section 3's transposition order as an edge-additive tie-break,
  # strictly below every criterion AND below the reserved space the
  # refinement stages write into, so it can only settle what they leave
  # open.
  #
  # Articles 3.3-3.5 take the SMALLEST transposition of the natural order,
  # and "smallest" is lexicographic over S2: which S2 member faces S1[0],
  # then S1[1], and so on. Maximising `B^(k-p) * (|S2| - q)` for an edge
  # from S1[p] to S2[q] minimises exactly that sequence, and it splits
  # over edges because each pair contributes one (p, q).
  #
  # An earlier version of this carried the engine's general-purpose
  # canonical tie-break instead (`lex_scale/1`), which keys on ABSOLUTE
  # bracket position rather than S2 index. That is a different order - it
  # makes the natural pairing (S1[0] vs S2[0], i.e. positions 0 and k)
  # look large and an adjacent pairing (0 vs 1) look smallest.
  #
  # ## It is inert, and promoting it is actively worse
  #
  # Every variant measures identically: removed, inverted, and replaced
  # with this handbook key, with byes and without. The eight refinement
  # stages settle every tie before it is consulted.
  #
  # `AINALRAMI_TRANS_ABOVE=1` slots it between the criteria and the stages'
  # reserved addends, so FIDE's order outranks a stage nudge rather than
  # the reverse. That is much worse - 95.97% -> 87.57% without byes and
  # 86.70% -> 79.93% with them.
  #
  # Which says the key is the wrong model, not the priority. Stages 5-7
  # EXCHANGE players between the two halves, so by the time partners are
  # chosen "S1" and "S2" are no longer the naive first-half/second-half
  # split this function assumes; it is measuring transpositions against a
  # reference the bracket has already moved away from. The stages are the
  # transposition procedure, and they are right. Kept, off the critical
  # path, because a correct key would be worth having if anyone works out
  # what the post-exchange split actually is.
  defp transposition_terms(_m, sgb, nsgb) do
    {s1, s2} =
      cond do
        # A heterogeneous bracket pairs its moved-down players against the
        # residents: MDPs are S1 (Article 3.3.1).
        sgb > 0 and sgb < nsgb -> {0..(sgb - 1)//1, sgb..(nsgb - 1)//1}
        nsgb >= 2 -> {0..(div(nsgb, 2) - 1)//1, div(nsgb, 2)..(nsgb - 1)//1}
        true -> {1..0//1, 1..0//1}
      end

    s1 = Enum.to_list(s1)
    s2 = Enum.to_list(s2)
    k = length(s1)
    n2 = length(s2)
    base = n2 + 2
    pow = for e <- 0..(k + 1), into: %{}, do: {e, Integer.pow(base, e)}

    terms =
      for {p, pi} <- Enum.with_index(s1),
          {q, qi} <- Enum.with_index(s2),
          into: %{} do
        {Enum.min_max([p, q]), Map.fetch!(pow, k - pi) * (n2 - qi)}
      end

    # One unit above anything the terms can reach, so the whole tie-break
    # sits under the criteria rather than beside them.
    if System.get_env("AINALRAMI_TRANS"),
      do: %{terms: terms, scale: Map.fetch!(pow, k + 1)},
      else: %{terms: %{}, scale: 1}
  end

  # bbpPairings reads an unmatched vertex as matched to ITSELF, and three
  # of the stage tests below (`< playerVertex`, `<= playerVertex`) depend
  # on that convention rather than on a nil check.
  defp partner(st, i), do: Map.get(st.matching, i, i)

  # Matched to a resident of this bracket's own score group.
  defp internal?(st, i) do
    p = partner(st, i)
    p >= st.sgb and p < st.nsgb
  end

  # Paired with someone LATER in the bracket - the "higher group" role in
  # an exchange.
  defp paired_down?(st, i) do
    p = partner(st, i)
    p > i and p < st.nsgb
  end

  defp exchange_needed?(st, i) do
    p = partner(st, i)
    p <= i or p >= st.nsgb
  end

  # `common.h:164`. Lock the pair by leaving each vertex exactly one
  # usable edge - the one to the other.
  #
  # The fast path, `WeightedMatching.finalize_pair/3`, is a pure edge
  # REMOVAL with no `prepare_vertex/2` and no forced re-solve (see its own
  # doc for why that stays optimal). It runs directly against whichever
  # matcher `i`/`j` are ALREADY matched in - `st.wm` for the local graph,
  # or the round matcher for the field one, `i`/`j` translated to field
  # indices exactly as `solve_field/1` itself does. Both call sites
  # (`finalize_matched/2`, `finalize_both/2`) reach here right after their
  # own `solve/1`, so that matcher always exists; the fallback below is for
  # when the fast function itself refuses - `i` or `j` inside a
  # non-trivial blossom - which is correctness-safe by construction since
  # it is the old, already-proven path, just slower.
  defp finalize_pair(st, i, j) do
    case fast_finalize_pair(st, i, j) do
      {:ok, st} -> st
      :error -> finalize_pair_by_rebuild(st, i, j)
    end
  end

  defp fast_finalize_pair(%{mode: :local, wm: nil}, _i, _j), do: :error

  defp fast_finalize_pair(%{mode: :local} = st, i, j) do
    case WeightedMatching.finalize_pair(st.wm, i, j) do
      {:ok, wm} -> {:ok, %{st | wm: wm, live: drop_other_live(st, i, j)}}
      :error -> :error
    end
  end

  defp fast_finalize_pair(%{mode: :field} = st, i, j) do
    case Process.get(@round_matcher_key) do
      {nil, _field_index, _field_size} ->
        :error

      {matcher, field_index, field_size} ->
        to_field = fn k -> Map.fetch!(field_index, elem(st.arr, k).rank) end

        case WeightedMatching.finalize_pair(matcher, to_field.(i), to_field.(j)) do
          {:ok, matcher} ->
            Process.put(@round_matcher_key, {matcher, field_index, field_size})
            {:ok, %{st | live: drop_other_live(st, i, j)}}

          :error ->
            :error
        end
    end
  end

  defp fast_finalize_pair(_st, _i, _j), do: :error

  # `live`'s half of the fast path: the matcher already has every OTHER
  # edge of `i` and `j` gone, so `live` is brought in line the same way -
  # plain writes, not `set_live/4`, since there is nothing left to apply
  # and so nothing to queue as dirty. The `(i, j)` edge itself is left
  # untouched here, unlike the slow path's max_w bump: the matcher already
  # holds it exactly as it was, and writing `st.max_w` into `live` would
  # queue exactly the `set_weight/4` prepare this path exists to avoid,
  # the next time `live` is diffed against the matcher.
  defp drop_other_live(st, i, j) do
    0..(st.wl - 1)//1
    |> Enum.reject(&(&1 == i or &1 == j))
    |> Enum.reduce(st.live, fn k, acc -> acc |> put_w(i, k, 0) |> put_w(j, k, 0) end)
  end

  defp finalize_pair_by_rebuild(st, i, j) do
    live =
      Enum.reduce(0..(st.wl - 1)//1, st.live, fn k, acc ->
        acc = if k == i, do: acc, else: set_live(acc, i, k, if(k == j, do: st.max_w, else: 0))
        if k == j, do: acc, else: set_live(acc, j, k, if(k == i, do: st.max_w, else: 0))
      end)

    %{st | live: live}
  end

  ## ---------- the ladder ----------

  defp base_edge_weights(_arr, m, _sgb, _nsgb, _scored, _ctx, _bands, _single_bye?) when m < 2,
    do: %{}

  # The weights for this bracket's graph -- and the graph is the whole
  # remaining field, but only the WINDOW of it is scored here.
  #
  # The window is the bracket and the next score group, positions
  # `0..wsgb-1`: bbpPairings' `playersByIndex`, the only vertices its
  # `computeBaseEdgeWeights` sees. Every edge with an end below the window
  # is a far edge -- scored for completability alone, at reach two or
  # more -- and bbpPairings sets those ONCE per round, before the first
  # bracket (dutch.cpp:740-816), and never touches them again. So does
  # this: the round's first bracket scores the whole field and the round
  # matcher is built from it; every later bracket scores its window and
  # nothing else, and the matcher still holds the far edges from the
  # first. The one thing that has to reach past the window is
  # `finalize_pair/3`, which zeroes a finalised player's every edge, and
  # it does so through `set_live/4` whether or not `live` ever held the
  # edge.
  #
  # Before this every bracket rescored all m^2/2 pairs and the boundary
  # diff walked them again: 1.4 s of a 9 s round at 400 players, for
  # values that could not have changed.
  defp base_edge_weights(arr, m, sgb, nsgb, scored, ctx, bands, single_bye?) do
    reach = reach_table(arr, m, nsgb)
    last = scored - 1

    Enum.reduce(0..(last - 1)//1, %{}, fn i, acc ->
      a = elem(arr, i)

      Enum.reduce((i + 1)..last//1, acc, fn j, inner ->
        r = Map.get(reach, j, 0)
        b = elem(arr, j)

        case bracket_edge_weight(a, b, j, sgb, r, ctx, bands, single_bye?) do
          nil -> inner
          w -> Map.put(inner, {i, j}, w)
        end
      end)
    end)
  end

  # How far BELOW the current bracket each position sits, counted in score
  # groups: 0 for the bracket itself, 1 for the next group, 2 for the one
  # after it, and so on.
  #
  # bbpPairings needs no such thing, because its graph stops at the next
  # group and `lowerPlayerInNextBracket` can only mean that one group. The
  # peek budget broke that equivalence: with several groups visible, a
  # plain "is the partner below?" bit scores a float that lands in the
  # very next group exactly the same as one that falls three groups. C8 is
  # about the FOLLOWING bracket specifically, so distance has to be graded.
  defp reach_table(_arr, m, nsgb) when nsgb >= m, do: %{}

  defp reach_table(arr, m, nsgb) do
    nsgb..(m - 1)//1
    |> Enum.reduce({%{}, 1, nil}, fn j, {acc, d, prev} ->
      points = elem(arr, j).points
      d = if prev != nil and points != prev, do: d + 1, else: d
      {Map.put(acc, j, d), d, points}
    end)
    |> elem(0)
  end

  defp bracket_edge_weight(a, b, j, sgb, reach, ctx, bands, single_bye?) do
    # dutch.cpp:607 - no edge unless the LARGER index is a resident or
    # lower, which is what stops two MDPs being paired with each other.
    if j >= sgb and legal_pair?(a, b) and colour_compatible?(a, b) do
      a
      |> edge_rungs(b, reach, ctx, bands, single_bye?)
      |> Enum.map(fn {_label, value, span} -> {value, span} end)
      |> ranked()
      |> Kernel.*(bands.reserve)
    end
  end

  # The ladder itself, as LABELLED rungs highest-priority first, so the
  # same definition serves both the matcher (packed by `ranked/1`) and
  # `explain_round/3`, which needs to say WHICH criterion two pairings
  # part company on. Keeping one definition is the point: a diagnostic
  # that scored a reimplementation of the criteria would only ever tell
  # you whether the two implementations agreed.
  #
  # `a` is the higher-placed player of the pair, `b` the lower.
  defp edge_rungs(a, b, reach, ctx, bands, single_bye?) do
    in_current = reach == 0
    s = bands.count_span

    place = Map.fetch!(bands.places, a.points)

    # C8 is about the FOLLOWING bracket, singular. bbpPairings' graph
    # stops at the next score group, so its `lowerPlayerInNextBracket`
    # can only ever mean that one group - including for pairs formed
    # wholly inside it, which genuinely are "pairs in the next bracket".
    #
    # The peek budget broke that equivalence in a way grading by distance
    # did not fix. With several groups visible, pairs formed THREE groups
    # down were still scoring on C8, and there are many more of those than
    # there are real downfloat placements, so they swamped the signal:
    # nearly every candidate matching carried the same large C8 total and
    # the rung stopped discriminating. Traced on seed127-r5-p13, where the
    # engine floated a player who then had to fall two groups while
    # bbpPairings floated one who landed in the next.
    #
    # So the deeper groups stay VISIBLE - the matcher still needs to know
    # those players exist, which is what the peek was for - but only the
    # immediate next group counts toward C8. Anything further is re-decided
    # in a later bracket anyway, and C8 has nothing to say about it.
    scores_c8? = reach == 1
    nearness = bit(scores_c8?)

    {c1, c2, c3, c4} = colour_criteria(a, b)
    {f1, f2, f3, f4} = float_criteria(a, b)
    {s18, s19, s20, s21} = float_score_criteria(a, b, %{score_place: bands.places})

    gate = fn value, on? -> if on?, do: value, else: 0 end

    [
      # C4 completion + C2/C5 bye eligibility. `isByeCandidate` is
      # `eligibleForBye AND score <= byeAssigneeScore` - pairing someone
      # who may NOT take the bye is preferred, so whoever is left over
      # is someone the absolute criteria allow.
      #
      # The leading `1` is what makes this rung count EDGES, and on an
      # even field (where the rest is constant) that is all it does. Since
      # it outranks C6, it makes the matcher trade an internal pair for
      # two cross-bracket ones whenever that yields more edges - and
      # `test/fixtures/open_questions/` shows bbpPairings does NOT do
      # that. `completion_rung/3` is where that is measured.
      completion_rung(a, b, ctx, s),
      # C6, then C7 graded by which score group got paired.
      {"C6 pairs in bracket", bit(in_current), s},
      {"C7 scores paired", gate.(place, in_current), bands.place_span},
      # C8, the same two rungs one bracket down - but graded by how far
      # down, since the peek budget makes several groups visible at once.
      {"C8 pairs next bracket", nearness, s},
      {"C8 scores next bracket", gate.(place, scores_c8?), bands.place_span},
      {"C9 bye unplayed games", gate.(c9_rank(a, b, ctx), single_bye?), s * s},
      # C10-C13, `insertColorBits`.
      {"C10 topscorer colour diff", gate.(bit(c1), in_current), s},
      {"C11 topscorer same colour x3", gate.(bit(c2), in_current), s},
      {"C12 colour preference", gate.(bit(c3), in_current), s},
      {"C13 strong colour preference", gate.(bit(c4), in_current), s},
      # C14-C17.
      {"C14 downfloat repeat r-1", gate.(f1, in_current), 2 * s},
      {"C15 upfloat repeat r-1", gate.(f2, in_current), s},
      {"C16 downfloat repeat r-2", gate.(f3, in_current), 2 * s},
      {"C17 upfloat repeat r-2", gate.(f4, in_current), s},
      # C18-C21.
      {"C18 downfloat scores r-1", gate.(s18, in_current), bands.place_span},
      {"C19 upfloat scores r-1", gate.(s19, in_current), bands.place_span},
      {"C20 downfloat scores r-2", gate.(s20, in_current), bands.place_span},
      {"C21 upfloat scores r-2", gate.(s21, in_current), bands.place_span}
    ]
  end

  # dutch.cpp:276 reads `1u + !isByeCandidate(higher) + !isByeCandidate(lower)`.
  #
  #   default        the C++ verbatim - the leading 1 makes it count edges
  #   "eligibility"  drop the leading 1, so the rung expresses only the
  #                  bye preference and leaves C6 to decide pair counts
  #
  # This briefly diverged from the literal text. On an even field the
  # bye-eligibility part is constant, so the leading 1 makes the rung
  # purely an edge count - and since it outranks C6 it will trade an
  # internal pair for two cross-bracket ones to gain an edge, which
  # `test/fixtures/open_questions/` catches bbpPairings NOT doing.
  # Dropping the 1 was worth +0.18 exact rounds at the time.
  #
  # The peek-budget fix then superseded it. Once brackets can see far
  # enough to evaluate C8 (see `peek_budget/0`), the two forms measure
  # IDENTICALLY - 95.97% / 98.64% without byes and 86.70% / 96.48% at an
  # 8% bye rate, byte for byte - so the divergence bought nothing and the
  # verbatim reading is back. The anomaly was never about this rung; it
  # was about what the bracket could see.
  defp completion_rung(a, b, ctx, s) do
    eligibility =
      bit(not bye_candidate?(a, ctx.bye_score)) + bit(not bye_candidate?(b, ctx.bye_score))

    case System.get_env("AINALRAMI_COMPLETION") do
      "eligibility" -> {"C2/C5 bye-eligibility", eligibility, 3 * s}
      _ -> {"C2/C4/C5 bye-eligibility", 1 + eligibility, 3 * s}
    end
  end

  # `isByeCandidate` (dutch.cpp:213) is `eligibleForBye AND score <=
  # byeAssigneeScore`, and bbpPairings only ever computes a real
  # `byeAssigneeScore` for an ODD field - for an even one it stays at its
  # zero initialiser (dutch.cpp:822). So on an even field the test is
  # `score <= 0`, false for anyone who has scored at all, and the rung
  # collapses to a constant 3 per edge: pure "maximise the number of
  # pairs", which is what the completion criterion wants.
  #
  # Treating a nil bye score as "no score test" instead made the rung VARY
  # on even fields - an edge touching someone who had already taken a bye
  # outscored one that did not - so the top rung of the whole ladder was
  # quietly expressing a preference bbpPairings does not have, above C6.
  defp bye_candidate?(player, nil), do: eligible_for_bye?(player) and player.points <= 0

  defp bye_candidate?(player, bye_score) do
    eligible_for_bye?(player) and player.points <= bye_score
  end

  defp c9_rank(a, b, ctx) do
    unplayed_rank(a, ctx) + unplayed_rank(b, ctx)
  end

  defp unplayed_rank(player, ctx) do
    if player.points == ctx.bye_score,
      do: Map.get(ctx.unplayed_ranks, played_games(player), 0),
      else: 0
  end

  ## ---------- stage 1: which MDPs get paired (dutch.cpp 1091-1205) ----------

  # Walks the moved-down players in rank order and, for each one the
  # current matching has NOT placed inside the bracket, nudges its edges
  # to residents and RE-SOLVES, keeping the result only if the MDP is now
  # paired. That is the ordering guarantee a lone matching cannot give:
  # among equally-optimal matchings, the better-ranked MDPs are the ones
  # that get paired.
  #
  # The two early exits are what the previous port was missing. Counting
  # how many of a score group CAN be matched (`matched_left`) lets the
  # loop skip the expensive re-solve entirely when the answer is already
  # forced - either none of them can be paired, or all of the ones left
  # will be.
  defp stage_select_mdps(%{sgb: 0} = st), do: st

  defp stage_select_mdps(st) do
    {st, _, _, _} =
      Enum.reduce(0..(st.sgb - 1), {st, nil, 0, 0}, fn i, {st, group, remaining, matched_left} ->
        {group, remaining, matched_left} =
          if is_nil(group) or elem(st.arr, i).points < group,
            do: count_mdp_group(st, i),
            else: {group, remaining, matched_left}

        cond do
          matched_left == 0 ->
            {st, group, remaining, matched_left}

          # Every MDP still to process in this group is matched internally, so
          # they can be committed without re-deriving it - `matched_left` can
          # never exceed `remaining`, so this arm only fires when the two are
          # equal.
          #
          # `internal?/2` is checked anyway, and that is not belt-and-braces.
          # `matched_left` is counted once when the group is entered, while
          # `nudge_mdp_edges/2` below re-solves the matching mid-loop and can
          # move a LATER member of the same group out of the bracket - after
          # which the count is stale and this arm would freeze an MDP against
          # a partner in the next score group. The invariant was previously
          # held only by `collect_bracket/1`'s `p < st.nsgb` guard, a
          # downstream filter documented as this port's own addition rather
          # than bbpPairings'. Enforced at the decision instead.
          remaining <= matched_left and internal?(st, i) ->
            {%{st | matched: MapSet.put(st.matched, i)}, group, remaining - 1, matched_left - 1}

          true ->
            st = if internal?(st, i), do: st, else: nudge_mdp_edges(st, i)

            if internal?(st, i) do
              {st |> Map.update!(:matched, &MapSet.put(&1, i)) |> freeze_mdp_edges(i), group,
               remaining - 1, matched_left - 1}
            else
              {st, group, remaining - 1, matched_left}
            end
        end
      end)

    st
  end

  # How many MDPs share this one's score, and how many of them the current
  # matching already places inside the bracket. The scan stops at the
  # first lower score, which is the first resident - moved-down players
  # are by definition higher-scored than the group they landed in.
  defp count_mdp_group(st, from) do
    score = elem(st.arr, from).points

    Enum.reduce_while(from..(st.m - 1)//1, {score, 0, 0}, fn k, {s, remaining, matched_left} ->
      if elem(st.arr, k).points >= s do
        {:cont, {s, remaining + 1, matched_left + bit(internal?(st, k))}}
      else
        {:halt, {s, remaining, matched_left}}
      end
    end)
  end

  # dutch.cpp:1168 `edgeWeight |= 1u` - the smallest bump there is, enough
  # to break a tie in favour of using this edge and far too small to
  # outrank any criterion.
  defp nudge_mdp_edges(st, mdp) do
    live =
      Enum.reduce(st.sgb..(st.nsgb - 1)//1, st.live, fn opp, acc ->
        case get_w(st.base, mdp, opp) do
          0 -> acc
          w -> set_live(acc, mdp, opp, w + 1)
        end
      end)

    solve(%{st | live: live})
  end

  # dutch.cpp:1196. Once an MDP is committed to being paired here, its
  # resident edges are lifted clear of the plain nudge so a later MDP's
  # re-solve cannot quietly drop it again.
  defp freeze_mdp_edges(st, mdp) do
    bump = st.nsgb - st.sgb + 1

    live =
      Enum.reduce(st.sgb..(st.nsgb - 1)//1, st.live, fn opp, acc ->
        case get_w(st.base, mdp, opp) do
          0 -> acc
          w -> set_live(acc, mdp, opp, w + bump)
        end
      end)

    %{st | live: live}
  end

  ## ---------- stage 2: who each MDP plays (dutch.cpp 1207-1255) ----------

  # Stage 1 settled WHETHER each moved-down player is paired; this settles
  # WITH WHOM, one player at a time, highest-ranked opponent first. The
  # ascending addend runs over the candidate opponents from the bottom up,
  # so the best-ranked available resident carries the largest bump.
  defp stage_mdp_opponents(%{sgb: 0} = st), do: st

  defp stage_mdp_opponents(st) do
    Enum.reduce(0..(st.sgb - 1), st, fn mdp, st ->
      if MapSet.member?(st.matched, mdp) do
        st |> prefer_high_opponents(mdp) |> solve() |> finalize_matched(mdp)
      else
        st
      end
    end)
  end

  # dutch.cpp:1218 seeds the addend with `playersByIndex.size()` - the
  # bracket plus the next score group, i.e. `wsgb`, NOT the size of the
  # whole graph. It used to read `st.m`, which was the same order of
  # magnitude while the graph stopped a few groups down and is not now that
  # the graph is the whole remaining field.
  defp prefer_high_opponents(st, mdp) do
    {live, _} =
      Enum.reduce((st.nsgb - 1)..st.sgb//-1, {st.live, st.wsgb}, fn opp, {acc, addend} ->
        if MapSet.member?(st.matched, opp) do
          {acc, addend}
        else
          case get_w(st.base, mdp, opp) do
            0 -> {acc, addend}
            w -> {set_live(acc, mdp, opp, w + addend), addend + 1}
          end
        end
      end)

    %{st | live: live}
  end

  defp finalize_matched(st, i) do
    case partner(st, i) do
      ^i -> st
      p -> st |> Map.update!(:matched, &MapSet.put(&1, p)) |> finalize_pair(i, p)
    end
  end

  ## ---------- stages 3-4: the remainder (dutch.cpp 1257-1318) ----------

  # What is left of the score group once the moved-down players and their
  # opponents are settled. `remainder_pairs` splits it into FIDE's S1 and
  # S2: the first `remainder_pairs` entries are the higher half, the rest
  # the lower half, and pairing them is the homogeneous-bracket problem.
  defp stage_build_remainder(st) do
    remainder = Enum.filter(st.sgb..(st.nsgb - 1)//1, &(partner(st, &1) >= st.sgb))

    %{
      st
      | remainder: remainder,
        remainder_pairs: Enum.count(remainder, &(partner(st, &1) < &1))
    }
  end

  defp stage_exchange_weights(%{remainder: []} = st), do: st

  defp stage_exchange_weights(st) do
    changes =
      for opp <- st.remainder,
          {p, idx} <- st.remainder |> Enum.take_while(&(&1 < opp)) |> Enum.with_index(),
          do: {p, opp, idx, exchange_weight(st, p, opp, idx)}

    case exchange_by_dual_shift(st, changes) do
      {:ok, st} ->
        solve(st)

      :no ->
        live =
          Enum.reduce(changes, st.live, fn {p, opp, _, w}, acc -> set_live(acc, p, opp, w) end)

        solve(%{st | live: live})
    end
  end

  # Stage 4 rewrites every remainder pair's weight, which through
  # `set_live/4` prepares every remainder vertex and makes the next solve
  # rediscover the matching from nothing -- 372 stages and 2.7 s of a
  # 1,000-player round, for a step that almost always returns the matching
  # it was given. It returns it because of how the change is shaped: pair
  # (p, opp) with p < opp moves by `2 * c(p)`, a per-vertex amount on the
  # SMALLER side, with c >= 0 for the first half of the remainder and
  # c <= 0 for the second. When the current matching already pairs first
  # half against second half -- every pair one of each, the odd one out
  # from the second half -- raising each first-half vertex's dual by its
  # own `2 * c(p)` (doubled scale) absorbs the change exactly: a first-to-
  # second pair's slack is unchanged and stays tight; a first-to-first
  # pair's slack rises by the other member's c; a second-to-second pair's
  # slack rises by minus its own c. Nothing is unmatched, so the state is
  # still optimal and `solve/1` has nothing to do. `shift_and_set/3`
  # checks the invariants it relies on and refuses otherwise -- including
  # when a remainder vertex sits inside a blossom, which it dissolves
  # first -- and a refusal, or a matching not in that shape, takes the
  # old path. Local graph only: the field graph's matcher indexes by
  # field position and its brackets are small.
  defp exchange_by_dual_shift(%{mode: :local} = st, changes) do
    s1 = st.remainder |> Enum.take(st.remainder_pairs) |> MapSet.new()
    remainder = MapSet.new(st.remainder)

    # Every first-half member paired with a second-half member; a second-
    # half member may be paired outside the remainder (the odd one floats).
    shaped? =
      Enum.all?(st.remainder, fn v ->
        p = partner(st, v)

        if MapSet.member?(s1, v),
          do: MapSet.member?(remainder, p) and not MapSet.member?(s1, p),
          else: not MapSet.member?(remainder, p) or MapSet.member?(s1, p)
      end)

    if shaped? do
      weigh = edge_weigher(st, & &1, st.m)
      s = st.bands.count_span

      shifts =
        for {p, idx} <- st.remainder |> Enum.take(st.remainder_pairs) |> Enum.with_index(),
            into: %{},
            do: {p, 2 * (weigh.(p, p + 1, 1 + 2 * (s * s - idx)) - weigh.(p, p + 1, 1))}

      edges = for {p, opp, _, w} <- changes, do: {p, opp, weigh.(p, opp, w)}

      case WeightedMatching.shift_and_set(st.wm, shifts, edges) do
        {:ok, wm} ->
          live =
            Enum.reduce(changes, st.live, fn {p, opp, _, w}, acc -> put_w(acc, p, opp, w) end)

          {:ok, %{st | wm: wm, live: live}}

        :error ->
          :no
      end
    else
      :no
    end
  end

  defp exchange_by_dual_shift(_st, _changes), do: :no

  # dutch.cpp:1055-1085. Two objectives, lexicographically: first keep the
  # pair inside its own half of the remainder (minimise the number of
  # exchanges), then prefer the smaller position (minimise the difference
  # of the exchanged branch scoring numbers).
  #
  # The `- remainder_index` runs off the end of the guard bit when that
  # bit is clear, which is where the negative addend discussed at the top
  # of this section comes from.
  defp exchange_weight(st, smaller, larger, remainder_index) do
    case get_w(st.base, smaller, larger) do
      0 ->
        0

      w ->
        s = st.bands.count_span
        w + (bit(remainder_index < st.remainder_pairs) * s * s - remainder_index) * 2
    end
  end

  ## ---------- stages 5-7: exchange selection (dutch.cpp 1320-1543) ----------

  defp stage_exchange_lower_from_higher(%{remainder: []} = st), do: st

  defp stage_exchange_lower_from_higher(st) do
    st = %{st | exchange_count: count_exchanges(st)}

    {st, _} =
      Enum.reduce_while(
        (st.remainder_pairs - 1)..0//-1,
        {st, st.exchange_count},
        fn pos, {st, left} ->
          if left == 0 do
            {:halt, {st, left}}
          else
            player = Enum.at(st.remainder, pos)
            opponents = Enum.drop(st.remainder, pos + 1)

            # Make this player's downward edges fractionally worse and ask
            # again: if the matcher now declines to pair them downward,
            # they are the one to exchange.
            st =
              if paired_down?(st, player) do
                live =
                  Enum.reduce(opponents, st.live, fn opp, acc ->
                    case exchange_weight(st, player, opp, pos) do
                      0 -> acc
                      w -> set_live(acc, player, opp, w - 1)
                    end
                  end)

                solve(%{st | live: live})
              else
                st
              end

            exchange = exchange_needed?(st, player)
            {:cont, {settle_exchange(st, player, pos, opponents, exchange), left - bit(exchange)}}
          end
        end
      )

    st
  end

  # How many of the higher half are not currently paired downward - the
  # number of exchanges the bracket has to make.
  defp count_exchanges(st) do
    case Enum.at(st.remainder, st.remainder_pairs) do
      nil ->
        0

      bound ->
        st.remainder
        |> Enum.take_while(&(&1 < bound))
        |> Enum.count(&exchange_needed?(st, &1))
    end
  end

  # Either commit the exchange by cutting the player's edges to everyone
  # after them, or put the untouched weights back.
  defp settle_exchange(st, player, pos, opponents, exchange) do
    {base, live} =
      Enum.reduce(opponents, {st.base, st.live}, fn opp, {b, l} ->
        b = if exchange, do: put_w(b, player, opp, 0), else: b
        {b, set_live(l, player, opp, exchange_weight(%{st | base: b}, player, opp, pos))}
      end)

    %{st | base: base, live: live}
  end

  defp stage_exchange_higher_from_lower(%{remainder: []} = st), do: st

  defp stage_exchange_higher_from_lower(st) do
    {st, _} =
      Enum.reduce_while(
        st.remainder_pairs..(length(st.remainder) - 1)//1,
        {st, st.exchange_count},
        fn pos, {st, left} ->
          # dutch.cpp:1414 stops at one, not zero: the last exchange has
          # no partner left to swap with.
          if left <= 1 do
            {:halt, {st, left}}
          else
            player = Enum.at(st.remainder, pos)
            opponents = Enum.drop(st.remainder, pos + 1)
            already? = paired_down?(st, player)

            st = if already?, do: st, else: probe_upward(st, player, pos, opponents)
            exchange = paired_down?(st, player)
            st = if exchange, do: cut_exchanged(st, player, pos), else: st
            st = if already?, do: st, else: restore_probe(st, player, pos, opponents)

            {:cont, {st, left - bit(exchange)}}
          end
        end
      )

    st
  end

  # The mirror of stage 5's probe: sweeten rather than sour, and ask
  # whether the matcher will now pair this lower-half player downward.
  defp probe_upward(st, player, pos, opponents) do
    live =
      Enum.reduce(opponents, st.live, fn opp, acc ->
        case exchange_weight(st, player, opp, pos) do
          0 -> acc
          w -> set_live(acc, player, opp, w + 1)
        end
      end)

    solve(%{st | live: live})
  end

  defp restore_probe(st, player, pos, opponents) do
    live =
      Enum.reduce(opponents, st.live, fn opp, acc ->
        set_live(acc, player, opp, exchange_weight(st, player, opp, pos))
      end)

    %{st | live: live}
  end

  # A player promoted out of the lower half can no longer play anyone
  # ABOVE them in the remainder, nor anyone in the next score group -
  # dutch.cpp:1473-1484 cuts both sets of edges from the base weights,
  # permanently. The second set is `nextScoreGroupBegin ..
  # playersByIndex.size()`, i.e. the next score group EXACTLY: players
  # further down are outside the window and keep their edges, so the
  # bound is `wsgb`, not the size of the graph.
  defp cut_exchanged(st, player, pos) do
    cuts = Enum.take(st.remainder, pos) ++ Enum.to_list(st.nsgb..(st.wsgb - 1)//1)

    {base, live} =
      Enum.reduce(cuts, {st.base, st.live}, fn opp, {b, l} ->
        {put_w(b, player, opp, 0), set_live(l, player, opp, 0)}
      end)

    %{st | base: base, live: live}
  end

  # dutch.cpp:1509. Drop every edge inconsistent with the exchange pattern
  # just chosen, and put the live weights back to their (now edited) base
  # so the reserved bits the probes used are clear again.
  defp stage_reset_exchange_bits(%{remainder: []} = st), do: st

  defp stage_reset_exchange_bits(st) do
    {base, live} =
      st.remainder
      |> Enum.with_index()
      |> Enum.reduce({st.base, st.live}, fn {player, pos}, acc ->
        st.remainder
        |> Enum.drop(pos + 1)
        |> Enum.reduce(acc, fn opp, {b, l} ->
          b =
            if exchange_needed?(st, player) or paired_down?(st, opp),
              do: put_w(b, player, opp, 0),
              else: b

          {b, set_live(l, player, opp, get_w(b, player, opp))}
        end)
      end)

    %{st | base: base, live: live}
  end

  ## ---------- stage 8: partners for the higher half (dutch.cpp 1545-1599) ----------

  defp stage_first_group_partners(st) do
    Enum.reduce(st.remainder, st, fn player, st ->
      if paired_down?(st, player) do
        st |> prefer_high_remainder(player) |> solve() |> finalize_both(player)
      else
        st
      end
    end)
  end

  defp prefer_high_remainder(st, player) do
    {live, _} =
      st.remainder
      |> Enum.reverse()
      |> Enum.reduce({st.live, 0}, fn opp, {acc, addend} ->
        if opp <= player or MapSet.member?(st.matched, opp) do
          {acc, addend}
        else
          acc =
            case get_w(st.base, player, opp) do
              0 -> acc
              w -> set_live(acc, player, opp, w + addend)
            end

          # Incremented even when the edge was unusable, so the ordering
          # reflects rank rather than availability (dutch.cpp:1580).
          {acc, addend + 1}
        end
      end)

    %{st | live: live}
  end

  defp finalize_both(st, i) do
    case partner(st, i) do
      ^i ->
        st

      p ->
        st
        |> Map.update!(:matched, &(&1 |> MapSet.put(i) |> MapSet.put(p)))
        |> finalize_pair(i, p)
    end
  end

  ## ---------- carry forward (dutch.cpp 1601-1649) ----------

  defp collect_bracket(st) do
    {pairs, carried, sgb} =
      Enum.reduce(0..(st.m - 1)//1, {[], [], 0}, fn i, {pairs, carried, sgb} ->
        p = partner(st, i)

        # `p < st.nsgb` is this port's own guard, not bbpPairings'. Their
        # recording condition tests only the near end of the pair, which
        # would let an MDP that was flagged matched but ended up paired
        # into the NEXT score group be written out as a finalised pair
        # while its partner also carried forward. bbpPairings never
        # finalises a cross-bracket pair (see docs/engineering-log.md); this makes that
        # invariant explicit rather than relying on it.
        if i < st.nsgb and p != i and p < st.nsgb and MapSet.member?(st.matched, i) do
          if i < p,
            do:
              {[assign_colour_with_history({elem(st.arr, i), elem(st.arr, p)}) | pairs], carried,
               sgb},
            else: {pairs, carried, sgb}
        else
          {pairs, [mark_float(elem(st.arr, i), i < st.nsgb) | carried], sgb + bit(i < st.nsgb)}
        end
      end)

    # dutch.cpp:1636-1643 needs, for each player carrying forward, the
    # score of whoever the tentative matching had them with - that is what
    # tells the NEXT bracket whether its downfloat runs deeper than one
    # group, and so whether C9 applies there at all. An unmatched carried
    # player constrains nothing, so they report their own score
    # (bbpPairings reads an unmatched vertex as matched to itself).
    #
    # The scan runs to `wsgb`, not `nsgb`: dutch.cpp:1613 loops over the
    # whole of `playersByIndex`, which is the bracket AND the next score
    # group, and every one of those that is not finalised here goes into
    # the next bracket and gets its tentative match checked. Members of the
    # next group are exactly the players who become residents next time, so
    # excluding them dropped the majority of the clearing signal.
    #
    # It stops there rather than running to `st.m`. Everything past `wsgb`
    # is graph-only lookahead that bbpPairings has no analogue for - its
    # window IS bracket-plus-next-group - and an earlier attempt that used
    # the full peek window here fixed one traced case and broke two others
    # (docs/engineering-log.md), which is what a too-wide scan looks like: players who are
    # nowhere near this decision clearing its gate.
    partner_scores =
      for i <- 0..(st.m - 1)//1,
          i < st.wsgb,
          p = partner(st, i),
          not (p != i and p < st.nsgb and MapSet.member?(st.matched, i)),
          do: elem(st.arr, if(p == i, do: i, else: p)).points

    {Enum.reverse(pairs), Enum.reverse(carried), sgb, partner_scores}
  end

  # A current-bracket player who was not paired here IS a downfloater.
  # `mark_float(player, true)` used to stamp `:already_floated`, which was
  # `float_weight/1`'s heavy re-float penalty. That function is gone with the
  # per-bracket cascade, and nothing has read the key since - it cost an
  # allocation per carried player to record something no rule consults.
  defp mark_float(player, true), do: player
  defp mark_float(player, false), do: player
  # Returns `{bye assignee score | nil, isSingleDownfloaterTheByeAssignee}`.
  # The two come from the SAME bootstrap whole-field matching in
  # bbpPairings (dutch.cpp:818-870) and are returned together for the same
  # reason: the C9 gate's first-bracket value is a property of that
  # matching, not something recoverable afterwards. On an even field
  # bbpPairings never computes either (dutch.cpp:872's `else` branch sets
  # the flag `false` and leaves the score at its zero initialiser).
  defp bye_assignee_score(_brackets, 0), do: {nil, false}

  defp bye_assignee_score(brackets, _allowed_byes) do
    field =
      brackets
      |> List.flatten()
      |> Enum.sort_by(&{-&1.points, &1.rank})
      |> Enum.map(&Map.put(&1, :colour_stats, colour_stats(&1)))

    n = length(field)

    # Found by a 100,000-tournament overnight run (PAIRING_FUZZ_BYE_PCT=15
    # - see docs/engineering-log.md): with n <= 1 there is at most one candidate, so
    # there's no pair to build an edge list over at all. The general path
    # below builds it as `0..(n - 2)`, which for n == 1 is `0..-1` -
    # Elixir's default step for a descending range walks `0, -1`, and
    # `elem(arr, -1)` raised ArgumentError instead of pairing (n == 1) or
    # doing nothing (n == 0). n == 1 is the reachable case in practice
    # (one genuine bye candidate left after everyone else resolved) -
    # trivially THEIR score, no matching needed. n == 0 shouldn't arise
    # given the `allowed_byes == 0` clause above already short-circuits
    # the no-candidates case, but costs nothing to make safe the same way
    # rather than assume it can't happen.
    if n <= 1 do
      case field do
        # One player, who takes the bye. They are also the whole top score
        # group and are matched to themselves, so dutch.cpp:851-870's scan
        # finds nothing below the top score and the flag stays `true`.
        [player] -> {player.points, true}
        [] -> {nil, false}
      end
    else
      bye_assignee_score_from_field(field, n)
    end
  end

  defp bye_assignee_score_from_field(field, n) do
    arr = List.to_tuple(field)
    {places, place_span} = score_places(field)
    max_place = places |> Map.values() |> Enum.max(fn -> 1 end)

    # Room for the eligibility term above the score term, and for a
    # cardinality term above both, so more pairs always wins.
    eligibility_unit = place_span
    edge_ceiling = 3 * eligibility_unit + 2 * max_place
    cardinality_unit = div(n, 2) * edge_ceiling + 1

    # dutch.cpp:782-786's THIRD packed field, which this port was missing
    # entirely: after the eligibility and score-group fields are shifted
    # up, the bottom `scoreGroupSizeBits` hold
    #
    #     player->scoreWithAcceleration(tournament)
    #       >= sortedPlayers.front()->scoreWithAcceleration(tournament)
    #
    # `player` is the OUTER loop variable and `opponent` the inner one,
    # and the inner loop breaks at `opponentIndex == playerIndex`, so
    # `player` is always the WORSE-sorted of the two. On a field sorted
    # best-first that makes the test "the lower player is still in the top
    # score group", i.e. the edge lies WHOLLY inside the top score group.
    # Summed over a matching it is a count: *maximise the number of pairs
    # formed inside the top score group*.
    #
    # Why it is not redundant with the two fields above it. On an odd
    # field the matcher returns a near-perfect matching, so every player
    # but one is covered and both higher fields collapse to statements
    # about that one leftover - eligibility to "leave out someone who may
    # actually take the bye", score to "leave out the lowest-placed
    # player". They cannot distinguish two matchings with the SAME
    # leftover, nor two leftovers that tie on both. This field can, and it
    # is the only one that says anything about the matching's SHAPE.
    #
    # Shape is exactly what `first_single_bye?/4` reads back out. That
    # scan clears the C9 gate when any top-group player is tentatively
    # matched BELOW the top group - which is precisely the arrangement
    # this field penalises - so leaving it out let the gate be decided by
    # whichever member of a tie the matcher happened to return.
    #
    # Scaled rather than packed. Multiplying everything above it by
    # `div(n, 2) + 1` - one more than the number of edges a matching can
    # hold, hence one more than the largest attainable bit total - makes
    # this strictly a TIEBREAK: it can never overturn a difference in the
    # fields above, only decide one they leave open. bbpPairings gets the
    # same guarantee from bit widths, sizing the field at
    # `scoreGroupSizeBits` so its sum cannot carry.
    top_score = elem(arr, 0).points
    tie_unit = div(n, 2) + 1

    edges =
      Enum.flat_map(0..(n - 2), fn i ->
        a = elem(arr, i)

        Enum.flat_map((i + 1)..(n - 1), fn j ->
          b = elem(arr, j)

          if legal_pair?(a, b) and colour_compatible?(a, b) do
            # NOT `bye_candidate?/2` (the eligible-AND-score<=threshold
            # test): checked directly against dutch.cpp:766-786, the
            # bootstrap matching that DETERMINES byeAssigneeScore for an odd
            # field uses its own separate, simpler inline weight -
            # `1u + !eligibleForBye(player) + !eligibleForBye(opponent)` -
            # not the real per-bracket `computeEdgeWeight`/`isByeCandidate`
            # test. That's not an oversight on the C++ side: `isByeCandidate`
            # needs `byeAssigneeScore` as an input, which is exactly what
            # this pass is computing, so testing candidates against it here
            # would be circular. Confirmed by measurement too - swapping
            # this to `bye_candidate?(_, nil)` (tried during the
            # `tools/adjudicate.exs` investigation below) made ~80/2522
            # rounds newly unpairable where bbpPairings still found a legal
            # pairing, a large regression, not the intended fix.
            eligibility = 1 + bit(not eligible_for_bye?(a)) + bit(not eligible_for_bye?(b))

            # A deliberate NON-literal reading, argued rather than copied.
            # bbpPairings sums the raw SHIFT amounts here -
            # `scoreGroupShifts[a] + scoreGroupShifts[b]`, roughly linear
            # in the score-group index - where everywhere else it uses
            # them as shifts (`1u << scoreGroupShifts[...]`). `places` is
            # the mixed-radix encoding used by the rest of this port, and
            # it is geometric, so the two are different functions.
            #
            # They agree on everything this pass can observe. The field is
            # odd, the graph is complete, so the matcher covers all but one
            # player and this band's total is `constant - value(leftover)`
            # under EITHER encoding. Both are strictly increasing in the
            # score-group index, so both say the same thing: minimise the
            # leftover's score. The same collapse applies to the
            # eligibility band above (`(n-1)/2 + ineligible_total -
            # [leftover ineligible]`), which is why neither band can see
            # the matching's shape and the field below had to.
            #
            # The reduction needs every edge compatible. Where it isn't,
            # more than one player goes uncovered and the two encodings
            # could in principle part company - but that is the case where
            # real bbpPairings throws `NoValidPairingException` instead,
            # and the `[] -> {nil, false}` branch below already declines to
            # constrain C5 there.
            score = Map.fetch!(places, a.points) + Map.fetch!(places, b.points)

            # `b` is the worse-sorted of the two, so testing it alone is
            # the whole of the C++ condition - see `tie_unit` above.
            top_pair = bit(b.points >= top_score)
            weight = cardinality_unit + eligibility * eligibility_unit + score

            [{i, j, tie_unit * weight + top_pair}]
          else
            # dutch.cpp:768-791: `compatible/4`-failing pairs still get a
            # real edge here (`edgeWeight` starts at, and for these stays,
            # exactly 0) - the bootstrap matching_computer is built as a
            # COMPLETE graph, so an incompatible pair is only ever a worse
            # choice than a compatible one, never an impossible one.
            # `WeightedMatching.solve/2`'s `build_state/2` silently drops
            # any edge with weight `0` (`if w > 0`), so a literal port of
            # "weight 0" would vanish here exactly like the omitted-edge
            # version this replaces - hence weight `1`, the smallest weight
            # that still registers, still guaranteed below every compatible
            # edge's `cardinality_unit`-or-higher floor. Previously this
            # pair contributed NO edge at all, so a field whose only
            # legal/colour-compatible pairs can't form a near-perfect
            # matching (heavy forfeits/absolute-colour clashes) could leave
            # MORE than one player unmatched here - a case real bbpPairings
            # doesn't hit at this bootstrap step, since it always has a
            # complete graph to fall back on.
            #
            # Scaled by `tie_unit` along with every compatible edge, so an
            # incompatible pair stays exactly as far below them as before.
            [{i, j, tie_unit}]
          end
        end)
      end)

    # Every compatible edge's weight is a sum of per-vertex terms plus the
    # one-bit `top_pair`, so a dual of half the symmetric part per vertex
    # (on the matcher's doubled scale: the whole of it), plus one for a
    # top-group vertex, makes every compatible edge tight except a
    # top-to-lower one (slack 1) and leaves the incompatible ones far from
    # it. The matcher's greedy start then pairs the field in index order
    # along those edges and the search has one or two exposed vertices to
    # settle, instead of matching one heaviest edge per stage for a
    # hundred stages. Checked against the weights by `new/3`.
    duals =
      Map.new(0..(n - 1)//1, fn i ->
        p = elem(arr, i)

        {i,
         tie_unit *
           (cardinality_unit + eligibility_unit * (1 + 2 * bit(not eligible_for_bye?(p))) +
              2 * Map.fetch!(places, p.points)) + bit(p.points >= top_score)}
      end)

    {_state, matching} =
      n |> WeightedMatching.new(edges, duals: duals) |> WeightedMatching.solve()

    case Enum.reject(0..(n - 1), &is_map_key(matching, &1)) do
      # No legal complete round exists; leave C5 unconstrained and let the
      # cascade and `repair_bye_count/3` produce the best answer they can
      # rather than refusing every candidate here.
      [] ->
        {nil, false}

      leftovers ->
        score = leftovers |> Enum.map(&elem(arr, &1).points) |> Enum.min()
        {score, first_single_bye?(arr, n, matching, score)}
    end
  end

  # dutch.cpp:851-870, verbatim. C9 ("minimise the unplayed games of the
  # bye assignee") only means anything in a bracket that downfloats exactly
  # ONE player and that player takes the bye. For the very first bracket
  # bbpPairings decides that from the bootstrap matching above: the bye has
  # to fall in the TOP score group at all (`byeAssigneeScore >= topScore`),
  # and no top-group player may already be tentatively matched below it -
  # if one is, the top group is floating someone down as well as producing
  # the bye, so there is no single assignee to talk about.
  #
  # In practice this is usually FALSE, because the bye assignee is normally
  # the lowest-scoring eligible player and `byeAssigneeScore >= topScore`
  # then only holds for a field that is effectively one score group. That
  # is the point: `bracket_loop/5` used to approximate this as "odd field,
  # and an even number of players below the top bracket", which fires far
  # more often and so scored C9 in brackets bbpPairings excludes.
  #
  # The scan stops at the first player below the top score - the C++ loop
  # `break`s there - which the sorted field turns into a plain implication.
  # An unmatched vertex is its own partner in bbpPairings' convention, so
  # the bye assignee themselves never clears the flag.
  #
  # This reads the matching's SHAPE, so it is only as well-defined as the
  # matching is. Where several matchings tie on weight the flag can differ
  # between them, and a maximum-weight matcher may return any of them -
  # which is exactly why the bootstrap's lowest-order weight field (see
  # `tie_unit` above) is not optional. That field prefers matchings that
  # pair the top score group internally, i.e. the ones this scan does NOT
  # clear, so the tie is resolved before it ever gets here.
  defp first_single_bye?(arr, n, matching, bye_score) do
    top = elem(arr, 0).points

    bye_score >= top and
      Enum.all?(0..(n - 1)//1, fn i ->
        elem(arr, i).points < top or
          elem(arr, Map.get(matching, i, i)).points >= top
      end)
  end

  # C5, the PAB Criterion: "Minimise the score of the assignee of the
  # pairing-allocated-bye". ABSOLUTE, so it is checked here alongside C2
  # rather than weighted anywhere.
  defp bye_score_ok?(player) do
    case Process.get(@bye_score_key) do
      nil -> true
      score -> player.points <= score
    end
  end

  defp score_places(players) do
    players
    |> Enum.group_by(& &1.points)
    |> Enum.map(fn {score, members} -> {score, length(members)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({%{}, 1}, fn {score, size}, {places, place} ->
      {Map.put(places, score, place), place * (size + 1)}
    end)
  end

  defp float_score_criteria(higher, lower, spans) do
    crossing? = higher.points > lower.points

    # Only a pair that spans two score groups HAS a score difference, and
    # the difference belongs to the MDP - the higher-scored player, who
    # moved down into this bracket. `score_place` already encodes exactly
    # that: one digit per score group, the higher group more significant,
    # so a bigger drop is a bigger number and "taken in descending order"
    # falls out of the positional comparison.
    #
    # Weighting by the LOWER player instead was tried first and is inert:
    # `lower` is decided by bracket position, so in an MDP bracket it is
    # always a resident, every resident shares one score, and the term is
    # then the same constant for every candidate pairing.
    if crossing? do
      psd = Map.fetch!(spans.score_place, higher.points)

      {
        # C18/C20 - the MDP itself downfloated recently. Pairing it here is
        # what stops it floating on, so the reward grows with the drop.
        if(float_of(higher, 1) == :down, do: psd, else: 0),
        # C19/C21 - inverted like `float_criteria/2`'s f2/f4: the reward is
        # for an opponent who did NOT just upfloat.
        if(float_of(lower, 1) == :up, do: 0, else: psd),
        if(float_of(higher, 2) == :down, do: psd, else: 0),
        if(float_of(lower, 2) == :up, do: 0, else: psd)
      }
    else
      {0, 0, 0, 0}
    end
  end

  # Pack ranked criteria, highest priority first, the same way bbpPairings'
  # `computeEdgeWeight` does with successive left-shifts: each criterion is
  # worth more than every lower-priority criterion combined, so a better
  # value on an earlier term can never be outvoted by later ones. Passing
  # explicit spans rather than hard-coded decimal magnitudes is what makes
  # that guarantee hold - the previous `* 1_000_000` / `* 1_000` scheme was
  # only safe as long as nobody looked at a bracket big enough to overflow
  # the gap between two of its terms.
  defp ranked(components) do
    Enum.reduce(components, 0, fn {value, span}, acc -> acc * span + value end)
  end

  defp bit(true), do: 1
  defp bit(false), do: 0
  # Only these three mean a game was actually contested. A forfeit carries
  # an opponent AND a colour but is legally unplayed, which is why every
  # caller has to ask whether the game HAPPENED rather than whether there
  # was an opponent - four separate call sites had that wrong until the
  # harness started generating forfeits.
  @played_results ~w(1 = 0)

  defp played?(game), do: game.result in @played_results

  # A player's full colour state, ported from bbpPairings'
  # `tournament.cpp` `computePlayerData`. This replaces a one-line
  # stand-in ("preference is the opposite of your last colour") that was
  # only ever right for round 2, which is exactly why round 2 measured
  # 99.85% and round 3 fell off a cliff: after two games a player can be
  # two colours out of balance, or have had the same colour twice running,
  # and both produce an ABSOLUTE preference that the old rule couldn't
  # represent at all.
  #
  # Unplayed games (byes, forfeits) are excluded entirely - they carry no
  # colour and must not break a run of repeated colours either.
  defp colour_stats(player) do
    played = Enum.filter(player.games, &played?/1)
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
    # gamesAsBlack ? BLACK : WHITE` - not a coin flip.
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
  # engine had only the third of these - a single "are the preferences
  # compatible" boolean - which cannot distinguish a clash between two
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

  # The four float-history criteria of bbpPairings' `computeEdgeWeight`,
  # ranked immediately below every colour criterion and above the
  # bracket-ordering ones. These are what docs/engineering-log.md item 4 predicted would
  # first bite in round 3: `float_direction/4` looks one and two rounds
  # back, and two rounds back doesn't exist until round 3.
  #
  # All four are phrased so that HIGHER is better, since the matcher
  # maximises. The two "repeated downfloater" terms reward *pairing* a
  # player who was floated down recently - pairing them here is precisely
  # how you avoid floating them again. The two "repeated upfloater" terms
  # instead withhold their bit from an edge that would upfloat someone who
  # already upfloated, an edge being an upfloat exactly when it crosses
  # score groups.
  defp float_criteria(higher, lower) do
    crossing? = higher.points > lower.points

    {
      bit(float_of(lower, 1) == :down) + bit(not crossing? and float_of(higher, 1) == :down),
      bit(not (crossing? and float_of(lower, 1) == :up)),
      bit(float_of(lower, 2) == :down) + bit(not crossing? and float_of(higher, 2) == :down),
      bit(not (crossing? and float_of(lower, 2) == :up))
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

  # C1, no repeat pairings - but only actually-PLAYED games forbid a
  # rematch. bbpPairings builds its `forbiddenPairs` set under an explicit
  # `if (match.gameWasPlayed)` guard (`dutch.cpp:664`), so two players who
  # were paired and forfeited have not "met" and may be paired again.
  #
  # Confirmed against real javafo before changing it: seed 140, an
  # 11-player round 2 where players 5 and 10 were paired in round 1 and
  # double-forfeited. javafo paired them with each other AGAIN, in
  # preference to two rematch-free alternatives it could have taken
  # instead - so this is javafo's actual behaviour, not an artefact of
  # having no other option.
  #
  # An arbiter's `XXP` exclusion lives here, and nowhere else, because
  # that is where bbpPairings puts it: `compatible` (`dutch.cpp:39-68`)
  # opens with `!forbiddenPairs[player0.id].count(player1.id)` and only
  # then considers colour, and the rematch rule reaches that same test by
  # being INSERTED INTO the very same set (`dutch.cpp:653-666`). The two
  # rules are literally one lookup in the reference. So a forbidden pair is
  # an absolute criterion of exactly the standing of "you have already
  # played this opponent" - never a term weighed against the others.
  defp legal_pair?(p1, p2) do
    not forbidden_pair?(p1.rank, p2.rank) and
      not Enum.any?(p1.games, &(played?(&1) and &1.opponent_rank == p2.rank))
  end

  defp forbidden_pair?(rank1, rank2) do
    case Process.get(@forbidden_key) do
      nil -> false
      map -> map |> Map.get(rank1) |> forbids?(rank2)
    end
  end

  defp forbids?(nil, _rank), do: false
  defp forbids?(set, rank), do: MapSet.member?(set, rank)

  # Two players who both hold an ABSOLUTE colour preference for the same
  # colour cannot be paired at all. bbpPairings puts this in `compatible`
  # (`dutch.cpp:57-68`) alongside the no-rematch rule - an absolute
  # criterion, not something weighed against other considerations. This
  # engine had it only as scored criteria c1/c2, which means a bad enough
  # position elsewhere could buy a pairing that is simply not allowed.
  #
  # bbpPairings carries one exception: in the FINAL round, two players
  # above half the maximum possible score may be paired despite the
  # clash, rather than leave a tournament's decisive game unplayed. It
  # needs the expected round count, which reaches here via
  # `pair_next_round/2`'s `:expected_rounds` option; without it the
  # exception simply never fires and the engine stays strict.
  #
  # Leaving it out was measurable: rounds 4-8 all improved when the hard
  # exclusion landed, and round 9 - the final round of the nine-round
  # sweep, and the only round where this exception can apply - was the
  # one round that got worse.
  defp colour_compatible?(a, b) do
    p = a.colour_stats
    o = b.colour_stats

    if p.absolute? and o.absolute? and not is_nil(p.preference) and
         p.preference == o.preference do
      final_round_topscorers?(a, b)
    else
      true
    end
  end

  defp final_round_topscorers?(a, b) do
    case Process.get(@expected_rounds_key) do
      nil ->
        false

      expected_rounds ->
        # `playedRounds >= expectedRounds - 1`: the round being paired is
        # the last one. The threshold is bbpPairings' own
        # `(tournament.playedRounds * pointsForWin) >> 1` - half of what a
        # player could have scored SO FAR (rounds already played), not
        # half the tournament's eventual maximum. Those are genuinely
        # different numbers even in the one round this exception can ever
        # fire in: playedRounds is expectedRounds-1 there, so the correct
        # threshold is floor((expectedRounds-1)/2), one lower than
        # floor(expectedRounds/2) whenever expectedRounds is even. This
        # engine used expectedRounds directly, which was simply the wrong
        # variable - found by tracing a genuine round-30 disagreement
        # (seed 39, 32-player field): Ainalrami left two players unpaired
        # despite a full pairing existing, confirmed reachable by
        # disabling colour compatibility entirely first, and this
        # one-line fix alone was enough to reach it (see docs/engineering-log.md).
        # Not `length(a.games)`: that is this player's own game count, and a
        # player holding a pre-recorded bye for the round being paired has one
        # more of those than the tournament has played rounds.
        played_rounds = Process.get(@played_key, length(a.games))

        # `>> 1` in bbpPairings is a shift on DOUBLED point units, so it is an
        # exact half, not a floor. `div/2` here rounded it down: at
        # playedRounds 7 the real threshold is 3.5 and this used 3, admitting
        # a player on exactly 3.5 as a topscorer where the reference requires
        # strictly more than half. Kept as a float and compared with `>`, so
        # 3.5 > 3.5 is false - which is what `(points * 2) > playedRounds`
        # gives in the reference's own units.
        # `pointsForWin` is the missing factor whenever a win is not worth
        # 1.0: the reference's expression is
        # `(playedRounds * pointsForWin) >> 1`, i.e. half of what a player
        # COULD have scored so far, and scores are in the file's own units.
        # Dividing rounds by two alone silently assumed the standard system.
        points_for_win = point_system().win
        threshold = played_rounds * points_for_win / 2

        played_rounds >= expected_rounds - 1 and
          (a.points > threshold or b.points > threshold)
    end
  end

  # Absolute criterion C2: nobody receives a second pairing-allocated bye.
  # bbpPairings' `eligibleForBye` (common.h:104-118) disqualifies a player who
  # has an UNPLAYED game that is either worth at least a win, or was a
  # pairing-allocated bye:
  #
  #     U   pairing-allocated bye        both limbs
  #     F   full-point bye (arbiter)     worth a win
  #     +   forfeit win                  worth a win
  #
  # and leaves eligible the ones worth less: `H` (half-point bye), `Z`
  # (zero-point bye), `-` (forfeit loss).
  #
  # **`W` was here and should not have been**, on the reading that it is an
  # "unplayed win". It is not. bbpPairings gates the whole rule on
  # `!match.gameWasPlayed` (common.h:111) and sets that false for exactly
  # `+ - H F U Z` and space (trf.cpp:278-286) - `W`, `D` and `L` are absent
  # from that list, so they are PLAYED games, scored through the same
  # WIN/DRAW/LOSS branch as `1`, `=` and `0` (trf.cpp:252-270). They are
  # letter spellings of an ordinary result, and an ordinary win has never
  # disqualified anybody from a bye.
  #
  # Unreachable through this repo's own parser either way, since `Trf.parse/1`
  # normalises `W` to `1` before the engine sees it - but reachable from a
  # caller that hands in player maps directly, which is exactly how the
  # sibling Phoenix app uses this engine. There it would have barred a player
  # from a bye for the crime of having won a game.
  #
  # Enforced as a hard requirement on the cascade's final state rather
  # than scored, so the search has to find a legal bye assignee or report
  # that none exists.
  # Under the standard system this is exactly `~w(U F +)`, which is what
  # this was: `+` and `F` are unplayed and worth a win, and `U` is the
  # pairing's own bye. Written as the reference writes it - a comparison
  # against `pointsForWin` rather than a fixed list - because the list stops
  # being right the moment a file sets its own point values. With
  # `BBF 1.0`, a forfeit LOSS is worth a win and disqualifies its holder;
  # with `BBW 2.0`, a half-point bye still does not.

  defp eligible_for_bye?(player) do
    not Enum.any?(player.games, &bye_disqualifying?/1)
  end

  defp bye_disqualifying?(%{result: result}) do
    not Ainalrami.Trf.game_was_played?(result) and
      (result == "U" or result_points(result) >= point_system().win)
  end

  defp assign_colour_with_history({a, b}) do
    case choose_colour(a, b) do
      "w" ->
        {a.rank, b.rank}

      "b" ->
        {b.rank, a.rank}

      nil ->
        # Neither player has a colour preference, so 5.2.1-5.2.4 cannot apply
        # and 5.2.5 decides on the higher ranked player's TPN parity.
        #
        # "Higher ranked" is Article 1.2 -- SCORE first, then TPN ascending.
        # This compared TPN alone, the same defect 5.2.4 carried one article
        # up: any pair straddling a score group got the parity rule applied to
        # the wrong player. Reachable wherever a player has no PLAYED games at
        # all, which arbiter byes produce routinely -- and which is exactly
        # where the residual colour disagreements clustered.
        {top, bottom} = order_by_placement(a, b)
        assign_colour_round_one(top, bottom)
    end
  end

  # The colour `player` gets against `opponent` - a port of bbpPairings'
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
          {players_colour, opponents_colour}
          when not is_nil(players_colour) and not is_nil(opponents_colour) ->
            opponents_colour

          # 5.2.3 could not separate them: the two have identical colour
          # histories, so there is no "most recent time in which one player
          # had White and the other Black".
          #
          # 5.2.4 decides next -- "grant the colour preference of the higher
          # ranked player" -- and this used to skip it, falling straight to
          # 5.2.5's odd-TPN rule. Both players hold the same preference here
          # (the branch above rules out any other case), so the higher ranked
          # of the two takes it and the other gets the opposite.
          #
          # Only reachable when two players' colour histories match exactly,
          # which ordinary Swiss play makes uncommon -- different opponents
          # give different colours -- and which no random corpus produced in
          # 195 million pairings. It was found by building a position that
          # forces it: see `tools/forced_exchange.exs`.
          _ ->
            #  is non-nil here: the first clause of this cond
            # already handled a missing or differing preference, so both hold
            # the same one and only who is higher ranked is left to decide.
            # "Higher ranked" is Article 1.2 -- SCORE first, then TPN
            # ascending -- not TPN alone. A bracket routinely holds players on
            # different scores (every moved-down player is one), and comparing
            # TPN there hands the preference to the wrong player. Caught by the
            # first colour-aware fuzz run: both disagreeing boards had
            # identical colour histories, so 5.2.4 was deciding, and in each
            # the engine preferred the lower TPN where bbpPairings preferred
            # the higher score.
            if {-player.points, player.rank} < {-opponent.points, opponent.rank},
              do: p.preference,
              else: invert(o.preference)
        end
    end
  end

  # The colours the two players had in the most recent round where they
  # differed, walking both histories back in step and skipping unplayed
  # games on either side independently.
  defp first_colour_difference(a, b) do
    walk_back(played_colours(a), played_colours(b))
  end

  # bbpPairings' `skipUnplayedGames`: a forfeit is skipped here too, so
  # the two histories stay aligned on rounds that were actually contested.
  defp played_colours(player) do
    player.games |> Enum.filter(&played?/1) |> Enum.map(& &1.colour) |> Enum.reverse()
  end

  defp walk_back([x | xs], [y | ys]) when x == y, do: walk_back(xs, ys)
  defp walk_back([x | _], [y | _]), do: {x, y}
  defp walk_back([], [y | _]), do: {nil, y}
  defp walk_back([x | _], []), do: {x, nil}
  defp walk_back([], []), do: {nil, nil}
end
