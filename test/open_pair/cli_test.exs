defmodule OpenPair.CLITest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  alias OpenPair.{CLI, Log, Trf}

  setup do
    on_exit(fn -> Log.set_quiet(false) end)
  end

  defp write_trf!(text) do
    path =
      Path.join(System.tmp_dir!(), "open_pair_cli_test_#{System.unique_integer([:positive])}.trf")

    File.write!(path, text)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # Built via Trf.serialize/1 rather than hand-typed fixed-width text — a
  # manually counted column offset is exactly the kind of mistake that's
  # bitten this TRF parser before (see the sibling project's own history).
  # No game history — this is a round-1 roster.
  defp sample_trf do
    Trf.serialize(%{
      tournament: %{name: "CLI Test Open", type: "swiss"},
      players: [
        %{rank: 1, name: "A", fide_rating: 2000, points: 0.0, games: []},
        %{rank: 2, name: "B", fide_rating: 1900, points: 0.0, games: []}
      ]
    })
  end

  # Same idea, but WITH a round of history already played (4 players, two
  # round-1 boards decided) — exercises the round-2 bracket-cascade path
  # instead of round 1's own split-the-whole-field pairing.
  defp sample_trf_with_history do
    Trf.serialize(%{
      tournament: %{name: "CLI Test Open R2", type: "swiss"},
      players: [
        %{
          rank: 1,
          name: "A",
          fide_rating: 2000,
          points: 1.0,
          games: [%{opponent_rank: 3, colour: "w", result: "1"}]
        },
        %{
          rank: 2,
          name: "B",
          fide_rating: 1900,
          points: 1.0,
          games: [%{opponent_rank: 4, colour: "w", result: "1"}]
        },
        %{
          rank: 3,
          name: "C",
          fide_rating: 1800,
          points: 0.0,
          games: [%{opponent_rank: 1, colour: "b", result: "0"}]
        },
        %{
          rank: 4,
          name: "D",
          fide_rating: 1700,
          points: 0.0,
          games: [%{opponent_rank: 2, colour: "b", result: "0"}]
        }
      ]
    })
  end

  # Same roster, but round 1 has both players claiming a win — illegal per
  # `Trf`'s own result-pair validation. `Trf.serialize/1` would reject this
  # outright, so it's built by serializing a *legal* round then flipping one
  # result character afterward, the same technique the sibling project's own
  # `trf_test.exs` uses for this exact kind of fixture.
  defp illegal_result_trf do
    text =
      Trf.serialize(%{
        tournament: %{name: "Bad File", type: "swiss"},
        players: [
          %{
            rank: 1,
            name: "A",
            points: 0.0,
            games: [%{opponent_rank: 2, colour: "w", result: "1"}]
          },
          %{
            rank: 2,
            name: "B",
            points: 0.0,
            games: [%{opponent_rank: 1, colour: "b", result: "0"}]
          }
        ]
      })

    # Round 1's result column is 99 (base 92 + 7) — flip B's loss into a
    # second win.
    lines = String.split(text, "\r\n")
    p2 = Enum.find(lines, &(String.starts_with?(&1, "001") and &1 =~ "B"))
    {before, rest} = String.split_at(p2, 98)
    <<_::binary-size(1), after_::binary>> = rest
    bad_p2 = before <> "1" <> after_

    lines |> Enum.map(&if &1 == p2, do: bad_p2, else: &1) |> Enum.join("\r\n")
  end

  test "-h prints help and exits 0" do
    out = capture_io(fn -> assert CLI.run(["-h"]) == 0 end)
    assert out =~ "openpair — a FIDE Dutch-system Swiss pairing engine"
  end

  test "--version prints something and exits 0" do
    out = capture_io(fn -> assert CLI.run(["--version"]) == 0 end)
    assert String.trim(out) != ""
  end

  test "missing input file exits 1 with a usage message" do
    {out, code} = run_capturing(fn -> CLI.run(["-p"]) end)

    assert code == 1
    assert out =~ "missing input TRF file"
  end

  test "missing mode flag exits 1" do
    path = write_trf!(sample_trf())

    {out, code} = run_capturing(fn -> CLI.run([path]) end)

    assert code == 1
    assert out =~ "missing mode flag"
  end

  test "-p on a round-1 TRF file loads, reports the roster, and actually pairs it (exit 0)" do
    path = write_trf!(sample_trf())

    {out, code} = run_capturing(fn -> CLI.run([path, "-p"]) end)

    assert code == 0
    assert out =~ "Loading #{path}"
    assert out =~ "2 players, 0 teams"
    assert out =~ "#1 A"
    assert out =~ "#2 B"
    assert out =~ "#1 (white) vs. #2 (black)"
  end

  test "-p with no output file prints the JaVaFo-shaped pairing to stdout" do
    path = write_trf!(sample_trf())

    {out, code} = run_capturing(fn -> CLI.run([path, "-p"]) end)

    assert code == 0
    # javafo.jar's own output shape: a count line, then "white black" lines,
    # CRLF throughout — confirmed against a real javafo.jar run.
    assert out =~ "1\r\n1 2\r\n"
  end

  test "-p with an output file writes the pairing there instead of stdout" do
    path = write_trf!(sample_trf())
    out_path = write_trf!("")

    {out, code} = run_capturing(fn -> CLI.run([path, "-p", out_path]) end)

    assert code == 0
    assert out =~ "wrote #{out_path}"
    assert File.read!(out_path) == "1\r\n1 2\r\n"
  end

  test "-p on a later round (game history already present) pairs it via the bracket cascade" do
    path = write_trf!(sample_trf_with_history())

    {out, code} = run_capturing(fn -> CLI.run([path, "-p"]) end)

    assert code == 0
    assert out =~ "pairing round 2"
    # Round-1 winners A(1) and B(2) bracket together; round-1 losers C(3)
    # and D(4) bracket together — see sample_trf_with_history/0's doc.
    #
    # B(2) takes White on board 1, and this asserted the opposite until
    # 2026-08-17. Both A and B played White in round 1, so both hold a strong
    # preference for Black and their colour histories are identical: 5.2.1
    # cannot grant both, 5.2.2 cannot separate two equally strong
    # preferences, and 5.2.3 has no round in which one had White and the
    # other Black. C.04.3 5.2.4 decides — "grant the colour preference of the
    # higher ranked player" — so A(1) gets Black.
    #
    # `choose_colour/2` skipped 5.2.4 and fell through to 5.2.5's odd-TPN
    # rule, which handed A the initial colour instead. Confirmed against
    # bbpPairings on this exact position: it answers `2 1`.
    assert out =~ "2\r\n2 1\r\n3 4\r\n"
  end

  test "-p on a missing file exits 1 with a clear error" do
    {out, code} = run_capturing(fn -> CLI.run(["does-not-exist.trf", "-p"]) end)

    assert code == 1
    assert out =~ "could not read"
  end

  test "-p on an invalid TRF file exits 1 with the validation error" do
    path = write_trf!(illegal_result_trf())

    {out, code} = run_capturing(fn -> CLI.run([path, "-p"]) end)

    assert code == 1
    assert out =~ "invalid TRF file"
  end

  describe "-g (Random Tournament Generator)" do
    test "writes a parseable TRF that records its own seed" do
      path =
        Path.join(System.tmp_dir!(), "openpair-rtg-#{System.unique_integer([:positive])}.trf")

      on_exit(fn -> File.rm(path) end)

      {out, code} =
        run_capturing(fn ->
          CLI.run(["-g", path, "--seed=1234", "--players=14", "--rounds=5"])
        end)

      assert code == 0
      assert out =~ "seed 1234"

      parsed = Trf.parse(File.read!(path))
      assert length(parsed.players) == 14
      assert Enum.all?(parsed.players, &(length(&1.games) == 5))
      # The seed rides in the tournament name so the file alone reproduces
      # the run — see OpenPair.Generator's moduledoc on why not line one.
      assert parsed.tournament[:name] =~ "seed=1234"
    end

    test "the same seed generates the same tournament" do
      {first, 7} = OpenPair.Generator.generate(seed: 7, players: 12, rounds: 4)
      {second, 7} = OpenPair.Generator.generate(seed: 7, players: 12, rounds: 4)

      assert first == second
    end

    test "generated tournaments check clean against the checker, byes and forfeits included" do
      for opts <- [
            [seed: 1, players: 16, rounds: 6],
            [seed: 2, players: 13, rounds: 7, forfeit_pct: 12],
            [seed: 3, players: 18, rounds: 6, requested_bye_pct: 10],
            [seed: 4, players: 15, rounds: 7, forfeit_pct: 10, requested_bye_pct: 8]
          ] do
        {text, _seed} = OpenPair.Generator.generate(opts)
        path = write_trf!(text)

        {_out, code} = run_capturing(fn -> CLI.run([path, "-c", "-q"]) end)

        # The RTG pairs with this very engine, so its output is by
        # construction what the checker expects. A failure here means the
        # two modes disagree about the same rules — most likely in how a
        # round's pre-pairing state is reconstructed.
        assert code == 0, "generated tournament failed its own checker: #{inspect(opts)}"
      end
    end

    # The same round-trip, but now the file carries `XXP`/`XXA` lines. This
    # is a stronger test of those than it looks: `-c` reads the extension
    # lines back out of the generated file and hands them to the engine, so
    # a serializer and parser that disagree about `XXA`'s columns — the
    # exact mistake that makes real bbpPairings reject the sibling
    # project's own output — fails here rather than silently pairing an
    # unaccelerated tournament.
    test "generated tournaments carrying XXP and XXA also check clean" do
      for opts <- [
            [seed: 11, players: 16, rounds: 6, forbidden_pct: 15],
            [seed: 12, players: 16, rounds: 6, acceleration: :baku],
            [seed: 13, players: 14, rounds: 7, acceleration: :random],
            [
              seed: 14,
              players: 18,
              rounds: 6,
              forbidden_pct: 10,
              acceleration: :baku,
              requested_bye_pct: 8,
              forfeit_pct: 8
            ]
          ] do
        {text, _seed} = OpenPair.Generator.generate(opts)
        path = write_trf!(text)
        parsed = Trf.parse(text)

        if opts[:forbidden_pct],
          do: assert(parsed.tournament[:forbidden_pairs] not in [nil, []])

        if opts[:acceleration],
          do: assert(Enum.any?(parsed.players, &(&1[:accelerations] not in [nil, []])))

        {_out, code} = run_capturing(fn -> CLI.run([path, "-c", "-q"]) end)

        assert code == 0, "generated tournament failed its own checker: #{inspect(opts)}"
      end
    end

    test "rounds are capped so the field cannot run out of legal opponents" do
      {text, _seed} = OpenPair.Generator.generate(seed: 9, players: 6, rounds: 40)
      parsed = Trf.parse(text)

      assert Enum.all?(parsed.players, &(length(&1.games) <= 5))
    end
  end

  test "-q suppresses the step/detail trace on a successful round-1 pairing, but the pairing output still prints" do
    path = write_trf!(sample_trf())

    {out, code} = run_capturing(fn -> CLI.run([path, "-p", "-q"]) end)

    assert code == 0
    refute out =~ "Loading"
    refute out =~ "players,"
    assert out =~ "1\r\n1 2\r\n"
  end

  test "-q suppresses the step/detail trace on a later-round pairing too, but the output still prints" do
    path = write_trf!(sample_trf_with_history())

    {out, code} = run_capturing(fn -> CLI.run([path, "-p", "-q"]) end)

    assert code == 0
    refute out =~ "Loading"
    refute out =~ "players,"
    assert out =~ "2\r\n2 1\r\n3 4\r\n"
  end

  describe "-c (Pairings Checker)" do
    test "a tournament this engine paired itself checks clean" do
      path = write_trf(self_paired_tournament(4))
      {out, code} = run_capturing(fn -> CLI.run([path, "-c"]) end)

      assert code == 0
      assert out =~ "4/4 round(s) match"
      refute out =~ "DIFFERS"
    end

    test "a tampered pairing is reported, and the exit code is nonzero" do
      players = self_paired_tournament(4)

      # Swap two players' round-3 opponents so the recorded pairing is one
      # this engine would not have produced.
      [a, b | rest] = players
      ga = Enum.at(a.games, 2)
      gb = Enum.at(b.games, 2)

      tampered =
        [
          %{a | games: List.replace_at(a.games, 2, %{ga | opponent_rank: gb.opponent_rank})},
          %{b | games: List.replace_at(b.games, 2, %{gb | opponent_rank: ga.opponent_rank})}
        ] ++ rest

      path = write_trf(tampered)
      {out, code} = run_capturing(fn -> CLI.run([path, "-c"]) end)

      assert code == 1
      assert out =~ "round 3: DIFFERS"
    end

    test "a player holding an arbiter-assigned bye is left out of the replayed pairing" do
      # Five players, one of whom took a half-point bye in round 1: the
      # engine must pair the other four and not deal that player a game.
      players = self_paired_tournament(1, 5)

      [sitting | others] =
        Enum.map(players, fn p -> %{p | games: [], points: 0.0} end)

      sitting = %{
        sitting
        | points: 0.5,
          games: [%{opponent_rank: nil, colour: nil, result: "H"}]
      }

      path = write_trf([sitting | others])
      {out, code} = run_capturing(fn -> CLI.run([path, "-c"]) end)

      # Round 1 as recorded has nobody paired at all, so it differs — what
      # matters is that the engine never proposes a game for the player who
      # sat out.
      assert code == 1
      refute out =~ "engine: []"
      assert out =~ "engine:"
      refute out =~ "{#{sitting.rank},"
    end
  end

  # A small tournament paired entirely by this engine, so a checker run
  # over it should agree with itself on every round.
  defp self_paired_tournament(rounds, player_count \\ 8) do
    roster =
      for i <- 1..player_count do
        %{rank: i, name: "P#{i}", fide_rating: 2000 - i * 10, points: 0.0, games: []}
      end

    Enum.reduce(1..rounds, roster, fn _round, players ->
      pairs = OpenPair.Pairing.pair_next_round(players, expected_rounds: rounds)

      by_rank =
        Enum.reduce(pairs, %{}, fn
          {w, nil}, acc ->
            Map.put(acc, w, {%{opponent_rank: nil, colour: nil, result: "U"}, 1.0})

          {w, b}, acc ->
            acc
            |> Map.put(w, {%{opponent_rank: b, colour: "w", result: "1"}, 1.0})
            |> Map.put(b, {%{opponent_rank: w, colour: "b", result: "0"}, 0.0})
        end)

      Enum.map(players, fn p ->
        {game, points} = Map.fetch!(by_rank, p.rank)
        %{p | points: p.points + points, games: p.games ++ [game]}
      end)
    end)
  end

  defp write_trf(players) do
    text =
      OpenPair.Trf.serialize(%{
        tournament: %{name: "CheckerTest", type: "swiss"},
        players: players
      }) <> "XXR 9
"

    path =
      Path.join(System.tmp_dir!(), "openpair-check-#{System.unique_integer([:positive])}.trf")

    File.write!(path, text)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # OpenPair.Log writes step/detail to stdout and warn/error to stderr —
  # interleaving order doesn't matter for these assertions, so this just
  # concatenates both streams into one string, plus returns the CLI's own
  # return value (the would-be exit code).
  defp run_capturing(fun) do
    ref = make_ref()
    Process.put(ref, nil)

    stdout =
      capture_io(fn ->
        stderr = capture_io(:stderr, fn -> Process.put(ref, fun.()) end)
        IO.write(stderr)
      end)

    {stdout, Process.get(ref)}
  end
end
