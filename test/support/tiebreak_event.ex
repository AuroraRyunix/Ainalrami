defmodule Ainalrami.Test.TiebreakEvent do
  @moduledoc """
  Builds an `Ainalrami.Tiebreaks.Event` from a crosstable written the way a
  person reads one, so a tie-break test can show its tournament.

      build(%{
        1 => {2000, [{:w, 2, "1"}, {:b, 3, "="}, :pab]},
        2 => {1900, [{:b, 1, "0"}, ...]}
      }, points: %{win: 3.0, draw: 1.0, loss: 0.0})

  A round is `{colour, opponent, result}` with a TRF result (`"1" "=" "0"`,
  `"+" "-"` for forfeits, `"W" "D" "L"` for games under one move), or one of
  `:pab :full :half :zero`. The builder does not check that both sides of a
  game agree - tests that need an inconsistent record can write one.
  """

  alias Ainalrami.Tiebreaks.Event
  alias Ainalrami.Tiebreaks.Event.{Participant, Round}

  def build(spec, opts \\ []) do
    points = Map.merge(%{win: 1.0, draw: 0.5, loss: 0.0}, Map.new(opts[:points] || %{}))
    rounds = spec |> Map.values() |> Enum.map(fn {_rating, rs} -> length(rs) end) |> Enum.max()

    participants =
      for {id, {rating, rs}} <- spec do
        %Participant{
          id: id,
          tpn: Keyword.get(opts, :tpn, %{}) |> Map.get(id, id),
          rating: rating,
          rounds: rs |> Enum.with_index(1) |> Map.new(fn {r, i} -> {i, round(r, points)} end)
        }
      end

    Event.new(participants, rounds,
      points: points,
      predetermined?: Keyword.get(opts, :predetermined?, false)
    )
  end

  defp round(:pab, p), do: bye(:pab, p.win, p)
  defp round(:full, p), do: bye(:full_bye, p.win, p)
  defp round(:half, p), do: bye(:half_bye, p.draw, p)
  defp round(:zero, p), do: bye(:zero_bye, p.loss, p)

  defp round({colour, opponent, result}, p) do
    {kind, outcome} =
      case result do
        r when r in ["1", "W"] -> {:played, :win}
        r when r in ["=", "D"] -> {:played, :draw}
        r when r in ["0", "L"] -> {:played, :loss}
        "+" -> {:forfeit_win, :win}
        "-" -> {:forfeit_loss, :loss}
      end

    %Round{
      kind: kind,
      opponent: opponent,
      colour: if(colour == :w, do: :white, else: :black),
      points: Map.fetch!(p, outcome),
      outcome: outcome
    }
  end

  defp bye(kind, value, p),
    do: %Round{kind: kind, points: value, outcome: Event.outcome(value, p)}
end
