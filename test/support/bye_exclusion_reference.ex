defmodule Ainalrami.Test.ByeExclusionReference do
  @moduledoc """
  A brute-force reference for the pairing-allocated bye under the
  organiser's bye exclusions (`Ainalrami.Pairing.pair_next_round/2`'s
  `:bye_exclusions`, not a FIDE rule).

  It shares no code with `Ainalrami.Pairing`. The absolute criteria are
  written from the article text, the same way `tools/exhaustion_bruteforce.exs`
  writes them, and the search is exhaustive: every complete pairing of the
  active field is enumerated (with early exit on the first legal one), where
  the engine runs a weighted matching over a graph whose missing edges encode
  the same rules.

  What it answers, for a field and an exclusion list:

    * `feasible?/3` - does ANY legal round exist in which the bye goes to a
      player [C2] allows and the organiser did not exclude?
    * `min_bye_score/3` - [C5], "minimise the score of the assignee of the
      pairing-allocated bye", over exactly those rounds: the lowest score a
      permitted bye holder can have in a legal round, or nil.
    * `violations/4` - what is wrong with a round the engine produced:
      seating, rematches, colour clashes, forbidden pairs, and a bye to a
      player C2 or the organiser rules out.

  The exclusion enters in ONE place, `bye_permitted?/3`, beside [C2] - which
  is the whole claim being checked: an excluded player is ineligible for the
  bye exactly as a player who already had one, and for nothing else.

  Scope: the standard 1/=/0 point system with `H` worth a draw and `Z`
  nothing, no acceleration, one forbidden-pair list. That is what
  `Ainalrami.ByeExclusionValidationTest` generates.
  """

  @max_field 15

  @doc "The largest active field the exhaustive search is run on."
  def max_field, do: @max_field

  # ---------------------------------------------------------------- rules

  # C1. Only a PLAYED game counts; a forfeit is legally unplayed.
  defp met_before?(a, b) do
    Enum.any?(a.games, &(&1.result in ~w(1 = 0) and &1.opponent_rank == b.rank))
  end

  # C2, both clauses: a pairing-allocated bye (an opponentless `U` or `+`),
  # or a win's worth scored in one round without playing (`+`, `F`, `U`).
  defp c2_eligible?(player) do
    not Enum.any?(player.games, fn g ->
      (is_nil(g.opponent_rank) and g.result in ~w(U +)) or g.result in ~w(+ F U)
    end)
  end

  @doc "May `player` receive the pairing-allocated bye: [C2] and not excluded."
  def bye_permitted?(player, excluded, _ctx) do
    c2_eligible?(player) and not MapSet.member?(excluded, player.rank)
  end

  # 1.7.1: colour difference beyond +-1, or the same colour in the two
  # latest rounds PLAYED.
  defp absolute_preference(player) do
    coloured = Enum.filter(player.games, &(&1.result in ~w(1 = 0) and &1.colour in ~w(w b)))
    whites = Enum.count(coloured, &(&1.colour == "w"))
    diff = whites - (length(coloured) - whites)
    last_two = coloured |> Enum.reverse() |> Enum.take(2) |> Enum.map(& &1.colour)

    cond do
      diff > 1 -> "b"
      diff < -1 -> "w"
      match?([x, x], last_two) -> if(hd(last_two) == "w", do: "b", else: "w")
      true -> nil
    end
  end

  # 1.8: more than 50% of the maximum possible score so far, final round
  # only.
  defp topscorer?(player, ctx) do
    ctx.played >= ctx.expected - 1 and player.points > ctx.played / 2
  end

  # C3, with the topscorer exception: ONE topscorer lifts it.
  defp colour_clash?(a, b, ctx) do
    pa = absolute_preference(a)

    not is_nil(pa) and pa == absolute_preference(b) and
      not (topscorer?(a, ctx) or topscorer?(b, ctx))
  end

  defp forbidden?(a, b, ctx) do
    MapSet.member?(ctx.forbidden, Enum.sort([a.rank, b.rank]))
  end

  defp legal_pair?(a, b, ctx) do
    not met_before?(a, b) and not colour_clash?(a, b, ctx) and not forbidden?(a, b, ctx)
  end

  # ------------------------------------------------------------ the search

  @doc """
  `ctx` is `%{played:, expected:, forbidden: MapSet of sorted [a, b]}`.
  """
  def feasible?(active, excluded, ctx), do: not is_nil(min_bye_score(active, excluded, ctx))

  @doc """
  [C5] under the exclusions: the lowest score a permitted bye holder has in
  any legal round; nil when there is none. On an even field there is no
  bye, and the answer is `:no_bye` when a legal round exists.
  """
  def min_bye_score(active, excluded, ctx) do
    if rem(length(active), 2) == 0 do
      if perfect?(active, ctx), do: :no_bye, else: nil
    else
      active
      |> Enum.filter(&bye_permitted?(&1, excluded, ctx))
      |> Enum.sort_by(& &1.points)
      |> Enum.find_value(fn bye ->
        if perfect?(List.delete(active, bye), ctx), do: bye.points
      end)
    end
  end

  defp perfect?([], _ctx), do: true

  defp perfect?([first | rest], ctx) do
    Enum.any?(rest, fn partner ->
      legal_pair?(first, partner, ctx) and perfect?(List.delete(rest, partner), ctx)
    end)
  end

  @doc """
  Everything wrong with `pairs` as a round of `active`, as a list of
  tagged tuples; `[]` for a legal round.
  """
  def violations(active, pairs, excluded, ctx) do
    by_rank = Map.new(active, &{&1.rank, &1})
    seated = Enum.flat_map(pairs, fn {w, b} -> if b, do: [w, b], else: [w] end)
    byes = for {w, nil} <- pairs, do: w

    seating =
      if Enum.sort(seated) == Enum.sort(Map.keys(by_rank)),
        do: [],
        else: [{:seating, Enum.sort(seated), Enum.sort(Map.keys(by_rank))}]

    bye_count =
      if length(byes) == rem(map_size(by_rank), 2), do: [], else: [{:bye_count, byes}]

    bye_rules =
      byes
      |> Enum.map(&{&1, by_rank[&1]})
      |> Enum.reject(fn {_w, p} -> is_nil(p) or bye_permitted?(p, excluded, ctx) end)
      |> Enum.map(fn {w, p} ->
        if c2_eligible?(p), do: {:bye_to_excluded, w}, else: {:bye_to_c2_ineligible, w}
      end)

    pair_rules =
      pairs
      |> Enum.reject(fn {_w, b} -> is_nil(b) end)
      |> Enum.filter(fn {w, b} ->
        a = by_rank[w]
        c = by_rank[b]
        a && c && not legal_pair?(a, c, ctx)
      end)
      |> Enum.map(fn {w, b} -> {:illegal_pair, w, b} end)

    seating ++ bye_count ++ bye_rules ++ pair_rules
  end
end
