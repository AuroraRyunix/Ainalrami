"""Solver half of tools/exhaustion_matching.exs.

Reads the position graphs the Elixir half wrote and decides, for each, whether
a complete legal pairing exists. It shares no code with Ainalrami and uses two
unrelated algorithms, and both must agree on the SIZE of a maximum matching,
not only on whether it is perfect:

  1. networkx.max_weight_matching(G, maxcardinality=True) - Edmonds' blossom
     algorithm in a third-party library (weights all 1, so this is maximum
     cardinality).
  2. The rank of a random Tutte matrix over GF(2^61 - 1) (Lovasz 1979): the
     maximum matching has size rank/2. Algebraic, no blossoms. It can only err
     by reporting a rank that is too LOW, with probability at most N/p per
     graph (about 2e-17 here); a rank it reports is never too high.

An odd field is handled by one dummy vertex joined to every bye-eligible
player: the field can be paired iff the extended graph has a perfect matching,
the dummy's partner being the player who sits out.

Line format (tab separated), one position per line:

    kind  seed  round  n  enum  witness  byehex  row0,row1,...,row(n-1)

`kind` is `refusal` or `control`; `enum` is `legal`/`none`/`-` (the Elixir
side's enumeration, present for n <= 12 only); `byehex` is the bye-eligible
players as a bitmask; each row is the hex bitmask of that player's legal
opponents (bit j = player j). Players are numbered 0..n-1.

Usage:  py -3 -I tools/exhaustion_matching.py <chunk-file> <workers>
Prints one JSON object: counts, and the disagreeing lines (capped).
"""

import json
import random
import sys
from collections import Counter
from multiprocessing import Pool

import networkx as nx

P = (1 << 61) - 1


def parse(line):
    kind, seed, rnd, n, enum, witness, byehex, rows = line.rstrip("\n").split("\t")
    n = int(n)
    rows = [int(r, 16) for r in rows.split(",")] if n else []
    return kind, int(seed), int(rnd), n, enum, witness, int(byehex, 16), rows


def edges_of(n, rows, bye):
    edges = [(i, j) for i in range(n) for j in range(i + 1, n) if rows[i] >> j & 1]
    if n % 2 == 1:
        edges += [(i, n) for i in range(n) if bye >> i & 1]
    return edges


def nx_size(N, edges):
    G = nx.Graph()
    G.add_nodes_from(range(N))
    G.add_edges_from(edges)
    m = nx.max_weight_matching(G, maxcardinality=True)
    # return the matching so the caller can verify it is a real matching
    return m


def tutte_size(N, edges, rng):
    M = [[0] * N for _ in range(N)]
    for i, j in edges:
        x = rng.randrange(1, P)
        M[i][j] = x
        M[j][i] = P - x
    rank = 0
    for col in range(N):
        piv = next((r for r in range(rank, N) if M[r][col]), None)
        if piv is None:
            continue
        M[rank], M[piv] = M[piv], M[rank]
        inv = pow(M[rank][col], P - 2, P)
        prow = M[rank]
        for r in range(rank + 1, N):
            f = M[r][col]
            if f:
                f = f * inv % P
                row = M[r]
                for c in range(col, N):
                    row[c] = (row[c] - f * prow[c]) % P
        rank += 1
    return rank // 2  # skew-symmetric: rank is even


def solve(line):
    kind, seed, rnd, n, enum, witness, bye, rows = parse(line)
    if n == 0:
        return dict(kind=kind, seed=seed, rnd=rnd, n=n, verdict="empty", enum=enum, witness=witness, line=line)
    N = n + (n % 2)
    edges = edges_of(n, rows, bye)
    m = nx_size(N, edges)
    # the library's answer must itself be a valid matching on the graph
    es = {frozenset(e) for e in edges}
    seen = set()
    valid = True
    for a, b in m:
        if frozenset((a, b)) not in es or a in seen or b in seen:
            valid = False
        seen.update((a, b))
    nx_pairs = len(m)
    verdict = "legal" if nx_pairs * 2 == N else "none"
    # Tutte rank: all refusals, all small fields, and every control up to 24
    # players; larger controls already carry the reference's own pairing as a
    # witness checked on the Elixir side.
    tutte = None
    if kind == "refusal" or n <= 24:
        tutte = tutte_size(N, edges, random.Random(seed * 1000 + rnd))
    return dict(
        kind=kind, seed=seed, rnd=rnd, n=n, verdict=verdict, enum=enum, witness=witness,
        nx_pairs=nx_pairs, tutte_pairs=tutte, valid=valid, line=line,
    )


def main():
    path, workers = sys.argv[1], int(sys.argv[2])
    with open(path) as f:
        lines = [l for l in f if l.strip()]
    with Pool(workers) as pool:
        results = pool.map(solve, lines, chunksize=64)

    counts = Counter()
    bad = []
    for r in results:
        k = r["kind"]
        counts[f"{k}:total"] += 1
        counts[f"{k}:{r['verdict']}"] += 1
        counts[f"n:{k}:{r['n']}"] += 1
        flagged = []
        if r["verdict"] == "empty":
            flagged.append("empty_field")
        else:
            if not r["valid"]:
                flagged.append("nx_returned_invalid_matching")
            if r["tutte_pairs"] is not None:
                counts["tutte:compared"] += 1
                if r["tutte_pairs"] != r["nx_pairs"]:
                    flagged.append(f"nx_vs_tutte nx={r['nx_pairs']} tutte={r['tutte_pairs']}")
            if r["enum"] != "-":
                counts["enum:compared"] += 1
                if r["enum"] != r["verdict"]:
                    flagged.append(f"nx_vs_enum nx={r['verdict']} enum={r['enum']}")
            if k == "refusal" and r["verdict"] != "none":
                flagged.append("refusal_but_legal_pairing_exists")
            if k == "control" and r["verdict"] != "legal":
                flagged.append("control_says_none")
            if k == "control" and r["witness"] != "ok":
                flagged.append("witness_" + r["witness"])
        if flagged:
            counts["flagged"] += 1
            bad.append(dict(flags=flagged, line=r["line"].rstrip("\n")))
    json.dump(dict(counts=counts, bad=bad[:50]), sys.stdout)


if __name__ == "__main__":
    main()
