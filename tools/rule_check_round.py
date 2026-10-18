"""Independent rule check (C1, C2, C3, completeness) of two pairings of one TRF round.

usage: python tools/rule_check_round.py file.trf bbp_out.txt ainalrami_out.txt
Output files are bbpPairings' -p format: count, then "w b" lines, "x 0" = PAB.
"""
import sys


def parse(path):
    players = {}
    xxr = None
    for line in open(path, encoding="utf-8", errors="replace"):
        if line.startswith("XXR"):
            xxr = int(line.split()[1])
        if not line.startswith("001"):
            continue
        rank = int(line[4:8])
        pts = float(line[80:84])
        rounds = []
        rest = line[91:].rstrip("\n")
        i = 0
        while i + 8 <= len(rest) + 1:
            chunk = rest[i:i + 8]
            if not chunk.strip():
                i += 10
                continue
            opp, col, res = chunk[0:4].strip(), chunk[5:6], chunk[7:8]
            rounds.append((int(opp) if opp.isdigit() else 0, col, res))
            i += 10
        players[rank] = dict(pts=pts, rounds=rounds)
    return players, xxr


def read_out(path):
    lines = [l.split() for l in open(path) if l.strip()]
    return [(int(a), int(b)) for a, b in lines[1:]]


def played_rounds(players):
    n = 0
    for p in players.values():
        for k, (opp, _c, _r) in enumerate(p["rounds"]):
            if opp:
                n = max(n, k + 1)
    return n


def colour_pref(rounds):
    cols = [c for opp, c, r in rounds if opp and c in "wb" and r not in "+-"]
    if not cols:
        return None
    diff = cols.count("w") - cols.count("b")
    if diff > 1 or (len(cols) >= 2 and cols[-1] == cols[-2] == "w"):
        return "B"  # absolute black
    if diff < -1 or (len(cols) >= 2 and cols[-1] == cols[-2] == "b"):
        return "W"
    return None


def check(players, pairing, rnd):
    hist = {r: players[r]["rounds"][: rnd - 1] for r in players}
    absent = {r for r in players if len(players[r]["rounds"]) >= rnd and players[r]["rounds"][rnd - 1][0] == 0}
    present = set(players) - absent
    probs = []
    seen = []
    byes = []
    for w, b in pairing:
        seen.append(w)
        if b == 0:
            byes.append(w)
        else:
            seen.append(b)
            opps_w = {o for o, _c, _r in hist[w] if o}
            if b in opps_w:
                probs.append(f"C1 rematch {w}-{b}")
            pw, pb = colour_pref(hist[w]), colour_pref(hist[b])
            if pw and pw == pb:
                probs.append(f"C3 both absolute {pw}: {w}-{b}")
    if sorted(seen) != sorted(present):
        probs.append(f"not every present player paired once: {sorted(seen)} vs {sorted(present)}")
    if len(byes) > 1 or (byes and len(present) % 2 == 0):
        probs.append("bad bye count")
    for x in byes:
        unplayed_full = [k + 1 for k, (o, _c, r) in enumerate(hist[x]) if (o == 0 and r in "UF") or r == "+"]
        if unplayed_full:
            probs.append(f"C2 bye to {x}, who already scored unplayed full point in round(s) {unplayed_full}")
    return probs, byes, sorted(absent)


players, xxr = parse(sys.argv[1])
rnd = played_rounds(players) + 1
print(f"round paired: {rnd} (XXR {xxr}); players {len(players)}")
for label, path in (("bbpPairings", sys.argv[2]), ("Ainalrami", sys.argv[3])):
    pairing = read_out(path)
    probs, byes, absent = check(players, pairing, rnd)
    print(f"  {label}: {pairing}  bye={byes} absent={absent}")
    print("    " + ("LEGAL (C1, C2, C3, completeness)" if not probs else "; ".join(probs)))
