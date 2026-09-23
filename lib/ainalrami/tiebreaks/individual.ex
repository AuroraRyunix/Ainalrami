defmodule Ainalrami.Tiebreaks.Individual do
  @moduledoc """
  The individual tie-breaks of C.07 Articles 7-10: one value per
  participant for a `%Ainalrami.Tiebreaks.Code{}`.

  `values/3` returns `%{id => value}`, or `:dropped` for an Article 10
  tie-break in an event with unrated participants and no rating to use for
  them - "these tie-breaks must be dropped from the tournament tie-break
  list when unrated players are present, unless detailed rules on the
  handling of unrated players are included" (Article 10; the rule is
  `U<rating>` on the code). Direct encounter is not here: it is not a value
  a participant has but an ordering of a tied group, see
  `Ainalrami.Tiebreaks.DirectEncounter`.

  Swiss events follow Article 16 (`Ainalrami.Tiebreaks.Unplayed`); events
  with pairings fixed in advance follow 15.2, where forfeits are games
  "except that all forfeits in ratings-based tie-breaks and forfeit losses
  in Type B tie-breaks remain unplayed rounds". Every reading taken is in
  docs/conformance-c07-tiebreaks.md under the article it belongs to.
  """

  alias Ainalrami.Tiebreaks.{Code, Event, Rating, Unplayed}

  @doc """
  Everything the tie-breaks share, computed once: scores, adjusted scores.
  """
  def context(%Event{} = event) do
    scores =
      Map.new(event.participants, fn {id, p} ->
        {id, p.rounds |> Map.values() |> Enum.map(& &1.points) |> Enum.sum()}
      end)

    adjusted =
      if event.predetermined?,
        do: scores,
        else:
          Map.new(event.participants, fn {id, p} ->
            {id, Unplayed.adjusted_score(p.rounds, event)}
          end)

    %{event: event, scores: scores, adjusted: adjusted}
  end

  @doc "`%{id => value}` or `:dropped` - see the moduledoc."
  def values(%Code{} = code, %Event{} = event, ctx \\ nil) do
    ctx = ctx || context(event)
    compute(code.name, code, ctx)
  end

  # ---- the score --------------------------------------------------------

  defp compute("PTS", _code, ctx), do: ctx.scores

  # ---- Type B (Article 7) -----------------------------------------------

  # 7.1: rounds with a win's points, with or without playing. (A forfeit
  # loss scores no points, so 15.2's exception changes nothing here.)
  defp compute("WIN", _code, ctx) do
    win = ctx.event.points.win
    per_round(ctx, fn round -> if round.points >= win - 1.0e-9, do: 1, else: 0 end)
  end

  # 7.2: games won over the board - also under 15.2 (reading 9).
  defp compute("WON", _code, ctx),
    do: per_round(ctx, &if(game?(&1, ctx) and &1.outcome == :win, do: 1, else: 0))

  # 7.3, 7.4: games played / won over the board with the black pieces.
  defp compute("BPG", _code, ctx),
    do: per_round(ctx, &if(game?(&1, ctx) and &1.colour == :black, do: 1, else: 0))

  defp compute("BWG", _code, ctx) do
    per_round(ctx, fn round ->
      if game?(round, ctx) and round.colour == :black and round.outcome == :win, do: 1, else: 0
    end)
  end

  # 7.5: the running score after each round, summed. Cut-n drops the first
  # n running scores (14.1.2 c).
  defp compute("PS", code, ctx) do
    each(ctx, fn p ->
      {running, _} =
        Enum.map_reduce(1..ctx.event.rounds//1, 0.0, fn r, acc ->
          score = acc + p.rounds[r].points
          {score, score}
        end)

      running |> Enum.drop(code.cut_low) |> Enum.sum()
    end)
  end

  # 7.6: rounds minus half-point byes, zero-point byes and forfeit losses.
  defp compute("REP", _code, ctx) do
    each(ctx, fn p ->
      ctx.event.rounds -
        Enum.count(p.rounds, fn {_r, round} ->
          round.kind in [:half_bye, :zero_bye, :forfeit_loss]
        end)
    end)
  end

  # 7.7: a point for scoring more than the scheduled opponent (or, without
  # one, more than a draw), half for the same.
  defp compute("STD", _code, ctx) do
    draw = ctx.event.points.draw

    each(ctx, fn p ->
      Enum.reduce(p.rounds, 0.0, fn {r, round}, acc ->
        against =
          case round.opponent do
            nil -> draw
            opponent -> ctx.event.participants[opponent].rounds[r].points
          end

        cond do
          round.points > against + 1.0e-9 -> acc + 1.0
          abs(round.points - against) <= 1.0e-9 -> acc + 0.5
          true -> acc
        end
      end)
    end)
  end

  # 7.8, 10.6: the ordering direction lives in `Ainalrami.Tiebreaks`.
  defp compute("TPN", _code, ctx), do: each(ctx, & &1.tpn)

  defp compute("RTNG", code, ctx) do
    if dropped?(code, ctx), do: :dropped, else: each(ctx, &(&1.rating || code.unrated))
  end

  # ---- Buchholz family (Articles 8, 16) ---------------------------------

  defp compute("BH", code, ctx), do: ctx |> buchholz_contributions() |> cut(code, :by_value, ctx)

  defp compute("FB", code, ctx) do
    ctx.event |> fore() |> context() |> buchholz_contributions() |> cut(code, :by_value, ctx)
  end

  # 8.2: over opponents met over the board - a dummy has no Buchholz.
  defp compute("AOB", code, ctx) do
    source = if code.fore?, do: "FB", else: "BH"
    of_opponents = compute(source, %Code{name: source}, ctx)

    each(ctx, fn p ->
      case for({_r, %{kind: :played, opponent: o}} <- p.rounds, do: of_opponents[o]) do
        [] -> 0.0
        values -> Enum.sum(values) / length(values)
      end
    end)
  end

  defp compute("SB", code, ctx),
    do: ctx |> sonneborn_contributions() |> cut(code, :by_opponent_score, ctx)

  # 9.2: points against participants on at least half of the maximum
  # possible score, the limit moved by half a point per step of `Ln` (14.5).
  #
  # "The maximum possible tournament score" is a win's points for every round
  # a participant could have been scheduled against somebody: in an odd
  # round robin nobody can score in their free round, so 13 players over 13
  # rounds have a maximum of 12, not 13. In a Swiss event every round can
  # score (a pairing-allocated bye does). Points count against a qualifying
  # opponent in every round with a scheduled opponent, forfeits included -
  # they are points "achieved against" that participant. (Reading 10, and
  # TieBreakServer's `compute_koya`.)
  defp compute("KS", code, ctx) do
    threshold = max_possible(ctx) / 2 + code.limit * 0.5

    each(ctx, fn p ->
      Enum.reduce(p.rounds, 0.0, fn {_r, round}, acc ->
        if round.opponent != nil and ctx.scores[round.opponent] >= threshold - 1.0e-9,
          do: acc + round.points,
          else: acc
      end)
    end)
  end

  # ---- Ratings (Article 10) ---------------------------------------------

  defp compute(name, code, ctx) when name in ~w(ARO TPR PTP) do
    if dropped?(code, ctx) do
      :dropped
    else
      each(ctx, fn p ->
        games = rated_games(p, code, ctx)

        case name do
          "ARO" ->
            games
            |> Enum.map(&elem(&1, 0))
            |> Enum.sort()
            |> Enum.drop(code.cut_low)
            |> Enum.reverse()
            |> Enum.drop(code.cut_high)
            |> Rating.aro()

          "TPR" ->
            Rating.tpr(
              Enum.map(games, &elem(&1, 0)),
              games |> Enum.map(&elem(&1, 1)) |> Enum.sum()
            )

          "PTP" ->
            Rating.ptp(
              Enum.map(games, &elem(&1, 0)),
              games |> Enum.map(&elem(&1, 1)) |> Enum.sum()
            )
        end
      end)
    end
  end

  defp compute(name, code, ctx) when name in ~w(APRO APPO) do
    if dropped?(code, ctx) do
      :dropped
    else
      of_opponents = compute(if(name == "APRO", do: "TPR", else: "PTP"), code, ctx)

      each(ctx, fn p ->
        values =
          for {_r, %{kind: :played, opponent: o}} <- p.rounds,
              value = of_opponents[o],
              not is_nil(value),
              do: value

        case values do
          [] -> nil
          values -> Rating.round_half_up(Enum.sum(values) / length(values))
        end
      end)
    end
  end

  # ---- shared ------------------------------------------------------------

  defp each(ctx, fun), do: Map.new(ctx.event.participants, fn {id, p} -> {id, fun.(p)} end)

  defp per_round(ctx, fun) do
    each(ctx, fn p -> p.rounds |> Map.values() |> Enum.map(fun) |> Enum.sum() end)
  end

  # A game over the board. Reading 9: 7.2-7.4 each say "over the board", and
  # that wins over 15.2's general "forfeits are treated as regular games" -
  # a forfeit win in a round robin is not a game won over the board.
  defp game?(%{kind: :played}, _ctx), do: true
  defp game?(_round, _ctx), do: false

  defp max_possible(%{event: %{predetermined?: false} = event}),
    do: event.rounds * event.points.win

  defp max_possible(%{event: event}) do
    scheduled =
      event.participants
      |> Map.values()
      |> Enum.map(fn p -> Enum.count(p.rounds, fn {_r, round} -> round.opponent != nil end) end)
      |> Enum.max(fn -> 0 end)

    scheduled * event.points.win
  end

  # Article 10's opening paragraph.
  defp dropped?(%Code{unrated: nil}, ctx),
    do: Enum.any?(ctx.event.participants, fn {_id, p} -> is_nil(p.rating) end)

  defp dropped?(_code, _ctx), do: false

  # {opponent rating, score in games} for each game played over the board -
  # forfeits stay unplayed here even under 15.2.
  defp rated_games(p, code, ctx) do
    for {_r, %{kind: :played} = round} <- p.rounds do
      opponent = ctx.event.participants[round.opponent]
      {opponent.rating || code.unrated, game_score(round.outcome)}
    end
  end

  defp game_score(:win), do: 1.0
  defp game_score(:draw), do: 0.5
  defp game_score(:loss), do: 0.0

  # ---- contributions and cuts (Articles 14, 16.5) ------------------------

  # One entry per round: the value it adds, the score of the opponent (or
  # dummy) it came from, and whether the round was a VUR.
  defp buchholz_contributions(ctx) do
    each(ctx, fn p ->
      for r <- counted_rounds(p, ctx) do
        score = opponent_score(p, r, ctx)
        %{value: score, opponent_score: score, vur?: Unplayed.vur?(p.rounds[r])}
      end
    end)
  end

  defp sonneborn_contributions(ctx) do
    each(ctx, fn p ->
      for r <- counted_rounds(p, ctx) do
        score = opponent_score(p, r, ctx)
        round = p.rounds[r]

        %{
          value: score * round.points,
          opponent_score: score,
          vur?: Unplayed.vur?(round)
        }
      end
    end)
  end

  # The rounds that are elements of a Buchholz or Sonneborn-Berger sum: all
  # of them in a Swiss event, where an unplayed round is a game against a
  # dummy (16.4); only those with an opponent when the pairings were fixed in
  # advance, where there is no dummy - the free round of an odd round robin
  # is not an element at all, and so is not what Cut-1 removes.
  defp counted_rounds(p, %{event: %{predetermined?: true}} = ctx),
    do: for(r <- 1..ctx.event.rounds//1, p.rounds[r].opponent != nil, do: r)

  defp counted_rounds(_p, ctx), do: Enum.to_list(1..ctx.event.rounds//1)

  # What round `r` contributes as "the opponent's score": the opponent's
  # adjusted score for a game; the dummy's score for an unplayed round in a
  # Swiss event (16.4). With pairings fixed in advance a forfeit is a game
  # (15.2) and a round without an opponent contributes nothing.
  defp opponent_score(p, r, ctx) do
    round = p.rounds[r]

    cond do
      round.kind == :played ->
        ctx.adjusted[round.opponent]

      ctx.event.predetermined? ->
        if round.opponent, do: ctx.scores[round.opponent], else: 0.0

      true ->
        Unplayed.dummy_score(p.rounds, r, ctx.scores[p.id], ctx.adjusted, ctx.event)
    end
  end

  # Article 14 with 16.5's exception. `:by_value` is Buchholz's notion of
  # the least significant value (the lowest contribution); `:by_opponent_
  # score` is Sonneborn-Berger's (the contribution of the opponent with the
  # lowest score, the lowest such contribution among several - 14.1.2 d).
  # In a Swiss event, each low cut compares that with the lowest VUR
  # contribution and removes the higher of the two (16.5.2) - which for
  # Buchholz is always the VUR one.
  defp cut(contributions, code, notion, ctx) do
    swiss? = not ctx.event.predetermined?

    Map.new(contributions, fn {id, list} ->
      list = Enum.reduce(1..code.cut_low//1, list, fn _, acc -> cut_low(acc, notion, swiss?) end)
      list = Enum.reduce(1..code.cut_high//1, list, fn _, acc -> cut_high(acc, notion) end)
      {id, list |> Enum.map(& &1.value) |> Enum.sum()}
    end)
  end

  defp cut_low([], _notion, _swiss?), do: []

  defp cut_low(list, notion, swiss?) do
    least = least_significant(list, notion)

    victim =
      case swiss? && Enum.filter(list, & &1.vur?) do
        vurs when is_list(vurs) and vurs != [] ->
          lowest_vur = Enum.min_by(vurs, & &1.value)
          if lowest_vur.value >= least.value, do: lowest_vur, else: least

        _ ->
          least
      end

    remove_one(list, victim)
  end

  defp cut_high([], _notion), do: []
  defp cut_high(list, notion), do: remove_one(list, most_significant(list, notion))

  defp least_significant(list, :by_value), do: Enum.min_by(list, & &1.value)

  defp least_significant(list, :by_opponent_score) do
    low = list |> Enum.map(& &1.opponent_score) |> Enum.min()
    list |> Enum.filter(&(&1.opponent_score == low)) |> Enum.min_by(& &1.value)
  end

  defp most_significant(list, :by_value), do: Enum.max_by(list, & &1.value)

  defp most_significant(list, :by_opponent_score) do
    high = list |> Enum.map(& &1.opponent_score) |> Enum.max()
    list |> Enum.filter(&(&1.opponent_score == high)) |> Enum.max_by(& &1.value)
  end

  # Removes exactly one element equal to `victim` - equal maps are
  # interchangeable, so which of several identical ones goes does not
  # matter.
  defp remove_one(list, victim), do: List.delete(list, victim)

  # ---- Fore Buchholz (8.3) -----------------------------------------------

  # The event as it would stand if every paired game of the final round had
  # been drawn. Byes in that round stay as awarded.
  # Only once the event's final round is among the rounds counted - before
  # that there is nothing to draw, and FB is BH (see Event.new/3).
  defp fore(%Event{rounds: rounds, total_rounds: total} = event) when rounds < total or rounds == 0,
    do: event

  defp fore(%Event{rounds: last, points: points} = event) do
    participants =
      Map.new(event.participants, fn {id, p} ->
        round = p.rounds[last]

        round =
          if round.kind in [:played, :forfeit_win, :forfeit_loss],
            do: %{round | kind: :played, points: points.draw, outcome: :draw},
            else: round

        {id, %{p | rounds: Map.put(p.rounds, last, round)}}
      end)

    %{event | participants: participants}
  end
end
