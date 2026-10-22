#!/usr/bin/env bash
# The release smoke test, run by .github/workflows/release.yml on every system
# it builds for, from the root of a checkout:
#
#   rel/smoke.sh <the packaged ainalrami> <the escript>
#
# It runs the same command lines through both and demands the same bytes on
# stdout, the same bytes on stderr, the same exit code, and the same output
# file where there is one. The escript is the reference because it is what
# people have been using; a release that disagrees with it is the release
# that is wrong. Startup time of the packaged program is printed, since a
# command line that takes three seconds to say "0.44.0" gets noticed.
set -u

bin=$1
esc=$2
fail=0
tmp=$(mktemp -d)

now_ms() {
  local n
  n=$(date +%s%N 2>/dev/null)
  case $n in
    ''|*[!0-9]*) python3 -c 'import time; print(int(time.time()*1000))' ;;
    *) echo $((n / 1000000)) ;;
  esac
}

# One command line, both ways. A "@OUT@" argument is replaced by a file name
# and the file is compared afterwards.
check() {
  local label=$1
  shift
  local args=("$@") a
  local i

  for who in bin esc; do
    local call=()
    for a in "${args[@]}"; do
      if [ "$a" = "@OUT@" ]; then call+=("out.trf"); else call+=("$a"); fi
    done
    rm -f out.trf
    if [ "$who" = bin ]; then
      "$bin" "${call[@]}" >"$tmp/$who.out" 2>"$tmp/$who.err"
    else
      escript "$esc" "${call[@]}" >"$tmp/$who.out" 2>"$tmp/$who.err"
    fi
    echo $? >"$tmp/$who.rc"
    if [ -f out.trf ]; then mv out.trf "$tmp/$who.file"; else : >"$tmp/$who.file"; fi
  done

  local bad=""
  for i in out err rc file; do
    cmp -s "$tmp/bin.$i" "$tmp/esc.$i" || bad="$bad $i"
  done
  if [ -z "$bad" ]; then
    echo "ok   $label  (exit $(cat "$tmp/bin.rc"), $(wc -c <"$tmp/bin.out" | tr -d ' ') bytes on stdout)"
  else
    echo "FAIL $label  differs in:$bad"
    for i in $bad; do
      echo "--- $i: packaged"
      head -c 2000 "$tmp/bin.$i"
      echo "--- $i: escript"
      head -c 2000 "$tmp/esc.$i"
    done
    fail=1
  fi
}

only=test/fixtures/forbidden_pairs/only-legal-pairing.trf
big=test/fixtures/c2_seed8112174-r9-p18.trf

check "--version" --version
check "--help" --help
check "pair, quiet, to stdout" "$only" -p -q
check "pair, verbose, to stdout" "$only" -p
check "pair, to a file" "$only" -p @OUT@ -q
check "pair, 18 players round 9" "$big" -p -q
check "check a tournament" "$big" -c
check "standings, no tie-break list (exit 1)" "$only" -s
check "no such file" test/fixtures/does-not-exist.trf -p

# Startup time of the packaged program, median of five.
times=()
for i in 1 2 3 4 5; do
  t0=$(now_ms)
  "$bin" --version >/dev/null 2>&1
  t1=$(now_ms)
  times+=($((t1 - t0)))
done
sorted=$(printf '%s\n' "${times[@]}" | sort -n | tr '\n' ' ')
median=$(printf '%s\n' "${times[@]}" | sort -n | sed -n 3p)
echo "startup (--version), five runs sorted: $sorted ms; median $median ms"

rm -rf "$tmp"
if [ "$fail" -ne 0 ]; then
  echo "The packaged program and the escript disagree."
  exit 1
fi
echo "The packaged program and the escript agree, byte for byte."
