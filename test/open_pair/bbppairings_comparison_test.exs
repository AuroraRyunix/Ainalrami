defmodule OpenPair.BbppairingsComparisonTest do
  @moduledoc """
  Cross-checks `OpenPair.Pairing.pair_next_round/1` against the real
  `bbpPairings.exe` (Bierema Boyz Programming's independent, Apache-2.0
  Dutch-system implementation) over a whole tournament, every round —
  the second reference this project has always meant to check against
  (see TODO.md's "Cross-validation against bbpPairings"), distinct from
  the earlier use of its SOURCE to port `OpenPair.WeightedMatching`. That
  was a code-fidelity check; this is a pairing-output comparison, on a
  binary OpenPair has never actually run against before.

  Deliberately the SAME methodology as `OpenPair.JavafoComparisonTest`
  (see that module's moduledoc for the full reasoning): play a
  tournament forward one round at a time, ask both engines to pair the
  identical history, diff, then advance on the REFERENCE engine's own
  answer (bbpPairings', here) so a disagreement in one round can't
  corrupt the measurement of the rounds after it.

  ## The one real behavioural difference from the javafo harness

  javafo signals "no legal pairing left" by writing an EMPTY pairs file
  and exiting 0. bbpPairings signals the identical situation with exit
  code 1 and no output file at all (its own documented error code 1:
  "no valid pairing exists for the current round") — see
  `OpenPair.Test.Bbppairings`'s moduledoc. Handled the same way either
  way: the tournament ends early and the round is excluded from the
  rates, not counted as a disagreement.

  A disagreement here is a research question, not an automatic verdict —
  bbpPairings and javafo don't always agree with each other either (both
  are independent readings of the same rulebook). Treat it as "which
  one, if either, matches the current Handbook text", the same standard
  `OpenPair.JavafoComparisonTest` already uses.

  ## Running it

      PAIRING_FUZZ_COUNT=500 PAIRING_FUZZ_ROUNDS=9 mix test --only bbppairings

  Same tunables as the javafo harness: `PAIRING_FUZZ_COUNT`,
  `PAIRING_FUZZ_ROUNDS`, `PAIRING_FUZZ_MIN_PLAYERS`/`_MAX_PLAYERS`,
  `PAIRING_FUZZ_BYE_PCT`, `PAIRING_FUZZ_FORFEIT_PCT`, `PAIRING_FUZZ_DUMP`.

  **Vary `PAIRING_FUZZ_ROUNDS`, and run an EVEN value.** Every axis measured
  on this project until 2026-08-17 used `ROUNDS=9`, whose final round is
  paired with 8 rounds played. `final_round_topscorers?/2` compares against
  half the played-round count, so a threshold that floors that half is
  identical to an exact one whenever the count is even — the bug lived
  through 2.5 million tournaments because every one of them held this
  parameter at the same odd value. At `ROUNDS=8` it surfaced in 2,000.
  Six-, eight- and ten-round Swisses are ordinary events.

  The general lesson, worth applying to any new axis: ask what the existing
  axes hold CONSTANT, not what they vary. Corpus size bought nothing here.

  `PAIRING_FUZZ_SEED_FROM` (default 1) moves where the seed range starts,
  so a dumped case can be reproduced on its own:

      PAIRING_FUZZ_SEED_FROM=735265 PAIRING_FUZZ_COUNT=1 \\
        PAIRING_FUZZ_MAX_PLAYERS=10 PAIRING_FUZZ_BYE_PCT=15 \\
        PAIRING_FUZZ_ROUNDS=9 mix test --only bbppairings

  Every seed is independent (`run_tournament!/3` reseeds `:rand` from it
  alone), so seed *n* generates the same tournament whether it is reached
  first or 735,264 tournaments in. Without this, revisiting one dumped
  disagreement meant re-running everything before it — which is why the
  cases catalogued in TODO.md were adjudicated once, from dumps, and never
  re-checked when the adjudicator itself changed. The seed, round and
  player count in a dump's filename are all that is needed; the rest of the
  configuration has to match what produced it.

  Two more cover the `XX` extension lines, and they work because
  bbpPairings implements both — the same file is handed to both engines, so
  the oracle validates them exactly as it validates every other axis:

    * `PAIRING_FUZZ_FORBIDDEN_PCT` — percentage of players given one
      arbiter-forbidden opponent, emitted as `XXP`.
    * `PAIRING_FUZZ_ACCEL` — `baku` or `random`, emitted as `XXA`.

  Both are fixed per TOURNAMENT, not per round: an exclusion and an
  acceleration record are properties of the event, and `XXA` in particular
  is only meaningful as a full round-by-round history (JaVaFo's manual is
  explicit that the record is what the float history is derived from).
  """

  use ExUnit.Case
  alias OpenPair.{Pairing, Test.Bbppairings}

  @moduletag :bbppairings
  @moduletag timeout: :infinity

  test "OpenPair and bbpPairings.exe agree on who plays whom, in every round of a tournament" do
    count = env_int("PAIRING_FUZZ_COUNT", 20)
    rounds = env_int("PAIRING_FUZZ_ROUNDS", 2)
    players = env_int("PAIRING_FUZZ_MIN_PLAYERS", 4)..env_int("PAIRING_FUZZ_MAX_PLAYERS", 40)
    seed_from = env_int("PAIRING_FUZZ_SEED_FROM", 1)

    measurements =
      seed_from..(seed_from + count - 1)
      |> Task.async_stream(&run_tournament(&1, rounds, players),
        max_concurrency: System.schedulers_online(),
        timeout: :infinity,
        ordered: false
      )
      |> Enum.flat_map(fn {:ok, rounds_played} -> rounds_played end)

    {errors, rest} = Enum.split_with(measurements, & &1.process_error?)
    {exhausted, comparisons} = Enum.split_with(rest, & &1.exhausted?)
    mismatches = Enum.reject(comparisons, & &1.match?)

    report(comparisons, errors, exhausted, rounds)
    dump(mismatches)

    assert mismatches == [], """
    #{length(mismatches)} disagreement(s) across #{length(comparisons)} compared round(s) \
    of #{count} tournament(s) — a legal-but-different pairing, or a genuine gap in OpenPair's \
    bracket cascade, not necessarily a bug in the sense that bbpPairings is "right" and \
    OpenPair is "wrong". Each needs its own look against the Handbook text.

    #{length(errors)} bbpPairings process error(s) are counted separately and are NOT included \
    above; a nonzero count there means the run was resource-starved and its rate is not \
    trustworthy.

    #{Enum.map_join(Enum.take(mismatches, 20), "\n\n", &format_mismatch/1)}
    #{if length(mismatches) > 20, do: "\n... and #{length(mismatches) - 20} more, truncated.", else: ""}
    """
  end

  defp run_tournament(seed, rounds, player_range) do
    run_tournament!(seed, rounds, player_range)
  rescue
    e ->
      [
        %{
          seed: seed,
          round: nil,
          player_count: nil,
          process_error?: false,
          exhausted?: false,
          match?: false,
          openpair: {:raised, e},
          bbppairings: nil,
          trf: "",
          illegal: :raised,
          pairs_matched: 0,
          pairs_total: 0
        }
      ]
  end

  defp run_tournament!(seed, rounds, player_range) do
    :rand.seed(:exsss, {seed, seed * 7919, seed * 104_729})
    player_count = Enum.random(player_range)
    forbidden = forbidden_pairs(player_count)
    roster = player_count |> initial_roster() |> accelerate(rounds)

    {measurements, _final} =
      Enum.reduce_while(1..rounds, {[], roster}, fn round, {acc, players} ->
        case play_round(players, seed, round, rounds, player_count, forbidden) do
          {:ok, measurement, next_players} -> {:cont, {[measurement | acc], next_players}}
          {:error, measurement} -> {:halt, {[measurement | acc], players}}
        end
      end)

    Enum.reverse(measurements)
  end

  defp initial_roster(player_count) do
    for i <- 1..player_count do
      %{rank: i, name: "P#{i}", fide_rating: Enum.random(1000..2800), points: 0.0, games: []}
    end
    |> Enum.shuffle()
    |> Enum.with_index(1)
    |> Enum.map(fn {p, i} -> %{p | rank: i} end)
  end

  # One forbidden opponent for each selected player, as a two-id `XXP`
  # group. Chosen once for the whole tournament and deliberately allowed to
  # over-constrain the field — bbpPairings answers an impossible round with
  # its own no-valid-pairing exit, which the harness already treats as "the
  # tournament ends here", so an unpairable draw is measured rather than
  # avoided.
  defp forbidden_pairs(player_count) do
    pct = env_int("PAIRING_FUZZ_FORBIDDEN_PCT", 0)

    if pct == 0 or player_count < 2 do
      []
    else
      for rank <- 1..player_count, :rand.uniform(100) <= pct do
        Enum.sort([rank, Enum.random(Enum.reject(1..player_count, &(&1 == rank)))])
      end
      |> Enum.uniq()
    end
  end

  # `XXA` virtual points, stamped onto the roster once and carried by every
  # round's TRF unchanged — the full round-by-round record JaVaFo's manual
  # requires, and the same list `OpenPair.Trf.parse/1` hands the engine.
  # `:baku` is FIDE C.04.7; `:random` exists because Baku alone only ever
  # produces two distinct acceleration values in one flat block, which
  # exercises far less of the bracket machinery than arbitrary per-player
  # histories do.
  defp accelerate(players, rounds) do
    case System.get_env("PAIRING_FUZZ_ACCEL") do
      nil -> players
      "baku" -> baku(players, rounds)
      "random" -> Enum.map(players, &random_acceleration(&1, rounds))
      other -> raise "PAIRING_FUZZ_ACCEL must be \"baku\" or \"random\", got #{inspect(other)}"
    end
  end

  defp baku(players, rounds) do
    count = length(players)
    group_a = 2 * ceil_div(count, 4)
    accelerated = ceil_div(rounds, 2)
    full = ceil_div(accelerated, 2)

    values =
      Enum.map(1..rounds//1, fn round ->
        cond do
          round <= full -> 1.0
          round <= accelerated -> 0.5
          true -> 0.0
        end
      end)

    Enum.map(players, fn p ->
      if p.rank <= group_a, do: Map.put(p, :accelerations, values), else: p
    end)
  end

  defp random_acceleration(player, rounds) do
    Map.put(
      player,
      :accelerations,
      Enum.map(1..rounds//1, fn _ -> Enum.random([0.0, 0.0, 0.5, 1.0]) end)
    )
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)

  defp play_round(players, seed, round, total_rounds, player_count, forbidden) do
    players = assign_requested_byes(players)
    trf = build_trf(players, total_rounds, forbidden)

    base = %{
      trf: trf,
      seed: seed,
      round: round,
      player_count: player_count,
      process_error?: false,
      exhausted?: false
    }

    case Bbppairings.pair(trf) do
      # bbpPairings' own equivalent of javafo's empty-pairs-file case — see
      # this module's moduledoc on the exit-code-vs-empty-file difference.
      {:no_valid_pairing, _message} ->
        {:error,
         Map.merge(base, %{
           exhausted?: true,
           match?: true,
           openpair: nil,
           bbppairings: [],
           illegal: nil
         })}

      {:ok, bbp_pairs} ->
        openpair_pairs = safely_pair(players, total_rounds, forbidden)

        # The active set comes from bbpPairings' OWN pairing, not from a rule
        # this project wrote. It used to come from `Test.Field.active/1`,
        # which was character-for-character `Pairing.rounds_played/1` — so the
        # legality check shared its central assumption with the engine it was
        # checking and could not have caught a wrong round number. See
        # `OpenPair.Test.Field`'s moduledoc.
        active = OpenPair.Test.Field.from_reference(bbp_pairs)

        measurement =
          Map.merge(base, %{
            match?: pairings_match?(openpair_pairs, bbp_pairs),
            openpair: summarise(openpair_pairs),
            bbppairings: Enum.sort(bbp_pairs)
          })
          |> Map.merge(pair_agreement(openpair_pairs, bbp_pairs))
          |> Map.put(:illegal, illegality(openpair_pairs, active, players, forbidden))

        next_players = apply_round(players, bbp_pairs, simulate_results(bbp_pairs))
        {:ok, measurement, next_players}

      {:error, {code, out}} ->
        {:error,
         Map.merge(base, %{
           process_error?: true,
           match?: false,
           illegal: nil,
           openpair: nil,
           bbppairings: {:error, code, out}
         })}
    end
  end

  defp safely_pair(players, total_rounds, forbidden) do
    Pairing.pair_next_round(players,
      expected_rounds: total_rounds,
      forbidden_pairs: forbidden
    )
  rescue
    e -> {:raised, e}
  end

  defp pairings_match?({:raised, _}, _bbp_pairs), do: false

  defp pairings_match?(openpair_pairs, bbp_pairs),
    do: normalize(openpair_pairs) == normalize(bbp_pairs)

  defp summarise({:raised, _} = raised), do: raised
  defp summarise(pairs), do: Enum.sort(pairs)

  defp illegality({:raised, _}, _active, _players, _forbidden), do: :raised

  defp illegality(pairs, active, players, forbidden) do
    byes = Enum.count(pairs, fn {_white, black} -> is_nil(black) end)
    seated = Enum.flat_map(pairs, fn {w, b} -> if b, do: [w, b], else: [w] end)
    by_rank = Map.new(players, &{&1.rank, &1})

    rematch? =
      Enum.any?(pairs, fn
        {_w, nil} ->
          false

        {w, b} ->
          Enum.any?(
            Map.fetch!(by_rank, w).games,
            &(&1.result in ~w(1 = 0) and &1.opponent_rank == b)
          )
      end)

    # C2: nobody receives a SECOND pairing-allocated bye — see the
    # identical check's doc in javafo_comparison_test.exs.
    repeat_bye? =
      Enum.any?(pairs, fn
        {w, nil} -> Enum.any?(Map.fetch!(by_rank, w).games, &(&1.result in ["U", "F", "+"]))
        _ -> false
      end)

    # An arbiter's `XXP` exclusion, checked here rather than trusted to the
    # engine. This is the only one of these five that can be violated
    # WITHOUT the round looking wrong in any other way: the pairing is a
    # clean partition, byes are correct, nobody is a rematch, and two
    # people who were never to meet are sitting across a board. It is the
    # entire reason the sibling project refused to hand OpenPair a TRF
    # carrying one, so it is measured, not assumed.
    forbidden_set =
      Enum.reduce(forbidden, MapSet.new(), fn group, acc ->
        for a <- group, b <- group, a < b, into: acc, do: {a, b}
      end)

    forbidden_pair? =
      Enum.any?(pairs, fn
        {_w, nil} -> false
        {w, b} -> MapSet.member?(forbidden_set, {min(w, b), max(w, b)})
      end)

    # `active` is a MapSet of ranks taken from bbpPairings' own pairing, so
    # both of these now compare against the reference's answer rather than
    # against a restatement of the engine's own rule.
    cond do
      byes != rem(MapSet.size(active), 2) -> :bad_bye_count
      MapSet.new(seated) != active -> :not_a_partition
      rematch? -> :rematch
      repeat_bye? -> :repeat_bye
      forbidden_pair? -> :forbidden_pair
      true -> nil
    end
  end

  defp pair_agreement({:raised, _}, bbp_pairs),
    do: %{pairs_matched: 0, pairs_total: length(bbp_pairs)}

  defp pair_agreement(openpair_pairs, bbp_pairs) do
    ours = MapSet.new(normalize(openpair_pairs))
    theirs = MapSet.new(normalize(bbp_pairs))

    %{
      pairs_matched: MapSet.size(MapSet.intersection(ours, theirs)),
      pairs_total: MapSet.size(theirs)
    }
  end

  # `152 W` (TRF-2026's native initial-piece-colour field): unlike javafo,
  # bbpPairings does not choose the very first round's colour on its own —
  # it requires the initial colour to be specified whenever no player has
  # one recorded yet, or it refuses to pair at all ("Please configure the
  # initial piece colors"). Which colour is picked doesn't matter here:
  # `normalize/1` already strips colour from the comparison entirely, the
  # same "deliberately colour-blind" stance `OpenPair.JavafoComparisonTest`
  # takes and for the identical reason (Article 5.1's drawing of lots has
  # no deterministic rule either engine's fixed convention needs to match).
  defp build_trf(players, total_rounds, forbidden) do
    OpenPair.Trf.serialize(%{
      tournament: %{name: "Fuzz", type: "swiss", forbidden_pairs: forbidden},
      players: players
    }) <> "152 W\r\nXXR #{total_rounds}\r\n"
  end

  defp assign_requested_byes(players) do
    pct = env_int("PAIRING_FUZZ_BYE_PCT", 0)

    if pct == 0 do
      players
    else
      Enum.map(players, fn player ->
        if :rand.uniform(100) <= pct do
          {result, points} = Enum.random([{"H", 0.5}, {"Z", 0.0}])

          %{
            player
            | points: player.points + points,
              games: player.games ++ [%{opponent_rank: nil, colour: nil, result: result}]
          }
        else
          player
        end
      end)
    end
  end

  defp simulate_results(pairs) do
    forfeit_pct = env_int("PAIRING_FUZZ_FORFEIT_PCT", 0)

    Map.new(pairs, fn
      {white, nil} ->
        {{white, nil}, :bye}

      {white, black} ->
        outcome =
          if forfeit_pct > 0 and :rand.uniform(100) <= forfeit_pct do
            Enum.random([:white_forfeits, :black_forfeits, :double_forfeit])
          else
            Enum.random([:white_win, :black_win, :draw])
          end

        {{white, black}, outcome}
    end)
  end

  defp apply_round(players, pairs, results) do
    games_by_rank = games_by_rank(pairs, results)

    Enum.map(players, fn p ->
      case Map.fetch(games_by_rank, p.rank) do
        {:ok, game} ->
          %{p | points: p.points + game.points, games: p.games ++ [Map.delete(game, :points)]}

        :error ->
          p
      end
    end)
  end

  defp games_by_rank(pairs, results) do
    Enum.reduce(pairs, %{}, fn {white, black} = pair, acc ->
      outcome = Map.fetch!(results, pair)
      {white_game, black_game} = games_for(white, black, outcome)

      acc = Map.put(acc, white, white_game)
      if black, do: Map.put(acc, black, black_game), else: acc
    end)
  end

  defp games_for(_white, nil, :bye) do
    {%{opponent_rank: nil, colour: nil, result: "U", points: 1.0}, nil}
  end

  defp games_for(white, black, :white_win) do
    {
      %{opponent_rank: black, colour: "w", result: "1", points: 1.0},
      %{opponent_rank: white, colour: "b", result: "0", points: 0.0}
    }
  end

  defp games_for(white, black, :black_win) do
    {
      %{opponent_rank: black, colour: "w", result: "0", points: 0.0},
      %{opponent_rank: white, colour: "b", result: "1", points: 1.0}
    }
  end

  defp games_for(white, black, :white_forfeits) do
    {
      %{opponent_rank: black, colour: "w", result: "-", points: 0.0},
      %{opponent_rank: white, colour: "b", result: "+", points: 1.0}
    }
  end

  defp games_for(white, black, :black_forfeits) do
    {
      %{opponent_rank: black, colour: "w", result: "+", points: 1.0},
      %{opponent_rank: white, colour: "b", result: "-", points: 0.0}
    }
  end

  defp games_for(white, black, :double_forfeit) do
    {
      %{opponent_rank: black, colour: "w", result: "-", points: 0.0},
      %{opponent_rank: white, colour: "b", result: "-", points: 0.0}
    }
  end

  defp games_for(white, black, :draw) do
    {
      %{opponent_rank: black, colour: "w", result: "=", points: 0.5},
      %{opponent_rank: white, colour: "b", result: "=", points: 0.5}
    }
  end

  defp normalize(pairs) do
    pairs
    |> Enum.map(fn {a, b} -> Enum.sort_by([a, b], &(&1 || :infinity)) end)
    |> Enum.sort()
  end

  defp report(comparisons, errors, exhausted, rounds) do
    IO.puts("\nbbpPairings comparison, #{rounds} round(s) per tournament:\n")
    IO.puts("  round | exact rounds |    rate | individual pairs |    rate | refused | illegal")

    IO.puts("  ------+--------------+---------+------------------+---------+---------+--------")

    comparisons
    |> Enum.group_by(& &1.round)
    |> Enum.sort_by(fn {round, _} -> round end)
    |> Enum.each(fn {round, in_round} ->
      IO.puts("  " <> String.pad_leading(to_string(round), 5) <> " | " <> row(in_round))
    end)

    IO.puts("\n  overall: " <> row(comparisons))

    illegal = Enum.reject(comparisons, &(&1.illegal == nil))

    if illegal == [] do
      IO.puts("\n  legality: every OpenPair round was a legal pairing.")
    else
      by_kind =
        illegal |> Enum.group_by(& &1.illegal) |> Enum.map(fn {k, v} -> "#{k}: #{length(v)}" end)

      IO.puts(
        "\n  LEGALITY: #{length(illegal)}/#{length(comparisons)} OpenPair rounds were not legal " <>
          "pairings at all (#{Enum.join(by_kind, ", ")}) — independent of whether bbpPairings agreed. " <>
          "`raised` means OpenPair REFUSED to pair the round, which is a different failure from " <>
          "emitting a wrong one: check whether bbpPairings paired it before assuming the round " <>
          "was genuinely impossible."
      )
    end

    if exhausted != [] do
      IO.puts(
        "\n  (#{length(exhausted)} tournament(s) ended early — bbpPairings found no legal " <>
          "pairing left, i.e. the field ran out of opponents. Excluded from the rates above.)"
      )
    end

    if errors != [] do
      IO.puts(
        "\n  WARNING: #{length(errors)} bbpPairings process error(s) — this run was likely " <>
          "resource-starved and the rates above are not trustworthy. Re-run it alone."
      )
    end
  end

  defp dump(mismatches) do
    case System.get_env("PAIRING_FUZZ_DUMP") do
      nil ->
        :ok

      dir ->
        File.mkdir_p!(dir)

        Enum.each(mismatches, fn m ->
          stem = Path.join(dir, "seed#{m.seed}-r#{m.round}-p#{m.player_count}")
          File.write!(stem <> ".trf", m.trf)

          File.write!(
            stem <> ".txt",
            "seed #{m.seed}, round #{m.round}, #{m.player_count} players\n" <>
              "pairs matched: #{m.pairs_matched}/#{m.pairs_total}\n\n" <>
              "OpenPair:     #{inspect(m.openpair, limit: :infinity)}\n" <>
              "bbpPairings:  #{inspect(m.bbppairings, limit: :infinity)}\n"
          )
        end)

        IO.puts("\n  Dumped #{length(mismatches)} disagreement(s) to #{dir}")
    end
  end

  defp row(measurements) do
    rounds_matched = Enum.count(measurements, & &1.match?)
    rounds_total = length(measurements)
    pairs_matched = Enum.sum(Enum.map(measurements, & &1.pairs_matched))
    pairs_total = Enum.sum(Enum.map(measurements, & &1.pairs_total))

    # Refusing to pair and emitting a wrong pairing are different
    # failures and want different responses, so they get their own
    # columns. Counting them together is how 142 refusals once read as
    # 142 illegal pairings — see `OpenPair.DeepRoundsTest`.
    refused = Enum.count(measurements, &(&1.illegal == :raised))
    illegal = Enum.count(measurements, &(&1.illegal not in [nil, :raised]))

    String.pad_leading("#{rounds_matched}/#{rounds_total}", 12) <>
      " | " <>
      String.pad_leading(percent(rounds_matched, rounds_total), 6) <>
      "% | " <>
      String.pad_leading("#{pairs_matched}/#{pairs_total}", 16) <>
      " | " <>
      String.pad_leading(percent(pairs_matched, pairs_total), 6) <>
      "% | " <>
      String.pad_leading("#{refused}", 7) <> " | " <> String.pad_leading("#{illegal}", 7)
  end

  defp percent(_matched, 0), do: "n/a"

  defp percent(matched, total),
    do: :erlang.float_to_binary(Float.round(matched / total * 100, 2), decimals: 2)

  defp format_mismatch(m) do
    """
    seed #{m.seed}, round #{m.round}, #{m.player_count} players:
      OpenPair:    #{inspect(m.openpair)}
      bbpPairings: #{inspect(m.bbppairings)}
    """
  end

  defp env_int(name, default) do
    name |> System.get_env(to_string(default)) |> String.to_integer()
  end
end
