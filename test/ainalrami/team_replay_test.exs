defmodule Ainalrami.TeamReplayTest do
  @moduledoc """
  `ainalrami -c` on team files: a team Swiss is replayed with the C.04.6
  engine (`Ainalrami.TeamReplay`), a deliberately altered pairing or colour
  is flagged, and a team system that cannot be replayed exits 2.

  The Swiss files come from `Ainalrami.TeamTrfGenerator` with
  `pairing: :engine`, which pairs every round with `Ainalrami.TeamPairing`
  itself - so a clean file must check clean, and an edit to one round must
  be found in that round.
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias Ainalrami.{CLI, TeamReplay, TeamTrfGenerator, Trf}

  defp check(text) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ainalrami_team_replay_#{System.unique_integer([:positive])}.trf"
      )

    File.write!(path, text)
    on_exit(fn -> File.rm(path) end)

    ref = make_ref()

    out =
      capture_io(fn ->
        capture_io(:stderr, fn -> Process.put(ref, CLI.run([path, "-c"])) end) |> IO.write()
      end)

    {out, Process.get(ref)}
  end

  defp swiss(seed, opts) do
    TeamTrfGenerator.generate(seed, [selector: 0, pairing: :engine] ++ opts)
  end

  # A generated Swiss with at least `min` rounds, from the first seed that
  # gives one.
  defp swiss_with_rounds(seed, min, opts \\ []) do
    Stream.iterate(seed, &(&1 + 1))
    |> Stream.map(&swiss(&1, opts))
    |> Enum.find(&(&1.rounds >= min))
  end

  describe "a C.04.6 Swiss paired by the engine checks clean" do
    for {seed, opts} <- [
          {1, []},
          {2, []},
          {3, [type: :b]},
          {4, [type: :b]},
          {5, [score_mode: :game_points]},
          {6, [initial_colour: :black]},
          {7, [type: :b, initial_colour: :black]},
          {8, [score_mode: :game_points, type: :b]},
          {11, []},
          {12, [initial_colour: :black]},
          {13, []},
          {14, [type: :b]}
        ] do
      test "seed #{seed} #{inspect(opts)}" do
        gen = swiss(unquote(seed), unquote(opts))
        {out, code} = check(gen.text)

        assert code == 0, out
        assert out =~ "#{gen.rounds}/#{gen.rounds} round(s) match this engine's own pairing"
        assert out =~ "C.04.6"
      end
    end

    test "with no 152, the initial colour is the one round 1 shows" do
      gen = swiss_with_rounds(20, 2, initial_colour: :black)
      parsed = Trf.parse(gen.text)
      text = Trf.serialize(%{parsed | tournament: Map.delete(parsed.tournament, :initial_colour)})

      {out, code} = check(text)
      assert code == 0, out
      assert out =~ "initial colour black (no 152 in the file"
    end

    test "with no 192 and 013 team records instead of 310, the games show a team event" do
      gen = swiss_with_rounds(30, 2)
      parsed = Trf.parse(gen.text)

      text =
        Trf.serialize(%{
          parsed
          | tournament: Map.delete(parsed.tournament, :type_code),
            teams: Enum.map(parsed.teams, &Map.take(&1, [:name, :player_ranks]))
        })

      assert text =~ "\n013 "
      refute text =~ "\n310 "

      {out, code} = check(text)
      assert code == 0, out
      assert out =~ "no 192: the C.04.6 defaults"
    end
  end

  describe "an altered file is flagged" do
    test "two matches of one round with their opponents exchanged" do
      gen = swiss_with_rounds(40, 3)
      parsed = Trf.parse(gen.text)
      history = TeamReplay.history(parsed)
      {[{a, b, _}, {c, d, _} | _], _bye} = TeamReplay.recorded(history, 2)

      altered = exchange_opponents(parsed, 2, {a, b}, {c, d})
      {out, code} = check(Trf.serialize(altered))

      assert code == 1
      assert out =~ "round 1: matches"
      assert out =~ "round 2: DIFFERS\n"
      assert out =~ "{#{a}, #{d}}"
    end

    test "one match of one round with its colours reversed" do
      gen = swiss_with_rounds(50, 3)
      parsed = Trf.parse(gen.text)
      history = TeamReplay.history(parsed)
      {[{a, b, true} | _], _bye} = TeamReplay.recorded(history, 3)

      altered = reverse_colours(parsed, 3, [a, b])
      {out, code} = check(Trf.serialize(altered))

      assert code == 1
      assert out =~ "round 2: matches"
      assert out =~ "round 3: DIFFERS in colours only"
      assert out =~ "[{#{b}, #{a}}]"
    end
  end

  describe "a team system this checker cannot replay" do
    for {selector, what} <- [{6, "round robin"}, {8, "Scheveningen"}, {9, "Schiller"}] do
      test "a team #{what} exits 2 and says why" do
        gen = TeamTrfGenerator.generate(100 + unquote(selector), selector: unquote(selector))
        {out, code} = check(gen.text)

        assert code == 2, out
        assert out =~ "rounds: not replayed"
        assert out =~ "exit code 2"
        refute out =~ "DIFFERS"
      end
    end

    for code <- ~w(FIDE_TEAM_BAKU FIDE_TEAM_TYPEA_MP_GP_BAKU CUSTOM_TEAM_SWISS_MP) do
      test "#{code} exits 2" do
        gen = swiss_with_rounds(60, 2)
        parsed = Trf.parse(gen.text)

        text =
          Trf.serialize(%{
            parsed
            | tournament: Map.put(parsed.tournament, :type_code, unquote(code))
          })

        {out, exit_code} = check(text)
        assert exit_code == 2, out
        assert out =~ "rounds: not replayed - #{unquote(code)}"
      end
    end

    test "a standings difference still exits 1" do
      gen = TeamTrfGenerator.generate(106, selector: 6)
      parsed = Trf.parse(gen.text)

      teams =
        parsed.teams
        |> Enum.with_index(1)
        |> Enum.map(fn {t, i} -> Map.put(t, :final_rank, length(parsed.teams) + 1 - i) end)

      text =
        Trf.serialize(%{
          parsed
          | teams: teams,
            tournament: Map.put(parsed.tournament, :standings_order, ~w(MPTS))
        })

      {out, code} = check(text)
      assert out =~ "rounds: not replayed"

      # Reversed ranks follow MPTS only if every team is level.
      if out =~ "do not follow", do: assert(code == 1), else: assert(code == 2)
    end
  end

  describe "system/1" do
    defp sys(code, teams \\ [%{name: "T", player_ranks: [1]}]) do
      TeamReplay.system(%{
        tournament: %{type_code: code},
        teams: teams,
        players: []
      })
    end

    test "reads a team Swiss code's settings" do
      assert {:team, %{type: :a, score_mode: :match_points, use_secondary?: true}} =
               sys("FIDE_TEAM")

      assert {:team, %{type: :b, score_mode: :game_points, use_secondary?: true}} =
               sys("FIDE_TEAM_TYPEB_GP_MP")

      assert {:team, %{type: :a, score_mode: :match_points, use_secondary?: false}} =
               sys("FIDE_TEAM_TYPEA_MP")

      assert {:team, %{type: :a, score_mode: :game_points, use_secondary?: false}} =
               sys("FIDE_TEAM_GP")
    end

    test "an individual code keeps the individual replay, team records or not" do
      assert sys("FIDE_DUTCH_2026") == :individual
      assert sys(nil, []) == :individual
    end

    test "predetermined, custom and accelerated team systems are not replayed" do
      for code <-
            ~w(FIDE_TEAM_ROUNDROBIN FIDE_TEAM_DOUBLEROUNDROBIN BERGER_TEAM_ROUNDROBIN_G2
               CUSTOM_TEAM_ROUNDROBIN FIDE_SCHEVENINGEN FIDE_SCHEVENINGEN_G2
               FIDE_DOUBLESCHEVENINGEN FIDE_SCHILLER FIDE_SCHILLER_4x2 CUSTOM_TEAM_KNOCKOUT
               CUSTOM_TEAM_SWISS FIDE_TEAM_MP_BAKU) do
        assert {:unreplayable, _} = sys(code), code
      end
    end
  end

  test "an individual Swiss with team records keeps the individual replay" do
    {text, _seed} = Ainalrami.Generator.generate(seed: 7, players: 16, rounds: 5)
    parsed = Trf.parse(text)
    ranks = Enum.map(parsed.players, & &1.rank)

    teams =
      ranks
      |> Enum.chunk_every(4)
      |> Enum.with_index(1)
      |> Enum.map(fn {chunk, i} -> %{name: "Club #{i}", player_ranks: chunk} end)

    assert TeamReplay.system(%{parsed | teams: teams}) == :individual

    {out, code} = check(Trf.serialize(%{parsed | teams: teams}))
    assert code == 0, out
    refute out =~ "team round(s)"
  end

  # ---- editing a parsed file --------------------------------------------------

  defp roster(parsed, team) do
    Enum.find_value(Enum.with_index(parsed.teams, 1), fn {t, i} ->
      if (Map.get(t, :number) || i) == team, do: t.player_ranks
    end)
  end

  # The players of `team` who met somebody in `round`, in roster order.
  defp lineup(parsed, team, round) do
    by_rank = Map.new(parsed.players, &{&1.rank, &1})

    for rank <- roster(parsed, team),
        game = Enum.at(by_rank[rank].games, round - 1),
        game != nil and is_integer(game.opponent_rank),
        do: rank
  end

  # A-B and C-D become A-D and C-B: B's and D's players swap their round
  # games (opponent, colour, result), and A's and C's point at them.
  defp exchange_opponents(parsed, round, {a, b}, {c, d}) do
    [la, lb, lc, ld] = Enum.map([a, b, c, d], &lineup(parsed, &1, round))
    by_rank = Map.new(parsed.players, &{&1.rank, &1})
    game = fn rank -> Enum.at(by_rank[rank].games, round - 1) end

    b_to_d = Map.new(Enum.zip(lb, ld))
    d_to_b = Map.new(Enum.zip(ld, lb))

    new_games =
      Map.new(
        for(r <- la, do: {r, %{game.(r) | opponent_rank: b_to_d[game.(r).opponent_rank]}}) ++
          for(r <- lc, do: {r, %{game.(r) | opponent_rank: d_to_b[game.(r).opponent_rank]}}) ++
          for({x, y} <- Enum.zip(lb, ld), do: {x, game.(y)}) ++
          for({x, y} <- Enum.zip(lb, ld), do: {y, game.(x)})
      )

    put_round_games(parsed, round, new_games)
  end

  defp reverse_colours(parsed, round, teams) do
    by_rank = Map.new(parsed.players, &{&1.rank, &1})

    new_games =
      for team <- teams, rank <- lineup(parsed, team, round), into: %{} do
        g = Enum.at(by_rank[rank].games, round - 1)
        {rank, %{g | colour: if(g.colour == "w", do: "b", else: "w")}}
      end

    put_round_games(parsed, round, new_games)
  end

  defp put_round_games(parsed, round, new_games) do
    players =
      Enum.map(parsed.players, fn p ->
        case new_games[p.rank] do
          nil -> p
          g -> %{p | games: List.replace_at(p.games, round - 1, g)}
        end
      end)

    %{parsed | players: players}
  end
end
