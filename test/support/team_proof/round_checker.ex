defmodule Ainalrami.TeamProof.RoundChecker do
  @moduledoc """
  A CHECKER for one paired C.04.6 round: it constructs nothing, it is handed
  the round and says what is wrong with it.

  ## Why it exists next to the exact reference

  `Ainalrami.TeamProof.ExactReference` reduces Article 3.6 to two
  minimum-cost matchings by packing the identifier order into the edge
  costs. On 2026-09-25 the ENGINE adopted that same reduction for its own
  3.6 (`Ainalrami.TeamPairing.Bracket.exact/1`, with its own matcher). The
  two still share no code, but for 3.6 they now share an ARGUMENT, and an
  error in the argument would be made twice and agree with itself. Below
  about ten teams the naive enumeration settles it; above that nothing did.

  This module checks 3.6 without that argument. It never packs an
  identifier into a cost. It asks the regulation's question directly, one
  position at a time:

    1. the bracket's pairing has the least `{C8, C10}` any legal pairing of
       the bracket has (one matching, the cost a pair of small counts);
    2. no legal pairing with that least cost has an earlier TOP set: for
       every team that is a bottom in the round, force it to be a top while
       holding every smaller team to its role - if a least-cost pairing
       still exists, the round's identifier was not the first;
    3. no such pairing has an earlier BOTTOM sequence: for every top in
       order, hold the earlier pairs, offer this top only the bottoms
       smaller than the one it got - if a least-cost pairing still exists,
       the round's identifier was not the first.

  That is about one matching per team in the bracket instead of two per
  bracket, so it is run on brackets up to a size cap (`:max_bracket`) and
  reports how many it checked and skipped.

  It also checks the absolutes on the whole round, at any size: every team
  of the field placed exactly once, a bye exactly when the field is odd and
  only for a team [C2] allows, and no rematch ([C1]).

  ## What it does not check

  Which teams are in a bracket (3.5: [C4]-[C7], and 3.4's choice among
  eligible bye teams) - that is the exact reference's job, and the engine
  does 3.5 by a different method from the reference (an ordered walk, not a
  matching), so no argument is shared there. It takes the brackets as the
  round has them: each scoregroup's residents and the lower teams they were
  paired with.

  ## What it shares

  With the engine: the `%Team{}` struct. With the exact reference: the
  matcher (`Ainalrami.TeamProof.Blossom`) and the naive reference's Type A
  preference (`ref_preference/1`) - not the reduction.
  """

  alias Ainalrami.TeamProof.{Blossom, NaiveReference}

  @doc """
  `round` is `%{bye: tpn | nil, pairs: [{white, black}]}`; `opts` the
  engine options the round was paired with (`:round`, `:expected_rounds`).

  Returns `{:ok, %{checked: n, skipped: n}}` (brackets) or `{:error, text}`.
  """
  def check(field, round, opts, max_bracket \\ 64) do
    last_two? = opts[:round] >= opts[:expected_rounds] - 1
    by_tpn = Map.new(field, &{&1.tpn, &1})

    with :ok <- absolutes(field, by_tpn, round) do
      partner =
        round.pairs
        |> Enum.flat_map(fn {w, b} -> [{w, b}, {b, w}] end)
        |> Map.new()

      remaining = field |> Enum.reject(&(&1.tpn == round.bye)) |> Enum.sort_by(& &1.tpn)
      brackets(remaining, partner, by_tpn, last_two?, max_bracket, %{checked: 0, skipped: 0})
    end
  end

  # ------------------------------------------------------------------
  # The absolutes
  # ------------------------------------------------------------------

  defp absolutes(field, by_tpn, round) do
    placed = Enum.flat_map(round.pairs, fn {w, b} -> [w, b] end) ++ List.wrap(round.bye)
    rematch = Enum.find(round.pairs, fn {w, b} -> met?(by_tpn[w], by_tpn[b]) end)
    bye = round.bye && by_tpn[round.bye]

    cond do
      Enum.sort(placed) != field |> Enum.map(& &1.tpn) |> Enum.sort() ->
        {:error, "the round does not place every team of the field exactly once"}

      round.bye != nil != (rem(length(field), 2) == 1) ->
        {:error,
         "a bye exactly when the field is odd: field #{length(field)}, bye #{inspect(round.bye)}"}

      bye != nil and (bye.had_pab? or bye.won_by_forfeit?) ->
        {:error, "[C2]: team #{bye.tpn} has had a bye or a forfeit win and got the bye"}

      rematch != nil ->
        {:error, "[C1]: #{inspect(rematch)} have met"}

      true ->
        :ok
    end
  end

  defp met?(a, b), do: a.tpn in b.opponents or b.tpn in a.opponents

  # ------------------------------------------------------------------
  # The brackets as the round has them, top scoregroup first
  # ------------------------------------------------------------------

  defp brackets([], _partner, _by_tpn, _last_two?, _max, stats), do: {:ok, stats}

  defp brackets(remaining, partner, by_tpn, last_two?, max, stats) do
    top = remaining |> Enum.map(& &1.match_points) |> Enum.max()
    residents = Enum.filter(remaining, &(&1.match_points == top))
    resident? = MapSet.new(residents, & &1.tpn)

    ups =
      for r <- residents,
          p = partner[r.tpn],
          not MapSet.member?(resident?, p),
          do: p

    bracket = residents ++ Enum.map(ups, &by_tpn[&1])
    in_bracket = MapSet.new(bracket, & &1.tpn)
    rest = Enum.reject(remaining, &MapSet.member?(in_bracket, &1.tpn))

    cond do
      Enum.any?(ups, &(by_tpn[&1].match_points > top)) ->
        {:error, "the #{top}-point scoregroup is paired with a team already placed above it"}

      length(bracket) > max ->
        brackets(rest, partner, by_tpn, last_two?, max, %{stats | skipped: stats.skipped + 1})

      true ->
        case bracket_36(bracket, MapSet.new(ups), partner, last_two?) do
          :ok ->
            brackets(rest, partner, by_tpn, last_two?, max, %{stats | checked: stats.checked + 1})

          {:error, text} ->
            {:error,
             "the #{top}-point bracket #{inspect(Enum.sort(MapSet.to_list(in_bracket)))}: #{text}"}
        end
    end
  end

  # ------------------------------------------------------------------
  # 3.6 on one bracket, position by position
  # ------------------------------------------------------------------

  defp bracket_36(bracket, ups, partner, last_two?) do
    teams = Enum.sort_by(bracket, & &1.tpn)
    m = length(teams)
    index = teams |> Enum.with_index() |> Map.new(fn {t, i} -> {t.tpn, i} end)
    tuple = List.to_tuple(teams)
    pref = Map.new(teams, &{&1.tpn, NaiveReference.ref_preference(&1)})

    # {c8, c10} of one pair as ONE small number: c10 is at most 2 a pair, so
    # at most m over a pairing, and m + 1 keeps it from carrying into c8.
    cost = fn i, j ->
      a = elem(tuple, i)
      b = elem(tuple, j)
      c8 = if pref[a.tpn] != nil and pref[a.tpn] == pref[b.tpn], do: 1, else: 0

      c10 =
        if last_two? do
          0
        else
          if(MapSet.member?(ups, b.tpn) and a.floated_last_round?, do: 1, else: 0) +
            if MapSet.member?(ups, a.tpn) and b.floated_last_round?, do: 1, else: 0
        end

      c8 * (m + 1) + c10
    end

    edges =
      for i <- 0..(m - 2)//1,
          j <- (i + 1)..(m - 1)//1,
          not met?(elem(tuple, i), elem(tuple, j)),
          do: {i, j, cost.(i, j)}

    least = fn edges ->
      case Blossom.min_cost_perfect(m, edges) do
        :none -> nil
        {:ok, c, _mate} -> c
      end
    end

    # The round's pairing of this bracket, as {top, bottom} index pairs in
    # the tops' order.
    pairs =
      for t <- teams, i = index[t.tpn], j = index[partner[t.tpn]], i < j, do: {i, j}

    role = Map.new(Enum.flat_map(pairs, fn {t, b} -> [{t, :top}, {b, :bottom}] end))
    mine = pairs |> Enum.map(fn {t, b} -> cost.(t, b) end) |> Enum.sum()
    opt = least.(edges)

    cond do
      opt != mine ->
        {:error,
         "{C8, C10} is #{inspect(unpack(mine, m))}, a legal pairing reaches #{inspect(unpack(opt, m))}"}

      (i = earlier_top(pairs, role, edges, opt, least)) != nil ->
        {:error,
         "team #{elem(tuple, i).tpn} is a bottom, and a least-cost pairing has it as a top with every smaller team as it is"}

      (k = earlier_bottom(pairs, role, edges, opt, least)) != nil ->
        {t, b} = Enum.at(pairs, k)

        {:error,
         "top #{elem(tuple, t).tpn} got #{elem(tuple, b).tpn}, and a least-cost pairing gives it a smaller bottom with the earlier pairs as they are"}

      true ->
        :ok
    end
  end

  defp unpack(nil, _m), do: nil
  defp unpack(c, m), do: {div(c, m + 1), rem(c, m + 1)}

  # A bottom of the round that could have been a top, every smaller team
  # keeping its role: the top set containing it is earlier in the order.
  defp earlier_top(pairs, role, edges, opt, least) do
    pairs
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort()
    |> Enum.find(fn i ->
      confined =
        Enum.filter(edges, fn {a, b, _c} ->
          # a < b: a is this edge's top, b its bottom.
          (a >= i or role[a] == :top) and (b > i or (b < i and role[b] == :bottom))
        end)

      least.(confined) == opt
    end)
  end

  # A top of the round that could have had a smaller bottom, the earlier
  # tops keeping theirs and the top set unchanged.
  defp earlier_bottom(pairs, role, edges, opt, least) do
    top_to_bottom =
      Enum.filter(edges, fn {a, b, _c} -> role[a] == :top and role[b] == :bottom end)

    Enum.find(0..(length(pairs) - 1)//1, fn k ->
      {t, b} = Enum.at(pairs, k)
      fixed = Map.new(Enum.take(pairs, k))
      fixed_bottoms = MapSet.new(Map.values(fixed))

      confined =
        Enum.filter(top_to_bottom, fn {a, c, _cost} ->
          cond do
            Map.has_key?(fixed, a) -> fixed[a] == c
            MapSet.member?(fixed_bottoms, c) -> false
            a == t -> c < b
            true -> true
          end
        end)

      Enum.any?(confined, fn {a, _c, _cost} -> a == t end) and least.(confined) == opt
    end)
  end
end
