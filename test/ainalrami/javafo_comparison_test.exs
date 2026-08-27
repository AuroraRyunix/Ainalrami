defmodule Ainalrami.JavafoComparisonTest do
  @moduledoc """
  Cross-checks `Ainalrami.Pairing.pair_next_round/1` against the real
  `javafo.jar` (FIDE's own reference Dutch-system implementation) over a
  whole tournament - every round, not just the first or second.

  This replaces the former `javafo_comparison_test.exs` (round 1) and
  `javafo_comparison_round2_test.exs` (round 2) pair, which were the same
  methodology copied one round apart. Rounds don't need per-round code:
  bbpPairings' own tournament generator (`src/tournament/generator.cpp`)
  is a single `for` loop over `roundsNumber` calling the identical
  `computeMatching` each iteration, and `Ainalrami.Pairing` is built the
  same way. The round count belongs in the harness as a loop bound, not
  as a separate test file per round.

  ## Methodology

  Each iteration builds a random roster, then plays a real tournament
  forward, one round at a time. At every round both engines are asked to
  pair the *same* history and their answers are diffed.

  The history is then advanced using **javafo's** pairing, never
  Ainalrami's. That matters: it keeps every round an independent
  measurement against a real reference history, so a disagreement in
  round 3 doesn't corrupt the input to rounds 4-9 and inflate the failure
  count with knock-on divergence. It also means an Ainalrami crash or
  mismatch mid-tournament doesn't cost the measurements after it.

  Deliberately colour-blind (see `normalize/1`) - JaVaFo's own choice of
  the very first round's colour is not a function of the roster or round
  count alone (confirmed empirically: identical rosters under different
  tournament *names* produced opposite initial colours), so it can't be
  replicated without reverse-engineering JaVaFo's internal seed.
  `Ainalrami.Pairing`'s own fixed colour convention is spec-legal but not
  expected to match JaVaFo's on every run - see that module's doc.
  Pairing *composition* is the thing under test.

  ## Result variety

  `simulate_results/1` generates wins, losses, draws, pairing-allocated
  byes, and - with `PAIRING_FUZZ_FORFEIT_PCT` - forfeits, including
  double forfeits. Forfeits earn their own switch because they found four
  engine bugs of one family on the first run: a forfeit carries both an
  opponent and a colour in the TRF yet is legally unplayed (Art. 16), so
  every check that tested for the presence of one instead of asking
  whether the game happened was wrong, C1's no-rematch rule included.

  Default 0, so every measurement taken before forfeits existed stays
  reproducible, and so a rate change can be attributed to one cause at a
  time.

  Still missing, and needing a protocol change rather than another result
  code: half-point byes, zero-point byes and retirements
  (`generator.h`'s `retiredRate`, `halfPointByeRate`). Those are decided
  BEFORE a round is paired, so the harness would have to withhold the
  player from the TRF it hands the engine, not record a result after the
  fact.

  ## Running it

  Each round of each tournament spawns a real JVM (~0.2s), so cost is
  `count * rounds` JVM launches - run large sweeps deliberately, not on
  every `mix test`. Run them *alone*: a previous 100,000-roster attempt
  run alongside other fuzz batches reported a meaningless 6.29% that was
  entirely javafo processes failing to launch under load (Windows
  `0xC0000142`), not pairing mismatches. This harness reports process
  errors separately from real mismatches so that can't be misread again.

      PAIRING_FUZZ_COUNT=500 PAIRING_FUZZ_ROUNDS=9 mix test --only javafo

  Tunables (all optional):

    * `PAIRING_FUZZ_COUNT` - tournaments to play (default 20)
    * `PAIRING_FUZZ_ROUNDS` - rounds per tournament (default 2)
    * `PAIRING_FUZZ_MIN_PLAYERS` / `PAIRING_FUZZ_MAX_PLAYERS` - roster size
      range (default 4..40)
    * `PAIRING_FUZZ_BYE_PCT` / `PAIRING_FUZZ_FORFEIT_PCT` - result variety
    * `PAIRING_FUZZ_DUMP=<dir>` - write each disagreement's TRF there

  That is the WHOLE list. This harness predates
  `Ainalrami.Test.FuzzTournament` and never adopted it - `initial_roster/1`
  and `build_trf/2` are its own private generator - so the nine remaining
  `PAIRING_FUZZ_*` knobs the bbpPairings harness reads take effect nowhere
  here. `refuse_unsupported_axes!/0` raises rather than letting a run report
  the default axis's rate under a requested axis's name.

  The historical round-1 measurement (20,000 rosters, 2..60 players,
  100%) is reproducible as
  `PAIRING_FUZZ_COUNT=20000 PAIRING_FUZZ_ROUNDS=1 PAIRING_FUZZ_MIN_PLAYERS=2
  PAIRING_FUZZ_MAX_PLAYERS=60`.
  """

  use ExUnit.Case
  alias Ainalrami.{Pairing, Test.Javafo}

  @moduletag :javafo
  @moduletag timeout: :infinity

  test "Ainalrami and javafo.jar agree on who plays whom, in every round of a tournament" do
    refuse_unsupported_axes!()

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
    of #{count} tournament(s) - a legal-but-different pairing, or a genuine gap in Ainalrami's \
    bracket cascade (see `Pairing.pair_round/1`'s documented simplifications) - not necessarily \
    a bug in the sense that JaVaFo is "right" and Ainalrami is "wrong". Each needs its own look.

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
          ainalrami: {:raised, e},
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
    # round 1's pairing rule only ever consults rank - shuffling before
    # assigning ranks incidentally covers "ratings don't determine the
    # pairing, rank does".
    |> Enum.shuffle()
    |> Enum.with_index(1)
    |> Enum.map(fn {p, i} -> %{p | rank: i} end)
  end

  # Ask both engines to pair the identical history, diff them, then
  # advance the tournament on JAVAFO's answer (see the moduledoc on why
  # not Ainalrami's).
  defp play_round(players, seed, round, total_rounds, player_count) do
    players = assign_requested_byes(players)
    # See `Ainalrami.Test.Field` for why this is not `length(games) < round`.
    active = Ainalrami.Test.Field.active(players)
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
      # javafo emits a zero-pair file when no legal pairing exists at all -
      # a small field simply runs out of legal opponents (4 players are
      # exhausted after 3 rounds, C1 forbidding rematches). That's the
      # tournament ending early, not a disagreement: stop this tournament
      # and exclude the round from the rates entirely.
      {:ok, []} ->
        {:error,
         Map.merge(base, %{
           exhausted?: true,
           match?: true,
           ainalrami: nil,
           javafo: [],
           illegal: nil
         })}

      {:ok, javafo_pairs} ->
        ainalrami_pairs = safely_pair(players, total_rounds)

        measurement =
          Map.merge(base, %{
            match?: pairings_match?(ainalrami_pairs, javafo_pairs),
            ainalrami: summarise(ainalrami_pairs),
            javafo: Enum.sort(javafo_pairs)
          })
          |> Map.merge(pair_agreement(ainalrami_pairs, javafo_pairs))
          |> Map.put(:illegal, illegality(ainalrami_pairs, active, players))

        next_players = apply_round(players, javafo_pairs, simulate_results(javafo_pairs))
        {:ok, measurement, next_players}

      {:error, {code, out}} ->
        {:error,
         Map.merge(base, %{
           process_error?: true,
           match?: false,
           illegal: nil,
           ainalrami: nil,
           javafo: {:error, code, out}
         })}
    end
  end

  # An Ainalrami crash is a disagreement, not a reason to lose the rest of
  # the tournament's measurements - `Task.async_stream` would otherwise
  # propagate the raise as an :exit and kill the whole stream.
  defp safely_pair(players, total_rounds) do
    Pairing.pair_next_round(players, expected_rounds: total_rounds)
  rescue
    e -> {:raised, e}
  end

  # Not named `match?/2`: that would collide with the auto-imported
  # `Kernel.match?/2` macro and fail to compile.
  defp pairings_match?({:raised, _}, _javafo_pairs), do: false

  defp pairings_match?(ainalrami_pairs, javafo_pairs),
    do: normalize(ainalrami_pairs) == normalize(javafo_pairs)

  defp summarise({:raised, _} = raised), do: raised
  defp summarise(pairs), do: Enum.sort(pairs)

  # Exact whole-round agreement is a brutal metric at depth: in a 20-player
  # field, one misplaced pair scores the round exactly as badly as ten do,
  # so a round-level 0% can't distinguish "nearly right" from "unrelated".
  # This measures how many individual pairs both engines chose, which turns
  # that flat 0% back into a gradient worth optimising against.
  # Is Ainalrami's own answer a legal round AT ALL, judged without
  # reference to javafo? Agreement and legality are different questions,
  # and this one has a right answer: a round must pair every player
  # exactly once, never repeat a pairing, and hand out exactly one
  # pairing-allocated bye in an odd field and none in an even one.
  #
  # Worth measuring separately because the largest defect the depth work
  # found was not a disagreement at all - it was this engine emitting two
  # byes in an even field, which no amount of "javafo would have done it
  # differently" describes properly.
  defp illegality({:raised, _}, _active, _players), do: :raised

  defp illegality(pairs, active, players) do
    byes = Enum.count(pairs, fn {_white, black} -> is_nil(black) end)
    seated = Enum.flat_map(pairs, fn {w, b} -> if b, do: [w, b], else: [w] end)
    by_rank = Map.new(players, &{&1.rank, &1})

    # Only an actually-played game forbids a rematch: bbpPairings builds
    # its forbiddenPairs set under `if (match.gameWasPlayed)`, and javafo
    # was observed re-pairing two players whose only previous meeting was
    # a double forfeit. Judging the engine by the stricter rule would
    # report 443 false violations in a forfeit-heavy run.
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

    # C2: nobody receives a SECOND pairing-allocated bye. Was never
    # actually checked here - a real gap, closed after finding that
    # Ainalrami's own `repair_bye_count/3` could silently violate it too
    # (see that function's doc in lib/ainalrami/pairing.ex).
    repeat_bye? =
      Enum.any?(pairs, fn
        {w, nil} -> Enum.any?(Map.fetch!(by_rank, w).games, &(&1.result in ["U", "F", "+"]))
        _ -> false
      end)

    cond do
      byes != rem(length(active), 2) -> :bad_bye_count
      Enum.sort(seated) != Enum.sort(Enum.map(active, & &1.rank)) -> :not_a_partition
      rematch? -> :rematch
      repeat_bye? -> :repeat_bye
      true -> nil
    end
  end

  defp pair_agreement({:raised, _}, javafo_pairs),
    do: %{pairs_matched: 0, pairs_total: length(javafo_pairs)}

  defp pair_agreement(ainalrami_pairs, javafo_pairs) do
    ours = MapSet.new(normalize(ainalrami_pairs))
    theirs = MapSet.new(normalize(javafo_pairs))

    %{
      pairs_matched: MapSet.size(MapSet.intersection(ours, theirs)),
      pairs_total: MapSet.size(theirs)
    }
  end

  defp build_trf(players, total_rounds) do
    Ainalrami.Trf.serialize(%{tournament: %{name: "Fuzz", type: "swiss"}, players: players}) <>
      "XXR #{total_rounds}\r\n"
  end

  # Requested byes: a half-point or zero-point bye that the arbiter grants
  # BEFORE the round is paired, recorded in the TRF so the engine leaves
  # that player out. bbpPairings implements exactly this
  # (`dutch.cpp:658`), and it is the only way a real tournament expresses
  # "this player is not playing this round" - there is no TRF flag for it.
  #
  # This is what caught the engine pairing a player who had asked not to
  # play. Note these must NOT advance the round number, unlike a
  # pairing-allocated bye.
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

  # White win, black win, or draw for a real pairing; a bye (nil opponent)
  # always scores the standard pairing-allocated-bye full point.
  #
  # With `PAIRING_FUZZ_FORFEIT_PCT` a share of games are forfeited
  # instead. A forfeit is the interesting case, not just a rarer one: it
  # occupies a pairing slot and carries BOTH an opponent and a colour in
  # the TRF, yet is legally unplayed under FIDE Art. 16. So it must not
  # count toward colour balance, must not extend a repeated-colour run,
  # and counts as an unplayed game for float and bye-eligibility purposes
  # - every one of which is a separate place the engine can get it wrong.
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
      case Map.fetch(games_by_rank, p.rank) do
        {:ok, game} ->
          %{p | points: p.points + game.points, games: p.games ++ [Map.delete(game, :points)]}

        # Sat this round out on a requested bye - their result for it was
        # recorded before the round was paired, which is the whole point.
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

  # Forfeits keep the colour they were paired with - that is what a real
  # TRF records - even though the game counts as unplayed.
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

  # Colour/board-order is presentation, not the thing under test - sort
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
      IO.puts("\n  legality: every Ainalrami round was a legal pairing.")
    else
      by_kind =
        illegal |> Enum.group_by(& &1.illegal) |> Enum.map(fn {k, v} -> "#{k}: #{length(v)}" end)

      IO.puts(
        "\n  LEGALITY: #{length(illegal)}/#{length(comparisons)} Ainalrami rounds were not legal " <>
          "pairings at all (#{Enum.join(by_kind, ", ")}) - independent of whether javafo agreed. " <>
          "`raised` means Ainalrami REFUSED to pair the round, which is a different failure from " <>
          "emitting a wrong one: check whether javafo paired it before assuming the round was " <>
          "genuinely impossible."
      )
    end

    if exhausted != [] do
      IO.puts(
        "\n  (#{length(exhausted)} tournament(s) ended early - javafo found no legal pairing " <>
          "left, i.e. the field ran out of opponents. Excluded from the rates above.)"
      )
    end

    if errors != [] do
      IO.puts(
        "\n  WARNING: #{length(errors)} javafo process error(s) - this run was likely " <>
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
              "Ainalrami: #{inspect(m.ainalrami, limit: :infinity)}\n" <>
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

    # Refusing to pair and emitting a wrong pairing are different failures
    # and want different responses, so they get their own columns.
    # Counting them together is how 142 refusals once read as 142 illegal
    # pairings - see `Ainalrami.DeepRoundsTest`. The split landed in the
    # bbpPairings harness and not in this copy, which is the second
    # instrument fix to have reached one of the two.
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
      Ainalrami: #{inspect(m.ainalrami)}
      javafo:   #{inspect(m.javafo)}
    """
  end

  # This harness predates `Ainalrami.Test.FuzzTournament` and never adopted
  # it: `initial_roster/1` and `build_trf/2` below are its own private
  # generator, and they read seven of the sixteen `PAIRING_FUZZ_*` knobs.
  # The other nine take effect NOWHERE here, and setting one used to be
  # indistinguishable from not setting it - the run completed, reported a
  # rate, and the rate was for the DEFAULT axis under the requested axis's
  # name. `PAIRING_FUZZ_POINT_SYSTEM=mixed ... --only javafo` banked as
  # "the point system checks out against JaVaFo too" would have been a
  # measurement of nothing.
  #
  # Modelled on `Ainalrami.ThreeWayComparisonTest`'s guard of the same name,
  # and refusing for the same reason: not because the axis is unmeasurable,
  # but because a silently ignored request produces a number that reads as
  # evidence and is not. Wiring this harness onto `FuzzTournament` would
  # retire the whole list; until then it says so out loud.
  @unsupported_axes [
    {"PAIRING_FUZZ_RATING_MODE",
     "initial_roster/1 draws Enum.random(1000..2800) - no ties, no unrated"},
    {"PAIRING_FUZZ_ACCEL", "build_trf/2 emits no XXA line"},
    {"PAIRING_FUZZ_FORBIDDEN_PCT",
     "build_trf/2 emits no XXP or 260 line, and safely_pair/2 passes no :forbidden_pairs"},
    {"PAIRING_FUZZ_POINT_SYSTEM",
     "build_trf/2 emits no BB* or 162 line, and safely_pair/2 passes no :point_system"},
    {"PAIRING_FUZZ_NUMERIC_EXT", "build_trf/2 emits neither spelling of the extension lines"},
    {"PAIRING_FUZZ_WITHDRAW_PCT", "nothing withdraws anyone"},
    {"PAIRING_FUZZ_INITIAL_COLOUR",
     "build_trf/2 emits no 152 line, and this harness is colour-blind by design"},
    {"PAIRING_FUZZ_ROUNDS_MAX", "the round count is fixed at PAIRING_FUZZ_ROUNDS"},
    {"PAIRING_FUZZ_SEED_FROM", "seeds always run 1..PAIRING_FUZZ_COUNT"}
  ]

  defp refuse_unsupported_axes! do
    set =
      Enum.filter(@unsupported_axes, fn {name, _why} ->
        System.get_env(name) not in [nil, "", "0", "false"]
      end)

    if set != [] do
      raise """
      #{length(set)} axis/axes are set that this harness does not implement:

      #{Enum.map_join(set, "
", fn {name, why} -> "  #{name}=#{System.get_env(name)} - #{why}" end)}

      This harness has its own private generator and never adopted
      `Ainalrami.Test.FuzzTournament`, so these knobs take effect nowhere in
      it. The run would complete and report a rate for the DEFAULT axis
      under the requested axis's name.

      Run these against bbpPairings (`--only bbppairings`), which does read
      them, or wire this harness onto `FuzzTournament` first.
      """
    end
  end

  defp env_int(name, default) do
    name |> System.get_env(to_string(default)) |> String.to_integer()
  end
end
