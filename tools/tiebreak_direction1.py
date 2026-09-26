# VCL4THP Q33, direction 1: tournaments made by Ainalrami's generator
# (tools/tiebreak_corpus.exs), their tie-breaks and final ranks checked
# against FIDE's TieBreakServer. Direction 2 - TieBreakServer's generator -
# is tools/tiebreak_direction2.py; the two share the state and log format.
#
#     py -3 tools/tiebreak_direction1.py --batches 380 --size 100 --workers 2 \
#         --first-seed 1000000 --work DIR --state direction1_state.json
#
# Batch b covers seeds first_seed + b*size .. + size - 1. Resumable; a batch
# that agrees is deleted, one that does not is kept with compare.txt.
#
# --random-lists SEED: rank each tournament under its own random tie-break
# list (tools/tiebreak_random_list.exs) and compare the values of the codes
# in it, instead of the fixed list below. Earlier fixed-list runs used seeds
# from 1,000,000; the random-list run of 2026-09-25 used 2,000,000 on.
#
# Env: TBS_DIR (default ../TieBreakServer), TBS_PYTHON, and elixir on PATH.

import argparse, json, os, re, shutil, subprocess, sys, threading, time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PY = os.environ.get("TBS_PYTHON", sys.executable)
RANK = "BH/C1 BH SB DE"

SUMMARY = re.compile(r"files (\d+), skipped (\d+), values compared (\d+), mismatches (\d+), known differences (\d+)")
RANKS = re.compile(r"rankings compared (\d+), rank known (\d+)")
lock = threading.Lock()


def mix(args, env):
    return subprocess.run(["mix", "run"] + args, cwd=ROOT, capture_output=True, text=True, env=env,
                          shell=(os.name == "nt"), encoding="utf-8", errors="replace")


def run_batch(b, size, first_seed, work, random_lists=None):
    d = os.path.join(work, f"b{b:05d}")
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d, exist_ok=True)
    env = dict(os.environ, ELIXIR_ERL_OPTIONS="+S 1:1", TBS_PYTHON=PY)

    g = mix(["tools/tiebreak_corpus.exs", d, str(size), str(first_seed + b * size)], env)
    if g.returncode != 0:
        return {"batch": b, "error": "generator: " + (g.stdout + g.stderr)[-300:]}

    lists = ["--random-lists", str(random_lists)] if random_lists is not None else ["--rank", RANK]
    c = mix(["tools/tiebreak_compare.exs"] + lists + ["--dir", d], env)
    m = SUMMARY.search(c.stdout)
    if not m:
        return {"batch": b, "error": "compare: " + (c.stdout + c.stderr)[-300:]}

    files, skipped, values, bad, known = map(int, m.groups())
    result = {"batch": b, "files": files, "skipped": skipped, "values": values, "mismatches": bad, "known": known}
    r = RANKS.search(c.stdout)
    if r:
        result["rankings"], result["rank_known"] = map(int, r.groups())
    if bad == 0:
        shutil.rmtree(d, ignore_errors=True)
    else:
        with open(os.path.join(d, "compare.txt"), "w", encoding="utf-8") as f:
            f.write(c.stdout)
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--batches", type=int, default=380)
    ap.add_argument("--size", type=int, default=100)
    ap.add_argument("--workers", type=int, default=2)
    ap.add_argument("--first-seed", type=int, default=1_000_000)
    ap.add_argument("--work", required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--random-lists", type=int, default=None, metavar="SEED",
                    help="a random tie-break list per tournament, drawn from SEED")
    ap.add_argument("--strict", action="store_true",
                    help="exit 1 if any batch errored or disagreed (CI; see .github/workflows/tiebreak-check.yml)")
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
              f"rankings {sum(r.get('rankings', 0) for r in ok):,} (known {sum(r.get('rank_known', 0) for r in ok)})  "
              f"skipped {tot('skipped')}  errors {len(done) - len(ok)}", flush=True)

    with ThreadPoolExecutor(a.workers) as pool:
        for r in pool.map(lambda b: run_batch(b, a.size, a.first_seed, a.work, a.random_lists), todo):
            with lock:
                state["done"][str(r["batch"])] = r
                with open(a.state + ".tmp", "w") as f:
                    json.dump(state, f)
                os.replace(a.state + ".tmp", a.state)
                if "error" in r or r.get("mismatches"):
                    print("  ", json.dumps(r), flush=True)
                report()
    print(f"finished in {(time.time() - start) / 3600:.1f} h", flush=True)
    if a.strict:
        failed = [r for r in state["done"].values() if "error" in r or r.get("mismatches")]
        for r in failed:
            print("FAILED batch", json.dumps(r), flush=True)
        if failed:
            sys.exit(1)


if __name__ == "__main__":
    main()
