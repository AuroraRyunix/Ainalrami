defmodule Ainalrami.MatchCertificateTest do
  @moduledoc """
  The certified shortcuts in `Ainalrami.Pairing` rest on three claims, each
  held here against brute force - every matching of a small graph
  enumerated, so "every maximum-weight matching" is a list, not an
  argument:

    * `MatchCertificate.certify/5` issues a certificate only for a
      maximum-weight matching, and a strict one only when every maximum
      agrees with it on the window;
    * `WeightedMatching.possible_partners/3` covers the partner (or the
      unmatched state) of every vertex in every maximum-weight matching,
      for every kind of state the engine reads - solved, shifted,
      installed;
    * a state built by `install/3` or `scale/2` is a valid starting point:
      searches resumed from it after arbitrary weight changes still reach a
      maximum.

  Graphs are drawn with few distinct weights (so that ties, which are the
  whole difficulty, are common) and with packed multi-digit weights like
  the engine's.
  """
  use ExUnit.Case, async: true

  alias Ainalrami.{MatchCertificate, WeightedMatching}

  # MATCH_CERT_SEEDS=20000 for a heavier run.
  @seeds 1..String.to_integer(System.get_env("MATCH_CERT_SEEDS", "500"))

  describe "certify/5" do
    test "certifies only maximum-weight matchings, and strictly only where every maximum agrees" do
      stats =
        Enum.reduce(@seeds, %{ok: 0, strict_ok: 0, refused: 0}, fn seed, stats ->
          {n, edges} = graph(seed)
          {state, m} = n |> new_state(edges) |> WeightedMatching.solve()
          {best, maxima} = maxima(n, edges)
          window = random_window(seed, n)
          window? = &MapSet.member?(window, &1)
          {fam_hint, family} = WeightedMatching.certificate_hint(state)

          candidates = [
            {m, WeightedMatching.vertex_duals(state), nil},
            {m, fam_hint, family},
            {other_matching(seed, n, edges), WeightedMatching.vertex_duals(state), nil}
          ]

          for {mate, hint, fam} <- candidates, strict <- [true, false], reduce: stats do
            stats ->
              case MatchCertificate.certify(state.weight, mate, window?, hint,
                     strict: strict,
                     family: fam
                   ) do
                {:ok, _cert} ->
                  assert weight_of(mate, edges) == best,
                         "seed #{seed}: certified a matching of weight #{weight_of(mate, edges)}, maximum #{best}"

                  if strict do
                    for other <- maxima, v <- window do
                      assert Map.get(other, v) == Map.get(mate, v),
                             "seed #{seed}: strict certificate, but a maximum gives #{v} " <>
                               "#{inspect(Map.get(other, v))} not #{inspect(Map.get(mate, v))}"
                    end
                  end

                  stats
                  |> Map.update!(:ok, &(&1 + 1))
                  |> Map.update!(:strict_ok, &(&1 + bit(strict)))

                {:error, _} ->
                  Map.update!(stats, :refused, &(&1 + 1))
              end
          end
        end)

      # The test must have exercised both outcomes, and strict ones.
      assert stats.ok > 300 and stats.strict_ok > 100 and stats.refused > 100, inspect(stats)
    end

    test "check/5 refuses duals that are off by one anywhere" do
      for seed <- @seeds do
        {n, edges} = graph(seed)
        {state, m} = n |> new_state(edges) |> WeightedMatching.solve()

        case MatchCertificate.certify(
               state.weight,
               m,
               fn _ -> false end,
               WeightedMatching.vertex_duals(state),
               strict: false
             ) do
          {:ok, cert} ->
            assert {:ok, _} =
                     MatchCertificate.check(state.weight, m, fn _ -> false end, cert.dual)

            # Lowering any matched vertex's dual breaks a matched edge's
            # tightness, which the check must see.
            case Enum.find(Map.keys(m), &is_integer/1) do
              nil ->
                :ok

              v ->
                broken = Map.update!(cert.dual, v, &(&1 - 1))

                assert {:error, _} =
                         MatchCertificate.check(state.weight, m, fn _ -> false end, broken)
            end

          _ ->
            :ok
        end
      end
    end
  end

  describe "possible_partners/3" do
    test "covers every maximum's partner on solved, installed and shifted states" do
      Enum.each(@seeds, fn seed ->
        {n, edges} = graph(seed)
        {state, m} = n |> new_state(edges) |> WeightedMatching.solve()
        {_best, maxima} = maxima(n, edges)
        assert_covers(state, maxima, "seed #{seed} solved")

        # A state installed from a certificate.
        case MatchCertificate.certify(
               state.weight,
               m,
               fn _ -> false end,
               WeightedMatching.vertex_duals(state),
               strict: false
             ) do
          {:ok, cert} ->
            installed = WeightedMatching.install(state, m, cert.dual)
            assert_covers(installed, maxima, "seed #{seed} installed")

          _ ->
            :ok
        end

        # After a random weight change and a resumed search.
        {u, v, w} = Enum.at(edges, rem(seed, max(length(edges), 1))) || {0, 1, 1}

        if n >= 2 and u != v do
          changed = WeightedMatching.set_weight(state, u, v, w + rem(seed, 5) + 1)
          {changed, _} = WeightedMatching.solve(changed)
          edges2 = replace_edge(edges, u, v, w + rem(seed, 5) + 1)
          {_best2, maxima2} = maxima(n, edges2)
          assert_covers(changed, maxima2, "seed #{seed} resumed")
        end
      end)
    end
  end

  describe "install/3 and scale/2" do
    test "searches resumed from an installed or a scaled state reach a maximum after further changes" do
      Enum.each(@seeds, fn seed ->
        {n, edges} = graph(seed)
        {state, m} = n |> new_state(edges) |> WeightedMatching.solve()

        starts =
          case MatchCertificate.certify(
                 state.weight,
                 m,
                 fn _ -> false end,
                 WeightedMatching.vertex_duals(state),
                 strict: false
               ) do
            {:ok, cert} ->
              [
                {1, WeightedMatching.install(state, m, cert.dual)},
                {3, WeightedMatching.scale(state, 3)}
              ]

            _ ->
              [{3, WeightedMatching.scale(state, 3)}]
          end

        :rand.seed(:exsss, {seed, 5, 11})

        for {k, start} <- starts do
          # A few random weight changes on the scaled graph, then a search.
          {changed, edges2} =
            Enum.reduce(1..3, {start, Enum.map(edges, fn {a, b, w} -> {a, b, k * w} end)}, fn _,
                                                                                              {st,
                                                                                               es} ->
              case es do
                [] ->
                  {st, es}

                _ ->
                  {a, b, _} = Enum.random(es)
                  w = Enum.random(1..(6 * k))
                  {WeightedMatching.set_weight(st, a, b, w), replace_edge(es, a, b, w)}
              end
            end)

          {_, got} = WeightedMatching.solve(changed)
          {best, _} = maxima(n, edges2)
          assert weight_of(got, edges2) == best, "seed #{seed} k=#{k}: resumed to a non-maximum"
        end
      end)
    end
  end

  # ------------------------------------------------------------------ helpers

  # As the engine builds its matchers: no weight reduction, a ceiling far
  # above anything a test writes.
  defp new_state(n, edges), do: WeightedMatching.new(n, edges, gcd: 1, max_weight: 1_000_000_000)

  defp assert_covers(state, maxima, label) do
    ctx = WeightedMatching.dual_context(state)
    assert ctx != :invalid, "#{label}: dual context refused"

    for v <- 0..(state.n - 1), map_size(Map.get(state.weight, v, %{})) > 0 do
      {tight, exposable?} = WeightedMatching.possible_partners(state, ctx, v)

      for other <- maxima do
        case Map.get(other, v) do
          nil ->
            assert exposable?, "#{label}: a maximum leaves #{v} unmatched, not allowed for"

          u ->
            assert u in tight,
                   "#{label}: a maximum pairs #{v} with #{u}, not among #{inspect(tight)}"
        end
      end
    end
  end

  # A small graph: few distinct weights, sometimes packed into digits the
  # way the engine packs its criteria (a high digit, a middle one, and a
  # low "nearness" term).
  defp graph(seed) do
    :rand.seed(:exsss, {seed, 17, 23})
    n = Enum.random(3..9)
    p = Enum.random([0.45, 0.65, 0.85])
    packed? = rem(seed, 3) == 0

    edges =
      for a <- 0..(n - 1), b <- 0..(n - 1), a < b, :rand.uniform() < p do
        w =
          if packed? do
            Enum.random(1..2) * 10_000 + Enum.random(0..2) * 100 + (n - abs(b - a))
          else
            Enum.random(1..4)
          end

        {a, b, w}
      end

    {n, edges}
  end

  defp random_window(seed, n) do
    :rand.seed(:exsss, {seed, 3, 5})
    for v <- 0..(n - 1), :rand.uniform() < 0.6, into: MapSet.new(), do: v
  end

  # A maximal matching built greedily in a random order - usually not a
  # maximum-weight one.
  defp other_matching(seed, n, edges) do
    :rand.seed(:exsss, {seed, 7, 9})

    edges
    |> Enum.shuffle()
    |> Enum.reduce(%{}, fn {a, b, _}, acc ->
      if is_map_key(acc, a) or is_map_key(acc, b) or a >= n or b >= n,
        do: acc,
        else: acc |> Map.put(a, b) |> Map.put(b, a)
    end)
  end

  # The edge list after `set_weight(u, v, w)`: the edge's weight replaced,
  # or the edge added when it was not there.
  defp replace_edge(edges, u, v, w) do
    {a, b} = {min(u, v), max(u, v)}

    if Enum.any?(edges, fn {x, y, _} -> {x, y} == {a, b} end),
      do:
        Enum.map(edges, fn {x, y, ow} -> if {x, y} == {a, b}, do: {x, y, w}, else: {x, y, ow} end),
      else: [{a, b, w} | edges]
  end

  defp weight_of(mate, edges) do
    lookup = Map.new(edges, fn {a, b, w} -> {{a, b}, w} end)

    Enum.reduce(mate, 0, fn {u, v}, acc ->
      if u < v, do: acc + Map.get(lookup, {u, v}, 0), else: acc
    end)
  end

  # Every maximum-weight matching (edges of weight <= 0 are not edges), by
  # enumerating every matching.
  defp maxima(n, edges) do
    adj =
      Enum.reduce(edges, %{}, fn {a, b, w}, acc ->
        if w > 0 do
          acc
          |> Map.update(a, [{b, w}], &[{b, w} | &1])
          |> Map.update(b, [{a, w}], &[{a, w} | &1])
        else
          acc
        end
      end)

    all = enumerate(0, n, adj, MapSet.new(), %{}, 0, [])
    best = all |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)
    {best, for({m, w} <- all, w == best, do: m)}
  end

  defp enumerate(i, n, _adj, _used, mate, w, acc) when i >= n, do: [{mate, w} | acc]

  defp enumerate(i, n, adj, used, mate, w, acc) do
    if MapSet.member?(used, i) do
      enumerate(i + 1, n, adj, used, mate, w, acc)
    else
      acc = enumerate(i + 1, n, adj, MapSet.put(used, i), mate, w, acc)

      adj
      |> Map.get(i, [])
      |> Enum.reduce(acc, fn {j, wj}, acc ->
        if j > i and not MapSet.member?(used, j) do
          enumerate(
            i + 1,
            n,
            adj,
            used |> MapSet.put(i) |> MapSet.put(j),
            mate |> Map.put(i, j) |> Map.put(j, i),
            w + wj,
            acc
          )
        else
          acc
        end
      end)
    end
  end

  defp bit(true), do: 1
  defp bit(false), do: 0
end
