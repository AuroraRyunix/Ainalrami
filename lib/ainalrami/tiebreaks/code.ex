defmodule Ainalrami.Tiebreaks.Code do
  @moduledoc """
  One tie-break as a TRF26 `202`/`212` list writes it: a name, an optional
  score for team events, and modifiers - `BH/C1`, `ARO/M2`, `KS/L-1`,
  `RTNG/R`, `DE/P`, `AOB/F`, `SB:GP/C1`.

  The syntax is the one FIDE's checklist (VCL4THP v13, Q104 and Q199) spells
  its codes in, which is also what TieBreakServer reads. The modifiers and
  the articles behind them are tabled in
  `docs/conformance-c07-tiebreaks.md` ("Code syntax"); the one reading worth
  repeating here is the Koya limit: `L1` moves the 50% threshold UP by one
  half-point and `L-2` down by a whole point, as the checklist spells
  "Koya System (limit=50% + ½) (KS/L1)". `L+1` is accepted as `L1`.

  `parse/1` refuses a name this module does not know rather than carrying
  it along: a tie-break list is a regulation the arbiter published, and a
  misspelt entry silently computing as zero would rank a tournament wrong
  without anybody noticing.
  """

  @enforce_keys [:name]
  defstruct name: nil,
            score: nil,
            cut_low: 0,
            cut_high: 0,
            limit: 0,
            reverse?: false,
            forfeits?: false,
            fore?: false,
            unrated: nil

  @type t :: %__MODULE__{
          name: String.t(),
          score: nil | :mp | :gp,
          cut_low: non_neg_integer(),
          cut_high: non_neg_integer(),
          limit: integer(),
          reverse?: boolean(),
          forfeits?: boolean(),
          fore?: boolean(),
          unrated: nil | non_neg_integer()
        }

  # Individual tie-breaks (Articles 6-10) and the score itself.
  @individual ~w(PTS DE WIN WON BPG BWG PS REP STD TPN BH AOB FB SB KS ARO TPR PTP APRO APPO RTNG)

  # Team tie-breaks (Articles 11-13). `MPTS`/`GPTS` name a primary score.
  @team ~w(MPTS GPTS MPVGP ESB EMMSB EMGSB EGMSB EGGSB EDE EDEBT EDEBB EDET EDEB BC TBR BBE SSSC)

  # Which modifiers each tie-break accepts. A modifier on a tie-break it
  # means nothing for (`WIN/C1`) is refused for the same reason an unknown
  # name is.
  @cuts ~w(PS BH FB SB ARO ESB EMMSB EMGSB EGMSB EGGSB)
  @medians ~w(BH FB ARO)

  @doc "Every name `parse/1` accepts."
  def names, do: @individual ++ @team

  @doc "Whether `name` is a team tie-break."
  def team?(name), do: name in @team

  @doc """
  Parses one code. Returns `{:ok, %Code{}}` or `{:error, reason}`.

      iex> {:ok, code} = Ainalrami.Tiebreaks.Code.parse("BH/C1")
      iex> {code.name, code.cut_low}
      {"BH", 1}

      iex> Ainalrami.Tiebreaks.Code.parse("XYZ")
      {:error, "XYZ is not a tie-break code"}
  """
  def parse(text) when is_binary(text) do
    [head | modifiers] = text |> String.trim() |> String.upcase() |> String.split("/")

    with {:ok, name, score} <- parse_head(head),
         {:ok, code} <- apply_modifiers(%__MODULE__{name: name, score: score}, modifiers) do
      {:ok, code}
    end
  end

  @doc "Like `parse/1` but raises `ArgumentError`."
  def parse!(text) do
    case parse(text) do
      {:ok, code} -> code
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @doc """
  Parses a whole list - a `202`/`212` value split on commas or spaces.
  Returns `{:ok, [%Code{}]}` or the first error.
  """
  def parse_list(codes) when is_list(codes) do
    Enum.reduce_while(codes, {:ok, []}, fn text, {:ok, acc} ->
      case parse(text) do
        {:ok, code} -> {:cont, {:ok, [code | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  def parse_list(text) when is_binary(text) do
    text |> String.split([",", " "], trim: true) |> parse_list()
  end

  @doc """
  The canonical spelling - what `parse/1` reads back to the same struct.

      iex> "bh/c1" |> Ainalrami.Tiebreaks.Code.parse!() |> Ainalrami.Tiebreaks.Code.format()
      "BH/C1"
  """
  def format(%__MODULE__{} = code) do
    head = code.name <> score_suffix(code.score)

    modifiers =
      [
        cut_modifier(code),
        limit_modifier(code.limit),
        code.reverse? && "R",
        code.forfeits? && "P",
        code.fore? && "F",
        code.unrated && "U#{code.unrated}"
      ]
      |> Enum.filter(&is_binary/1)

    Enum.join([head | modifiers], "/")
  end

  defp score_suffix(nil), do: ""
  defp score_suffix(:mp), do: ":MP"
  defp score_suffix(:gp), do: ":GP"

  # Medians cut the same number from both ends (14.3, 14.4); anything else
  # with a high cut cannot have come from `parse/1`.
  defp cut_modifier(%{cut_low: 0, cut_high: 0}), do: nil
  defp cut_modifier(%{cut_low: n, cut_high: n}), do: "M#{n}"
  defp cut_modifier(%{cut_low: n, cut_high: 0}), do: "C#{n}"

  defp limit_modifier(0), do: nil
  defp limit_modifier(n), do: "L#{n}"

  defp parse_head(head) do
    {name, score} =
      case String.split(head, ":") do
        [name] -> {name, nil}
        [name, "MP"] -> {name, :mp}
        [name, "GP"] -> {name, :gp}
        # TieBreakServer spells the four extended Sonneborn-Bergers of 13.2
        # as ESB with the two scores after the colon: ESB:MG is EMGSB.
        ["ESB", pair] when pair in ~w(MM MG GM GG) -> {"E#{pair}SB", nil}
        [name, other] -> {name, {:bad, other}}
        _ -> {head, {:bad, head}}
      end

    cond do
      match?({:bad, _}, score) -> {:error, "#{head}: the score after : must be MP or GP"}
      name not in names() -> {:error, "#{name} is not a tie-break code"}
      true -> {:ok, name, score}
    end
  end

  defp apply_modifiers(code, []), do: {:ok, code}

  defp apply_modifiers(code, [modifier | rest]) do
    case modifier(code, modifier) do
      {:ok, code} -> apply_modifiers(code, rest)
      :error -> {:error, "#{code.name}/#{modifier} is not a modifier #{code.name} accepts"}
    end
  end

  defp modifier(code, "C" <> n) when code.name in @cuts, do: count(n, &%{code | cut_low: &1})

  defp modifier(code, "M" <> n) when code.name in @medians,
    do: count(n, &%{code | cut_low: &1, cut_high: &1})

  defp modifier(%{name: "KS"} = code, "L" <> n) do
    case Integer.parse(String.trim_leading(n, "+")) do
      {limit, ""} when limit != 0 -> {:ok, %{code | limit: limit}}
      _ -> :error
    end
  end

  defp modifier(code, "R") when code.name in ~w(TPN RTNG), do: {:ok, %{code | reverse?: true}}

  defp modifier(code, "P") when code.name in ~w(DE EDE EDEBT EDEBB EDET EDEB),
    do: {:ok, %{code | forfeits?: true}}

  # Fore Buchholz underneath: AOB (8.2), and SSSC when "the tie-break value
  # must be known before playing" (13.4.2 a).
  defp modifier(code, "F") when code.name in ~w(AOB SSSC), do: {:ok, %{code | fore?: true}}

  defp modifier(code, "U" <> n) when code.name in ~w(ARO TPR PTP APRO APPO RTNG) do
    case Integer.parse(n) do
      {rating, ""} when rating >= 0 -> {:ok, %{code | unrated: rating}}
      _ -> :error
    end
  end

  defp modifier(_code, _modifier), do: :error

  defp count(text, fun) do
    case Integer.parse(text) do
      {n, ""} when n in 1..2 -> {:ok, fun.(n)}
      _ -> :error
    end
  end
end
