defmodule Ainalrami.TrfLinearTest do
  @moduledoc """
  Reading a TRF is linear in its size, and a line is measured in bytes.

  Both were quadratic until 0.24.0, and the second was also wrong: `001`
  and `013` records were accumulated with `&1 ++ [record]`, a full list copy
  per record, and `parse_round_dates/3`, `parse_team_line/3` and
  `read_260_ids/3` each called `String.length/1` on the whole line at every
  column step. A 5 MB file of `001` lines took over an hour; a single 5 MB
  `132` line took about forty-five minutes on its own, which is a two-line
  file that hangs the reader.

  Nothing here asserts on wall-clock - that is how a test becomes flaky on a
  busy machine. What is asserted is the two things the fix actually turns
  on: that order survives being built backwards, and that a line's length is
  its byte count, which is what every column in this module already means.
  """

  use ExUnit.Case, async: true

  alias Ainalrami.Trf

  defp player_row(rank) do
    "001 " <>
      String.pad_leading(to_string(rank), 4) <>
      String.duplicate(" ", 10) <>
      "P#{rank}" <> String.duplicate(" ", 60) <> "0.0"
  end

  defp file(rows), do: Enum.map_join(rows, "", &(&1 <> "\r\n"))

  describe "record order survives the reversal" do
    # The accumulators prepend now. If the reverse were dropped, or applied
    # to one list and not the other, this is what catches it - and it has to
    # be a real count, because a two-player file reads the same both ways.
    test "players come back in file order, not reversed" do
      parsed = 1..50 |> Enum.map(&player_row/1) |> file() |> Trf.parse()

      assert Enum.map(parsed.players, & &1.rank) == Enum.to_list(1..50)
    end

    test "teams come back in file order too, with their rosters intact" do
      teams =
        for t <- 1..5 do
          ranks = Enum.map_join(((t - 1) * 4 + 1)..(t * 4), "", &String.pad_leading("#{&1}", 5))
          "013 Team #{t}" <> String.duplicate(" ", 25) <> ranks
        end

      parsed = (Enum.map(1..20, &player_row/1) ++ teams) |> file() |> Trf.parse()

      assert Enum.map(parsed.teams, & &1.name) == [
               "Team 1",
               "Team 2",
               "Team 3",
               "Team 4",
               "Team 5"
             ]

      assert hd(parsed.teams).player_ranks == [1, 2, 3, 4]
      assert List.last(parsed.teams).player_ranks == [17, 18, 19, 20]
    end
  end

  describe "a line is measured in bytes, not graphemes" do
    # The correctness half, and the reason this is a fix rather than only a
    # speed-up. Every column in this module is a byte - `read/2` takes a
    # `binary_part`, `place/4` pads to `byte_size` - so a line carrying an
    # accent is LONGER in bytes than in graphemes, and the old
    # `String.length(line) < start` guard could stop reading a line that
    # still had fields in it. A team name is where a real file gets its
    # accents.
    # Built by BYTE column, which is the only way to build one of these
    # correctly and is what the writer does. Padding by CHARACTER instead is
    # the mistake this test made on its first run: the accents push every
    # rank field four bytes right, the parse comes back empty, and it looks
    # like a defect in the reader rather than in the fixture.
    defp team_row(name, ranks) do
      base = "013 " <> name
      padded = base <> String.duplicate(" ", max(37 - 1 - byte_size(base), 0))

      ranks
      |> Enum.with_index()
      |> Enum.reduce(padded, fn {rank, i}, acc ->
        at = 37 + i * 5

        acc <>
          String.duplicate(" ", max(at - 1 - byte_size(acc), 0)) <>
          String.pad_leading("#{rank}", 4)
      end)
    end

    test "an accented team name does not truncate the roster" do
      plain = team_row("Reunis", [1, 2, 3, 4])
      accented = team_row("Réunis Élégants", [1, 2, 3, 4])

      # Three accented characters, so the line is three bytes longer than it
      # is characters - which is exactly the gap the old grapheme-counting
      # guard fell into. Asserted rather than assumed, because a fixture that
      # quietly became pure ASCII would make this whole test vacuous.
      assert byte_size(accented) - String.length(accented) == 3

      rows = Enum.map(1..4, &player_row/1)

      [from_plain] = (rows ++ [plain]) |> file() |> Trf.parse() |> Map.fetch!(:teams)
      [from_accented] = (rows ++ [accented]) |> file() |> Trf.parse() |> Map.fetch!(:teams)

      assert from_plain.player_ranks == [1, 2, 3, 4]
      assert from_accented.name == "Réunis Élégants"
      assert from_accented.player_ranks == [1, 2, 3, 4]
    end

    test "an accented round-dates line keeps every date" do
      # `132` shares the cadence and shared the defect. The accent goes in a
      # player row so the file is realistic; the dates themselves are ASCII,
      # which is the point - one long line is enough to move the guard.
      dates =
        "132" <>
          String.duplicate(" ", 88) <>
          Enum.map_join(1..6, "", fn n -> "26/03/0#{n}" <> "  " end)

      parsed = [player_row(1), dates] |> file() |> Trf.parse()

      assert length(parsed.tournament[:round_dates]) == 6
      assert hd(parsed.tournament[:round_dates]) == "2026-03-01"
    end
  end

  describe "a pathological file is read rather than hung on" do
    # Not a timing assertion: a quadratic reader does not finish these at
    # all inside the test timeout, so arriving at the assertion IS the
    # result. 4,000 records and a 100 KB line are both far past the point
    # where the old code was visibly slow (280 ms and 1,057 ms measured) and
    # far short of anything a real tournament produces.
    @tag timeout: 30_000
    test "four thousand player records" do
      parsed = 1..4_000 |> Enum.map(&player_row/1) |> file() |> Trf.parse()

      assert length(parsed.players) == 4_000
      assert List.last(parsed.players).rank == 4_000
    end

    @tag timeout: 30_000
    test "one team line naming twenty thousand slots" do
      long =
        "013 Huge" <> String.duplicate(" ", 28) <> String.duplicate("   1 ", 20_000)

      parsed = [player_row(1), long] |> file() |> Trf.parse()

      assert [team] = parsed.teams
      assert length(team.player_ranks) > 19_000
    end
  end
end
