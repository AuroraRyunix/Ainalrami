defmodule Ainalrami.TypeCode do
  @moduledoc """
  What a TRF26 `192` tournament type code says, per FIDE's Tournament Type
  Code Table for TRF_CODE 192 (published by the Technical Commission with
  TRF-2026, <https://tec.fide.com/trf-2026>).

  `Ainalrami.Trf.tournament_type_code?/1` says whether a value may stand on
  a `192` line at all; `parse/1` says what it means. The table's meanings,
  one line each:

  | code | meaning |
  |---|---|
  | `FIDE_DUTCH_2017` / `FIDE_DUTCH_2025` | the Dutch system before 1 July 2025 / after 30 June 2025 |
  | `FIDE_DUTCH` | `_2017` before 1 July 2025, `_2025` after |
  | `FIDE_DUBOV`, `FIDE_BURSTEIN` | the Dubov and Burstein systems |
  | `..._BAKU` | the same with the Baku Acceleration Method |
  | `CUSTOM_SWISS`, `FIDE_DOUBLESWISS[_BAKU]`, `CUSTOM_DOUBLESWISS` | a Swiss of the competition's own; the Double Swiss |
  | `BERGER_ROUNDROBIN_Gn` | a round robin by the Berger tables, every game played n times |
  | `BERGER_ROUNDROBIN`, `FIDE_ROUNDROBIN` | `_G1` |
  | `BERGER_DOUBLEROUNDROBIN` | `_G2` |
  | `FIDE_DOUBLEROUNDROBIN` | `_G1` with its last two rounds played in reverse order, then `_G1` |
  | `FIDE_SCHILLER_TxP` | Schiller system, T teams of P players (`FIDE_SCHILLER`: 4x3) |
  | `FIDE_SCHEVENINGEN_Gn` | Scheveningen, games repeated n times (`FIDE_SCHEVENINGEN` G1, `FIDE_DOUBLESCHEVENINGEN` G2) |
  | `CUSTOM_ROUNDROBIN`, `CUSTOM_SCHILLER`, `CUSTOM_SCHEVENINGEN`, `CUSTOM_KNOCKOUT` | the competition's own |
  | `FIDE_TEAM_TYPEA_*` / `FIDE_TEAM_TYPEB_*` | C.04.6 with Type A / Type B colour preferences |
  | `FIDE_TEAM_MP_GP`, `_GP_MP`, `_MP`, `_GP` (no `TYPEA`/`TYPEB`) | C.04.6 with **no colour preferences** |
  | `..._X_Y` / `..._X` | X the primary score, Y the secondary one used in colour allocation / secondary not used |
  | `FIDE_TEAM`, `FIDE_TEAM_BAKU` | `FIDE_TEAM_TYPEA_MP_GP`, `FIDE_TEAM_TYPEA_MP_GP_BAKU` |
  | `CUSTOM_TEAM_SWISS[_MP|_GP]` | a team Swiss of the competition's own |
  | `BERGER_TEAM_ROUNDROBIN_Gn` | a team round robin by the Berger tables, n times (`BERGER_TEAM_ROUNDROBIN` and `FIDE_TEAM_ROUNDROBIN` G1, `BERGER_TEAM_DOUBLEROUNDROBIN` and `FIDE_TEAM_DOUBLEROUNDROBIN` G2) |
  | `CUSTOM_TEAM_ROUNDROBIN`, `CUSTOM_TEAM_KNOCKOUT` | the competition's own |

  The table itself notes that the Berger tables are defined in the
  Competition Rules' Appendix 1, that Schiller and Scheveningen are "not yet
  defined", and that a Double Swiss algorithm is still to come.

  `FIDE_DUTCH_2026` and `FIDE_DUTCH_2026_BAKU` are not in the table. An
  earlier draft of TRF-2026 spelled the current Dutch edition that way,
  and files written from it exist (this library wrote them, and
  OpenPairings did), so they are still accepted and read as
  `FIDE_DUTCH_2025` - `legacy?: true` says so.
  """

  alias Ainalrami.Trf

  @typedoc """
  `parse/1`'s answer. Always `:code` (normalised), `:system`, `:team?` and
  `:baku?`; the rest only where the system has them:

    * `:edition` - the Dutch system: `2017`, `2025`, or `:by_date`
      (`FIDE_DUTCH`, decided by the event's date - `edition/2`);
    * `:games` - a round robin or Scheveningen: how many times each game
      is played; `:reverse_last_two?` for `FIDE_DOUBLEROUNDROBIN`'s own
      construction;
    * `:teams`, `:players` - a Schiller;
    * `:colour_preferences` (`:a`, `:b` or `:none`), `:score_mode`
      (`:match_points` or `:game_points`), `:use_secondary?` - a C.04.6
      team Swiss;
    * `:defaults_to` - the code a shorthand stands for (`FIDE_TEAM`,
      `FIDE_SCHILLER`, `BERGER_ROUNDROBIN`, ...);
    * `:legacy?` - a spelling from the draft table (see the moduledoc).
  """
  @type t :: %{required(:code) => String.t(), optional(atom()) => term()}

  @doc """
  What `code` means: `{:ok, description}` for a code in FIDE's table (see
  `t:t/0`), `:error` otherwise. Case and surrounding blanks are forgiven -
  `fide_team_mp` is `FIDE_TEAM_MP` - since a reader should not refuse what a
  writer merely mis-cased.
  """
  @spec parse(term()) :: {:ok, t()} | :error
  def parse(code) when is_binary(code) do
    code =
      code
      |> String.trim()
      |> String.upcase()
      |> then(&Regex.replace(~r/^FIDE_SCHILLER_(\d+)X(\d+)$/, &1, "FIDE_SCHILLER_\\1x\\2"))

    with true <- Trf.tournament_type_code?(code),
         %{} = description <- describe(code) do
      {:ok, Map.merge(%{code: code, team?: false, baku?: false}, description)}
    else
      _ -> :error
    end
  end

  def parse(_code), do: :error

  @doc """
  The Dutch edition a parsed Dutch code names, with `FIDE_DUTCH`'s
  date-dependent default resolved against `start_date` (the file's `042`, as
  written): `2017` before 1 July 2025, `2025` from then on. `:unknown` when
  the code leaves it to a date the file does not give readably.
  """
  def edition(%{system: :dutch, edition: :by_date}, start_date) do
    case parse_date(start_date) do
      {:ok, date} ->
        if Date.compare(date, ~D[2025-07-01]) == :lt, do: 2017, else: 2025

      :error ->
        :unknown
    end
  end

  def edition(%{system: :dutch, edition: edition}, _start_date), do: edition
  def edition(_description, _start_date), do: nil

  # `042` is free text in practice: `2025/03/14`, `2025-03-14`,
  # `14.03.2025`, `14/03/2025`.
  defp parse_date(text) when is_binary(text) do
    parts =
      case Regex.run(~r/(\d{4})[\/.-](\d{1,2})[\/.-](\d{1,2})/, text) do
        [_, y, m, d] ->
          {y, m, d}

        nil ->
          case Regex.run(~r/(\d{1,2})[\/.-](\d{1,2})[\/.-](\d{4})/, text) do
            [_, d, m, y] -> {y, m, d}
            nil -> nil
          end
      end

    with {y, m, d} <- parts,
         {:ok, date} <-
           Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d)) do
      {:ok, date}
    else
      _ -> :error
    end
  end

  defp parse_date(_text), do: :error

  # ---- the table -----------------------------------------------------------

  defp describe("FIDE_DUTCH" <> rest) do
    {rest, baku?} = baku(rest)

    {edition, extra} =
      case rest do
        "" -> {:by_date, %{}}
        "_2017" -> {2017, %{}}
        "_2025" -> {2025, %{}}
        "_2026" -> {2025, %{legacy?: true}}
      end

    Map.merge(%{system: :dutch, edition: edition, baku?: baku?}, extra)
  end

  defp describe("FIDE_DUBOV" <> rest), do: %{system: :dubov, baku?: rest == "_BAKU"}
  defp describe("FIDE_BURSTEIN" <> rest), do: %{system: :burstein, baku?: rest == "_BAKU"}
  defp describe("FIDE_DOUBLESWISS" <> rest), do: %{system: :double_swiss, baku?: rest == "_BAKU"}
  defp describe("CUSTOM_SWISS"), do: %{system: :custom_swiss}
  defp describe("CUSTOM_DOUBLESWISS"), do: %{system: :custom_double_swiss}

  defp describe("BERGER_ROUNDROBIN_G" <> n), do: %{system: :round_robin, games: int(n)}

  defp describe("BERGER_ROUNDROBIN"),
    do: %{system: :round_robin, games: 1, defaults_to: "BERGER_ROUNDROBIN_G1"}

  defp describe("BERGER_DOUBLEROUNDROBIN"),
    do: %{system: :round_robin, games: 2, defaults_to: "BERGER_ROUNDROBIN_G2"}

  defp describe("FIDE_ROUNDROBIN"),
    do: %{system: :round_robin, games: 1, defaults_to: "BERGER_ROUNDROBIN"}

  defp describe("FIDE_DOUBLEROUNDROBIN"),
    do: %{system: :round_robin, games: 2, reverse_last_two?: true}

  defp describe("CUSTOM_ROUNDROBIN"), do: %{system: :custom_round_robin}

  defp describe("FIDE_SCHILLER_" <> size) do
    [t, p] = String.split(size, "x")
    %{system: :schiller, teams: int(t), players: int(p)}
  end

  defp describe("FIDE_SCHILLER"),
    do: %{system: :schiller, teams: 4, players: 3, defaults_to: "FIDE_SCHILLER_4x3"}

  defp describe("CUSTOM_SCHILLER"), do: %{system: :custom_schiller}

  defp describe("FIDE_SCHEVENINGEN_G" <> n), do: %{system: :scheveningen, games: int(n)}

  defp describe("FIDE_SCHEVENINGEN"),
    do: %{system: :scheveningen, games: 1, defaults_to: "FIDE_SCHEVENINGEN_G1"}

  defp describe("FIDE_DOUBLESCHEVENINGEN"),
    do: %{system: :scheveningen, games: 2, defaults_to: "FIDE_SCHEVENINGEN_G2"}

  defp describe("CUSTOM_SCHEVENINGEN"), do: %{system: :custom_scheveningen}
  defp describe("CUSTOM_KNOCKOUT"), do: %{system: :knockout}

  defp describe("CUSTOM_TEAM_SWISS" <> _), do: %{system: :custom_team_swiss, team?: true}

  defp describe("BERGER_TEAM_ROUNDROBIN_G" <> n),
    do: %{system: :team_round_robin, team?: true, games: int(n)}

  defp describe(code)
       when code in ~w(BERGER_TEAM_ROUNDROBIN FIDE_TEAM_ROUNDROBIN),
       do: %{
         system: :team_round_robin,
         team?: true,
         games: 1,
         defaults_to: "BERGER_TEAM_ROUNDROBIN_G1"
       }

  defp describe(code)
       when code in ~w(BERGER_TEAM_DOUBLEROUNDROBIN FIDE_TEAM_DOUBLEROUNDROBIN),
       do: %{
         system: :team_round_robin,
         team?: true,
         games: 2,
         defaults_to: "BERGER_TEAM_ROUNDROBIN_G2"
       }

  defp describe("CUSTOM_TEAM_ROUNDROBIN"), do: %{system: :custom_team_round_robin, team?: true}
  defp describe("CUSTOM_TEAM_KNOCKOUT"), do: %{system: :team_knockout, team?: true}

  defp describe("FIDE_TEAM"),
    do: Map.put(describe("FIDE_TEAM_TYPEA_MP_GP"), :defaults_to, "FIDE_TEAM_TYPEA_MP_GP")

  defp describe("FIDE_TEAM_BAKU"),
    do:
      Map.put(describe("FIDE_TEAM_TYPEA_MP_GP_BAKU"), :defaults_to, "FIDE_TEAM_TYPEA_MP_GP_BAKU")

  defp describe("FIDE_TEAM_" <> rest) do
    {rest, baku?} = baku(rest)

    {preferences, scores} =
      case rest do
        "TYPEA_" <> scores -> {:a, scores}
        "TYPEB_" <> scores -> {:b, scores}
        scores -> {:none, scores}
      end

    {mode, secondary?} =
      case scores do
        "MP_GP" -> {:match_points, true}
        "GP_MP" -> {:game_points, true}
        "MP" -> {:match_points, false}
        "GP" -> {:game_points, false}
      end

    %{
      system: :team_swiss,
      team?: true,
      baku?: baku?,
      colour_preferences: preferences,
      score_mode: mode,
      use_secondary?: secondary?
    }
  end

  defp baku(rest) do
    if String.ends_with?(rest, "_BAKU"),
      do: {String.replace_suffix(rest, "_BAKU", ""), true},
      else: {rest, false}
  end

  defp int(digits), do: String.to_integer(digits)
end
