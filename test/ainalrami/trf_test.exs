defmodule Ainalrami.TrfTest do
  use ExUnit.Case, async: true

  alias Ainalrami.Trf

  # Column numbers are 1-indexed inclusive, straight from the FIDE spec.
  defp col(line, start, stop), do: String.slice(line, start - 1, stop - start + 1)

  defp sample do
    %{
      tournament: %{
        name: "Test Open 2026",
        city: "Ghent",
        federation: "BEL",
        start_date: "2026-07-01",
        end_date: "2026-07-05",
        type: "swiss",
        chief_arbiter: "Jorian Burssens",
        deputy_arbiters: ["Assistant One"],
        time_control: "90+30",
        round_dates: ["2026-07-01", "2026-07-02", "2026-07-03"]
      },
      players: [
        %{
          rank: 1,
          sex: "m",
          title: "GM",
          name: "Carlsen, Magnus",
          fide_rating: 2823,
          federation: "NOR",
          fide_number: 1_503_014,
          birth_date: "1990-11-30",
          points: 2.5,
          games: [
            %{opponent_rank: 2, colour: "w", result: "1"},
            %{opponent_rank: 3, colour: "b", result: "="},
            %{opponent_rank: nil, colour: nil, result: "U"}
          ]
        },
        %{
          rank: 2,
          sex: "w",
          title: "",
          name: "Vandekerckhove, Ava",
          fide_rating: 1674,
          federation: "BEL",
          fide_number: 207_918,
          birth_date: "1990-01-01",
          points: 0.0,
          games: [
            %{opponent_rank: 1, colour: "b", result: "0"},
            %{opponent_rank: 3, colour: "w", result: "0"},
            %{opponent_rank: 2, colour: nil, result: "Z"}
          ]
        }
      ]
    }
  end

  test "header lines use the code + free-text layout" do
    lines = sample() |> Trf.serialize() |> String.split("\r\n")

    assert Enum.at(lines, 0) == "012 Test Open 2026"
    assert Enum.at(lines, 1) == "022 Ghent"
    assert Enum.at(lines, 2) == "032 BEL"
    assert Enum.at(lines, 3) == "042 2026/07/01"
    assert Enum.at(lines, 4) == "052 2026/07/05"
  end

  test "player line matches the exact FIDE TRF16 column positions" do
    line =
      sample()
      |> Trf.serialize()
      |> String.split("\r\n")
      |> Enum.find(&(String.starts_with?(&1, "001") and &1 =~ "Carlsen"))

    assert col(line, 1, 3) == "001"
    assert col(line, 5, 8) |> String.trim() == "1"
    assert col(line, 10, 10) == "m"
    assert col(line, 11, 13) |> String.trim() == "GM"
    assert col(line, 15, 47) |> String.trim() == "Carlsen, Magnus"
    assert col(line, 49, 52) |> String.trim() == "2823"
    assert col(line, 54, 56) == "NOR"
    assert col(line, 58, 68) |> String.trim() == "1503014"
    assert col(line, 70, 79) == "1990/11/30"
    assert col(line, 81, 84) == " 2.5"
    assert col(line, 86, 89) |> String.trim() == "1"

    # Round 1: opponent 2, colour w, result 1 (win)
    assert col(line, 92, 95) |> String.trim() == "2"
    assert col(line, 97, 97) == "w"
    assert col(line, 99, 99) == "1"

    # Round 2: opponent 3, colour b, result = (draw)
    assert col(line, 102, 105) |> String.trim() == "3"
    assert col(line, 107, 107) == "b"
    assert col(line, 109, 109) == "="

    # Round 3: pairing-allocated bye -> opponent 0000, colour '-', result U
    assert col(line, 112, 115) == "0000"
    assert col(line, 117, 117) == "-"
    assert col(line, 119, 119) == "U"
  end

  test "a control character in a name can't split or inject a TRF line" do
    # A player name has no format check beyond length, so it can carry a
    # newline/CR/tab. TRF is line- and column-oriented and this text is
    # written to a pairing engine's input file, so an unstripped newline
    # would break the row into two — corrupting the parse or injecting a
    # line.
    data = put_in(sample(), [:players, Access.at(0), :name], "Ev\r\nil\t001 injected")

    lines = Trf.serialize(data) |> String.split("\r\n")
    player_lines = Enum.filter(lines, &String.starts_with?(&1, "001"))

    # Still exactly one 001 line per player (2 in the sample), none injected.
    assert length(player_lines) == 2

    carlsen_replacement = Enum.find(player_lines, &(&1 =~ "Ev"))
    refute carlsen_replacement =~ "\n"
    refute carlsen_replacement =~ "\t"
    # The controls became spaces, so the name field stays inside its columns.
    assert col(carlsen_replacement, 15, 47) |> String.trim() =~ ~r/^Ev  il 001 injected$/
  end

  test "082 (number of teams) is always emitted, even 0 for an individual tournament" do
    lines = sample() |> Trf.serialize() |> String.split("\r\n")
    assert Enum.any?(lines, &(&1 == "082 0"))
  end

  test "082 reflects the real team count when teams are present" do
    data =
      sample()
      |> Map.put(:teams, [%{name: "A", player_ranks: [1]}, %{name: "B", player_ranks: [2]}])

    lines = Trf.serialize(data) |> String.split("\r\n")
    assert Enum.any?(lines, &(&1 == "082 2"))
  end

  test "132 (round dates) is omitted when every round in the list is blank/nil" do
    data = put_in(sample(), [:tournament, :round_dates], [nil, "", nil])
    lines = Trf.serialize(data) |> String.split("\r\n")
    refute Enum.any?(lines, &String.starts_with?(&1, "132"))
  end

  test "132 (round dates) is still emitted, with blanks for missing rounds, when at least one date is set" do
    data = put_in(sample(), [:tournament, :round_dates], [nil, "2026-07-02", nil])

    line =
      Trf.serialize(data) |> String.split("\r\n") |> Enum.find(&String.starts_with?(&1, "132"))

    assert col(line, 92, 99) == "        "
    assert col(line, 102, 109) == "26/07/02"
  end

  test "round-dates (132) line places YY/MM/DD at the round-block columns" do
    line =
      sample()
      |> Trf.serialize()
      |> String.split("\r\n")
      |> Enum.find(&String.starts_with?(&1, "132"))

    assert col(line, 92, 99) == "26/07/01"
    assert col(line, 102, 109) == "26/07/02"
    assert col(line, 112, 119) == "26/07/03"
  end

  test "parse/1 is the inverse of serialize/1 for header + player data" do
    parsed = sample() |> Trf.serialize() |> Trf.parse()

    assert parsed.tournament[:name] == "Test Open 2026"
    assert parsed.tournament[:city] == "Ghent"
    assert parsed.tournament[:federation] == "BEL"
    assert parsed.tournament[:start_date] == "2026-07-01"
    assert parsed.tournament[:end_date] == "2026-07-05"
    assert parsed.tournament.deputy_arbiters == ["Assistant One"]
    assert parsed.tournament[:time_control] == "90+30"
    assert parsed.tournament[:round_dates] == ["2026-07-01", "2026-07-02", "2026-07-03"]

    assert length(parsed.players) == 2
    [magnus | _] = parsed.players
    assert magnus.rank == 1
    assert magnus.sex == "m"
    assert magnus.title == "GM"
    assert magnus.name == "Carlsen, Magnus"
    assert magnus.fide_rating == 2823
    assert magnus.federation == "NOR"
    assert magnus.fide_number == 1_503_014
    assert magnus.birth_date == "1990-11-30"
    assert magnus.points == 2.5

    assert magnus.games == [
             %{opponent_rank: 2, colour: "w", result: "1"},
             %{opponent_rank: 3, colour: "b", result: "="},
             %{opponent_rank: nil, colour: nil, result: "U"}
           ]
  end

  test "teams are serialized and parsed with correct player-slot columns" do
    data = sample() |> Map.put(:teams, [%{name: "KGSRL Gent", player_ranks: [1, 2]}])
    trf = Trf.serialize(data)
    line = trf |> String.split("\r\n") |> Enum.find(&String.starts_with?(&1, "013"))

    assert col(line, 1, 3) == "013"
    assert col(line, 5, 36) |> String.trim() == "KGSRL Gent"
    assert col(line, 37, 40) |> String.trim() == "1"
    assert col(line, 42, 45) |> String.trim() == "2"

    parsed = Trf.parse(trf)
    assert parsed.teams == [%{name: "KGSRL Gent", player_ranks: [1, 2]}]
  end

  test "a name longer than 33 characters is truncated, not overflowed into the rating field" do
    data = %{
      tournament: %{name: "T"},
      players: [%{rank: 1, name: String.duplicate("A", 50), points: 0.0, games: []}]
    }

    line =
      data
      |> Trf.serialize()
      |> String.split("\r\n")
      |> Enum.find(&String.starts_with?(&1, "001"))

    assert col(line, 15, 47) == String.duplicate("A", 33)
    assert col(line, 48, 48) == " "
  end

  ## ---------- result validation ----------

  # Two players paired against each other for round 1, with the given TRF
  # result codes on each side.
  defp two_player_round(result_a, result_b) do
    %{
      tournament: %{name: "T"},
      players: [
        %{
          rank: 1,
          name: "A",
          points: 0.0,
          games: [%{opponent_rank: 2, colour: "w", result: result_a}]
        },
        %{
          rank: 2,
          name: "B",
          points: 0.0,
          games: [%{opponent_rank: 1, colour: "b", result: result_b}]
        }
      ]
    }
  end

  defp set_char(line, col, char) do
    {a, rest} = String.split_at(line, col - 1)
    <<_::binary-size(1), b::binary>> = rest
    a <> char <> b
  end

  test "serialize/1 raises when both players claim a win" do
    assert_raise Trf.ValidationError, ~r/illegal result combination/, fn ->
      two_player_round("1", "1") |> Trf.serialize()
    end
  end

  test "serialize/1 raises when both players are marked forfeit-win" do
    assert_raise Trf.ValidationError, ~r/illegal result combination/, fn ->
      two_player_round("+", "+") |> Trf.serialize()
    end
  end

  test "serialize/1 raises when a played result is paired with a mismatched score (win vs draw)" do
    assert_raise Trf.ValidationError, ~r/illegal result combination/, fn ->
      two_player_round("1", "=") |> Trf.serialize()
    end
  end

  test "serialize/1 raises on a result code that isn't in the TRF16 spec" do
    assert_raise Trf.ValidationError, ~r/unrecognized TRF result code/, fn ->
      two_player_round("X", "0") |> Trf.serialize()
    end
  end

  test "serialize/1 accepts a played 0-0 (both players score a loss, code '0' for both)" do
    trf = two_player_round("0", "0") |> Trf.serialize()
    assert trf =~ "001"
  end

  test "serialize/1 accepts the asymmetric result ('=' vs '0', an arbiter's disciplinary point adjustment)" do
    trf = two_player_round("=", "0") |> Trf.serialize()
    assert trf =~ "001"

    # And the mirror image — the other side gets the ½.
    trf2 = two_player_round("0", "=") |> Trf.serialize()
    assert trf2 =~ "001"
  end

  test "serialize/1 still rejects '=' paired with anything other than '=' or '0'" do
    assert_raise Trf.ValidationError, fn -> two_player_round("=", "1") |> Trf.serialize() end
    assert_raise Trf.ValidationError, fn -> two_player_round("=", "+") |> Trf.serialize() end
  end

  test "serialize/1 accepts a double forfeit ('-' for both sides)" do
    trf = two_player_round("-", "-") |> Trf.serialize()
    assert trf =~ "001"
  end

  test "serialize/1 accepts a single forfeit ('+' vs '-')" do
    trf = two_player_round("+", "-") |> Trf.serialize()
    assert trf =~ "001"
  end

  test "serialize/1 does not flag a dangling/unresolvable opponent reference as illegal" do
    # Round 1's opponent (rank 2) doesn't exist in this single-player roster —
    # that's a caller concern (e.g. a partial player card), not a result
    # validation error.
    data = %{
      tournament: %{name: "T"},
      players: [
        %{rank: 1, name: "A", points: 0.0, games: [%{opponent_rank: 2, colour: "w", result: "1"}]}
      ]
    }

    assert Trf.serialize(data) =~ "001"
  end

  test "parse/1 also raises on an illegal result combination" do
    text = two_player_round("1", "0") |> Trf.serialize()
    lines = String.split(text, "\r\n")
    p2 = Enum.find(lines, &(String.starts_with?(&1, "001") and &1 =~ "B"))

    # Round 1's result column is 99 (base 92 + 7) — see round_cols/1. Flip
    # player B's loss into a second win, making the round illegal.
    bad_p2 = set_char(p2, 99, "1")
    bad_text = lines |> Enum.map(&if &1 == p2, do: bad_p2, else: &1) |> Enum.join("\r\n")

    assert_raise Trf.ValidationError, ~r/illegal result combination/, fn ->
      Trf.parse(bad_text)
    end
  end

  test "serialize/1 raises when opponent 0000 carries a played-game result code" do
    data = %{
      tournament: %{name: "T"},
      players: [
        %{
          rank: 1,
          name: "A",
          points: 1.0,
          games: [%{opponent_rank: nil, colour: nil, result: "1"}]
        }
      ]
    }

    assert_raise Trf.ValidationError, ~r/opponent 0000 cannot carry played-game result/, fn ->
      Trf.serialize(data)
    end
  end

  test "serialize/1 accepts a legitimate bye code (F/H/Z/U) with no opponent" do
    for code <- ["F", "H", "Z", "U"] do
      data = %{
        tournament: %{name: "T"},
        players: [
          %{
            rank: 1,
            name: "A",
            points: 1.0,
            games: [%{opponent_rank: nil, colour: nil, result: code}]
          }
        ]
      }

      assert Trf.serialize(data) =~ "001"
    end
  end

  test "parse/1 succeeds on a legal round-trip" do
    text = two_player_round("+", "-") |> Trf.serialize()
    parsed = Trf.parse(text)
    [a, b] = parsed.players
    assert a.games == [%{opponent_rank: 2, colour: "w", result: "+"}]
    assert b.games == [%{opponent_rank: 1, colour: "b", result: "-"}]
  end

  # ---------------------------------------------------------------------
  # TRF06 (FIDE's Annexure-B, 2006) — column-identical to TRF16, but
  # predates the F/H/U/Z bye codes: a bye is a dangling playing code
  # against opponent 0000, and a "not paired" round is left fully blank
  # rather than carrying any code at all.
  # ---------------------------------------------------------------------

  # Places `text` at 1-indexed `col` in `line`, padding with spaces as
  # needed — exact column math, so these fixtures can't suffer the same
  # off-by-a-few-spaces mistake a hand-typed fixed-width string risks.
  defp place_col(line, position, text) do
    text = to_string(text)
    needed = position - 1 + String.length(text)
    line = if String.length(line) < needed, do: String.pad_trailing(line, needed), else: line
    {before, rest} = String.split_at(line, position - 1)
    {_, after_} = String.split_at(rest, String.length(text))
    before <> text <> after_
  end

  defp round_block(line, round_number, opponent, colour, result) do
    base = 92 + (round_number - 1) * 10

    line
    |> place_col(base, (opponent && String.pad_leading(to_string(opponent), 4)) || "0000")
    |> place_col(base + 5, colour || "-")
    |> place_col(base + 7, result || "")
  end

  test "parse/1 tolerates a TRF06-vintage dangling playing code (bye with no F/H/U/Z code) that serialize/1 rejects" do
    line =
      ""
      |> place_col(1, "001")
      |> place_col(5, "   1")
      |> place_col(15, "Solo, Player")
      |> place_col(81, " 1.0")
      |> place_col(86, "   1")
      |> round_block(1, nil, nil, "1")

    parsed = Trf.parse(line <> "\r\n")
    assert [%{games: [%{opponent_rank: nil, colour: nil, result: "1"}]}] = parsed.players

    # The exact same shape is still correctly rejected on the way OUT — our
    # own pairing-input construction must never write this.
    assert_raise Trf.ValidationError, fn ->
      Trf.serialize(%{
        tournament: %{name: "T"},
        players: [
          %{
            rank: 1,
            name: "A",
            points: 1.0,
            games: [%{opponent_rank: nil, colour: nil, result: "1"}]
          }
        ]
      })
    end
  end

  test "parse/1 doesn't stop at a genuinely blank round when real rounds follow (a late entrant's TRF06-style gap)" do
    # Round 1 is entirely blank ("not paired", TRF06's own convention for a
    # late entrant) - round 2 is a real game. A naive implementation that
    # stops parsing at the first blank round would silently drop round 2.
    line =
      ""
      |> place_col(1, "001")
      |> place_col(5, "   1")
      |> place_col(15, "Late, Entrant")
      |> place_col(81, " 1.0")
      |> place_col(86, "   1")
      |> round_block(2, 2, "b", "1")

    parsed = Trf.parse(line <> "\r\n")

    assert [%{games: [blank, real]}] = parsed.players
    assert blank == %{opponent_rank: nil, colour: nil, result: nil}
    assert real == %{opponent_rank: 2, colour: "b", result: "1"}
  end

  describe "XXR (JaVaFo's round-count extension)" do
    # A two-player roster plus whatever extension lines the test wants.
    defp roster_trf(extra) do
      Ainalrami.Trf.serialize(%{
        tournament: %{name: "XXR Test", type: "swiss"},
        players: [
          %{rank: 1, name: "A", fide_rating: 2000, points: 0.0, games: []},
          %{rank: 2, name: "B", fide_rating: 1900, points: 0.0, games: []}
        ]
      }) <> extra
    end

    test "supplies the round count when the file carries no 142 line" do
      parsed = Ainalrami.Trf.parse(roster_trf("XXR 9\r\n"))

      assert parsed.tournament[:number_of_rounds] == 9
    end

    test "an explicit 142 wins over XXR" do
      text =
        Ainalrami.Trf.serialize(%{
          tournament: %{name: "XXR Test", type: "swiss", number_of_rounds: 5},
          players: [
            %{rank: 1, name: "A", fide_rating: 2000, points: 0.0, games: []},
            %{rank: 2, name: "B", fide_rating: 1900, points: 0.0, games: []}
          ]
        }) <> "XXR 9\r\n"

      assert Ainalrami.Trf.parse(text).tournament[:number_of_rounds] == 5
    end

    test "a malformed XXR is ignored rather than failing the parse" do
      parsed = Ainalrami.Trf.parse(roster_trf("XXR banana\r\n"))

      assert parsed.tournament[:number_of_rounds] == nil
      assert length(parsed.players) == 2
    end
  end

  describe "XXP (JaVaFo's forbidden-pairings extension)" do
    test "reads one line as a group of starting ranks" do
      parsed = Ainalrami.Trf.parse(roster_trf("XXP 1 2\r\n"))

      assert parsed.tournament[:forbidden_pairs] == [[1, 2]]
    end

    # `readForbiddenPairsXxp` (`trf.cpp:554-568`) tokenizes the whole rest
    # of the line, so one line can name any number of players and forbids
    # every pair within the group. Tab is a separator too.
    test "reads an N-player group, space- or tab-separated" do
      parsed = Ainalrami.Trf.parse(roster_trf("XXP 1\t2  1\r\n"))

      assert parsed.tournament[:forbidden_pairs] == [[1, 2, 1]]
    end

    test "collects several lines" do
      parsed = Ainalrami.Trf.parse(roster_trf("XXP 1 2\r\nXXP 2 1\r\n"))

      assert parsed.tournament[:forbidden_pairs] == [[1, 2], [2, 1]]
    end

    test "a file with no XXP line has no forbidden_pairs key at all" do
      refute Map.has_key?(Ainalrami.Trf.parse(roster_trf("")).tournament, :forbidden_pairs)
    end

    # Unlike XXR next door, this RAISES. An unreadable exclusion has no
    # safe fallback: silently dropping it yields a complete, legal-looking
    # pairing that seats two players an arbiter said must never meet.
    test "a malformed XXP raises rather than being skipped" do
      assert_raise Ainalrami.Trf.ValidationError, ~r/not a starting rank/, fn ->
        Ainalrami.Trf.parse(roster_trf("XXP 1 banana\r\n"))
      end
    end

    test "round-trips through serialize" do
      text =
        Ainalrami.Trf.serialize(%{
          tournament: %{name: "T", type: "swiss", forbidden_pairs: [[1, 2], [1, 2, 3]]},
          players: [%{rank: 1, name: "A", points: 0.0, games: []}]
        })

      assert Ainalrami.Trf.parse(text).tournament[:forbidden_pairs] == [[1, 2], [1, 2, 3]]
    end
  end

  describe "XXA (JaVaFo's acceleration extension)" do
    # The columns are the whole story here — see `@xxa_rank_cols`. Asserted
    # explicitly because a one-column drift is invisible to a round-trip
    # test (this parser and this serializer would simply agree on the wrong
    # answer) and is exactly the mistake the sibling project made.
    test "emits the fixed columns the spec and bbpPairings both require" do
      text =
        Ainalrami.Trf.serialize(%{
          tournament: %{name: "T", type: "swiss"},
          players: [
            %{rank: 12, name: "A", points: 0.0, games: [], accelerations: [1.0, 0.5, 0.0]}
          ]
        })

      line = text |> String.split("\r\n") |> Enum.find(&String.starts_with?(&1, "XXA"))

      assert col(line, 1, 3) == "XXA"
      assert col(line, 5, 8) == "  12"
      assert col(line, 10, 13) == " 1.0"
      assert col(line, 15, 18) == " 0.5"
      assert col(line, 20, 23) == " 0.0"
    end

    test "attaches the values to the player it names" do
      parsed = Ainalrami.Trf.parse(roster_trf("XXA    2  1.0  0.5\r\n"))

      assert [%{rank: 1} = first, %{rank: 2} = second] = parsed.players
      refute Map.has_key?(first, :accelerations)
      assert second[:accelerations] == [1.0, 0.5]
    end

    # bbpPairings pre-sizes `tournament.players` from the XXA line and
    # moves the accelerations onto the real record when the 001 line
    # arrives (`trf.cpp:369-372`), so order cannot matter.
    test "an XXA line before the player's own 001 line still lands" do
      text = "012 T\r\nXXA    1  1.0\r\n" <> roster_trf("")

      assert [%{accelerations: [1.0]}, _] = Ainalrami.Trf.parse(text).players
    end

    # `startIndex + 4 <= line.size()` (`trf.cpp:501`): a blank slot that is
    # fully present reads as zero rather than ending the record.
    test "a blank but present slot reads as zero" do
      parsed = Ainalrami.Trf.parse(roster_trf("XXA    1  1.0       0.5\r\n"))

      assert [first, _second] = parsed.players
      assert first[:accelerations] == [1.0, 0.0, 0.5]
    end

    # `push_back` onto the player's existing record (`trf.cpp:510`), and
    # `tournament.players[id]` persists between lines — so a second line
    # for the same player CONTINUES the record rather than replacing it.
    test "two XXA lines for one player append rather than the second winning" do
      parsed = Ainalrami.Trf.parse(roster_trf("XXA    1  1.0\r\nXXA    1  0.5\r\n"))

      assert [first, _second] = parsed.players
      assert first[:accelerations] == [1.0, 0.5]
    end

    test "a file with no XXA line leaves every player without the key" do
      assert Enum.all?(
               Ainalrami.Trf.parse(roster_trf("")).players,
               &(not Map.has_key?(&1, :accelerations))
             )
    end

    # The sibling project's own emitter right-aligns the rank in a
    # FIVE-column field, which puts it in columns 5-9 rather than 5-8. Real
    # bbpPairings rejects such a line outright (`Invalid line "XXA     1
    # ..."`, exit code 3, reproduced directly against the vendored binary),
    # and this must not quietly pair an unaccelerated tournament instead.
    test "the sibling project's one-column-wide layout raises rather than being ignored" do
      assert_raise Ainalrami.Trf.ValidationError, ~r/columns 5-8/, fn ->
        Ainalrami.Trf.parse(roster_trf("XXA     1  1.0  1.0\r\n"))
      end
    end

    test "round-trips through serialize" do
      text =
        Ainalrami.Trf.serialize(%{
          tournament: %{name: "T", type: "swiss"},
          players: [%{rank: 3, name: "A", points: 0.0, games: [], accelerations: [1.0, 0.5, 0.0]}]
        })

      assert [player] = Ainalrami.Trf.parse(text).players
      assert player[:accelerations] == [1.0, 0.5, 0.0]
    end
  end
end
