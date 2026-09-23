defmodule Ainalrami.Tiebreaks.Rating do
  @moduledoc """
  The rating arithmetic behind C.07 Article 10: FIDE's two conversion
  tables, and ARO, TPR and PTP over a list of opponent ratings.

  ## The tables

  Both are from the FIDE Rating Regulations (B.02, Article 8.1): score
  fraction to rating difference (`dp`, the same table as the title
  regulations' B.01 1.4.9) and rating difference to expected score. They are
  kept here in the handbook's own shape - `dp` per whole percent, expected
  score per rating-difference band - and checked against each other in the
  tests (`dp` antisymmetric around 50%, expected score symmetric around 0).
  OpenPairings holds copies of both, transcribed independently
  (`PairingsEngine.Norms.TitleNorms`, `PairingsEngine.PlayerStats`), and
  TieBreakServer holds a third (`fidetables.py`); the tests diff the first
  against a literal transcription, and the validation run diffs results
  against TieBreakServer.

  ## Rounding

  "Rounded to the nearest whole number (0.5 rounded up)" (10.1, 10.4, 10.5)
  is `round_half_up/1`, not `Kernel.round/1` - which rounds half away from
  zero, the same for positive numbers, and `Float.round/1` - which is
  banker's rounding in some Erlang versions and is exactly the thing not to
  trust for a tie-break. TPR's score percentage is rounded the same way
  before the table lookup (docs/conformance-c07-tiebreaks.md, "Ratings").
  """

  # p (whole percent, 0..100) -> dp. The handbook lists 100..50; 49..0 are
  # its negation, which is how the handbook prints them too.
  @dp_upper %{
    100 => 800,
    99 => 677,
    98 => 589,
    97 => 538,
    96 => 501,
    95 => 470,
    94 => 444,
    93 => 422,
    92 => 401,
    91 => 383,
    90 => 366,
    89 => 351,
    88 => 336,
    87 => 322,
    86 => 309,
    85 => 296,
    84 => 284,
    83 => 273,
    82 => 262,
    81 => 251,
    80 => 240,
    79 => 230,
    78 => 220,
    77 => 211,
    76 => 202,
    75 => 193,
    74 => 184,
    73 => 175,
    72 => 166,
    71 => 158,
    70 => 149,
    69 => 141,
    68 => 133,
    67 => 125,
    66 => 117,
    65 => 110,
    64 => 102,
    63 => 95,
    62 => 87,
    61 => 80,
    60 => 72,
    59 => 65,
    58 => 57,
    57 => 50,
    56 => 43,
    55 => 36,
    54 => 29,
    53 => 21,
    52 => 14,
    51 => 7,
    50 => 0
  }

  @dp Map.merge(@dp_upper, Map.new(@dp_upper, fn {p, dp} -> {100 - p, -dp} end))

  # Rating difference bands -> the higher-rated side's expected score, as
  # the handbook tables them: {highest difference in the band, score}. A
  # difference above 735 scores 1.00 - the "full rating scale" PTP asks for
  # (10.3); only the rating regulations' own use caps it at 400.
  @expected_bands [
    {3, 0.50},
    {10, 0.51},
    {17, 0.52},
    {25, 0.53},
    {32, 0.54},
    {39, 0.55},
    {46, 0.56},
    {53, 0.57},
    {61, 0.58},
    {68, 0.59},
    {76, 0.60},
    {83, 0.61},
    {91, 0.62},
    {98, 0.63},
    {106, 0.64},
    {113, 0.65},
    {121, 0.66},
    {129, 0.67},
    {137, 0.68},
    {145, 0.69},
    {153, 0.70},
    {162, 0.71},
    {170, 0.72},
    {179, 0.73},
    {188, 0.74},
    {197, 0.75},
    {206, 0.76},
    {215, 0.77},
    {225, 0.78},
    {235, 0.79},
    {245, 0.80},
    {256, 0.81},
    {267, 0.82},
    {278, 0.83},
    {290, 0.84},
    {302, 0.85},
    {315, 0.86},
    {328, 0.87},
    {344, 0.88},
    {357, 0.89},
    {374, 0.90},
    {391, 0.91},
    {411, 0.92},
    {432, 0.93},
    {456, 0.94},
    {484, 0.95},
    {517, 0.96},
    {559, 0.97},
    {619, 0.98},
    {735, 0.99}
  ]

  # Expected score in hundredths, indexed by |difference| 0..736, so the
  # PTP search - which asks for it thousands of times - is a tuple lookup.
  @expected_hundredths (for d <- 0..736 do
                          case Enum.find(@expected_bands, fn {upper, _} -> d <= upper end) do
                            {_upper, p} -> round(p * 100)
                            nil -> 100
                          end
                        end)
                       |> List.to_tuple()

  @doc "The dp table: score percentage (0..100) to rating difference."
  def dp(percent) when percent in 0..100, do: Map.fetch!(@dp, percent)

  @doc """
  Expected score, in hundredths, of a player rated `own` against one rated
  `opponent`, on the full scale (no 400 cap).
  """
  def expected_hundredths(own, opponent) do
    diff = own - opponent
    p = elem(@expected_hundredths, min(abs(diff), 736))
    if diff >= 0, do: p, else: 100 - p
  end

  @doc "Half up, as C.07 10.1 says: 1.5 -> 2, 2.5 -> 3, -1.5 -> -1."
  def round_half_up(x), do: floor(x + 0.5)

  @doc """
  ARO: the average of `ratings`, rounded half up. `nil` for no games.
  """
  def aro([]), do: nil
  def aro(ratings), do: round_half_up(Enum.sum(ratings) / length(ratings))

  @doc """
  TPR (10.2): ARO plus the dp of the score percentage. `score` is in games
  (a win 1, a draw ½), not in the event's tournament points.
  """
  def tpr([], _score), do: nil

  def tpr(ratings, score) do
    percent = round_half_up(score * 100 / length(ratings)) |> max(0) |> min(100)
    aro(ratings) + dp(percent)
  end

  @doc """
  PTP (10.3): the lowest whole rating whose expected score against
  `ratings` is at least `score`; 800 below the lowest opponent for a zero
  score. `score` is in games, as for `tpr/2`.
  """
  def ptp([], _score), do: nil
  def ptp(ratings, score) when score <= 0, do: Enum.min(ratings) - 800

  def ptp(ratings, score) do
    # Work in hundredths so the comparison is exact.
    target = round(score * 100)

    # Enough: at max+736 every game is expected at 1.00, and a score above
    # the number of games cannot be reached at any rating.
    low = Enum.min(ratings) - 800
    high = Enum.max(ratings) + 736

    if expected_sum(high, ratings) < target, do: high, else: search(low, high, ratings, target)
  end

  # Invariant: expected(low) < target <= expected(high). The expected sum
  # never falls as the rating rises, so the answer is the first rating
  # where it reaches the target.
  defp search(low, high, ratings, target) do
    cond do
      expected_sum(low, ratings) >= target ->
        low

      high - low <= 1 ->
        high

      true ->
        mid = div(low + high, 2)

        if expected_sum(mid, ratings) >= target,
          do: search(low, mid, ratings, target),
          else: search(mid, high, ratings, target)
    end
  end

  defp expected_sum(own, ratings),
    do: Enum.reduce(ratings, 0, &(expected_hundredths(own, &1) + &2))
end
