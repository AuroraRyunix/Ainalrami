# Bye preferences on the shortcut paths: every round of a generated
# tournament is paired under random preferences three times - the default
# configuration, the direct brackets switched off (`AINALRAMI_DIRECT=off`),
# and the check mode that holds every direct answer to the stages' and
# raises on a difference (`AINALRAMI_DIRECT=check`) - with the certified
# shortcuts forced on the large fields they are built for. The three must
# return the same pairs and the same report.
#
# The preferences only ever reach the engine as bye exclusions, which the
# direct and certified shortcuts read through the same eligibility
# predicate as the stages; this is the empirical side of that argument.
#
#   MIX_ENV=test mix run tools/bye_pref_direct.exs
#
# Environment: BPD_SEED_FROM (1), BPD_COUNT (40), BPD_MIN/BPD_MAX players
# (101/401), BPD_ROUNDS (7), BPD_CERT ("force" or unset).

alias Ainalrami.ByePreference
alias Ainalrami.Test.FuzzTournament, as: Fuzz

int = fn name, default -> name |> System.get_env(to_string(default)) |> String.to_integer() end
from = int.("BPD_SEED_FROM", 1)
count = int.("BPD_COUNT", 40)
range = int.("BPD_MIN", 101)..int.("BPD_MAX", 401)
rounds_asked = int.("BPD_ROUNDS", 7)

if cert = System.get_env("BPD_CERT"), do: System.put_env("AINALRAMI_CERT", cert)

modes = [nil, "off", "check"]

run_mode = fn mode, players, opts ->
  if mode, do: System.put_env("AINALRAMI_DIRECT", mode), else: System.delete_env("AINALRAMI_DIRECT")

  try do
    {:ok, ByePreference.pair(players, opts)}
  rescue
    e -> {:error, Exception.message(e)}
  after
    System.delete_env("AINALRAMI_DIRECT")
  end
end

draw = fn active ->
  ranks = Enum.map(active, & &1.rank)

  for _ <- 1..Enum.random(1..5) do
    {Enum.random(ranks), Enum.random(ByePreference.preferences())}
  end
end

totals =
  Enum.reduce(from..(from + count - 1), %{rounds: 0, odd: 0, moved: 0, differ: 0}, fn seed, acc ->
    {rounds, _n, forbidden, roster} = Fuzz.begin!(seed, rounds_asked, range)
    :rand.seed(:exsss, {seed, 17, 4711})

    {acc, _} =
      Enum.reduce_while(1..rounds, {acc, roster}, fn round, {acc, players} ->
        Fuzz.withdraw_some(round, length(roster))
        {active, pending} = Fuzz.reveal_late_entrants(players, round)
        active = Fuzz.assign_requested_byes(active)

        opts = [
          expected_rounds: rounds,
          forbidden_pairs: forbidden,
          initial_colour: String.downcase(Fuzz.initial_colour()),
          point_system: Fuzz.point_system(),
          bye_preferences: draw.(active)
        ]

        results = Enum.map(modes, &run_mode.(&1, active, opts))
        odd? = rem(map_size(Ainalrami.Pairing.round_scores(active)), 2) == 1

        acc = %{acc | rounds: acc.rounds + 1, odd: acc.odd + if(odd?, do: 1, else: 0)}

        acc =
          if Enum.uniq(results) == [hd(results)] do
            acc
          else
            IO.puts("DIFFER seed #{seed} round #{round}: #{inspect(results, limit: 12)}")
            %{acc | differ: acc.differ + 1}
          end

        case hd(results) do
          {:ok, {pairs, report}} ->
            acc = if report.moved, do: %{acc | moved: acc.moved + 1}, else: acc
            next = Fuzz.apply_round(active, pairs, Fuzz.simulate_results(pairs))
            {:cont, {acc, next ++ pending}}

          {:error, _} ->
            {:halt, {acc, players}}
        end
      end)

    IO.puts("seed #{seed}: #{inspect(acc)}")
    acc
  end)

IO.puts("TOTAL #{inspect(totals)}")
if totals.differ > 0, do: System.halt(1)
