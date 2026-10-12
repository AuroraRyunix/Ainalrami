defmodule Ainalrami.RoundRobinCLITest do
  @moduledoc """
  Individual round robins on the standalone CLI: `-p` gives the next round
  of the Berger table with OpenPairings' boards (the fixture is
  OpenPairings' own `RoundRobin.schedule/3` output for 3-16 players, one
  and two cycles), `-c` checks a file against the table, `-g --roundrobin`
  writes one that `-c` passes.
  """
  # Not async: `capture_io(:stderr, ...)` is VM-wide (see team_cli_test).
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Ainalrami.{Berger, CLI, RoundRobin, RoundRobinGenerator, Trf}

  @fixture Path.join([__DIR__, "..", "fixtures", "round_robin", "openpairings_berger.txt"])
  @external_resource @fixture

  @rounds @fixture
          |> File.read!()
          |> String.split(~r/\r?\n/, trim: true)
          |> Enum.reject(&String.starts_with?(&1, "#"))
          |> Enum.map(fn line ->
            [head, boards] = String.split(line, ": ")
            [n, cycles, round] = head |> String.split() |> Enum.map(&String.to_integer/1)

            boards =
              boards
              |> String.split()
              |> Enum.map(fn b ->
                [w, k] = b |> String.split("-") |> Enum.map(&String.to_integer/1)
                {w, k}
              end)

            {n, cycles, round, boards}
          end)

  defp tmp(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ainalrami_rr_cli_#{System.unique_integer([:positive])}_#{name}"
      )

    on_exit(fn -> File.rm(path) end)
    path
  end

  defp cli(args) do
    ref = make_ref()

    out =
      capture_io(fn ->
        capture_io(:stderr, fn -> Process.put(ref, CLI.run(args)) end) |> IO.write()
      end)

    {out, Process.get(ref)}
  end

  defp write(text) do
    path = tmp("in.trf")
    File.write!(path, text)
    path
  end

  # A file of `n` players whose rounds 1..k-1 are the fixture's, every game
  # drawn and the free player given a zero-point bye.
  defp file_before(n, cycles, k) do
    played = for {^n, ^cycles, r, boards} <- @rounds, r < k, do: {r, boards}

    games =
      Enum.reduce(played, Map.new(1..n, &{&1, []}), fn {_r, boards}, acc ->
        Enum.reduce(boards, acc, fn
          {p, 0}, acc ->
            Map.update!(acc, p, &(&1 ++ [%{opponent_rank: nil, colour: nil, result: "Z"}]))

          {w, b}, acc ->
            acc
            |> Map.update!(w, &(&1 ++ [%{opponent_rank: b, colour: "w", result: "="}]))
            |> Map.update!(b, &(&1 ++ [%{opponent_rank: w, colour: "b", result: "="}]))
        end)
      end)

    players =
      for i <- 1..n do
        %{rank: i, name: "P#{i}", fide_rating: 2000, points: 0.0, games: games[i]}
      end

    Trf.serialize(
      %{
        tournament: %{
          name: "RR",
          type_code: "BERGER_ROUNDROBIN_G#{cycles}",
          number_of_rounds: Berger.total_rounds(n, cycles)
        },
        players: players
      },
      dialect: :trf26
    )
  end

  defp boards_of(output) do
    [_count | lines] = String.split(output, "\r\n", trim: true)

    Enum.map(lines, fn l ->
      [a, b] = l |> String.split() |> Enum.map(&String.to_integer/1)
      {a, b}
    end)
  end

  test "the fixture covers 3-16 players, one and two cycles, every round" do
    for n <- 3..16, cycles <- [1, 2] do
      count = Enum.count(@rounds, fn {m, c, _, _} -> m == n and c == cycles end)
      assert count == Berger.total_rounds(n, cycles), "#{n} players, #{cycles} cycle(s)"
    end
  end

  test "-p gives OpenPairings' boards, in its order, for every round of 3-16 players" do
    for {n, cycles, k, expected} <- @rounds do
      {out, code} = cli([write(file_before(n, cycles, k)), "-p", "-q"])
      assert code == 0, "#{n}/#{cycles} round #{k}: #{out}"
      assert boards_of(out) == expected, "#{n} players, #{cycles} cycle(s), round #{k}"
    end
  end

  test "-p after the last round says the table is finished" do
    {out, 1} = cli([write(file_before(4, 1, 4)), "-p"])
    assert out =~ "every round of the Berger table is paired (3)"
  end

  test "-c passes every generated round robin, tie-breaks included" do
    for seed <- 1..12 do
      {text, ^seed} = RoundRobinGenerator.generate(seed: seed, tie_breaks: ["SB", "DE"])
      {out, code} = cli([write(text), "-c"])
      assert code == 0, out
      assert out =~ "matches the Berger table"
      assert out =~ "standings: all"
    end
  end

  test "-c flags a round whose colours are reversed, and one with another pairing" do
    g = RoundRobinGenerator.run(seed: 5, players: 6, cycles: 1, forfeit_pct: 0)
    parsed = Trf.parse(g.text)

    flipped =
      Enum.map(parsed.players, fn p ->
        games =
          List.update_at(p.games, 1, fn
            %{colour: "w"} = x -> %{x | colour: "b"}
            %{colour: "b"} = x -> %{x | colour: "w"}
            x -> x
          end)

        %{p | games: games}
      end)

    {out, 1} = cli([write(Trf.serialize(%{parsed | players: flipped})), "-c"])
    assert out =~ "round 2: DIFFERS in colours only"

    # Round 3 with two games' opponents exchanged.
    [{a, b}, {c, d} | _] = g.pairings[3].boards

    swapped =
      Enum.map(parsed.players, fn p ->
        games =
          List.update_at(p.games, 2, fn x ->
            new =
              case p.rank do
                ^a -> d
                ^d -> a
                ^c -> b
                ^b -> c
                _ -> x.opponent_rank
              end

            if p.rank in [a, b, c, d],
              do: %{x | opponent_rank: new, result: "="},
              else: x
          end)

        %{p | games: games}
      end)

    {out, 1} = cli([write(Trf.serialize(%{parsed | players: swapped})), "-c"])
    assert out =~ "round 3: DIFFERS from the Berger table"
  end

  test "FIDE_DOUBLEROUNDROBIN plays the first cycle's last two rounds in reverse order" do
    {:ok, last, _} = Berger.round(6, 2, 5)
    {:ok, before_last, _} = Berger.round(6, 2, 4)
    assert {:ok, ^last, _} = Berger.round(6, 2, 4, reverse_last_two?: true)
    assert {:ok, ^before_last, _} = Berger.round(6, 2, 5, reverse_last_two?: true)
    assert Berger.round(6, 2, 6, reverse_last_two?: true) == Berger.round(6, 2, 6)

    parsed = %{tournament: %{type_code: "FIDE_DOUBLEROUNDROBIN"}, teams: [], players: []}

    assert {:round_robin, %{games: 2, reverse_last_two?: true}} =
             Ainalrami.TeamReplay.system(parsed)

    g =
      Stream.iterate(1, &(&1 + 1))
      |> Stream.map(&RoundRobinGenerator.run(seed: &1, cycles: 2))
      |> Enum.find(&(&1.text =~ "192 FIDE_DOUBLEROUNDROBIN"))

    {out, 0} = cli([write(g.text), "-c"])
    assert out =~ "the first cycle's last two rounds reversed"
  end

  test "-x says the table fixed the round; Swiss-only options are refused" do
    path = write(file_before(5, 1, 2))
    {out, 0} = cli([path, "-x", "-q"])
    assert out =~ "Nothing is chosen"
    assert out =~ ": free round"

    {out, 1} = cli([path, "-p", "--bye-want=2"])
    assert out =~ "round robin's byes are the table's"

    {out, 1} = cli([path, "-x", "--force=1-2"])
    assert out =~ "--force is not for a round robin"
  end

  test "-g --roundrobin writes a TRF26 round robin, repeatable from its seed" do
    path = tmp("g.trf")
    {err, 0} = cli(["-g", path, "--roundrobin", "--seed=9", "--players=7", "--cycles=1"])
    assert err =~ "seed 9"
    text = File.read!(path)
    assert text =~ "\r\n192 BERGER_ROUNDROBIN_G1\r\n"
    assert length(Trf.parse(text).players) == 7

    again = tmp("again.trf")
    {_, 0} = cli(["-g", again, "--roundrobin", "--seed=9", "--players=7", "--cycles=1"])
    assert File.read!(again) == text

    {out, 1} = cli(["-g", "--roundrobin", "--acceleration=baku"])
    assert out =~ "--acceleration is not an option of -g --roundrobin"
  end

  test "a 092 round robin with no 192 is checked, its cycles from its rounds" do
    {text, _} = RoundRobinGenerator.generate(seed: 3, players: 6, cycles: 1)
    parsed = Trf.parse(text)
    tournament = Map.delete(parsed.tournament, :type_code)
    {out, 0} = cli([write(Trf.serialize(%{parsed | tournament: tournament})), "-c"])
    assert out =~ "092 round robin"
    assert RoundRobin.cycles_played(parsed) == 1
  end
end
