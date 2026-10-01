# The timing study (docs/performance.md, "The timing study"): many random
# positions, three engines, the same machine, every answer compared.
#
#   MIX_ENV=test GACRUX_DIR=/path/to/TieBreakServer \
#     BBPPAIRINGS=/path/to/bbpPairings.exe BENCH_W=0 BENCH_N=32 \
#     BENCH_OUT=/tmp/timing elixir --erl "+S 1" -S mix run tools/timing_study.exs
#
# Run BENCH_N workers (BENCH_W = 0..N-1) side by side; each appends to
# BENCH_OUT/w<W>.csv and resumes where it stopped. The 2026-09-30 run's
# lines, all workers merged, are docs/timing-study-2026-09-30.csv. Needs a
# Unix-like host (`timeout`, `python3`).
#
# Worker W of N (env BENCH_W, BENCH_N) takes jobs with index rem N == W.
# Each engine runs single-threaded (+S 1 BEAM; bbp and Gacrux are single-threaded).
# Times: Ainalrami in-process, second of two calls (first warms code loading); bbp and Gacrux wall time minus a startup baseline.
# Output CSV: n,round,seed,ain_s,gac_s,bbp_s,gac_same,bbp_same,gac_status
import Ainalrami.Test.FuzzTournament
alias Ainalrami.Pairing

w = String.to_integer(System.get_env("BENCH_W", "0"))
nw = String.to_integer(System.get_env("BENCH_N", "1"))
seeds = String.to_integer(System.get_env("BENCH_SEEDS", "100"))
out = System.get_env("BENCH_OUT", "tmp/timing_study") |> Path.join("w#{w}.csv")
gac_dir = System.get_env("GACRUX_DIR")
bbp = System.get_env("BBPPAIRINGS", "bbpPairings.exe")

pair = fn ps, rounds, forbidden ->
  Pairing.pair_next_round(ps,
    expected_rounds: rounds,
    forbidden_pairs: forbidden,
    initial_colour: String.downcase(initial_colour()),
    point_system: point_system()
  )
end

parse = fn text ->
  text
  |> String.split("\n", trim: true)
  |> Enum.drop(1)
  |> Enum.flat_map(fn l ->
    case String.split(l) do
      [a, b] -> [{String.to_integer(a), if(b == "0", do: nil, else: String.to_integer(b))}]
      _ -> []
    end
  end)
end

ext = fn cmd, args, dir ->
  t0 = System.monotonic_time(:microsecond)
  {_, code} = System.cmd("timeout", ["900", cmd | args], stderr_to_stdout: true, cd: dir)
  t = (System.monotonic_time(:microsecond) - t0) / 1.0e6

  text =
    case File.read(Path.join(dir, "out.txt")) do
      {:ok, s} -> s
      _ -> ""
    end

  {t, code, text}
end

run_engine = fn which, trf ->
  dir = Path.join(System.tmp_dir!(), "bm_#{w}_#{System.unique_integer([:positive])}")
  File.mkdir_p!(dir)
  File.write!(Path.join(dir, "in.trf"), trf)

  r =
    case which do
      :gac ->
        ext.(
          "python3",
          [
            Path.join(gac_dir, "pairingchecker.py"),
            "-i",
            "in.trf",
            "-o",
            "out.txt",
            "-p",
            "-dT",
            "-m",
            "dutch"
          ],
          dir
        )

      :bbp ->
        ext.(bbp, ["--dutch", "in.trf", "-p", "out.txt"], dir)
    end

  File.rm_rf!(dir)
  r
end

position = fn n, target, seed ->
  {rounds, pc, forbidden, roster} = begin!(seed, 9, n..n)

  ps =
    Enum.reduce(1..(target - 1)//1, roster, fn round, ps ->
      withdraw_some(round, pc)
      ps = assign_requested_byes(ps)
      p = pair.(ps, rounds, forbidden)
      apply_round(ps, p, simulate_results(p))
    end)

  withdraw_some(target, pc)
  ps = assign_requested_byes(ps)
  {ps, rounds, forbidden, build_trf(ps, rounds, forbidden)}
end

median = fn xs -> Enum.at(Enum.sort(xs), div(length(xs), 2)) end
{_, _, _, trf0} = position.(4, 1, 1)
gbase = median.(for _ <- 1..5, do: elem(run_engine.(:gac, trf0), 0))
bbase = median.(for _ <- 1..5, do: elem(run_engine.(:bbp, trf0), 0))

sizes = [100, 101, 200, 201, 400, 401, 600, 601, 1000, 1001]
jobs = for s <- 1..seeds, n <- sizes, r <- [2, 5, 9], do: {n, r, 8_000_000 + s * 10_000 + n}
File.mkdir_p!(Path.dirname(out))

done =
  case File.read(out) do
    {:ok, s} ->
      s
      |> String.split("\n", trim: true)
      |> Enum.map(fn l -> Enum.take(String.split(l, ","), 3) |> Enum.join(",") end)
      |> MapSet.new()

    _ ->
      MapSet.new()
  end

jobs
|> Enum.with_index()
|> Enum.filter(fn {_, i} -> rem(i, nw) == w end)
|> Enum.each(fn {{n, r, seed}, _} ->
  unless MapSet.member?(done, "#{n},#{r},#{seed}") do
    {ps, rounds, forbidden, trf} = position.(n, r, seed)
    _ = pair.(ps, rounds, forbidden)
    {us, ours} = :timer.tc(fn -> pair.(ps, rounds, forbidden) end)
    {gt, gcode, gtext} = run_engine.(:gac, trf)
    {bt, _bcode, btext} = run_engine.(:bbp, trf)

    status =
      cond do
        gcode == 124 -> "timeout"
        String.contains?(gtext, "Error") -> "error"
        gcode != 0 -> "exit#{gcode}"
        true -> "ok"
      end

    ours_n = normalize(ours)

    line =
      Enum.join(
        [
          n,
          r,
          seed,
          Float.round(us / 1.0e6, 4),
          Float.round(gt - gbase, 4),
          Float.round(bt - bbase, 4),
          ours_n == normalize(parse.(gtext)),
          ours_n == normalize(parse.(btext)),
          status
        ],
        ","
      )

    File.write!(out, line <> "\n", [:append])
  end
end)

File.write!(out <> ".done", "")
