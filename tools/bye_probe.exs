# Minimal probe: does bbpPairings avoid giving a SECOND pairing-allocated bye
# when an eligible alternative exists?
#
# Three players, one round played. Rank 1 took a pairing-allocated bye (`U`)
# in round 1; ranks 2 and 3 played each other. Round 2 has an odd field, so
# somebody takes the bye, and both 2 and 3 are eligible for it.
#
#   mix run tools/bye_probe.exs

players = [
  %{
    rank: 1,
    name: "Already Byed",
    sex: "",
    title: "",
    fide_rating: 2000,
    federation: "",
    fide_number: nil,
    birth_date: "",
    points: 1.0,
    games: [%{opponent_rank: nil, colour: nil, result: "U"}]
  },
  %{
    rank: 2,
    name: "Winner",
    sex: "",
    title: "",
    fide_rating: 1900,
    federation: "",
    fide_number: nil,
    birth_date: "",
    points: 1.0,
    games: [%{opponent_rank: 3, colour: "w", result: "1"}]
  },
  %{
    rank: 3,
    name: "Loser",
    sex: "",
    title: "",
    fide_rating: 1800,
    federation: "",
    fide_number: nil,
    birth_date: "",
    points: 0.0,
    games: [%{opponent_rank: 2, colour: "b", result: "0"}]
  }
]

trf =
  OpenPair.Trf.serialize(%{
    tournament: %{name: "Bye probe", number_of_players: 3, number_of_rounds: 5},
    players: players
  })

path = Path.join(System.tmp_dir!(), "bye_probe.trf")
File.write!(path, trf)

out = Path.join(System.tmp_dir!(), "bye_probe_out.txt")
exe = System.get_env("BBPPAIRINGS_EXE", "../openpairings/priv/bbppairings/bbpPairings-windows.exe")

{result, code} = System.cmd(exe, ["--dutch", path, "-p", out], stderr_to_stdout: true)

IO.puts("bbpPairings exit #{code} #{String.trim(result)}")

if code == 0 do
  IO.puts("bbpPairings says:\n" <> File.read!(out))
end

IO.puts("OpenPair says: #{inspect(OpenPair.Pairing.pair_next_round(players, expected_rounds: 5))}")
