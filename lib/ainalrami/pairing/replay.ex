defmodule Ainalrami.Pairing.Replay do
  @moduledoc false
  # A forced search re-played from the round it is a variation of.
  #
  # `Ainalrami.Alternatives` answers "what if this player had floated / had
  # the bye" by pairing the round again with a few pairs forbidden - the
  # FORCING, a star of pairs around one or two players. Every such search is
  # the round the caller already has, with a handful of edges taken out of
  # the graph, and most of its work is the same work: the same brackets over
  # the same players, the same whole-field matching, only a few edges
  # short. This module lets `Ainalrami.Pairing` do that work once - in a
  # RECORDING of the unforced round - and have each forced search take it
  # from there, while answering exactly what the full re-pairing answers.
  #
  # Two things are taken from the recording, on two different arguments.
  #
  # ## A local bracket: the same computation
  #
  # A bracket paired on its own graph (`Pairing.attempt_local/7`) is a pure
  # function of the players in the round's remaining field, the bracket's
  # bounds and C9 flag, the round's context, and which pairs among the
  # bracket and the next score group are legal. When the forced search
  # reaches a bracket whose field, bounds and flag are the recording's and
  # no forced pair lies inside that window, it is literally the same call
  # on the same arguments, and its result is the recorded one. The oracle
  # question that follows it (`oracle_completable?/2`) is still asked of the
  # forced search's own oracle.
  #
  # ## A field bracket: another optimum, and a certificate
  #
  # The round matcher is built once per run of field brackets, over the
  # whole remaining field, and solved from cold - most of a large round's
  # time. When the forced search builds it for a bracket the recording
  # built it for, the graph is the recording's minus the forced pairs, and
  # the recording's solved state is a good start: take those edges out and
  # re-optimise, a few augmentations instead of a cold solve. (With no
  # forced pair in the graph the recorded state IS what the cold build
  # would give - the same call on the same arguments - and it is used as
  # it is.)
  #
  # The re-optimised matcher holds AN optimum, which need not be the one
  # the cold solve would have reached: the matcher breaks ties by the order
  # it meets edges in. So from then until the round matcher is next built
  # from cold, every read the bracket makes of its matching is CERTIFIED to
  # come out the same in every optimum of the weights it was solved for -
  # and then the cold search, which holds some optimum of the same weights,
  # read the same value. A read that cannot be certified throws, and the
  # caller runs the full re-pairing instead.
  #
  # ## What is read, and how it is certified
  #
  # A read is a predicate of a vertex's partner (`Pairing.read/4`): inside
  # the bracket or not, paired downward or not, the partner itself where a
  # pair is finalised, the partner's score for the next bracket's C9 gate.
  # Two tests certify it, the second only where the first cannot:
  #
  #   * the DUAL: the matcher's dual solution is an optimality certificate,
  #     and complementary slackness holds between it and every optimum, so
  #     every optimum matches a vertex along an edge of reduced cost zero -
  #     and inside a blossom with a positive dual, in one of the few ways a
  #     full blossom allows (`WeightedMatching.possible_mates/2`). If the
  #     predicate is the same for every such partner, it is the same in
  #     every optimum;
  #   * a RE-OPTIMISATION: take away every edge of the vertex that gives the
  #     read value and solve again. Every matching that reads differently is
  #     still there; if the best of them is worth less than the optimum, no
  #     optimum reads differently.
  #
  # Two reads are COUNTS whose members may differ between optima while the
  # count does not - the remainder's pairs, and the higher half's
  # exchanges - and are left uncertified member by member on the argument
  # `Pairing.stage_build_remainder/1` and `Pairing.count_exchanges/1` give.
  #
  # ## The same weights, read at the same points
  #
  # By induction over the stages. Every read that decides a route, a write
  # or a result is certified, so the forced search takes the same route as
  # the cold one, solves at the same points and writes the same weights -
  # every weight the stages write is a function of the base weights and of
  # those reads. What depends on the matcher's own state are the choices
  # between a dual shift and a re-solve (`shift_and_set/3` succeeding or
  # refusing) and between finalising a pair by edge removal or by rewrite:
  # each ends in an optimum of the same weights, and a finalised pair is
  # isolated either way, whatever its own edge weighs. (A round matcher
  # started from the recording also has the recording's pinned
  # finalisation weight and no far edges in `live`, which nothing reads.)
  #
  # A read is certified against the matcher its matching came from: as the
  # last solve left it - less, after a pair is finalised by edge removal,
  # the removed edges, which every run's matching avoids since it holds the
  # pair - and after stage 8's dual shift, the shifted matcher: a cold
  # search there either shifted too or re-solved, and holds an optimum of
  # the shifted weights either way. Stage 7's shift is NOT a point of
  # certification: a cold search whose shift was refused reads the stage-6
  # matching until its next solve.
  #
  # Everything else a forced search does - the bye bootstrap, the oracle,
  # the completion check and repair, the brackets whose windows hold a
  # forced pair - it does itself, exactly as the full re-pairing does; a
  # round whose context (field, bye score, C9 flag) the forcing changed
  # takes nothing from the recording at all.

  alias Ainalrami.WeightedMatching

  @key :ainalrami_replay
  @exact_key :ainalrami_replay_exact
  @cert_key :ainalrami_replay_cert
  @cache_key :ainalrami_replay_cache
  @fallback :ainalrami_replay_fallback

  ## ------------------------------------------------------------ lifecycle

  def start_recording do
    Process.put(@key, %{mode: :record, ctx: nil, local: %{}, field: %{}})
  end

  # The recording, or nil when it has nothing a forced search could use
  # (the round went to `pair_round_one/1`, or failed).
  def finish_recording do
    rec = Process.get(@key)
    stop()

    case rec do
      %{mode: :record, ctx: ctx} = rec when ctx != nil -> Map.delete(rec, :mode)
      _ -> nil
    end
  end

  def start_replay(rec, forced_groups) do
    Process.put(@key, %{
      mode: :replay,
      rec: rec,
      forced: forced_map(forced_groups),
      local_hits: 0,
      field_starts: []
    })

    Process.put(@exact_key, true)
  end

  # What the replay did, for measurement: how many local brackets were taken
  # from the recording, and how each round-matcher build started.
  def replay_info do
    case Process.get(@key) do
      %{mode: mode} = r when mode in [:replay, :off] ->
        %{
          local_hits: r.local_hits,
          field_starts: Enum.reverse(r.field_starts),
          mode: mode,
          dual_reads: Map.get(r, :dual_reads, 0),
          resolved_reads: Map.get(r, :resolved_reads, 0),
          resolved_ms: div(Map.get(r, :resolved_us, 0), 1000),
          by_kind: for({{k, w, l}, n} <- r, k in [:dual, :resolved], do: {k, w, l, n})
        }

      _ ->
        nil
    end
  end

  def stop do
    Process.delete(@key)
    Process.delete(@exact_key)
    Process.delete(@cert_key)
    Process.delete(@cache_key)
  end

  def fallback_tag, do: @fallback

  defp forced_map(groups) do
    Enum.reduce(groups, %{}, fn group, acc ->
      members = MapSet.new(group)

      Enum.reduce(group, acc, fn r, acc ->
        Map.update(
          acc,
          r,
          MapSet.delete(members, r),
          &MapSet.union(&1, MapSet.delete(members, r))
        )
      end)
    end)
  end

  ## ------------------------------------------------------ round context

  # The round's context (`Pairing.global_context/1`): the field, its order,
  # the bye score and the first bracket's C9 flag. A forced search whose
  # context differs from the recording's - the forcing moved the bye score -
  # shares nothing with it and runs as the full re-pairing does.
  def round_context(ctx) do
    case Process.get(@key) do
      %{mode: :record} = r ->
        Process.put(@key, %{r | ctx: ctx})

      %{mode: :replay, rec: %{ctx: recorded}} = r ->
        if recorded != ctx, do: Process.put(@key, %{r | mode: :off})

      _ ->
        :ok
    end

    :ok
  end

  ## ------------------------------------------------------- local brackets

  # `compute` is the local bracket's own computation; `key` its arguments
  # (the remaining field's ranks, the bracket bounds, the C9 flag) and
  # `window` the ranks whose legality it reads.
  def local(key, window, compute) do
    case Process.get(@key) do
      %{mode: :record} = r ->
        value = compute.()
        Process.put(@key, %{r | local: Map.put(r.local, key, value)})
        value

      %{mode: :replay, rec: rec, forced: forced} = r ->
        case Map.fetch(rec.local, key) do
          {:ok, value} ->
            if forced_inside?(forced, window) do
              compute.()
            else
              Process.put(@key, %{r | local_hits: r.local_hits + 1})
              value
            end

          :error ->
            compute.()
        end

      _ ->
        compute.()
    end
  end

  ## ------------------------------------------------------ field brackets

  # What the recording has for a round matcher built for this bracket, or
  # nil: `%{max_w: pinned}`, the bracket's pinned finalisation weight.
  def recorded_start(key) do
    case Process.get(@key) do
      %{mode: :replay, rec: %{field: field}} ->
        case Map.fetch(field, key) do
          {:ok, {_matcher, _matching, max_w}} -> %{max_w: max_w}
          :error -> nil
        end

      _ ->
        nil
    end
  end

  # The start of a round matcher. `build` makes it from cold, as the full
  # re-pairing does. Returns `{:solved, matcher, matching}` or `{:unsolved,
  # matcher}` for the caller to solve.
  def field_start(key, ranks, field_index, build) do
    case Process.get(@key) do
      %{mode: :replay, rec: rec, forced: forced} = r ->
        case Map.fetch(rec.field, key) do
          {:ok, {matcher, matching, _max_w}} ->
            drop =
              for {a, b} <- forced_pairs(forced, ranks),
                  fa = Map.fetch!(field_index, a),
                  fb = Map.fetch!(field_index, b),
                  WeightedMatching.edge_weight(matcher, fa, fb) > 0,
                  do: {fa, fb}

            if drop == [] do
              # The cold build's own arguments: its own result.
              Process.put(@key, %{r | field_starts: [:same | r.field_starts]})
              Process.put(@exact_key, true)
              {:solved, matcher, matching}
            else
              Process.put(@key, %{r | field_starts: [:warm | r.field_starts]})
              Process.put(@exact_key, false)

              {:unsolved,
               Enum.reduce(drop, matcher, fn {fa, fb}, acc ->
                 WeightedMatching.set_weight(acc, fa, fb, 0)
               end)}
            end

          :error ->
            Process.put(@key, %{r | field_starts: [:cold | r.field_starts]})
            Process.put(@exact_key, true)
            {:unsolved, build.()}
        end

      _ ->
        {:unsolved, build.()}
    end
  end

  # After every solve of the round matcher. `start_key` is the bracket key
  # when this solve was the one that built it, else nil.
  def field_solved(start_key, matcher, matching, max_w) do
    case Process.get(@key) do
      %{mode: :record} = r when start_key != nil ->
        Process.put(@key, %{r | field: Map.put(r.field, start_key, {matcher, matching, max_w})})

      %{mode: :replay} ->
        certify_against(matcher)

      _ ->
        :ok
    end

    :ok
  end

  # A pair finalised by edge removal, or stage 8's dual shift: reads from
  # here on are certified against this matcher (see the moduledoc).
  def field_changed(matcher) do
    case Process.get(@key) do
      %{mode: :replay} -> certify_against(matcher)
      _ -> :ok
    end

    :ok
  end

  defp certify_against(matcher) do
    unless Process.get(@exact_key, true) do
      {version, _} = Process.get(@cert_key, {0, nil})
      Process.put(@cert_key, {version + 1, matcher})
    end
  end

  ## ------------------------------------------------------ certification

  # The bracket just read `value = of_partner.(p)` of `i`'s partner `p`
  # (bracket-local, `i` itself when exposed) off the field graph: is it the
  # value every optimum gives? `what` names the read, for the cache - the
  # same read of the same vertex against the same matcher is answered once.
  def certify(%{mode: :field} = st, i, what, value, of_partner) do
    case Process.get(@key) do
      %{mode: :replay} ->
        if Process.get(@exact_key, true),
          do: :ok,
          else: certify_read(st, i, what, value, of_partner)

      _ ->
        :ok
    end
  end

  def certify(_st, _i, _what, _value, _of_partner), do: :ok

  defp certify_read(st, i, what, value, of_partner) do
    {version, matcher} = Process.get(@cert_key)

    {from, done} =
      case Process.get(@cache_key) do
        {^version, pos, from, done} when pos == st.field_pos ->
          {from, done}

        _ ->
          {st.field_pos |> Tuple.to_list() |> Enum.with_index() |> Map.new(), %{}}
      end

    case Map.fetch(done, {i, what}) do
      {:ok, ^value} ->
        :ok

      _ ->
        fi = elem(st.field_pos, i)

        verdict =
          case WeightedMatching.possible_mates(matcher, fi) do
            :invalid ->
              :invalid

            {mates, exposable?} ->
              Enum.all?(mates, fn fu ->
                case Map.fetch(from, fu) do
                  {:ok, q} -> of_partner.(q) == value
                  :error -> false
                end
              end) and (not exposable? or of_partner.(i) == value)
          end

        verdict =
          if verdict == false do
            count(:resolved_reads)
            count({:resolved, what, st.nsgb == st.m})
            {us, v} = :timer.tc(fn -> only_value?(matcher, fi, from, of_partner, value) end)
            add(:resolved_us, us)
            v
          else
            count(:dual_reads)
            count({:dual, what, st.nsgb == st.m})
            verdict
          end

        if verdict == true do
          Process.put(@cache_key, {version, st.field_pos, from, Map.put(done, {i, what}, value)})
          :ok
        else
          throw({@fallback, {:read, what, debug_detail(st, i, value, matcher, from)}})
        end
    end
  end

  # The second test, for a read the dual alone cannot settle: take away
  # every edge that would give the same value and re-optimise. Every
  # matching in which the read comes out differently is still there, so if
  # the best of them falls short of the optimum, no optimum reads
  # differently. (If the value is also what an exposed vertex reads, the
  # re-optimised matching may simply leave it exposed - then the totals
  # tie and the test fails, which is the safe direction.)
  defp only_value?(matcher, fi, from, of_partner, value) do
    same =
      Enum.reduce_while(WeightedMatching.neighbours(matcher, fi), [], fn {fu, _w}, acc ->
        case Map.fetch(from, fu) do
          {:ok, q} -> {:cont, if(of_partner.(q) == value, do: [fu | acc], else: acc)}
          :error -> {:halt, :outside}
        end
      end)

    case same do
      :outside ->
        false

      [] ->
        false

      same ->
        without = Enum.reduce(same, matcher, &WeightedMatching.set_weight(&2, fi, &1, 0))
        {without, best} = WeightedMatching.solve(without)
        total(without, best) < total(matcher, matcher.mate)
    end
  end

  defp add(what, n) do
    case Process.get(@key) do
      %{mode: :replay} = r -> Process.put(@key, Map.put(r, what, Map.get(r, what, 0) + n))
      _ -> :ok
    end
  end

  defp count(what) do
    case Process.get(@key) do
      %{mode: :replay} = r -> Process.put(@key, Map.put(r, what, Map.get(r, what, 0) + 1))
      _ -> :ok
    end
  end

  defp total(state, matching) do
    Enum.reduce(matching, 0, fn {a, b}, acc ->
      if a < b, do: acc + WeightedMatching.edge_weight(state, a, b), else: acc
    end)
  end

  defp debug_detail(st, i, value, matcher, from) do
    if System.get_env("AINALRAMI_REPLAY_DEBUG") do
      fi = elem(st.field_pos, i)

      %{
        i: i,
        value: value,
        partner: Map.get(st.matching, i, i),
        sgb: st.sgb,
        nsgb: st.nsgb,
        wsgb: st.wsgb,
        m: st.m,
        mates:
          case WeightedMatching.possible_mates(matcher, fi) do
            :invalid ->
              :invalid

            {mates, exposable?} ->
              # The best total with `i` held to each candidate in turn: equal
              # totals are a genuine tie, unequal ones a weak certificate.
              totals =
                for fu <- mates do
                  forced =
                    matcher
                    |> WeightedMatching.neighbours(fi)
                    |> Enum.reject(fn {x, _} -> x == fu end)
                    |> Enum.reduce(matcher, fn {x, _}, acc ->
                      WeightedMatching.set_weight(acc, fi, x, 0)
                    end)

                  {_s, m} = WeightedMatching.solve(forced)

                  total =
                    m
                    |> Enum.filter(fn {a, b} -> a < b end)
                    |> Enum.map(fn {a, b} -> WeightedMatching.edge_weight(forced, a, b) end)
                    |> Enum.sum()

                  {Map.get(from, fu), Map.get(m, fi) == fu, total}
                end

              base = totals |> Enum.map(&elem(&1, 2)) |> Enum.max()

              {Enum.map(mates, &Map.get(from, &1)), exposable?,
               Enum.map(totals, fn {q, ok, t} -> {q, ok, t - base} end)}
          end,
        blossom:
          Map.get(matcher.in_blossom, fi)
          |> then(&{Map.get(matcher.dual, &1), Map.get(matcher.children, &1)}),
        in_blossom: Map.get(matcher.in_blossom, fi) != fi
      }
    end
  end

  ## ------------------------------------------------------------ forcing

  defp forced_inside?(forced, ranks) when map_size(forced) == 0 or ranks == [], do: false

  defp forced_inside?(forced, ranks) do
    set = MapSet.new(ranks)

    Enum.any?(ranks, fn r ->
      case Map.get(forced, r) do
        nil -> false
        partners -> Enum.any?(partners, &MapSet.member?(set, &1))
      end
    end)
  end

  # Each forced pair among `ranks` once, as `{centre, other}`: the end with
  # more forced partners first. `set_weight/4` prepares its first vertex
  # only, so taking a star of edges out prepares its centre alone, not
  # every player around it.
  defp forced_pairs(forced, ranks) do
    set = MapSet.new(ranks)
    degree = fn r -> MapSet.size(Map.get(forced, r, MapSet.new())) end

    for r <- ranks,
        partners = Map.get(forced, r),
        partners != nil,
        q <- partners,
        r < q,
        MapSet.member?(set, q) do
      if degree.(q) > degree.(r), do: {q, r}, else: {r, q}
    end
  end
end
