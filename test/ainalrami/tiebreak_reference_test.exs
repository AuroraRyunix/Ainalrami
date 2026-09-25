defmodule Ainalrami.TiebreakReferenceTest do
  @moduledoc """
  C.07 tie-breaks, engine against an independent reference.

  `Ainalrami.TiebreakReference` is a naive second implementation written
  from `docs/c07-regulation-text.md`, sharing no code with
  `lib/ainalrami/tiebreaks*`. Every value of every code, and the final ranks
  under several tie-break lists, must agree. Method, readings and results:
  `docs/tiebreak-reference.md`.

  ## Scale mode

      TIEBREAK_REF_SEEDS="1..5000" mix test test/ainalrami/tiebreak_reference_test.exs --only tiebreak_reference_scale

  prints `TBREF seeds=N events=N values=N disagreements=N`. A failure
  message starts with the seed (`seed N ...`).
  """
  use ExUnit.Case, async: true

  alias Ainalrami.TiebreakReference, as: Ref
  alias Ainalrami.TiebreakReference.Proof
  alias Ainalrami.Tiebreaks
  alias Ainalrami.Tiebreaks.{Event, Team}
  alias Ainalrami.Tiebreaks.Team.{Entry, Match}

  @swiss_codes ~w(PTS WIN WON BPG BWG PS PS/C1 REP STD TPN BH BH/C1 BH/C2 BH/M1 FB FB/C1
                  AOB AOB/F SB SB/C1 SB/C2 KS KS/L1 KS/L-1 ARO ARO/C1 TPR PTP APRO APPO RTNG)

  defp run(seeds) do
    Enum.reduce(seeds, Proof.zero(), fn seed, acc -> Proof.add(acc, Proof.run(seed)) end)
  end

  defp seeds_from_env(default) do
    case System.get_env("TIEBREAK_REF_SEEDS") do
      nil ->
        default

      text ->
        case String.split(text, "..") do
          [a, b] -> String.to_integer(a)..String.to_integer(b)
          [a] -> String.to_integer(a)..String.to_integer(a)
        end
    end
  end

  describe "engine and reference agree on generated events" do
    @tag timeout: :infinity
    test "a few hundred small events: Swiss, round robins, team events" do
      result = run(1..300)

      assert result.bad == [], Enum.join(Enum.take(result.bad, 20), "\n")
      assert result.events == 300
      assert result.values > 100_000
    end

    @tag :tiebreak_reference_scale
    @tag timeout: :infinity
    test "scale mode" do
      seeds = seeds_from_env(1..5000)
      result = run(seeds)

      IO.puts(
        "TBREF seeds=#{Enum.count(seeds)} events=#{result.events} values=#{result.values} " <>
          "disagreements=#{length(result.bad)}"
      )

      assert result.bad == [], Enum.join(Enum.take(result.bad, 20), "\n")
    end
  end

  # ======================================================================
  # Hand-built events aimed at the points the TieBreakServer comparison
  # set aside as "known" - where our answer rests on our own reading.
  # ======================================================================

  # A crosstable as a parsed TRF: %{id => {rating, [round]}}, a round being
  # {opponent, "w" | "b", result} or a bye code ("U" "F" "H" "Z").
  defp trf(spec, opts \\ []) do
    rounds = spec |> Map.values() |> Enum.map(fn {_, rs} -> length(rs) end) |> Enum.max()

    %{
      tournament:
        Map.merge(
          %{name: "hand-built", number_of_rounds: Keyword.get(opts, :total, rounds)},
          if(opts[:rr], do: %{type_code: "FIDE_ROUNDROBIN"}, else: %{})
        ),
      teams: [],
      players:
        for {id, {rating, rs}} <- Enum.sort(spec) do
          %{
            rank: id,
            fide_rating: rating,
            games:
              Enum.map(rs, fn
                {opp, colour, result} -> %{opponent_rank: opp, colour: colour, result: result}
                bye -> %{opponent_rank: nil, colour: nil, result: bye}
              end)
          }
        end
    }
  end

  # Engine and reference agree on every code and list, and both give `expected`.
  defp both(trf, code, expected, opts \\ []) do
    agree(trf, opts)
    engine = trf |> Event.from_trf(opts) |> Tiebreaks.compute([code]) |> elem(1)
    reference = trf |> Ref.from_trf(opts) |> Ref.values(code)

    for {id, value} <- expected do
      assert_in_delta engine[code][id], value, 1.0e-9, "engine #{code} of #{id}"
      assert_in_delta reference[id], value, 1.0e-9, "reference #{code} of #{id}"
    end
  end

  defp agree(trf, opts \\ []) do
    codes =
      if opts[:rr] || match?(%{type_code: _}, trf.tournament),
        do: @swiss_codes -- ~w(BH BH/C1 BH/C2 BH/M1 FB FB/C1 AOB AOB/F),
        else: @swiss_codes

    result =
      Proof.compare_individual(
        trf,
        Keyword.take(opts, [:rounds]),
        codes,
        [~w(DE), ~w(DE/P SB)],
        "hand"
      )

    assert result.bad == [], Enum.join(result.bad, "\n")
  end

  defp ranks(event_or_team, list) do
    {:ok, rows} = Tiebreaks.rank(event_or_team, list)
    Map.new(rows, &{&1.id, &1.rank})
  end

  test "STD scores against the scheduled opponent (reading 8)" do
    # r1: 1 and 2 double forfeit; r2: 2 takes ½ from 4's 0 (an odd result).
    t =
      trf(%{
        1 => {2000, [{2, "w", "-"}, {3, "w", "="}]},
        2 => {2000, [{1, "b", "-"}, {4, "w", "="}]},
        3 => {2000, [{4, "w", "1"}, {1, "b", "="}]},
        4 => {2000, [{3, "b", "0"}, {2, "b", "0"}]}
      })

    # Against a draw's value (TieBreakServer) 1 and 2 would get 0.5 and 1.0.
    both(t, "STD", %{1 => 1.0, 2 => 1.5, 3 => 1.5, 4 => 0.0})
  end

  # Player 1 (2.5 of 4): a half-point bye (dummy min(2.5, 0.5 x 4) = 2.0,
  # contribution 1.0), a forfeit loss to 2 (dummy min(2.5, 3.0) = 2.5,
  # contribution 0), a win over the lowest scorer 3 (0.5) and one over 6 (1.5).
  defp vur_event do
    trf(%{
      1 => {2100, ["H", {2, "w", "-"}, {3, "w", "1"}, {6, "b", "1"}]},
      2 => {2100, [{3, "w", "1"}, {1, "b", "+"}, {5, "w", "="}, {4, "w", "="}]},
      3 => {2100, [{2, "b", "0"}, {4, "w", "="}, {1, "b", "0"}, {5, "w", "0"}]},
      4 => {2100, [{5, "w", "="}, {3, "b", "="}, {6, "w", "="}, {2, "b", "="}]},
      5 => {2100, [{4, "b", "="}, {6, "w", "1"}, {2, "b", "="}, {3, "b", "1"}]},
      6 => {2100, ["U", {5, "b", "0"}, {4, "b", "="}, {1, "w", "0"}]}
    })
  end

  test "SB/C1 cuts the higher of the lowest VUR contribution and the least significant value (finding B)" do
    # SB = 1.0 + 0 + 0.5 + 1.5 = 3.0. Lowest VUR contribution 0 (round 2);
    # least significant value 0.5 (round 3, the lowest opponent); the
    # higher, 0.5, goes: 2.5. Choosing the VUR by its dummy's score (round
    # 1, dummy 2.0 against round 2's 2.5) would cut 1.0 and give 2.0.
    both(vur_event(), "SB", %{1 => 3.0})
    both(vur_event(), "SB/C1", %{1 => 2.5})
  end

  test "BH/C1 with VURs cuts the lowest VUR contribution (16.5.2)" do
    # 2.0 (half-point bye) + 2.5 (forfeit loss) + 0.5 + 1.5 = 6.5; the
    # lowest VUR contribution, 2.0, goes - not the least value 0.5.
    both(vur_event(), "BH", %{1 => 6.5})
    both(vur_event(), "BH/C1", %{1 => 4.5})
  end

  test "a value does not depend on the codes listed before it (finding A)" do
    event = Event.from_trf(vur_event())
    {:ok, alone} = Tiebreaks.compute(event, ~w(SB BH))
    {:ok, after_fb} = Tiebreaks.compute(event, ~w(FB SB BH))
    assert alone["SB"] == after_fb["SB"]
    assert alone["BH"] == after_fb["BH"]
    assert ranks(event, ~w(FB SB)) == Ref.rank(Ref.from_trf(vur_event()), ~w(FB SB))
  end

  test "direct encounter averages repeated meetings (6.1.2, finding C)" do
    # 1, 2 and 3 finish on 3.5. Among them: 1 drew 3 and beat 2; 2 beat 3
    # twice. Encounter points 1.5, 1 (the average of two wins), 0.5. Summed
    # instead, 2 would lead with 2.
    t =
      trf(%{
        1 =>
          {2000,
           [
             {3, "w", "="},
             {2, "w", "1"},
             {4, "b", "="},
             {5, "w", "="},
             {6, "b", "="},
             {4, "w", "="}
           ]},
        2 =>
          {2000,
           [
             {4, "w", "="},
             {1, "b", "0"},
             {3, "w", "1"},
             {3, "b", "1"},
             {5, "b", "="},
             {6, "w", "="}
           ]},
        3 =>
          {2000,
           [
             {1, "b", "="},
             {4, "w", "1"},
             {2, "b", "0"},
             {2, "w", "0"},
             {4, "b", "1"},
             {5, "w", "1"}
           ]},
        4 =>
          {2000,
           [
             {2, "b", "="},
             {3, "b", "0"},
             {1, "w", "="},
             {6, "w", "="},
             {3, "w", "0"},
             {1, "b", "="}
           ]},
        5 =>
          {2000,
           [
             {6, "w", "="},
             {6, "b", "1"},
             {6, "w", "="},
             {1, "b", "="},
             {2, "w", "="},
             {3, "b", "0"}
           ]},
        6 =>
          {2000,
           [
             {5, "b", "="},
             {5, "w", "0"},
             {5, "b", "="},
             {4, "b", "="},
             {1, "w", "="},
             {2, "b", "="}
           ]}
      })

    agree(t)
    expected = %{1 => 1, 2 => 2, 3 => 3}
    assert Map.take(ranks(Event.from_trf(t), ~w(DE)), [1, 2, 3]) == expected
    assert Map.take(Ref.rank(Ref.from_trf(t), ~w(DE)), [1, 2, 3]) == expected
  end

  test "Koya's maximum in an odd round robin leaves out the free round (reading 10)" do
    # Five players, all games drawn: 2.0 each out of a possible 4 (not 5),
    # so everybody is on the 50% line and counts; L1 moves it to 2.5.
    ids = 1..5
    field = 6

    schedule =
      for r <- 1..5 do
        circle = [
          field | Enum.drop(Enum.to_list(1..5), r - 1) ++ Enum.take(Enum.to_list(1..5), r - 1)
        ]

        for i <- 0..2, do: {Enum.at(circle, i), Enum.at(circle, 5 - i)}
      end

    spec =
      Map.new(ids, fn id ->
        rounds =
          for pairs <- schedule do
            case Enum.find(pairs, fn {a, b} -> a == id or b == id end) do
              {a, b} when a == field or b == field -> "Z"
              {^id, b} -> {b, "w", "="}
              {a, ^id} -> {a, "b", "="}
            end
          end

        {id, {2000, rounds}}
      end)

    t = trf(spec, rr: true)
    both(t, "KS", Map.new(ids, &{&1, 2.0}), rr: true)
    both(t, "KS/L1", Map.new(ids, &{&1, 0.0}), rr: true)
    both(t, "KS/L-1", Map.new(ids, &{&1, 2.0}), rr: true)
  end

  test "a forfeit win is not a game won over the board, even in a round robin (reading 9)" do
    t =
      trf(
        %{
          1 => {2000, [{2, "w", "+"}, {3, "b", "1"}, {4, "w", "="}]},
          2 => {2000, [{1, "b", "-"}, {4, "w", "1"}, {3, "b", "="}]},
          3 => {2000, [{4, "w", "0"}, {1, "w", "0"}, {2, "w", "="}]},
          4 => {2000, [{3, "b", "1"}, {2, "b", "0"}, {1, "b", "="}]}
        },
        rr: true
      )

    both(t, "WON", %{1 => 1, 2 => 1}, rr: true)
    both(t, "WIN", %{1 => 2, 2 => 1}, rr: true)
    both(t, "REP", %{1 => 3, 2 => 2}, rr: true)
    # 15.2: in a round robin the forfeit is a game for SB - 2's 1.5 x 1.
    both(t, "SB", %{1 => 1.5 * 1 + 0.5 * 1 + 1.5 * 0.5}, rr: true)
  end

  # Player 1 has a pairing-allocated bye and wins everything else (4.0);
  # player 5 ends with a zero-point bye in the last round (16.2.5).
  defp cap_event do
    trf(%{
      1 => {2000, ["U", {2, "w", "1"}, {4, "b", "1"}, {3, "w", "1"}]},
      2 => {2000, [{3, "w", "1"}, {1, "b", "0"}, {5, "w", "1"}, {4, "b", "="}]},
      3 => {2000, [{2, "b", "0"}, {4, "w", "="}, "U", {1, "b", "0"}]},
      4 => {2000, [{5, "w", "1"}, {3, "b", "="}, {1, "w", "0"}, {2, "w", "="}]},
      5 => {2000, [{4, "b", "0"}, "U", {2, "b", "0"}, "Z"]}
    })
  end

  test "16.4.2 caps the dummy at a draw per round; 16.3.2 counts a trailing bye as a draw" do
    # 1: dummy min(4.0, 0.5 x 4) = 2.0, then 2.5 + 2.0 + 1.5 = 8.0.
    # 2: 1.5 + 4.0 + 5's adjusted 1.5 (its round-4 bye as a draw) + 2.0.
    both(cap_event(), "BH", %{1 => 8.0, 2 => 9.0})
  end

  test "part-way standings: the cap counts the rounds played, FB is BH (readings 11, 8.3)" do
    # After round 2 of 4: 1 has 2.0; the dummy is min(2.0, 0.5 x 2) = 1.0,
    # and 2 has 1.0 - so BH 2.0 (the announced-rounds cap would give 3.0).
    both(cap_event(), "BH", %{1 => 2.0}, rounds: 2)
    both(cap_event(), "FB", %{1 => 2.0}, rounds: 2)
  end

  test "a requested bye followed only by VURs is a draw to the opponents; followed by a forfeit win it is not (16.2)" do
    # 2: zero-point bye, then a forfeit loss - 16.2.5, adjusted 0.5.
    # 4: zero-point bye, then a forfeit WIN (not a VUR) - 16.2.3, adjusted 1.0.
    t =
      trf(%{
        1 => {2000, [{2, "w", "1"}, {6, "b", "="}, {3, "w", "="}]},
        2 => {2000, [{1, "b", "0"}, "Z", {5, "w", "-"}]},
        3 => {2000, [{4, "w", "1"}, {5, "w", "1"}, {1, "b", "="}]},
        4 => {2000, [{3, "b", "0"}, "Z", {6, "b", "+"}]},
        5 => {2000, [{6, "w", "="}, {3, "b", "0"}, {2, "b", "+"}]},
        6 => {2000, [{5, "b", "="}, {1, "w", "="}, {4, "w", "-"}]}
      })

    both(t, "BH", %{1 => 0.5 + 1.0 + 2.5, 3 => 1.0 + 1.5 + 2.0})
  end

  # Four teams of four boards, two rounds. 1 and 2 never meet and finish
  # level on 3 MP and 4.5 GP, with different boards.
  defp board_team do
    m = fn opp, mp, boards ->
      %Match{
        kind: :played,
        opponent: opp,
        mp: mp,
        gp: boards |> Enum.sum(),
        boards: boards |> Enum.with_index(1) |> Map.new(fn {g, b} -> {b, g} end)
      }
    end

    Team.new(
      [
        %Entry{
          id: 1,
          tpn: 1,
          rounds: %{1 => m.(3, 2.0, [1, 1, 0, 0.5]), 2 => m.(4, 1.0, [0.5, 0.5, 0.5, 0.5])}
        },
        %Entry{
          id: 2,
          tpn: 2,
          rounds: %{1 => m.(4, 2.0, [0, 0.5, 1, 1]), 2 => m.(3, 1.0, [0.5, 0.5, 0.5, 0.5])}
        },
        %Entry{
          id: 3,
          tpn: 3,
          rounds: %{1 => m.(1, 0.0, [0, 0, 1, 0.5]), 2 => m.(2, 1.0, [0.5, 0.5, 0.5, 0.5])}
        },
        %Entry{
          id: 4,
          tpn: 4,
          rounds: %{1 => m.(2, 0.0, [1, 0.5, 0, 0]), 2 => m.(1, 1.0, [0.5, 0.5, 0.5, 0.5])}
        }
      ],
      2,
      boards: 4
    )
  end

  test "EDEBT: two level teams that never met are separated by Board Count over the tournament, lower first (finding D, reading T4)" do
    t = board_team()
    # BC: 1 has 5 + 5 = 10, 2 has 8 + 5 = 13; 4 has 7, 3 has 10.
    expected = %{1 => 1, 2 => 2, 4 => 3, 3 => 4}

    for list <- [~w(MPTS GPTS EDEBT), ~w(MPTS GPTS EDEBB), ~w(MPTS BC)] do
      assert ranks(t, list) == expected, inspect(list)
      assert Ref.rank(Ref.from_team(t), list) == expected, inspect(list)
    end

    result =
      Proof.compare_team(
        t,
        ~w(MPTS GPTS SB:MP EMGSB BH:GP),
        [~w(MPTS EDET), ~w(GPTS EDEB)],
        "board team"
      )

    assert result.bad == []
  end

  test "EDE between exactly two teams tied after a drawn match goes to the knockout tie-breaks" do
    # 1 and 2 drew 2-2 and are level; the match cannot separate them in
    # either score, so EDET falls to the top board (1 took board 1) and EDEB
    # to boards 1-3 (level), 1-2 (level), then board 1.
    m = fn opp, mp, boards ->
      %Match{
        kind: :played,
        opponent: opp,
        mp: mp,
        gp: Enum.sum(boards),
        boards: boards |> Enum.with_index(1) |> Map.new(fn {g, b} -> {b, g} end)
      }
    end

    t =
      Team.new(
        [
          %Entry{id: 1, rounds: %{1 => m.(2, 1.0, [1, 0, 0.5, 0.5])}},
          %Entry{id: 2, rounds: %{1 => m.(1, 1.0, [0, 1, 0.5, 0.5])}}
        ],
        1,
        boards: 4
      )

    for {list, expected} <- [
          {~w(MPTS GPTS EDET), %{1 => 1, 2 => 2}},
          {~w(MPTS GPTS EDEB), %{1 => 1, 2 => 2}},
          {~w(MPTS GPTS EDE), %{1 => 1, 2 => 1}}
        ] do
      assert ranks(t, list) == expected, inspect(list)
      assert Ref.rank(Ref.from_team(t), list) == expected, inspect(list)
    end
  end

  test "team events built match by match, with rematches and every unplayed round" do
    # The first five match-by-match events with both a rematch and a
    # forfeited match.
    seeds =
      8..3000//10
      |> Stream.filter(fn seed ->
        matches =
          for {id, team} <- Proof.direct_team(seed).teams, {_r, m} <- team.rounds, do: {id, m}

        forfeit? = Enum.any?(matches, fn {_, m} -> m.kind == :forfeit_loss end)

        rematch? =
          matches
          |> Enum.filter(fn {_, m} -> m.kind == :played end)
          |> Enum.frequencies_by(fn {id, m} -> {id, m.opponent} end)
          |> Enum.any?(fn {_, n} -> n > 1 end)

        forfeit? and rematch?
      end)
      |> Enum.take(5)

    assert length(seeds) == 5

    for seed <- seeds, do: assert(Proof.team_direct(seed).bad == [], "seed #{seed}")
  end
end
