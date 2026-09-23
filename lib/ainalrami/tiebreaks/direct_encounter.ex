defmodule Ainalrami.Tiebreaks.DirectEncounter do
  @moduledoc """
  C.07 Article 6, Direct Encounter: orders a group of tied participants by
  the games among themselves.

  It is not a value a participant has, which is why it is not in
  `Ainalrami.Tiebreaks.Individual`: the same player can be first by DE in
  one tied group and last in another. `order/3` takes the tied group and
  returns it as an ordered list of subgroups, each subgroup still tied
  after Article 6 - the ranking goes on to the next tie-break inside each.

  ## The article, step by step

    * **6.1** - separate standings from the encounters among the group.
      Forfeits are excluded unless the tie-break says `P`, or the event's
      pairings were fixed in advance (15.2 makes those forfeits games, and
      6.1.1 excludes only forfeits "not covered by Article 15.2"). Two
      participants who met more than once add the average of those games
      (6.1.2), not the sum.
    * **6.2** - when every pair in the group has met, the separate standings
      rank the group, and Article 6 is applied again to each subset still
      tied, until nothing more resolves.
    * **6.3** - in a Swiss event where not every pair has met, a participant
      who is alone at the top whatever the missing games' results is ranked
      first; then the same for the next place among the rest; whoever is
      left is taken through Article 6 again. "Alone at the top whatever the
      outcome" is reading 6 in docs/conformance-c07-tiebreaks.md: their
      score with every missing game lost is above every rival's score with
      every missing game won.

  Anything Article 6 cannot resolve is returned still tied, never guessed.
  """

  alias Ainalrami.Tiebreaks.{Code, Event}

  @doc """
  Orders `group` (a list of participant ids). Returns `[[id]]` - subgroups
  in rank order, each one still tied.
  """
  def order(group, %Code{} = code, %Event{} = event) do
    resolve(group, code, event)
  end

  defp resolve([_] = group, _code, _event), do: [group]
  defp resolve([], _code, _event), do: []

  defp resolve(group, code, event) do
    {scores, missing} = separate_standings(group, code, event)

    cond do
      missing == %{} ->
        all_met(group, scores, code, event)

      not event.predetermined? ->
        swiss_incomplete(group, scores, missing, code, event)

      true ->
        [group]
    end
  end

  # 6.2
  defp all_met(group, scores, code, event) do
    subgroups =
      group
      |> Enum.group_by(&key(scores[&1]))
      |> Enum.sort_by(fn {score, _} -> score end, :desc)
      |> Enum.map(fn {_score, members} -> Enum.sort(members) end)

    case subgroups do
      # Nothing separated: reapplying to the same set changes nothing.
      [^group] -> [group]
      [same] when length(same) == length(group) -> [group]
      _ -> Enum.flat_map(subgroups, &resolve(&1, code, event))
    end
  end

  # 6.3
  defp swiss_incomplete(group, scores, missing, code, event) do
    win = event.points.win
    loss = event.points.loss

    worst = fn id -> scores[id] + length(Map.get(missing, id, [])) * loss end
    best = fn id -> scores[id] + length(Map.get(missing, id, [])) * win end

    {ranked, rest} = peel(group, worst, best, [])

    cond do
      ranked == [] -> [group]
      rest == [] -> Enum.map(ranked, &[&1])
      true -> Enum.map(ranked, &[&1]) ++ resolve(rest, code, event)
    end
  end

  defp peel(candidates, worst, best, ranked) do
    alone =
      Enum.find(candidates, fn c ->
        Enum.all?(candidates -- [c], fn r -> worst.(c) > best.(r) + 1.0e-9 end)
      end)

    case alone do
      nil -> {Enum.reverse(ranked), candidates}
      c -> peel(candidates -- [c], worst, best, [c | ranked])
    end
  end

  # {%{id => separate score}, %{id => [ids not met]}}
  defp separate_standings(group, code, event) do
    counted? = fn round ->
      round.kind == :played or
        (round.kind in [:forfeit_win, :forfeit_loss] and (code.forfeits? or event.predetermined?))
    end

    in_group = MapSet.new(group)

    per_pair =
      for id <- group,
          {_r, round} <- event.participants[id].rounds,
          counted?.(round),
          round.opponent in in_group,
          reduce: %{} do
        acc -> Map.update(acc, {id, round.opponent}, [round.points], &[round.points | &1])
      end

    scores =
      Map.new(group, fn id ->
        total =
          for other <- group, other != id, games = per_pair[{id, other}], reduce: 0.0 do
            acc -> acc + Enum.sum(games) / length(games)
          end

        {id, total}
      end)

    missing =
      for id <- group,
          other <- group,
          other != id,
          not Map.has_key?(per_pair, {id, other}),
          reduce: %{} do
        acc -> Map.update(acc, id, [other], &[other | &1])
      end

    {scores, missing}
  end

  defp key(value), do: Float.round(value * 1.0, 6)
end
