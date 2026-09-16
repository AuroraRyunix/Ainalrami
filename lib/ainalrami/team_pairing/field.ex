defmodule Ainalrami.TeamPairing.Field do
  @moduledoc """
  The round's "who may still meet whom", built once per round, and the
  matching questions 3.4 and 3.5 ask of it.

  `Ainalrami.TeamPairing` asks one question constantly - *can these teams be
  paired among themselves without a rematch?* - for the bye (3.4.1), for
  every candidate upfloater set ([C1] for the bracket it forms, [C3] for the
  teams left below) and inside the [C6] look-ahead. Until 2026-09-16 every
  one of those questions built its own adjacency map over the teams in
  question, with a list-membership test per pair: quadratic work per
  question, thousands of questions per round on a 500-team field.

  ## What is built

  `new/1` numbers the round's teams once and keeps, per team, a bitmask of
  the teams it has NOT met. A question about a subset is then a mask, and
  `feasible?/2` answers it with a greedy pass over the masks (a success is a
  witness) and an exact maximum matching when greedy fails.

  ## Why no pairing can change

  Every function here answers a yes/no or a minimum that is a property of
  the teams and their histories - whether a perfect matching exists, or the
  least number of a certain kind of pair any perfect matching must contain.
  Which algorithm computes it cannot change it.

  One thing could: the engine's own adjacency was built from ONE team's side
  (`Team.met?(a, b)`), and a history in which `a` lists `b` but `b` does not
  list `a` would make the older answers depend on the order the teams were
  listed in. No event produces such a history - a match is between two
  teams - but a caller can. `new/1` returns nil for it (and for duplicate
  TPNs), and every caller then takes the older, order-dependent path exactly
  as before.
  """

  alias Ainalrami.TeamPairing.{Matching, Team}
  alias Ainalrami.WeightedMatching

  import Bitwise

  @type t :: %{index: %{integer() => non_neg_integer()}, allowed: tuple()} | nil

  @doc """
  The round's adjacency over `teams`, or nil when the fast paths may not be
  used: duplicate TPNs, or a history that is not symmetric (a team listing
  an opponent in the field that does not list it back).
  """
  def new(teams) do
    index = teams |> Enum.map(& &1.tpn) |> Enum.with_index() |> Map.new()

    if map_size(index) == length(teams) and symmetric?(teams, index) do
      full = (1 <<< length(teams)) - 1

      allowed =
        teams
        |> Enum.with_index()
        |> Enum.map(fn {team, i} ->
          met =
            Enum.reduce(team.opponents, 0, fn opp, acc ->
              case index do
                %{^opp => j} -> acc ||| 1 <<< j
                _ -> acc
              end
            end)

          full &&& bnot(met ||| 1 <<< i)
        end)
        |> List.to_tuple()

      %{index: index, allowed: allowed}
    end
  end

  defp symmetric?(teams, index) do
    by_tpn = Map.new(teams, &{&1.tpn, &1})

    Enum.all?(teams, fn team ->
      Enum.all?(team.opponents, fn opp ->
        not Map.has_key?(index, opp) or Team.met?(Map.fetch!(by_tpn, opp), team.tpn)
      end)
    end)
  end

  @doc """
  Whether `teams` can all be paired among themselves without a rematch.

  With a field: parity, then `Matching.greedy_cover?/2`, then an exact
  maximum matching. Without one (nil, or a team the field does not know):
  the adjacency built for these teams alone and `Matching.feasible?/2`, the
  path every question took before the field existed.
  """
  def feasible?(teams, nil), do: local_feasible?(teams)

  def feasible?(teams, field) do
    case mask(teams, field.index) do
      :error ->
        local_feasible?(teams)

      {_mask, n} when rem(n, 2) == 1 ->
        false

      {mask, n} ->
        Matching.greedy_cover?(mask, field.allowed) or perfect?(indices(mask), n, field)
    end
  end

  @doc """
  The least number of pairs joining a team of `first` to a team of `second`
  that any perfect matching of `first ++ second` must contain, or nil when
  there is no perfect matching at all. `first` and `second` are disjoint
  teams of `field`.

  This is the number both [C4] and the [C6] look-ahead are after. For a
  scoregroup `first` above the teams `second`, the fewest upfloaters that
  give a bracket pairable without a rematch AND leave everything below
  pairable is exactly it:

    * a legal set `S` of size `c` gives a perfect matching of the bracket
      and one of the rest; together they match `first ++ second` with at
      most `c` crossing pairs (fewer when two upfloaters meet);
    * a perfect matching with `x` crossing pairs gives the legal set made of
      the `second`-side ends of those pairs, of size `x`.

  So no size below it has a legal set, and it does. Computed as one
  maximum-weight matching - every edge weighs more than all the same-side
  bonuses together, so the heaviest matching is a maximum one first and has
  the most same-side pairs among those.
  """
  def min_cross(first, second, field) do
    case {mask(first, field.index), mask(second, field.index)} do
      {{first_mask, nf}, {second_mask, ns}} ->
        n = nf + ns
        order = indices(first_mask) ++ indices(second_mask)

        if rem(n, 2) == 1 do
          nil
        else
          base = n + 1

          mate =
            order
            |> edges(fn i, j -> base + if(i < nf == j < nf, do: 1, else: 0) end, field)
            |> solve(n)

          if map_size(mate) == n,
            do: Enum.count(mate, fn {i, j} -> i < j and i < nf != j < nf end)
        end

      _ ->
        :error
    end
  end

  # Exact. Up to sixteen teams, the memoised search over this subset alone -
  # it can see at most 2^16 masks, far under `Matching`'s memo cap, so it
  # always answers; above that, a maximum matching, perfect or not.
  defp perfect?(order, n, field) when n <= 16 do
    local = List.to_tuple(order)

    adj =
      Map.new(0..(n - 1)//1, fn i ->
        allowed = elem(field.allowed, elem(local, i))

        {i,
         Enum.reduce(0..(n - 1)//1, 0, fn j, mask ->
           if (allowed >>> elem(local, j) &&& 1) == 1, do: mask ||| 1 <<< j, else: mask
         end)}
      end)

    Matching.feasible?((1 <<< n) - 1, adj)
  end

  defp perfect?(order, n, field) do
    mate = order |> edges(fn _i, _j -> 1 end, field) |> solve(n)
    map_size(mate) == n
  end

  defp solve(_edges, n) when n <= 1, do: %{}
  defp solve(edges, n), do: WeightedMatching.solve(n, edges)

  # Local numbering 0..n-1 in `order`, one weighted edge per allowed pair.
  defp edges(order, weight, field) do
    local = List.to_tuple(order)
    n = tuple_size(local)

    Enum.flat_map(0..(n - 2)//1, fn i ->
      allowed = elem(field.allowed, elem(local, i))

      for j <- (i + 1)..(n - 1)//1, (allowed >>> elem(local, j) &&& 1) == 1 do
        {i, j, weight.(i, j)}
      end
    end)
  end

  defp mask(teams, index) do
    Enum.reduce_while(teams, {0, 0}, fn team, {mask, n} ->
      tpn = team.tpn

      case index do
        %{^tpn => i} -> {:cont, {mask ||| 1 <<< i, n + 1}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp indices(mask), do: indices(mask, 0, [])

  defp indices(0, _offset, acc), do: Enum.reverse(acc)

  defp indices(mask, offset, acc) do
    i = Matching.lowest_index(mask)
    indices(mask >>> (i + 1), offset + i + 1, [offset + i | acc])
  end

  # The adjacency for these teams alone, as each question built it before
  # the field existed: index i and j are adjacent when i has not met j.
  defp local_feasible?(teams) do
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

    Matching.feasible?((1 <<< length(teams)) - 1, adj)
  end
end
