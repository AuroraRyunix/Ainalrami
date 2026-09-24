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
# Env: TBS_DIR (default ../TieBreakServer), TBS_PYTHON, and elixir on PATH.

import argparse, json, os, re, shutil, subprocess, sys, threading, time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PY = os.environ.get("TBS_PYTHON", sys.executable)
RANK = "BH/C1 BH SB DE"

SUMMARY = re.compile(r"files (\d+), skipped (\d+), values compared (\d+), mismatches (\d+), known differences (\d+)")
lock = threading.Lock()


def mix(args, env):
    return subprocess.run(["mix", "run"] + args, cwd=ROOT, capture_output=True, text=True, env=env,
                          shell=(os.name == "nt"), encoding="utf-8", errors="replace")


def run_batch(b, size, first_seed, work):
    d = os.path.join(work, f"b{b:05d}")
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d, exist_ok=True)
    env = dict(os.environ, ELIXIR_ERL_OPTIONS="+S 1:1", TBS_PYTHON=PY)

    g = mix(["tools/tiebreak_corpus.exs", d, str(size), str(first_seed + b * size)], env)
    if g.returncode != 0:
        return {"batch": b, "error": "generator: " + (g.stdout + g.stderr)[-300:]}

    c = mix(["tools/tiebreak_compare.exs", "--rank", RANK, "--dir", d], env)
    m = SUMMARY.search(c.stdout)
    if not m:
        return {"batch": b, "error": "compare: " + (c.stdout + c.stderr)[-300:]}

    files, skipped, values, bad, known = map(int, m.groups())
    result = {"batch": b, "files": files, "skipped": skipped, "values": values, "mismatches": bad, "known": known}
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
        for r in pool.map(lambda b: run_batch(b, a.size, a.first_seed, a.work), todo):
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
