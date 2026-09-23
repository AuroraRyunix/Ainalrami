defmodule Ainalrami.Tiebreaks do
  @moduledoc """
  FIDE tie-breaks (C.07, effective 1 March 2026): values, and final
  standings from an ordered tie-break list.

      event = Ainalrami.Tiebreaks.Event.from_trf(Ainalrami.Trf.parse(text))
      {:ok, standings} = Ainalrami.Tiebreaks.rank(event, ~w(BH/C1 BH SB DE))

      hd(standings)
      #=> %{id: 7, rank: 1, values: %{"PTS" => 6.5, "BH/C1" => 31.5, ...}}

  ## Where things are

    * `Ainalrami.Tiebreaks.Code` - the code syntax (`BH/C1`, `KS/L-1`, ...)
    * `Ainalrami.Tiebreaks.Event` - the input, and `from_trf/2`
    * `Ainalrami.Tiebreaks.Individual` - Articles 7-10, one value each
    * `Ainalrami.Tiebreaks.Unplayed` - Article 16
    * `Ainalrami.Tiebreaks.DirectEncounter` - Article 6
    * `Ainalrami.Tiebreaks.Rating` - the FIDE rating tables
    * `docs/conformance-c07-tiebreaks.md` - every reading taken, and why
    * `docs/c07-regulation-text.md` - the regulation itself

  ## Ranking (Article 4.2)

  Participants are ordered by the first code, then each group still tied by
  the next, and so on; direct encounter reorders a tied group by its own
  games rather than comparing values. What is still tied when the list runs
  out shares a rank - drawing lots (4.2) is the arbiter's act, not the
  program's.

  The score comes first unless the list names it: a TRF26 `202` list is
  the tie-breaks after the score, a `212` list starts with `PTS` itself.

  A code the event cannot use is refused rather than computed:
  Buchholz-type tie-breaks in a round robin ("must not be used in
  round-robins", Article 8), and team tie-breaks, which need team data.
  An Article 10 tie-break with unrated participants and no rating for them
  is DROPPED - skipped, as the article says, and reported in `:dropped`.
  """

  alias Ainalrami.Tiebreaks.{Code, DirectEncounter, Event, Individual}

  @higher_is_better_except ~w(TPN)

  @doc """
  Every value of every code, per participant, without ranking:
  `{:ok, %{code_string => %{id => value} | :dropped}}`.
  Direct encounter has no per-participant value and is left out.
  """
  def compute(%Event{} = event, codes) do
    with {:ok, parsed} <- parse(codes),
         :ok <- usable(parsed, event) do
      ctx = Individual.context(event)

      {:ok,
       for code <- parsed, code.name != "DE", into: %{} do
         {Code.format(code), Individual.values(code, event, ctx)}
       end}
    end
  end

  @doc """
  The standings. Returns `{:ok, [%{id:, rank:, values:}]}` in rank order,
  where `values` maps each code (score included) to that participant's
  value - DE's value is the position DE gave within the tied group, 1 the
  best. `{:error, reason}` for an unusable list.

  The result also carries, as the second element when asked for with
  `with_dropped: true`, the codes Article 10 dropped.
  """
  def rank(%Event{} = event, codes, opts \\ []) do
    with {:ok, parsed} <- parse(codes),
         :ok <- usable(parsed, event) do
      parsed = with_score_first(parsed)
      ctx = Individual.context(event)

      {values, dropped} =
        Enum.reduce(parsed, {%{}, []}, fn code, {acc, dropped} ->
          case code.name do
            "DE" ->
              {acc, dropped}

            _ ->
              case Individual.values(code, event, ctx) do
                :dropped -> {acc, [Code.format(code) | dropped]}
                map -> {Map.put(acc, Code.format(code), map), dropped}
              end
          end
        end)

      active = Enum.reject(parsed, &(Code.format(&1) in dropped))
      ids = Map.keys(event.participants) |> Enum.sort()

      {groups, de_positions} = order(ids, active, values, event, %{})

      standings = assign_ranks(groups, active, values, de_positions)

      if Keyword.get(opts, :with_dropped, false),
        do: {:ok, standings, Enum.reverse(dropped)},
        else: {:ok, standings}
    end
  end

  # ---- validation ----------------------------------------------------------

  defp parse(codes) when is_binary(codes), do: Code.parse_list(codes)
  defp parse(codes) when is_list(codes), do: Code.parse_list(codes)

  defp usable(codes, event) do
    team = Enum.find(codes, &Code.team?(&1.name))
    buchholz = Enum.find(codes, &(&1.name in ~w(BH FB AOB)))

    cond do
      team ->
        {:error, "#{Code.format(team)} is a team tie-break; this event has no team data"}

      event.predetermined? and buchholz ->
        {:error, "#{Code.format(buchholz)} must not be used in round robins (C.07 Article 8)"}

      true ->
        :ok
    end
  end

  defp with_score_first([%Code{name: "PTS"} | _] = codes), do: codes
  defp with_score_first(codes), do: [%Code{name: "PTS"} | codes]

  # ---- ordering (Article 4.2) --------------------------------------------

  # Returns {[[id]] groups in order, %{{code_index, id} => DE position}}.
  defp order(group, [], _values, _event, de), do: {[group], de}
  defp order([_] = group, _codes, _values, _event, de), do: {[group], de}

  defp order(group, [code | rest], values, event, de) do
    {subgroups, de} = split(group, code, values, event, de)

    Enum.reduce(subgroups, {[], de}, fn subgroup, {acc, de} ->
      {groups, de} = order(subgroup, rest, values, event, de)
      {acc ++ groups, de}
    end)
  end

  defp split(group, %Code{name: "DE"} = code, _values, event, de) do
    subgroups = DirectEncounter.order(group, code, event)

    de =
      subgroups
      |> Enum.with_index(1)
      |> Enum.reduce(de, fn {members, position}, de ->
        Enum.reduce(members, de, &Map.put(&2, {Code.format(code), &1}, position))
      end)

    {subgroups, de}
  end

  defp split(group, code, values, _event, de) do
    map = values[Code.format(code)]
    direction = direction(code)

    subgroups =
      group
      |> Enum.group_by(&key(map[&1]))
      |> Enum.sort_by(fn {value, _} -> value end, direction)
      |> Enum.map(fn {_value, members} -> Enum.sort(members) end)

    {subgroups, de}
  end

  # Higher is better, except TPN (ascending, 7.8) - and `R` turns either
  # round (TPN/R descending, RTNG/R ascending).
  defp direction(%Code{name: name, reverse?: reverse?}) do
    ascending? = name in @higher_is_better_except
    if ascending? != reverse?, do: :asc, else: :desc
  end

  # nil (no games to average over) sorts below every number.
  defp key(nil), do: -1.0e18
  defp key(value), do: Float.round(value * 1.0, 6)

  defp assign_ranks(groups, codes, values, de_positions) do
    {rows, _next} =
      Enum.flat_map_reduce(groups, 1, fn group, next ->
        rows =
          for id <- group do
            %{
              id: id,
              rank: next,
              values:
                Map.new(codes, fn code ->
                  formatted = Code.format(code)

                  value =
                    if code.name == "DE",
                      do: Map.get(de_positions, {formatted, id}),
                      else: values[formatted][id]

                  {formatted, value}
                end)
            }
          end

        {rows, next + length(group)}
      end)

    rows
  end
end
