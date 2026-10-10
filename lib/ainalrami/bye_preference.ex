defmodule Ainalrami.ByePreference do
  @moduledoc """
  Per-player preferences for the pairing-allocated bye - an ORGANISER's
  wish, not a FIDE rule (see README, "Organiser deviations").

  Four settings, each for every round or for chosen rounds:

    * `:want_hard` - if the round has a pairing-allocated bye, this player
      gets it, as long as the rest of the field can still be paired under
      the absolute criteria ([C1]-[C3], forbidden pairs, and the bye rules
      below). When no legal round gives them the bye, the round is paired
      as it would have been without the wish, and the report says why.
    * `:want_soft` - among the players who could take the bye, prefer this
      one, unless that costs something the FIDE criteria rank higher.
    * `:avoid_hard` - never give this player the bye. This IS the engine's
      existing bye exclusion (`pair_next_round/2`'s `:bye_exclusions`), and
      is passed on as one: a round the exclusion makes impossible is refused
      exactly as before, with `reason: :bye_exclusions` and an override.
    * `:avoid_soft` - prefer anyone else for the bye, unless that costs
      something the FIDE criteria rank higher.

  ## Where the soft settings sit in the criteria

  Both soft settings sit exactly where a `:strong` soft pair does
  (`soft_pairs:`): directly below the ladder's top rung - the absolute
  criteria, the completion of the round and the bye's own rules ([C2]:
  no second pairing-allocated bye; [C4]/[C5]: the bye goes to the lowest
  score that still lets the rest be paired) - and above every quality
  criterion, [C6] to [C21], [C9] (the bye holder's unplayed games)
  included, and the final ordering rule.

  So a soft preference never moves the bye to a higher score group, never
  gives it to a player [C2] rules out, and never leaves the round
  unpairable. Among the players on the bye score who could take it, it
  decides; the brackets are then paired as well as the criteria allow
  around that choice. There is no `:weak` position for the bye: below
  [C21] the only thing left to decide is the transposition order, which
  practically never has two bye holders to choose between.

  Mechanically every setting is a set of bye exclusions, so the rule that
  decides who MAY take the bye is still the one `eligible_for_bye?/1`
  applies everywhere, including the certified and direct-bracket
  shortcuts, which are proved against that predicate:

    * a hard want pairs the round with every other active player excluded;
    * a soft want does the same, and keeps the result only if its bye
      holder has the bye score of the round paired without the wish;
    * a soft avoid excludes the bye holder while the holder is someone to
      avoid, and keeps the last round whose holder still has that score.

  ## Precedence and conflicts

  Organiser exclusions (`:bye_exclusions`) count as `:avoid_hard`. For one
  player: a hard avoid beats any want; a hard want beats a soft avoid; a
  soft want and a soft avoid cancel out; of two settings on the same side
  the stronger one counts. Across players: hard wants are applied first -
  with several, the FIDE criteria choose among them - and the soft
  settings only when no hard want decided the bye; soft wants before soft
  avoids.

  Nothing is applied on an even field (there is no bye) or for a player not
  in the round, and a "rather gets it" for a player [C2] already rules out
  is not applied either - each is reported, and the round paired. A "must
  get it" for a player [C2] rules out, on a round that has a bye, is
  different: the round is REFUSED with `Ainalrami.ByePreference.RefusedError`,
  naming the player and the round of their earlier bye (or forfeit win, or
  full-point bye) - silently pairing without it would hide that the
  organiser asked for a second pairing-allocated bye, which C2 forbids.

  ## What a caller gets

  `pair/2` returns `{pairs, report}`. `pair_next_round/2` with a
  `:bye_preferences` option returns the same pairs. The report:

    * `:round` - the round being paired.
    * `:bye` - the bye holder, or nil.
    * `:fide_bye` - who would have had the bye with no preference (the
      organiser's exclusions still applied), or nil.
    * `:moved` - whether the preferences changed the round at all. Only a
      round they moved departs from the pairing C.04.3 produces.
    * `:decided_by` - the setting that moved the bye (`:want_hard`,
      `:want_soft` or `:avoid_soft`), nil when nothing moved it.
    * `:exclusions` - the bye exclusions the round was finally paired
      under, and `:opts` - the options, with `:bye_preferences` resolved
      into those exclusions. Hand `:opts` to `explain_round/3` and the
      `Ainalrami.Alternatives` functions: they then judge the round under
      the rules it was actually paired by. The players a preference (rather
      than the organiser) kept from the bye are also listed there as
      `:bye_preference_exclusions`, so "why not me" says `:bye_preference`
      for them, not `:organiser_exclusion`.
    * `:outcomes` - one entry per preference that names a player, in rank
      order: `%{rank:, preference:, outcome:}` plus, for some outcomes, a
      detail. `outcome` is one of

        * `:honoured` - a want got the bye, an avoid did not;
        * `:no_bye_this_round` - even field, no bye to give;
        * `:not_in_round` - the player is not paired this round (absent,
          a requested bye, withdrawn);
        * `:ineligible` (`reason:` `:pairing_bye`, `:forfeit_win` or
          `:full_point_bye`) - a "rather gets it" for a player [C2] rules
          out of the bye;
        * `:conflict` (`with:` the setting that won) - the same player
          carries an opposite setting;
        * `:unpairable` - a hard want: no legal round gives them the bye;
        * `:other_player` (`holder:`) - another player's equal or
          stronger wish got the bye;
        * `:outranked` - a soft setting a higher criterion overruled: the
          wanted player could only get the bye on a higher score, or in no
          legal round; the avoided player was the only one on the bye
          score who could take it.

  ## Not FIDE

  A round these settings MOVED is not a Dutch-system round in the
  homologation sense, and a FIDE checker replaying the file will not
  reproduce it. No FIDE record carries them; this engine's own `XXO` lines
  do (`Ainalrami.Trf`, "The organiser's records"), which no other program
  reads.
  """

  alias Ainalrami.Pairing
  alias Ainalrami.Pairing.NoValidPairingError

  @preferences [:want_hard, :want_soft, :avoid_hard, :avoid_soft]

  @doc "The four settings, strongest want first."
  def preferences, do: @preferences

  @doc """
  Whether `opts` carries any bye preference at all - the switch
  `Ainalrami.Pairing.pair_next_round/2` dispatches on.
  """
  def active?(opts), do: Keyword.get(opts, :bye_preferences) not in [nil, []]

  @doc """
  Pairs the next round under `opts[:bye_preferences]` and returns
  `{pairs, report}` - see the moduledoc.

  `opts[:bye_preferences]` is a list of `{rank, preference}` (every round)
  or `{rank, preference, rounds}` with `rounds` a list of round numbers or
  `:all`. Every other option is `Ainalrami.Pairing.pair_next_round/2`'s,
  passed through unchanged.

  Raises `Ainalrami.Pairing.NoValidPairingError` exactly when the round
  cannot be paired under the absolute criteria and the organiser's hard
  exclusions - never because of a want or a soft setting, which fall back.
  Raises `Ainalrami.ByePreference.RefusedError` for a "must get it" [C2]
  rules out, on a round with a bye (see the moduledoc).

  `pair` is the function every round is paired by, with the preferences
  already resolved into `:bye_exclusions` - `Ainalrami.Pairing.pair_next_round/2`
  by default, and `Ainalrami.Pairing.pair_later_round/2` when that is the
  entry point the preferences reached the engine through, so the rounds
  tried here take the same path as the one they are compared against.
  """
  def pair(players, opts, pair \\ &Pairing.pair_next_round/2) do
    # The roster and the other options, as every pairing entry point checks
    # them, before the scores and the round are read off the roster.
    Pairing.check_input!(players, opts)
    prefs = parse!(Keyword.get(opts, :bye_preferences, []))
    base_opts = Keyword.delete(opts, :bye_preferences)
    round = Ainalrami.Trf.rounds_played(players) + 1
    scores = Pairing.round_scores(players)

    {hard_avoid, entries} = settings(prefs, round, base_opts, scores)
    base_opts = Keyword.put(base_opts, :bye_exclusions, hard_avoid)

    if rem(map_size(scores), 2) == 1,
      do: refuse_second_bye!(players, base_opts, entries, round)

    fide = pair.(players, base_opts)
    h0 = holder(fide)

    report = %{
      round: round,
      bye: h0,
      fide_bye: h0,
      moved: false,
      decided_by: nil,
      exclusions: hard_avoid,
      opts: base_opts,
      outcomes: []
    }

    {pairs, report} =
      cond do
        entries == [] ->
          {fide, report}

        rem(map_size(scores), 2) == 0 ->
          {fide, %{report | outcomes: Enum.map(entries, &outcome(&1, :no_bye_this_round))}}

        true ->
          resolve(
            players,
            base_opts,
            fide,
            entries,
            scores,
            eligibility(players, base_opts),
            pair
          )
          |> then(fn {pairs, extra, decided_by, outcomes} ->
            exclusions = Enum.sort(Enum.uniq(hard_avoid ++ extra))
            by_preference = Enum.sort(Enum.uniq(extra) -- hard_avoid)

            opts =
              base_opts
              |> Keyword.put(:bye_exclusions, exclusions)
              |> then(fn o ->
                if by_preference == [],
                  do: o,
                  else: Keyword.put(o, :bye_preference_exclusions, by_preference)
              end)

            {pairs,
             %{
               report
               | bye: holder(pairs),
                 moved: Enum.sort(pairs) != Enum.sort(fide),
                 decided_by: if(Enum.sort(pairs) != Enum.sort(fide), do: decided_by),
                 exclusions: exclusions,
                 opts: opts,
                 outcomes: outcomes
             }}
          end)
      end

    {pairs, %{report | outcomes: Enum.sort_by(report.outcomes, &{&1.rank, pref_order(&1)})}}
  end

  # ------------------------------------------------------------ settings

  defp parse!(prefs) when is_list(prefs) do
    Enum.map(prefs, fn
      {rank, pref} when is_integer(rank) and pref in @preferences ->
        {rank, pref, :all}

      {rank, pref, :all} when is_integer(rank) and pref in @preferences ->
        {rank, pref, :all}

      {rank, pref, rounds} = entry
      when is_integer(rank) and pref in @preferences and is_list(rounds) ->
        if Enum.all?(rounds, &is_integer/1), do: {rank, pref, rounds}, else: bad!(entry)

      other ->
        bad!(other)
    end)
  end

  defp parse!(other), do: bad!(other)

  defp bad!(what) do
    raise ArgumentError,
          ":bye_preferences takes {rank, preference} or {rank, preference, rounds} " <>
            "with preference one of #{inspect(@preferences)}, got #{inspect(what)}"
  end

  # The settings that apply to this round, with each player's conflicts
  # resolved: `{hard_avoid_ranks, entries}`, where `entries` holds every
  # remaining setting that names a player - applicable or not - as
  # `%{rank:, preference:, status:}`, `status` `:live` or an outcome
  # already decided.
  defp settings(prefs, round, opts, scores) do
    organiser = opts[:bye_exclusions] || []
    applicable = Enum.filter(prefs, fn {_r, _p, rounds} -> rounds == :all or round in rounds end)
    listed = Enum.map(applicable, fn {rank, pref, _} -> {rank, pref} end)

    by_player =
      (Enum.map(organiser, &{&1, :avoid_hard}) ++ listed)
      |> Enum.uniq()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    entries =
      Enum.flat_map(by_player, fn {rank, prefs} ->
        prefs
        |> resolve_player()
        |> Enum.map(fn {pref, status} ->
          status =
            if status == :live and not is_map_key(scores, rank), do: :not_in_round, else: status

          %{rank: rank, preference: pref, status: status}
        end)
      end)

    # The organiser's own list is passed on as given - including ranks not
    # in the round, which the engine ignores - so a round with no other
    # setting pairs with exactly the options it always had. A hard avoid
    # always wins its player's conflicts, so every one listed is in force.
    hard_avoid =
      Enum.sort(Enum.uniq(organiser ++ for({r, :avoid_hard} <- listed, do: r)))

    # The organiser's exclusions are not preferences and are not reported
    # as such - only a want they overrule is.
    reported =
      Enum.reject(entries, fn e ->
        e.preference == :avoid_hard and {e.rank, :avoid_hard} not in listed
      end)

    {hard_avoid, reported}
  end

  # One player's settings for the round -> `[{preference, status}]`.
  defp resolve_player(prefs) do
    want = strongest(prefs, [:want_hard, :want_soft])
    avoid = strongest(prefs, [:avoid_hard, :avoid_soft])

    case {want, avoid} do
      {nil, a} -> [{a, :live}]
      {w, nil} -> [{w, :live}]
      {w, :avoid_hard} -> [{:avoid_hard, :live}, {w, {:conflict, :avoid_hard}}]
      {:want_hard, a} -> [{:want_hard, :live}, {a, {:conflict, :want_hard}}]
      {w, a} -> [{w, {:conflict, a}}, {a, {:conflict, w}}]
    end
  end

  defp strongest(prefs, order), do: Enum.find(order, &(&1 in prefs))

  # A "must get the bye" C2 rules out, on a round that has a bye: the round
  # is refused rather than paired without the wish (see `RefusedError`).
  # Only a live want for a player in the round - one an exclusion overrules
  # is reported as a conflict instead, and an even field has no bye.
  defp refuse_second_bye!(players, opts, entries, round) do
    wanted = for %{preference: :want_hard, status: :live, rank: r} <- entries, do: r

    if wanted != [] do
      c2 = Pairing.bye_disqualifications(players, Keyword.delete(opts, :bye_exclusions))

      case for(
             r <- Enum.sort(wanted),
             {reason, at} = c2[r] || {nil, nil},
             reason,
             do: %{rank: r, reason: reason, round: at}
           ) do
        [] ->
          :ok

        refused ->
          raise Ainalrami.ByePreference.RefusedError,
            round: round,
            players: refused,
            message:
              "round #{round} not paired: " <>
                Enum.map_join(refused, "; ", fn p ->
                  "##{p.rank} must get the pairing-allocated bye but " <>
                    "#{Ainalrami.ByePreference.RefusedError.reason_words(p.reason)} " <>
                    "(round #{p.round})"
                end) <>
                " - FIDE C.04.3 C2 allows no second pairing-allocated bye; " <>
                "change or remove the bye preference"
      end
    end
  end

  defp eligibility(players, opts) do
    Pairing.bye_eligibility(players, Keyword.delete(opts, :bye_exclusions))
  end

  # ------------------------------------------------------------ resolution

  # `{pairs, extra_exclusions, decided_by, outcomes}`.
  defp resolve(players, opts, fide, entries, scores, eligibility, pair) do
    {live, settled} = Enum.split_with(entries, &(&1.status == :live))

    {live, ineligible} =
      Enum.split_with(live, fn e ->
        e.preference in [:avoid_hard, :avoid_soft] or is_nil(eligibility[e.rank])
      end)

    settled =
      Enum.map(settled, &outcome(&1, &1.status)) ++
        Enum.map(ineligible, &outcome(&1, {:ineligible, eligibility[&1.rank]}))

    ranks = fn pref -> for %{preference: ^pref, rank: r} <- live, do: r end
    ctx = %{players: players, opts: opts, scores: scores, fide: fide, pair: pair}

    {pairs, extra, decided_by, live_outcomes} =
      case want(ctx, ranks.(:want_hard), fide) do
        {:ok, pairs, extra} ->
          {pairs, extra, :want_hard, account(live, holder(pairs), :want_hard, [])}

        :unpairable ->
          unpairable = ranks.(:want_hard)
          soft = soft(ctx, ranks.(:want_soft), ranks.(:avoid_soft))
          {pairs, extra, by, notes} = soft
          {pairs, extra, by, account(live, holder(pairs), by, notes, unpairable)}
      end

    {pairs, extra, decided_by, settled ++ live_outcomes}
  end

  # A want: the round with every active player but the wanted ones kept
  # from the bye. `fide` already giving it to one of them is that round.
  defp want(_ctx, [], _fide), do: :unpairable

  defp want(ctx, wanted, fide) do
    if holder(fide) in wanted do
      {:ok, fide, []}
    else
      extra = Enum.reject(Map.keys(ctx.scores), &(&1 in wanted))

      case try_pair(ctx, extra) do
        {:ok, pairs} -> {:ok, pairs, extra}
        :error -> :unpairable
      end
    end
  end

  # `{pairs, extra, decided_by, notes}` - soft wants first, then soft
  # avoids, never at the cost of the bye score (see the moduledoc).
  defp soft(ctx, wants, avoids) do
    fide = ctx.fide
    s0 = score(ctx, holder(fide))

    case want(ctx, wants, fide) do
      {:ok, pairs, extra} when wants != [] ->
        if score(ctx, holder(pairs)) == s0,
          do: {pairs, extra, :want_soft, []},
          else: avoid(ctx, fide, avoids, s0, [{:outranked_wants, wants}])

      _ ->
        notes = if wants == [], do: [], else: [{:outranked_wants, wants}]
        avoid(ctx, fide, avoids, s0, notes)
    end
  end

  defp avoid(ctx, pairs, avoids, s0, notes) do
    chain(ctx, pairs, MapSet.new(avoids), s0, [], notes)
  end

  # Exclude the holder while it is someone to avoid; keep the last round
  # whose holder is still on the bye score.
  defp chain(ctx, pairs, avoids, s0, passed, notes) do
    h = holder(pairs)

    if MapSet.member?(avoids, h) do
      case try_pair(ctx, [h | passed]) do
        {:ok, next} ->
          if score(ctx, holder(next)) == s0,
            do: chain(ctx, next, avoids, s0, [h | passed], notes),
            else: {pairs, passed, by(passed), notes}

        :error ->
          {pairs, passed, by(passed), notes}
      end
    else
      {pairs, passed, by(passed), notes}
    end
  end

  defp by([]), do: nil
  defp by(_passed), do: :avoid_soft

  defp try_pair(ctx, extra) do
    excluded = Enum.uniq((ctx.opts[:bye_exclusions] || []) ++ extra)
    {:ok, ctx.pair.(ctx.players, Keyword.put(ctx.opts, :bye_exclusions, excluded))}
  rescue
    NoValidPairingError -> :error
  end

  # ------------------------------------------------------------ the account

  defp account(live, holder, decided_by, notes, unpairable \\ []) do
    outranked = Keyword.get(notes, :outranked_wants, [])

    Enum.map(live, fn e ->
      cond do
        e.preference in [:want_hard, :want_soft] and e.rank == holder ->
          outcome(e, :honoured)

        e.preference in [:avoid_hard, :avoid_soft] and e.rank != holder ->
          outcome(e, :honoured)

        e.preference in [:avoid_hard, :avoid_soft] ->
          outcome(e, :outranked)

        e.rank in unpairable ->
          outcome(e, :unpairable)

        e.preference == :want_soft and e.rank in outranked and
            decided_by not in [:want_hard, :want_soft] ->
          outcome(e, :outranked)

        true ->
          outcome(e, {:other_player, holder})
      end
    end)
  end

  defp outcome(e, {:conflict, with}),
    do: %{rank: e.rank, preference: e.preference, outcome: :conflict, with: with}

  defp outcome(e, {:ineligible, reason}),
    do: %{rank: e.rank, preference: e.preference, outcome: :ineligible, reason: reason}

  defp outcome(e, {:other_player, holder}),
    do: %{rank: e.rank, preference: e.preference, outcome: :other_player, holder: holder}

  defp outcome(e, status) when is_atom(status),
    do: %{rank: e.rank, preference: e.preference, outcome: status}

  defp pref_order(%{preference: p}), do: Enum.find_index(@preferences, &(&1 == p))

  defp holder(pairs), do: Enum.find_value(pairs, fn {w, b} -> if is_nil(b), do: w end)

  defp score(_ctx, nil), do: nil
  defp score(ctx, rank), do: Map.get(ctx.scores, rank)

  @doc """
  The report's outcomes as one plain-English line each - what the CLI
  prints, and a default any caller may use.
  """
  def describe(%{outcomes: outcomes} = report) do
    Enum.map(outcomes, &describe_outcome(&1, report))
  end

  defp describe_outcome(o, _report) do
    who = "##{o.rank} (#{label(o.preference)})"

    what =
      case o do
        %{outcome: :honoured, preference: p} when p in [:want_hard, :want_soft] ->
          "receives the pairing-allocated bye"

        %{outcome: :honoured} ->
          "does not receive the pairing-allocated bye"

        %{outcome: :no_bye_this_round} ->
          "not applied: the round has an even number of players, so there is no pairing-allocated bye"

        %{outcome: :not_in_round} ->
          "not applied: the player is not paired this round"

        %{outcome: :ineligible, reason: reason} ->
          "not applied: C2 rules the player out of the bye (#{reason_words(reason)})"

        %{outcome: :conflict, with: with} ->
          "not applied: the same player is also set to #{label(with)}, which takes precedence"

        %{outcome: :unpairable} ->
          "not applied: no legal round gives this player the bye, so the round is paired as without the wish"

        %{outcome: :other_player, holder: holder} ->
          "not applied: ##{holder}'s preference decided the bye"

        %{outcome: :outranked, preference: :want_soft} ->
          "not applied: the player could only get the bye on a higher score or not at all, which the FIDE criteria rank above this wish"

        %{outcome: :outranked} ->
          "not applied: nobody else on the bye score could take the bye"
      end

    "#{who}: #{what}"
  end

  defp label(:want_hard), do: "must get the bye"
  defp label(:want_soft), do: "rather gets the bye"
  defp label(:avoid_hard), do: "must not get the bye"
  defp label(:avoid_soft), do: "rather not the bye"

  defp reason_words(:pairing_bye), do: "already had a pairing-allocated bye"
  defp reason_words(:forfeit_win), do: "already won a game without playing"
  defp reason_words(:full_point_bye), do: "already had a full-point bye"
  defp reason_words(other), do: to_string(other)
end
