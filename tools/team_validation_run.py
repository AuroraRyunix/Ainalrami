"""The long C.04.6 validation run: team rounds against the brute-force reference.

Runs `test/ainalrami/team_pairing_validation_test.exs --only whole_rounds` - the
ordinary test, whose reference is written from the regulation text and shares
no code with the engine - many times at once, each copy on its own seed range
(TEAM_VALIDATION_SEEDS) and its own core (`+S 1:1`), at below-normal priority.

Resumable: every finished chunk is recorded in the state file, and a restart
skips them. A disagreement fails that chunk's test; the seed is read from the
failure message, recorded with the message, and the rest of the chunk is
queued again from the next seed - one bad seed never hides the ones after it.

    py -3 tools/team_validation_run.py --first 1 --last 250000000 --workers 12

Run it from a separate checkout (a git worktree) so compiling in the main one
cannot change the code under a run that takes hours.
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
SEED_IN_FAILURE = re.compile(r"seed (\d+),")
TEAMRUN_LINE = re.compile(r"TEAMRUN seeds=(\d+) rounds=(\d+)")


def parse_args():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--first", type=int, default=1)
    p.add_argument("--last", type=int, default=250_000_000)
    p.add_argument("--chunk", type=int, default=50_000)
    p.add_argument("--workers", type=int, default=12)
    p.add_argument("--state", default="team_validation_state.json")
    p.add_argument("--repo", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    return p.parse_args()


def load_state(path):
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    return {"done": [], "failures": [], "errors": [], "rounds": 0, "seeds": 0}


def save_state(path, state):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=1)
    os.replace(tmp, path)


def covered(state):
    """Seeds already accounted for: finished ranges, plus seeds that failed."""
    spans = [tuple(d["range"]) for d in state["done"]]
    spans += [(f["seed"], f["seed"]) for f in state["failures"]]
    return sorted(spans)


def todo(first, last, chunk, spans):
    """The chunks of [first, last] no finished range already covers."""
    out, at = [], first
    for a, b in spans + [(last + 1, last + 1)]:
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


def run_chunk(mix, repo, first, last):
    env = dict(os.environ)
    env.update(
        MIX_ENV="test",
        TEAM_VALIDATION_SEEDS=f"{first}..{last}",
        ELIXIR_ERL_OPTIONS="+S 1:1",
    )
    proc = subprocess.run(
        [mix, "test", "test/ainalrami/team_pairing_validation_test.exs", "--only", "whole_rounds"],
        cwd=repo,
        env=env,
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

    state = load_state(args.state)
    queue = collections.deque(todo(args.first, args.last, args.chunk, covered(state)))
    lock = threading.Lock()
    started = time.time()
    rounds_at_start = state["rounds"]
    print(f"{len(queue)} chunks to run, {args.workers} workers, state in {args.state}", flush=True)

    def worker():
        while True:
            with lock:
                if not queue:
                    return
                first, last = queue.popleft()
            t0 = time.time()
            code, out = run_chunk(mix, args.repo, first, last)
            secs = round(time.time() - t0, 1)

            with lock:
                ok = TEAMRUN_LINE.search(out)
                if code == 0 and ok:
                    seeds, rounds = int(ok.group(1)), int(ok.group(2))
                    state["done"].append({"range": [first, last], "rounds": rounds, "secs": secs})
                    state["rounds"] += rounds
                    state["seeds"] += seeds
                else:
                    seed = SEED_IN_FAILURE.search(out)
                    if seed and first <= int(seed.group(1)) <= last:
                        bad = int(seed.group(1))
                        state["failures"].append({"seed": bad, "output": out[-6000:]})
                        # Seeds before the bad one passed, but their count is
                        # not reported on a failure: re-run them rather than
                        # claim rounds nobody counted.
                        if first < bad:
                            queue.appendleft((first, bad - 1))
                        if bad < last:
                            queue.appendleft((bad + 1, last))
                        print(f"DISAGREEMENT at seed {bad} - recorded, continuing", flush=True)
                    else:
                        state["errors"].append({"range": [first, last], "code": code, "output": out[-6000:]})
                        print(f"chunk {first}..{last} errored (exit {code}) - recorded, not retried", flush=True)

                save_state(args.state, state)
                done = state["rounds"] - rounds_at_start
                rate = done / max(time.time() - started, 1)
                left = sum(b - a + 1 for a, b in queue) * (state["rounds"] / max(state["seeds"], 1))
                eta_h = left / rate / 3600 if rate else float("inf")
                print(
                    f"{time.strftime('%H:%M:%S')}  rounds {state['rounds']:,}  "
                    f"{rate:,.0f}/s  failures {len(state['failures'])}  errors {len(state['errors'])}  "
                    f"chunks left {len(queue)}  ETA {eta_h:.1f} h",
                    flush=True,
                )

    threads = [threading.Thread(target=worker) for _ in range(args.workers)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    print(
        f"FINISHED  seeds {state['seeds']:,}  rounds {state['rounds']:,}  "
        f"failures {len(state['failures'])}  errors {len(state['errors'])}",
        flush=True,
    )


if __name__ == "__main__":
    main()
