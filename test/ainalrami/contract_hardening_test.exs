defmodule Ainalrami.ContractHardeningTest do
  @moduledoc """
  The public pairing entry points' contracts, 2026-10-02: one validation of
  the input before any path is chosen, the same option handling behind
  `pair_next_round/2` and `pair_later_round/2`, no process state left behind
  by a call that raised, and a supplied pairing checked before it is
  explained. Each test is one way the old contract let a wrong answer
  through without a word.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Ainalrami.{Alternatives, ByePreference, CLI, Generator, Log, Pairing, Trf}

  setup do
    on_exit(fn -> Log.set_level(:normal) end)
  end

  # ------------------------------------------------------------ fixtures

  defp player(rank), do: %{rank: rank, name: "P#{rank}", points: 0.0, games: []}

  defp field(n), do: for(rank <- 1..n, do: player(rank))

  defp played(rank, games) do
    games =
      for {opp, colour, result} <- games,
          do: %{opponent_rank: opp, colour: colour, result: result}

    points =
      Enum.reduce(games, 0.0, fn g, acc ->
        acc + %{"1" => 1.0, "0" => 0.0, "U" => 1.0}[g.result]
      end)

    %{player(rank) | points: points, games: games}
  end

  # Round two of five players: 1 beat 4, 2 beat 5, 3 had the bye.
  defp round_two_field do
    [
      played(1, [{4, "w", "1"}]),
      played(2, [{5, "b", "1"}]),
      played(3, [{nil, nil, "U"}]),
      played(4, [{1, "b", "0"}]),
      played(5, [{2, "w", "0"}])
    ]
  end

  defp fixture do
    "test/fixtures/rule_delta/delta-1-seed1-r8.trf" |> File.read!() |> Trf.parse()
  end

  defp fixture_opts(parsed) do
    [
      expected_rounds: parsed.tournament[:number_of_rounds],
      forbidden_pairs: parsed.tournament[:forbidden_pairs],
      initial_colour: parsed.tournament[:initial_colour],
      soft_pairs: [[1, 2], [3, 4]],
      soft_position: :weak
    ]
  end

  defp bye(pairs), do: Enum.find_value(pairs, fn {w, b} -> if is_nil(b), do: w end)

  # Every round-scoped key the engine owns. The log level is the CLI's
  # setting and the certified-mode counters accumulate on purpose.
  defp engine_keys do
    Process.get_keys()
    |> Enum.filter(fn
      :ainalrami_log_level -> false
      :ainalrami_cert_stats -> false
      key when is_atom(key) -> String.starts_with?(Atom.to_string(key), "ainalrami_")
      {key, _} when is_atom(key) -> String.starts_with?(Atom.to_string(key), "ainalrami_")
      _ -> false
    end)
  end

  defp in_fresh_process(fun), do: fun |> Task.async() |> Task.await(:infinity)

  # ------------------------------------------- validation, every entry

  @bad_players [
    {"not a list", :nope},
    {"a player without a rank", [%{points: 0.0, games: []}]},
    {"a rank that is not an integer", [%{rank: "1", points: 0.0, games: []}]},
    {"points that are not a number", [%{rank: 1, points: nil, games: []}]},
    {"a game that is not a map", [%{rank: 1, points: 0.0, games: [:won]}]},
    {"an opponent rank that is not an integer",
     [%{rank: 1, points: 0.0, games: [%{opponent_rank: "2", colour: "w", result: "1"}]}]}
  ]

  @bad_opts [
    {:initial_colour, "W"},
    {:initial_colour, "white"},
    {:initial_colour, :w},
    {:soft_position, "weak"},
    {:soft_position, :medium},
    {:expected_rounds, "9"},
    {:point_system, %{win: 1.0}},
    {:point_system, :fide},
    {:forbidden_pairs, [[1, :two]]},
    {:forbidden_pairs, [{[1, 2], "1", 3}]},
    {:soft_pairs, [1, 2]},
    {:bye_exclusions, ["5"]},
    {:bye_passed_over, "false"}
  ]

  # Every public entry point that takes a roster, as `fun.(players, opts)`.
  defp entry_points do
    [
      pair_next_round: &Pairing.pair_next_round/2,
      pair_later_round: &Pairing.pair_later_round/2,
      explain_round: fn players, opts -> Pairing.explain_round(players, [], opts) end,
      explain_context: fn players, opts -> Pairing.explain_context(players, opts) end,
      bye_eligibility: &Pairing.bye_eligibility/2,
      bye_preference_pair: fn players, opts ->
        ByePreference.pair(players, opts ++ [bye_preferences: [{1, :avoid_soft}]])
      end,
      float_alternatives: fn players, opts ->
        Alternatives.float_alternatives(players, [], opts)
      end
    ]
  end

  describe "malformed input is refused by every entry point, with nothing left behind" do
    test "a malformed roster" do
      for {name, fun} <- entry_points(), {what, players} <- @bad_players do
        error = assert_raise ArgumentError, fn -> fun.(players, []) end
        assert error.message =~ ~r/player|players|game/, "#{name}, #{what}: #{error.message}"
        assert engine_keys() == [], "#{name}, #{what}: left #{inspect(engine_keys())}"
      end

      for what <- @bad_players do
        {_, players} = what

        if is_list(players) do
          assert_raise ArgumentError, fn -> Pairing.pair_round_one(players) end
        end
      end
    end

    test "a malformed option names the option" do
      # `Ainalrami.Alternatives` sets `:bye_passed_over` itself, so the
      # caller's value never reaches the engine there.
      for {name, fun} <- entry_points(),
          {key, value} <- @bad_opts,
          not (name == :float_alternatives and key == :bye_passed_over) do
        error = assert_raise ArgumentError, fn -> fun.(field(5), [{key, value}]) end

        assert error.message =~ inspect(key) or error.message =~ to_string(key),
               "#{name}, #{key}: #{error.message}"

        assert engine_keys() == [], "#{name}, #{key}: left #{inspect(engine_keys())}"
      end

      assert_raise ArgumentError, ~r/keyword list/, fn ->
        Pairing.pair_next_round(field(4), %{expected_rounds: 5})
      end
    end

    test "duplicate starting ranks are refused on round one too, and among absent players" do
      round_one = [player(1), player(2), player(2), player(3)]

      # `pair_round_one/1`'s shortcut never reached the check, so this
      # round was paired - two vertices for one rank.
      assert_raise ArgumentError, ~r/duplicate starting rank\(s\).*2 \(x2\)/, fn ->
        Pairing.pair_next_round(round_one)
      end

      assert_raise ArgumentError, ~r/duplicate starting rank/, fn ->
        Pairing.pair_round_one(round_one)
      end

      # Rank 9 sits round two out (no game for round one, not active) and
      # shares its rank with an active player's opponent record.
      absent_twice = round_two_field() ++ [%{player(9) | games: []}, %{player(9) | games: []}]

      assert_raise ArgumentError, ~r/duplicate starting rank\(s\).*9 \(x2\)/, fn ->
        Pairing.pair_next_round(absent_twice)
      end
    end

    test "pair_round_one/1 refuses a field somebody has played in" do
      assert_raise ArgumentError, ~r/pair_round_one\/1 pairs a round nobody has played in/, fn ->
        Pairing.pair_round_one(round_two_field())
      end
    end

    test "the options accepted still pair exactly as before" do
      parsed = fixture()
      opts = fixture_opts(parsed)

      # nil and the explicit default are the same round.
      plain = Pairing.pair_next_round(parsed.players, Keyword.delete(opts, :soft_position))

      assert Pairing.pair_next_round(
               parsed.players,
               Keyword.put(opts, :soft_position, :strong)
             ) == plain

      assert Pairing.pair_next_round(parsed.players, Keyword.put(opts, :soft_position, nil)) ==
               plain

      # Host keys the engine does not read are left alone.
      assert Pairing.pair_next_round(parsed.players, opts ++ [host_note: "x"]) ==
               Pairing.pair_next_round(parsed.players, opts)
    end
  end

  # ------------------------------------------- no state survives a raise

  describe "a call that raises in setup leaves no process state" do
    # A game record without `:colour` passes validation (the engine reads
    # colours only where it needs them) and raises from the initial-colour
    # inference - which ran AFTER the first keys were stamped and BEFORE the
    # `try` whose `after` cleared them. The next call in the process then
    # read the dead tournament's `expected_rounds`.
    defp colourless do
      [
        %{player(1) | points: 1.0, games: [%{opponent_rank: 2, result: "1"}]},
        %{player(2) | games: [%{opponent_rank: 1, result: "0"}]}
      ]
    end

    test "every entry point, then a valid tournament pairs as in a fresh process" do
      parsed = fixture()
      opts = fixture_opts(parsed)

      fresh =
        in_fresh_process(fn ->
          {Pairing.pair_next_round(parsed.players, opts),
           Pairing.pair_later_round(parsed.players, opts),
           Pairing.explain_round(
             parsed.players,
             Pairing.pair_next_round(parsed.players, opts),
             opts
           )}
        end)

      failing = [
        fn -> Pairing.pair_next_round(colourless(), expected_rounds: 2) end,
        fn ->
          Pairing.pair_later_round(colourless(), expected_rounds: 2, forbidden_pairs: [[1, 2]])
        end,
        fn -> Pairing.explain_round(colourless(), [{1, 2}], expected_rounds: 2) end,
        fn -> Pairing.explain_context(colourless(), expected_rounds: 2) end
      ]

      for call <- failing do
        assert_raise KeyError, call
        assert engine_keys() == [], "left behind: #{inspect(engine_keys())}"

        pairs = Pairing.pair_next_round(parsed.players, opts)

        assert {pairs, Pairing.pair_later_round(parsed.players, opts),
                Pairing.explain_round(parsed.players, pairs, opts)} == fresh
      end
    end

    test "a successful call leaves nothing behind either" do
      parsed = fixture()
      opts = fixture_opts(parsed)
      pairs = Pairing.pair_next_round(parsed.players, opts)
      assert engine_keys() == []
      _ = Pairing.pair_later_round(parsed.players, opts)
      assert engine_keys() == []
      _ = Pairing.explain_round(parsed.players, pairs, opts)
      assert engine_keys() == []
      _ = Alternatives.float_alternatives(parsed.players, pairs, opts)
      assert engine_keys() == []
    end
  end

  # ------------------------------------------- one option contract

  describe "pair_later_round/2 resolves options exactly as pair_next_round/2 does" do
    test "soft pairs are honoured, not ignored" do
      # Round one of six pairs 1-4 naturally; a soft pair asks not to.
      # The cascade is what `pair_next_round/2` runs for it too (a soft pair
      # rules the round-one shortcut out), so the two agree board for board.
      steered = Pairing.pair_next_round(field(6), soft_pairs: [[1, 4]])
      refute Enum.any?(steered, &(&1 in [{1, 4}, {4, 1}]))
      assert Pairing.pair_later_round(field(6), soft_pairs: [[1, 4]]) == steered
    end

    test "bye preferences are resolved, not ignored" do
      players = round_two_field()
      assert bye(Pairing.pair_later_round(players)) == 5

      opts = [bye_preferences: [{5, :avoid_hard}]]
      pairs = Pairing.pair_later_round(players, opts)
      refute bye(pairs) == 5
      assert pairs == Pairing.pair_next_round(players, opts)
    end

    test "on a later round the two are one function" do
      parsed = fixture()
      opts = fixture_opts(parsed)

      assert Pairing.pair_later_round(parsed.players, opts) ==
               Pairing.pair_next_round(parsed.players, opts)
    end
  end

  # ------------------------------------------- the pairing explained

  describe "a supplied pairing is checked before it is explained" do
    setup do
      players = round_two_field()
      pairs = Pairing.pair_next_round(players)
      %{players: players, pairs: pairs}
    end

    test "a complete pairing is explained, the bye as a bye", %{players: players, pairs: pairs} do
      assert [_ | _] = Pairing.explain_round(players, pairs)
      context = Pairing.explain_context(players, [], pairs)
      assert [_ | _] = Pairing.explain_pairs(context, pairs)
    end

    test "refusals, each with its reason", %{players: players, pairs: pairs} do
      [{a, b} | rest] = Enum.reject(pairs, fn {_, b} -> is_nil(b) end)
      holder = bye(pairs)

      cases = [
        # A board left out used to be explained as two more byes.
        {"not in it", rest ++ [{holder, nil}]},
        {"more than once", [{a, b}, {a, holder} | rest]},
        {"not an active player", [{a, 99}, {b, holder} | rest]},
        {"paired with themselves", [{a, a} | pairs]},
        {"pairing-allocated bye", [{a, nil}, {b, nil} | rest] ++ [{holder, nil}]},
        {"names nil, who is not an active player", [{nil, a} | pairs]},
        {"each entry is", [[a, b] | rest] ++ [{holder, nil}]},
        {"each entry is", [{a, b, :extra} | rest] ++ [{holder, nil}]},
        {"a list of pairs", :none_at_all}
      ]

      context = Pairing.explain_context(players, [])

      for {reason, bad} <- cases do
        error = assert_raise ArgumentError, fn -> Pairing.explain_round(players, bad) end
        assert error.message =~ "invalid pairing to explain", inspect(bad)
        assert error.message =~ reason, "#{inspect(bad)}: #{error.message}"

        assert_raise ArgumentError, ~r/invalid pairing to explain/, fn ->
          Pairing.explain_pairs(context, bad)
        end

        assert engine_keys() == []
      end
    end

    test "an even field has no bye to give" do
      players = field(4)

      assert_raise ArgumentError, ~r/2 pairing-allocated bye\(s\) where this round of 4/, fn ->
        Pairing.explain_round(players, [{1, 3}, {2, nil}, {4, nil}])
      end
    end

    test "a player sitting the round out is not in it" do
      # Rank 6 has an arbiter's half-point bye recorded for round two, so is
      # not active: naming them names a player the round does not have.
      players =
        round_two_field() ++
          [
            %{
              player(6)
              | points: 1.5,
                games: [
                  %{opponent_rank: nil, colour: nil, result: "U"},
                  %{opponent_rank: nil, colour: nil, result: "H"}
                ]
            }
          ]

      pairs = Pairing.pair_next_round(players)
      refute Enum.any?(pairs, fn {w, b} -> 6 in [w, b] end)

      assert_raise ArgumentError, ~r/names 6, who is not an active player/, fn ->
        Pairing.explain_round(players, pairs ++ [{6, nil}])
      end
    end
  end

  # ------------------------------------------- the CLI and the generator

  describe "the CLI" do
    defp run(argv) do
      out =
        capture_io(fn ->
          err = capture_io(:stderr, fn -> send(self(), {:code, CLI.run(argv)}) end)
          send(self(), {:stderr, err})
        end)

      assert_received {:code, code}
      assert_received {:stderr, err}
      {code, out, err}
    end

    defp tmp_path(suffix) do
      path =
        Path.join(
          System.tmp_dir!(),
          "ainalrami_contract_#{System.unique_integer([:positive])}#{suffix}"
        )

      on_exit(fn -> File.rm(path) end)
      path
    end

    defp roster(lines) do
      """
      012 Contract\r
      062 #{length(lines)}\r
      XXR 5\r
      152 W\r
      """ <> Enum.join(lines)
    end

    defp line(rank, name, rating) do
      "001 " <>
        String.pad_leading(to_string(rank), 4) <>
        " m  gm " <>
        String.pad_trailing(name, 33) <>
        String.pad_leading(to_string(rating), 4) <>
        " BEL     1000001 1990/01/01  0.0    " <> String.pad_leading(to_string(rank), 1) <> "\r\n"
    end

    test "a round one with a duplicate starting rank exits 1 and says why" do
      input = tmp_path(".trf")
      output = tmp_path(".out")

      File.write!(
        input,
        roster([
          line(1, "Alpha", 2400),
          line(2, "Beta", 2300),
          line(2, "Gamma", 2200),
          line(3, "Delta", 2100)
        ])
      )

      {code, _out, err} = run([input, "-p", output])
      assert code == 1
      assert err =~ "duplicate starting rank"
      refute File.exists?(output) and File.read!(output) != ""
    end

    test "the same roster without the duplicate pairs" do
      input = tmp_path(".trf")
      output = tmp_path(".out")

      File.write!(
        input,
        roster([
          line(1, "Alpha", 2400),
          line(2, "Beta", 2300),
          line(3, "Gamma", 2200),
          line(4, "Delta", 2100)
        ])
      )

      {code, _out, _err} = run([input, "-p", output])
      assert code == 0
      assert File.read!(output) =~ "2"
    end
  end

  describe "the generator's initial colour" do
    test "every accepted spelling reaches the engine as the draw the file records" do
      {w, _} = Generator.generate(seed: 11, players: 9, rounds: 3, initial_colour: "w")
      {white, _} = Generator.generate(seed: 11, players: 9, rounds: 3, initial_colour: "white")
      {b, _} = Generator.generate(seed: 11, players: 9, rounds: 3, initial_colour: "B")
      {black, _} = Generator.generate(seed: 11, players: 9, rounds: 3, initial_colour: "black")

      # "white" used to reach the engine verbatim and be paired as Black,
      # under a `152 W` line.
      assert white == w
      assert black == b
      refute w == b
    end

    test "anything else is refused" do
      assert_raise ArgumentError, ~r/:initial_colour/, fn ->
        Generator.generate(seed: 11, players: 9, rounds: 3, initial_colour: "x")
      end
    end
  end
end
