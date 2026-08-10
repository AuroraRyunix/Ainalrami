defmodule OpenPair.FailureTaxonomyTest do
  @moduledoc """
  Classifies the disagreements `OpenPair.BbppairingsComparisonTest` counts,
  instead of only counting them.

  That harness answers "how often". At ~90% of exact rounds this project
  had stopped being able to act on that number: every remaining
  architecture-level idea was a blind bet, and the last three of those
  (cross-bracket pairing, both C8 scorings, the global-graph rewrite)
  had all failed or tied. Every measurable win it had came from
  identifying one concrete wrong decision and fixing it. So this asks
  "wrong how", and buckets the answers.

  It earned its keep immediately. Ranking the 164 failures by cause, and
  then adjudicating them with `tools/adjudicate.exs`, is what isolated
  the peek-budget defect — brackets could not see far enough to evaluate
  C8, the criterion whose whole job is to protect the bracket below. That
  one fix took the engine from 90.29% to 95.97% of exact rounds, and from
  82.22% to 99.44% on the 60-80 player fields an open actually has.

  ## What it classifies

  For each disagreeing round it walks the score groups from the top and
  reports the FIRST one where the two engines part company, and the way
  they part:

    * `:bye_assignee` — a different player is left unpaired. C5/C2.
    * `:float_set` — a score group sends a different SET of players out
      of it. C6/C7/C8, the downfloater choice.
    * `:internal_pairing` — identical float sets everywhere, but a group
      pairs its own members differently. That is FIDE C.04.3 section 3's
      transposition/exchange procedure, which the default path only
      approximates (`deviation`/`spread`, see docs/fide-criteria.md).

  A round's first divergence is the actionable one: everything below it
  is downstream of a decision already made, so classifying the whole
  round by its first bracket avoids counting one mistake several times.

  ## Why it re-derives the tournaments

  The generation below is a deliberate copy of the comparison harness's,
  because the two must produce byte-identical tournaments for the buckets
  to describe the same failures the rates are measured over. That
  duplication is checked rather than trusted: the run asserts its own
  disagreement count against `EXPECTED_DISAGREEMENTS` when told what to
  expect, so a drift in either copy fails loudly instead of quietly
  classifying a different population.

      PAIRING_FUZZ_COUNT=200 PAIRING_FUZZ_ROUNDS=9 \\
        EXPECTED_DISAGREEMENTS=68 mix test --only taxonomy
  """

  use ExUnit.Case
  alias OpenPair.{Pairing, Test.Bbppairings}

  @moduletag :taxonomy
  @moduletag timeout: :infinity

  test "classifies every OpenPair/bbpPairings disagreement by its first divergent bracket" do
    count = env_int("PAIRING_FUZZ_COUNT", 20)
    rounds = env_int("PAIRING_FUZZ_ROUNDS", 2)
    players = env_int("PAIRING_FUZZ_MIN_PLAYERS", 4)..env_int("PAIRING_FUZZ_MAX_PLAYERS", 40)

    failures =
      1..count
      |> Task.async_stream(&run_tournament(&1, rounds, players),
        max_concurrency: System.schedulers_online(),
        timeout: :infinity,
        ordered: false
      )
      |> Enum.flat_map(fn {:ok, rows} -> rows end)

    report(failures, rounds)

    case System.get_env("EXPECTED_DISAGREEMENTS") do
      nil ->
        :ok

      expected ->
        assert length(failures) == String.to_integer(expected),
               "classified #{length(failures)} disagreements but the comparison harness " <>
                 "reports #{expected}. The replayed tournaments have drifted from " <>
                 "bbppairings_comparison_test.exs's, so these buckets describe a " <>
                 "different population and cannot be acted on."
    end
  end

  ## ---------- classification ----------

  # Everyone a pairing leaves unpaired (at most one, but a broken pairing
  # could leave more and that should surface as a bye disagreement rather
  # than crash).
  defp byes(pairs), do: for({w, nil} <- pairs, do: w)

  # The pairs, as unordered {low, high} rank tuples, colour discarded —
  # the comparison harness is deliberately colour-blind and so is this.
  defp seated(pairs), do: for({w, b} <- pairs, b != nil, do: Enum.min_max([w, b]))

  # Players of THIS score who are paired with someone of a different
  # score: the group's floats, in or out.
  defp floats(pairs_seated, group, score_of) do
    for {a, b} <- pairs_seated,
        score_of[a] != score_of[b],
        rank <- [a, b],
        score_of[rank] == group,
        into: MapSet.new(),
        do: rank
  end

  defp internal(pairs_seated, group, score_of) do
    for {a, b} <- pairs_seated,
        score_of[a] == group and score_of[b] == group,
        into: MapSet.new(),
        do: {a, b}
  end

  # The pairs with exactly one end in this group. Needed as well as
  # `floats/3`, which is only the SET of players who leave: two engines
  # can float the identical players and still send them to different
  # partners, and an earlier version of this classifier called those
  # rounds indistinguishable — 27% of them — because it never looked at
  # where a floater landed.
  defp cross(pairs_seated, group, score_of) do
    for {a, b} <- pairs_seated,
        score_of[a] == group != (score_of[b] == group),
        into: MapSet.new(),
        do: {a, b}
  end

  defp classify(ours, theirs, players) do
    score_of = Map.new(players, &{&1.rank, &1.points})
    groups = players |> Enum.map(& &1.points) |> Enum.uniq() |> Enum.sort(:desc)
    depth_of = groups |> Enum.with_index(1) |> Map.new()

    our_byes = Enum.sort(byes(ours))
    their_byes = Enum.sort(byes(theirs))

    if our_byes != their_byes do
      # Whose bye it is outranks everything else in the round: it is an
      # absolute criterion (C5/C2), and every bracket below the assignee
      # is repartitioned by the choice.
      group = (their_byes ++ our_byes) |> Enum.map(&score_of[&1]) |> Enum.max()
      {:bye_assignee, Map.fetch!(depth_of, group), group}
    else
      first_divergent_group(groups, depth_of, seated(ours), seated(theirs), score_of)
    end
  end

  # Top group down, because who LEAVES a bracket is settled before the
  # rest of it pairs: a difference higher up is the cause, and anything
  # below it is that cause's consequence.
  #
  # The three tests together are exhaustive — every pair is either
  # internal to some group or crosses two of them — so a round that
  # reaches `:indistinguishable` means this classifier and the comparison
  # harness disagree about what a disagreement is, which is a bug here
  # rather than a finding.
  defp first_divergent_group(groups, depth_of, ours, theirs, score_of) do
    hit =
      Enum.find_value(groups, fn group ->
        cond do
          floats(ours, group, score_of) != floats(theirs, group, score_of) ->
            {:float_set, group}

          internal(ours, group, score_of) != internal(theirs, group, score_of) ->
            {:internal_pairing, group}

          cross(ours, group, score_of) != cross(theirs, group, score_of) ->
            {:float_partner, group}

          true ->
            nil
        end
      end)

    case hit do
      {cause, group} -> {cause, Map.fetch!(depth_of, group), group}
      nil -> {:indistinguishable, 0, nil}
    end
  end

  # Was the first divergent bracket carrying moved-down players?
  #
  # Read this with care for `:float_partner`. The divergence is DETECTED
  # at the group the floater leaves, but the choice of who receives them
  # is made when the group BELOW is paired — as a heterogeneous bracket
  # with that floater as its MDP. So a "homogeneous" float_partner still
  # implicates the MDP-opponent machinery, just one bracket further down.
  defp bracket_shape(theirs, group, players) do
    score_of = Map.new(players, &{&1.rank, &1.points})

    upfloated_in? =
      Enum.any?(seated(theirs), fn {a, b} ->
        (score_of[a] == group and score_of[b] > group) or
          (score_of[b] == group and score_of[a] > group)
      end)

    if upfloated_in?, do: :heterogeneous, else: :homogeneous
  end

  ## ---------- replay (a deliberate copy — see moduledoc) ----------

  defp run_tournament(seed, rounds, player_range) do
    :rand.seed(:exsss, {seed, seed * 7919, seed * 104_729})
    player_count = Enum.random(player_range)
    roster = initial_roster(player_count)

    {rows, _final} =
      Enum.reduce_while(1..rounds, {[], roster}, fn round, {acc, players} ->
        case play_round(players, seed, round, rounds) do
          {:ok, nil, next} -> {:cont, {acc, next}}
          {:ok, row, next} -> {:cont, {[row | acc], next}}
          :halt -> {:halt, {acc, players}}
        end
      end)

    rows
  rescue
    # Surfaced as a bucket rather than swallowed: a crash in the replay
    # would otherwise quietly shrink the population being classified, and
    # the EXPECTED_DISAGREEMENTS check is what catches that.
    e ->
      [%{seed: seed, round: 0, cause: :replay_crashed, depth: 0, shape: inspect(e), swapped: 0}]
  end

  defp initial_roster(player_count) do
    for i <- 1..player_count do
      %{rank: i, name: "P#{i}", fide_rating: Enum.random(1000..2800), points: 0.0, games: []}
    end
    |> Enum.shuffle()
    |> Enum.with_index(1)
    |> Enum.map(fn {p, i} -> %{p | rank: i} end)
  end

  defp play_round(players, seed, round, total_rounds) do
    players = assign_requested_byes(players)
    trf = build_trf(players, total_rounds)

    case Bbppairings.pair(trf) do
      {:ok, bbp_pairs} ->
        active = Enum.filter(players, &(length(&1.games) < round))
        ours = safely_pair(players, total_rounds)
        next = apply_round(players, bbp_pairs, simulate_results(bbp_pairs))

        row =
          cond do
            match?({:raised, _}, ours) ->
              %{seed: seed, round: round, cause: :raised, depth: 0, shape: nil, swapped: 0}

            normalize(ours) == normalize(bbp_pairs) ->
              nil

            true ->
              {cause, depth, group} = classify(ours, bbp_pairs, active)

              %{
                seed: seed,
                round: round,
                cause: cause,
                depth: depth,
                shape: group && bracket_shape(bbp_pairs, group, active),
                swapped:
                  MapSet.size(
                    MapSet.difference(
                      MapSet.new(normalize(ours)),
                      MapSet.new(normalize(bbp_pairs))
                    )
                  )
              }
          end

        {:ok, row, next}

      _ ->
        :halt
    end
  end

  defp safely_pair(players, total_rounds) do
    Pairing.pair_next_round(players, expected_rounds: total_rounds)
  rescue
    e -> {:raised, e}
  end

  defp build_trf(players, total_rounds) do
    OpenPair.Trf.serialize(%{tournament: %{name: "Fuzz", type: "swiss"}, players: players}) <>
      "152 W\r\nXXR #{total_rounds}\r\n"
  end

  # Both of these must stay identical to the comparison harness's, or the
  # replayed tournaments diverge and the buckets describe a different
  # population — which is what `EXPECTED_DISAGREEMENTS` exists to catch.
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

  defp games_for(white, black, :white_forfeits) do
    {%{opponent_rank: black, colour: "w", result: "-", points: 0.0},
     %{opponent_rank: white, colour: "b", result: "+", points: 1.0}}
  end

  defp games_for(white, black, :black_forfeits) do
    {%{opponent_rank: black, colour: "w", result: "+", points: 1.0},
     %{opponent_rank: white, colour: "b", result: "-", points: 0.0}}
  end

  defp games_for(white, black, :double_forfeit) do
    {%{opponent_rank: black, colour: "w", result: "-", points: 0.0},
     %{opponent_rank: white, colour: "b", result: "-", points: 0.0}}
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
      {white_game, black_game} = games_for(white, black, Map.fetch!(results, pair))
      acc = Map.put(acc, white, white_game)
      if black, do: Map.put(acc, black, black_game), else: acc
    end)
  end

  defp games_for(_white, nil, :bye),
    do: {%{opponent_rank: nil, colour: nil, result: "U", points: 1.0}, nil}

  defp games_for(white, black, :white_win) do
    {%{opponent_rank: black, colour: "w", result: "1", points: 1.0},
     %{opponent_rank: white, colour: "b", result: "0", points: 0.0}}
  end

  defp games_for(white, black, :black_win) do
    {%{opponent_rank: black, colour: "w", result: "0", points: 0.0},
     %{opponent_rank: white, colour: "b", result: "1", points: 1.0}}
  end

  defp games_for(white, black, :draw) do
    {%{opponent_rank: black, colour: "w", result: "=", points: 0.5},
     %{opponent_rank: white, colour: "b", result: "=", points: 0.5}}
  end

  defp normalize(pairs) do
    pairs
    |> Enum.map(fn {a, b} -> Enum.sort_by([a, b], &(&1 || :infinity)) end)
    |> Enum.sort()
  end

  ## ---------- report ----------

  defp report(failures, rounds) do
    total = length(failures)
    IO.puts("\nfailure taxonomy, #{total} disagreement(s) over #{rounds} round(s):\n")

    if total > 0 do
      section("by cause", failures, &"#{&1.cause}", total)

      section(
        "by cause and bracket shape",
        failures,
        &"#{&1.cause} (#{&1.shape || "n/a"})",
        total
      )

      section("by first divergent bracket, 1 = top", failures, &"depth #{&1.depth}", total)
      section("by round", failures, &"round #{&1.round}", total)
      section("by pairs wrong", failures, &"#{&1.swapped} pair(s)", total)

      # The TOP bracket is the one worth looking at first: it inherits no
      # floats and no earlier decision, so a divergence there is an
      # isolated wrong answer rather than the downstream consequence of
      # one. Anything in this slice should be reproducible on its own.
      top = Enum.filter(failures, &(&1.depth == 1))

      if top != [] do
        IO.puts("  TOP BRACKET ONLY (#{length(top)} of #{total}) — no inherited state:")
        section("    by cause", top, &"#{&1.cause}", length(top))

        IO.puts("    first 8 to trace:")

        top
        |> Enum.sort_by(&{&1.seed, &1.round})
        |> Enum.take(8)
        |> Enum.each(&IO.puts("      seed #{&1.seed}, round #{&1.round}, #{&1.cause}"))

        IO.puts("")
      end

      IO.puts("\n  worst bucket, first 8 cases to trace:")

      {label, cases} =
        failures
        |> Enum.group_by(fn f -> "#{f.cause} (#{f.shape || "n/a"})" end)
        |> Enum.max_by(fn {_k, v} -> length(v) end)

      IO.puts("    #{label}")

      cases
      |> Enum.sort_by(&{&1.seed, &1.round})
      |> Enum.take(8)
      |> Enum.each(&IO.puts("      seed #{&1.seed}, round #{&1.round}, depth #{&1.depth}"))
    end

    IO.puts("")
  end

  defp section(title, failures, key, total) do
    IO.puts("  #{title}:")

    failures
    |> Enum.group_by(key)
    |> Enum.sort_by(fn {_k, v} -> -length(v) end)
    |> Enum.each(fn {k, v} ->
      share = Float.round(length(v) * 100 / total, 1)

      IO.puts(
        "    #{String.pad_trailing(k, 38)} #{String.pad_leading(to_string(length(v)), 4)}  #{share}%"
      )
    end)

    IO.puts("")
  end

  defp env_int(name, default) do
    name |> System.get_env(to_string(default)) |> String.to_integer()
  end
end
