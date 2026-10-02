defmodule Ainalrami.GeneratorUnsetTest do
  @moduledoc """
  The generator against VCL4THP v13 Q25, Q30 and Q32: options left out
  are drawn rather than always off (`unset: :random`, what `-g` uses), a
  run without a seed does not repeat an earlier one, and results follow
  the FIDE rating table with its 400-point cap.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Ainalrami.{CLI, Generator, Trf}
  alias Ainalrami.Tiebreaks.Rating

  defp sha(text), do: Base.encode16(:crypto.hash(:sha256, text), case: :lower)

  defp tmp(label),
    do:
      Path.join(System.tmp_dir!(), "ainalrami-#{label}-#{System.unique_integer([:positive])}.trf")

  defp results(parsed), do: for(p <- parsed.players, g <- p.games, do: g.result)

  describe "a seed per run (Q30)" do
    test "without a seed, calls in one VM draw different seeds and different tournaments" do
      runs = for _ <- 1..20, do: Generator.generate(players: 10, rounds: 3)
      seeds = Enum.map(runs, &elem(&1, 1))

      assert length(Enum.uniq(seeds)) == 20
      assert runs |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == 20

      # Drawn on a throwaway state: the caller's own :rand stream is not
      # reseeded by asking for a fresh seed.
      for {text, seed} <- runs, do: assert(text =~ "012 Ainalrami RTG seed=#{seed}\r\n")
    end

    test "the seed a run drew reproduces it, in either unset mode" do
      for unset <- [:fixed, :random] do
        {text, seed} = Generator.generate(unset: unset, players: 14, rounds: 5)

        assert {^text, ^seed} =
                 Generator.generate(unset: unset, seed: seed, players: 14, rounds: 5)
      end
    end

    test "two -g runs without --seed write different files, each reproducible from its own" do
      [a, b, again] = for label <- ~w(a b again), do: tmp("q30-#{label}")
      on_exit(fn -> Enum.each([a, b, again], &File.rm/1) end)

      for path <- [a, b] do
        capture_io(fn ->
          assert CLI.run(["-g", path, "--players=12", "--rounds=4", "-q"]) == 0
        end)
      end

      refute File.read!(a) == File.read!(b)

      [seed] = Regex.run(~r/seed=(\d+)/, File.read!(a), capture: :all_but_first)

      capture_io(fn ->
        assert CLI.run(["-g", again, "--seed=#{seed}", "--players=12", "--rounds=4", "-q"]) == 0
      end)

      assert File.read!(again) == File.read!(a)
    end

    test "-g prints the seed it used" do
      path = tmp("q30-print")
      on_exit(fn -> File.rm(path) end)

      out = capture_io(fn -> assert CLI.run(["-g", path, "--players=8", "--rounds=3"]) == 0 end)
      [seed] = Regex.run(~r/seed=(\d+)/, File.read!(path), capture: :all_but_first)
      assert out =~ "seed #{seed}"
    end
  end

  describe "unset options are drawn (Q25)" do
    @axes [
      :full_bye_pct,
      :half_bye_pct,
      :zero_bye_pct,
      :forfeit_win_pct,
      :double_forfeit_pct,
      :odd_results_pct
    ]

    # What a generated file shows of each axis.
    defp seen(text) do
      parsed = Trf.parse(text)
      rs = results(parsed)

      %{
        full_bye: "F" in rs,
        half_bye: "H" in rs,
        zero_bye: "Z" in rs,
        forfeit: "+" in rs,
        baku: Enum.any?(parsed.players, &(&1[:accelerations] not in [nil, []])),
        tie_breaks: parsed.tournament[:tie_breaks] not in [nil, []]
      }
    end

    test "each axis turns up in some tournaments and not in others" do
      seen =
        for seed <- 1..60 do
          {text, _} = Generator.generate(unset: :random, seed: seed, players: 16, rounds: 7)
          seen(text)
        end

      for axis <- [:full_bye, :half_bye, :zero_bye, :forfeit, :baku, :tie_breaks] do
        hits = Enum.count(seen, & &1[axis])
        assert hits > 0 and hits < 60, "#{axis} in #{hits} of 60"
      end
    end

    test "the fixed default draws nothing, so recorded seeds keep their bytes" do
      # The digests in generator_checklist_test.exs hold the default to the
      # bytes it always produced; `unset: :fixed` is that default, named.
      for seed <- [1, 2, 42] do
        assert Generator.generate(seed: seed) == Generator.generate(seed: seed, unset: :fixed)
      end

      assert {text, 1} = Generator.generate(seed: 1)
      assert sha(text) == "daafea2965b896d394f7150c5777efd454b1891b15d2f2ea33f5c070dd4353ad"
    end

    test "a given option is kept, an explicit 0 included" do
      zeros = Enum.map(@axes, &{&1, 0}) ++ [tie_breaks: nil]

      for seed <- 1..25 do
        {text, _} =
          Generator.generate(
            [unset: :random, unset_chance: 100, seed: seed, players: 14, rounds: 6] ++
              Keyword.delete(zeros, :tie_breaks)
          )

        s = seen(text)
        refute s.full_bye or s.half_bye or s.zero_bye or s.forfeit, "seed #{seed}"
        # Unset Baku and tie-breaks at 100% are always drawn.
        assert s.baku and s.tie_breaks, "seed #{seed}"
      end
    end

    test "giving one more option changes only that option's draw" do
      base = [unset: :random, unset_chance: 100, seed: 77, players: 12, rounds: 5]
      {with_list, _} = Generator.generate(base ++ [tie_breaks: ["SB"]])
      {drawn, _} = Generator.generate(base)

      strip = fn text ->
        text
        |> String.split("\r\n")
        |> Enum.reject(&String.starts_with?(&1, "202 "))
        |> Enum.map(&String.slice(&1, 0, 84))
      end

      # Same roster, byes, results and acceleration; only the list (and so
      # the final ranks in columns 86-89) differ.
      assert strip.(with_list) == strip.(drawn)
      assert with_list =~ "202 SB\r\n"
    end

    test "unset_chance 0 switches every axis off but results still follow the table" do
      for seed <- 1..20 do
        {text, _} =
          Generator.generate(unset: :random, unset_chance: 0, seed: seed, players: 12, rounds: 5)

        s = seen(text)
        refute Enum.any?(Map.values(s)), "seed #{seed}"
        refute text =~ ~r/\d \w [+-]/
      end
    end

    test "random-mode tournaments are valid TRF that check clean, tie-breaks and Baku included" do
      for seed <- 1..40 do
        {text, _} = Generator.generate(unset: :random, unset_chance: 70, seed: seed)
        path = tmp("q25-#{seed}")
        File.write!(path, text)

        {code, _} = with_io(fn -> CLI.run([path, "-c", "-q"]) end)
        File.rm(path)
        assert code == 0, "seed #{seed} failed its own checker"
      end
    end

    test "bad unset values are refused" do
      assert_raise ArgumentError, ~r/:unset/, fn ->
        Generator.generate(seed: 1, unset: :sometimes)
      end

      assert_raise ArgumentError, ~r/:unset_chance/, fn ->
        Generator.generate(seed: 1, unset: :random, unset_chance: 101)
      end

      for flag <- ["--unset=maybe", "--unset-chance=101", "--unset-chance=-1"] do
        {{code, _}, _} =
          with_io(fn -> with_io(:stderr, fn -> CLI.run(["-g", flag, "-q"]) end) end)

        assert code != 0, flag
      end
    end
  end

  describe "results by the rating table, 400-point cap (Q32)" do
    # 2600 against 1900: the table says 0.99, the rating calculation counts
    # the 700 as 400 and expects 0.92. Results whose expectation is the
    # uncapped 0.99 move the 2600's rating up every time they meet.
    defp mean_score(mode) do
      scores =
        for seed <- 1..2000 do
          {text, _} =
            Generator.generate(
              seed: seed,
              players: 2,
              rounds: 1,
              ratings: [2600, 1900],
              results: mode
            )

          [first | _] = Trf.parse(text).players
          Trf.points_for(hd(first.games).result)
        end

      Enum.sum(scores) / length(scores)
    end

    test "a gap over 400 is scored as a gap of 400" do
      assert Rating.expected_hundredths(2300, 1900) == 92
      assert abs(mean_score(:fide) - 0.92) < 0.02
      assert abs(mean_score(:fide_uncapped) - 0.99) < 0.01
    end

    # Q32's own test: the same players, the same ratings, many tournaments,
    # and each player's rating change should come out close to zero. Two
    # pairs 750-850 points apart, round robin in three rounds, so most games
    # are across a gap the cap applies to - under `:fide_uncapped` the two
    # 2600s gain about 0.05 of a point per game over the rating calculation.
    defp drift(mode) do
      for seed <- 1..1000, reduce: %{} do
        acc ->
          {text, _} =
            Generator.generate(
              seed: seed,
              players: 4,
              rounds: 3,
              ratings: [2700, 2650, 1900, 1850],
              results: mode
            )

          parsed = Trf.parse(text)
          rating = Map.new(parsed.players, &{&1.rank, &1.fide_rating})

          for p <- parsed.players, g <- p.games, g.opponent_rank != nil, reduce: acc do
            acc ->
              diff = (rating[p.rank] - rating[g.opponent_rank]) |> max(-400) |> min(400)
              delta = Trf.points_for(g.result) - Rating.expected_hundredths(diff, 0) / 100
              Map.update(acc, p.rank, {delta, 1}, fn {s, n} -> {s + delta, n + 1} end)
          end
      end
      |> Map.new(fn {rank, {sum, games}} -> {rank, sum / games} end)
    end

    test "fixed ratings over many tournaments: every player's rating change averages out" do
      # Score minus expected per game, which K multiplies into the change.
      for {rank, per_game} <- drift(:fide) do
        assert abs(per_game) < 0.015, "TPN #{rank}: #{Float.round(per_game, 4)} per game"
      end

      uncapped = drift(:fide_uncapped)
      assert uncapped[1] > 0.03 and uncapped[2] > 0.03
    end

    test ":fide_uncapped reproduces what :fide produced before the cap" do
      # Captured from f6a52b7, the generator before the cap.
      for {opts, digest} <- [
            {[seed: 21, players: 16, rounds: 6, ratings: {:step, 2650, 90}],
             "1308cdd6986b182648052c092ed8f48b4d091c274e63251d9d6cbbc6e725748d"},
            {[
               seed: 22,
               players: 11,
               rounds: 5,
               ratings: {:range, 1200, 2800},
               draw_rate: 0.2,
               odd_results_pct: 5,
               forfeit_win_pct: 5
             ], "d0d8c4605b8181b26434af05e75e4b936eca3a13de8b07223279baaa193c35f2"}
          ] do
        {text, _} = Generator.generate(opts ++ [results: :fide_uncapped])
        assert sha(text) == digest
      end
    end

    test "-g follows the table by default, --unset=fixed keeps the uniform draw" do
      ratings = "--ratings=2700,1500"

      score = fn extra ->
        scores =
          for seed <- 1..300 do
            path = tmp("q32")

            capture_io(fn ->
              0 =
                CLI.run(
                  ["-g", path, "--seed=#{seed}", "--players=2", "--rounds=1", ratings, "-q"] ++
                    extra
                )
            end)

            [first | _] = Trf.parse(File.read!(path)).players
            File.rm(path)
            Trf.points_for(hd(first.games).result)
          end

        Enum.sum(scores) / length(scores)
      end

      # Unset byes and forfeits can still land on this game at the default
      # chance; switch them off to measure the results alone.
      assert abs(score.(["--unset-chance=0"]) - 0.92) < 0.04
      assert abs(score.(["--unset=fixed"]) - 0.5) < 0.08
    end
  end
end
