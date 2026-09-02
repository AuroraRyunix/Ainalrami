defmodule Ainalrami.GeneratorSweep0901Test do
  @moduledoc """
  Sweep 2026-09-01, M2 and the corpus blind spot.

  M2: `1..rounds` and `1..count` step BACKWARDS when their end is below one,
  so `rounds: 0` was two rounds and `players: -5` was a seven-player roster
  with ranks down to -5 - written to a file, exit 0, nothing said.

  The blind spot is not a rule at all: every one of the ~488M validated
  pairings went through a TRF this generator wrote, and it only ever wrote
  ASCII names. The grapheme-versus-byte column question was therefore never
  asked of the corpus. `names: :unicode` asks it.
  """
  use ExUnit.Case, async: true

  alias Ainalrami.{Generator, Trf}

  defp ascii_only?(text), do: Enum.all?(:binary.bin_to_list(text), &(&1 < 128))

  describe "M2 - ranges that would run backwards" do
    test "rounds: 0 produces a roster with no games, and says zero rounds" do
      {text, _seed} = Generator.generate(seed: 1, players: 8, rounds: 0)

      assert text =~ ~r/^142 +0\r$/m
      assert text =~ ~r/^XXR 0\r$/m

      parsed = Trf.parse(text)
      assert length(parsed.players) == 8
      assert Enum.all?(parsed.players, &(&1.games == []))
      assert parsed.tournament[:number_of_rounds] == 0
    end

    test "a negative roster size is rejected rather than inverted" do
      assert_raise ArgumentError, ~r/:players/, fn ->
        Generator.generate(seed: 1, players: -5)
      end
    end

    test "a zero roster size is rejected" do
      assert_raise ArgumentError, ~r/:players/, fn ->
        Generator.generate(seed: 1, players: 0)
      end
    end

    test "a non-integer roster size is rejected" do
      assert_raise ArgumentError, ~r/:players/, fn ->
        Generator.generate(seed: 1, players: 8.0)
      end
    end

    test "a negative round count is rejected" do
      assert_raise ArgumentError, ~r/:rounds/, fn ->
        Generator.generate(seed: 1, players: 8, rounds: -3)
      end
    end
  end

  describe "the corpus blind spot - non-ASCII names" do
    test "names: :unicode puts multibyte surnames in the file" do
      {text, _seed} = Generator.generate(seed: 42, players: 20, rounds: 3, names: :unicode)

      assert String.valid?(text)
      assert text =~ "Đurić"
      refute ascii_only?(text)
    end

    test "a unicode-named tournament round-trips through serialize and parse" do
      {text, _seed} = Generator.generate(seed: 42, players: 20, rounds: 3, names: :unicode)

      parsed = Trf.parse(text)

      assert Enum.any?(parsed.players, &(String.length(&1.name) < byte_size(&1.name)))

      # Losslessly: everything the parser read comes back out the same way,
      # names included.
      reserialised = Trf.serialize(%{tournament: parsed.tournament, players: parsed.players})
      again = Trf.parse(reserialised)

      assert Enum.map(again.players, & &1.name) == Enum.map(parsed.players, & &1.name)

      assert Enum.map(again.players, & &1.fide_rating) ==
               Enum.map(parsed.players, & &1.fide_rating)

      assert Enum.map(again.players, & &1.points) == Enum.map(parsed.players, & &1.points)
      assert Enum.map(again.players, & &1.games) == Enum.map(parsed.players, & &1.games)
    end

    test "the default is unchanged, byte for byte, so existing seeds reproduce" do
      {plain, _} = Generator.generate(seed: 99, players: 16, rounds: 4)
      {explicit, _} = Generator.generate(seed: 99, players: 16, rounds: 4, names: :ascii)

      assert plain == explicit
      assert plain =~ "Player1 "
      # ASCII by the byte, not by the grapheme: "\r\n" is one grapheme and
      # two bytes, so a length-versus-byte_size test proves nothing here.
      assert ascii_only?(plain)
    end

    test "an unknown names mode is rejected" do
      assert_raise ArgumentError, ~r/:names/, fn ->
        Generator.generate(seed: 1, players: 8, rounds: 2, names: :klingon)
      end
    end
  end
end
