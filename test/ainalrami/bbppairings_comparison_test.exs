defmodule Ainalrami.BbppairingsComparisonTest do
  @moduledoc """
  Cross-checks `Ainalrami.Pairing.pair_next_round/1` against the real
  `bbpPairings.exe` (Bierema Boyz Programming's independent, Apache-2.0
  Dutch-system implementation) over a whole tournament, every round -
  the second reference this project has always meant to check against
  (see docs/engineering-log.md's "Cross-validation against bbpPairings"), distinct from
  the earlier use of its SOURCE to port `Ainalrami.WeightedMatching`. That
  was a code-fidelity check; this is a pairing-output comparison, on a
  binary Ainalrami has never actually run against before.

  Deliberately the SAME methodology as `Ainalrami.JavafoComparisonTest`
  (see that module's moduledoc for the full reasoning): play a
  tournament forward one round at a time, ask both engines to pair the
  identical history, diff, then advance on the REFERENCE engine's own
  answer (bbpPairings', here) so a disagreement in one round can't
  corrupt the measurement of the rounds after it.

  ## The one real behavioural difference from the javafo harness

  javafo signals "no legal pairing left" by writing an EMPTY pairs file
  and exiting 0. bbpPairings signals the identical situation with exit
  code 1 and no output file at all (its own documented error code 1:
  "no valid pairing exists for the current round") - see
  `Ainalrami.Test.Bbppairings`'s moduledoc. Handled the same way either
  way: the tournament ends early and the round is excluded from the
  rates, not counted as a disagreement.

  A disagreement here is a research question, not an automatic verdict -
  bbpPairings and javafo don't always agree with each other either (both
  are independent readings of the same rulebook). Treat it as "which
  one, if either, matches the current Handbook text", the same standard
  `Ainalrami.JavafoComparisonTest` already uses.

  ## A coverage gap in the corpus, found by review rather than by a failure

  `safely_pair/3` passes `initial_colour:` on **every** comparison, and
  `Ainalrami.Test.FuzzTournament` writes the matching `152` line into the
  TRF handed to bbpPairings. So `opts[:initial_colour]` short-circuits
  `pair_next_round/2`'s `||` on every round of every axis, and
  `Pairing.infer_initial_colour/1` is never reached by the corpus at all.
  Whatever this harness's headline rate is, it is a rate for the initial
  colour's ALLOCATION, never for its inference.

  The inference has unit coverage only - `Ainalrami.InitialColourTest`,
  which runs with no binary present - plus the two `describe "the initial
  colour inferred from a file with no 152"` tests below, which are its only
  contact with a reference implementation and deliberately omit `152`. Any
  new axis added here inherits the gap unless it stops stating the draw.

  ## Running it

      PAIRING_FUZZ_COUNT=500 PAIRING_FUZZ_ROUNDS=9 mix test --only bbppairings

  Same tunables as the javafo harness: `PAIRING_FUZZ_COUNT`,
  `PAIRING_FUZZ_ROUNDS`, `PAIRING_FUZZ_MIN_PLAYERS`/`_MAX_PLAYERS`,
  `PAIRING_FUZZ_BYE_PCT`, `PAIRING_FUZZ_FORFEIT_PCT`, `PAIRING_FUZZ_DUMP`.

  **Vary `PAIRING_FUZZ_ROUNDS`, and run an EVEN value.** Every axis measured
  on this project until 2026-08-17 used `ROUNDS=9`, whose final round is
  paired with 8 rounds played. `final_round_topscorers?/2` compares against
  half the played-round count, so a threshold that floors that half is
  identical to an exact one whenever the count is even - the bug lived
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
  disagreement meant re-running everything before it - which is why the
  cases catalogued in docs/engineering-log.md were adjudicated once, from dumps, and never
  re-checked when the adjudicator itself changed. The seed, round and
  player count in a dump's filename are all that is needed; the rest of the
  configuration has to match what produced it.

  Three more cover the extension lines, and they work because
  bbpPairings implements both - the same file is handed to both engines, so
  the oracle validates them exactly as it validates every other axis:

    * `PAIRING_FUZZ_NUMERIC_EXT` - `1` to write forbidden pairs and
      acceleration as bbpPairings' fixed-column `260`/`250` instead of
      JaVaFo's `XXP`/`XXA`. Same tournament, different lines on both
      sides: a different writer here, a different reader there.
    * `PAIRING_FUZZ_FORBIDDEN_PCT` - percentage of players given one
      arbiter-forbidden opponent, emitted as `XXP`.
    * `PAIRING_FUZZ_ACCEL` - `baku` or `random`, emitted as `XXA`.

  Both are fixed per TOURNAMENT, not per round: an exclusion and an
  acceleration record are properties of the event, and `XXA` in particular
  is only meaningful as a full round-by-round history (JaVaFo's manual is
  explicit that the record is what the float history is derived from).
  """

  use ExUnit.Case
  alias Ainalrami.{Pairing, Test.Bbppairings}

  # Generation moved to `Ainalrami.Test.FuzzTournament` so the three-way
  # harness could stop generating a weaker corpus than this one. Imported
  # rather than aliased: the call sites below are unchanged from when these
  # were private functions here, which is what makes the move verifiable by
  # re-running a fixed seed range and diffing the summary.
  import Ainalrami.Test.FuzzTournament

  @moduletag :bbppairings
  @moduletag timeout: :infinity

  # Guards the rating axis against going quietly inert.
  #
  # A mode that stopped taking effect would still report 100% agreement -
  # the run would simply be another "spread" corpus wearing a different
  # name, and the axis it claims to test would be untested while looking
  # green. The board COUNTS cannot catch that, because the number of
  # pairings does not depend on rating at all; only the roster can.
  test "each rating mode actually shapes the roster it claims to" do
    roster = fn mode ->
      Process.put(:fuzz_rating_mode, mode)
      :rand.seed(:exsss, {11, 22, 33})
      initial_roster(40) |> Enum.map(& &1.fide_rating)
    end

    spread = roster.("spread")
    equal = roster.("equal")
    clustered = roster.("clustered")
    none = roster.("all_unrated")
    some = roster.("unrated")

    assert Enum.uniq(equal) |> length() == 1,
           "equal should give one rating, got #{length(Enum.uniq(equal))}"

    assert Enum.all?(none, &(&1 == 0)), "all_unrated should be every player at 0"
    assert Enum.any?(some, &(&1 == 0)) and Enum.any?(some, &(&1 > 0)), "unrated should mix"

    # The point of "clustered" is TIES, which spread almost never produces.
    assert length(Enum.uniq(clustered)) < length(Enum.uniq(spread)),
           "clustered should collide far more than spread: #{length(Enum.uniq(clustered))} vs #{length(Enum.uniq(spread))} distinct"

    assert length(Enum.uniq(spread)) > 30, "spread should stay near-distinct"
  end

  # ------------------------------------------------------------------
  # The inference, which the corpus below CANNOT reach
  # ------------------------------------------------------------------
  #
  # `safely_pair/3` passes `initial_colour:` on every single comparison, and
  # `FuzzTournament` writes the matching `152` line into the TRF, so
  # `opts[:initial_colour]` short-circuits `pair_next_round/2`'s `||` and
  # `Pairing.infer_initial_colour/1` IS NEVER ENTERED. Not rarely - never,
  # on every axis this harness has ever run. Every rate it has ever reported
  # measures the round's ALLOCATION and the numbering the allocation uses;
  # it says nothing whatever about the inference, and the size of the
  # numbers invites the opposite reading.
  #
  # That includes the two small runs taken on 2026-08-27 to check the SPP
  # ruling. Those are TWO SEPARATE runs on different configurations, and
  # merging them into one figure manufactures a before/after that neither of
  # them is:
  #
  #   * 60 tournaments, 5 rounds, 50% byes, 6-16 players: 27 colour
  #     disagreements against bbpPairings with the overturned numbering
  #     deliberately reinstated, and 0 with the fix in. The "before" was
  #     sabotaged on purpose - a zero on its own is unfalsifiable, because
  #     the same corpus at a 15% bye rate reports zero under both readings.
  #   * 60 tournaments, 5 rounds, 40% byes, 25% forfeits: 0 colour
  #     disagreements, 1096/1096 pairs, 299/299 rounds. A different
  #     configuration, with no sabotaged before-column at all.
  #
  # Neither of them is the corpus, and the corpus has NOT been re-run since
  # the fix - so there is no post-fix large-scale figure to quote here yet.
  # docs/conformance-c0403-2026.md and docs/dispute-initial-colour.md carry
  # both rows and mark the re-measurement pending.
  #
  # These two tests are the inference's only contact with the real binary.
  # They deliberately use no `152` at all.
  describe "the initial colour inferred from a file with no 152" do
    test "matches bbpPairings on a field whose first coloured round is round two" do
      # Round one records nothing but arbiter byes, so it carries no colour
      # and the inference has to read ROUND TWO - where the scores already
      # differ, and a downfloat can seat a low-TPN low-score player as the
      # BOTTOM of their board.
      for draw <- ["w", "b"] do
        field = second_round_colours_only(["H", "H", "F", "Z"], 4, draw)

        {:ok, silent} = Bbppairings.pair(trf(field, nil))
        ours = Pairing.pair_next_round(field, expected_rounds: 9)

        assert Enum.sort(ours) == Enum.sort(silent),
               "draw #{draw}: bbpPairings deduced one initial colour from this file and we " <>
                 "deduced another\n  ours: #{inspect(Enum.sort(ours))}\n  bbp:  #{inspect(Enum.sort(silent))}"
      end
    end

    test "reproduces bbpPairings' asymmetry: its own deduction disagrees with its own 152" do
      # The finding this pins. `assign_colour_round_one/3` takes the parity
      # of the TOP of the board - Article 1.2, score first - while
      # `infer_initial_colour/1` takes it off whichever player holds a
      # colour, top or bottom. That is not an exact inverse, and on this
      # field the two readings answer opposite.
      #
      # It is not corrected, because bbpPairings does not correct it either:
      # handed a file IT produced under `152 B`, with the `152` stripped, it
      # deduces White and pairs the later boards accordingly. Ainalrami
      # copies the asymmetry rather than out-reasoning the reference on a
      # point no article covers - 5.1 leaves the initial colour to a drawing
      # of lots, and C.04.3 says nothing at all about recovering a lost one.
      #
      # A future bbpPairings that fixed its deduction would fail HERE, on a
      # named expectation, rather than as noise in the corpus.
      field = second_round_colours_only(["H", "H", "F", "Z"], 4, "b")

      {:ok, silent} = Bbppairings.pair(trf(field, nil))
      {:ok, stated_white} = Bbppairings.pair(trf(field, "w"))
      {:ok, stated_black} = Bbppairings.pair(trf(field, "b"))

      refute Enum.sort(stated_white) == Enum.sort(stated_black),
             "the position must be informative: the two draws have to pair differently"

      assert Enum.sort(silent) == Enum.sort(stated_white),
             "bbpPairings deduces White from a file it paired under 152 B"

      refute Enum.sort(silent) == Enum.sort(stated_black),
             "which is to say its deduction does NOT recover the draw it actually used"

      # And we land on the same side of that asymmetry.
      assert Enum.sort(Pairing.pair_next_round(field, expected_rounds: 9)) == Enum.sort(silent)

      # The forward direction is NOT asymmetric, and both engines agree on
      # it - so the divergence is in the deduction alone, not in 5.2.5.
      core = round_one_byes(["H", "H", "F", "Z"])
      {:ok, bbp_round_two} = Bbppairings.pair(trf(core, "b"))

      assert Pairing.pair_next_round(core, expected_rounds: 9, initial_colour: "b") ==
               bbp_round_two,
             "with the draw stated, 5.2.5 hands the initial colour to the higher-SCORED " <>
               "player and both engines do it identically"
    end
  end

  # Ranks 1..n, each holding one arbiter bye in round one and nothing else.
  defp round_one_byes(codes) do
    for {code, rank} <- Enum.with_index(codes, 1) do
      bye = %{opponent_rank: nil, colour: nil, result: code}
      %{blank_player(rank) | points: bye_points(code), games: [bye]}
    end
  end

  # `round_one_byes/1` played forward one round on bbpPairings' OWN answer,
  # plus `spectators` players who have never been paired at all - so a board
  # of never-paired players survives into round three and 5.2.5 decides it.
  #
  # Built on the reference's round two rather than ours: the file then
  # provably is one bbpPairings would have written, which is what makes its
  # own deduction from it a fair reading.
  defp second_round_colours_only(codes, spectators, draw) do
    n = length(codes)
    core = round_one_byes(codes)
    {:ok, round_two} = Bbppairings.pair(trf(core, draw))

    played =
      for {code, rank} <- Enum.with_index(codes, 1) do
        seat =
          Enum.find_value(round_two, fn
            {^rank, black} when black != nil -> {black, "w"}
            {white, ^rank} when white != nil -> {white, "b"}
            _ -> nil
          end)

        bye = %{opponent_rank: nil, colour: nil, result: code}

        case seat do
          nil ->
            %{blank_player(rank) | points: bye_points(code), games: [bye, bye_of("Z")]}

          {opponent, colour} ->
            %{
              blank_player(rank)
              | points: bye_points(code) + 0.5,
                games: [bye, %{opponent_rank: opponent, colour: colour, result: "="}]
            }
        end
      end

    watching =
      for rank <- (n + 1)..(n + spectators) do
        %{blank_player(rank) | points: 0.0, games: [bye_of("Z"), bye_of("Z")]}
      end

    played ++ watching
  end

  defp bye_of(code), do: %{opponent_rank: nil, colour: nil, result: code}

  defp bye_points("H"), do: 0.5
  defp bye_points("F"), do: 1.0
  defp bye_points("Z"), do: 0.0

  defp blank_player(rank) do
    %{
      rank: rank,
      name: "P#{rank}",
      sex: "",
      title: "",
      federation: "",
      fide_rating: 2400 - rank * 7,
      fide_number: nil,
      birth_date: "",
      points: 0.0,
      games: []
    }
  end

  # `initial` of `nil` omits the `152` line entirely, which is the whole
  # point of these two tests.
  defp trf(players, initial) do
    Ainalrami.Trf.serialize(%{
      tournament: %{
        name: "inference",
        type: "swiss",
        number_of_rounds: 9,
        initial_colour: initial
      },
      players: players
    })
  end

  test "Ainalrami and bbpPairings.exe agree on who plays whom, in every round of a tournament" do
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
    of #{count} tournament(s) - a legal-but-different pairing, or a genuine gap in Ainalrami's \
    bracket cascade, not necessarily a bug in the sense that bbpPairings is "right" and \
    Ainalrami is "wrong". Each needs its own look against the Handbook text.

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
          ainalrami: {:raised, e},
          bbppairings: nil,
          trf: "",
          illegal: :raised,
          colour_mismatches: 0,
          pairs_matched: 0,
          pairs_total: 0
        }
      ]
  end

  defp run_tournament!(seed, rounds, player_range) do
    {rounds, player_count, forbidden, roster} = begin!(seed, rounds, player_range)

    {measurements, _final} =
      Enum.reduce_while(1..rounds, {[], roster}, fn round, {acc, players} ->
        withdraw_some(round, player_count)

        case play_round(players, seed, round, rounds, player_count, forbidden) do
          {:ok, measurement, next_players} -> {:cont, {[measurement | acc], next_players}}
          {:error, measurement} -> {:halt, {[measurement | acc], players}}
        end
      end)

    Enum.reverse(measurements)
  end

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
      # bbpPairings' own equivalent of javafo's empty-pairs-file case - see
      # this module's moduledoc on the exit-code-vs-empty-file difference.
      {:no_valid_pairing, _message} ->
        {:error,
         Map.merge(base, %{
           exhausted?: true,
           match?: true,
           ainalrami: nil,
           bbppairings: [],
           illegal: nil,
           colour_mismatches: 0
         })}

      {:ok, bbp_pairs} ->
        ainalrami_pairs = safely_pair(players, total_rounds, forbidden)

        # The active set comes from bbpPairings' OWN pairing, not from a rule
        # this project wrote. It used to come from `Test.Field.active/1`,
        # which was character-for-character `Pairing.rounds_played/1` - so the
        # legality check shared its central assumption with the engine it was
        # checking and could not have caught a wrong round number. See
        # `Ainalrami.Test.Field`'s moduledoc.
        active = Ainalrami.Test.Field.from_reference(bbp_pairs)

        measurement =
          Map.merge(base, %{
            match?: pairings_match?(ainalrami_pairs, bbp_pairs),
            ainalrami: summarise(ainalrami_pairs),
            bbppairings: Enum.sort(bbp_pairs)
          })
          |> Map.merge(pair_agreement(ainalrami_pairs, bbp_pairs))
          |> Map.merge(
            colour_mismatches(ainalrami_pairs, bbp_pairs, active, players, {seed, round})
          )
          |> Map.put(:illegal, illegality(ainalrami_pairs, active, players, forbidden))

        next_players = apply_round(players, bbp_pairs, simulate_results(bbp_pairs))
        {:ok, measurement, next_players}

      {:error, {code, out}} ->
        {:error,
         Map.merge(base, %{
           process_error?: true,
           match?: false,
           illegal: nil,
           ainalrami: nil,
           colour_mismatches: 0,
           bbppairings: {:error, code, out}
         })}
    end
  end

  defp safely_pair(players, total_rounds, forbidden) do
    Pairing.pair_next_round(players,
      expected_rounds: total_rounds,
      forbidden_pairs: forbidden,
      initial_colour: String.downcase(initial_colour()),
      # `nil` on every run that does not set the axis, which is what
      # `Pairing` already defaults to - so this changes nothing until a file
      # carries `BB*` lines saying otherwise.
      point_system: point_system()
    )
  rescue
    e -> {:raised, e}
  end

  defp pairings_match?({:raised, _}, _bbp_pairs), do: false

  defp pairings_match?(ainalrami_pairs, bbp_pairs),
    do: normalize(ainalrami_pairs) == normalize(bbp_pairs)

  # WHO IS WHITE, which `normalize/1` deliberately throws away.
  #
  # Every rate this harness has ever reported is colour-blind: it sorts each
  # pair's two ranks before comparing, so 4.3 million tournaments and 195
  # million pairings validated who plays whom and never once checked Article
  # 5. A missing 5.2.4 survived all of it, and was found only by building a
  # position by hand. Counted separately from pairing agreement, because the
  # two fail for different reasons and a colour difference on an otherwise
  # identical round is not the same finding as a different round.
  #
  # Until 2026-08-28 this split its findings in two: a board Article 5.2.5
  # decided was filed as "the known dispute" and expected, anything else as
  # a finding. The dispute is over - the SPP ruled on 2026-08-27 that
  # 5.2.5's parity is taken on the arrival numbering, which is what
  # bbpPairings does and what this engine now does too - so there is nothing
  # left for a colour difference against bbpPairings to be EXCEPT a finding.
  # The split is gone rather than left to report zero, because a bucket
  # labelled "expected" that nothing may legitimately land in is a place for
  # a real regression to hide.
  defp colour_mismatches({:raised, _}, _bbp, _active, _players, _where),
    do: %{colour_mismatches: 0, colour_shared: 0}

  defp colour_mismatches(ainalrami_pairs, bbp_pairs, _active, players, {seed, round}) do
    theirs = MapSet.new(bbp_pairs)

    reversed =
      Enum.filter(ainalrami_pairs, fn
        {_w, nil} ->
          false

        {w, b} = pair ->
          # Only a pair both engines formed can disagree about colour; a pair
          # only we formed is a pairing difference, already counted.
          MapSet.member?(theirs, {b, w}) and not MapSet.member?(theirs, pair)
      end)

    if System.get_env("COLOUR_DEBUG") do
      for {w, b} <- reversed do
        IO.puts("
seed #{seed} round #{round}: UNEXPLAINED - we say #{w} White, bbpPairings says #{b} White")

        # Deciding WHICH of Article 5.2's five steps applies needs both
        # players' full colour history, unplayed rounds included: 5.2.3
        # walks the two histories back in step, and a round nobody played
        # is not a round where the colours agreed.
        for rank <- [w, b] do
          p = Enum.find(players, &(&1.rank == rank))

          history =
            p.games |> Enum.map_join(" ", fn g -> "#{g.colour || "-"}#{g.result}" end)

          # Acceleration too: Article 1.2's order is over the score the
          # engine actually pairs on, virtual points included, so a board
          # cannot be judged from raw points alone on an accelerated axis.
          IO.puts(
            "  ##{rank} pts=#{p.points} accel=#{inspect(p[:accelerations])} games=[#{history}]"
          )
        end
      end
    end

    # The denominator travels with the count. A colour report needs to say
    # what it compared: "no disagreement" over zero boards is not a result,
    # and printing it as one is how an empty axis passes for a clean one.
    shared =
      Enum.count(ainalrami_pairs, fn
        {_w, nil} -> false
        {w, b} = pair -> MapSet.member?(theirs, pair) or MapSet.member?(theirs, {b, w})
      end)

    %{colour_mismatches: length(reversed), colour_shared: shared}
  end

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

    # C2: nobody receives a SECOND pairing-allocated bye - see the
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
    # entire reason the sibling project refused to hand Ainalrami a TRF
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

  defp pair_agreement(ainalrami_pairs, bbp_pairs) do
    ours = MapSet.new(normalize(ainalrami_pairs))
    theirs = MapSet.new(normalize(bbp_pairs))

    %{
      pairs_matched: MapSet.size(MapSet.intersection(ours, theirs)),
      pairs_total: MapSet.size(theirs)
    }
  end

  defp report(comparisons, errors, exhausted, rounds) do
    colour_bad = comparisons |> Enum.map(&Map.get(&1, :colour_mismatches, 0)) |> Enum.sum()
    colour_shared = comparisons |> Enum.map(&Map.get(&1, :colour_shared, 0)) |> Enum.sum()

    if colour_bad > 0 do
      IO.puts(
        "
  !! #{colour_bad} pair(s) agreed on WHO plays whom but disagreed on who is WHITE." <>
          "
     Since the SPP's 2026-08-27 ruling there is no expected colour" <>
          "
     difference against bbpPairings left, so every one of these is a" <>
          "
     finding. Article 5 is a real" <>
          "
     conformance surface and this harness was blind to it until 2026-08-17 --" <>
          "
     `normalize/1` sorts each pair's ranks before comparing. Re-run with" <>
          "
     COLOUR_DEBUG=1 to print each unexplained board."
      )
    else
      if colour_shared == 0 do
        IO.puts("
  !! colours: NOTHING WAS COMPARED - 0 board(s) were formed by both engines,
     so the absence of a disagreement here means nothing at all. Check the
     process-error count below and the axis parameters.")
      else
        IO.puts("
  colours: no disagreement about who is White, over #{colour_shared} board(s)
  formed by both engines.")
      end
    end

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
      IO.puts("\n  legality: every Ainalrami round was a legal pairing.")
    else
      by_kind =
        illegal |> Enum.group_by(& &1.illegal) |> Enum.map(fn {k, v} -> "#{k}: #{length(v)}" end)

      IO.puts(
        "\n  LEGALITY: #{length(illegal)}/#{length(comparisons)} Ainalrami rounds were not legal " <>
          "pairings at all (#{Enum.join(by_kind, ", ")}) - independent of whether bbpPairings agreed. " <>
          "`raised` means Ainalrami REFUSED to pair the round, which is a different failure from " <>
          "emitting a wrong one: check whether bbpPairings paired it before assuming the round " <>
          "was genuinely impossible."
      )
    end

    if exhausted != [] do
      IO.puts(
        "\n  (#{length(exhausted)} tournament(s) ended early - bbpPairings found no legal " <>
          "pairing left, i.e. the field ran out of opponents. Excluded from the rates above.)"
      )
    end

    if errors != [] do
      IO.puts(
        "\n  WARNING: #{length(errors)} bbpPairings process error(s) - this run was likely " <>
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

        # An axis that disagrees on a few per cent of two million rounds
        # produces tens of thousands of these, and the hundredth example of
        # one pattern is worth nothing the first ten were not. Capped, and
        # the cap SAYS what it dropped - a silent truncation reads as
        # "that is all of them", which is how a rate gets misread later.
        {kept, dropped} = Enum.split(mismatches, dump_limit())

        Enum.each(kept, fn m ->
          stem = Path.join(dir, "seed#{m.seed}-r#{m.round}-p#{m.player_count}")
          File.write!(stem <> ".trf", m.trf)

          File.write!(
            stem <> ".txt",
            "seed #{m.seed}, round #{m.round}, #{m.player_count} players\n" <>
              "pairs matched: #{m.pairs_matched}/#{m.pairs_total}\n\n" <>
              "Ainalrami:     #{inspect(m.ainalrami, limit: :infinity)}\n" <>
              "bbpPairings:  #{inspect(m.bbppairings, limit: :infinity)}\n"
          )
        end)

        IO.puts("\n  Dumped #{length(kept)} disagreement(s) to #{dir}")

        if dropped != [] do
          IO.puts(
            "  #{length(dropped)} further disagreement(s) NOT dumped " <>
              "(PAIRING_FUZZ_DUMP_LIMIT=#{dump_limit()}); the rates above count all of them"
          )
        end
    end
  end

  defp dump_limit, do: env_int("PAIRING_FUZZ_DUMP_LIMIT", 200)

  defp row(measurements) do
    rounds_matched = Enum.count(measurements, & &1.match?)
    rounds_total = length(measurements)
    pairs_matched = Enum.sum(Enum.map(measurements, & &1.pairs_matched))
    pairs_total = Enum.sum(Enum.map(measurements, & &1.pairs_total))

    # Refusing to pair and emitting a wrong pairing are different
    # failures and want different responses, so they get their own
    # columns. Counting them together is how 142 refusals once read as
    # 142 illegal pairings - see `Ainalrami.DeepRoundsTest`.
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
      Ainalrami:    #{inspect(m.ainalrami)}
      bbpPairings: #{inspect(m.bbppairings)}
    """
  end
end
