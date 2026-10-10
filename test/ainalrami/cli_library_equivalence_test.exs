defmodule Ainalrami.CLILibraryEquivalenceTest do
  @moduledoc """
  The standalone CLI against the library, option by option.

  Every pairing option OpenPairings hands the engine through the library
  API has a flag, a TRF record, or both (docs/cli-parity.md). This file
  holds the two to the same answer: a corpus of generated tournaments, each
  cut back to before one of its rounds, is paired through the library with
  an option and through `ainalrami -p` with the equivalent flags or
  records, and the boards have to be the same boards in the same order.

    * one option at a time, on every position of the corpus;
    * two at a time, every compatible pair of options;
    * through the file: the organiser's options written as `XXO`,
      read back, paired, and a whole event played under them and then
      replayed by `-c`;
    * teams (C.04.6) and the standings (`-s`, `XXO round-ratings`).

  The library side builds its options and its players by hand here - not
  with `Ainalrami.PairingInput` or `Ainalrami.Acceleration`, which the CLI
  uses - so an error in those shows up as a difference rather than as two
  matching mistakes.

  `AINALRAMI_CLI_PARITY_SEEDS` sets the corpus size (default 200
  tournaments; the pairwise test uses a slice of it per pair).
  """
  # Not async: `capture_io(:stderr, ...)` is VM-wide.
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Ainalrami.{
    ByePreference,
    CLI,
    EventFormat,
    Generator,
    Pairing,
    PairingInput,
    TeamGenerator,
    TeamPairing,
    TeamReplay,
    Tiebreaks,
    Trf
  }

  alias Ainalrami.Pairing.NoValidPairingError

  @moduletag timeout: 900_000

  @seeds (case Integer.parse(System.get_env("AINALRAMI_CLI_PARITY_SEEDS") || "") do
            {n, ""} when n >= 20 -> n
            _ -> 200
          end)

  # ---- the corpus ------------------------------------------------------------

  setup_all do
    dir = Path.join(System.tmp_dir!(), "ainalrami_equiv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    positions =
      1..@seeds
      |> Task.async_stream(&position(&1, dir), timeout: :infinity, max_concurrency: 4)
      |> Enum.map(fn {:ok, position} -> position end)

    {:ok, positions: positions, dir: dir}
  end

  # One tournament per seed - small fields on odd seeds, medium on even -
  # cut back to before one of its rounds (round 1 included, and the round
  # after the last one played).
  defp position(seed, dir) do
    players = if rem(seed, 2) == 1, do: 5 + rem(seed * 7, 12), else: 17 + rem(seed * 11, 44)
    rounds = 3 + rem(seed, 5)

    {text, _} =
      Generator.generate(
        seed: seed,
        players: players,
        rounds: rounds,
        forfeit_pct: rem(seed, 3) * 4,
        requested_bye_pct: rem(seed, 4) * 3,
        forbidden_pct: if(rem(seed, 5) == 0, do: 10, else: 0)
      )

    full = Trf.parse(text)
    played = full.players |> Enum.map(&length(&1.games)) |> Enum.max()
    k = 1 + rem(seed * 13, played + 1)

    cut = cut(full, k)
    path = Path.join(dir, "s#{seed}.trf")
    File.write!(path, Trf.serialize(cut))
    parsed = Trf.parse(File.read!(path))

    %{
      seed: seed,
      path: path,
      parsed: parsed,
      players: parsed.players,
      tournament: parsed.tournament,
      round: Trf.rounds_played(parsed.players) + 1,
      ranks: Enum.map(parsed.players, & &1.rank),
      free:
        for(p <- parsed.players, length(p.games) <= Trf.rounds_played(parsed.players), do: p.rank)
    }
  end

  # The file as it stood before round `k` was paired.
  defp cut(parsed, k) do
    players = EventFormat.before_round(parsed.players, k, parsed.tournament[:point_system])
    tournament = Map.drop(parsed.tournament, [:tie_breaks, :standings_order, :byes])
    %{parsed | players: Enum.map(players, &Map.put(&1, :final_rank, nil)), tournament: tournament}
  end

  # ---- the two sides ---------------------------------------------------------

  # What OpenPairings' `ainalrami_opts/3` builds from the file.
  defp base_opts(t) do
    [
      expected_rounds: t[:number_of_rounds],
      forbidden_pairs: t[:forbidden_pairs],
      point_system: t[:point_system],
      initial_colour: t[:initial_colour]
    ]
  end

  defp lib_pair({players, opts, prefs}) do
    cond do
      opts[:groups] ->
        opts = if prefs == [], do: opts, else: opts ++ [bye_preferences: prefs]
        EventFormat.pair_next_round(players, opts)

      prefs == [] ->
        Pairing.pair_next_round(players, opts)

      true ->
        players |> ByePreference.pair(opts ++ [bye_preferences: prefs]) |> elem(0)
    end
  rescue
    NoValidPairingError -> :no_pairing
    ByePreference.RefusedError -> :no_pairing
    EventFormat.Error -> :no_pairing
  end

  # `-p` to a file, quietly: the boards, `:no_pairing` for a round the
  # engine refuses, `{:usage, stderr}` for anything else that exits 1.
  defp cli_pair(path, flags) do
    out = path <> ".out"
    File.rm(out)
    ref = make_ref()

    err =
      capture_io(:stderr, fn -> Process.put(ref, CLI.run([path, "-p", out, "-q" | flags])) end)

    case Process.get(ref) do
      0 ->
        pairs_of(File.read!(out))

      code ->
        # A refused round is an error and nothing else; a usage error
        # prints the help, and is a failure of this test's own flags.
        if err =~ "Usage:" or err =~ "unexpected error",
          do: {:failed, code, err},
          else: :no_pairing
    end
  end

  defp pairs_of(output) do
    [_count | lines] = String.split(output, "\r\n", trim: true)

    Enum.map(lines, fn line ->
      [a, b] = line |> String.split() |> Enum.map(&String.to_integer/1)
      {a, if(b == 0, do: nil, else: b)}
    end)
  end

  defp cli(args) do
    ref = make_ref()

    out =
      capture_io(fn ->
        capture_io(:stderr, fn -> Process.put(ref, CLI.run(args)) end) |> IO.write()
      end)

    {out, Process.get(ref)}
  end

  # ---- the options -----------------------------------------------------------
  #
  # Each is `{flags, fun}`: the command line's spelling, and what it does
  # to the library's `{players, opts, bye preferences}`.

  defp put_opt(key, value), do: fn {pl, o, pr} -> {pl, Keyword.put(o, key, value), pr} end

  defp some(list, limit) do
    list |> Enum.shuffle() |> Enum.take(:rand.uniform(max(min(limit, length(list)), 1)))
  end

  # Rounds a per-player setting applies to: all of them, some that include
  # the round being paired, or some that do not.
  defp rounds_spec(round) do
    case :rand.uniform(4) do
      1 -> :all
      2 -> Enum.uniq([round, round + 1 + :rand.uniform(2)])
      3 -> Enum.sort(Enum.uniq([max(round - 1, 1), round, round + 2]))
      4 -> [round + 1, round + 3]
    end
  end

  defp ranked(rank, :all), do: "#{rank}"
  defp ranked(rank, rounds), do: "#{rank}@#{Enum.join(rounds, "+")}"

  # Groups of players for `--forbidden=` and `--soft-pairs=`, some limited
  # to a range of rounds that may or may not hold the round being paired.
  defp groups(pos) do
    for _ <- 1..:rand.uniform(3), length(pos.ranks) >= 2 do
      ranks =
        pos.ranks |> Enum.shuffle() |> Enum.take(1 + :rand.uniform(min(3, length(pos.ranks) - 1)))

      case :rand.uniform(4) do
        1 -> {ranks, pos.round, pos.round}
        2 -> {ranks, max(pos.round - 1, 1), pos.round + 2}
        3 -> {ranks, pos.round + 1, pos.round + 2}
        4 -> ranks
      end
    end
  end

  defp group_text({ranks, n, n}), do: Enum.join(ranks, ",") <> "@#{n}"
  defp group_text({ranks, a, b}), do: Enum.join(ranks, ",") <> "@#{a}-#{b}"
  defp group_text(ranks), do: Enum.join(ranks, ",")

  defp option(:rounds, pos) do
    n = pos.round + :rand.uniform(3) - 1
    {["--rounds=#{n}"], put_opt(:expected_rounds, n)}
  end

  defp option(:initial_colour, _pos) do
    word = Enum.random(~w(white black w b))
    {["--initial-colour=#{word}"], put_opt(:initial_colour, String.first(word))}
  end

  defp option(:points, pos) do
    {text, given} =
      Enum.random([
        {"3,1,0", %{win: 3.0, draw: 1.0, loss: 0.0, pairing_allocated_bye: 3.0}},
        {"2,1,0", %{win: 2.0, draw: 1.0, loss: 0.0, pairing_allocated_bye: 2.0}},
        {"win:3,draw:1,bye:1", %{win: 3.0, draw: 1.0, pairing_allocated_bye: 1.0}},
        {"draw:0.25,forfeit-loss:0.5,zero-bye:0.25",
         %{draw: 0.25, forfeit_loss: 0.5, zero_point_bye: 0.25}},
        {"bye:0.5,half-bye:0.25", %{pairing_allocated_bye: 0.5, half_point_bye: 0.25}}
      ])

    system = Map.merge(pos.tournament[:point_system] || Trf.default_point_system(), given)

    {["--points=#{text}"],
     fn {players, opts, prefs} ->
       players =
         Enum.map(players, fn p ->
           %{p | points: Enum.sum(Enum.map(p.games, &Trf.points_for_game(&1, system))) / 1}
         end)

       {players, Keyword.put(opts, :point_system, system), prefs}
     end}
  end

  defp option(:forbidden, pos) do
    groups = groups(pos)

    {if(groups == [],
       do: [],
       else: ["--forbidden=" <> Enum.map_join(groups, "/", &group_text/1)]
     ),
     fn {pl, o, pr} -> {pl, Keyword.update!(o, :forbidden_pairs, &((&1 || []) ++ groups)), pr} end}
  end

  defp option(soft, pos) when soft in [:soft_strong, :soft_weak, :soft_default] do
    groups = groups(pos)

    {position, flag} =
      case soft do
        :soft_strong -> {:strong, ["--soft-position=strong"]}
        :soft_weak -> {:weak, ["--soft-position=weak"]}
        :soft_default -> {:strong, []}
      end

    if groups == [] do
      {[], & &1}
    else
      {["--soft-pairs=" <> Enum.map_join(groups, "/", &group_text/1) | flag],
       fn {pl, o, pr} -> {pl, o ++ [soft_pairs: groups, soft_position: position], pr} end}
    end
  end

  defp option(:bye_exclude, pos) do
    entries =
      for rank <- some(pos.ranks, div(length(pos.ranks), 2) + 1),
          do: {rank, rounds_spec(pos.round)}

    active = for {rank, rounds} <- entries, rounds == :all or pos.round in rounds, do: rank

    {["--bye-exclude=" <> Enum.map_join(entries, ",", fn {r, s} -> ranked(r, s) end)],
     fn {pl, o, pr} ->
       {pl, if(active == [], do: o, else: o ++ [bye_exclusions: Enum.sort(active)]), pr}
     end}
  end

  defp option(pref, pos) when pref in [:want_hard, :want_soft, :avoid_hard, :avoid_soft] do
    flag =
      %{
        want_hard: "bye-want",
        want_soft: "bye-want-soft",
        avoid_hard: "bye-avoid",
        avoid_soft: "bye-avoid-soft"
      }[pref]

    entries = for rank <- some(pos.ranks, 3), do: {rank, rounds_spec(pos.round)}

    prefs =
      Enum.map(entries, fn
        {rank, :all} -> {rank, pref}
        {rank, rounds} -> {rank, pref, rounds}
      end)

    {["--#{flag}=" <> Enum.map_join(entries, ",", fn {r, s} -> ranked(r, s) end)],
     fn {pl, o, pr} -> {pl, o, pr ++ prefs} end}
  end

  defp option(:cascade, _pos) do
    {["--cascade-order"], fn {pl, o, pr} -> {pl, o ++ [cascade_order: true], pr} end}
  end

  # C.04.7, written out again here rather than called: Group A the top
  # 2 * ceil(n / 4), ceil(R / 2) accelerated rounds, the first half of them
  # (rounded up) a point and the rest a half.
  defp option(:baku, pos) do
    total = max(pos.tournament[:number_of_rounds] || 0, pos.round)
    n = length(pos.ranks)
    explicit = if :rand.uniform(3) == 1, do: Enum.random(pos.ranks)
    last = explicit || pos.ranks |> Enum.sort() |> Enum.at(min(n, 2 * div(n + 3, 4)) - 1)
    accelerated = div(total + 1, 2)
    full = div(accelerated + 1, 2)

    points =
      for r <- 1..max(total, pos.round) do
        cond do
          r <= full -> 1.0
          r <= accelerated -> 0.5
          true -> 0.0
        end
      end

    {["--acceleration=baku", "--rounds=#{total}"] ++
       if(explicit, do: ["--baku-group-a=#{explicit}"], else: []),
     fn {players, opts, prefs} ->
       players =
         Enum.map(players, fn p ->
           if p.rank <= last, do: Map.put(p, :accelerations, points), else: p
         end)

       {players, Keyword.put(opts, :expected_rounds, total), prefs}
     end}
  end

  defp option(:virtual_points, pos) do
    table =
      for rank <- some(pos.ranks, length(pos.ranks)), into: %{} do
        {rank, for(_ <- 1..pos.round, do: Enum.random([0.0, 0.5, 1.0, 1.5]))}
      end

    text =
      Enum.map_join(table, "/", fn {rank, values} ->
        "#{rank}:" <> Enum.map_join(values, ",", &:erlang.float_to_binary(&1, decimals: 1))
      end)

    {["--virtual-points=#{text}"],
     fn {players, opts, prefs} ->
       players =
         Enum.map(players, fn p ->
           if v = table[p.rank], do: Map.put(p, :accelerations, v), else: p
         end)

       {players, opts, prefs}
     end}
  end

  # Byes asked for in the round being paired - only by players the file has
  # nothing for in that round yet.
  defp option(:byes, pos) do
    byes =
      for rank <- some(pos.free, 3), pos.free != [] do
        {rank, Enum.random(~w(H Z F))}
      end

    flags =
      for {type, name} <- [{"H", "half-bye"}, {"Z", "zero-bye"}, {"F", "full-bye"}],
          ranks = for({rank, ^type} <- byes, do: rank),
          ranks != [] do
        "--#{name}=" <> Enum.join(ranks, ",")
      end

    {flags,
     fn {players, opts, prefs} ->
       system = opts[:point_system] || Trf.default_point_system()
       played = pos.round - 1
       wanted = Map.new(byes)

       players =
         Enum.map(players, fn p ->
           case wanted[p.rank] do
             nil ->
               p

             type ->
               blank = %{opponent_rank: nil, colour: nil, result: nil}
               pad = List.duplicate(blank, played - length(p.games))
               game = %{opponent_rank: nil, colour: nil, result: type}

               %{
                 p
                 | games: p.games ++ pad ++ [game],
                   points: p.points + Trf.points_for(type, system)
               }
           end
         end)

       {players, opts, prefs}
     end}
  end

  defp option(:groups, pos) do
    sorted = Enum.sort(pos.ranks)
    {a, b} = Enum.split(sorted, max(div(length(sorted), 2), 1))
    groups = Enum.reject([a, b], &(&1 == []))

    {["--groups=" <> Enum.map_join(groups, "/", &Enum.join(&1, ","))],
     fn {pl, o, pr} -> {pl, o ++ [groups: groups], pr} end}
  end

  @options [
    :rounds,
    :initial_colour,
    :points,
    :forbidden,
    :soft_default,
    :soft_strong,
    :soft_weak,
    :bye_exclude,
    :want_hard,
    :want_soft,
    :avoid_hard,
    :avoid_soft,
    :cascade,
    :baku,
    :virtual_points,
    :byes,
    :groups
  ]

  # Byes are recorded before the scores move, and before anything reads
  # the roster; the order the CLI applies its flags in.
  @order Map.new(Enum.with_index([:points, :byes, :baku, :virtual_points]))

  defp compatible?(a, b) do
    pair = Enum.sort([a, b])
    soft = [:soft_default, :soft_strong, :soft_weak]

    pair != [:baku, :virtual_points] and pair != [:baku, :rounds] and
      not (a in soft and b in soft)
  end

  defp seed!(pos, names) do
    :rand.seed(:exsss, {pos.seed, :erlang.phash2(names), 20_261_010})
  end

  # Pairs `pos` under `names` both ways and returns `{library, cli, flags}`.
  defp both(pos, names) do
    seed!(pos, names)
    specs = Enum.map(names, &{&1, option(&1, pos)})
    flags = Enum.flat_map(specs, fn {_name, {flags, _fun}} -> flags end)

    state =
      specs
      |> Enum.sort_by(fn {name, _} -> Map.get(@order, name, 99) end)
      |> Enum.reduce({pos.players, base_opts(pos.tournament), []}, fn {_name, {_flags, fun}},
                                                                      acc ->
        fun.(acc)
      end)

    {lib_pair(state), cli_pair(pos.path, flags), flags}
  end

  defp describe_position(pos, flags) do
    "seed #{pos.seed}, round #{pos.round}, #{length(pos.ranks)} players: " <>
      "ainalrami #{Path.basename(pos.path)} -p #{Enum.join(flags, " ")}"
  end

  # ---- (a) one option at a time ---------------------------------------------

  test "no option: the CLI's round is the library's on every position", %{positions: positions} do
    for pos <- positions do
      {lib, cli, flags} = both(pos, [])
      assert cli == lib, describe_position(pos, flags)
    end
  end

  for name <- @options do
    @tag option: name
    @tag must_move: name != :rounds
    test "#{name}: the CLI's flags give the library's round on every position", %{
      positions: positions,
      must_move: must_move
    } do
      name = unquote(name)

      {compared, moved} =
        Enum.reduce(positions, {0, 0}, fn pos, {compared, moved} ->
          {lib, cli, flags} = both(pos, [name])
          assert cli == lib, describe_position(pos, flags)

          plain = lib_pair({pos.players, base_opts(pos.tournament), []})
          {compared + 1, if(lib == plain, do: moved, else: moved + 1)}
        end)

      assert compared == length(positions)

      # An option that never changes a round over the whole corpus is an
      # option this test would pass with the flag ignored. The round count
      # is the one that hardly ever does on a random position - it matters
      # in the last round, to top scorers with a colour clash - and has a
      # test of its own below.
      if must_move do
        assert moved > 0, "#{name} changed no round in #{compared} positions"
      end
    end
  end

  # `--rounds=` where it bites: late rounds of seven-round events, paired as
  # the last round and as one with three more to come.
  test "rounds: the last round's rules follow --rounds=, as they follow :expected_rounds", %{
    dir: dir
  } do
    moved =
      for seed <- 1..max(div(@seeds, 4), 30), reduce: 0 do
        moved ->
          {text, _} = Generator.generate(seed: seed, players: 6 + rem(seed, 9), rounds: 7)
          full = Trf.parse(text)
          played = full.players |> Enum.map(&length(&1.games)) |> Enum.max()

          for k <- 4..7//1, k <= played, reduce: moved do
            moved ->
              path = Path.join(dir, "rounds_#{seed}_#{k}.trf")
              File.write!(path, Trf.serialize(cut(full, k)))
              parsed = Trf.parse(File.read!(path))

              [last, more] =
                for n <- [k, k + 3] do
                  opts = Keyword.put(base_opts(parsed.tournament), :expected_rounds, n)
                  lib = lib_pair({parsed.players, opts, []})
                  assert cli_pair(path, ["--rounds=#{n}"]) == lib, "seed #{seed} round #{k}, #{n}"
                  lib
                end

              if last == more, do: moved, else: moved + 1
          end
      end

    assert moved > 0
  end

  # ---- (b) two at a time ------------------------------------------------------

  test "every compatible pair of options: the CLI's round is the library's", %{
    positions: positions
  } do
    pairs = for a <- @options, b <- @options, a < b, compatible?(a, b), do: [a, b]
    per_pair = max(div(length(positions), 6), 20)

    compared =
      pairs
      |> Enum.with_index()
      |> Enum.map(fn {names, index} ->
        slice =
          positions
          |> Stream.cycle()
          |> Stream.drop(rem(index * 7, length(positions)))
          |> Enum.take(per_pair)

        for pos <- slice do
          {lib, cli, flags} = both(pos, names)
          assert cli == lib, describe_position(pos, flags)
        end

        length(slice)
      end)
      |> Enum.sum()

    assert compared == length(pairs) * per_pair
    assert length(pairs) == 131
  end

  test "three and four options together", %{positions: positions} do
    sets = [
      [:forbidden, :soft_weak, :bye_exclude],
      [:points, :byes, :want_soft],
      [:baku, :avoid_hard, :cascade],
      [:rounds, :initial_colour, :virtual_points, :avoid_soft],
      [:groups, :forbidden, :want_hard, :points],
      [:soft_strong, :bye_exclude, :want_hard, :byes]
    ]

    for names <- sets, pos <- Enum.take_every(positions, 4) do
      {lib, cli, flags} = both(pos, names)
      assert cli == lib, describe_position(pos, flags)
    end
  end

  # ---- (c) through the file ---------------------------------------------------

  defp organiser(pos) do
    :rand.seed(:exsss, {pos.seed, 77, 20_261_010})
    soft = groups(pos)

    prefs =
      for rank <- some(pos.ranks, 3) do
        pref = Enum.random(ByePreference.preferences())

        case rounds_spec(pos.round) do
          :all -> {rank, pref}
          rounds -> {rank, pref, rounds}
        end
      end

    excluded =
      for rank <- some(pos.ranks, 3) do
        case rounds_spec(pos.round) do
          :all -> rank
          rounds -> {rank, rounds}
        end
      end

    position = Enum.random([:strong, :weak])

    %{
      tournament: %{
        soft_pairs: soft,
        soft_position: position,
        bye_preferences: prefs,
        bye_exclusions: excluded
      },
      opts:
        if(soft == [], do: [], else: [soft_pairs: soft, soft_position: position]) ++
          case for(
                 e <- excluded,
                 is_integer(e) or pos.round in elem(e, 1),
                 do: if(is_integer(e), do: e, else: elem(e, 0))
               ) do
            [] -> []
            ranks -> [bye_exclusions: ranks |> Enum.uniq() |> Enum.sort()]
          end,
      prefs: prefs
    }
  end

  for dialect <- [:engine, :trf26] do
    test "XXO round-trip (#{dialect}): written, read back, and paired like the library",
         %{positions: positions, dir: dir} do
      dialect = unquote(dialect)

      moved =
        for pos <- positions, reduce: 0 do
          moved ->
            organiser = organiser(pos)
            tournament = Map.merge(pos.tournament, organiser.tournament)
            text = Trf.serialize(%{pos.parsed | tournament: tournament}, dialect: dialect)
            back = Trf.parse(text)

            # The data, as it went in.
            for key <- [:soft_pairs, :bye_preferences, :bye_exclusions] do
              expected = organiser.tournament[key]

              assert (back.tournament[key] || []) |> Enum.sort() == Enum.sort(expected),
                     "#{key}, seed #{pos.seed}"
            end

            if organiser.tournament.soft_pairs != [] do
              assert back.tournament[:soft_position] == organiser.tournament.soft_position
            end

            # Written again, it is the same file.
            assert Trf.serialize(back, dialect: dialect) == text

            # The options the file gives are the options that went in.
            resolved = PairingInput.organiser_opts(back.tournament, pos.round)
            assert Keyword.delete(resolved, :bye_preferences) == organiser.opts
            assert (resolved[:bye_preferences] || []) |> Enum.sort() == Enum.sort(organiser.prefs)

            # And the round paired from the file is the library's.
            path = Path.join(dir, "rt_#{dialect}_#{pos.seed}.trf")
            File.write!(path, text)

            lib =
              lib_pair(
                {back.players, base_opts(back.tournament) ++ organiser.opts, organiser.prefs}
              )

            assert cli_pair(path, []) == lib, "seed #{pos.seed} round #{pos.round}"

            plain = lib_pair({back.players, base_opts(back.tournament), []})
            if lib == plain, do: moved, else: moved + 1
        end

      assert moved > 0
    end
  end

  test "records and flags together: the flags are added to the file's", %{
    positions: positions,
    dir: dir
  } do
    for pos <- Enum.take_every(positions, 2) do
      organiser = organiser(pos)

      text =
        Trf.serialize(%{pos.parsed | tournament: Map.merge(pos.tournament, organiser.tournament)})

      path = Path.join(dir, "both_#{pos.seed}.trf")
      File.write!(path, text)

      :rand.seed(:exsss, {pos.seed, 78, 20_261_010})
      extra_soft = groups(pos)
      extra_excluded = some(pos.ranks, 2)
      extra_pref = {Enum.random(pos.ranks), :avoid_soft}

      flags =
        if(extra_soft == [],
          do: [],
          else: ["--soft-pairs=" <> Enum.map_join(extra_soft, "/", &group_text/1)]
        ) ++
          [
            "--bye-exclude=" <> Enum.join(extra_excluded, ","),
            "--bye-avoid-soft=#{elem(extra_pref, 0)}"
          ]

      soft = organiser.tournament.soft_pairs ++ extra_soft

      excluded =
        Enum.uniq((organiser.opts[:bye_exclusions] || []) ++ extra_excluded) |> Enum.sort()

      opts =
        base_opts(pos.tournament) ++
          if(soft == [],
            do: [],
            else: [soft_pairs: soft, soft_position: organiser.tournament.soft_position]
          ) ++ [bye_exclusions: excluded]

      lib = lib_pair({pos.players, opts, organiser.prefs ++ [extra_pref]})
      assert cli_pair(path, flags) == lib, "seed #{pos.seed}: #{Enum.join(flags, " ")}"
    end
  end

  # A whole event played under the organiser's options, written with its
  # records, and replayed by the checker: every round has to come back.
  test "an event paired under XXO records passes -c, and fails it without them", %{dir: dir} do
    events = max(div(@seeds, 5), 20)

    results =
      for seed <- 1..events do
        :rand.seed(:exsss, {seed, 5, 20_261_010})
        count = 7 + rem(seed * 3, 20)
        rounds = 4 + rem(seed, 3)
        {text, _} = Generator.generate(seed: 1000 + seed, players: count, rounds: 0)
        start = Trf.parse(text)
        ranks = Enum.map(start.players, & &1.rank)
        fake = %{ranks: ranks, round: 2}

        organiser = %{
          soft_pairs: groups(fake) ++ groups(fake),
          soft_position: Enum.random([:strong, :weak]),
          bye_preferences:
            for rank <- some(ranks, 4) do
              case :rand.uniform(3) do
                1 ->
                  {rank, Enum.random(ByePreference.preferences())}

                _ ->
                  {rank, Enum.random([:want_soft, :avoid_soft, :avoid_hard]),
                   some(Enum.to_list(1..rounds), 3) |> Enum.sort()}
              end
            end,
          bye_exclusions:
            for rank <- some(ranks, 3) do
              if :rand.uniform(2) == 1,
                do: rank,
                else: {rank, Enum.sort(some(Enum.to_list(1..rounds), 3))}
            end
        }

        tournament =
          start.tournament |> Map.put(:number_of_rounds, rounds) |> Map.merge(organiser)

        base = base_opts(tournament)

        {players, moved} =
          Enum.reduce_while(1..rounds, {start.players, 0}, fn round, {players, moved} ->
            excluded =
              for e <- organiser.bye_exclusions,
                  is_integer(e) or round in elem(e, 1),
                  do: if(is_integer(e), do: e, else: elem(e, 0))

            opts =
              base ++
                if(organiser.soft_pairs == [],
                  do: [],
                  else: [soft_pairs: organiser.soft_pairs, soft_position: organiser.soft_position]
                ) ++
                if(excluded == [],
                  do: [],
                  else: [bye_exclusions: excluded |> Enum.uniq() |> Enum.sort()]
                )

            case lib_pair({players, opts, organiser.bye_preferences}) do
              :no_pairing ->
                {:halt, {players, moved}}

              pairs ->
                plain = lib_pair({players, base, []})

                {:cont,
                 {play(players, pairs),
                  if(composition(pairs) == composition(plain), do: moved, else: moved + 1)}}
            end
          end)

        with_records = Path.join(dir, "event_#{seed}.trf")

        File.write!(
          with_records,
          Trf.serialize(%{start | players: players, tournament: tournament})
        )

        without = Path.join(dir, "event_#{seed}_plain.trf")

        File.write!(
          without,
          Trf.serialize(%{
            start
            | players: players,
              tournament: Map.drop(tournament, Map.keys(organiser))
          })
        )

        {err, code} = cli([with_records, "-c", "-q"])
        assert code == 0, "seed #{seed}: #{err}"
        assert err =~ "not a pure FIDE check"

        {_err, plain_code} = cli([without, "-c", "-q"])
        if moved > 0, do: assert(plain_code == 1, "seed #{seed}: moved rounds went unnoticed")

        moved
      end

    # The records have to have mattered, or the first half proves nothing.
    assert Enum.count(results, &(&1 > 0)) >= div(events, 4)
  end

  defp composition(:no_pairing), do: :no_pairing

  defp composition(pairs) do
    pairs |> Enum.map(fn {a, b} -> Enum.sort([a || 0, b || 0]) end) |> Enum.sort()
  end

  # Plays a round: random results, the bye worth a point.
  defp play(players, pairs) do
    entries =
      Enum.flat_map(pairs, fn
        {w, nil} ->
          [{w, %{opponent_rank: nil, colour: nil, result: "U"}, 1.0}]

        {w, b} ->
          {rw, rb, pw, pb} =
            Enum.random([{"1", "0", 1.0, 0.0}, {"0", "1", 0.0, 1.0}, {"=", "=", 0.5, 0.5}])

          [
            {w, %{opponent_rank: b, colour: "w", result: rw}, pw},
            {b, %{opponent_rank: w, colour: "b", result: rb}, pb}
          ]
      end)
      |> Map.new(fn {rank, game, points} -> {rank, {game, points}} end)

    Enum.map(players, fn p ->
      {game, points} =
        Map.get(entries, p.rank, {%{opponent_rank: nil, colour: nil, result: "Z"}, 0.0})

      %{p | games: p.games ++ [game], points: p.points + points}
    end)
  end

  test "XXO round-ratings round-trips, and a file without the records parses and writes as before",
       %{
         positions: positions
       } do
    for pos <- positions do
      # Nothing new in a file that has none of it.
      for key <- [:soft_pairs, :soft_position, :bye_preferences, :bye_exclusions] do
        refute Map.has_key?(pos.tournament, key)
      end

      refute Enum.any?(pos.players, &Map.has_key?(&1, :round_ratings))
      text = Trf.serialize(pos.parsed)
      refute text =~ ~r/^XXO/m
      assert text == File.read!(pos.path)

      :rand.seed(:exsss, {pos.seed, 79, 20_261_010})

      players =
        Enum.map(pos.players, fn p ->
          ratings =
            for r <- 1..(pos.round + 1), :rand.uniform(3) > 1, into: %{} do
              {r, 1000 + :rand.uniform(1800)}
            end

          if ratings == %{}, do: p, else: Map.put(p, :round_ratings, ratings)
        end)

      for dialect <- [:engine, :trf26] do
        written = Trf.serialize(%{pos.parsed | players: players}, dialect: dialect)
        back = Trf.parse(written)

        assert Enum.map(back.players, &Map.get(&1, :round_ratings)) ==
                 Enum.map(players, &Map.get(&1, :round_ratings))

        assert Trf.serialize(back, dialect: dialect) == written
      end
    end
  end

  # ---- -c with the tournament's flags ------------------------------------------

  test "-c replays under --forbidden=, --points= and --rounds= as -p pairs under them", %{
    dir: dir
  } do
    for seed <- 1..max(div(@seeds, 8), 15) do
      rounds = 4 + rem(seed, 3)

      {text, _} =
        Generator.generate(seed: 900 + seed, players: 8 + rem(seed * 3, 20), rounds: rounds)

      path = Path.join(dir, "check_#{seed}.trf")
      File.write!(path, text)
      parsed = Trf.parse(text)
      assert {_, 0} = cli([path, "-c", "-q"])

      # What the file already says, said again: nothing changes.
      assert {_, 0} = cli([path, "-c", "-q", "--rounds=#{rounds}", "--points=1,0.5,0"])

      met =
        for p <- parsed.players, g <- p.games, g.opponent_rank != nil, p.rank < g.opponent_rank do
          {p.rank, g.opponent_rank}
        end

      ranks = Enum.map(parsed.players, & &1.rank)
      strangers = for a <- ranks, b <- ranks, a < b, {a, b} not in met, do: {a, b}

      # Two players who never met may be forbidden to: the engine did not
      # want them together anyway, and every round still comes back.
      for {a, b} <- Enum.take(strangers, 2) do
        {err, code} = cli([path, "-c", "-q", "--forbidden=#{a},#{b}"])
        assert code == 0, "seed #{seed}, #{a}-#{b}: #{err}"
      end

      # Two who did meet may not be, and the round they met in differs.
      {a, b} = hd(met)
      {err, code} = cli([path, "-c", "-q", "--forbidden=#{a},#{b}"])
      assert code == 1
      assert err =~ "DIFFERS" or err =~ "no legal pairing"

      # Limited to rounds after the last, the same rule forbids nothing.
      assert {_, 0} = cli([path, "-c", "-q", "--forbidden=#{a},#{b}@#{rounds + 1}-#{rounds + 3}"])
    end
  end

  # ---- Baku against the generator --------------------------------------------

  test "--acceleration=baku on a Baku file stripped of its XXA lines is that file", %{dir: dir} do
    for seed <- 1..max(div(@seeds, 5), 20) do
      players = 6 + rem(seed * 5, 30)

      {text, _} =
        Generator.generate(
          seed: 500 + seed,
          players: players,
          rounds: 3 + rem(seed, 6),
          acceleration: :baku
        )

      full = Trf.parse(text)
      assert Enum.any?(full.players, &(Map.get(&1, :accelerations) not in [nil, []]))

      stripped =
        text
        |> String.split("\r\n")
        |> Enum.reject(&String.starts_with?(&1, "XXA"))
        |> Enum.join("\r\n")

      refute stripped == text
      path = Path.join(dir, "baku_#{seed}.trf")
      File.write!(path, stripped)

      {err, code} = cli([path, "-c", "-q", "--acceleration=baku"])
      assert code == 0, "seed #{seed}: #{err}"

      total = full.tournament[:number_of_rounds]
      bare = Trf.parse(stripped)
      derived = Ainalrami.Acceleration.baku(bare.players, total, through: total)

      for {given, worked_out} <- Enum.zip(full.players, derived) do
        assert Map.get(given, :accelerations) == Map.get(worked_out, :accelerations),
               "seed #{seed}, rank #{given.rank}"
      end
    end
  end

  # ---- teams (C.04.6) ----------------------------------------------------------

  defp team_cut(text, k) do
    parsed = Trf.parse(text)

    players =
      Enum.map(parsed.players, fn p ->
        earlier = Enum.take(p.games, k - 1)

        games =
          case Enum.at(p.games, k - 1) do
            %{opponent_rank: nil, result: "Z"} = g -> earlier ++ [g]
            _ -> earlier
          end

        %{p | games: games, points: 0.0}
      end)

    t =
      parsed.tournament
      |> Map.drop([:standings_order, :tie_breaks, :byes])
      |> Map.update(:forfeited_matches, nil, fn l -> l && Enum.filter(l, &(&1.round < k)) end)
      |> Map.update(:board_orders, nil, fn l -> l && Enum.filter(l, &(&1.round <= k)) end)
      |> Map.update(:team_pab, nil, fn p -> p && %{p | teams: Enum.take(p.teams, k - 1)} end)
      |> Enum.reject(fn {_k, v} -> v in [nil, []] end)
      |> Map.new()

    teams = Enum.map(parsed.teams, &Map.put(&1, :final_rank, nil))
    Trf.serialize(%{parsed | players: players, tournament: t, teams: teams}, dialect: :trf26)
  end

  # The library's round for a team file under `settings` (C.04.6): the
  # matches as a sorted `{white, black}` list with `{team, 0}` for the bye,
  # or `{:error, reason}`.
  defp lib_team(parsed, overrides, extra) do
    {:team, settings} = TeamReplay.system(parsed)
    settings = Map.merge(settings, overrides)
    history = TeamReplay.history(parsed)
    next = TeamReplay.next_round(parsed, history, settings)
    expected = parsed.tournament[:number_of_rounds]

    {colour, _source} =
      TeamReplay.initial_colour(history, parsed.tournament, settings, expected_rounds: expected)

    opts =
      [
        score_mode: settings.score_mode,
        use_secondary?: settings.use_secondary?,
        type: settings.type,
        initial_colour: colour,
        absent: next.absent,
        round: next.round,
        expected_rounds: expected
      ] ++ extra

    if length(next.field) < 2 do
      {:error, :too_few}
    else
      case TeamPairing.pair_round(next.teams, opts) do
        {:ok, result} ->
          (Enum.map(result.pairs, &{&1.white, &1.black}) ++
             if(result.bye, do: [{result.bye, 0}], else: []))
          |> Enum.sort()

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp cli_team(path, flags) do
    {out, code} = cli([path, "-p", "-q" | flags])

    if code == 0 do
      [count | rest] = String.split(out, "\r\n", trim: true)

      rest
      |> Enum.take(String.to_integer(count))
      |> Enum.map(fn line ->
        [a, b] = line |> String.split() |> Enum.map(&String.to_integer/1)
        {a, b}
      end)
      |> Enum.sort()
    else
      {:exit, code, out}
    end
  end

  test "team Swiss: the settings flags give the library's round", %{dir: dir} do
    events = max(div(@seeds, 5), 20)

    {compared, moved} =
      for seed <- 1..events, reduce: {0, 0} do
        {compared, moved} ->
          :rand.seed(:exsss, {seed, 9, 20_261_010})
          teams = 5 + rem(seed * 3, 9)

          {text, _} =
            TeamGenerator.generate(system: :swiss, seed: 300 + seed, teams: teams, rounds: 5)

          played = text |> Trf.parse() |> TeamReplay.history() |> TeamReplay.paired_rounds()
          k = 1 + rem(seed * 5, played + 1)
          path = Path.join(dir, "team_#{seed}.trf")
          File.write!(path, team_cut(text, k))
          parsed = Trf.parse(File.read!(path))

          # Not what the file's 192 says, so the flag has something to change.
          {:team, file} = TeamReplay.system(parsed)
          type = Enum.random([:a, :b, :none] -- [file.type])
          score = if file.score_mode == :match_points, do: :game_points, else: :match_points
          secondary = not file.use_secondary?
          colour = Enum.random(["white", "black"])
          rounds = k + :rand.uniform(3) - 1

          numbers =
            parsed.teams
            |> Enum.with_index(1)
            |> Enum.map(fn {t, i} -> Map.get(t, :number) || i end)

          away =
            if :rand.uniform(3) == 1 and length(numbers) > 4, do: [Enum.random(numbers)], else: []

          cases = [
            {[], %{}, parsed, []},
            {["--team-type=#{%{a: "a", b: "b", none: "none"}[type]}"], %{type: type}, parsed, []},
            {["--score=#{if score == :match_points, do: "mp", else: "gp"}"], %{score_mode: score},
             parsed, []},
            {["--secondary=#{if secondary, do: "yes", else: "no"}"], %{use_secondary?: secondary},
             parsed, []},
            {["--initial-colour=#{colour}"], %{},
             put_in(parsed.tournament[:initial_colour], String.first(colour)), []},
            {["--rounds=#{rounds}"], %{}, put_in(parsed.tournament[:number_of_rounds], rounds),
             []},
            {["--max-upfloater-sets=3"], %{}, parsed, [max_upfloater_sets: 3]},
            {[
               "--team-type=b",
               "--score=gp",
               "--secondary=no",
               "--rounds=#{rounds}",
               "--initial-colour=#{colour}"
             ], %{type: :b, score_mode: :game_points, use_secondary?: false},
             parsed
             |> put_in([:tournament, :number_of_rounds], rounds)
             |> put_in([:tournament, :initial_colour], String.first(colour)), []}
          ]

          cases =
            if away == [] do
              cases
            else
              roster =
                parsed.teams
                |> Enum.with_index(1)
                |> Enum.find_value(fn {t, i} ->
                  if (Map.get(t, :number) || i) == hd(away), do: t.player_ranks
                end)

              absent =
                update_in(parsed.players, fn players ->
                  Enum.map(players, fn p ->
                    if p.rank in roster and length(p.games) < k do
                      blank = %{opponent_rank: nil, colour: nil, result: nil}
                      pad = List.duplicate(blank, k - 1 - length(p.games))

                      %{
                        p
                        | games:
                            p.games ++ pad ++ [%{opponent_rank: nil, colour: nil, result: "Z"}]
                      }
                    else
                      p
                    end
                  end)
                end)

              cases ++ [{["--absent-teams=#{hd(away)}"], %{}, absent, []}]
            end

          plain = lib_team(parsed, %{}, [])

          for {flags, overrides, input, extra} <- cases, reduce: {compared, moved} do
            {compared, moved} ->
              lib = lib_team(input, overrides, extra)
              cli = cli_team(path, flags)

              case lib do
                {:error, _} -> assert match?({:exit, 1, _}, cli), "seed #{seed} #{inspect(flags)}"
                _ -> assert cli == lib, "seed #{seed} round #{k}: #{Enum.join(flags, " ")}"
              end

              if lib != plain do
                key = flags |> List.first("") |> String.split("=") |> hd()
                Process.put({:team_moved, key}, true)
              end

              {compared + 1, if(lib == plain, do: moved, else: moved + 1)}
          end
      end

    assert compared >= events * 8
    assert moved > 0

    # Each setting has to have changed a round somewhere, or its flag could
    # be ignored and this would still pass.
    for key <- ~w(--team-type --score --initial-colour --absent-teams) do
      assert Process.get({:team_moved, key}), "#{key} changed no team round"
    end
  end

  # The secondary score breaks a first-team tie (C.04.6 4.2.2), which is
  # rare enough that the random events above never see it decide anything:
  # 2 of 600 generated events do. These are those two.
  test "team Swiss: --secondary= where the secondary score decides a colour", %{dir: dir} do
    for seed <- [90, 134] do
      {text, _} = TeamGenerator.generate(system: :swiss, seed: seed, teams: 10, rounds: 6)
      path = Path.join(dir, "secondary_#{seed}.trf")
      File.write!(path, text)
      parsed = Trf.parse(text)
      {:team, file} = TeamReplay.system(parsed)

      plain = lib_team(parsed, %{}, [])
      other = lib_team(parsed, %{use_secondary?: not file.use_secondary?}, [])
      assert plain != other

      assert cli_team(path, []) == plain
      flag = "--secondary=#{if file.use_secondary?, do: "no", else: "yes"}"
      assert cli_team(path, [flag]) == other
    end
  end

  test "team Swiss: -c with the file's own settings given as flags still passes", %{dir: dir} do
    for seed <- 1..10 do
      {text, _} = TeamGenerator.generate(system: :swiss, seed: 400 + seed, teams: 8, rounds: 4)
      path = Path.join(dir, "teamc_#{seed}.trf")
      File.write!(path, text)
      {:team, settings} = text |> Trf.parse() |> TeamReplay.system()

      flags = [
        "--team-type=#{%{a: "a", b: "b", none: "none"}[settings.type]}",
        "--score=#{if settings.score_mode == :match_points, do: "mp", else: "gp"}",
        "--secondary=#{if settings.use_secondary?, do: "yes", else: "no"}"
      ]

      assert {_, 0} = cli([path, "-c", "-q"])
      {err, code} = cli([path, "-c", "-q" | flags])
      assert code == 0, err
    end
  end

  # ---- the standings (-s, XXO round-ratings) -------------------------------------------------

  defp standings_of(output) do
    [header | rows] = String.split(output, "\r\n", trim: true)
    ["RANK", "ID" | codes] = String.split(header)

    {codes,
     Enum.map(rows, fn row ->
       [rank, id | values] = String.split(row)
       {String.to_integer(rank), String.to_integer(id), Enum.map(values, &number/1)}
     end)}
  end

  defp number("-"), do: nil

  defp number(text) do
    case Float.parse(text) do
      {f, ""} -> f
      _ -> text
    end
  end

  defp same_standings?(rows, codes, cli_rows) do
    length(rows) == length(cli_rows) and
      Enum.all?(Enum.zip(rows, cli_rows), fn {row, {rank, id, values}} ->
        row.rank == rank and row.id == id and
          Enum.all?(Enum.zip(codes, values), fn {code, value} ->
            case row.values[code] do
              nil -> value == nil
              v when is_number(v) and is_number(value) -> abs(v - value) < 1.0e-3
              v -> to_string(v) == to_string(value)
            end
          end)
      end)
  end

  @codes ~w(BH BH/C1 BH/M1 SB DE WIN WON BPG BWG PS KS ARO TPR PTP APRO APPO FB AOB TPN RTNG)

  test "-s: the standings are Tiebreaks.rank/3's, for the file's list and for --tie-breaks=",
       %{dir: dir} do
    for seed <- 1..max(div(@seeds, 4), 25) do
      :rand.seed(:exsss, {seed, 11, 20_261_010})
      codes = @codes |> Enum.shuffle() |> Enum.take(1 + :rand.uniform(4))

      {text, _} =
        Generator.generate(
          seed: 700 + seed,
          players: 6 + rem(seed * 7, 30),
          rounds: 3 + rem(seed, 5),
          forfeit_pct: 5,
          requested_bye_pct: 5
        )

      path = Path.join(dir, "st_#{seed}.trf")
      parsed = Trf.parse(text)

      # Per-round ratings on some seeds, as XXO round-ratings lines.
      parsed =
        if rem(seed, 2) == 0 do
          update_in(parsed.players, fn players ->
            Enum.map(players, fn p ->
              Map.put(
                p,
                :round_ratings,
                for(
                  r <- 1..length(p.games)//1,
                  :rand.uniform(4) > 1,
                  into: %{},
                  do: {r, 1200 + :rand.uniform(1500)}
                )
              )
            end)
          end)
        else
          parsed
        end

      File.write!(path, Trf.serialize(parsed))
      cap = Enum.random([:played, :announced])

      # Built without `from_trf/2`'s reading of XXO round-ratings and `:cap_rounds`: the
      # event from a file with no XXO round-ratings, the ratings and the cap put in by hand.
      bare = Trf.parse(text)
      event = Tiebreaks.Event.from_trf(bare)

      participants =
        Map.new(event.participants, fn {id, participant} ->
          ratings = Enum.find(parsed.players, &(&1.rank == id)) |> Map.get(:round_ratings, %{})
          {id, %{participant | round_ratings: ratings}}
        end)

      event = %{event | participants: participants, cap_rounds: cap}

      {out, code} =
        cli([path, "-s", "-q", "--tie-breaks=#{Enum.join(codes, ",")}", "--cap-rounds=#{cap}"])

      case Tiebreaks.rank(event, ["PTS" | codes], with_dropped: true) do
        {:ok, rows, dropped} ->
          assert code == 0, out
          {cli_codes, cli_rows} = standings_of(out)
          assert cli_codes == ["PTS" | codes] -- dropped

          assert same_standings?(rows, cli_codes, cli_rows),
                 "seed #{seed}: #{Enum.join(codes, ",")}"

        {:error, _reason} ->
          assert code == 1, out
      end

      # The per-round ratings have to reach the rating tie-breaks.
      if rem(seed, 2) == 0 do
        {plain_out, 0} = cli([write_plain(dir, seed, text), "-s", "-q", "--tie-breaks=ARO,TPR"])
        {with_out, 0} = cli([path, "-s", "-q", "--tie-breaks=ARO,TPR"])
        if plain_out != with_out, do: Process.put(:xxt_moved, true)
      end
    end

    assert Process.get(:xxt_moved), "XXO round-ratings changed no rating tie-break"
  end

  defp write_plain(dir, seed, text) do
    path = Path.join(dir, "st_plain_#{seed}.trf")
    File.write!(path, text)
    path
  end

  test "-s on a team file ranks the teams; -c --tie-breaks= checks the file's ranks by that list",
       %{dir: dir} do
    for seed <- 1..10 do
      {text, _} =
        TeamGenerator.generate(
          system: :swiss,
          seed: 600 + seed,
          teams: 8,
          rounds: 4,
          tie_breaks: ["MPTS", "GPTS", "EDE"]
        )

      path = Path.join(dir, "tst_#{seed}.trf")
      File.write!(path, text)
      parsed = Trf.parse(text)
      list = parsed.tournament[:standings_order] || ["PTS" | parsed.tournament[:tie_breaks]]

      {:ok, rows, dropped} =
        parsed |> Tiebreaks.Team.from_trf() |> Tiebreaks.Team.rank(list, with_dropped: true)

      {out, code} = cli([path, "-s", "-q"])
      assert code == 0, out
      {codes, cli_rows} = standings_of(out)
      assert codes == list -- dropped
      assert same_standings?(rows, codes, cli_rows)
    end

    for seed <- 1..15 do
      {text, _} =
        Generator.generate(seed: 800 + seed, players: 12, rounds: 5, tie_breaks: ["BH", "SB"])

      path = Path.join(dir, "ctb_#{seed}.trf")
      File.write!(path, text)
      assert {_, 0} = cli([path, "-c", "-q"])
      {err, code} = cli([path, "-c", "-q", "--tie-breaks=BH,SB"])
      assert code == 0, err

      # Another list is another order, and the file's ranks do not follow it.
      {_err, other} = cli([path, "-c", "-q", "--tie-breaks=TPN/R"])
      if other == 1, do: Process.put(:list_mattered, true)
    end
  end

  # ---- -x: the alternatives ----------------------------------------------------

  test "-x --judge, --bye-alternatives and --float-alternatives are Alternatives' answers", %{
    positions: positions
  } do
    for pos <- Enum.take_every(positions, 8), length(pos.ranks) <= 24 do
      opts = base_opts(pos.tournament)

      case lib_pair({pos.players, opts, []}) do
        :no_pairing ->
          :ok

        pairs ->
          judged = Enum.map_join(pairs, ",", fn {w, b} -> "#{w}-#{b || 0}" end)

          {out, code} =
            cli([
              pos.path,
              "-x",
              "-q",
              "--judge=#{judged}",
              "--bye-alternatives",
              "--float-alternatives"
            ])

          assert code == 0, out
          assert out =~ "that is the round that was paired"

          case Ainalrami.Alternatives.bye_alternatives(pos.players, pairs, opts) do
            nil ->
              assert out =~ "the round has no pairing-allocated bye"

            %{holder: holder} = result ->
              assert out =~ "Bye alternatives (the bye went to #{holder})"

              for %{rank: rank} <- Map.get(result, :candidates, []) do
                assert out =~ ~r/^  #{rank}: /m
              end
          end

          for entry <- Ainalrami.Alternatives.float_alternatives(pos.players, pairs, opts) do
            assert out =~ "Float alternatives (#{entry.floater} floated out of"
          end

          # A round with two boards' Blacks swapped is another round, and
          # the verdict is `judge/4`'s.
          with [{w1, b1}, {w2, b2} | rest] when b1 != nil and b2 != nil <- pairs do
            other = [{w1, b2}, {w2, b1} | rest]
            text = Enum.map_join(other, ",", fn {w, b} -> "#{w}-#{b || 0}" end)
            {out, code} = cli([pos.path, "-x", "-q", "--judge=#{text}"])
            assert code == 0, out
            result = Ainalrami.Alternatives.judge(pos.players, pairs, other, opts)

            word =
              case result.verdict do
                :identical -> "that is the round that was paired"
                {:worse, _, label, _, _} -> to_string(label)
                {:better, _, label, _, _} -> to_string(label)
                {:tie, _, _} -> "equal on every criterion"
                {:incomparable, _} -> "not comparable"
              end

            assert out =~ word
            assert length(Regex.scan(~r/^  illegal: /m, out)) == length(result.violations)
          end
      end
    end
  end
end
