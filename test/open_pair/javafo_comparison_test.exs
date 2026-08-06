defmodule OpenPair.JavafoComparisonTest do
  @moduledoc """
  Cross-checks `OpenPair.Pairing.pair_next_round/1` against the real
  `javafo.jar` (FIDE's own reference Dutch-system implementation) over a
  whole tournament — every round, not just the first or second.

  This replaces the former `javafo_comparison_test.exs` (round 1) and
  `javafo_comparison_round2_test.exs` (round 2) pair, which were the same
  methodology copied one round apart. Rounds don't need per-round code:
  bbpPairings' own tournament generator (`src/tournament/generator.cpp`)
  is a single `for` loop over `roundsNumber` calling the identical
  `computeMatching` each iteration, and `OpenPair.Pairing` is built the
  same way. The round count belongs in the harness as a loop bound, not
  as a separate test file per round.

  ## Methodology

  Each iteration builds a random roster, then plays a real tournament
  forward, one round at a time. At every round both engines are asked to
  pair the *same* history and their answers are diffed.

  The history is then advanced using **javafo's** pairing, never
  OpenPair's. That matters: it keeps every round an independent
  measurement against a real reference history, so a disagreement in
  round 3 doesn't corrupt the input to rounds 4-9 and inflate the failure
  count with knock-on divergence. It also means an OpenPair crash or
  mismatch mid-tournament doesn't cost the measurements after it.

  Deliberately colour-blind (see `normalize/1`) — JaVaFo's own choice of
  the very first round's colour is not a function of the roster or round
  count alone (confirmed empirically: identical rosters under different
  tournament *names* produced opposite initial colours), so it can't be
  replicated without reverse-engineering JaVaFo's internal seed.
  `OpenPair.Pairing`'s own fixed colour convention is spec-legal but not
  expected to match JaVaFo's on every run — see that module's doc.
  Pairing *composition* is the thing under test.

  ## Results are still only wins/losses/draws/byes

  `simulate_results/1` does not yet generate forfeits, retirements, or
  half-point byes, though bbpPairings' generator does (`generator.h`'s
  `forfeitRate`, `retiredRate`, `halfPointByeRate`). That's a real
  coverage gap and the obvious next step — but adding it in the same
  change as multi-round depth would confound the two, and this harness
  exists precisely to attribute a rate change to one cause. Depth first,
  measured; then result variety, measured separately.

  ## Running it

  Each round of each tournament spawns a real JVM (~0.2s), so cost is
  `count * rounds` JVM launches — run large sweeps deliberately, not on
  every `mix test`. Run them *alone*: a previous 100,000-roster attempt
  run alongside other fuzz batches reported a meaningless 6.29% that was
  entirely javafo processes failing to launch under load (Windows
  `0xC0000142`), not pairing mismatches. This harness reports process
  errors separately from real mismatches so that can't be misread again.

      PAIRING_FUZZ_COUNT=500 PAIRING_FUZZ_ROUNDS=9 mix test --only javafo

  Tunables (all optional):

    * `PAIRING_FUZZ_COUNT` — tournaments to play (default 20)
    * `PAIRING_FUZZ_ROUNDS` — rounds per tournament (default 2)
    * `PAIRING_FUZZ_MIN_PLAYERS` / `PAIRING_FUZZ_MAX_PLAYERS` — roster size
      range (default 4..40)

  The historical round-1 measurement (20,000 rosters, 2..60 players,
  100%) is reproducible as
  `PAIRING_FUZZ_COUNT=20000 PAIRING_FUZZ_ROUNDS=1 PAIRING_FUZZ_MIN_PLAYERS=2
  PAIRING_FUZZ_MAX_PLAYERS=60`.
  """

  use ExUnit.Case
  alias OpenPair.{Pairing, Test.Javafo}

  @moduletag :javafo
  @moduletag timeout: :infinity

  test "OpenPair and javafo.jar agree on who plays whom, in every round of a tournament" do
    count = env_int("PAIRING_FUZZ_COUNT", 20)
    rounds = env_int("PAIRING_FUZZ_ROUNDS", 2)
    players = env_int("PAIRING_FUZZ_MIN_PLAYERS", 4)..env_int("PAIRING_FUZZ_MAX_PLAYERS", 40)

    measurements =
      1..count
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
    bracket cascade (see `Pairing.pair_round/1`'s documented simplifications) — not necessarily \
    a bug in the sense that JaVaFo is "right" and OpenPair is "wrong". Each needs its own look.

    #{length(errors)} javafo process error(s) are counted separately and are NOT included above; \
    a nonzero count there means the run was resource-starved and its rate is not trustworthy.

    #{Enum.map_join(Enum.take(mismatches, 20), "\n\n", &format_mismatch/1)}
    #{if length(mismatches) > 20, do: "\n... and #{length(mismatches) - 20} more, truncated.", else: ""}
    """
  end

  # One tournament: build a roster, then play `rounds` rounds forward,
  # comparing both engines at each one. Returns a per-round measurement
  # list (possibly shorter than `rounds`, if javafo itself failed).
  defp run_tournament(seed, rounds, player_range) do
    run_tournament!(seed, rounds, player_range)
  rescue
    # One tournament blowing up must not take the whole stream down with it
    # (`Task.async_stream` propagates an unhandled raise as an :exit).
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
          javafo: nil,
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
    roster = initial_roster(player_count)

    {measurements, _final} =
      Enum.reduce_while(1..rounds, {[], roster}, fn round, {acc, players} ->
        case play_round(players, seed, round, rounds, player_count) do
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
    # Rating isn't necessarily rank-monotonic in a real tournament, and
    # round 1's pairing rule only ever consults rank — shuffling before
    # assigning ranks incidentally covers "ratings don't determine the
    # pairing, rank does".
    |> Enum.shuffle()
    |> Enum.with_index(1)
    |> Enum.map(fn {p, i} -> %{p | rank: i} end)
  end

  # Ask both engines to pair the identical history, diff them, then
  # advance the tournament on JAVAFO's answer (see the moduledoc on why
  # not OpenPair's).
  defp play_round(players, seed, round, total_rounds, player_count) do
    trf = build_trf(players, total_rounds)

    base = %{
      trf: trf,
      seed: seed,
      round: round,
      player_count: player_count,
      process_error?: false,
      exhausted?: false
    }

    case Javafo.pair(trf) do
      # javafo emits a zero-pair file when no legal pairing exists at all —
      # a small field simply runs out of legal opponents (4 players are
      # exhausted after 3 rounds, C1 forbidding rematches). That's the
      # tournament ending early, not a disagreement: stop this tournament
      # and exclude the round from the rates entirely.
      {:ok, []} ->
        {:error,
         Map.merge(base, %{
           exhausted?: true,
           match?: true,
           openpair: nil,
           javafo: [],
           illegal: nil
         })}

      {:ok, javafo_pairs} ->
        openpair_pairs = safely_pair(players)

        measurement =
          Map.merge(base, %{
            match?: pairings_match?(openpair_pairs, javafo_pairs),
            openpair: summarise(openpair_pairs),
            javafo: Enum.sort(javafo_pairs)
          })
          |> Map.merge(pair_agreement(openpair_pairs, javafo_pairs))
          |> Map.put(:illegal, illegality(openpair_pairs, players))

        next_players = apply_round(players, javafo_pairs, simulate_results(javafo_pairs))
        {:ok, measurement, next_players}

      {:error, {code, out}} ->
        {:error,
         Map.merge(base, %{
           process_error?: true,
           match?: false,
           illegal: nil,
           openpair: nil,
           javafo: {:error, code, out}
         })}
    end
  end

  # An OpenPair crash is a disagreement, not a reason to lose the rest of
  # the tournament's measurements — `Task.async_stream` would otherwise
  # propagate the raise as an :exit and kill the whole stream.
  defp safely_pair(players) do
    Pairing.pair_next_round(players)
  rescue
    e -> {:raised, e}
  end

  # Not named `match?/2`: that would collide with the auto-imported
  # `Kernel.match?/2` macro and fail to compile.
  defp pairings_match?({:raised, _}, _javafo_pairs), do: false

  defp pairings_match?(openpair_pairs, javafo_pairs),
    do: normalize(openpair_pairs) == normalize(javafo_pairs)

  defp summarise({:raised, _} = raised), do: raised
  defp summarise(pairs), do: Enum.sort(pairs)

  # Exact whole-round agreement is a brutal metric at depth: in a 20-player
  # field, one misplaced pair scores the round exactly as badly as ten do,
  # so a round-level 0% can't distinguish "nearly right" from "unrelated".
  # This measures how many individual pairs both engines chose, which turns
  # that flat 0% back into a gradient worth optimising against.
  # Is OpenPair's own answer a legal round AT ALL, judged without
  # reference to javafo? Agreement and legality are different questions,
  # and this one has a right answer: a round must pair every player
  # exactly once, never repeat a pairing, and hand out exactly one
  # pairing-allocated bye in an odd field and none in an even one.
  #
  # Worth measuring separately because the largest defect the depth work
  # found was not a disagreement at all — it was this engine emitting two
  # byes in an even field, which no amount of "javafo would have done it
  # differently" describes properly.
  defp illegality({:raised, _}, _players), do: :raised

  defp illegality(pairs, players) do
    byes = Enum.count(pairs, fn {_white, black} -> is_nil(black) end)
    seated = Enum.flat_map(pairs, fn {w, b} -> if b, do: [w, b], else: [w] end)
    by_rank = Map.new(players, &{&1.rank, &1})

    rematch? =
      Enum.any?(pairs, fn
        {_w, nil} -> false
        {w, b} -> Enum.any?(Map.fetch!(by_rank, w).games, &(&1.opponent_rank == b))
      end)

    cond do
      byes != rem(length(players), 2) -> :bad_bye_count
      Enum.sort(seated) != Enum.sort(Enum.map(players, & &1.rank)) -> :not_a_partition
      rematch? -> :rematch
      true -> nil
    end
  end

  defp pair_agreement({:raised, _}, javafo_pairs),
    do: %{pairs_matched: 0, pairs_total: length(javafo_pairs)}

  defp pair_agreement(openpair_pairs, javafo_pairs) do
    ours = MapSet.new(normalize(openpair_pairs))
    theirs = MapSet.new(normalize(javafo_pairs))

    %{
      pairs_matched: MapSet.size(MapSet.intersection(ours, theirs)),
      pairs_total: MapSet.size(theirs)
    }
  end

  defp build_trf(players, total_rounds) do
    OpenPair.Trf.serialize(%{tournament: %{name: "Fuzz", type: "swiss"}, players: players}) <>
      "XXR #{total_rounds}\r\n"
  end

  # White win, black win, or draw for a real pairing; a bye (nil opponent)
  # always scores the standard pairing-allocated-bye full point.
  #
  # With `PAIRING_FUZZ_FORFEIT_PCT` a share of games are forfeited
  # instead. A forfeit is the interesting case, not just a rarer one: it
  # occupies a pairing slot and carries BOTH an opponent and a colour in
  # the TRF, yet is legally unplayed under FIDE Art. 16. So it must not
  # count toward colour balance, must not extend a repeated-colour run,
  # and counts as an unplayed game for float and bye-eligibility purposes
  # — every one of which is a separate place the engine can get it wrong.
  #
  # Defaults to 0 so every earlier measurement stays reproducible.
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
      game = Map.fetch!(games_by_rank, p.rank)
      %{p | points: p.points + game.points, games: p.games ++ [Map.delete(game, :points)]}
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

  # Forfeits keep the colour they were paired with — that is what a real
  # TRF records — even though the game counts as unplayed.
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

  # Colour/board-order is presentation, not the thing under test — sort
  # each pair's own two members (bye's `nil` sorts last) then the whole set.
  defp normalize(pairs) do
    pairs
    |> Enum.map(fn {a, b} -> Enum.sort_by([a, b], &(&1 || :infinity)) end)
    |> Enum.sort()
  end

  # The per-round breakdown is the whole point of running deep: a single
  # blended percentage over all rounds would hide exactly the signal this
  # harness was built to find (criteria that cannot bind until round 3+).
  defp report(comparisons, errors, exhausted, rounds) do
    IO.puts("\nJaVaFo comparison, #{rounds} round(s) per tournament:\n")
    IO.puts("  round | exact rounds |    rate | individual pairs |    rate")
    IO.puts("  ------+--------------+---------+------------------+--------")

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
          "pairings at all (#{Enum.join(by_kind, ", ")}) — independent of whether javafo agreed."
      )
    end

    if exhausted != [] do
      IO.puts(
        "\n  (#{length(exhausted)} tournament(s) ended early — javafo found no legal pairing " <>
          "left, i.e. the field ran out of opponents. Excluded from the rates above.)"
      )
    end

    if errors != [] do
      IO.puts(
        "\n  WARNING: #{length(errors)} javafo process error(s) — this run was likely " <>
          "resource-starved and the rates above are not trustworthy. Re-run it alone."
      )
    end
  end

  # With `PAIRING_FUZZ_DUMP=<dir>`, write each disagreement's exact TRF
  # alongside both engines' answers. A rate tells you there's a problem; a
  # replayable input is what lets you find it, and regenerating one from a
  # seed means reproducing the whole tournament up to that round.
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
              "OpenPair: #{inspect(m.openpair, limit: :infinity)}\n" <>
              "javafo:   #{inspect(m.javafo, limit: :infinity)}\n"
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

    String.pad_leading("#{rounds_matched}/#{rounds_total}", 12) <>
      " | " <>
      String.pad_leading(percent(rounds_matched, rounds_total), 6) <>
      "% | " <>
      String.pad_leading("#{pairs_matched}/#{pairs_total}", 16) <>
      " | " <> String.pad_leading(percent(pairs_matched, pairs_total), 6) <> "%"
  end

  defp percent(_matched, 0), do: "n/a"

  defp percent(matched, total),
    do: :erlang.float_to_binary(Float.round(matched / total * 100, 2), decimals: 2)

  defp format_mismatch(m) do
    """
    seed #{m.seed}, round #{m.round}, #{m.player_count} players:
      OpenPair: #{inspect(m.openpair)}
      javafo:   #{inspect(m.javafo)}
    """
  end

  defp env_int(name, default) do
    name |> System.get_env(to_string(default)) |> String.to_integer()
  end
end
