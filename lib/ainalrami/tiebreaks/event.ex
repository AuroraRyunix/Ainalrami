defmodule Ainalrami.Tiebreaks.Event do
  @moduledoc """
  The tournament as the tie-breaks see it: participants, and for each round
  what kind of round it was for them, against whom, with which colour, and
  what it was worth.

  Plain data on purpose. `from_trf/2` builds one from `Ainalrami.Trf.parse/1`
  for the checker and the generator; OpenPairings builds one from its own
  tables. Neither the tie-breaks nor their tests need a TRF file to exist.

  ## Round kinds

  The kinds are the ones C.07 Article 16.2 sorts unplayed rounds into, plus
  `:played`. The table, and the reading behind each, is in
  `docs/conformance-c07-tiebreaks.md` ("The data model"):

    * `:played` - a game over the board, rated or not (TRF `1 = 0 W D L`,
      and `?` valued by the file's `X`)
    * `:forfeit_win`, `:forfeit_loss` - against a scheduled opponent; both
      sides of a double forfeit are `:forfeit_loss`
    * `:pab` - pairing-allocated bye
    * `:full_bye`, `:half_bye`, `:zero_bye` - the three byes an arbiter
      grants. A round a participant has no record for at all - before a late
      entry, after a withdrawal - is a `:zero_bye` worth nothing (16.1.1).

  Every round also carries its `outcome`, `:win`, `:draw` or `:loss`: for a
  game, its result; for an unplayed round, "the result corresponding to the
  awarded number of points" (16.3.1, 16.4) - a win's points is a win, a
  draw's a draw, anything else a loss.
  """

  alias Ainalrami.Trf

  defmodule Round do
    @moduledoc "One participant's round. See `Ainalrami.Tiebreaks.Event`."
    @enforce_keys [:kind, :points, :outcome]
    defstruct kind: nil, opponent: nil, colour: nil, points: 0.0, outcome: :loss

    @type kind ::
            :played | :forfeit_win | :forfeit_loss | :pab | :full_bye | :half_bye | :zero_bye

    @type t :: %__MODULE__{
            kind: kind(),
            opponent: term() | nil,
            colour: :white | :black | nil,
            points: float(),
            outcome: :win | :draw | :loss
          }
  end

  defmodule Participant do
    @moduledoc "One participant. `rating` is nil when unrated."
    @enforce_keys [:id]
    defstruct id: nil, tpn: nil, rating: nil, rounds: %{}

    @type t :: %__MODULE__{
            id: term(),
            tpn: pos_integer() | nil,
            rating: non_neg_integer() | nil,
            rounds: %{pos_integer() => Ainalrami.Tiebreaks.Event.Round.t()}
          }
  end

  @enforce_keys [:rounds, :participants]
  defstruct rounds: 0,
            total_rounds: 0,
            predetermined?: false,
            points: %{win: 1.0, draw: 0.5, loss: 0.0},
            participants: %{}

  @type t :: %__MODULE__{
          rounds: non_neg_integer(),
          total_rounds: non_neg_integer(),
          predetermined?: boolean(),
          points: %{win: float(), draw: float(), loss: float()},
          participants: %{term() => Participant.t()}
        }

  @doc """
  Builds an event. `participants` is a list of `%Participant{}`; any round
  up to `rounds` a participant has no record for becomes a zero-point bye.

  `rounds` is how many rounds the standings are for - every rule that
  says "the rounds" counts these. `:total_rounds` is how many the event was
  announced with, default `rounds`; only Fore Buchholz reads it, because
  "the final round" (8.3) is the event's last round, not the last one
  played so far - after round 1 of 9 there is no final round to draw yet,
  and Fore Buchholz is plain Buchholz. (TieBreakServer reads it the same
  way.)

  Options: `:predetermined?` (a round robin or other event with pairings
  fixed in advance - Article 15.2 instead of 16), `:points`
  (`%{win:, draw:, loss:}`, default 1 / ½ / 0) and `:total_rounds`.
  """
  def new(participants, rounds, opts \\ []) do
    points = Map.merge(%{win: 1.0, draw: 0.5, loss: 0.0}, Map.new(opts[:points] || %{}))

    participants =
      Map.new(participants, fn %Participant{} = p ->
        filled =
          Map.new(1..rounds//1, fn r ->
            {r, Map.get(p.rounds, r) || zero_bye(points)}
          end)

        {p.id, %{p | rounds: filled}}
      end)

    %__MODULE__{
      rounds: rounds,
      total_rounds: max(Keyword.get(opts, :total_rounds) || rounds, rounds),
      predetermined?: Keyword.get(opts, :predetermined?, false),
      points: points,
      participants: participants
    }
  end

  defp zero_bye(points), do: %Round{kind: :zero_bye, points: 0.0, outcome: outcome(0.0, points)}

  @doc """
  The outcome a number of points corresponds to under `points`.
  """
  def outcome(value, %{win: win, draw: draw}) do
    cond do
      same?(value, win) -> :win
      same?(value, draw) -> :draw
      true -> :loss
    end
  end

  defp same?(a, b), do: abs(a - b) < 1.0e-9

  @doc """
  Builds an event from `Ainalrami.Trf.parse/1`'s result.

  Participants are identified by their starting rank (the TRF's pairing
  number), which is also their TPN. The rating is the `001` line's FIDE
  rating, nil when zero. Rounds run to the longest game list in the file,
  or to `opts[:rounds]`.

  Options: `:rounds`, `:predetermined?` (default: whether the `192` type
  code names a round robin).
  """
  def from_trf(%{players: players, tournament: tournament}, opts \\ []) do
    system = Map.get(tournament, :point_system) || Trf.default_point_system()
    points = %{win: system.win, draw: system.draw, loss: system.loss}

    rounds =
      Keyword.get_lazy(opts, :rounds, fn ->
        players |> Enum.map(&length(&1.games)) |> Enum.max(fn -> 0 end)
      end)

    participants =
      Enum.map(players, fn player ->
        %Participant{
          id: player.rank,
          tpn: player.rank,
          rating: rating(player),
          rounds:
            player.games
            |> Enum.take(rounds)
            |> Enum.with_index(1)
            |> Map.new(fn {game, r} -> {r, trf_round(game, system, points)} end)
        }
      end)

    predetermined? =
      Keyword.get_lazy(opts, :predetermined?, fn -> round_robin?(tournament[:type_code]) end)

    new(participants, rounds,
      points: points,
      predetermined?: predetermined?,
      total_rounds: tournament[:number_of_rounds]
    )
  end

  defp rating(player) do
    case Map.get(player, :fide_rating) do
      r when is_integer(r) and r > 0 -> r
      _ -> nil
    end
  end

  # Article 15.2's "tournaments with pre-determined pairings": the TRF26
  # types whose whole schedule is fixed before round one.
  defp round_robin?(code) when is_binary(code),
    do: Enum.any?(~w(ROUNDROBIN SCHILLER SCHEVENINGEN), &String.contains?(code, &1))

  defp round_robin?(_code), do: false

  defp trf_round(game, system, points) do
    opponent = Map.get(game, :opponent_rank)
    result = Map.get(game, :result)
    colour = colour(Map.get(game, :colour))

    {kind, outcome} = classify(opponent, result)

    # A zero-point bye is worth what the file's `162` says one is - which is
    # also what a blank round block, or `Z`, or an opponent-less `-` means.
    value =
      case kind do
        :zero_bye -> system.zero_point_bye
        _ -> Trf.points_for_game(%{opponent_rank: opponent, result: result}, system)
      end

    outcome = outcome || outcome(value, points)

    %Round{
      kind: kind,
      opponent: if(kind in [:played, :forfeit_win, :forfeit_loss], do: opponent),
      colour: if(kind in [:played, :forfeit_win, :forfeit_loss], do: colour),
      points: value * 1.0,
      outcome: outcome
    }
  end

  # {kind, outcome for a game - nil when it follows from the points}
  defp classify(opponent, result) when not is_nil(opponent) do
    case result do
      r when r in ["1", "W"] -> {:played, :win}
      r when r in ["=", "D"] -> {:played, :draw}
      r when r in ["0", "L"] -> {:played, :loss}
      "?" -> {:played, nil}
      "+" -> {:forfeit_win, :win}
      "-" -> {:forfeit_loss, :loss}
      # A bye code written next to an opponent: the bye is what happened.
      other -> classify(nil, other)
    end
  end

  defp classify(nil, result) do
    case result do
      r when r in ["U", "+"] -> {:pab, nil}
      "F" -> {:full_bye, nil}
      "H" -> {:half_bye, nil}
      _ -> {:zero_bye, nil}
    end
  end

  defp colour("w"), do: :white
  defp colour("b"), do: :black
  defp colour(_), do: nil
end
