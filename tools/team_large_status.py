"""One-line progress of the large-field C.04.6 run (tools/team_large_run.py).

    py -3 tools/team_large_status.py [team_large_state.json]
"""

import json
import os
import sys

path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "team_large_state.json"
)
with open(path, encoding="utf-8") as f:
    s = json.load(f)

plan = s.get("planned", {})
total = plan.get("last", 0) - plan.get("first", 1) + 1
secs = sum(d["secs"] for d in s["done"])
workers = plan.get("workers", 1)
per_seed = secs / s["seeds"] if s["seeds"] else 0
left_h = (total - s["seeds"]) * per_seed / workers / 3600

print(
    f"seeds {s['seeds']:,} of {total:,} ({plan.get('first')}..{plan.get('last')})  "
    f"rounds {s['rounds']:,}  failures {len(s['failures'])}  errors {len(s['errors'])}  "
    f"brackets checked {s['brackets_checked']:,} / skipped {s['brackets_skipped']:,}  "
    f"{per_seed:.1f} core-s per seed  about {left_h:.1f} h left at {workers} workers  "
    f"updated {s.get('updated', '-')}  runner pid {s.get('pid')}"
)
for f in s["failures"]:
    print(f"  FAILURE seed {f['seed']} round {f['round']} ({f['teams']} teams): {f['file']}")
for e in s["errors"]:
    print(f"  ERROR chunk {e['range']} exit {e['code']}")
