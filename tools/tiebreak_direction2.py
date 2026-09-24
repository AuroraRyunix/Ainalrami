# VCL4THP Q33, direction 2: tournaments made by FIDE's own generator
# (TieBreakServer's tournamentgenerator.py), their tie-breaks and final ranks
# computed by Ainalrami and checked against TieBreakServer's tiebreakchecker.
# Direction 1 - Ainalrami's generator - is tools/tiebreak_corpus.exs.
#
#     py -3 tools/tiebreak_direction2.py --batches 500 --size 100 --workers 2 \
#         --work DIR --state direction2_state.json
#
# Batch b uses setup b % len(SETUPS) and seeds b*size .. (b+1)*size-1 (the
# generator seeds from the file number), so every tournament is distinct and
# a rerun of a batch is the same batch. Resumable: finished batches are in the
# state file. A batch that agrees is deleted; one that does not is kept.
#
# Env: TBS_DIR (default ../TieBreakServer), TBS_PYTHON, and elixir on PATH.

import argparse, json, os, re, shutil, subprocess, sys, threading, time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TBS = os.environ.get("TBS_DIR", os.path.join(ROOT, "..", "TieBreakServer"))
PY = os.environ.get("TBS_PYTHON", sys.executable)

SWISS_RANK = "BH/C1 BH SB DE"
RR_CODES = "PTS SB SB/C1 KS KS/L1 PS WIN WON BPG BWG REP STD ARO/U1000 TPR/U1000 PTP/U1000"
RR_RANK = "DE SB KS"

# (name, generator args, compare args)
SETUPS = [
    ("swiss40x9", ["-p", "40", "-N", "9"], ["--rank", SWISS_RANK]),
    ("swiss16x7", ["-p", "16", "-N", "7"], ["--rank", SWISS_RANK]),
    ("swiss100x11", ["-p", "100", "-N", "11"], ["--rank", SWISS_RANK]),
    ("swiss64x9-unplayed", ["-p", "64", "-N", "9", "-S", "0.03", "0.10", "0.08"], ["--rank", SWISS_RANK]),
    # No accelerated setup: TieBreakServer 1.9.57's generator raises KeyError
    # 'gamePoints' in get_accelerated with -a, before any file is written.
    ("rr10", ["-p", "10", "-N", "9", "-m", "berger"], ["--rr", "--codes", RR_CODES, "--rank", RR_RANK]),
    ("rr9", ["-p", "9", "-N", "9", "-m", "berger"], ["--rr", "--codes", RR_CODES, "--rank", RR_RANK]),
]

SUMMARY = re.compile(r"files (\d+), skipped (\d+), values compared (\d+), mismatches (\d+), known differences (\d+)")
lock = threading.Lock()


def run_batch(b, size, work):
    name, gen_args, cmp_args = SETUPS[b % len(SETUPS)]
    d = os.path.join(work, f"b{b:05d}-{name}")
    shutil.rmtree(d, ignore_errors=True)
    first = b * size
    gen = [PY, os.path.join(TBS, "tournamentgenerator.py"), "-g", str(first), str(size)] + gen_args + \
          ["-F", "TRF", "-o", os.path.join(d, "t%d.trf")]
    g = subprocess.run(gen, cwd=TBS, capture_output=True, text=True)
    if g.returncode != 0:
        return {"batch": b, "setup": name, "error": "generator: " + (g.stdout + g.stderr)[-300:]}

    env = dict(os.environ, ELIXIR_ERL_OPTIONS="+S 1:1", TBS_PYTHON=PY)
    cmd = ["mix", "run", "tools/tiebreak_compare.exs"] + cmp_args + ["--dir", d]
    c = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, env=env, shell=(os.name == "nt"),
                       encoding="utf-8", errors="replace")
    m = SUMMARY.search(c.stdout)
    if not m:
        return {"batch": b, "setup": name, "error": "compare: " + (c.stdout + c.stderr)[-300:]}

    files, skipped, values, bad, known = map(int, m.groups())
    result = {"batch": b, "setup": name, "files": files, "skipped": skipped, "values": values,
              "mismatches": bad, "known": known}
    if bad == 0 and skipped == 0:
        shutil.rmtree(d, ignore_errors=True)
    else:
        with open(os.path.join(d, "compare.txt"), "w", encoding="utf-8") as f:
            f.write(c.stdout)
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--batches", type=int, default=500)
    ap.add_argument("--size", type=int, default=100)
    ap.add_argument("--workers", type=int, default=2)
    ap.add_argument("--work", required=True)
    ap.add_argument("--state", required=True)
    a = ap.parse_args()

    state = {"done": {}}
    if os.path.exists(a.state):
        state = json.load(open(a.state))
    todo = [b for b in range(a.batches) if str(b) not in state["done"]]
    os.makedirs(a.work, exist_ok=True)
    start = time.time()

    def report():
        done = state["done"].values()
        ok = [r for r in done if "error" not in r]
        tot = lambda k: sum(r[k] for r in ok)
        print(f"{time.strftime('%H:%M:%S')}  batches {len(done)}/{a.batches}  tournaments {tot('files'):,}  "
              f"values {tot('values'):,}  mismatches {tot('mismatches')}  known {tot('known')}  "
              f"skipped {tot('skipped')}  errors {len(done) - len(ok)}", flush=True)

    with ThreadPoolExecutor(a.workers) as pool:
        for r in pool.map(lambda b: run_batch(b, a.size, a.work), todo):
            with lock:
                state["done"][str(r["batch"])] = r
                with open(a.state + ".tmp", "w") as f:
                    json.dump(state, f)
                os.replace(a.state + ".tmp", a.state)
                if "error" in r or r.get("mismatches"):
                    print("  ", json.dumps(r), flush=True)
                report()
    print(f"finished in {(time.time() - start) / 3600:.1f} h", flush=True)


if __name__ == "__main__":
    main()
