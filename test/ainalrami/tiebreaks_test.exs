defmodule Ainalrami.TiebreaksTest do
  @moduledoc """
  C.07 tie-breaks against hand-worked tournaments. Every expected value is
  worked out in the comment next to it from the article it tests - the
  tournaments are small on purpose, so the arithmetic can be checked by
  reading rather than trusted.
  """
  use ExUnit.Case, async: true

  import Ainalrami.Test.TiebreakEvent

  alias Ainalrami.Tiebreaks
  alias Ainalrami.Tiebreaks.{Code, DirectEncounter, Rating}

  defp values(event, code) do
    {:ok, all} = Tiebreaks.compute(event, [code])
    all[code]
  end

  # ------------------------------------------------------------------
  # A four-player Swiss, three rounds, every game played.
  #
  #   R1: 1(w) 1-0 2     3(w) =-= 4
  #   R2: 3(w) =-= 1     2(w) 1-0 4
  #   R3: 1(w) 1-0 4     3(w) 1-0 2
  #
  #   scores: 1 = 2.5, 2 = 1, 3 = 2, 4 = 0.5
  # ------------------------------------------------------------------
  defp swiss do
    build(%{
      1 => {2000, [{:w, 2, "1"}, {:b, 3, "="}, {:w, 4, "1"}]},
      2 => {1900, [{:b, 1, "0"}, {:w, 4, "1"}, {:b, 3, "0"}]},
      3 => {1800, [{:w, 4, "="}, {:w, 1, "="}, {:w, 2, "1"}]},
      4 => {1700, [{:b, 3, "="}, {:b, 2, "0"}, {:b, 1, "0"}]}
    })
  end

  describe "a plain Swiss" do
    test "PTS is the score" do
      assert values(swiss(), "PTS") == %{1 => 2.5, 2 => 1.0, 3 => 2.0, 4 => 0.5}
    end

    test "BH (8.1) sums the opponents' scores" do
      # 1: 2 + 3 + 4 = 1 + 2 + 0.5     2: 1 + 4 + 3 = 2.5 + 0.5 + 2
      # 3: 4 + 1 + 2 = 0.5 + 2.5 + 1   4: 3 + 2 + 1 = 2 + 1 + 2.5
      assert values(swiss(), "BH") == %{1 => 3.5, 2 => 5.0, 3 => 4.0, 4 => 5.5}
    end

    test "BH/C1 (14.1) drops the lowest contribution; nobody has a VUR" do
      assert values(swiss(), "BH/C1") == %{1 => 3.0, 2 => 4.5, 3 => 3.5, 4 => 4.5}
    end

    test "BH/M1 (14.3) drops the lowest and then the highest" do
      # 1: {1, 2, 0.5} -> 1     2: {2.5, 0.5, 2} -> 2
      # 3: {0.5, 2.5, 1} -> 1   4: {2, 1, 2.5} -> 2
      assert values(swiss(), "BH/M1") == %{1 => 1.0, 2 => 2.0, 3 => 1.0, 4 => 2.0}
    end

    test "SB (9.1) weights each opponent's score by the points taken from them" do
      # 1: 1x1 + 0.5x2 + 1x0.5 = 2.5     2: 0 + 1x0.5 + 0 = 0.5
      # 3: 0.5x0.5 + 0.5x2.5 + 1x1 = 2.5 4: 0.5x2 + 0 + 0 = 1
      assert values(swiss(), "SB") == %{1 => 2.5, 2 => 0.5, 3 => 2.5, 4 => 1.0}
    end

    test "PS (7.5) sums the running scores; PS/C1 drops the first" do
      # 1: 1 + 1.5 + 2.5   2: 0 + 1 + 1   3: 0.5 + 1 + 2   4: 0.5 x 3
      assert values(swiss(), "PS") == %{1 => 5.0, 2 => 2.0, 3 => 3.5, 4 => 1.5}
      assert values(swiss(), "PS/C1") == %{1 => 4.0, 2 => 2.0, 3 => 3.0, 4 => 1.0}
    end

    test "WIN, WON, BPG, BWG (7.1-7.4)" do
      assert values(swiss(), "WIN") == %{1 => 2, 2 => 1, 3 => 1, 4 => 0}
      assert values(swiss(), "WON") == %{1 => 2, 2 => 1, 3 => 1, 4 => 0}
      # black: 1 in R2; 2 in R1 and R3; 3 never; 4 always
      assert values(swiss(), "BPG") == %{1 => 1, 2 => 2, 3 => 0, 4 => 3}
      assert values(swiss(), "BWG") == %{1 => 0, 2 => 0, 3 => 0, 4 => 0}
    end

    test "STD (7.7) is the score under 1/0.5/0 when every round is a game" do
      assert values(swiss(), "STD") == %{1 => 2.5, 2 => 1.0, 3 => 2.0, 4 => 0.5}
    end

    test "REP (7.6) is every round when nobody missed one" do
      assert values(swiss(), "REP") == %{1 => 3, 2 => 3, 3 => 3, 4 => 3}
    end

    test "ARO (10.1) averages the opponents' ratings, half up" do
      # 1: (1900+1800+1700)/3 = 1800        2: (2000+1700+1800)/3 = 1833.3
      # 3: (1700+2000+1900)/3 = 1866.7      4: (1800+1900+2000)/3 = 1900
      assert values(swiss(), "ARO") == %{1 => 1800, 2 => 1833, 3 => 1867, 4 => 1900}
    end

    test "TPR (10.2) is ARO plus dp of the score percentage" do
      # 1: 2.5/3 = 83.3% -> 83 -> +273 = 2073
      # 4: 0.5/3 = 16.7% -> 17 -> -273 = 1627
      tpr = values(swiss(), "TPR")
      assert tpr[1] == 2073
      assert tpr[4] == 1627
    end

    test "the standings follow the score, then the list" do
      {:ok, standings} = Tiebreaks.rank(swiss(), ~w(BH/C1 BH SB))
      assert Enum.map(standings, &{&1.id, &1.rank}) == [{1, 1}, {3, 2}, {2, 3}, {4, 4}]
      assert hd(standings).values["BH/C1"] == 3.0
    end
  end

  # ------------------------------------------------------------------
  # Article 16: player 4 withdraws after round 1; odd field, so byes.
  #
  #   R1: 1(w) 1-0 4     2(w) =-= 3
  #   R2: 1(w) 1-0 2     3 pairing-allocated bye     4 gone (zero bye)
  #   R3: 1(b) =-= 3     2 pairing-allocated bye     4 gone (zero bye)
  #
  #   scores: 1 = 2.5, 2 = 1.5, 3 = 2, 4 = 0
  # ------------------------------------------------------------------
  defp withdrawal do
    build(%{
      1 => {2000, [{:w, 4, "1"}, {:w, 2, "1"}, {:b, 3, "="}]},
      2 => {1900, [{:w, 3, "="}, {:b, 1, "0"}, :pab]},
      3 => {1800, [{:b, 2, "="}, :pab, {:w, 1, "="}]},
      4 => {1700, [{:b, 1, "0"}, :zero, :zero]}
    })
  end

  describe "unplayed rounds in a Swiss (Article 16)" do
    test "a withdrawn player's trailing zero-point byes count as draws for their opponents" do
      # 4's rounds 2-3 are requested byes followed only by VURs (16.2.5),
      # so to 1 (who played them) 4 is worth 0 + 0.5 + 0.5 = 1 (16.3.2).
      # BH(1) = 1 (4, adjusted) + 1.5 (2) + 2 (3) = 4.5
      assert values(withdrawal(), "BH")[1] == 4.5
    end

    test "a pairing-allocated bye is a game against a dummy capped at a draw per round" do
      # 3: R1 opponent 2 = 1.5; R2 bye: dummy = min(own 2, 0.5 x 3) = 1.5
      # (16.4.2); R3 opponent 1 = 2.5.  BH = 5.5
      assert values(withdrawal(), "BH")[3] == 5.5
      # 2: R1 opponent 3 = 2; R2 opponent 1 = 2.5; R3 bye: min(1.5, 1.5)
      assert values(withdrawal(), "BH")[2] == 6.0
    end

    test "the withdrawn player's own dummies score their own score (zero)" do
      # 4: R1 opponent 1 = 2.5; R2, R3 dummies = min(own 0, 1.5) = 0
      assert values(withdrawal(), "BH")[4] == 2.5
    end

    test "SB counts the dummy times the points the bye was worth" do
      # 3: 1.5 x 0.5 (draw with 2) + 1.5 x 1 (bye dummy) + 2.5 x 0.5 = 3.5
      assert values(withdrawal(), "SB")[3] == 3.5
    end

    test "BH/C1 with two equal lowest contributions drops just one" do
      # 3: {1.5, 1.5, 2.5}, no VUR -> 4.0
      assert values(withdrawal(), "BH/C1")[3] == 4.0
    end

    test "REP (7.6) takes the zero-point byes off" do
      assert values(withdrawal(), "REP") == %{1 => 3, 2 => 3, 3 => 3, 4 => 1}
    end

    test "WIN (7.1) counts a win's points without playing" do
      assert values(withdrawal(), "WIN") == %{1 => 2, 2 => 1, 3 => 1, 4 => 0}
      assert values(withdrawal(), "WON") == %{1 => 2, 2 => 0, 3 => 0, 4 => 0}
    end

    test "STD (7.7): a bye worth more than a draw is a full point" do
      # 2: R1 draw 0.5, R2 lost 0, R3 bye (1 > draw) 1 -> 1.5
      assert values(withdrawal(), "STD")[2] == 1.5
    end
  end

  # ------------------------------------------------------------------
  # Forfeits (16.2.2, 16.2.4, 16.4.1) and the Cut-1 exception (16.5).
  #
  #   R1: 1 wins by forfeit against 2      3(w) 1-0 4
  #   R2: 1(w) 1-0 3                        2(w) 1-0 4
  #
  #   scores: 1 = 2, 2 = 1, 3 = 1, 4 = 0
  # ------------------------------------------------------------------
  defp forfeit do
    build(%{
      1 => {2000, [{:w, 2, "+"}, {:w, 3, "1"}]},
      2 => {1900, [{:b, 1, "-"}, {:w, 4, "1"}]},
      3 => {1800, [{:w, 4, "1"}, {:b, 1, "0"}]},
      4 => {1700, [{:b, 3, "0"}, {:b, 2, "0"}]}
    })
  end

  describe "forfeits" do
    test "a forfeit's dummy is capped at the scheduled opponent's adjusted score" do
      # 1, R1: min(own 2, adjusted(2) = 1) = 1; R2: 3 scored 1.  BH = 2
      assert values(forfeit(), "BH")[1] == 2.0
      # 2, R1: min(own 1, adjusted(1) = 2) = 1; R2: 4 scored 0.  BH = 1
      assert values(forfeit(), "BH")[2] == 1.0
    end

    test "Cut-1 removes the VUR's contribution, not the lowest (16.5.2)" do
      # 2's contributions are {1 (forfeit loss, a VUR), 0}. Plain Cut-1
      # would leave 1; 16.5 cuts the VUR's 1 and leaves 0.
      assert values(forfeit(), "BH/C1")[2] == 0.0
    end

    test "a forfeit is not a game for WON, BPG or the rating averages" do
      assert values(forfeit(), "WON")[1] == 1
      assert values(forfeit(), "ARO")[1] == 1800
    end

    test "REP (7.6) takes the forfeit loss off" do
      assert values(forfeit(), "REP")[2] == 1
    end
  end

  # ------------------------------------------------------------------
  # A round robin (pairings fixed in advance, Article 15.2).
  #
  #   1 beats 2 and 4, loses to 3          -> 2
  #   2 beats 3 and 4                       -> 2
  #   3 beats 1, loses to 2, draws with 4   -> 1.5
  #   4 draws with 3                        -> 0.5
  # ------------------------------------------------------------------
  defp round_robin do
    build(
      %{
        1 => {2000, [{:w, 2, "1"}, {:b, 3, "0"}, {:w, 4, "1"}]},
        2 => {1900, [{:b, 1, "0"}, {:w, 4, "1"}, {:w, 3, "1"}]},
        3 => {1800, [{:b, 4, "="}, {:w, 1, "1"}, {:b, 2, "0"}]},
        4 => {1700, [{:w, 3, "="}, {:b, 2, "0"}, {:b, 1, "0"}]}
      },
      predetermined?: true
    )
  end

  describe "a round robin" do
    test "Buchholz-type tie-breaks are refused (Article 8)" do
      assert {:error, message} = Tiebreaks.rank(round_robin(), ~w(BH))
      assert message =~ "round robins"
      assert {:error, _} = Tiebreaks.rank(round_robin(), ~w(AOB))
    end

    test "Koya (9.2) counts points against those on at least half the maximum" do
      # half of 3 = 1.5: opponents 1, 2 and 3 qualify.
      # 1: 1 (vs 2) + 0 (vs 3)   2: 0 + 1   3: 1 + 0   4: 0.5 (vs 3)
      assert values(round_robin(), "KS") == %{1 => 1.0, 2 => 1.0, 3 => 1.0, 4 => 0.5}
    end

    test "KS/L1 raises the limit by half a point (14.5)" do
      # limit 2.0: only 1 and 2 qualify.
      assert values(round_robin(), "KS/L1") == %{1 => 1.0, 2 => 0.0, 3 => 1.0, 4 => 0.0}
    end

    test "KS/L-1 lowers it by half a point" do
      # limit 1.0: 1, 2 and 3 - the same as 50% here.
      assert values(round_robin(), "KS/L-1") == values(round_robin(), "KS")
    end

    test "SB counts every game" do
      # 1: 2 x 1 + 0.5 x 1 (beat 4) = 2.5     2: 1.5 (beat 3) + 0.5 (beat 4) = 2
      sb = values(round_robin(), "SB")
      assert sb[1] == 2.5
      assert sb[2] == 2.0
    end

    test "Koya's maximum leaves out the free round of an odd round robin (reading 10)" do
      # Three players, three rounds: each plays twice and sits out once, so
      # the maximum is 2 and the line is 1 - not 1.5. 1 beat 2 and drew
      # with 3; 2 beat 3: scores 1.5, 1, 0.5, so 1 and 2 qualify.
      #   1: 1 (vs 2) + nothing vs 3 (below the line) = 1
      #   2: 0 (vs 1) + nothing vs 3                   = 0
      #   3: 0.5 (vs 1) + 0 (vs 2)                     = 0.5
      event =
        build(
          %{
            1 => {nil, [{:w, 2, "1"}, {:b, 3, "="}, :zero]},
            2 => {nil, [{:b, 1, "0"}, :zero, {:w, 3, "1"}]},
            3 => {nil, [:zero, {:w, 1, "="}, {:b, 2, "0"}]}
          },
          predetermined?: true
        )

      assert values(event, "KS") == %{1 => 1.0, 2 => 0.0, 3 => 0.5}
    end

    test "Koya counts a forfeit win against a qualifying opponent" do
      # 1 wins by forfeit against 2, who beat 3: 2 has 1 of a maximum 2.
      event =
        build(
          %{
            1 => {nil, [{:w, 2, "+"}, :zero, {:b, 3, "="}]},
            2 => {nil, [{:b, 1, "-"}, {:w, 3, "1"}, :zero]},
            3 => {nil, [:zero, {:b, 2, "0"}, {:w, 1, "="}]}
          },
          predetermined?: true
        )

      assert values(event, "KS")[1] == 1.0
    end

    test "a forfeit win is not a game won over the board, even here (reading 9)" do
      event =
        build(
          %{
            1 => {nil, [{:b, 2, "+"}]},
            2 => {nil, [{:w, 1, "-"}]}
          },
          predetermined?: true
        )

      assert values(event, "WON")[1] == 0
      assert values(event, "BWG")[1] == 0
      assert values(event, "BPG")[1] == 0
      assert values(event, "WIN")[1] == 1
    end

    test "DE separates 1 and 2: 1 won their game (6.2)" do
      {:ok, standings} = Tiebreaks.rank(round_robin(), ~w(DE))
      assert Enum.map(standings, &{&1.id, &1.rank}) == [{1, 1}, {2, 2}, {3, 3}, {4, 4}]
      assert Enum.find(standings, &(&1.id == 2)).values["DE"] == 2
    end
  end

  # ------------------------------------------------------------------
  # Direct encounter in a Swiss where not everybody met (6.3). Only the
  # games inside the tied group matter, so the event holds just those.
  # ------------------------------------------------------------------
  describe "direct encounter (Article 6)" do
    test "someone alone at the top whatever the missing games gives is ranked first" do
      # 1 beat 2 and 3; 2 and 3 never met. 1 has 2 whatever happens;
      # 2 or 3 could reach 1 at most. 2 and 3 have no games between them
      # and stay tied.
      event =
        build(%{
          1 => {nil, [{:w, 2, "1"}, {:w, 3, "1"}]},
          2 => {nil, [{:b, 1, "0"}, :zero]},
          3 => {nil, [:zero, {:b, 1, "0"}]}
        })

      assert DirectEncounter.order([1, 2, 3], Code.parse!("DE"), event) == [[1], [2, 3]]
    end

    test "nobody is ranked when the missing games could still change the top" do
      # 1 beat 2; 3 met neither. 3 could still win both missing games.
      event =
        build(%{
          1 => {nil, [{:w, 2, "1"}, :zero]},
          2 => {nil, [{:b, 1, "0"}, :zero]},
          3 => {nil, [:zero, :zero]}
        })

      assert DirectEncounter.order([1, 2, 3], Code.parse!("DE"), event) == [[1, 2, 3]]
    end

    test "forfeits are left out unless the code says P (6.1.1)" do
      event =
        build(%{
          1 => {nil, [{:w, 2, "+"}]},
          2 => {nil, [{:b, 1, "-"}]}
        })

      assert DirectEncounter.order([1, 2], Code.parse!("DE"), event) == [[1, 2]]
      assert DirectEncounter.order([1, 2], Code.parse!("DE/P"), event) == [[1], [2]]
    end

    test "a pair that met twice adds the average of their games (6.1.2)" do
      # 1 and 2 drew once and 1 won once: 1 scores 0.75, 2 scores 0.25.
      event =
        build(
          %{
            1 => {nil, [{:w, 2, "="}, {:b, 2, "1"}]},
            2 => {nil, [{:b, 1, "="}, {:w, 1, "0"}]}
          },
          predetermined?: true
        )

      assert DirectEncounter.order([1, 2], Code.parse!("DE"), event) == [[1], [2]]
    end
  end

  # ------------------------------------------------------------------
  # Ratings (Article 10)
  # ------------------------------------------------------------------
  describe "rating-based tie-breaks" do
    test "are dropped when unrated players are present and no rating is set for them" do
      event =
        build(%{
          1 => {2000, [{:w, 2, "1"}]},
          2 => {nil, [{:b, 1, "0"}]}
        })

      assert values(event, "ARO") == :dropped
      assert values(event, "ARO/U1400") == %{1 => 1400, 2 => 2000}

      {:ok, _standings, dropped} = Tiebreaks.rank(event, ~w(ARO), with_dropped: true)
      assert dropped == ["ARO"]
    end

    test "PTP (10.3) is the lowest rating whose expected score reaches the score" do
      # 1.5 out of 3 against 2000s: 0.50 each needs a difference within 3,
      # so 1997 is the lowest rating that gets there.
      assert Rating.ptp([2000, 2000, 2000], 1.5) == 1997
      # a zero score: 800 below the lowest opponent.
      assert Rating.ptp([1800, 1900], 0.0) == 1000
    end

    test "APRO (10.4) averages the opponents' TPRs" do
      tpr = values(swiss(), "TPR")
      # 1 met 2, 3 and 4.
      expected = Rating.round_half_up((tpr[2] + tpr[3] + tpr[4]) / 3)
      assert values(swiss(), "APRO")[1] == expected
    end

    test "RTNG (10.6) sorts highest first, RTNG/R lowest first" do
      {:ok, rows} = Tiebreaks.rank(swiss(), ~w(PTS RTNG))
      assert Enum.map(rows, & &1.id) == [1, 3, 2, 4]

      tied =
        build(%{
          1 => {1800, [{:w, 2, "="}]},
          2 => {2000, [{:b, 1, "="}]}
        })

      assert tied |> Tiebreaks.rank(~w(RTNG)) |> elem(1) |> Enum.map(& &1.id) == [2, 1]
      assert tied |> Tiebreaks.rank(~w(RTNG/R)) |> elem(1) |> Enum.map(& &1.id) == [1, 2]
    end

    test "TPN (7.8) sorts lowest first, TPN/R highest first" do
      tied =
        build(%{
          1 => {1800, [{:w, 2, "="}]},
          2 => {2000, [{:b, 1, "="}]}
        })

      assert tied |> Tiebreaks.rank(~w(TPN)) |> elem(1) |> Enum.map(& &1.id) == [1, 2]
      assert tied |> Tiebreaks.rank(~w(TPN/R)) |> elem(1) |> Enum.map(& &1.id) == [2, 1]
    end
  end

  describe "ties" do
    test "participants still level when the list runs out share a rank" do
      tied =
        build(%{
          1 => {1800, [{:w, 2, "="}]},
          2 => {1800, [{:b, 1, "="}]}
        })

      {:ok, rows} = Tiebreaks.rank(tied, ~w(BH))
      assert Enum.map(rows, & &1.rank) == [1, 1]
    end
  end

  describe "the rating tables" do
    test "dp is antisymmetric around 50%" do
      for p <- 0..100, do: assert(Rating.dp(p) == -Rating.dp(100 - p))
      assert Rating.dp(100) == 800
      assert Rating.dp(83) == 273
    end

    test "the expected score is symmetric, and full-scale beyond 400" do
      for d <- 0..800 do
        assert Rating.expected_hundredths(2000 + d, 2000) +
                 Rating.expected_hundredths(2000, 2000 + d) == 100
      end

      # 500 falls in the band ending at 517 (0.96), 700 in the one ending at 735.
      assert Rating.expected_hundredths(2500, 2000) == 96
      assert Rating.expected_hundredths(2700, 2000) == 99
      assert Rating.expected_hundredths(2800, 2000) == 100
    end

    test "rounding is half up" do
      assert Rating.round_half_up(1833.5) == 1834
      assert Rating.round_half_up(1833.49) == 1833
    end
  end
end
