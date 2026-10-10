"""The long C.04.6 large-field run: 100-200 team rounds against the exact reference.

Runs `test/ainalrami/team_proof_xl_test.exs --only whole_rounds_xl` many times
at once, each copy on its own seed range (TEAM_XL_SEEDS) and its own core
(`+S 1:1`), at below-normal priority. What the run proves is written up in
`docs/team-proof-large-fields.md`, section "100-200 teams".

Resumable: every finished chunk is recorded in the state file, and a restart
with the same command skips them. A disagreement does not stop anything: the
test writes the full reproducer (seed, field, options, engine round, reference
round) into the failures directory, the seed is counted in the state file, and
the chunk carries on with the next seed.

    py -3 -u tools/team_large_run.py --first 1 --last 14000 --workers 6

Stop it by creating the file named by --stop (default `STOP` next to the
state file): no new chunk starts, the running ones finish. Run it from its own
worktree so compiling elsewhere cannot change the code under it.
"""

import argparse
import collections
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time

BELOW_NORMAL_PRIORITY_CLASS = 0x00004000
MAX_WORKERS = 6
SUMMARY = re.compile(
    r"TEAMXL seeds=(\d+) rounds=(\d+) failures=(\d+) teams=(\d+) byes=(\d+) ref_ms=(\d+) "
    r"engine_ms=(\d+) checker_ms=(\d+) brackets_checked=(\d+) brackets_skipped=(\d+)"
)
FAIL = re.compile(r"TEAMXL-FAIL seed=(\d+) round=(\d+) teams=(\d+) file=(.+)$", re.M)
TOTALS = ["seeds", "rounds", "teams", "byes", "ref_ms", "engine_ms", "checker_ms",
          "brackets_checked", "brackets_skipped"]


def parse_args():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--first", type=int, default=1)
    p.add_argument("--last", type=int, required=True)
    p.add_argument("--chunk", type=int, default=6)
    p.add_argument("--workers", type=int, default=6)
    p.add_argument("--sizes", default="100..200")
    p.add_argument("--check-max", type=int, default=64)
    p.add_argument("--state", default="team_large_state.json")
    p.add_argument("--failures", default="failures")
    p.add_argument("--stop", default=None)
    p.add_argument("--repo", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    args = p.parse_args()
    if not 1 <= args.workers <= MAX_WORKERS:
        sys.exit(f"--workers must be 1..{MAX_WORKERS}: this PC is shared")
    return args


def load_state(path):
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    state = {"done": [], "failures": [], "errors": []}
    state.update({k: 0 for k in TOTALS})
    return state


def save_state(path, state):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=1)
    os.replace(tmp, path)


def todo(first, last, chunk, spans):
    """The chunks of [first, last] no finished range already covers."""
    out, at = [], first
    for a, b in sorted(spans) + [(last + 1, last + 1)]:
        if b < at:
            continue
        gap_end = min(a - 1, last)
        while at <= gap_end:
            end = min(at + chunk - 1, gap_end)
            out.append((at, end))
            at = end + 1
        at = max(at, b + 1)
        if at > last:
            break
    return out


def run_chunk(mix, args, first, last):
    env = dict(os.environ)
    env.update(
        MIX_ENV="test",
        TEAM_XL_SEEDS=f"{first}..{last}",
        TEAM_XL_SIZES=args.sizes,
        TEAM_XL_CHECK_MAX=str(args.check_max),
        TEAM_XL_FAILURES=os.path.abspath(args.failures),
        ELIXIR_ERL_OPTIONS="+S 1:1",
    )
    proc = subprocess.run(
        [mix, "test", "test/ainalrami/team_proof_xl_test.exs", "--only", "whole_rounds_xl"],
        cwd=args.repo,
        env=env,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=BELOW_NORMAL_PRIORITY_CLASS if sys.platform == "win32" else 0,
    )
    return proc.returncode, proc.stdout + proc.stderr


def main():
    args = parse_args()
    mix = shutil.which("mix")
    if not mix:
        sys.exit("mix is not on PATH")

    stop_file = args.stop or os.path.join(os.path.dirname(os.path.abspath(args.state)), "STOP")
    state = load_state(args.state)
    state["planned"] = {
        "first": args.first, "last": args.last, "chunk": args.chunk, "workers": args.workers,
        "sizes": args.sizes, "check_max": args.check_max,
    }
    state.setdefault("first_started", time.strftime("%Y-%m-%d %H:%M:%S"))
    state["last_started"] = time.strftime("%Y-%m-%d %H:%M:%S")
    state["pid"] = os.getpid()
    save_state(args.state, state)

    spans = [tuple(d["range"]) for d in state["done"]]
    queue = collections.deque(todo(args.first, args.last, args.chunk, spans))
    lock = threading.Lock()
    started = time.time()
    seeds_at_start = state["seeds"]
    print(
        f"{time.strftime('%Y-%m-%d %H:%M:%S')}  pid {os.getpid()}  {len(queue)} chunks to run "
        f"(seeds {args.first}..{args.last}), {args.workers} workers, state in {args.state}",
        flush=True,
    )

    def worker():
        while True:
            with lock:
                if not queue:
                    return
                if os.path.exists(stop_file):
                    print(f"{stop_file} exists - not starting another chunk", flush=True)
                    return
                first, last = queue.popleft()
            t0 = time.time()
            code, out = run_chunk(mix, args, first, last)
            secs = round(time.time() - t0, 1)

            with lock:
                ok = SUMMARY.search(out)
                if code == 0 and ok:
                    values = dict(zip(TOTALS[:2] + ["failures"] + TOTALS[2:], map(int, ok.groups())))
                    for k in TOTALS:
                        state[k] += values[k]
                    state["done"].append(
                        {"range": [first, last], "rounds": values["rounds"],
                         "failures": values["failures"], "secs": secs}
                    )
                    for m in FAIL.finditer(out):
                        state["failures"].append(
                            {"seed": int(m.group(1)), "round": int(m.group(2)),
                             "teams": int(m.group(3)), "file": m.group(4)}
                        )
                        print(f"DISAGREEMENT at seed {m.group(1)} round {m.group(2)} - "
                              f"reproducer {m.group(4)} - continuing", flush=True)
                else:
                    # mix itself failed (it should not: the test counts
                    # disagreements instead of failing). Recorded, not retried,
                    # and NOT counted as done: a restart tries the range again.
                    state["errors"].append(
                        {"range": [first, last], "code": code, "secs": secs, "output": out[-6000:]}
                    )
                    print(f"chunk {first}..{last} errored (exit {code}) - recorded", flush=True)

                state["updated"] = time.strftime("%Y-%m-%d %H:%M:%S")
                save_state(args.state, state)
                done = state["seeds"] - seeds_at_start
                rate = done / max(time.time() - started, 1)
                left = sum(b - a + 1 for a, b in queue)
                eta_h = left / rate / 3600 if rate else float("inf")
                print(
                    f"{time.strftime('%H:%M:%S')}  seeds {state['seeds']:,}  rounds {state['rounds']:,}  "
                    f"{rate * 3600:,.0f} seeds/h  failures {len(state['failures'])}  "
                    f"errors {len(state['errors'])}  chunks left {len(queue)}  ETA {eta_h:.1f} h",
                    flush=True,
                )

    threads = [threading.Thread(target=worker) for _ in range(args.workers)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    state["pid"] = None
    save_state(args.state, state)
    print(
        f"{time.strftime('%Y-%m-%d %H:%M:%S')}  FINISHED  seeds {state['seeds']:,}  "
        f"rounds {state['rounds']:,}  failures {len(state['failures'])}  errors {len(state['errors'])}",
        flush=True,
    )


if __name__ == "__main__":
    main()
