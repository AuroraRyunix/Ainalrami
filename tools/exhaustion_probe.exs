# Exhaustion probe.
#
# The two-way corpus halts a tournament the moment bbpPairings answers "no
# legal pairing left", records it as `exhausted?`, and NEVER ASKS Ainalrami.
# 45.5% of tournaments in the ~488M-pairing runs ended that way, so the one
# behaviour the corpus is structurally blind to is this engine being willing
# to pair a round the reference declines.
#
# This asks. Same generator, same axes, same TRF - but on
# `{:no_valid_pairing, _}` it puts the identical position to Ainalrami and
# classifies what comes back:
#
#   both_refuse   - agreement. The expected result.
#   paired_dirty  - Ainalrami produced a pairing that violates a rule the
#                   independent oracle checks. That is OUR bug, and the
#                   blind spot realised.
#   paired_clean  - Ainalrami produced a pairing with no rematch, no second
#                   pairing-allocated bye, no forbidden pair, and a correct
#                   partition of the active field. Either bbpPairings was
#                   wrong to decline, or the pairing breaks something this
#                   oracle does not check (colour, the C-criteria).
#                   Every one of these is dumped for inspection.
#
# The partition/bye-count checks need an `active` set. The corpus normally
# takes it from bbpPairings' own answer, which does not exist here, so it is
# derived from the players' own game lists instead - the same rule
# `Pairing.active_this_round?/2` uses. That is circular for those two checks
# and is why they are reported separately from the three that are not:
# rematch, repeat bye and forbidden pair are checked against the recorded
# game history alone and share nothing with the engine's own reasoning.

alias Ainalrami.Test.{Bbppairings, FuzzTournament}
alias Ainalrami.Pairing

defmodule Probe do
  def run(seed, rounds, player_range) do
    {rounds, player_count, forbidden, roster} =
      FuzzTournament.begin!(seed, rounds, player_range)

    {outcomes, _} =
      Enum.reduce_while(1..rounds, {[], roster}, fn round, {acc, players} ->
        FuzzTournament.withdraw_some(round, player_count)

        case play(players, seed, round, rounds, player_count, forbidden) do
          {:cont, next} -> {:cont, {acc, next}}
          {:halt, outcome} -> {:halt, {[outcome | acc], players}}
        end
      end)

    outcomes
  rescue
    e -> [%{class: :harness_error, seed: seed, detail: Exception.message(e) |> String.slice(0, 160)}]
  end

  defp play(players, seed, round, total_rounds, player_count, forbidden) do
    players = FuzzTournament.assign_requested_byes(players)
    trf = FuzzTournament.build_trf(players, total_rounds, forbidden)

    case Bbppairings.pair(trf) do
      {:no_valid_pairing, _msg} ->
        {:halt, probe_exhausted(players, seed, round, total_rounds, player_count, forbidden, trf)}

      {:ok, bbp_pairs} ->
        results = FuzzTournament.simulate_results(bbp_pairs)
        {:cont, FuzzTournament.apply_round(players, bbp_pairs, results)}

      _other ->
        {:halt, %{class: :bbp_process_error, seed: seed, round: round}}
    end
  end

  # bbpPairings says there is no legal pairing. Ask Ainalrami the same thing.
  defp probe_exhausted(players, seed, round, total_rounds, player_count, forbidden, trf) do
    base = %{seed: seed, round: round, player_count: player_count, trf: trf}

    case safely_pair(players, total_rounds, forbidden) do
      {:raised, %Pairing.NoValidPairingError{}} ->
        Map.put(base, :class, :both_refuse)

      {:raised, e} ->
        base
        |> Map.put(:class, :ainalrami_crashed)
        |> Map.put(:detail, Exception.message(e) |> String.slice(0, 200))

      pairs ->
        case violation(pairs, players, forbidden) do
          nil -> base |> Map.put(:class, :paired_clean) |> Map.put(:pairs, pairs)
          why -> base |> Map.put(:class, :paired_dirty) |> Map.put(:why, why) |> Map.put(:pairs, pairs)
        end
    end
  end

  defp safely_pair(players, total_rounds, forbidden) do
    Pairing.pair_next_round(players,
      expected_rounds: total_rounds,
      forbidden_pairs: forbidden,
      initial_colour: String.downcase(FuzzTournament.initial_colour()),
      point_system: FuzzTournament.point_system()
    )
  rescue
    e -> {:raised, e}
  end

  # The corpus's own oracle, minus its dependence on bbpPairings' answer.
  # The three history-only checks come first, because those are the ones
  # that share nothing with the engine being checked.
  defp violation(pairs, players, forbidden) do
    by_rank = Map.new(players, &{&1.rank, &1})

    rematch? =
      Enum.any?(pairs, fn
        {_w, nil} -> false
        {w, b} ->
          Enum.any?(
            Map.fetch!(by_rank, w).games,
            &(&1.result in ~w(1 = 0) and &1.opponent_rank == b)
          )
      end)

    repeat_bye? =
      Enum.any?(pairs, fn
        {w, nil} -> Enum.any?(Map.fetch!(by_rank, w).games, &(&1.result in ~w(U F +)))
        _ -> false
      end)

    forbidden_set =
      Enum.reduce(forbidden, MapSet.new(), fn group, acc ->
        for a <- group, b <- group, a < b, into: acc, do: {a, b}
      end)

    forbidden_pair? =
      Enum.any?(pairs, fn
        {_w, nil} -> false
        {w, b} -> MapSet.member?(forbidden_set, {min(w, b), max(w, b)})
      end)

    # Derived from the game lists, not from the reference. Circular with the
    # engine for exactly these two checks - flagged in the class name.
    active =
      players
      |> Enum.reject(&sitting_out?/1)
      |> MapSet.new(& &1.rank)

    seated = Enum.flat_map(pairs, fn {w, b} -> if b, do: [w, b], else: [w] end)
    byes = Enum.count(pairs, fn {_w, b} -> is_nil(b) end)

    cond do
      rematch? -> :rematch
      repeat_bye? -> :repeat_bye
      forbidden_pair? -> :forbidden_pair
      MapSet.new(seated) != active -> :not_a_partition_derived
      byes != rem(MapSet.size(active), 2) -> :bad_bye_count_derived
      true -> nil
    end
  end

  # A player whose LAST recorded game is an arbiter's bye is sitting the
  # round out; it was recorded before the round was paired.
  defp sitting_out?(player) do
    case List.last(player.games) do
      nil -> false
      game -> is_nil(game.opponent_rank) and game.result in ~w(H Z F)
    end
  end
end

# ---------------------------------------------------------------- driver

from = String.to_integer(Enum.at(System.argv(), 0))
to = String.to_integer(Enum.at(System.argv(), 1))
rounds = String.to_integer(Enum.at(System.argv(), 2, "9"))
min_p = String.to_integer(Enum.at(System.argv(), 3, "4"))
max_p = String.to_integer(Enum.at(System.argv(), 4, "10"))
dump_dir = Enum.at(System.argv(), 5, "/root/exhaustion_dumps")

File.mkdir_p!(dump_dir)
range = min_p..max_p

IO.puts("probe: seeds #{from}..#{to}, #{rounds} rounds, #{min_p}-#{max_p} players")

outcomes =
  from..to
  |> Task.async_stream(&Probe.run(&1, rounds, range),
    max_concurrency: System.schedulers_online(),
    timeout: :infinity,
    ordered: false
  )
  |> Enum.flat_map(fn {:ok, list} -> list end)

tally = Enum.frequencies_by(outcomes, & &1.class)
total_exhausted = Enum.count(outcomes, &(&1.class in [:both_refuse, :paired_clean, :paired_dirty, :ainalrami_crashed]))

IO.puts("\n=== #{to - from + 1} tournaments, #{total_exhausted} reached exhaustion ===")

for {class, n} <- Enum.sort_by(tally, &elem(&1, 1), :desc) do
  pct = if total_exhausted > 0, do: Float.round(n / total_exhausted * 100, 2), else: 0.0
  IO.puts("  #{String.pad_trailing(to_string(class), 24)} #{String.pad_leading(to_string(n), 8)}   #{pct}%")
end

interesting = Enum.filter(outcomes, &(&1.class in [:paired_clean, :paired_dirty, :ainalrami_crashed]))

if interesting == [] do
  IO.puts("\n  Ainalrami refused every position bbpPairings refused. No disagreement.")
else
  IO.puts("\n  #{length(interesting)} DISAGREEMENT(S) - dumping to #{dump_dir}")

  interesting
  |> Enum.take(200)
  |> Enum.each(fn o ->
    name = "#{o.class}-seed#{o.seed}-r#{o.round}-p#{o.player_count}"
    File.write!(Path.join(dump_dir, name <> ".trf"), o.trf)

    File.write!(
      Path.join(dump_dir, name <> ".txt"),
      """
      class:   #{o.class}
      seed:    #{o.seed}
      round:   #{o.round}
      players: #{o.player_count}
      why:     #{inspect(Map.get(o, :why))}
      detail:  #{inspect(Map.get(o, :detail))}
      pairs:   #{inspect(Map.get(o, :pairs))}
      """
    )
  end)

  for o <- Enum.take(interesting, 12) do
    IO.puts("    #{o.class} seed=#{o.seed} round=#{o.round} players=#{o.player_count} why=#{inspect(Map.get(o, :why))}")
  end
end
