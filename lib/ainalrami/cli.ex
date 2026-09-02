defmodule Ainalrami.CLI do
  @moduledoc """
  Command-line entry point. Deliberately mirrors JaVaFo's own invocation
  shape - `java -jar javafo.jar input.trf -p output.txt` (confirmed against
  the sibling project's real `System.cmd` call, not guessed) - as
  `ainalrami input.trf -p output.trf`, so a caller that already knows how to
  drive JaVaFo only has to swap the executable name, not rewrite its
  argument-building code. The same applies to JaVaFo's other two modes:
  `-c` (Pairings Checker, FPC) is implemented - it replays a completed
  tournament and diffs each round against what this engine would have
  paired, exiting nonzero if any round differs. `-g` (Random Tournament
  Generator) is implemented too - it takes no input file, since it creates
  a tournament rather than reading one.

  Verbose trace is the default (see `Ainalrami.Log`); pass `-q`/`--quiet` to
  suppress it.

  `run/1` does the real work and returns a plain exit code, deliberately
  never calling `System.halt/1` itself - that would kill the test VM if
  called from ExUnit. `main/1` (the actual escript entry point) is the only
  place that halts.
  """

  alias Ainalrami.{Generator, Log, Pairing, Trf}

  @doc false
  def main(argv), do: argv |> run() |> System.halt()

  # Wraps `run/1`'s body so a value-level complaint thrown from option parsing
  # comes back as an ordinary usage error. A throw rather than a return value
  # because those parsers are called for their VALUE - `option/2` hands back an
  # integer, and there is nowhere in `seed: option(flags, "seed")` for an error
  # tuple to go that is not just as silent as the bug this fixes.

  @doc "Runs the CLI and returns an exit code, without halting the VM - see moduledoc."
  def run(argv) do
    {flags, positional} = split_flags(argv)

    Log.set_level(
      cond do
        "-q" in flags or "--quiet" in flags -> :quiet
        "-d" in flags or "--debug" in flags -> :debug
        true -> :normal
      end
    )

    try do
      cond do
        # Before --help and --version, so a mistyped option is reported rather
        # than swallowed by a run that was going to print help anyway.
        complaint = bad_flag(flags) -> usage_error(complaint)
        "-h" in flags or "--help" in flags -> print_help_and_ok()
        "--version" in flags -> print_version_and_ok()
        true -> dispatch(positional, flags)
      end
    rescue
      # The backstop. Everything below here that CAN be predicted is already
      # reported as a message and an exit code - an unreadable file, an
      # invalid TRF, an option this program does not have. What was left was
      # everything else: a `260` line in the trace (sweep H2) reached the
      # user as `** (Protocol.UndefinedError) protocol Enumerable not
      # implemented for Tuple`, an escript stack trace with no indication of
      # which file or which line, and - because `main/1` halts on `run/1`'s
      # return value and an uncaught raise never returns one - an exit status
      # that depended on the VM rather than on this program.
      #
      # So an unexpected exception becomes the same contract as every
      # expected one: a message on stderr, exit 1. Without the help text,
      # which is for a caller who typed something wrong, not for this.
      e ->
        Log.error("unexpected error: #{Exception.message(e)}")
        1
    catch
      {:usage, message} -> usage_error(message)
    end
  end

  # Every flag this CLI accepts. Both lists are checked rather than pattern
  # matched, because the failure they prevent is silence.
  #
  # `--player=30` (singular) used to run with a RANDOM roster size.
  # `--initial-colour=x` used to quietly pick White. And
  # `ainalrami -g out.trf --seed 42` - a space instead of an equals sign -
  # used to write the file and ignore the seed, which makes the run
  # unreproducible, which is the whole argument for the generator existing.
  #
  # Each of those is a command that appears to work. The seed one is the worst
  # kind: it produces a real tournament that can never be produced again, and
  # nothing says so.
  @bare_flags ~w(-p -g -c -x --explain -q --quiet -d --debug -h --help --version)
  @valued_flags ~w(seed players rounds forfeit-pct bye-pct forbidden-pct
                   acceleration initial-colour initial-color)

  defp split_flags(argv), do: Enum.split_with(argv, &String.starts_with?(&1, "-"))

  # The first flag this program does not accept, described, or nil.
  defp bad_flag(flags), do: Enum.find_value(flags, &flag_complaint/1)

  defp flag_complaint(flag) do
    cond do
      flag in @bare_flags ->
        nil

      String.contains?(flag, "=") and name_of(flag) in @valued_flags ->
        nil

      # Written correctly but not a flag this program has. Named back, because
      # the mistake is almost always a plural or a spelling.
      String.contains?(flag, "=") ->
        "unknown option --#{name_of(flag)}"

      # A valued flag with a space instead of an equals sign. Worth its own
      # message: the shell has already split it, so the value is sitting in
      # the positional arguments looking like a file name, and the run happens
      # without the option.
      String.trim_leading(flag, "-") in @valued_flags ->
        "#{flag} takes its value with an equals sign, as #{flag}=VALUE - " <>
          "written with a space the value is read as a file name and the option is lost"

      true ->
        "unknown option #{flag}"
    end
  end

  defp name_of(flag) do
    flag |> String.trim_leading("-") |> String.split("=") |> hd()
  end

  # The one `-g` option whose value is a word rather than an integer.
  #
  # An unknown value is refused rather than treated as absent. The name being
  # known is not enough - `--acceleration=bakku` is a request for something
  # this program does not do, and running without acceleration is not that.
  defp acceleration_option(flags) do
    Enum.find_value(flags, fn
      "--acceleration=baku" -> :baku
      "--acceleration=random" -> :random
      "--acceleration=" <> other -> refuse("unknown acceleration \"#{other}\" - baku or random")
      _ -> nil
    end)
  end

  # Article 5.1's drawing of lots, for `-g`. Accepts either spelling of
  # each colour and defaults to White, which is what the generator always
  # used implicitly before the option existed.
  defp initial_colour_option(flags) do
    Enum.find_value(flags, "w", fn
      "--initial-colour=" <> value -> normalise_colour(value) || bad_colour(value)
      "--initial-color=" <> value -> normalise_colour(value) || bad_colour(value)
      _ -> nil
    end)
  end

  # Refused rather than silently defaulted. Somebody who typed a colour has an
  # answer in mind, and quietly running the opposite one is worse than
  # stopping.
  defp bad_colour(value) do
    refuse("unknown initial colour \"#{value}\" - white/w or black/b")
  end

  defp bounded(nil, _key, _minimum), do: nil
  defp bounded(value, _key, minimum) when value >= minimum, do: value

  defp bounded(value, key, minimum) do
    refuse("--#{key} must be at least #{minimum}, not #{value}")
  end

  # A complaint from deep inside option parsing, where returning an exit code
  # would just be ignored by the caller expecting a value. Caught in `run/1`.
  defp refuse(message), do: throw({:usage, message})

  defp normalise_colour(value) do
    case String.downcase(value) do
      v when v in ["w", "white"] -> "w"
      v when v in ["b", "black"] -> "b"
      _ -> nil
    end
  end

  # `--key=value` options, used only by `-g`. Anything unrecognised is left
  # for the mode to reject rather than silently ignored.
  # An unparsable value is refused, not treated as absent. `--seed=fourty2`
  # producing a random seed is the same unreproducible run as `--seed 42` did.
  defp option(flags, key) do
    prefix = "--#{key}="

    case Enum.find(flags, &String.starts_with?(&1, prefix)) do
      nil ->
        nil

      flag ->
        value = String.trim_leading(flag, prefix)

        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> refuse("--#{key} takes a whole number, not \"#{value}\"")
        end
    end
  end

  # `input.trf -p [output.trf]` - input file is always the first positional
  # argument, exactly like JaVaFo; the mode flag then decides what happens
  # to the rest.
  # `-g` is the one mode that takes no input file - it creates a
  # tournament rather than reading one - so it's dispatched before the
  # missing-input check.
  defp dispatch(positional, flags) do
    cond do
      "-g" in flags -> generate(positional, flags)
      positional == [] -> usage_error("missing input TRF file")
      "-p" in flags -> pair_checked(hd(positional), tl(positional))
      "-c" in flags -> check(hd(positional))
      "-x" in flags or "--explain" in flags -> explain(hd(positional))
      true -> usage_error("missing mode flag: one of -p, -g, -c, -x")
    end
  end

  # Random Tournament Generator (RTG). `ainalrami -g [output.trf]` with
  # optional `--seed=`, `--players=`, `--rounds=`, `--forfeit-pct=`,
  # `--bye-pct=`, `--forbidden-pct=` and `--acceleration=`; writes to
  # stdout when no output path is given.
  defp generate(positional, flags) do
    opts =
      [
        seed: option(flags, "seed"),
        # `Generator.generate/1` raises on these too, but a caller who typed
        # `--players=-5` deserves the usage error rather than the backstop's
        # "unexpected error". The two agree on the bounds on purpose: a
        # roster of at least one, and a round count of at least none.
        players: bounded(option(flags, "players"), "players", 1),
        rounds: bounded(option(flags, "rounds"), "rounds", 0),
        forfeit_pct: option(flags, "forfeit-pct"),
        requested_bye_pct: option(flags, "bye-pct"),
        forbidden_pct: option(flags, "forbidden-pct"),
        acceleration: acceleration_option(flags),
        initial_colour: initial_colour_option(flags)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    Log.step("Generating a random tournament")
    {text, seed} = Generator.generate(opts)

    # Reported as well as embedded in the file's own tournament name, so a
    # run is reproducible from the console alone if the file is lost.
    Log.detail("seed #{seed}")

    case positional do
      [output_path | _] -> write_file!(output_path, text)
      [] -> IO.write(text)
    end

    0
  end

  # `-p`'s output is not a TRF - it is JaVaFo's bare board list, a count line
  # and one "white black" per pair. `ainalrami live.trf -p live.trf` therefore
  # did not "update" the tournament, it REPLACED it: 361 bytes of roster and
  # history became 13 bytes of board numbers, and the exit code was 0.
  #
  # Refused before anything is read, and on `Path.expand/1` of both sides so
  # `./live.trf` and `live.trf` are the same file here as they are on disk.
  # A caller who genuinely wants to overwrite can write elsewhere and move it,
  # which at least leaves a moment where both files exist.
  defp pair_checked(input_path, positional_rest) do
    case positional_rest do
      [output_path | _] ->
        if Path.expand(output_path) == Path.expand(input_path) do
          usage_error(
            "the output file is the input file (#{input_path}) - " <>
              "-p writes a board list, not a tournament, so this would destroy it"
          )
        else
          pair(input_path, positional_rest)
        end

      [] ->
        pair(input_path, positional_rest)
    end
  end

  defp pair(input_path, positional_rest) do
    Log.step("Loading #{input_path}")

    with {:ok, text} <- read_input(input_path),
         {:ok, parsed} <- parse_input(text) do
      round_count = report_roster(parsed)

      Log.step("Pairing engine")

      Log.detail(
        if round_count == 0, do: "pairing round 1", else: "pairing round #{round_count + 1}"
      )

      report_extensions(parsed)

      case pair_next_round(parsed.players, parsed.tournament) do
        {:ok, pairs} ->
          write_pairs(pairs, positional_rest)
          0

        {:error, :halt} ->
          1
      end
    else
      {:error, :halt} -> 1
    end
  end

  # `input.trf -x` - pair the next round and then say WHY, bracket by
  # bracket, from the engine's own criteria rather than by reconstructing
  # an argument from the finished boards.
  #
  # This exists because the reasoning was already computed and had no way
  # of being asked for. `Pairing.explain_round/3` has been here since the
  # adjudicator needed it, but only as a library function, so a host
  # application that is not this project's own could pair with the engine
  # and then had to re-derive the explanation from the results. That
  # re-derivation is an inference; this is the thing itself.
  #
  # Two limits, both inherited from `explain_round/3` and both worth
  # printing rather than hiding: it scores the pairs a bracket KEEPS plus
  # those reaching into the next group, so a criterion reads zero when it
  # genuinely did not separate anything; and the rung values are SUMS over
  # a bracket's edges, so they compare across answers only when the edge
  # counts match.
  defp explain(input_path) do
    Log.step("Loading #{input_path}")

    with {:ok, text} <- read_input(input_path),
         {:ok, parsed} <- parse_input(text) do
      round_count = report_roster(parsed)
      Log.step("Pairing engine")
      Log.detail("explaining round #{round_count + 1}")
      report_extensions(parsed)

      case pair_next_round(parsed.players, parsed.tournament) do
        {:ok, pairs} ->
          reports =
            Pairing.explain_round(parsed.players, pairs, pairing_opts(parsed.tournament))

          IO.write(render_explanation(reports, pairs, round_count + 1))
          0

        {:error, :halt} ->
          1
      end
    else
      {:error, :halt} -> 1
    end
  end

  defp render_explanation(reports, pairs, round_number) do
    boards = Enum.count(pairs, fn {_w, b} -> b != nil end)

    header =
      "
Round #{round_number} - #{boards} board#{plural(boards)} over " <>
        "#{length(reports)} bracket#{plural(length(reports))}
"

    header <> Enum.map_join(Enum.with_index(reports, 1), "", &render_bracket/1)
  end

  defp render_bracket({report, index}) do
    """

    Bracket #{index} · score #{format_score(report.group)} · #{length(report.order)} player#{plural(length(report.order))}
    #{row("moved down", report.mdps)}
    #{row("residents", report.residents)}
    #{row("paired", Enum.map(report.pairs, fn {a, b} -> "#{a}-#{b}" end))}
    #{row("floats down", report.floats)}
    #{render_rungs(report)}
    """
  end

  defp row(label, []), do: "  #{String.pad_trailing(label, 12)} -"
  defp row(label, values), do: "  #{String.pad_trailing(label, 12)} #{Enum.join(values, ", ")}"

  # Only the rungs that actually scored. A zero means the criterion did not
  # separate anything in this bracket, and printing nineteen of them buries
  # the two that did.
  defp render_rungs(%{rungs: rungs, edge_count: edges}) do
    scored = Enum.reject(rungs, fn {_label, value} -> value == 0 end)

    head =
      "  #{String.pad_trailing("criteria", 12)} #{length(scored)} of #{length(rungs)} scored, " <>
        "over #{edges} edge#{plural(edges)}"

    case scored do
      [] ->
        head <> "
                 (nothing separated this bracket)"

      _ ->
        head <>
          Enum.map_join(scored, "", fn {label, value} ->
            "
                 #{String.pad_trailing(label, 30)} #{value}"
          end)
    end
  end

  defp format_score(score) when is_float(score), do: :erlang.float_to_binary(score, decimals: 1)
  defp format_score(score), do: to_string(score)

  defp plural(1), do: ""
  defp plural(_), do: "s"

  # No legal pairing can mean the field has genuinely run out of legal
  # opponents (bbpPairings' own `NoValidPairingException` - see
  # `Ainalrami.Pairing.NoValidPairingError`'s doc) rather than a crash. That
  # matches how JaVaFo itself reports it: an empty pairing, not a stack
  # trace.
  defp pair_next_round(players, tournament) do
    {:ok, Pairing.pair_next_round(players, pairing_opts(tournament))}
  rescue
    e in Pairing.NoValidPairingError ->
      Log.error("no legal pairing exists for this round: #{Exception.message(e)}")
      {:error, :halt}
  end

  # Everything the engine needs that lives on the tournament rather than on
  # a player. Acceleration is absent because it doesn't belong here: `XXA`
  # is per-player and rides along on the player maps themselves.
  defp pairing_opts(tournament) do
    [
      expected_rounds: tournament[:number_of_rounds],
      forbidden_pairs: tournament[:forbidden_pairs],
      # What a result is worth (`BBW`/`BBD`/`BBL`/`BBZ`/`BBF`/`BBU`, or a
      # `162` line). Absent from a file means the standard system, which is
      # what `Pairing` defaults to - but when a file DOES say, the scores
      # every bracket is built from depend on it.
      point_system: tournament[:point_system],
      # Article 5.1's drawing of lots. `Trf` has read `152` since
      # 2026-08-17 but the CLI never forwarded it, so `-p` and `-c` fell
      # back to inferring the draw from round one - which works for a file
      # that HAS a round one and is simply wrong for a fresh roster, where
      # there is nothing to infer from and the engine defaults to White.
      #
      # So an arbiter who drew Black, recorded it, and asked for round one
      # got White pairings from a file that said otherwise. `nil` here is
      # harmless: the engine falls through to inference and then to White,
      # exactly as before.
      initial_colour: tournament[:initial_colour]
    ]
  end

  # An arbiter's exclusions and any acceleration are reported explicitly.
  # These were silently discarded until this engine learned to read them,
  # and a silent "no `XXP` line here after all" is exactly the failure the
  # trace should make impossible to miss.
  defp report_extensions(parsed) do
    for group <- parsed.tournament[:forbidden_pairs] || [] do
      Log.detail("forbidden pairing: #{describe_group(group)}")
    end

    for player <- parsed.players, player[:accelerations] not in [nil, []] do
      Log.detail(
        "##{player.rank} acceleration: " <>
          Enum.map_join(
            player[:accelerations],
            " ",
            &:erlang.float_to_binary(&1 / 1, decimals: 1)
          )
      )
    end
  end

  # A forbidden-pair group is EITHER a bare list of starting ranks (`XXP`)
  # or the round-limited `{ids, first, last}` a `260` line parses into. The
  # trace joined the group directly, so a `260` reached `Enum.map_join/3`
  # with a tuple and took `-p` and `-x` down with "protocol Enumerable not
  # implemented for Tuple" - on a file the engine itself pairs correctly.
  # `Trf` has its own private `group_ids/1` for exactly this; the shape is
  # part of the parse result's public surface, so the CLI matches it here
  # rather than reaching into the parser.
  defp describe_group({ids, first, last}) when is_list(ids) do
    "#{join_ids(ids)} (rounds #{first}-#{last})"
  end

  defp describe_group(ids) when is_list(ids), do: join_ids(ids)
  defp describe_group(other), do: inspect(other)

  defp join_ids(ids), do: Enum.map_join(ids, " / ", &"##{&1}")

  # Pairings Checker (FPC). Replays a completed tournament round by round,
  # re-pairing each round from the state that preceded it and diffing
  # against the pairing the file actually records.
  #
  # This mirrors what bbpPairings' own `-c` does (`tournament/checker.cpp`)
  # and it is worth being precise about what that means: a checker is NOT
  # an independent verifier of the rules. It clears the matches, replays,
  # and calls the SAME pairing engine to decide what each round should
  # have been. "Correct" here means "what this engine would have paired",
  # so a disagreement is a difference, not a proof of illegality - the
  # file may hold a perfectly legal pairing that this engine wouldn't pick.
  #
  # Composition (who plays whom) is reported as an error. Colours are
  # reported separately and never as an error, because Article 5.1 leaves
  # the first colour to a drawing of lots and this engine's convention is
  # its own - see `Ainalrami.Pairing.pair_round_one/1`.
  defp check(input_path) do
    Log.step("Loading #{input_path}")

    with {:ok, text} <- read_input(input_path),
         {:ok, parsed} <- parse_input(text) do
      rounds = completed_rounds(parsed.players)

      if rounds == 0 do
        Log.warn("no completed rounds to check")
        0
      else
        Log.step("Checking #{rounds} round(s)")

        results = Enum.map(1..rounds, &check_round(parsed, &1))
        differing = Enum.count(results, &(&1 != :ok))

        Log.step(
          "#{rounds - differing}/#{rounds} round(s) match this engine's own pairing" <>
            if(differing == 0, do: "", else: " - #{differing} differ")
        )

        if differing == 0, do: 0, else: 1
      end
    else
      {:error, :halt} -> 1
    end
  end

  defp check_round(parsed, round) do
    before = state_before_round(parsed.players, round, parsed.tournament[:point_system])

    expected = Pairing.pair_next_round(before, pairing_opts(parsed.tournament))
    actual = recorded_pairs(parsed.players, round)

    if composition(expected) == composition(actual) do
      Log.detail("round #{round}: matches" <> colour_note(expected, actual))
      :ok
    else
      Log.warn("round #{round}: DIFFERS")
      Log.warn("  file:   #{inspect(Enum.sort(actual))}")
      Log.warn("  engine: #{inspect(Enum.sort(expected))}")
      :differs
    end
  rescue
    e in Pairing.NoValidPairingError ->
      Log.warn(
        "round #{round}: this engine finds no legal pairing at all - #{Exception.message(e)}"
      )

      :differs
  end

  # How many rounds were actually PAIRED. Taken over players rather than the
  # header's own round count, which states the tournament's intended length,
  # not its progress.
  #
  # `length(&1.games)` is not that number. An arbiter's bye is recorded
  # BEFORE its round is paired - that is how the engine knows to leave the
  # player out - so a file waiting to have round N paired already carries a
  # round-N `H` or `Z` for everyone who asked to sit it out, and
  # `parse_games/1` sizes the list from the line. One such player made this
  # count one high, and the checker then diffed a round the file had never
  # paired: `recorded_pairs/2` discards every non-participating game, so
  # `actual` was `[]`, while `state_before_round/3` reconstructs exactly the
  # position that round is to be paired FROM and duly pairs it. Every file
  # with a pre-recorded bye for its pending round reported a spurious
  # mismatch on its last round and exited 1.
  #
  # A round counts as paired if ANY player took part in its pairing. Rounds
  # before that are counted too even if nobody's entry participated, which
  # is bbpPairings' rule as well: `trf.cpp:329-340` raises `playedRounds` to
  # `matches.size()` for any non-empty entry and to `matches.size() + 1`
  # only when `participatedInPairing`.
  #
  # bbpPairings on the same file reaches the same place by a different
  # route. Its reader pads every short history out to the pending round
  # with non-participating self-matches (`evenUpMatchHistories`), so its
  # checker does visit round N - and then finds every player sitting it out,
  # computes an empty matching, and prints nothing. Not checking the round
  # at all says the same thing more plainly.
  defp completed_rounds(players) do
    players |> Enum.map(&paired_through/1) |> Enum.max(fn -> 0 end)
  end

  defp paired_through(player) do
    player.games
    |> Enum.with_index(1)
    |> Enum.reduce(0, fn {game, round}, paired ->
      cond do
        blank?(game) -> paired
        Trf.participated_in_pairing?(game) -> round
        true -> max(paired, round - 1)
      end
    end)
  end

  # An entry holding nothing at all - no opponent, no colour, no result.
  # `parse_games/1` keeps these for interior rounds a late entrant missed,
  # and they are evidence of nothing.
  defp blank?(game) do
    is_nil(game.opponent_rank) and is_nil(game.colour) and
      (is_nil(game.result) or String.trim(game.result) == "")
  end

  # The tournament as it stood immediately before `round` was paired:
  # every earlier game, plus this round's own result for anyone who did
  # NOT participate in the pairing. That last part is not an optimisation
  # - an arbiter-assigned bye is recorded in advance precisely so the
  # engine leaves that player out, so replaying without it would ask the
  # engine to pair somebody who had already been excused.
  defp state_before_round(players, round, point_system) do
    points = point_system || Trf.default_point_system()

    Enum.map(players, fn player ->
      earlier = Enum.take(player.games, round - 1)

      games =
        case Enum.at(player.games, round - 1) do
          nil -> earlier
          game -> if Trf.participated_in_pairing?(game), do: earlier, else: earlier ++ [game]
        end

      %{
        player
        | games: games,
          points: Enum.sum(Enum.map(games, &Trf.points_for_game(&1, points)))
      }
    end)
  end

  # The pairing the file records for `round`, as {white, black} with `nil`
  # for a pairing-allocated bye. Each game is claimed by its White so the
  # pair is emitted once; players who sat the round out contribute nothing.
  defp recorded_pairs(players, round) do
    Enum.flat_map(players, fn player ->
      case Enum.at(player.games, round - 1) do
        nil ->
          []

        game ->
          cond do
            not Trf.participated_in_pairing?(game) -> []
            is_nil(game.opponent_rank) -> [{player.rank, nil}]
            game.colour == "w" -> [{player.rank, game.opponent_rank}]
            game.colour == "b" -> []
            # No colour recorded: claim it from the lower rank so the pair
            # is still emitted exactly once.
            player.rank < game.opponent_rank -> [{player.rank, game.opponent_rank}]
            true -> []
          end
      end
    end)
  end

  defp composition(pairs) do
    pairs
    |> Enum.map(fn {a, b} -> Enum.sort_by([a, b], &(&1 || :infinity)) end)
    |> Enum.sort()
  end

  defp colour_note(expected, actual) do
    if Enum.sort(expected) == Enum.sort(actual),
      do: "",
      else: " (same pairing, different colours)"
  end

  defp write_pairs(pairs, positional_rest) do
    for {white, black} <- pairs do
      Log.detail(board_description(white, black))
    end

    output_text = format_pairs(pairs)

    case positional_rest do
      [output_path | _] -> write_file!(output_path, output_text)
      [] -> IO.write(output_text)
    end
  end

  # Written to a sibling temp file and renamed into place, so an interrupted
  # or failing write leaves the previous file untouched rather than a
  # half-written one. Same directory on purpose: `File.rename/2` is only
  # atomic within a filesystem, and `System.tmp_dir!/0` is routinely on
  # another one.
  defp write_file!(output_path, text) do
    temp_path = "#{output_path}.#{System.unique_integer([:positive])}.tmp"

    try do
      File.write!(temp_path, text)

      case File.rename(temp_path, output_path) do
        :ok ->
          :ok

        {:error, reason} ->
          raise File.Error, reason: reason, action: "write to file", path: output_path
      end
    rescue
      e ->
        File.rm(temp_path)
        reraise e, __STACKTRACE__
    end

    Log.detail("wrote #{output_path}")
  end

  defp board_description(white, nil), do: "##{white} - pairing-allocated bye"
  defp board_description(white, black), do: "##{white} (white) vs. ##{black} (black)"

  # Same shape as javafo.jar's own output file: a count line, then one
  # "white black" line per pair (0 for a bye), CRLF throughout - confirmed
  # against a real javafo.jar run, not assumed.
  defp format_pairs(pairs) do
    header = "#{length(pairs)}\r\n"
    body = Enum.map_join(pairs, "", fn {w, b} -> "#{w} #{b || 0}\r\n" end)
    header <> body
  end

  defp read_input(input_path) do
    case File.read(input_path) do
      {:ok, text} ->
        {:ok, text}

      {:error, reason} ->
        Log.error("could not read #{input_path}: #{:file.format_error(reason)}")
        {:error, :halt}
    end
  end

  defp parse_input(text) do
    {:ok, Trf.parse(text)}
  rescue
    e in Trf.ValidationError ->
      Log.error("invalid TRF file: #{Exception.message(e)}")
      {:error, :halt}
  end

  defp report_roster(parsed) do
    round_count = parsed.players |> Enum.map(&length(&1.games)) |> Enum.max(fn -> 0 end)

    Log.detail("#{length(parsed.players)} players, #{length(parsed.teams)} teams")
    Log.detail("#{round_count} round(s) of history in the file")

    for p <- parsed.players do
      Log.detail("##{p.rank} #{p.name} (#{format_rating(p.fide_rating)}) - #{p.points} pts")
    end

    round_count
  end

  defp format_rating(0), do: "unrated"
  defp format_rating(rating), do: "#{rating}"

  defp usage_error(message) do
    Log.error(message)
    print_help()
    1
  end

  defp print_help_and_ok do
    print_help()
    0
  end

  defp print_version_and_ok do
    print_version()
    0
  end

  defp print_help do
    IO.puts("""
    ainalrami - a FIDE Dutch-system Swiss pairing engine

    Usage:
      ainalrami <input.trf> -p [<output.trf>]   Pair the next round (writes to
                                                stdout if <output.trf> is omitted)
      ainalrami -g [<output.trf>]                Random Tournament Generator
      ainalrami <input.trf> -c                   Pairings Checker: replay a
                                                 finished tournament and diff
                                                 every round against this engine
      ainalrami <input.trf> -x                   Explain: pair the next round and
                                                 report, per bracket, which
                                                 criteria decided it

    Options:
      -q, --quiet    Warnings and errors only
      -d, --debug    Add engine internals (bracket paths, sizes, timings)
      -h, --help     Show this help
          --version  Show the version number
    """)
  end

  defp print_version do
    case Application.spec(:ainalrami, :vsn) do
      nil -> IO.puts("unknown")
      vsn -> IO.puts(List.to_string(vsn))
    end
  end
end
