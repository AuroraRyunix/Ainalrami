# Random tie-break lists for the comparison tools (`--random-lists SEED` in
# tools/tiebreak_compare.exs and tools/team_tiebreak_compare.exs).
#
# The fixed lists those tools rank under by default exercise a handful of
# codes in a handful of positions. A random list per tournament puts every
# code and modifier Ainalrami supports into a full ranking, in every order -
# which is where order-dependent behaviour (finding A) and the modifiers'
# rarer paths show up.
#
# A list is drawn per tournament from (SEED, the tournament's own number),
# so a run is reproducible and a single file can be re-run with its list:
# one to six entries, each a family drawn uniformly and then one of its
# spellings. No entry twice, at most one direct-encounter code. Validity:
#
#   - round robins: no Buchholz family (BH, FB, AOB - C.07 Article 8);
#   - individual events: individual codes only;
#   - team events: the list starts with the primary score (MPTS, or GPTS
#     one time in four), then team codes and individual codes on either
#     score (`BH:MP`, `SB:GP`).
#
# The Article 10 codes carry a rating for unrated players (`U1000`,
# `U1400`) most of the time and none one time in five, so the "drop the
# code when unrated players are present" rule is ranked too.

defmodule TiebreakRandomList do
  @rating_u ["/U1000", "/U1000", "/U1400", "/U1400", ""]

  defp rating(name, cuts) do
    for cut <- cuts, u <- Enum.uniq(@rating_u), do: name <> cut <> u
  end

  @doc "The families for an event: `:swiss`, `:rr` or `:team`."
  def families(:swiss), do: common() ++ buchholz("")
  def families(:rr), do: common()

  def families(:team) do
    [
      {:de, ~w(EDE EDE EDET EDEB EDEBT EDEBB DE)},
      ["MPVGP"],
      ["BC"],
      ["TBR"],
      ["BBE"],
      ~w(SSSC SSSC/F),
      ~w(EMMSB EMGSB EGMSB EGGSB EMMSB/C1 EMGSB/C1 EGMSB/C1 EGGSB/C1),
      ~w(SB:MP SB:GP SB:MP/C1 SB:GP/C1),
      ~w(PS:MP PS:GP PS:MP/C1),
      ~w(KS:MP KS:GP),
      ~w(WIN WON)
    ] ++ buchholz(":MP") ++ buchholz(":GP")
  end

  # Team round robins, Scheveningen and Schiller: no Buchholz family.
  def families(:team_rr), do: families(:team) -- (buchholz(":MP") ++ buchholz(":GP"))

  defp common do
    [
      {:de, ~w(DE DE/P)},
      ~w(SB SB/C1 SB/C2),
      ~w(PS PS/C1 PS/C2),
      ~w(KS KS/L1 KS/L2 KS/L-1 KS/L-2),
      ["WIN"],
      ["WON"],
      ["BPG"],
      ["BWG"],
      ["REP"],
      ["STD"],
      ~w(TPN TPN/R),
      ~w(RTNG RTNG/R RTNG/U1000 RTNG/R/U1400),
      rating("ARO", ["", "/C1", "/C2", "/M1", "/M2"]),
      rating("TPR", [""]),
      rating("PTP", [""]),
      rating("APRO", [""]),
      rating("APPO", [""])
    ]
  end

  defp buchholz(score) do
    [
      Enum.map(~w(BH BH/C1 BH/C2 BH/M1 BH/M2), &sub(&1, score)),
      Enum.map(~w(FB FB/C1 FB/C2 FB/M1 FB/M2), &sub(&1, score)),
      Enum.map(~w(AOB AOB/F), &sub(&1, score))
    ]
  end

  # "BH/C1" with ":MP" -> "BH:MP/C1"
  defp sub(code, ""), do: code

  defp sub(code, score) do
    [name | mods] = String.split(code, "/")
    Enum.join([name <> score | mods], "/")
  end

  @doc """
  The list for tournament `number` under `seed`, as a list of code strings.
  For `:team` the first entry is the primary score.
  """
  def draw(kind, seed, number) do
    :rand.seed(:exsss, {seed + 1, number + 7, 20_260_925})
    length = :rand.uniform(6)
    families = families(kind)

    list =
      Enum.reduce_while(1..200, [], fn _, acc ->
        if length(acc) == length do
          {:halt, acc}
        else
          {tag, spellings} =
            case Enum.random(families) do
              {tag, spellings} -> {tag, spellings}
              spellings -> {nil, spellings}
            end

          code = Enum.random(spellings)
          de_taken? = tag == :de and Enum.any?(acc, &de?/1)

          if code in acc or de_taken?, do: {:cont, acc}, else: {:cont, acc ++ [code]}
        end
      end)

    case kind do
      k when k in [:team, :team_rr] ->
        primary = if :rand.uniform(4) == 1, do: "GPTS", else: "MPTS"
        [primary | list]

      _ ->
        list
    end
  end

  def de?(code), do: code |> String.split(["/", ":"]) |> hd() |> String.starts_with?(["DE", "EDE"])

  @doc "The tournament number in a file name (`g123.trf`, `t45.trf`)."
  def number(file) do
    case Regex.run(~r"(\d+)\.trf$", file) do
      [_, n] -> String.to_integer(n)
      nil -> :erlang.phash2(Path.basename(file))
    end
  end
end
