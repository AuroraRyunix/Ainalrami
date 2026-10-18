defmodule Ainalrami.CLIParity3Test do
  @moduledoc """
  The last three things OpenPairings could tell the engine and the command
  line could not:

    * `max_candidates:` - OpenPairings asks for `:all` when the arbiter
      wants the whole bracket worked out; `-x --max-candidates=N|all`;
    * a `?` result's value - `162`'s `X` in a file, and now
      `--points=unknown:V`;
    * the TRF26 dialect for the Swiss generator - `-g --dialect=trf26`,
      `Generator.generate/1`'s `:dialect`.

  Each is held to the library's answer for the same input, or, for the
  dialect, to the same tournament in the other spelling.
  """
  # Not async: `capture_io(:stderr, ...)` is VM-wide.
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Ainalrami.{Alternatives, CLI, EventFormat, Generator, Pairing, Trf}

  defp tmp(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ainalrami_parity3_#{System.unique_integer([:positive])}_#{name}"
      )

    on_exit(fn -> File.rm(path) end)
    path
  end

  defp write(text, name \\ "in.trf") do
    path = tmp(name)
    File.write!(path, text)
    path
  end

  defp cli(args) do
    ref = make_ref()
    err = make_ref()

    out =
      capture_io(fn ->
        stderr = capture_io(:stderr, fn -> Process.put(ref, CLI.run(args)) end)
        Process.put(err, stderr)
      end)

    {out, Process.get(ref), Process.get(err)}
  end

  defp pairs_of(output) do
    [_count | lines] = String.split(output, "\r\n", trim: true)

    Enum.map(lines, fn line ->
      [a, b] = line |> String.split() |> Enum.map(&String.to_integer/1)
      {a, if(b == 0, do: nil, else: b)}
    end)
  end

  # ---- --max-candidates ------------------------------------------------------

  describe "-x --max-candidates" do
    # A field after one round whose bye bracket is past the default cap,
    # paired the way the CLI pairs it (`--rounds=7` over the file's 1).
    setup do
      {path, players, pairs, capped} =
        Enum.find_value(1..40, fn seed ->
          {text, _} = Generator.generate(seed: seed, players: 33, rounds: 1)
          parsed = Trf.parse(text)
          opts = [expected_rounds: 7, initial_colour: parsed.tournament[:initial_colour]]
          pairs = Pairing.pair_next_round(parsed.players, opts)

          case Alternatives.bye_alternatives(parsed.players, pairs, opts) do
            %{skipped: :too_many, count: count} ->
              {write(text), parsed.players, {pairs, opts}, count}

            _ ->
              nil
          end
        end)

      {pairs, opts} = pairs
      %{path: path, players: players, pairs: pairs, opts: opts, capped: capped}
    end

    test "all works out the bracket the default cap leaves, candidate for candidate", ctx do
      {out, 0, _} = cli([ctx.path, "-x", "-q", "--rounds=7", "--bye-alternatives"])
      assert out =~ "  not worked out: #{ctx.capped} candidates"

      {out, 0, _} =
        cli([ctx.path, "-x", "-q", "--rounds=7", "--bye-alternatives", "--max-candidates=all"])

      refute out =~ "not worked out"

      result =
        Alternatives.bye_alternatives(
          ctx.players,
          ctx.pairs,
          Keyword.put(ctx.opts, :max_candidates, :all)
        )

      assert length(result.candidates) == ctx.capped

      for %{rank: rank} <- result.candidates do
        assert out =~ ~r/^  #{rank}: /m
      end

      # A number is the same cap moved: exactly the count works it out, one
      # short does not.
      {exact, 0, _} =
        cli([
          ctx.path,
          "-x",
          "-q",
          "--rounds=7",
          "--bye-alternatives",
          "--max-candidates=#{ctx.capped}"
        ])

      assert exact == out

      {short, 0, _} =
        cli([
          ctx.path,
          "-x",
          "-q",
          "--rounds=7",
          "--bye-alternatives",
          "--max-candidates=#{ctx.capped - 1}"
        ])

      assert short =~ "  not worked out: #{ctx.capped} candidates"
    end

    test "float alternatives take the same cap", ctx do
      {out, 0, _} =
        cli([ctx.path, "-x", "-q", "--rounds=7", "--float-alternatives", "--max-candidates=0"])

      floats =
        Alternatives.float_alternatives(
          ctx.players,
          ctx.pairs,
          Keyword.put(ctx.opts, :max_candidates, 0)
        )

      for %{skipped: :too_many, count: count} <- floats do
        assert out =~ "  not worked out: #{count} candidates"
      end
    end

    test "is refused without a question to cap, outside -x, and with a bad value", ctx do
      {_, 1, err} = cli([ctx.path, "-x", "--rounds=7", "--max-candidates=all"])
      assert err =~ "--max-candidates caps --bye-alternatives or --float-alternatives"

      {_, 1, err} = cli([ctx.path, "-p", "--max-candidates=all"])
      assert err =~ "--max-candidates is for -x, not -p"

      {_, 1, err} = cli([ctx.path, "-x", "--bye-alternatives", "--max-candidates=lots"])
      assert err =~ "--max-candidates takes a whole number or all"
    end
  end

  # ---- --points=unknown: ------------------------------------------------------

  describe "--points=unknown:V" do
    # Twelve players who played four rounds, and two more who met once, lost
    # the result (`?`) and have been absent since: the round can be paired,
    # and the two scores depend on what `?` is worth.
    defp unknown_files do
      {text, _} = Generator.generate(seed: 4242, players: 12, rounds: 4)
      parsed = Trf.parse(text)
      bye = %{opponent_rank: nil, colour: nil, result: "Z"}

      lost =
        for {rank, opponent, colour} <- [{13, 14, "w"}, {14, 13, "b"}] do
          %{
            rank: rank,
            name: "Lost#{rank}",
            sex: "",
            title: "",
            federation: "",
            fide_rating: 1500,
            fide_number: nil,
            birth_date: "",
            points: 0.5,
            # Written as a draw, then turned into `?` below: the writer
            # refuses `?` by design.
            games: [
              %{opponent_rank: opponent, colour: colour, result: "="} | List.duplicate(bye, 4)
            ]
          }
        end

      data = %{
        tournament: Map.put(parsed.tournament, :number_of_rounds, 9),
        players: parsed.players ++ lost
      }

      with_x =
        put_in(
          data.tournament[:point_system],
          Map.put(Trf.default_point_system(), :unknown, 0.5)
        )

      {unknown(Trf.serialize(data, dialect: :trf26)),
       unknown(Trf.serialize(with_x, dialect: :trf26))}
    end

    # Round 1's result for ranks 13 and 14, in column 99.
    defp unknown(text) do
      text
      |> String.split("\r\n")
      |> Enum.map_join("\r\n", fn
        "001   1" <> rank_rest = line when binary_part(rank_rest, 0, 1) in ["3", "4"] ->
          <<head::binary-size(98), _::binary-size(1), rest::binary>> = line
          head <> "?" <> rest

        other ->
          other
      end)
    end

    test "is the file's 162 X: the same pairing as the library with :unknown" do
      {plain, declared} = unknown_files()
      assert plain =~ ~r/^001   13 .* 0\.5 .*  14 w \?/m
      assert declared =~ ~r/^162 .*X 0\.5/m
      plain_path = write(plain, "plain.trf")
      declared_path = write(declared, "declared.trf")

      {flag_out, 0, _} = cli([plain_path, "-p", "-q", "--points=unknown:0.5"])
      {file_out, 0, _} = cli([declared_path, "-p", "-q"])
      assert flag_out == file_out

      parsed = Trf.parse(declared)

      library =
        Pairing.pair_next_round(parsed.players,
          expected_rounds: 9,
          initial_colour: parsed.tournament[:initial_colour],
          point_system: parsed.tournament[:point_system]
        )

      assert Enum.sort(pairs_of(flag_out)) == Enum.sort(library)
    end

    test "-s scores the ? the flag values, as it scores the file's X" do
      {plain, declared} = unknown_files()
      plain_path = write(plain, "plain.trf")
      declared_path = write(declared, "declared.trf")

      {flag_out, 0, _} = cli([plain_path, "-s", "-q", "--tie-breaks=BH", "--points=unknown:0.5"])
      {file_out, 0, _} = cli([declared_path, "-s", "-q", "--tie-breaks=BH"])
      assert flag_out == file_out

      # Without a value anywhere, TRF-2026's default: a draw, so the same
      # table. A value of nought is a different one.
      {default_out, 0, _} = cli([plain_path, "-s", "-q", "--tie-breaks=BH"])
      assert default_out == file_out

      {nought_out, 0, _} = cli([plain_path, "-s", "-q", "--tie-breaks=BH", "--points=unknown:0"])
      refute nought_out == file_out
    end
  end

  # ---- -g --dialect -----------------------------------------------------------

  describe "-g --dialect=trf26" do
    @shapes [
      [players: 15, rounds: 6, acceleration: :baku, forbidden_pct: 20, requested_bye_pct: 10],
      [players: 24, rounds: 7, forfeit_pct: 8, tie_breaks: ["BH/C1", "BH", "SB"]],
      [players: 9, rounds: 5, requested_bye_pct: 15, forbidden_pct: 10],
      [players: 30, rounds: 5, acceleration: :random, half_bye_pct: 5, full_bye_pct: 3]
    ]

    test "one seed is one tournament in either spelling, and -c passes the TRF26 one" do
      for {shape, i} <- Enum.with_index(@shapes, 1), seed <- [11 * i, 101 * i] do
        opts = [{:seed, seed} | shape]
        {engine, ^seed} = Generator.generate(opts)
        {trf26, ^seed} = Generator.generate([{:dialect, :trf26} | opts])

        # The default is the engine spelling, to the byte.
        assert {^engine, _} = Generator.generate([{:dialect, :engine} | opts])
        assert engine =~ "XXR "
        refute trf26 =~ "XXR "
        refute trf26 =~ ~r/^XX[APC]/m

        e = Trf.parse(engine)
        t = Trf.parse(trf26)
        assert strip(e.players) == strip(t.players)
        assert e.tournament[:number_of_rounds] == t.tournament[:number_of_rounds]
        assert e.tournament[:initial_colour] == t.tournament[:initial_colour]

        assert Enum.sort(e.tournament[:forbidden_pairs] || []) ==
                 Enum.sort(Enum.map(t.tournament[:forbidden_pairs] || [], &group/1))

        path = write(trf26)
        {out, code, err} = cli([path, "-c"])
        assert code == 0, out <> err

        # Every round, paired again from each spelling, is the same round.
        played = Trf.rounds_played(e.players)

        for k <- 1..played//1 do
          assert pair_before(e, k) == pair_before(t, k)
        end
      end
    end

    test "the command line writes what the library writes" do
      out = tmp("g.trf")

      {_, 0, _} =
        cli([
          "-g",
          out,
          "-q",
          "--seed=77",
          "--players=14",
          "--rounds=5",
          "--unset=fixed",
          "--dialect=trf26"
        ])

      {expected, 77} = Generator.generate(seed: 77, players: 14, rounds: 5, dialect: :trf26)
      assert File.read!(out) == expected
    end

    test "is refused where there is nothing to choose" do
      {_, 1, err} = cli(["-g", "--dialect=trf16"])
      assert err =~ "unknown --dialect \"trf16\" - engine or trf26"

      {_, 1, err} = cli(["-g", "--team=swiss", "--dialect=trf26"])
      assert err =~ "a team event is always written as TRF26"

      {_, 1, err} = cli(["-g", "--roundrobin", "--dialect=engine"])
      assert err =~ "a round robin is always written as TRF26"

      path = write(elem(Generator.generate(seed: 3, players: 8, rounds: 2), 0))
      {_, 1, err} = cli([path, "-p", "--dialect=trf26"])
      assert err =~ "--dialect is for -g, not -p"
    end

    test "the library refuses a dialect it does not have" do
      assert_raise ArgumentError, ~r/:dialect must be :engine or :trf26/, fn ->
        Generator.generate(seed: 1, players: 6, rounds: 1, dialect: :trf16)
      end
    end
  end

  # The engine spelling writes Baku's or a random table's zeros out to the
  # last round (`XXA`); TRF26's `250` stops at the last round that has a
  # point. The same table either way.
  defp strip(players) do
    Enum.map(players, fn p ->
      case p[:accelerations] do
        nil ->
          p

        values ->
          trimmed = values |> Enum.reverse() |> Enum.drop_while(&(&1 == 0.0)) |> Enum.reverse()
          Map.put(p, :accelerations, trimmed)
      end
    end)
  end

  # A `260` that covers every round is an `XXP` group.
  defp group({ranks, _first, _last}), do: ranks
  defp group(ranks), do: ranks

  defp pair_before(parsed, k) do
    players = EventFormat.before_round(parsed.players, k, parsed.tournament[:point_system])

    Pairing.pair_next_round(players,
      expected_rounds: parsed.tournament[:number_of_rounds],
      initial_colour: parsed.tournament[:initial_colour],
      forbidden_pairs: parsed.tournament[:forbidden_pairs],
      point_system: parsed.tournament[:point_system]
    )
  rescue
    Pairing.NoValidPairingError -> :no_pairing
  end
end
