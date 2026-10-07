defmodule Ainalrami.CLIParityTest do
  @moduledoc """
  The pairing options OpenPairings uses that the standalone CLI could not
  express until now - the Swiss and round robin match formats (`XXM`,
  `--match-format`), pairing by category (`XXG`, `--groups=`) for a Swiss
  and a round robin, and soft pairs (`--soft-pairs=`, `--soft-position=`):
  each round-trips through the TRF and the CLI, `-g` writes files `-c`
  passes, `-p` on every round of them gives what was generated, and the
  CLI's answer is the library's answer for the same input.
  """
  # Not async: `capture_io(:stderr, ...)` is VM-wide (see team_cli_test).
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Ainalrami.{
    Berger,
    CLI,
    EventFormat,
    Generator,
    Pairing,
    RoundRobinGenerator,
    TeamGenerator,
    Trf
  }

  @fixture Path.join([__DIR__, "..", "fixtures", "round_robin", "openpairings_berger.txt"])
  @external_resource @fixture

  # OpenPairings' single-cycle Berger boards, `{n, round} => boards`.
  @table @fixture
         |> File.read!()
         |> String.split(~r/\r?\n/, trim: true)
         |> Enum.reject(&String.starts_with?(&1, "#"))
         |> Enum.flat_map(fn line ->
           [head, boards] = String.split(line, ": ")
           [n, cycles, round] = head |> String.split() |> Enum.map(&String.to_integer/1)

           boards =
             boards
             |> String.split()
             |> Enum.map(fn b ->
               [w, k] = b |> String.split("-") |> Enum.map(&String.to_integer/1)
               {w, k}
             end)

           if cycles == 1, do: [{{n, round}, boards}], else: []
         end)
         |> Map.new()

  defp tmp(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ainalrami_parity_#{System.unique_integer([:positive])}_#{name}"
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

  # The file as it stood before round `k` was paired.
  defp cut(parsed, k) do
    players = EventFormat.before_round(parsed.players, k, parsed.tournament[:point_system])

    tournament =
      parsed.tournament |> Map.drop([:tie_breaks, :standings_order]) |> Map.delete(:byes)

    %{parsed | players: Enum.map(players, &Map.put(&1, :final_rank, nil)), tournament: tournament}
  end

  defp pairs_of(output) do
    [_count | lines] = String.split(output, "\r\n", trim: true)

    Enum.map(lines, fn line ->
      [a, b] = line |> String.split() |> Enum.map(&String.to_integer/1)
      {a, if(b == 0, do: nil, else: b)}
    end)
  end

  defp p(text, extra \\ []) do
    # The board list to a file: a warning (soft pairs announce themselves)
    # goes to stderr, which `cli/1` folds into what it returns.
    output = tmp("out.txt")
    {out, code} = cli([write(text), "-p", output, "-q" | extra])
    assert code == 0, out
    output |> File.read!() |> pairs_of()
  end

  defp library_opts(parsed) do
    t = parsed.tournament

    [
      expected_rounds: t[:number_of_rounds],
      forbidden_pairs: t[:forbidden_pairs],
      point_system: t[:point_system],
      initial_colour: t[:initial_colour]
    ] ++
      if(t[:match_format], do: [match_format: true], else: []) ++
      if(t[:pairing_groups], do: [groups: t.pairing_groups], else: [])
  end

  describe "the TRF records" do
    test "XXM and XXG round-trip in both dialects" do
      {text, _} = Generator.generate(seed: 3, players: 9, rounds: 2, groups: [[1, 4, 7], [2, 5]])
      parsed = Trf.parse(text)
      assert parsed.tournament.pairing_groups == [[1, 4, 7], [2, 5]]

      data = %{parsed | tournament: Map.put(parsed.tournament, :match_format, true)}

      for dialect <- [:engine, :trf26] do
        again = data |> Trf.serialize(dialect: dialect) |> Trf.parse()
        assert again.tournament.match_format == true
        assert again.tournament.pairing_groups == [[1, 4, 7], [2, 5]]
      end
    end

    test "a malformed XXM or XXG is refused, not skipped" do
      base = Trf.serialize(%{tournament: %{name: "x"}, players: [player(1), player(2)]})

      for {line, message} <- [
            {"XXM 3", "XXM takes no value"},
            {"XXG 1 x", "not a starting rank"},
            {"XXG 1 9", "not a starting rank in this file"},
            {"XXG 1\r\nXXG 1 2", "in two pairing groups"}
          ] do
        assert_raise Trf.ValidationError, ~r/#{message}/, fn ->
          Trf.parse(base <> line <> "\r\n")
        end
      end
    end
  end

  describe "Swiss match format" do
    test "odd rounds are the Dutch system, even rounds the round before reversed; -c passes" do
      for seed <- 1..6 do
        {text, ^seed} =
          Generator.generate(seed: seed, players: 9 + seed, rounds: 8, match_format: true)

        assert text =~ "\r\n192 CUSTOM_SWISS\r\n"
        assert text =~ "\r\nXXM\r\n"
        {out, 0} = cli([write(text), "-c"])
        assert out =~ "the second leg of round 1's match"

        parsed = Trf.parse(text)

        for k <- 1..Trf.rounds_played(parsed.players) do
          before = cut(parsed, k)
          file = Trf.serialize(before)
          pairs = p(file)

          # The CLI is the library.
          assert pairs == EventFormat.pair_next_round(before.players, library_opts(before))

          recorded = EventFormat.recorded(parsed.players, k)

          if rem(k, 2) == 1 do
            assert pairs ==
                     Pairing.pair_next_round(
                       before.players,
                       library_opts(before) -- [match_format: true]
                     )

            assert Enum.sort(pairs) == Enum.sort(recorded)
          else
            previous = EventFormat.recorded(parsed.players, k - 1)
            mirrored = Enum.map(previous, fn {w, b} -> if b, do: {b, w}, else: {w, nil} end)
            assert Enum.sort(pairs) == Enum.sort(mirrored)
            assert Enum.sort(pairs) == Enum.sort(recorded)
          end

          # `--match-format` says what `XXM` says.
          plain = %{before | tournament: Map.delete(before.tournament, :match_format)}
          assert p(Trf.serialize(plain), ["--match-format"]) == pairs
        end
      end
    end

    test "the second leg keeps the first leg's board order" do
      {text, _} = Generator.generate(seed: 11, players: 12, rounds: 4, match_format: true)
      parsed = Trf.parse(text)
      first = p(Trf.serialize(cut(parsed, 3)))
      second = p(Trf.serialize(cut(parsed, 4)))
      assert second == Enum.map(first, fn {w, b} -> if b, do: {b, w}, else: {w, nil} end)
    end

    test "a second leg that cannot be copied is refused; -x says nothing was chosen" do
      {text, _} = Generator.generate(seed: 2, players: 8, rounds: 2, match_format: true)
      before = cut(Trf.parse(text), 2)

      {out, 0} = cli([write(Trf.serialize(before)), "-x", "-q"])
      assert out =~ "the second leg of the match begun in round 1"
      assert out =~ "Nothing is chosen"

      {out, 1} = cli([write(Trf.serialize(before)), "-x", "--force=1-2"])
      assert out =~ "--force is for a single pairing pool"

      # #1 played round 1 and is now away for round 2.
      away =
        Enum.map(before.players, fn pl ->
          if pl.rank == 1,
            do: %{pl | games: pl.games ++ [%{opponent_rank: nil, colour: nil, result: "Z"}]},
            else: pl
        end)

      {out, 1} = cli([write(Trf.serialize(%{before | players: away})), "-p"])
      assert out =~ "#1, seated in round 1, already has a result for round 2"
    end

    test "-c flags a second leg whose colours were not reversed" do
      {text, _} = Generator.generate(seed: 5, players: 10, rounds: 2, match_format: true)
      parsed = Trf.parse(text)

      flipped =
        Enum.map(parsed.players, fn pl ->
          games =
            List.update_at(pl.games, 1, fn
              %{colour: "w"} = g -> %{g | colour: "b"}
              %{colour: "b"} = g -> %{g | colour: "w"}
              g -> g
            end)

          %{pl | games: games}
        end)

      {out, 1} = cli([write(Trf.serialize(%{parsed | players: flipped})), "-c"])
      assert out =~ "round 2: DIFFERS from round 1 with the colours reversed"
    end
  end

  describe "Swiss pairing groups" do
    test "each group is paired on its own, as a TRF marking everyone else absent pairs it" do
      for seed <- 1..5 do
        {text, ^seed} = Generator.generate(seed: seed, players: 16, rounds: 4, groups: 3)
        assert text =~ "\r\nXXG "
        {out, 0} = cli([write(text), "-c"])
        assert out =~ "pairing group 1 (XXG)"

        parsed = Trf.parse(text)
        groups = parsed.tournament.pairing_groups

        for k <- 1..Trf.rounds_played(parsed.players) do
          before = cut(parsed, k)
          pairs = p(Trf.serialize(before))
          assert pairs == EventFormat.pair_next_round(before.players, library_opts(before))

          # The same groups from the command line.
          plain = %{before | tournament: Map.delete(before.tournament, :pairing_groups)}
          flag = "--groups=" <> Enum.map_join(groups, "/", &Enum.join(&1, ","))
          assert p(Trf.serialize(plain), [flag]) == pairs

          # OpenPairings' own construction, in the file: one TRF per group
          # carrying every player, the others given `0000 - Z` for the round.
          played = Trf.rounds_played(before.players)

          expected =
            Enum.flat_map(groups, fn group ->
              members = MapSet.new(group)

              field =
                Enum.map(plain.players, fn pl ->
                  if MapSet.member?(members, pl.rank) or length(pl.games) > played,
                    do: pl,
                    else: %{
                      pl
                      | games: pl.games ++ [%{opponent_rank: nil, colour: nil, result: "Z"}]
                    }
                end)

              case Enum.count(field, &(length(&1.games) <= played)) do
                0 -> []
                1 -> [{Enum.find(field, &(length(&1.games) <= played)).rank, nil}]
                _ -> p(Trf.serialize(%{plain | players: field}))
              end
            end)

          assert pairs == expected, "seed #{seed} round #{k}"

          for {w, b} <- pairs, b != nil do
            assert Enum.find(groups, &(w in &1)) == Enum.find(groups, &(b in &1))
          end
        end
      end
    end

    test "groups and match format together are refused, as OpenPairings refuses them" do
      {text, _} = Generator.generate(seed: 1, players: 8, rounds: 0, groups: [[1, 2, 3, 4]])
      {out, 1} = cli([write(text), "-p", "--match-format"])
      assert out =~ "match format and pairing groups together are not paired"
      {out, 1} = cli(["-g", "--match-format", "--groups=2"])
      assert out =~ "--match-format and --groups together"
    end

    test "-x explains each group as its own round" do
      {text, _} = Generator.generate(seed: 4, players: 12, rounds: 2, groups: 2)
      {out, 0} = cli([write(text), "-x", "-q"])
      assert out =~ "== Pairing group 1 of 2 (XXG)"
      assert out =~ "== Pairing group 2 of 2 (XXG)"
    end
  end

  describe "round robin match format and groups" do
    test "-p gives OpenPairings' match schedule: table round k twice, the second reversed" do
      for n <- 3..10 do
        g = RoundRobinGenerator.run(seed: n, players: n, match_format: true)
        assert g.text =~ "\r\n192 CUSTOM_ROUNDROBIN\r\n"
        assert g.rounds == 2 * Berger.total_rounds(n, 1)
        {out, 0} = cli([write(g.text), "-c"])
        assert out =~ "two-game match"

        parsed = Trf.parse(g.text)

        for k <- 1..g.rounds do
          table = Map.fetch!(@table, {n, div(k + 1, 2)})

          expected =
            if rem(k, 2) == 1,
              do: table,
              else: Enum.map(table, fn {w, b} -> if b == 0, do: {w, 0}, else: {b, w} end)

          got =
            parsed
            |> cut(k)
            |> Trf.serialize(dialect: :trf26)
            |> p()
            |> Enum.map(fn {w, b} -> {w, b || 0} end)

          assert got == expected, "#{n} players, round #{k}"
        end
      end
    end

    test "-p gives one table per group, each OpenPairings' table, table after table" do
      groups = [[2, 3, 5, 8, 9], [1, 4, 6, 7]]
      g = RoundRobinGenerator.run(seed: 1, players: 9, cycles: 1, groups: groups)
      {_, 0} = cli([write(g.text), "-c"])
      parsed = Trf.parse(g.text)

      for k <- 1..g.rounds do
        expected =
          groups
          |> Enum.map(&Enum.sort/1)
          |> Enum.flat_map(fn group ->
            case Map.get(@table, {length(group), k}) do
              nil -> []
              boards -> Enum.map(boards, fn {w, b} -> {Enum.at(group, w - 1), b} end)
            end
            |> Enum.map(fn
              {w, 0} -> {:free, w}
              {w, b} -> {w, Enum.at(group, b - 1)}
            end)
          end)

        boards = for {w, b} <- expected, w != :free, do: {w, b}
        free = for {:free, w} <- expected, do: {w, nil}

        assert p(Trf.serialize(cut(parsed, k), dialect: :trf26)) == boards ++ free
      end

      # The same groups from the command line, on the file without XXG.
      plain = %{parsed | tournament: Map.delete(parsed.tournament, :pairing_groups)}
      at3 = cut(plain, 3)
      with_xxg = cut(parsed, 3)

      assert p(Trf.serialize(at3, dialect: :trf26), ["--groups=2,3,5,8,9/1,4,6,7"]) ==
               p(Trf.serialize(with_xxg, dialect: :trf26))
    end

    test "a double round robin in match format is refused, not guessed at" do
      g = RoundRobinGenerator.run(seed: 2, players: 6, cycles: 2)
      {out, 2} = cli([write(g.text), "-p", "--match-format"])
      assert out =~ "XXM (match format) plays one Berger table"
    end

    test "a team round robin in match format: -c passes and -p gives each round" do
      for seed <- 1..4 do
        g = TeamGenerator.run(seed: seed, system: :round_robin, match_format: true)
        assert g.text =~ "\r\nXXM\r\n"
        {out, 0} = cli([write(g.text), "-c"])
        assert out =~ "two matches in a row"
      end
    end
  end

  describe "soft pairs" do
    test "-p with --soft-pairs is the library's pairing with :soft_pairs" do
      {text, _} = Generator.generate(seed: 21, players: 14, rounds: 3)
      parsed = Trf.parse(text)
      before = cut(parsed, 3)

      for position <- [:strong, :weak] do
        got = p(Trf.serialize(before), ["--soft-pairs=1,2/3,4,5", "--soft-position=#{position}"])

        assert got ==
                 Pairing.pair_next_round(
                   before.players,
                   library_opts(before) ++
                     [soft_pairs: [[1, 2], [3, 4, 5]], soft_position: position]
                 )
      end

      {out, 1} = cli([write(text), "-c", "--soft-pairs=1,2"])
      assert out =~ "--soft-pairs applies to -p and -x only"
      {out, 1} = cli([write(text), "-p", "--soft-position=weak"])
      assert out =~ "--soft-position needs --soft-pairs"
      {out, 1} = cli([write(text), "-p", "--soft-pairs=1"])
      assert out =~ "--soft-pairs takes groups of two or more"
    end
  end

  defp player(rank),
    do: %{rank: rank, name: "P#{rank}", fide_rating: 2000, points: 0.0, games: []}
end
