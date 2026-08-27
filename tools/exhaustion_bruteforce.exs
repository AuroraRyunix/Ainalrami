# Exhaustion brute force.
#
# `tools/exhaustion_probe.exs` established that this engine refuses every
# position bbpPairings refuses - 815,479 of them. That is agreement, not
# proof: two engines can be wrong together, and both refusing is the same
# single-oracle limit as everywhere else, moved from the pairing to the
# refusal.
#
# This settles it for small fields. When bbpPairings answers "no legal
# pairing left", it ENUMERATES every complete pairing of the active field
# and tests each against the three absolute criteria of C.04.3 (2026). If
# none is legal, the refusal is proved rather than corroborated.
#
# ## Why this is an independent oracle
#
# It shares no code with `Ainalrami.Pairing`. The criteria below are written
# from the article text as quoted in `docs/conformance-c0403-2026.md`, and
# the search is structurally the opposite of the engine's: exhaustive
# enumeration over all (n-1)!! perfect matchings, versus a weighted
# matching over a graph whose infeasible edges encode the same rules. An
# error would have to be made twice, in two different shapes, to survive.
#
# It is not independent of the REGULATION's ambiguities. Where the text
# admits two readings the tool runs both and reports separately - see the
# C3 topscorer exception below. A refusal proved under both readings is
# proved regardless of which is right.
#
# ## The three absolute criteria (C.04.3 2026, article 2.1)
#
#   C1  Two participants shall not play each other more than once.
#       Only a PLAYED game counts. FIDE Art. 16 makes a forfeit legally
#       unplayed, and this project measured that reading as correct against
#       the reference (88.67% -> 93.76% when it was fixed), so `+` and `-`
#       do NOT bar a later meeting.
#
#   C2  A participant who has already received a pairing-allocated bye, or
#       has already scored in one single round, without playing, as many
#       points as rewarded for a win, shall not receive the PAB.
#
#   C3  Non-topscorers with the same absolute colour preference shall not
#       meet.
#
# Supporting definitions, from article 1:
#
#   1.7.1  Absolute preference: colour difference > +1 or < -1, OR the same
#          colour in the two latest rounds played.
#   1.8    Topscorer: MORE than 50% of the maximum possible score, and only
#          in the final round.
#
# ## Scope
#
# Enumeration is (n-1)!! in the number of active players, times n for the
# bye choice on an odd field: 3 at n=4, 15 at n=6, 945 at n=10, 135,135 at
# n=14. Fields above @max_field are reported as `too_big` and counted
# separately rather than silently skipped.

alias Ainalrami.Test.{Bbppairings, FuzzTournament}

defmodule Brute do
  @max_field 14

  # ---------------------------------------------------------------- rules

  # C1. A game is PLAYED when it was contested - the TRF16 result codes for
  # a win, draw or loss. `+`/`-` are forfeits, which are unplayed, and
  # `H`/`Z`/`U`/`F` are byes with no opponent at all.
  defp met_before?(a, b) do
    Enum.any?(a.games, &(&1.result in ~w(1 = 0) and &1.opponent_rank == b.rank))
  end

  # C2, written as the article's two clauses rather than as one list of
  # codes, because the two disqualify for different reasons and only one of
  # them moves with the point system.
  #
  #   Clause 1, "has already received a pairing-allocated bye". A PAB is a
  #   bye the PAIRING produced, which in TRF16 is an opponentless `U` or
  #   `+`. It disqualifies however little the file pays it, so a tournament
  #   setting `BBU 0.0` does not hand somebody a second one.
  #
  #   Clause 2, "has already scored in one single round, WITHOUT PLAYING,
  #   as many points as rewarded for a win". That is a value comparison and
  #   it does move: `F` is an arbiter's full-point bye, and `+` against a
  #   real opponent is a forfeit win.
  #
  # Under the default system the two clauses together give exactly U, F and
  # `+`. They separate only under `BB*` values, which axis K exercises.
  defp bye_eligible?(player, ps) do
    not Enum.any?(player.games, &(pairing_allocated_bye?(&1) or unplayed_win?(&1, ps)))
  end

  defp pairing_allocated_bye?(g), do: is_nil(g.opponent_rank) and g.result in ~w(U +)

  defp unplayed_win?(g, ps), do: unplayed?(g) and unplayed_value(g, ps) >= ps.win

  defp unplayed?(g), do: g.result in ~w(+ - H F U Z) or g.result in [nil, ""]

  # What an unplayed game paid, from the TRF16 code meanings AND the file's
  # own point system. Every value is looked up; none is derived from
  # another.
  #
  # `H` was written as `win / 2` here, which is only the same number while a
  # draw is worth half a win. `BBD 2.0` on a default win of 1.0 makes a
  # half-point bye worth MORE than a win, which disqualifies its holder from
  # the pairing-allocated bye - and the tool said the opposite, reporting 66
  # positions as wrongly refused when the two engines were right.
  #
  # That is the same defect, in the same shape, as the one fixed in the
  # engine itself on 2026-08-26: a result scored from its code without the
  # system that says what the code is worth. It is worth noticing that it
  # reappeared immediately in a tool written from scratch to check that
  # engine.
  defp unplayed_value(%{result: r}, ps) when r in ~w(F +), do: ps.win
  defp unplayed_value(%{result: "H"}, ps), do: ps.draw
  defp unplayed_value(%{result: "U"}, ps), do: ps.pairing_allocated_bye
  defp unplayed_value(%{result: "-", opponent_rank: nil}, ps), do: ps.zero_point_bye
  defp unplayed_value(%{result: "-"}, ps), do: ps.forfeit_loss
  defp unplayed_value(_game, ps), do: ps.zero_point_bye

  # 1.7.1. The colour a player MUST have, or nil when their preference is
  # not absolute. Computed from the played games alone.
  defp absolute_preference(player) do
    coloured =
      player.games
      |> Enum.filter(&(&1.result in ~w(1 = 0) and &1.colour in ~w(w b)))

    whites = Enum.count(coloured, &(&1.colour == "w"))
    blacks = Enum.count(coloured, &(&1.colour == "b"))
    diff = whites - blacks

    last_two = coloured |> Enum.reverse() |> Enum.take(2) |> Enum.map(& &1.colour)

    cond do
      diff > 1 -> "b"
      diff < -1 -> "w"
      match?([x, x], last_two) -> invert(hd(last_two))
      true -> nil
    end
  end

  defp invert("w"), do: "b"
  defp invert("b"), do: "w"

  # 1.8. Over 50% of the maximum possible score, final round only.
  #
  # Three details, each of which this tool got wrong at first and each of
  # which is pinned to a source:
  #
  #   * The maximum is measured over the rounds PLAYED SO FAR, not over the
  #     tournament's eventual length. FIDE TEC's own worked example: "in a
  #     nine-round tournament the maximum score before the last round is
  #     eight points. So, a topscorer is a player who has 4.5 points or
  #     more."
  #
  #   * A round is worth `max(win, draw)`, not `win`. `dutch.cpp:55` reads
  #     `std::max(pointsForWin, pointsForDraw)`. Under `BBD 2.0` a draw
  #     outscores a win and the maximum per round is the draw. This tool
  #     had `win` because `docs/conformance-c0403-2026.md` still documents
  #     it that way - the engine was fixed and the conformance record was
  #     not, so the stale doc propagated the bug into a tool written to
  #     check the engine.
  #
  #   * The score is the ACCELERATED one. `dutch.cpp:63,65` calls
  #     `scoreWithAcceleration`, so a tournament carrying `XXA` has a
  #     different topscorer set from the same tournament without it.
  defp topscorer?(player, ctx) do
    final_round? = ctx.played >= ctx.expected - 1
    per_round = max(ctx.ps.win, ctx.ps.draw)

    final_round? and accelerated_score(player, ctx) > ctx.played * per_round / 2
  end

  defp accelerated_score(player, ctx) do
    boost = player |> Map.get(:accelerations, []) |> Enum.at(ctx.played) || 0.0
    player.points + boost
  end

  # C3. Both non-topscorers, both absolute, both wanting the same colour.
  #
  # `:with_exception` is the reading the sources settle on and the one the
  # result rests on. `:strict` drops the topscorer exception entirely and is
  # kept only as a measurement: the gap between the two counts how many
  # refusals turn on that exception being read correctly. It is deliberately
  # WRONG, so nothing asserts against it.
  defp colour_clash?(a, b, ctx, reading) do
    pa = absolute_preference(a)
    pb = absolute_preference(b)

    same_absolute? = not is_nil(pa) and pa == pb

    case reading do
      :strict ->
        same_absolute?

      :with_exception ->
        # OR, not AND. "Non-topscorers with the same absolute colour
        # preference shall not meet" - the prohibition needs BOTH to be
        # non-topscorers, so ONE topscorer lifts it. Confirmed in three
        # independent implementations: bbpPairings `dutch.cpp:63-66` is a
        # `||` between the two score tests, this engine's
        # `final_round_topscorers?/2` is `a.points > threshold or
        # b.points > threshold`, and Gacrux guards on `if (a["top"] or
        # b["top"])`.
        #
        # Written as AND here first, which produced 11,013 false "no legal
        # pairing exists" verdicts - every one of them in the final round,
        # which is the only round where topscorer status exists at all.
        # That signature is what identified it.
        exempt? = topscorer?(a, ctx) or topscorer?(b, ctx)

        same_absolute? and not exempt?
    end
  end

  defp legal_pair?(a, b, ctx, reading) do
    not met_before?(a, b) and not colour_clash?(a, b, ctx, reading) and
      not forbidden?(a, b, ctx)
  end

  # An arbiter's XXP/260 exclusion. Not one of the three absolute criteria,
  # but it is an absolute constraint on the pairing all the same, and the
  # generator emits it whenever the forbidden axis is on.
  defp forbidden?(a, b, ctx) do
    MapSet.member?(ctx.forbidden_set, {min(a.rank, b.rank), max(a.rank, b.rank)})
  end

  # ------------------------------------------------------------ the search

  @doc false
  def any_legal_round?(active, ctx, reading) do
    n = length(active)

    cond do
      n == 0 ->
        # `perfect_matching?([])` is vacuously true, which would report an
        # empty field as a legal pairing and count it against the reference.
        # An empty active field means the round was derived wrongly.
        :empty_field

      n > @max_field ->
        :too_big

      rem(n, 2) == 0 ->
        if perfect_matching?(active, ctx, reading), do: :legal_exists, else: :none_exists

      true ->
        # Odd field: exactly one pairing-allocated bye, to someone C2 allows.
        candidates = Enum.filter(active, &bye_eligible?(&1, ctx.ps))

        cond do
          candidates == [] ->
            :none_exists

          Enum.any?(candidates, fn bye ->
            perfect_matching?(List.delete(active, bye), ctx, reading)
          end) ->
            :legal_exists

          true ->
            :none_exists
        end
    end
  end

  # Exhaustive: fix the first player, try every partner, recurse. This walks
  # all (n-1)!! perfect matchings and stops at the first legal one.
  defp perfect_matching?([], _ctx, _reading), do: true

  defp perfect_matching?([first | rest], ctx, reading) do
    Enum.any?(rest, fn partner ->
      legal_pair?(first, partner, ctx, reading) and
        perfect_matching?(List.delete(rest, partner), ctx, reading)
    end)
  end
end

defmodule Driver do
  def run(seed, rounds, player_range) do
    {rounds, player_count, forbidden, roster} =
      FuzzTournament.begin!(seed, rounds, player_range)

    {out, _} =
      Enum.reduce_while(1..rounds, {[], roster}, fn round, {acc, players} ->
        FuzzTournament.withdraw_some(round, player_count)

        case play(players, seed, round, rounds, player_count, forbidden) do
          {:cont, next} -> {:cont, {acc, next}}
          {:halt, o} -> {:halt, {[o | acc], players}}
        end
      end)

    out ++ Process.get(:control_log, [])
  rescue
    e -> [%{class: :harness_error, seed: seed, detail: Exception.message(e) |> String.slice(0, 160)}]
  end

  defp play(players, seed, round, total_rounds, player_count, forbidden) do
    players = FuzzTournament.assign_requested_byes(players)
    trf = FuzzTournament.build_trf(players, total_rounds, forbidden)

    case Bbppairings.pair(trf) do
      {:no_valid_pairing, _} ->
        {:halt, verify(players, seed, round, total_rounds, player_count, forbidden, trf)}

      {:ok, pairs} ->
        # POSITIVE CONTROL. bbpPairings just produced a legal pairing for
        # this position, so a legal pairing demonstrably exists - and the
        # oracle must find one. An oracle that is too strict would answer
        # `:none_exists` here, and would then "prove" every refusal
        # impossible for the same wrong reason. Without this check the
        # negative result below is worth nothing.
        #
        # It also checks the ACTIVE SET, which is the other thing that could
        # be silently wrong: bbpPairings' own pairing names exactly who was
        # in the round, so a mismatch against the count-derived set is a
        # defect in this tool rather than a finding about the engines.
        if control?() do
          control(players, pairs, seed, round, total_rounds, forbidden)
        end

        {:cont, FuzzTournament.apply_round(players, pairs, FuzzTournament.simulate_results(pairs))}

      _ ->
        {:halt, %{class: :bbp_process_error, seed: seed, round: round}}
    end
  end

  # WHICH ROUND IS BEING PAIRED, and therefore who is in it.
  #
  # Not the loop counter. An arbiter's bye is recorded BEFORE its round is
  # paired, so a player holding one has a game for a round that has not
  # happened. When EVERY player holds one - three withdrawals plus three
  # requested byes on a field of six, which the 12% bye axis reaches - the
  # round is entirely byes, and bbpPairings advances and pairs the round
  # after it. The loop counter says round 5; the reference is pairing round
  # 6, with the whole field active again.
  #
  # Taking the round from the data rather than the counter agrees with the
  # reference in both cases: the lowest game count is by definition a player
  # with no entry for the round about to be paired.
  #
  # Found by the active-set control, which reported `derived: []` against
  # `seated: [1, 2, 3, 4, 5, 6]` on 101 positions. Before the control
  # existed this would have been an empty field, a vacuously legal empty
  # pairing, and a false "a legal pairing exists" verdict against the
  # reference.
  defp round_being_paired(players) do
    players |> Enum.map(&length(&1.games)) |> Enum.min(fn -> 0 end) |> Kernel.+(1)
  end

  defp active_players(players) do
    r = round_being_paired(players)
    Enum.filter(players, &(length(&1.games) < r))
  end

  defp control?, do: System.get_env("BRUTE_CONTROL") in ["1", "true"]

  defp control(players, pairs, seed, round, total_rounds, forbidden) do
    active = active_players(players)
    ctx = context(round_being_paired(players), total_rounds, forbidden)

    seated =
      pairs
      |> Enum.flat_map(fn {w, b} -> if b, do: [w, b], else: [w] end)
      |> MapSet.new()

    derived = MapSet.new(active, & &1.rank)

    if derived != seated do
      note(%{
        class: :control_active_set_mismatch,
        seed: seed,
        round: round,
        derived: Enum.sort(derived),
        seated: Enum.sort(seated)
      })
    end

    # Only the CORRECT reading is asserted on. `:strict` deliberately drops
    # the topscorer exception and is therefore expected to answer
    # `:none_exists` for final-round positions the reference paired legally
    # - asserting on it would report the hedge itself as an oracle failure,
    # which is what it did at first.
    for reading <- [:with_exception] do
      case Brute.any_legal_round?(active, ctx, reading) do
        :legal_exists -> note(%{class: :control_ok, reading: reading})
        :too_big -> note(%{class: :control_skipped_too_big, reading: reading})
        :empty_field -> note(%{class: :control_empty_field, seed: seed, round: round})
        other -> note(%{class: :CONTROL_FAIL, seed: seed, round: round, reading: reading, got: other})
      end
    end
  end

  # Each tournament runs in its own Task, so the process dictionary is
  # private to it and `Driver.run/3` collects the log at the end. Printing
  # would have made a passing control indistinguishable from one that never
  # ran, which is the failure this whole file exists to avoid making.
  defp note(entry), do: Process.put(:control_log, [entry | Process.get(:control_log, [])])

  # The default 1/half/0 system written out rather than read from
  # `Ainalrami.Trf`, so this tool shares no constant with the engine it
  # checks.
  @default_points %{
    win: 1.0,
    draw: 0.5,
    loss: 0.0,
    pairing_allocated_bye: 1.0,
    forfeit_loss: 0.0,
    zero_point_bye: 0.0
  }

  defp context(round, total_rounds, forbidden) do
    %{
      played: round - 1,
      expected: total_rounds,
      ps: FuzzTournament.point_system() || @default_points,
      forbidden_set:
        Enum.reduce(forbidden, MapSet.new(), fn group, acc ->
          for a <- group, b <- group, a < b, into: acc, do: {a, b}
        end)
    }
  end

  defp verify(players, seed, round, total_rounds, player_count, forbidden, trf) do
    active = active_players(players)
    ctx = context(round_being_paired(players), total_rounds, forbidden)

    base = %{
      seed: seed,
      round: round,
      player_count: player_count,
      active: length(active),
      trf: trf
    }

    strict = Brute.any_legal_round?(active, ctx, :strict)
    loose = Brute.any_legal_round?(active, ctx, :with_exception)

    class =
      case {strict, loose} do
        {:empty_field, _} -> :empty_field_BUG
        {:too_big, _} -> :too_big
        {:none_exists, :none_exists} -> :proved_impossible
        {:none_exists, :legal_exists} -> :legal_under_topscorer_exception
        {:legal_exists, :legal_exists} -> :legal_exists
        {a, b} -> {:unexpected, a, b}
      end

    Map.put(base, :class, class)
  end
end

# ---------------------------------------------------------------- driver

from = String.to_integer(Enum.at(System.argv(), 0))
to = String.to_integer(Enum.at(System.argv(), 1))
rounds = String.to_integer(Enum.at(System.argv(), 2, "20"))
min_p = String.to_integer(Enum.at(System.argv(), 3, "4"))
max_p = String.to_integer(Enum.at(System.argv(), 4, "6"))
dump_dir = Enum.at(System.argv(), 5, "/root/bruteforce_dumps")

File.mkdir_p!(dump_dir)

IO.puts("brute force: seeds #{from}..#{to}, #{rounds} rounds, #{min_p}-#{max_p} players")

outcomes =
  from..to
  |> Task.async_stream(&Driver.run(&1, rounds, min_p..max_p),
    max_concurrency: System.schedulers_online(),
    timeout: :infinity,
    ordered: false
  )
  |> Enum.flat_map(fn {:ok, l} -> l end)

tally = Enum.frequencies_by(outcomes, & &1.class)
control_classes = [:control_ok, :control_skipped_too_big, :control_active_set_mismatch, :CONTROL_FAIL]

refused =
  Enum.count(outcomes, &(&1.class not in [:bbp_process_error, :harness_error] ++ control_classes))

IO.puts("\n=== #{to - from + 1} tournaments, #{refused} refusals examined ===")

for {class, n} <- Enum.sort_by(tally, &elem(&1, 1), :desc), class not in control_classes do
  pct = if refused > 0, do: Float.round(n / refused * 100, 3), else: 0.0
  IO.puts("  #{String.pad_trailing(inspect(class), 34)} #{String.pad_leading(to_string(n), 9)}   #{pct}%")
end

control_ran = Enum.count(outcomes, &(&1.class in control_classes))

if control_ran > 0 do
  ok = Map.get(tally, :control_ok, 0)
  failed = Map.get(tally, :CONTROL_FAIL, 0)
  mismatch = Map.get(tally, :control_active_set_mismatch, 0)

  IO.puts("
  positive control: #{ok} passed, #{failed} FAILED, #{mismatch} active-set mismatch")

  if failed > 0 or mismatch > 0 do
    IO.puts("  !! THE ORACLE IS WRONG - the negative result below means nothing")

    outcomes
    |> Enum.filter(&(&1.class in [:CONTROL_FAIL, :control_active_set_mismatch]))
    |> Enum.take(10)
    |> Enum.each(&IO.puts("     #{inspect(&1)}"))
  end
else
  IO.puts("
  positive control: NOT RUN (set BRUTE_CONTROL=1)")
end

bad = Enum.filter(outcomes, &(&1.class in [:legal_exists, :legal_under_topscorer_exception]))

if bad == [] do
  IO.puts("\n  Every refusal PROVED: no complete pairing satisfies C1, C2 and C3.")
else
  IO.puts("\n  #{length(bad)} refusal(s) where a legal pairing DOES exist - dumping to #{dump_dir}")

  bad
  |> Enum.take(200)
  |> Enum.each(fn o ->
    name = "#{o.class}-seed#{o.seed}-r#{o.round}-p#{o.player_count}-a#{o.active}"
    File.write!(Path.join(dump_dir, name <> ".trf"), o.trf)
  end)

  for o <- Enum.take(bad, 12) do
    IO.puts("    #{o.class} seed=#{o.seed} round=#{o.round} players=#{o.player_count} active=#{o.active}")
  end
end
