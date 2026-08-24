defmodule Ainalrami.Test.FuzzTournament do
  @moduledoc """
  Generates the random tournaments every comparison harness measures, and
  plays them forward on a reference engine's answers.

  ## Why this is a module rather than a copy in each harness

  It used to live inside `Ainalrami.BbppairingsComparisonTest`, which was
  fine while that was the only harness that generated anything.
  `Ainalrami.ThreeWayComparisonTest` had its own generator, and the two had
  drifted badly: the two-way one produces byes, forfeits, forbidden pairs,
  acceleration, withdrawals, five rating shapes and a variable round count,
  and the three-way one produced none of them - uniform ratings, no byes, a
  fixed round count.

  That gap mattered more than it looks. The three-way harness exists to
  measure how far the two REFERENCES agree with each other, which is the
  precision of the ruler every other number in this project is quoted with.
  Measuring that on plain tournaments only, when both known disputes in
  2.5 billion pairings are about byes, bounds the references' agreement in
  exactly the region where nobody doubted it.

  So generation lives here once, and a harness supplies only the part that
  is its own: who gets asked, and what counts as a disagreement.

  ## The seed is the whole tournament

  `begin!/3` reseeds `:rand` from the seed alone, so seed *n* produces the
  same tournament whether it is reached first or 735,264 tournaments in.
  Every dumped disagreement in `docs/` is reproducible from its seed on
  that basis, which is why the ORDER of the draws below is load-bearing:
  inserting a random call before an existing one renumbers every tournament
  in every corpus this project has ever run. The code here was moved
  verbatim out of the two-way harness for that reason, comments included,
  rather than tidied on the way.

  ## Knobs

  All read from the environment, all optional:

  `PAIRING_FUZZ_ROUNDS`/`_ROUNDS_MAX`, `_MIN_PLAYERS`/`_MAX_PLAYERS`,
  `_BYE_PCT`, `_FORFEIT_PCT`, `_FORBIDDEN_PCT`, `_ACCEL`,
  `_INITIAL_COLOUR`, `_NUMERIC_EXT`, `_RATING_MODE`, `_WITHDRAW_PCT`.

  `_ROUNDS_MAX`, `_ACCEL=mixed`, `_INITIAL_COLOUR=mixed`,
  `_NUMERIC_EXT=mixed` and `_RATING_MODE=mixed` each draw PER TOURNAMENT
  rather than fixing a value for the run, which is what explores
  combinations nobody thought to write down.
  """

  @doc """
  Seeds the generator, resolves this tournament's per-tournament modes, and
  builds its opening roster.

  Returns `{rounds, player_count, forbidden, roster}` - `rounds` because
  `PAIRING_FUZZ_ROUNDS_MAX` may have drawn a different count than asked
  for.
  """
  def begin!(seed, rounds, player_range) do
    :rand.seed(:exsss, {seed, seed * 7919, seed * 104_729})

    # Modes that used to be fixed for a whole run can now be drawn PER
    # TOURNAMENT. Resolved here, once, and stashed in the process dictionary:
    # every tournament runs in its own Task, so a stash is private to it and
    # every helper reading it inside that tournament sees one consistent set
    # of values. Resolving them at each call site instead would let a single
    # tournament be built as White and scored as Black.
    #
    # This exists because a grid of fixed-value axes only tests the
    # combinations somebody thought to write down. Drawing per tournament
    # explores the space, which is what finds a bug that needs a forfeit AND
    # an upfloat AND a short tournament at once.
    Process.put(:fuzz_initial_colour, resolve_initial_colour())
    Process.put(:fuzz_accel, resolve_accel())
    Process.put(:fuzz_numeric, resolve_numeric())
    Process.put(:fuzz_rating_mode, resolve_rating_mode())
    Process.put(:fuzz_withdrawn, MapSet.new())
    rounds = resolve_rounds(rounds)

    player_count = Enum.random(player_range)
    forbidden = forbidden_pairs(player_count)
    roster = player_count |> initial_roster() |> accelerate(rounds)

    # Last, and only drawing when the axis is switched on: everything above
    # has to keep consuming `:rand` in exactly the order it did before.
    Process.put(:fuzz_point_system, resolve_point_system())

    {rounds, player_count, forbidden, roster}
  end

  # Rating shape, which every corpus before 2026-08-23 held constant at
  # "uniform 1000..2800". That draw makes every player RATED and makes ties
  # incidental - roughly the opposite of real chess, where a junior event is
  # entirely unrated and a club field sits on a handful of rounded numbers.
  #
  # It matters because equal ratings put the INITIAL RANKING on a different
  # path: not "sort by rating" but whatever breaks the tie. That ranking is
  # the foundation of every bracket in every round, so two engines breaking
  # it differently disagree about everything afterwards.
  defp rating_for(mode) do
    case mode do
      "equal" -> 1600
      "clustered" -> Enum.random(1580..1620)
      "unrated" -> if(:rand.uniform(2) == 1, do: 0, else: Enum.random(1000..2800))
      "all_unrated" -> 0
      _spread -> Enum.random(1000..2800)
    end
  end

  defp resolve_rating_mode do
    case System.get_env("PAIRING_FUZZ_RATING_MODE") do
      "mixed" -> Enum.random(~w(spread clustered equal unrated all_unrated))
      other -> other || "spread"
    end
  end

  def initial_roster(player_count) do
    mode = Process.get(:fuzz_rating_mode, "spread")

    for i <- 1..player_count do
      %{rank: i, name: "P#{i}", fide_rating: rating_for(mode), points: 0.0, games: []}
    end
    |> Enum.shuffle()
    |> Enum.with_index(1)
    |> Enum.map(fn {p, i} -> %{p | rank: i} end)
  end

  # One forbidden opponent for each selected player, as a two-id `XXP`
  # group. Chosen once for the whole tournament and deliberately allowed to
  # over-constrain the field - bbpPairings answers an impossible round with
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
  # round's TRF unchanged - the full round-by-round record JaVaFo's manual
  # requires, and the same list `Ainalrami.Trf.parse/1` hands the engine.
  # `:baku` is FIDE C.04.7; `:random` exists because Baku alone only ever
  # produces two distinct acceleration values in one flat block, which
  # exercises far less of the bracket machinery than arbitrary per-player
  # histories do.
  defp accelerate(players, rounds) do
    case Process.get(:fuzz_accel, System.get_env("PAIRING_FUZZ_ACCEL")) do
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

  # What a result is WORTH, which every corpus before 2026-08-24 held at the
  # standard 1 / 0.5 / 0 without ever saying so.
  #
  # It is the deepest constant this harness had left. Points decide a
  # player's score, score decides which bracket they are paired in, and the
  # bracket decides everything after that - so an engine reading these
  # differently does not report different totals, it pairs a different
  # tournament. `half_bye` is the one a real organiser reaches for: FIDE
  # permits valuing the pairing-allocated bye at half a point, which moves
  # its recipient into a different score group for every remaining round.
  #
  # `double` is deliberately a no-op in disguise: scaling everything by two
  # cannot reorder anybody, so any disagreement it produces is a unit bug
  # rather than a rules one - `(playedRounds * pointsForWin) >> 1` is
  # exactly the kind of expression that gets written as `rounds / 2`.
  @point_systems %{
    "standard" => nil,
    "half_bye" => %{pairing_allocated_bye: 0.5},
    "double" => %{win: 2.0, draw: 1.0, pairing_allocated_bye: 2.0},
    "football" => %{win: 3.0, draw: 1.0, pairing_allocated_bye: 3.0},
    "paid_loss" => %{loss: 0.5},
    "paid_forfeit" => %{forfeit_loss: 0.5, zero_point_bye: 0.5}
  }

  @doc "The named point systems this harness can generate."
  def point_system_names, do: Map.keys(@point_systems)

  @doc """
  This tournament's point system, or `nil` for the standard one.

  `nil` rather than the default map so that a run which sets nothing
  serialises byte-identically to before this axis existed - no `BB*` lines,
  no change to any file bbpPairings has already validated.
  """
  def point_system, do: Process.get(:fuzz_point_system)

  def result_points(result) do
    case point_system() do
      nil -> Ainalrami.Trf.points_for(result)
      system -> Ainalrami.Trf.points_for(result, system)
    end
  end

  # Consumes randomness ONLY for "mixed". Unset or a fixed name makes no
  # `:rand` call at all, so every seed in every existing corpus still
  # produces the tournament it produced before this was added - the
  # constraint described in the moduledoc.
  defp resolve_point_system do
    case System.get_env("PAIRING_FUZZ_POINT_SYSTEM") do
      nil -> nil
      "mixed" -> named_point_system(Enum.random(Enum.sort(Map.keys(@point_systems))))
      name -> named_point_system(name)
    end
  end

  defp named_point_system(name) do
    case Map.fetch(@point_systems, name) do
      {:ok, nil} ->
        nil

      {:ok, overrides} ->
        Map.merge(Ainalrami.Trf.default_point_system(), overrides)

      :error ->
        raise "PAIRING_FUZZ_POINT_SYSTEM must be one of " <>
                Enum.join(Enum.sort(Map.keys(@point_systems)), ", ") <>
                " or \"mixed\", got #{inspect(name)}"
    end
  end

  # `152` (TRF-2026's native initial-piece-colour field): unlike javafo,
  # bbpPairings does not choose the very first round's colour on its own -
  # it requires the initial colour to be specified whenever no player has
  # one recorded yet, or it refuses to pair at all ("Please configure the
  # initial piece colors").
  #
  # It carries `initial_colour/0`, and did NOT until 2026-08-24. The colour
  # axis was added on 08-17 to stop this line being hardcoded to White, and
  # only half of it landed: the drawn colour reached `Pairing` through the
  # harness's options and never reached the FILE, so on every Black
  # tournament the reference was told White while this engine was told
  # Black. Pairing rates survived that - `normalize/1` sorts colour out of
  # the comparison, and each round's recorded colours come from the
  # reference's own answer - but the separate colour-mismatch instrument was
  # counting a disagreement the harness had manufactured.
  # `PAIRING_FUZZ_NUMERIC_EXT=1` swaps JaVaFo's free-form `XXA`/`XXP` for
  # bbpPairings' own fixed-column `250`/`260`. Worth an axis because
  # bbpPairings is the implementation that DEFINES those two lines, and
  # until now they were exercised only by unit tests written from its
  # source -- nothing had ever handed the real binary a `250` we wrote.
  # The first attempt was rejected outright (`Invalid line`), which is
  # the whole argument for generating them rather than asserting them.
  def build_trf(players, total_rounds, forbidden) do
    numeric? =
      case Process.get(:fuzz_numeric) do
        nil -> System.get_env("PAIRING_FUZZ_NUMERIC_EXT") in ["1", "true"]
        stashed -> stashed
      end

    Ainalrami.Trf.serialize(
      %{
        tournament: %{
          name: "Fuzz",
          type: "swiss",
          forbidden_pairs: forbidden,
          number_of_rounds: total_rounds,
          point_system: point_system()
        },
        players: players
      },
      numeric_extensions: numeric?
    ) <> "152 #{initial_colour()}\r\nXXR #{total_rounds}\r\n"
  end

  # A withdrawal is a Z for every remaining round - the same shape as a
  # requested zero-point bye, which is why it reuses this machinery rather
  # than inventing a second one. Real events have them (someone drops out
  # after round 3) and no corpus here has ever generated one, so the TRF
  # construct that expresses it has never been read by bbpPairings from a
  # file this project produced.
  # Players drop out DURING an event, never before it - a withdrawal in
  # round 1 is just a smaller tournament and tests nothing. From round 2 on,
  # each remaining player may leave; once gone they stay gone, which is what
  # makes this different from a run of requested byes.
  #
  # Capped at half the field: past that the tail rounds have nobody left to
  # pair and the run measures deadlock handling rather than pairing.
  def withdraw_some(round, player_count) do
    pct = env_int("PAIRING_FUZZ_WITHDRAW_PCT", 0)

    if pct > 0 and round > 1 do
      withdrawn = Process.get(:fuzz_withdrawn, MapSet.new())
      cap = div(player_count, 2)

      new =
        Enum.reduce(1..player_count, withdrawn, fn rank, acc ->
          if MapSet.size(acc) < cap and not MapSet.member?(acc, rank) and
               :rand.uniform(100) <= pct do
            MapSet.put(acc, rank)
          else
            acc
          end
        end)

      Process.put(:fuzz_withdrawn, new)
    end
  end

  def assign_requested_byes(players) do
    pct = env_int("PAIRING_FUZZ_BYE_PCT", 0)
    withdrawn = Process.get(:fuzz_withdrawn, MapSet.new())

    players =
      Enum.map(players, fn player ->
        if MapSet.member?(withdrawn, player.rank) do
          %{player | games: player.games ++ [%{opponent_rank: nil, colour: nil, result: "Z"}]}
        else
          player
        end
      end)

    if pct == 0 do
      players
    else
      Enum.map(players, fn player ->
        if not MapSet.member?(withdrawn, player.rank) and :rand.uniform(100) <= pct do
          result = Enum.random(~w(H Z))

          %{
            player
            | points: player.points + result_points(result),
              games: player.games ++ [%{opponent_rank: nil, colour: nil, result: result}]
          }
        else
          player
        end
      end)
    end
  end

  def simulate_results(pairs) do
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

  def apply_round(players, pairs, results) do
    games_by_rank = games_by_rank(pairs, results)

    Enum.map(players, fn p ->
      case Map.fetch(games_by_rank, p.rank) do
        {:ok, game} ->
          %{p | points: p.points + result_points(game.result), games: p.games ++ [game]}

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
    {%{opponent_rank: nil, colour: nil, result: "U"}, nil}
  end

  defp games_for(white, black, :white_win) do
    {
      %{opponent_rank: black, colour: "w", result: "1"},
      %{opponent_rank: white, colour: "b", result: "0"}
    }
  end

  defp games_for(white, black, :black_win) do
    {
      %{opponent_rank: black, colour: "w", result: "0"},
      %{opponent_rank: white, colour: "b", result: "1"}
    }
  end

  defp games_for(white, black, :white_forfeits) do
    {
      %{opponent_rank: black, colour: "w", result: "-"},
      %{opponent_rank: white, colour: "b", result: "+"}
    }
  end

  defp games_for(white, black, :black_forfeits) do
    {
      %{opponent_rank: black, colour: "w", result: "+"},
      %{opponent_rank: white, colour: "b", result: "-"}
    }
  end

  defp games_for(white, black, :double_forfeit) do
    {
      %{opponent_rank: black, colour: "w", result: "-"},
      %{opponent_rank: white, colour: "b", result: "-"}
    }
  end

  defp games_for(white, black, :draw) do
    {
      %{opponent_rank: black, colour: "w", result: "="},
      %{opponent_rank: white, colour: "b", result: "="}
    }
  end

  def normalize(pairs) do
    pairs
    |> Enum.map(fn {a, b} -> Enum.sort_by([a, b], &(&1 || :infinity)) end)
    |> Enum.sort()
  end

  # C.04.3 5.1's initial colour. `PAIRING_FUZZ_INITIAL_COLOUR=B` runs the
  # corpus with Black drawn instead, which no axis did before 2026-08-17 -
  # and, because `build_trf/3` kept writing `152 W` until 2026-08-24, no axis
  # put Black in front of BOTH engines before then.
  # Each of these reads the value stashed for THIS tournament, falling back
  # to the environment so a run that sets nothing behaves exactly as before.
  def initial_colour, do: Process.get(:fuzz_initial_colour) || env_initial_colour()

  defp env_initial_colour, do: System.get_env("PAIRING_FUZZ_INITIAL_COLOUR", "W")

  # "mixed" draws per tournament. Anything else is used as-is, so W/B still
  # pin a whole run the way they always did.
  defp resolve_initial_colour do
    case String.downcase(env_initial_colour()) do
      "mixed" -> Enum.random(["W", "B"])
      _ -> env_initial_colour()
    end
  end

  defp resolve_accel do
    case System.get_env("PAIRING_FUZZ_ACCEL") do
      "mixed" -> Enum.random([nil, "baku", "random"])
      other -> other
    end
  end

  defp resolve_numeric do
    case System.get_env("PAIRING_FUZZ_NUMERIC_EXT") do
      "mixed" -> Enum.random([true, false])
      other -> other in ["1", "true"]
    end
  end

  # `PAIRING_FUZZ_ROUNDS_MAX` turns the round count into a RANGE drawn per
  # tournament. Unset keeps the single fixed value, so every previous run
  # description still means what it said.
  defp resolve_rounds(rounds) do
    case System.get_env("PAIRING_FUZZ_ROUNDS_MAX") do
      nil ->
        rounds

      raw ->
        case Integer.parse(raw) do
          {max, ""} when max >= rounds -> Enum.random(rounds..max)
          _ -> raise "PAIRING_FUZZ_ROUNDS_MAX must be an integer >= PAIRING_FUZZ_ROUNDS"
        end
    end
  end

  def env_int(name, default) do
    name |> System.get_env(to_string(default)) |> String.to_integer()
  end
end
