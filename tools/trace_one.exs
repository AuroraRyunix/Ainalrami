# Re-pairs a single dumped case with the global cascade, with stage
# tracing on, so the bracket where a pair is lost can be seen directly.
[trf_path] = System.argv()

%{players: players} = OpenPair.Trf.parse(File.read!(trf_path))

IO.puts("pairing #{Path.basename(trf_path)} with OPENPAIR_GLOBAL + OPENPAIR_TRACE\n")
pairs = OpenPair.Pairing.pair_next_round(players, expected_rounds: 9)
IO.puts("\nresult: #{inspect(Enum.sort(pairs), charlists: :as_lists)}")
