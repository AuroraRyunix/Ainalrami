# ADVERSARIAL micro-fuzz for Article 5.2.5's arrival numbering.
#
# Plays small tournaments forward one round at a time, asking BOTH this
# engine and the real bbpPairings binary to pair the identical file, and
# diffing the COLOUR on every board the two agree on the composition of.
# bbpPairings' own answer is what the tournament then advances on, so a
# disagreement in one round cannot corrupt the measurement of the next.
#
# What it generates that `Ainalrami.Test.FuzzTournament` cannot:
#
#   * LATE ENTRIES - players whose early rounds are wholly BLANK and who
#     appear for the first time mid-tournament. That is the one shape the
#     SPP's ruling is actually about, and the built-in generator has no way
#     to express it.
#   * `F` byes, which the built-in generator never emits (it draws from
#     H/Z only), and which are the counter-intuitive half of the membership
#     rule: score 1.0 like a `U` bye, but NOT an arrival.
#   * a mixed `152` - half the tournaments are drawn Black-first.
#   * withdrawals stacked on top of both.
#
# Deliberately small: ~80 tournaments of at most 5 rounds. This is a
# targeted probe, not a corpus run.
#
#   BBPPAIRINGS_EXE=../openpairings/priv/bbppairings/bbpPairings-windows.exe \
#     ADV_COUNT=80 MIX_ENV=test mix run tools/adv_colour_fuzz.exs

exe = System.get_env("BBPPAIRINGS_EXE", "../openpairings/priv/bbppairings/bbpPairings-windows.exe")
count = String.to_integer(System.get_env("ADV_COUNT", "80"))
rounds = String.to_integer(System.get_env("ADV_ROUNDS", "5"))
seed_from = String.to_integer(System.get_env("ADV_SEED_FROM", "1"))
bye_pct = String.to_integer(System.get_env("ADV_BYE_PCT", "35"))
max_players = String.to_integer(System.get_env("ADV_MAX_PLAYERS", "14"))

blank = %{opponent_rank: nil, colour: nil, result: ""}

points_for = fn result ->
  cond do
    result in ~w(1 + U F W) -> 1.0
    result in ~w(= H D) -> 0.5
    true -> 0.0
  end
end

bye = fn code -> %{opponent_rank: nil, colour: nil, result: code} end

new_player = fn rank ->
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

append = fn player, game ->
  %{player | games: player.games ++ [game], points: player.points + points_for.(game.result)}
end

pairs_of = fn text ->
  text
  |> String.split(~r/\r?\n/)
  |> Enum.reject(&(String.trim(&1) == ""))
  |> tl()
  |> Enum.map(fn l ->
    [w, b] = l |> String.trim() |> String.split(~r/\s+/)
    {String.to_integer(w), String.to_integer(b)}
  end)
end

board_map = fn ps ->
  for {w, b} <- ps, b != nil, b != 0, into: %{}, do: {Enum.sort([w, b]), w}
end


# --- an INDEPENDENT re-derivation of both readings -------------------------
#
# Without this the run measures nothing: most boards are decided by a colour
# preference (5.2.1-5.2.4) and never reach 5.2.5 at all, so a run of zeroes
# would be consistent with the rule never having been consulted. These
# helpers reimplement the numbering from the ruling rather than calling into
# `Ainalrami.Pairing` (whose version is private, and is the thing under
# test), and classify each shared board as
#
#   :tpn_only    bbp's white is what the OVERTURNED reading predicts
#   :arrival_only  bbp's white is what the RULING predicts
#   :both        the two readings coincide - the board proves nothing
#
played_codes = ~w(1 0 = W D L)
played? = fn gm -> gm.result in played_codes end
participated? = fn gm -> gm.opponent_rank != nil or gm.result in ~w(U +) end

paired_through = fn p ->
  p.games
  |> Enum.with_index(1)
  |> Enum.filter(fn {gm, _} -> participated?.(gm) end)
  |> Enum.map(fn {_, r} -> r end)
  |> Enum.max(fn -> 0 end)
end

rounds_played_of = fn roster ->
  base = roster |> Enum.map(paired_through) |> Enum.max(fn -> 0 end)
  if roster != [] and Enum.all?(roster, &(length(&1.games) > base)), do: base + 1, else: base
end

arrival_numbers_of = fn roster ->
  played = rounds_played_of.(roster)

  roster
  |> Enum.sort_by(& &1.rank)
  |> Enum.filter(fn p ->
    length(p.games) <= played or
      p.games |> Enum.take(played) |> Enum.any?(participated?)
  end)
  |> Enum.with_index(1)
  |> Map.new(fn {p, n} -> {p.rank, n} end)
end

tally = :ets.new(:tally, [:public, :duplicate_bag])

path = Path.join(System.tmp_dir!(), "adv_fuzz.trf")
out = Path.join(System.tmp_dir!(), "adv_fuzz_out.txt")

Enum.each(seed_from..(seed_from + count - 1), fn seed ->
  :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 3})

  n = Enum.random(6..max_players)
  ic = Enum.random(["W", "B"])

  # Late entries: 0-2 players, each arriving in round 2..3. An ODD count is
  # what shifts parity, so one is drawn twice as often as two.
  late_count = Enum.random([0, 1, 1, 1, 2])

  late =
    1..n
    |> Enum.shuffle()
    |> Enum.take(late_count)
    |> Map.new(fn rank -> {rank, Enum.random([2, 3])} end)

  players = Map.new(1..n, fn rank -> {rank, new_player.(rank)} end)
  withdrawn = MapSet.new()

  Enum.reduce_while(1..rounds, {players, withdrawn}, fn round, {players, withdrawn} ->
    # --- absences recorded BEFORE the pairing --------------------------
    {players, sitting} =
      Enum.reduce(1..n, {players, MapSet.new()}, fn rank, {acc, out_set} ->
        player = acc[rank]
        arrival = Map.get(late, rank)

        cond do
          arrival != nil and round < arrival ->
            {Map.put(acc, rank, append.(player, blank)), MapSet.put(out_set, rank)}

          MapSet.member?(withdrawn, rank) ->
            {Map.put(acc, rank, append.(player, bye.("Z"))), MapSet.put(out_set, rank)}

          :rand.uniform(100) <= bye_pct ->
            {Map.put(acc, rank, append.(player, bye.(Enum.random(~w(H Z F))))),
             MapSet.put(out_set, rank)}

          true ->
            {acc, out_set}
        end
      end)

    roster = 1..n |> Enum.map(&players[&1])
    playing = Enum.reject(roster, &MapSet.member?(sitting, &1.rank))

    if length(playing) < 2 do
      :ets.insert(tally, {:starved, "seed #{seed} r#{round}"})
      {:halt, {players, withdrawn}}
    else
      trf =
        Ainalrami.Trf.serialize(%{
          tournament: %{
            name: "advfuzz #{seed}",
            type: "swiss",
            number_of_rounds: rounds,
            initial_colour: String.downcase(ic)
          },
          players: roster
        })

      File.write!(path, trf)

      bbp =
        case System.cmd(exe, ["--dutch", path, "-p", out], stderr_to_stdout: true) do
          {_, 0} -> pairs_of.(File.read!(out))
          {msg, code} -> {:refused, code, String.slice(String.trim(msg), 0, 100)}
        end

      ours =
        try do
          Ainalrami.Pairing.pair_next_round(roster,
            expected_rounds: rounds,
            initial_colour: String.downcase(ic)
          )
        rescue
          e -> {:raised, Exception.message(e)}
        end

      case {bbp, ours} do
        {{:refused, code, msg}, _} ->
          :ets.insert(tally, {:refused, "seed #{seed} r#{round} exit #{code}: #{msg}"})
          {:halt, {players, withdrawn}}

        {_, {:raised, msg}} ->
          :ets.insert(tally, {:raised, "seed #{seed} r#{round}: #{msg}"})
          File.write!(Path.join(System.tmp_dir!(), "adv_raise_#{seed}_#{round}.trf"), trf)
          {:halt, {players, withdrawn}}

        _ ->
          # INSTRUMENT SELF-TEST. With ADV_SELFTEST=1 our own answer is
          # corrupted on one board per round before the diff runs. A run that
          # still reports `colour: 0` is measuring nothing, which is the
          # failure mode this whole file exists to avoid.
          ours =
            if System.get_env("ADV_SELFTEST") == "1" do
              case Enum.find(ours, fn {_, bl} -> bl != nil and bl != 0 end) do
                nil -> ours
                {w, bl} -> List.delete(ours, {w, bl}) ++ [{bl, w}]
              end
            else
              ours
            end

          o = board_map.(ours)
          b = board_map.(bbp)
          shared = o |> Map.keys() |> Enum.filter(&Map.has_key?(b, &1))
          bad = Enum.filter(shared, &(Map.get(o, &1) != Map.get(b, &1)))

          :ets.insert(tally, {:boards, length(shared)})

          # --- classify the boards that actually reach 5.2.5 --------------
          by_rank = Map.new(roster, &{&1.rank, &1})
          numbers = arrival_numbers_of.(roster)
          initial = String.downcase(ic)

          Enum.each(shared, fn brd ->
            [x, y] = brd
            px = by_rank[x]
            py = by_rank[y]

            if not Enum.any?(px.games ++ py.games, played?) do
              {top, bottom} =
                if {-px.points, px.rank} <= {-py.points, py.rank}, do: {px, py}, else: {py, px}

              white_for = fn number ->
                takes_initial? = rem(number, 2) == 1
                if takes_initial? == (initial == "w"), do: top.rank, else: bottom.rank
              end

              tpn_white = white_for.(top.rank)
              arr_white = white_for.(Map.get(numbers, top.rank, top.rank))
              bbp_white = Map.get(b, brd)

              tag =
                cond do
                  tpn_white == arr_white -> :both
                  bbp_white == arr_white -> :arrival_only
                  bbp_white == tpn_white -> :tpn_only
                  true -> :neither
                end

              :ets.insert(tally, {:reach, tag})

              if tag in [:tpn_only, :neither] do
                dump = Path.join(System.tmp_dir!(), "adv_reach_#{seed}_#{round}.trf")
                File.write!(dump, trf)

                :ets.insert(
                  tally,
                  {:reference_broke_ruling,
                   "seed #{seed} r#{round} 152 #{ic} board #{inspect(brd)} tag=#{tag}" <>
                     " bbp_white=#{bbp_white} arrival_white=#{arr_white} tpn_white=#{tpn_white}" <>
                     "  [#{dump}]"}
                )
              end
            end
          end)

          if Map.keys(o) != Map.keys(b) do
            :ets.insert(tally, {:board_mismatch, "seed #{seed} r#{round}"})
          end

          Enum.each(bad, fn brd ->
            dump = Path.join(System.tmp_dir!(), "adv_colour_#{seed}_#{round}.trf")
            File.write!(dump, trf)

            :ets.insert(
              tally,
              {:colour,
               "seed #{seed} round #{round} 152 #{ic} board #{inspect(brd)}:" <>
                 " ours white=#{Map.get(o, brd)} bbp white=#{Map.get(b, brd)}  [#{dump}]"}
            )
          end)

          # --- advance on bbpPairings' own answer ------------------------
          players =
            Enum.reduce(bbp, players, fn
              {w, 0}, acc ->
                Map.put(acc, w, append.(acc[w], bye.("U")))

              {w, bl}, acc ->
                case Enum.random([:played, :played, :played, :played, :played, :played, :wf, :bf, :df]) do
                  :played ->
                    r = Enum.random(~w(1 = 0))
                    inv = %{"1" => "0", "=" => "=", "0" => "1"}

                    acc
                    |> Map.put(w, append.(acc[w], %{opponent_rank: bl, colour: "w", result: r}))
                    |> Map.put(
                      bl,
                      append.(acc[bl], %{opponent_rank: w, colour: "b", result: inv[r]})
                    )

                  :wf ->
                    acc
                    |> Map.put(w, append.(acc[w], %{opponent_rank: bl, colour: "w", result: "-"}))
                    |> Map.put(bl, append.(acc[bl], %{opponent_rank: w, colour: "b", result: "+"}))

                  :bf ->
                    acc
                    |> Map.put(w, append.(acc[w], %{opponent_rank: bl, colour: "w", result: "+"}))
                    |> Map.put(bl, append.(acc[bl], %{opponent_rank: w, colour: "b", result: "-"}))

                  :df ->
                    acc
                    |> Map.put(w, append.(acc[w], %{opponent_rank: bl, colour: "w", result: "-"}))
                    |> Map.put(bl, append.(acc[bl], %{opponent_rank: w, colour: "b", result: "-"}))
                end
            end)

          withdrawn =
            if round >= 2 and MapSet.size(withdrawn) < div(n, 3) and :rand.uniform(100) <= 20 do
              MapSet.put(withdrawn, Enum.random(1..n))
            else
              withdrawn
            end

          {:cont, {players, withdrawn}}
      end
    end
  end)
end)

boards = :ets.lookup(tally, :boards) |> Enum.map(&elem(&1, 1)) |> Enum.sum()
IO.puts("\n#{count} tournaments, #{boards} shared boards compared")

reach = :ets.lookup(tally, :reach) |> Enum.map(&elem(&1, 1)) |> Enum.frequencies()
IO.puts("5.2.5-decidable boards: #{inspect(reach)}")

for tag <- [:colour, :reference_broke_ruling, :raised, :board_mismatch, :refused, :starved] do
  rows = :ets.lookup(tally, tag) |> Enum.map(&elem(&1, 1))
  IO.puts("\n#{tag}: #{length(rows)}")
  rows |> Enum.take(25) |> Enum.each(&IO.puts("   - #{&1}"))
end
