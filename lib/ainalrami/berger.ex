defmodule Ainalrami.Berger do
  @moduledoc """
  The Berger tables of the FIDE Competition Rules (C.05, Annex 1): the
  round-robin schedule that a `BERGER_*ROUNDROBIN*` `192` code names.

  For an even number of participants `n` the table has `n - 1` rounds; an
  odd field is played as `n + 1` with a dummy, and whoever meets the dummy
  has the round free. Numbers are pairing numbers `1..n`.

  The construction is the classic one the printed tables follow: in round
  `r` (0-based) participant `n` (the highest, fixed) meets `f + 1` where
  `f = r * (n / 2) mod (n - 1)`, with White when `r` is odd; every other
  pair `{i + 1, j + 1}` has `i + j = r (mod n - 1)`, and the lower number
  has White when `j - i` is odd. It reproduces Annex 1 table for table -
  for four, `1-4 2-3 / 4-3 1-2 / 2-4 3-1`; for six,
  `1-6 2-5 3-4 / 6-4 5-3 1-2 / 2-6 3-1 4-5 / 6-5 1-4 2-3 / 3-6 4-2 5-1`
  (`test/ainalrami/berger_test.exs` holds the tables for four, six and
  eight).

  A schedule played `games` times (`BERGER_ROUNDROBIN_Gn`,
  `BERGER_TEAM_ROUNDROBIN_Gn`) repeats the table, colours reversed in every
  second cycle - the same construction OpenPairings uses
  (`PairingsEngine.RoundRobin.schedule/3`), which this module mirrors so
  that the standalone engine and the app agree on every round.
  """

  @doc """
  The pairing of round `round` (1-based, across every cycle) for `n`
  participants playing the table `games` times: `{:ok, pairs, free}` with
  `pairs` as `[{white, black}]` and `free` the participant
  meeting the dummy (nil for an even field), or `{:error,
  {:all_rounds_paired, total}}` past the last round.

  Option `:reverse_last_two?` - `FIDE_DOUBLEROUNDROBIN`'s construction in
  FIDE's Tournament Type Code Table: the first cycle with its last two
  rounds played in reverse order, then the second cycle (colours reversed,
  as in any repeated table) in table order.

  Option `:match_format?` - every game of a single table played twice in a
  row as a two-game match, colours reversed in the second: physical rounds
  `2k - 1` and `2k` are round `k` of the table, the second with every board
  turned round and the same participant free. OpenPairings' "match format"
  (`PairingsEngine.RoundRobin.match_schedule/2`), a different shape from
  `games: 2`, which repeats the table a whole cycle apart. `games` must be 1.
  """
  def round(n, games, round, opts \\ [])

  def round(n, games, round, opts) do
    if Keyword.get(opts, :match_format?, false) do
      match_round(n, games, round, Keyword.delete(opts, :match_format?))
    else
      plain_round(n, games, round, opts)
    end
  end

  defp match_round(n, 1, round, opts) when is_integer(n) and n >= 2 and is_integer(round) do
    total = total_rounds(n, 1, match_format?: true)

    if round > total do
      {:error, {:all_rounds_paired, total}}
    else
      {:ok, pairs, free} = plain_round(n, 1, div(round + 1, 2), opts)
      pairs = if rem(round, 2) == 0, do: Enum.map(pairs, fn {w, b} -> {b, w} end), else: pairs
      {:ok, pairs, free}
    end
  end

  defp match_round(_n, games, _round, _opts) do
    raise ArgumentError,
          "the match format plays a single table (games: 1), not #{inspect(games)}"
  end

  defp plain_round(n, games, round, opts)
       when is_integer(n) and n >= 2 and is_integer(games) and games >= 1 and
              is_integer(round) and round >= 1 do
    field = if rem(n, 2) == 0, do: n, else: n + 1
    dummy = if field == n, do: nil, else: field
    per_cycle = field - 1
    total = per_cycle * games

    if round > total do
      {:error, {:all_rounds_paired, total}}
    else
      cycle = div(round - 1, per_cycle)
      r = rem(round - 1, per_cycle)

      r =
        cond do
          not Keyword.get(opts, :reverse_last_two?, false) or cycle != 0 or per_cycle < 2 -> r
          r == per_cycle - 1 -> per_cycle - 2
          r == per_cycle - 2 -> per_cycle - 1
          true -> r
        end

      reverse? = rem(cycle, 2) == 1

      {pairs, free} =
        field
        |> table_round(r)
        |> Enum.map(fn {w, b} -> if reverse?, do: {b, w}, else: {w, b} end)
        |> Enum.reduce({[], nil}, fn
          {w, b}, {acc, _free} when w == dummy -> {acc, b}
          {w, b}, {acc, _free} when b == dummy -> {acc, w}
          pair, {acc, free} -> {[pair | acc], free}
        end)

      {:ok, Enum.reverse(pairs), free}
    end
  end

  @doc """
  How many rounds the table needs for `n` participants played `games`
  times - twice a single table's under `match_format?: true`.
  """
  def total_rounds(n, games, opts \\ [])

  def total_rounds(n, games, opts)
      when is_integer(n) and n >= 2 and is_integer(games) and games >= 1 do
    field = if rem(n, 2) == 0, do: n, else: n + 1
    per_table = (field - 1) * games
    if Keyword.get(opts, :match_format?, false), do: per_table * 2, else: per_table
  end

  # Round `r` (0-based) of the single table for an even `field`.
  defp table_round(field, r) do
    m = field - 1
    f = rem(r * div(field, 2), m)
    fixed = if rem(r, 2) == 1, do: {field, f + 1}, else: {f + 1, field}

    others =
      for i <- 0..(m - 1),
          i != f,
          j = Integer.mod(r - i, m),
          i < j do
        if rem(j - i, 2) == 1, do: {i + 1, j + 1}, else: {j + 1, i + 1}
      end

    [fixed | others]
  end
end
