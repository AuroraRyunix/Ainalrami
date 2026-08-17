defmodule Ainalrami.InteropTest do
  @moduledoc """
  Reading a TRF written by something other than this engine.

  The comparison harness runs bbpPairings on every axis, but always on a
  file `Ainalrami.Trf.serialize/2` produced. So 4.3 million tournaments
  validate that the two engines agree about *pairing* and say nothing
  whatever about whether this one can read a file it did not write.

  It could not. bbpPairings' own generator terminates its lines with a
  BARE carriage return — 212 of them in this fixture, and not one newline
  — and `parse/1` split on `~r/\\r?\\n/`, which matches neither. The whole
  29KB parsed as a single line and returned zero players, with no error:
  `ainalrami their_file.trf -p` answered with an empty pairing.

  See `test/fixtures/interop/README.md` for how the fixture was made and
  why it is stored byte for byte.
  """

  use ExUnit.Case, async: true

  @moduletag timeout: 600_000

  alias Ainalrami.{Pairing, Trf}

  @fixture "test/fixtures/interop/bbppairings-generated.trf"

  # bbpPairings' generator writes no round count, so its own pairer refuses
  # the file it just produced. Supplied here rather than edited into the
  # fixture, whose exact bytes are the thing being tested.
  defp fixture_with_rounds do
    File.read!(@fixture) <> "XXR 9\r152 W\r"
  end

  describe "a TRF from another implementation" do
    test "is stored with the byte shape that broke the parser" do
      raw = File.read!(@fixture)

      assert length(String.split(raw, "\r")) - 1 == 212, "bare carriage returns"
      assert length(String.split(raw, "\n")) - 1 == 0, "and not one newline"

      # If `.gitattributes` ever stops protecting this directory, the two
      # assertions above fail here rather than the fixture quietly becoming
      # an ordinary LF file that proves nothing.
    end

    test "parses to its full roster and history" do
      parsed = Trf.parse(File.read!(@fixture))

      assert length(parsed.players) == 209
      assert Enum.all?(parsed.players, &(length(&1[:games]) == 5))

      first = Enum.find(parsed.players, &(&1[:rank] == 1))
      assert first[:points] == 3.5
      assert first[:name] =~ "Player0001"
    end

    @tag :interop
    test "pairs its next round completely and legally" do
      parsed = Trf.parse(fixture_with_rounds())

      pairs =
        Pairing.pair_next_round(parsed.players,
          expected_rounds: parsed.tournament[:number_of_rounds],
          initial_colour: parsed.tournament[:initial_colour]
        )

      seated = Enum.flat_map(pairs, fn {w, b} -> if b, do: [w, b], else: [w] end)

      assert length(pairs) == 105, "104 boards and one bye for 209 players"
      assert Enum.sort(seated) == Enum.to_list(1..209), "everyone exactly once"

      # No rematches, checked against the file's own recorded history
      # rather than against anything this engine derived.
      met =
        Map.new(parsed.players, fn p ->
          {p[:rank], Enum.map(p[:games], & &1.opponent_rank)}
        end)

      for {w, b} <- pairs, b != nil do
        refute b in Map.fetch!(met, w), "#{w} has already played #{b}"
      end
    end

    @tag :interop
    test "replays every recorded round to the same pairing" do
      # The `-c` path over a tournament this engine did not produce. Colour
      # differences are not errors — Article 5.1 leaves the first colour to
      # a drawing of lots, and the fixture records none — so this compares
      # who plays whom.
      parsed = Trf.parse(fixture_with_rounds())
      players = parsed.players

      for round <- 1..5 do
        history = rewind(players, round - 1)

        recorded =
          for p <- players,
              game = Enum.at(p[:games], round - 1),
              game.opponent_rank != nil,
              p[:rank] < game.opponent_rank,
              into: MapSet.new() do
            {p[:rank], game.opponent_rank}
          end

        ours =
          history
          |> Pairing.pair_next_round(expected_rounds: 9, initial_colour: "w")
          |> Enum.reject(fn {_w, b} -> is_nil(b) end)
          |> MapSet.new(fn {w, b} -> {min(w, b), max(w, b)} end)

        assert ours == recorded,
               "round #{round} differs from what bbpPairings recorded"
      end
    end
  end

  # The roster as it stood before `round` had been played.
  defp rewind(players, played) do
    Enum.map(players, fn p ->
      games = Enum.take(p[:games], played)

      points =
        Enum.reduce(games, 0.0, fn g, sum -> sum + Trf.points_for(g.result) end)

      p |> Map.put(:games, games) |> Map.put(:points, points)
    end)
  end
end
