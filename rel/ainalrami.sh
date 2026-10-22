#!/bin/sh
# ainalrami - the command line on Linux and macOS, for people who have no
# Erlang. The same job as rel/windows/launcher.c: run the Erlang runtime that
# sits in this folder, pass the arguments through untouched, exit with the
# CLI's exit code. bin/ainalrami (the stock release script) is not used; it
# has no idea what a TRF is.
set -eu

self=$0
# Follow symlinks (a link in /usr/local/bin, say) to the real folder.
while [ -h "$self" ]; do
  dir=$(cd "$(dirname "$self")" && pwd -P)
  self=$(readlink "$self")
  case $self in /*) ;; *) self=$dir/$self ;; esac
done
root=$(cd "$(dirname "$self")" && pwd -P)

# No trailing newline in that file, so read reports failure on a good line.
read -r erts_vsn rel_vsn < "$root/releases/start_erl.data" || [ -n "$rel_vsn" ]

ROOTDIR=$root
BINDIR=$root/erts-$erts_vsn/bin
EMU=beam
PROGNAME=erl
export ROOTDIR BINDIR EMU PROGNAME
: "${ERL_CRASH_DUMP_SECONDS:=0}"
export ERL_CRASH_DUMP_SECONDS

exec "$BINDIR/erlexec" -noshell \
  -boot "$root/releases/$rel_vsn/start" -boot_var RELEASE_LIB "$root/lib" \
  -config "$root/releases/$rel_vsn/sys.config" \
  -eval "'Elixir.Ainalrami.CLI':main([unicode:characters_to_binary(A)||A<-init:get_plain_arguments()])" \
  -extra "$@"
