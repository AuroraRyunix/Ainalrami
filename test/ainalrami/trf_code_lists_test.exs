defmodule Ainalrami.TrfCodeListsTest do
  @moduledoc """
  `Trf.playing_codes/0` and `Trf.bye_codes/0` - the two published code lists.

  They exist for the sibling app (`AuroraRyunix/openpairings`), which reads
  them instead of keeping its own copies, so nothing inside this repo calls
  them and nothing inside this repo would notice them thinning, being renamed
  or falling out of step with the validation they claim to describe. Same
  reason `result_codes/0` is pinned in `letter_result_codes_test.exs`, and
  the same failure the lists were published to stop: a copy that was right
  when it was written and silently stayed that way.

  So these assertions are deliberately not "the list equals this literal" and
  nothing else. Each list is also checked against the behaviour it is
  supposed to summarise - what `serialize/1` accepts, and where - because a
  list that no longer matches the validator is worse than no list at all: a
  caller that trusted it would build a file this module then refuses.
  """

  use ExUnit.Case, async: true

  alias Ainalrami.Trf

  describe "playing_codes/0" do
    test "is the published set of codes for a round the player was paired in" do
      assert Trf.playing_codes() == ~w(1 = 0 + - W D L)
    end

    test "every code in it serializes against a real opponent" do
      for code <- Trf.playing_codes() do
        assert {:ok, _} = write(opposed(code, mirror(code))),
               "#{code} is published as a playing code but serialize/1 refuses it"
      end
    end

    test "no code in it serializes with nobody on the other side" do
      # The whole point of the split: a playing code occupies a pairing slot,
      # so an opponentless one is a file that says a game was contested
      # against nobody. `parse/1` tolerates it (TRF06 files predate the bye
      # codes); the writer never may.
      for code <- Trf.playing_codes() do
        assert {:error, message} = write(opponentless(code)),
               "#{code} is published as a playing code but serialize/1 allows it against 0000"

        assert message =~ "opponent 0000"
      end
    end
  end

  describe "bye_codes/0" do
    test "is the published set of codes for a round the player was not paired in" do
      assert Trf.bye_codes() == ~w(H F U Z)
    end

    test "every code in it serializes with nobody on the other side" do
      for code <- Trf.bye_codes() do
        assert {:ok, _} = write(opponentless(code)),
               "#{code} is published as a bye code but serialize/1 refuses it against 0000"
      end
    end
  end

  describe "the two lists together" do
    test "are disjoint, and between them are exactly what serialize/1 accepts" do
      assert Trf.playing_codes() -- Trf.bye_codes() == Trf.playing_codes()

      # Every published `result_codes/0` value has to land in one list or the
      # other, or this module documents a code its own writer rejects.
      published = Trf.result_codes() |> Map.values() |> Enum.sort()
      listed = Enum.sort(Trf.playing_codes() ++ Trf.bye_codes())
      assert published == listed
    end

    test "a code on neither list is refused, and the message says so" do
      assert {:error, message} = write(opposed("X", "X"))
      assert message =~ "unrecognized TRF result code"
    end
  end

  # The opponent's half of a legal pairing for each playing code. `-` pairs
  # with `+` rather than with itself only to keep this table single-valued;
  # both are legal.
  defp mirror("1"), do: "0"
  defp mirror("0"), do: "1"
  defp mirror("="), do: "="
  defp mirror("+"), do: "-"
  defp mirror("-"), do: "+"
  defp mirror("W"), do: "L"
  defp mirror("L"), do: "W"
  defp mirror("D"), do: "D"
  defp mirror(other), do: other

  defp opposed(code, opponent_code) do
    [
      player(1, %{opponent_rank: 2, colour: "w", result: code}),
      player(2, %{opponent_rank: 1, colour: "b", result: opponent_code})
    ]
  end

  defp opponentless(code) do
    [player(1, %{opponent_rank: nil, colour: nil, result: code})]
  end

  defp player(rank, game) do
    %{rank: rank, name: "P#{rank}", points: 0.0, games: [game]}
  end

  defp write(players) do
    {:ok, Trf.serialize(%{tournament: %{name: "Codes", type: "swiss"}, players: players}, [])}
  rescue
    e in Trf.ValidationError -> {:error, Exception.message(e)}
  end
end
