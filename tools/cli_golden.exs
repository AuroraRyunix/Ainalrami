# Everything the CLI prints for a fixed corpus, with only the flags it had
# before the `XXO` records and the parity flags - to compare two checkouts.
#
#     GOLDEN_OUT=/tmp/a.txt mix run tools/cli_golden.exs     # in checkout A
#     GOLDEN_OUT=/tmp/b.txt mix run tools/cli_golden.exs     # in checkout B
#     cmp /tmp/a.txt /tmp/b.txt
#
# The claim it checks is "an option that is absent changes nothing": stdout,
# stderr, the exit code and the file written, for -p, -x, -c and -g on
# generated Swiss, team and round-robin events (GOLDEN_SEEDS of them,
# default 150 - 2,747 runs). Run from the checkout's root both times: the
# input paths are printed, so they have to be the same paths. It uses only
# library calls the older checkout has. A usage error prints the help,
# which is allowed to change, so the corpus is built to make none.
alias Ainalrami.{CLI, Generator, TeamGenerator, RoundRobinGenerator, Trf, EventFormat}
import ExUnit.CaptureIO

ExUnit.start(autorun: false)
out_path = System.fetch_env!("GOLDEN_OUT")
File.rm_rf!("cli_golden_tmp")
File.mkdir_p!("cli_golden_tmp")

run = fn args ->
  ref = make_ref()

  out =
    capture_io(fn ->
      err = capture_io(:stderr, fn -> Process.put({ref, :c}, CLI.run(args)) end)
      Process.put({ref, :e}, err)
    end)

  file =
    case Enum.find(args, &String.ends_with?(&1, ".out")) do
      nil -> ""
      path -> if File.exists?(path), do: File.read!(path), else: "<none>"
    end

  ["$ ", Enum.join(args, " "), "\n", out, "\n--stderr--\n", Process.get({ref, :e}), "\n--exit ",
   to_string(Process.get({ref, :c})), "\n--file--\n", file, "\n"]
end

cut = fn parsed, k ->
  players = EventFormat.before_round(parsed.players, k, parsed.tournament[:point_system])
  tournament = Map.drop(parsed.tournament, [:tie_breaks, :standings_order, :byes])
  %{parsed | players: Enum.map(players, &Map.put(&1, :final_rank, nil)), tournament: tournament}
end

seeds = String.to_integer(System.get_env("GOLDEN_SEEDS") || "150")

individual =
  for seed <- 1..seeds do
    players = if rem(seed, 2) == 1, do: 5 + rem(seed * 7, 12), else: 17 + rem(seed * 11, 44)

    {text, _} =
      Generator.generate(
        seed: seed,
        players: players,
        rounds: 3 + rem(seed, 5),
        forfeit_pct: rem(seed, 3) * 4,
        requested_bye_pct: rem(seed, 4) * 3,
        forbidden_pct: if(rem(seed, 5) == 0, do: 10, else: 0),
        acceleration: if(rem(seed, 7) == 0, do: :baku),
        tie_breaks: if(rem(seed, 6) == 0, do: ["BH", "SB"]),
        unset: if(rem(seed, 9) == 0, do: :random, else: :fixed)
      )

    full_path = "cli_golden_tmp/full#{seed}.trf"
    File.write!(full_path, text)
    full = Trf.parse(text)
    played = full.players |> Enum.map(&length(&1.games)) |> Enum.max(fn -> 0 end)
    k = 1 + rem(seed * 13, played + 1)
    path = "cli_golden_tmp/s#{seed}.trf"
    File.write!(path, Trf.serialize(cut.(full, k)))
    a = 1 + rem(seed, players)
    b = 1 + rem(seed * 3 + 1, players)
    half = div(players, 2)

    [
      run.([full_path, "-c"]),
      run.([path, "-p"]),
      run.([path, "-p", "cli_golden_tmp/s#{seed}.out", "-q"]),
      run.([path, "-x"]),
      run.([path, "-p", "-q", "--bye-want=#{a}", "--bye-avoid-soft=#{b}@#{k}-#{k + 1}"]),
      run.([path, "-x", "-q", "--bye-avoid=#{a}", "--bye-want-soft=#{b}"]),
      run.([path, "-p", "-q", "--soft-pairs=#{a},#{rem(a, players) + 1}/1,2,3", "--soft-position=weak"]),
      run.([path, "-x", "-q", "--soft-pairs=1,2"]),
      run.([path, "-p", "-q", "--groups=1-#{half}"]),
      run.([path, "-x", "-q", "--groups=1-#{half}/#{half + 1}-#{players}"]),
      run.([path, "-p", "-q", "--match-format"]),
      run.([full_path, "-c", "-q", "--match-format"]),
      if(a != b, do: run.([path, "-x", "-q", "--force=#{a}-#{b}", "--absent=#{a}"]), else: []),
      # Flags that -p used to accept and ignore, kept out: --rounds,
      # --initial-colour, --acceleration and --tie-breaks now mean something.
      run.(["-g", "cli_golden_tmp/gen#{seed}.out", "--seed=#{seed}", "--players=#{players}", "--rounds=4"]),
      run.(["-g", "cli_golden_tmp/genu#{seed}.out", "--seed=#{seed}", "--unset=fixed", "--acceleration=baku",
            "--initial-colour=b", "--tie-breaks=BH,SB"])
    ]
  end

teams =
  for seed <- 1..div(seeds, 3) do
    {text, _} = TeamGenerator.generate(system: :swiss, seed: seed, teams: 5 + rem(seed * 3, 9), rounds: 5)
    path = "cli_golden_tmp/t#{seed}.trf"
    File.write!(path, text)
    {rr, _} = TeamGenerator.generate(system: :round_robin, seed: seed, teams: 4 + rem(seed, 5))
    rr_path = "cli_golden_tmp/tr#{seed}.trf"
    File.write!(rr_path, rr)
    {irr, _} = RoundRobinGenerator.generate(seed: seed, players: 4 + rem(seed, 9), rounds: 2)
    irr_path = "cli_golden_tmp/rr#{seed}.trf"
    File.write!(irr_path, irr)

    [
      run.([path, "-c"]),
      run.([path, "-p"]),
      run.([path, "-p", "--lineups", "-q"]),
      run.([path, "-x", "-q"]),
      run.([rr_path, "-c"]),
      run.([rr_path, "-p", "-q"]),
      run.([irr_path, "-c"]),
      run.([irr_path, "-p"]),
      run.([irr_path, "-x", "-q"]),
      run.(["-g", "cli_golden_tmp/tg#{seed}.out", "--team=swiss", "--seed=#{seed}", "--teams=8", "--team-type=b",
            "--score=gp", "--secondary=no", "--initial-colour=black"])
    ]
  end

File.write!(out_path, IO.iodata_to_binary([individual, teams, run.(["--version"])]))
File.rm_rf!("cli_golden_tmp")
IO.puts("wrote #{byte_size(File.read!(out_path))} bytes to #{out_path}")
