defmodule Ainalrami.TiebreakReference.Proof do
  @moduledoc """
  The events the tie-break proof runs on, and the comparison of
  `Ainalrami.Tiebreaks` with `Ainalrami.TiebreakReference` on them.

  `run(seed)` picks the kind of event from the seed:

    * Swiss events from `Ainalrami.Generator` with its checklist options
      (every bye kind, forfeits, double forfeits, odd results, FIDE-table
      results, stepped or partly unrated ratings), sometimes rescored 3/1/0,
      sometimes also compared on the standings after an earlier round;
    * round robins (single or double, odd or even, with withdrawals whose
      remaining games are forfeited);
    * board-level team events from `Ainalrami.TeamTrfGenerator`, read by the
      engine through `Ainalrami.Tiebreaks.Team.from_trf/2` and by the reference
      through its own `from_team_trf/2`;
    * team events built match by match, with the unplayed rounds the TRF
      path cannot express (half- and zero-point byes, forfeited matches) and
      deliberate rematches.

  Every value of every code is compared, then the final ranks under
  several lists. Returns `%{events:, values:, bad: [description]}`.
  """

  alias Ainalrami.{Generator, Trf}
  alias Ainalrami.TiebreakReference, as: Ref
  alias Ainalrami.Tiebreaks
  alias Ainalrami.Tiebreaks.{Event, Team}
  alias Ainalrami.Tiebreaks.Team.{Entry, Match}

  @swiss ~w(PTS WIN WON BPG BWG PS PS/C1 PS/C2 REP STD TPN BH BH/C1 BH/C2 BH/M1 BH/M2
            FB FB/C1 FB/C2 FB/M1 AOB AOB/F SB SB/C1 SB/C2 KS KS/L1 KS/L-1 KS/L2 KS/L-2
            ARO ARO/C1 ARO/C2 ARO/M1 ARO/M2 TPR PTP APRO APPO RTNG RTNG/R)
  @unrated ~w(ARO/U1400 ARO/C1/U1400 TPR/U1400 PTP/U1400 APRO/U1400 APPO/U1400 RTNG/U1400)
  @buchholz ~w(BH BH/C1 BH/C2 BH/M1 BH/M2 FB FB/C1 FB/C2 FB/M1 AOB AOB/F)

  @team ~w(MPTS GPTS MPVGP BH:MP BH:GP BH:MP/C1 BH:GP/C2 BH:MP/M1 FB:MP FB:GP/C1 AOB:MP AOB:GP/F
           SB:MP SB:GP SB:MP/C1 SB:GP/C2 EMMSB EMGSB EGMSB EGGSB EMMSB/C1 EMGSB/C1 EGMSB/C1
           EGGSB/C1 PS:MP PS:GP/C1 KS:MP KS:GP KS:MP/L1 KS:GP/L-1 WIN:MP WON:GP STD:MP STD:GP
           REP TPN SSSC SSSC/F)
  @team_lists [
    ~w(MPTS GPTS EDE BH:MP EMGSB),
    ~w(MPTS EDEBT),
    ~w(MPTS GPTS EDEBB),
    ~w(MPTS EDET),
    ~w(GPTS EDEB),
    ~w(MPTS BC TBR BBE),
    ~w(MPTS TBR),
    ~w(MPTS BBE BC),
    ~w(MPTS DE:GP SSSC),
    ~w(MPTS EDE/P TPN),
    ~w(EDE MPVGP),
    ~w(PTS DE SB:MP/C1 EDEBT)
  ]

  @doc """
  One event from `seed`; see the moduledoc. `kind: :team_trf` makes every
  seed a board-level team event (the team scale mode).
  """
  def run(seed, kind \\ :all)

  def run(seed, :team_trf), do: team_trf(seed, rem(seed, 10))

  def run(seed, :all) do
    case rem(seed, 10) do
      r when r in 0..4 -> swiss(seed)
      r when r in 5..6 -> round_robin(seed)
      7 -> team_trf(seed)
      _ -> team_direct(seed)
    end
  end

  # ======================================================================
  # Comparison
  # ======================================================================

  @doc """
  Compares engine and reference on an individual event (a parsed TRF and
  `Event.from_trf/2`'s options).
  """
  def compare_individual(trf, opts, codes, lists, label) do
    event = Event.from_trf(trf, opts)
    model = Ref.from_trf(trf, opts)
    compare(event, model, codes, lists, label)
  end

  def compare_team(team, codes, lists, label) do
    compare(team, Ref.from_team(team), codes, lists, label)
  end

  @doc """
  Compares engine and reference on a board-level team TRF (a parsed map),
  each reading it its own way: `Team.from_trf/2` against
  `Ref.from_team_trf/2`. Options: `:primary`.
  """
  def compare_team_trf(trf, codes, lists, label, opts \\ []) do
    compare(Team.from_trf(trf, opts), Ref.from_team_trf(trf, opts), codes, lists, label)
  end

  defp compare(event, model, codes, lists, label) do
    {:ok, engine} = Tiebreaks.compute(event, codes)

    # `Tiebreaks.compute/2` reads the whole list (reading T5); so does the
    # reference, through `for_list/2`.
    listed = Ref.for_list(model, codes)

    value_bad =
      for c <- codes,
          bad = value_diff(c, Map.fetch!(engine, c), Ref.values(listed, c)),
          bad != [] do
        "#{label} #{c}: #{inspect(Enum.take(bad, 4))}"
      end

    values =
      Enum.reduce(codes, 0, fn c, acc ->
        acc + if(is_map(engine[c]), do: map_size(engine[c]), else: 1)
      end)

    {rank_bad, ranks} =
      Enum.reduce(lists, {[], 0}, fn list, {bad, n} ->
        {:ok, rows} = Tiebreaks.rank(event, list)
        engine_ranks = Map.new(rows, &{&1.id, &1.rank})
        ref_ranks = Ref.rank(model, list)

        diff =
          for {id, r} <- engine_ranks, ref_ranks[id] != r, do: {id, r, ref_ranks[id]}

        bad =
          if diff == [],
            do: bad,
            else: ["#{label} ranks #{Enum.join(list, " ")}: #{inspect(Enum.take(diff, 6))}" | bad]

        {bad, n + map_size(engine_ranks)}
      end)

    %{events: 1, values: values + ranks, bad: value_bad ++ Enum.reverse(rank_bad)}
  end

  defp value_diff(_c, :dropped, :dropped), do: []
  defp value_diff(c, :dropped, other), do: [{c, :engine_dropped, other}]
  defp value_diff(c, other, :dropped), do: [{c, :reference_dropped, map_size(other)}]

  defp value_diff(_c, engine, ref) do
    for {id, e} <- Enum.sort(engine), not same?(e, ref[id]), do: {id, e, ref[id]}
  end

  defp same?(nil, nil), do: true
  defp same?(a, b) when is_number(a) and is_number(b), do: abs(a - b) < 1.0e-6
  defp same?(_, _), do: false

  @doc "Adds two results together."
  def add(a, b),
    do: %{events: a.events + b.events, values: a.values + b.values, bad: a.bad ++ b.bad}

  def zero, do: %{events: 0, values: 0, bad: []}

  # ======================================================================
  # Swiss (Ainalrami.Generator)
  # ======================================================================

  @doc false
  def swiss(seed) do
    :rand.seed(:exsss, {seed, 3 * seed + 7, 11 * seed + 1})
    players = Enum.random(4..24)
    rounds = Enum.random(2..9)

    ratings =
      case Enum.random(1..4) do
        1 -> {:step, Enum.random(1900..2600), Enum.random(3..60)}
        # some unrated players (0)
        2 -> for _ <- 1..players, do: Enum.random([0, 0 | Enum.to_list(1500..2400//7)])
        # equal ratings in blocks, for ties in rating tie-breaks
        3 -> for i <- 1..players, do: 2000 + div(i, 3) * 25
        4 -> nil
      end

    opts =
      [
        seed: seed,
        players: players,
        rounds: rounds,
        forfeit_pct: Enum.random([0, 5, 12]),
        requested_bye_pct: Enum.random([0, 5, 12, 25]),
        full_bye_pct: Enum.random([0, 0, 4, 10]),
        half_bye_pct: Enum.random([0, 5, 12]),
        zero_bye_pct: Enum.random([0, 4, 10]),
        forfeit_win_pct: Enum.random([0, 4, 10]),
        double_forfeit_pct: Enum.random([0, 3, 8]),
        odd_results_pct: Enum.random([0, 3, 8]),
        results: Enum.random([:uniform, :fide])
      ] ++ if(ratings, do: [ratings: ratings], else: [])

    {text, _} = Generator.generate(opts)
    trf = Trf.parse(text)

    # One event in four is scored 3/1/0: every "points for a draw" and
    # "points for a win" in the text has to follow the scoring.
    # Another in four gives the pairing-allocated bye a draw's value, so
    # its outcome (16.3.1, 16.4) is a draw and it is no longer a "win" (7.1).
    trf =
      case rem(div(seed, 10), 4) do
        3 ->
          put_in(trf, [:tournament, :point_system], %{
            win: 3.0,
            draw: 1.0,
            loss: 0.0,
            pairing_allocated_bye: 3.0,
            forfeit_loss: 0.0,
            zero_point_bye: 0.0
          })

        1 ->
          put_in(trf, [:tournament, :point_system], %{
            win: 1.0,
            draw: 0.5,
            loss: 0.0,
            pairing_allocated_bye: 0.5,
            forfeit_loss: 0.0,
            zero_point_bye: 0.0
          })

        _ ->
          trf
      end

    unrated? = Enum.any?(trf.players, &(Map.get(&1, :fide_rating) in [nil, 0]))
    codes = @swiss ++ if(unrated?, do: @unrated, else: [])
    played = trf.players |> Enum.map(&length(&1.games)) |> Enum.max(fn -> 0 end)

    lists = [~w(BH/C1 BH SB DE), ~w(DE BH/C1 SB), ~w(DE/P WIN STD), random_list(codes, 4)]
    full = compare_individual(trf, [], codes, lists, "seed #{seed} swiss")

    # Standings part-way through: "the final round" of 8.3 is not yet
    # played, and 16.4.2's rounds are the rounds counted (reading 11).
    if played > 2 and rem(seed, 3) == 0 do
      k = Enum.random(1..(played - 1))
      part = compare_individual(trf, [rounds: k], codes, lists, "seed #{seed} swiss@#{k}")
      %{add(full, part) | events: 1}
    else
      full
    end
  end

  defp random_list(codes, k) do
    picked = codes |> Enum.reject(&(&1 == "PTS")) |> Enum.take_random(k)
    List.insert_at(picked, Enum.random(0..k), Enum.random(["DE", "DE/P"]))
  end

  # ======================================================================
  # Round robins
  # ======================================================================

  @doc false
  def round_robin(seed) do
    :rand.seed(:exsss, {seed, 5 * seed + 3, 13 * seed + 9})
    size = Enum.random(3..12)
    cycles = Enum.random([1, 1, 2])
    field = if rem(size, 2) == 1, do: size + 1, else: size
    rating = Map.new(1..size, &{&1, Enum.random([0, 1700, 1850, 2000, 2100, 2250, 2400])})
    withdrawn = if :rand.uniform() < 0.3, do: {Enum.random(1..size), Enum.random(1..size)}

    # The circle method: `field` stays put, the others rotate; in an odd
    # field `field` is nobody, and meeting it is the free round.
    others = Enum.to_list(1..(field - 1))

    schedule =
      for cycle <- 1..cycles, r <- 1..(field - 1) do
        circle = [field | Enum.drop(others, r - 1) ++ Enum.take(others, r - 1)]

        for i <- 0..(div(field, 2) - 1) do
          a = Enum.at(circle, i)
          b = Enum.at(circle, field - 1 - i)
          {a, b} = if rem(r + i, 2) == 0, do: {a, b}, else: {b, a}
          if cycle == 2, do: {b, a}, else: {a, b}
        end
      end

    total = length(schedule)
    rounds = if :rand.uniform() < 0.8, do: total, else: Enum.random(1..total)

    empty = Map.new(1..size, &{&1, []})

    games =
      schedule
      |> Enum.take(rounds)
      |> Enum.with_index(1)
      |> Enum.reduce(empty, fn {pairs, r}, games ->
        Enum.reduce(pairs, games, fn {w, b}, games ->
          cond do
            w > size -> Map.update!(games, b, &(&1 ++ [free()]))
            b > size -> Map.update!(games, w, &(&1 ++ [free()]))
            true -> rr_game(games, w, b, r, withdrawn)
          end
        end)
      end)

    trf = %{
      tournament: %{name: "rr #{seed}", number_of_rounds: total, type_code: "FIDE_ROUNDROBIN"},
      teams: [],
      players:
        for id <- 1..size do
          %{rank: id, fide_rating: rating[id], games: games[id]}
        end
    }

    codes = (@swiss -- @buchholz) ++ @unrated
    lists = [~w(DE SB KS), ~w(DE/P SB WIN), ~w(SB DE KS/L1), random_list(codes -- ~w(DE), 3)]
    compare_individual(trf, [], codes, lists, "seed #{seed} rr#{size}x#{cycles}")
  end

  defp free, do: %{opponent_rank: nil, colour: nil, result: "Z"}

  defp rr_game(games, w, b, r, withdrawn) do
    {rw, rb} =
      case withdrawn do
        {^w, from} when r >= from ->
          {"-", "+"}

        {^b, from} when r >= from ->
          {"+", "-"}

        _ ->
          x = :rand.uniform()

          cond do
            x < 0.04 -> {"+", "-"}
            x < 0.07 -> {"-", "-"}
            x < 0.40 -> {"=", "="}
            x < 0.72 -> {"1", "0"}
            true -> {"0", "1"}
          end
      end

    games
    |> Map.update!(w, &(&1 ++ [%{opponent_rank: b, colour: "w", result: rw}]))
    |> Map.update!(b, &(&1 ++ [%{opponent_rank: w, colour: "b", result: rb}]))
  end

  # ======================================================================
  # Board-level team events, as tools/team_tiebreak_compare.exs builds them
  # ======================================================================

  @doc """
  A board-level team event from `Ainalrami.TeamTrfGenerator` (Swiss, team
  round robin, Scheveningen or Schiller; 3-10 boards; 2/1/0 or 3/1/0;
  reserves, individual and whole-match forfeits, `330` records), read by
  the engine through `Team.from_trf/2` and by the reference through its
  own `from_team_trf/2`: every value and rank compared, so the engine's
  reading of the TRF is checked too. `selector` picks the format (0-9, see
  the generator); by default it comes from the seed.
  """
  def team_trf(seed, selector \\ nil) do
    selector = selector || rem(div(seed, 10), 10)
    gen = Ainalrami.TeamTrfGenerator.generate(seed, selector: selector)
    primary = if rem(div(seed, 100), 3) == 2, do: :gp, else: :mp
    trf = Trf.parse(gen.text)

    {codes, lists} =
      if gen.predetermined?,
        do:
          {Enum.reject(@team, &buchholz?/1),
           Enum.map(team_lists(seed), &Enum.reject(&1, fn c -> buchholz?(c) end))},
        else: {@team, team_lists(seed)}

    compare_team_trf(trf, codes, lists, "seed #{seed} team-trf #{gen.format}", primary: primary)
  end

  defp buchholz?(code), do: code |> String.split(["/", ":"]) |> hd() |> Kernel.in(~w(BH FB AOB))

  defp team_lists(seed) do
    :rand.seed(:exsss, {seed, seed + 17, 3 * seed + 2})
    Enum.take_random(@team_lists, 5)
  end

  # The top team meets the highest team it has not met; a rematch only when
  # nothing else is left.
  defp greedy_pairs([], _met, acc), do: Enum.reverse(acc)

  defp greedy_pairs([a | rest], met, acc) do
    b = Enum.find(rest, &(not MapSet.member?(met, {a, &1}))) || hd(rest)
    greedy_pairs(List.delete(rest, b), met, [{a, b} | acc])
  end

  # ======================================================================
  # Team events built match by match
  # ======================================================================

  @doc false
  def team_direct(seed) do
    compare_team(direct_team(seed), @team, team_lists(seed), "seed #{seed} team-direct")
  end

  @doc false
  def direct_team(seed) do
    :rand.seed(:exsss, {seed, 9 * seed + 4, seed + 77})
    teams = Enum.random(3..10)
    rounds = Enum.random(2..7)
    boards = Enum.random([2, 3, 4, 4, 4, 6])

    mpts =
      Enum.random([%{win: 2.0, draw: 1.0, loss: 0.0}, %{win: 3.0, draw: 1.0, loss: 0.0}])

    gw = 1.0
    primary = Enum.random([:mp, :mp, :gp])
    absent_rate = Enum.random([0.0, 0.08, 0.2])
    rematch_rate = Enum.random([0.0, 0.0, 0.3])

    start = %{mp: Map.new(1..teams, &{&1, 0.0}), met: MapSet.new(), rounds: %{}, byes: []}

    final =
      Enum.reduce(1..rounds, start, fn r, st ->
        # who sits this round out on a requested (half or zero) bye
        {absent, present} =
          1..teams |> Enum.split_with(fn _ -> :rand.uniform() < absent_rate end)

        st =
          Enum.reduce(absent, st, fn t, st ->
            m =
              if :rand.uniform() < 0.5,
                do: %Match{kind: :half_bye, mp: mpts.draw, gp: boards * gw / 2},
                else: %Match{kind: :zero_bye, mp: 0.0, gp: 0.0}

            put_match(st, t, r, m)
          end)

        order = Enum.sort_by(present, &{-st.mp[&1], &1})

        {st, order} =
          if rem(length(order), 2) == 1 do
            b = order |> Enum.reverse() |> Enum.find(List.last(order), &(&1 not in st.byes))

            m =
              if :rand.uniform() < 0.8,
                do: %Match{kind: :pab, mp: mpts.win, gp: boards * gw},
                else: %Match{kind: :full_bye, mp: mpts.win, gp: boards * gw}

            {%{put_match(st, b, r, m) | byes: [b | st.byes]}, List.delete(order, b)}
          else
            {st, order}
          end

        met = if :rand.uniform() < rematch_rate, do: MapSet.new(), else: st.met
        pairs = greedy_pairs(order, met, [])

        Enum.reduce(pairs, st, fn {a, b}, st ->
          st = %{st | met: st.met |> MapSet.put({a, b}) |> MapSet.put({b, a})}
          x = :rand.uniform()

          cond do
            x < 0.05 ->
              st
              |> put_match(a, r, %Match{
                kind: :forfeit_win,
                opponent: b,
                mp: mpts.win,
                gp: boards * gw
              })
              |> put_match(b, r, %Match{kind: :forfeit_loss, opponent: a, mp: 0.0, gp: 0.0})

            x < 0.07 ->
              st
              |> put_match(a, r, %Match{kind: :forfeit_loss, opponent: b, mp: 0.0, gp: 0.0})
              |> put_match(b, r, %Match{kind: :forfeit_loss, opponent: a, mp: 0.0, gp: 0.0})

            true ->
              board_results =
                for k <- 1..boards, into: %{} do
                  {k, Enum.random([1.0, 1.0, 0.5, 0.5, 0.5, 0.0, 0.0])}
                end

              ga = board_results |> Map.values() |> Enum.sum()
              gb = boards * gw - ga

              {ma, mb} =
                cond do
                  ga > gb -> {mpts.win, mpts.loss}
                  ga < gb -> {mpts.loss, mpts.win}
                  true -> {mpts.draw, mpts.draw}
                end

              theirs = Map.new(board_results, fn {k, v} -> {k, gw - v} end)

              st
              |> put_match(a, r, %Match{
                kind: :played,
                opponent: b,
                mp: ma,
                gp: ga,
                boards: board_results
              })
              |> put_match(b, r, %Match{
                kind: :played,
                opponent: a,
                mp: mb,
                gp: gb,
                boards: theirs
              })
          end
        end)
      end)

    entries =
      for t <- 1..teams do
        %Entry{id: t, tpn: t, rounds: Map.get(final.rounds, t, %{})}
      end

    Team.new(entries, rounds, boards: boards, primary: primary, match_points: mpts)
  end

  defp put_match(st, t, r, m) do
    %{
      st
      | rounds: Map.update(st.rounds, t, %{r => m}, &Map.put(&1, r, m)),
        mp: Map.update!(st.mp, t, &(&1 + m.mp))
    }
  end
end
