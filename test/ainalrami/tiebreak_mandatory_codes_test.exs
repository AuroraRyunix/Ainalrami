defmodule Ainalrami.TiebreakMandatoryCodesTest do
  @moduledoc """
  FIDE's "Mandatory Tie-Breaks - TRF26" table (TEC, 2025-04): every code a
  FIDE-endorsed program must accept in a `202`/`212` record, and the values
  of the variants that table added to C.07 - `/P` on the Buchholz and
  Sonneborn-Berger family, `/K<n>` on SSSC.

  The table prints 151 distinct codes. Seven of them carry an `x` ("any
  reasonable value must be implemented"): the three Koya limits (`KS/Lx`,
  `KS:MP/Lx`, `KS:GP/Lx`) and four SSSC `Kx`. Each is tested here with two
  values, so the list below has 158 entries.

  Expected values are worked by hand in the comment beside each assertion.
  """
  # Not async: the CLI test captures :stderr, which is VM-wide.
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  import Ainalrami.Test.TiebreakEvent

  alias Ainalrami.{CLI, Generator, TeamGenerator, Tiebreaks, Trf}
  alias Ainalrami.Tiebreaks.{Code, Team}
  alias Ainalrami.Tiebreaks.Team.{Entry, Match}

  # The table as printed, column by column; `x` written out twice.
  @individual ~w(
    DE DE/P BPG BWG REP SB SB/C1 SB/C2 SB/P SB/C1/P SB/C2/P
    ARO ARO/C1 ARO/C2 ARO/M1 ARO/M2 TPR PTP APRO APPO
    WIN WON PS PS/C1 PS/C2 BH BH/C1 BH/C2 BH/M1 BH/M2
    BH/P BH/C1/P BH/C2/P BH/M1/P BH/M2/P
    FB FB/C1 FB/C2 FB/M1 FB/M2 FB/P FB/C1/P FB/C2/P FB/M1/P FB/M2/P
    AOB AOB/F KS KS/L1 KS/L-2
  )

  @team ~w(
    WIN:MP WON:MP PS:MP PS:GP PS:MP/C1 PS:MP/C2 PS:GP/C1 PS:GP/C2
    BH:MP BH:GP BH:MP/C1 BH:MP/C2 BH:MP/M1 BH:MP/M2 BH:GP/C1 BH:GP/C2 BH:GP/M1 BH:GP/M2
    BH:MP/P BH:GP/P
    BH:MP/C1/P BH:MP/C2/P BH:MP/M1/P BH:MP/M2/P BH:GP/C1/P BH:GP/C2/P BH:GP/M1/P BH:GP/M2/P
    FB:MP FB:GP FB:MP/C1 FB:MP/C2 FB:MP/M1 FB:MP/M2 FB:GP/C1 FB:GP/C2 FB:GP/M1 FB:GP/M2
    FB:MP/P FB:GP/P
    FB:MP/C1/P FB:MP/C2/P FB:MP/M1/P FB:MP/M2/P FB:GP/C1/P FB:GP/C2/P FB:GP/M1/P FB:GP/M2/P
    AOB:MP AOB:GP AOB:MP/F AOB:GP/F
    KS:MP KS:MP/L1 KS:MP/L-2 KS:GP KS:GP/L1 KS:GP/L-2
    BC TBR BBE MPvGP
    EMMSB EMMSB/C1 EMMSB/C2 EMMSB/P EMMSB/C1/P EMMSB/C2/P
    EMGSB EMGSB/C1 EMGSB/C2 EMGSB/P EMGSB/C1/P EMGSB/C2/P
    EGMSB EGMSB/C1 EGMSB/C2 EGMSB/P EGMSB/C1/P EGMSB/C2/P
    EGGSB EGGSB/C1 EGGSB/C2 EGGSB/P EGGSB/C1/P EGGSB/C2/P
    EDE EDEBT EDEBB EDET EDEB EDE/P EDEBT/P EDEBB/P EDET/P EDEB/P
    SSSC SSSC/F SSSC/P SSSC/F/P
    SSSC/K4 SSSC/K5 SSSC/F/K4 SSSC/F/K5 SSSC/P/K4 SSSC/P/K5 SSSC/F/P/K4 SSSC/F/P/K5
  )

  @all @individual ++ @team

  describe "the table" do
    test "has every code in it once" do
      assert length(@all) == 158
      assert length(Enum.uniq(@all)) == 158
    end

    test "every code parses" do
      refused = for text <- @all, match?({:error, _}, Code.parse(text)), do: text
      assert refused == []
    end

    test "every code formats back to itself, as the table spells it" do
      # Case aside: MPvGP comes back as MPVGP, which the table calls
      # case-insensitive anyway.
      for text <- @all do
        assert text |> Code.parse!() |> Code.format() == String.upcase(text)
      end
    end

    test "case does not matter" do
      assert Code.parse!("sssc/f/p/k4") == Code.parse!("SSSC/F/P/K4")
      assert Code.parse!("bh:mp/c1/p") == Code.parse!("BH:MP/C1/P")
    end

    test "the modifiers land where they should" do
      assert %Code{name: "BH", cut_low: 1, forfeits?: true} = Code.parse!("BH/C1/P")
      assert %Code{name: "FB", cut_low: 1, cut_high: 1, forfeits?: true} = Code.parse!("FB/M1/P")
      assert %Code{name: "EGGSB", cut_low: 2, forfeits?: true} = Code.parse!("EGGSB/C2/P")

      assert %Code{name: "SSSC", fore?: true, forfeits?: true, normaliser: 5} =
               Code.parse!("SSSC/F/P/K5")
    end

    test "what the table does not list is still refused" do
      # K is SSSC's alone, and needs a positive whole number.
      for text <- ~w(BH/K4 SSSC/K0 SSSC/K SSSC/K1.5 SSSC/K-2 WIN/P ARO/P PS/P KS/P AOB/P) do
        assert {:error, _} = Code.parse(text), text
      end
    end
  end

  # ------------------------------------------------------------------
  # `/P` in an individual Swiss.
  #
  # Event A, two rounds (the forfeit event of tiebreaks_test.exs):
  #
  #   R1: 1 wins by forfeit against 2      3(w) 1-0 4
  #   R2: 1(w) 1-0 3                        2(w) 1-0 4
  #
  #   scores: 1 = 2, 2 = 1, 3 = 1, 4 = 0 (no requested byes, so the
  #   adjusted scores of 16.3 are the scores)
  #
  # Event B, three rounds - the forfeit WINNER finishes below the loser:
  #
  #   R1: 2 wins by forfeit against 1      3(w) 1-0 4
  #   R2: 1(w) 1-0 3                        4(w) 1-0 2
  #   R3: 1(w) 1-0 4                        3(w) 1-0 2
  #
  #   scores: 1 = 2, 2 = 1, 3 = 2, 4 = 1
  # ------------------------------------------------------------------
  defp event_a do
    build(%{
      1 => {2000, [{:w, 2, "+"}, {:w, 3, "1"}]},
      2 => {1900, [{:b, 1, "-"}, {:w, 4, "1"}]},
      3 => {1800, [{:w, 4, "1"}, {:b, 1, "0"}]},
      4 => {1700, [{:b, 3, "0"}, {:b, 2, "0"}]}
    })
  end

  defp event_b do
    build(%{
      1 => {2000, [{:b, 2, "-"}, {:w, 3, "1"}, {:w, 4, "1"}]},
      2 => {1900, [{:w, 1, "+"}, {:b, 4, "0"}, {:b, 3, "0"}]},
      3 => {1800, [{:w, 4, "1"}, {:b, 1, "0"}, {:w, 2, "1"}]},
      4 => {1700, [{:b, 3, "0"}, {:w, 2, "1"}, {:b, 1, "0"}]}
    })
  end

  defp values(event, code) do
    {:ok, all} = Tiebreaks.compute(event, [code])
    all[code]
  end

  describe "BH/P" do
    test "a forfeit counts the scheduled opponent's score, not 16.4.1's capped dummy" do
      # A, player 2. BH: R1 dummy = min(own 1, adjusted(1) = 2) = 1, R2 4 = 0
      #   -> 1. BH/P: R1 opponent 1 = 2, R2 0 -> 2.
      # A, player 1. BH: R1 min(2, 1) = 1, R2 3 = 1 -> 2. BH/P: 1 + 1 = 2.
      assert values(event_a(), "BH")[2] == 1.0
      assert values(event_a(), "BH/P") == %{1 => 2.0, 2 => 2.0, 3 => 2.0, 4 => 2.0}
      # (3: 4 + 1 = 0 + 2; 4: 3 + 2 = 1 + 1 - nobody else had a forfeit.)
    end

    test "the forfeit is no longer a VUR, so 16.5 does not pick it for the cut" do
      # A, player 2. BH/C1: contributions {1 (VUR), 0}; 16.5.2 cuts the VUR
      #   -> 0. BH/C1/P: {2, 0}, no VUR; the lowest goes -> 2.
      assert values(event_a(), "BH/C1")[2] == 0.0
      assert values(event_a(), "BH/C1/P")[2] == 2.0
    end

    test "the forfeit winner gets the loser's full score" do
      # B, player 2. BH: R1 min(own 1, adjusted(1) = 2) = 1, R2 4 = 1,
      #   R3 3 = 2 -> 4. BH/P: 2 + 1 + 2 = 5.
      # B, player 1. BH: R1 min(own 2, adjusted(2) = 1) = 1, R2 3 = 2,
      #   R3 4 = 1 -> 4. BH/P: 1 + 2 + 1 = 4 - the cap did not bind.
      assert values(event_b(), "BH")[2] == 4.0
      assert values(event_b(), "BH/P")[2] == 5.0
      assert values(event_b(), "BH/P")[1] == 4.0
    end

    test "cuts and medians apply to what /P leaves" do
      # B, player 2 under /P: {2, 1, 2}.
      #   C1 -> 2 + 2 = 4; C2 -> 2; M1 -> drop 1 and a 2 -> 2; M2 -> 0.
      assert values(event_b(), "BH/C1/P")[2] == 4.0
      assert values(event_b(), "BH/C2/P")[2] == 2.0
      assert values(event_b(), "BH/M1/P")[2] == 2.0
      assert values(event_b(), "BH/M2/P")[2] == 0.0
      # Without /P, {1, 1, 2}: C1 -> 3 (no VUR: a forfeit WIN is not one).
      assert values(event_b(), "BH/C1")[2] == 3.0
    end
  end

  describe "SB/P" do
    test "the points scored against the forfeit opponent are weighted by their real score" do
      # B, player 2. SB: R1 1 point x dummy 1 = 1, R2 0 x 1, R3 0 x 2 -> 1.
      #   SB/P: 1 x 2 = 2, then 0, 0 -> 2.
      # B, player 1. SB: R1 0 x 1, R2 1 x 2, R3 1 x 1 -> 3. SB/P the same.
      assert values(event_b(), "SB")[2] == 1.0
      assert values(event_b(), "SB/P")[2] == 2.0
      assert values(event_b(), "SB/P")[1] == 3.0
    end

    test "cuts go by the opponents' scores (14.1.2 d)" do
      # B, player 2 under /P, {opponent score, product}: R1 {2, 2},
      # R2 {1, 0}, R3 {2, 0}. C1 cuts R2 (lowest opponent) -> 2. C2 then
      # cuts the lower of the two on 2, R3's 0 -> 2.
      # Without /P: R1 {1, 1}, R2 {1, 0}, R3 {2, 0}; C1 cuts the lower of
      # the two on 1, R2's 0 -> 1.
      assert values(event_b(), "SB/C1")[2] == 1.0
      assert values(event_b(), "SB/C1/P")[2] == 2.0
      assert values(event_b(), "SB/C2/P")[2] == 2.0
    end
  end

  describe "FB/P" do
    test "the forfeit is a game in the Fore Buchholz event too" do
      # A with its final round drawn (8.3): 1-3 and 2-4 become draws.
      # Fore scores: 1 = 1.5, 2 = 0.5, 3 = 1.5, 4 = 0.5.
      # Player 2. FB: R1 dummy min(own 0.5, 1's 1.5) = 0.5, R2 4 = 0.5
      #   -> 1. FB/P: 1.5 + 0.5 = 2.
      # Player 1. FB: R1 min(1.5, 0.5) = 0.5, R2 3 = 1.5 -> 2. FB/P: 2.
      assert values(event_a(), "FB")[2] == 1.0
      assert values(event_a(), "FB/P")[2] == 2.0
      assert values(event_a(), "FB/P")[1] == 2.0
      # Cut-1 of {1.5, 0.5} -> 1.5, and M1 of two elements leaves nothing.
      assert values(event_a(), "FB/C1/P")[2] == 1.5
      assert values(event_a(), "FB/M1/P")[2] == 0.0
    end
  end

  test "/P changes nothing when the pairings were fixed in advance (15.2 already counts forfeits)" do
    rr =
      build(
        %{
          1 => {2000, [{:w, 2, "+"}, {:b, 3, "1"}, {:w, 4, "1"}]},
          2 => {1900, [{:b, 1, "-"}, {:w, 4, "1"}, {:w, 3, "="}]},
          3 => {1800, [{:b, 4, "="}, {:w, 1, "0"}, {:b, 2, "="}]},
          4 => {1700, [{:w, 3, "="}, {:b, 2, "0"}, {:b, 1, "0"}]}
        },
        predetermined?: true
      )

    assert values(rr, "SB/P") == values(rr, "SB")
    assert values(rr, "SB/C1/P") == values(rr, "SB/C1")
  end

  # ------------------------------------------------------------------
  # `/P` and `/K` for teams. Four teams, two boards, three rounds of a
  # Swiss - event B again, as teams:
  #
  #   R1: 2 wins by forfeit against 1 (2-0)    3 2-0 4
  #   R2: 1 1½-½ 3                              4 2-0 2
  #   R3: 1 2-0 4                               3 1½-½ 2
  #
  #   MP: 1 = 4, 2 = 2, 3 = 4, 4 = 2
  #   GP: 1 = 0 + 1.5 + 2 = 3.5     2 = 2 + 0 + 0.5 = 2.5
  #       3 = 2 + 0.5 + 1.5 = 4     4 = 0 + 2 + 0 = 2
  # ------------------------------------------------------------------
  defp played(opponent, mp, gp), do: %Match{kind: :played, opponent: opponent, mp: mp, gp: gp}

  defp teams do
    rounds = %{
      1 => [
        %Match{kind: :forfeit_loss, opponent: 2, mp: 0.0, gp: 0.0},
        played(3, 2.0, 1.5),
        played(4, 2.0, 2.0)
      ],
      2 => [
        %Match{kind: :forfeit_win, opponent: 1, mp: 2.0, gp: 2.0},
        played(4, 0.0, 0.0),
        played(3, 0.0, 0.5)
      ],
      3 => [played(4, 2.0, 2.0), played(1, 0.0, 0.5), played(2, 2.0, 1.5)],
      4 => [played(3, 0.0, 0.0), played(2, 2.0, 2.0), played(1, 0.0, 0.0)]
    }

    entries =
      for {id, list} <- rounds do
        %Entry{
          id: id,
          tpn: id,
          rounds: list |> Enum.with_index(1) |> Map.new(fn {m, r} -> {r, m} end)
        }
      end

    Team.new(entries, 3, boards: 2)
  end

  describe "team codes with /P" do
    test "the scores are as drawn" do
      assert values(teams(), "MPTS") == %{1 => 4.0, 2 => 2.0, 3 => 4.0, 4 => 2.0}
      assert values(teams(), "GPTS") == %{1 => 3.5, 2 => 2.5, 3 => 4.0, 4 => 2.0}
    end

    test "BH:MP/P and BH:GP/P" do
      # Team 2. BH:MP: R1 dummy min(own 2, 1's 4) = 2, R2 4 = 2, R3 3 = 4
      #   -> 8. BH:MP/P: 4 + 2 + 4 = 10.
      # Team 2. BH:GP: R1 min(2.5, 3.5) = 2.5, R2 2, R3 4 -> 8.5.
      #   BH:GP/P: 3.5 + 2 + 4 = 9.5.
      assert values(teams(), "BH:MP")[2] == 8.0
      assert values(teams(), "BH:MP/P")[2] == 10.0
      assert values(teams(), "BH:GP")[2] == 8.5
      assert values(teams(), "BH:GP/P")[2] == 9.5
      # BH:MP/C1/P: {4, 2, 4} -> 8.
      assert values(teams(), "BH:MP/C1/P")[2] == 8.0
    end

    test "the extended Sonneborn-Bergers (13.2)" do
      # Team 2, {opponent's total, scored}:
      #   EMMSB:  R1 dummy 2 x 2 MP = 4, R2 2 x 0, R3 4 x 0      -> 4
      #   EMMSB/P: R1 4 x 2 = 8                                    -> 8
      #   EMGSB:  R1 2 x 2 GP = 4, R2 2 x 0, R3 4 x 0.5 = 2        -> 6
      #   EMGSB/P: R1 4 x 2 = 8                                    -> 10
      #   EGMSB:  R1 dummy min(2.5, 3.5) = 2.5 x 2 MP = 5, R2 2 x 0,
      #           R3 4 x 0                                         -> 5
      #   EGMSB/P: R1 3.5 x 2 = 7                                  -> 7
      #   EGGSB:  R1 2.5 x 2 GP = 5, R2 2 x 0, R3 4 x 0.5 = 2      -> 7
      #   EGGSB/P: R1 3.5 x 2 = 7                                  -> 9
      assert values(teams(), "EMMSB")[2] == 4.0
      assert values(teams(), "EMMSB/P")[2] == 8.0
      assert values(teams(), "EMGSB")[2] == 6.0
      assert values(teams(), "EMGSB/P")[2] == 10.0
      assert values(teams(), "EGMSB")[2] == 5.0
      assert values(teams(), "EGMSB/P")[2] == 7.0
      assert values(teams(), "EGGSB")[2] == 7.0
      assert values(teams(), "EGGSB/P")[2] == 9.0
      # EMGSB/C1/P, by the opponents' MP (14.1's team paragraph): {4, 8},
      # {2, 0}, {4, 2} - cut team 4's 0 -> 10. C2 then cuts the lower of
      # the two on 4 MP, R3's 2 -> 8.
      assert values(teams(), "EMGSB/C1/P")[2] == 10.0
      assert values(teams(), "EMGSB/C2/P")[2] == 8.0
    end
  end

  describe "SSSC (13.4) with /P and /K" do
    # The normalising factor: highest primary 3 rounds x 2 MP = 6, over the
    # highest secondary in one match, 2 boards x 1 GP = 2 -> 3.
    # BH:MP: 1 = R1 dummy min(4, 2's 2) = 2 + 3's 4 + 4's 2 = 8
    #        2 = 8 (above)   3 = 2 + 4 + 2 = 8   4 = 4 + 2 + 4 = 10
    test "plain: GP + BH:MP / 3" do
      sssc = values(teams(), "SSSC")
      assert_in_delta sssc[1], 3.5 + 8 / 3, 1.0e-9
      assert_in_delta sssc[2], 2.5 + 8 / 3, 1.0e-9
      assert_in_delta sssc[4], 2.0 + 10 / 3, 1.0e-9
    end

    test "/P counts the forfeit in the Buchholz" do
      # Team 2: 2.5 + 10 / 3. Team 1's BH:MP/P is 2 + 4 + 2 = 8 still.
      sssc = values(teams(), "SSSC/P")
      assert_in_delta sssc[2], 2.5 + 10 / 3, 1.0e-9
      assert_in_delta sssc[1], 3.5 + 8 / 3, 1.0e-9
    end

    test "/K<n> replaces the factor" do
      # K4: 1 = 3.5 + 8/4 = 5.5   2 = 2.5 + 2 = 4.5   3 = 4 + 2 = 6
      #     4 = 2 + 10/4 = 4.5
      assert values(teams(), "SSSC/K4") == %{1 => 5.5, 2 => 4.5, 3 => 6.0, 4 => 4.5}
      # K5: 4 = 2 + 10/5 = 4
      assert values(teams(), "SSSC/K5")[4] == 4.0
      # P and K together: team 2 = 2.5 + 10/4 = 5.
      assert values(teams(), "SSSC/P/K4")[2] == 5.0
    end

    test "/F/P/K<n>: Fore Buchholz, forfeits as games, the stated factor" do
      # The final round drawn: every team ends on 3 MP (1: 0+2+1,
      # 2: 2+0+1, 3: 2+0+1, 4: 0+2+1). Team 2's FB:MP/P is 3 + 3 + 3 = 9,
      # over 5, plus its real 2.5 GP -> 4.3. Team 1's the same 9 -> 5.3.
      sssc = values(teams(), "SSSC/F/P/K5")
      assert_in_delta sssc[2], 4.3, 1.0e-9
      assert_in_delta sssc[1], 5.3, 1.0e-9
    end
  end

  # ------------------------------------------------------------------
  # The standalone CLI takes the same codes (every engine option works
  # without OpenPairings too).
  # ------------------------------------------------------------------
  defp cli(args) do
    ref = make_ref()

    out =
      capture_io(fn ->
        capture_io(:stderr, fn -> Process.put(ref, CLI.run(args)) end) |> IO.write()
      end)

    {out, Process.get(ref)}
  end

  # A scratch directory outside the checkout; ExUnit's :tmp_dir would
  # leave one in it.
  defp scratch do
    dir =
      Path.join(System.tmp_dir!(), "ainalrami_mandatory_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp header(out), do: out |> String.split(~r/\r?\n/, trim: true) |> hd() |> String.split()

  test "ainalrami -s --tie-breaks= takes the new individual variants" do
    dir = scratch()

    {text, _} =
      Generator.generate(seed: 4242, players: 14, rounds: 5, forfeit_pct: 15)

    path = Path.join(dir, "individual.trf")
    File.write!(path, text)
    codes = ~w(BH/P BH/C1/P BH/M2/P SB/C2/P FB/M1/P)

    {out, 0} = cli([path, "-s", "-q", "--tie-breaks=#{Enum.join(codes, ",")}"])
    assert header(out) == ["RANK", "ID", "PTS" | codes]

    {:ok, rows} =
      text |> Trf.parse() |> Tiebreaks.Event.from_trf() |> Tiebreaks.rank(["PTS" | codes])

    ids =
      out
      |> String.split(~r/\r?\n/, trim: true)
      |> tl()
      |> Enum.map(&(&1 |> String.split() |> Enum.at(1) |> String.to_integer()))

    assert ids == Enum.map(rows, & &1.id)
  end

  test "ainalrami -s --tie-breaks= takes the new team variants" do
    dir = scratch()

    {text, _} =
      TeamGenerator.generate(
        system: :swiss,
        seed: 4243,
        teams: 8,
        rounds: 4,
        tie_breaks: ["MPTS"]
      )

    path = Path.join(dir, "team.trf")
    File.write!(path, text)
    codes = ~w(BH:MP/C1/P EMGSB/C1/P EGGSB/P SSSC/P/K4 SSSC/F/P/K5)

    {out, 0} = cli([path, "-s", "-q", "--tie-breaks=#{Enum.join(codes, ",")}"])
    assert header(out) == ["RANK", "ID", "PTS" | codes]
  end

  test "--tie-breaks= still refuses what the table does not list" do
    dir = scratch()
    {text, _} = Generator.generate(seed: 4244, players: 8, rounds: 3)
    path = Path.join(dir, "refuse.trf")
    File.write!(path, text)

    {out, code} = cli([path, "-s", "-q", "--tie-breaks=BH/K4"])
    assert code != 0
    assert out =~ "BH/K4"
  end
end
