defmodule Ainalrami.SoftConstraintsTest do
  @moduledoc """
  Soft pairs - the ones an arbiter would rather avoid but will accept. Two
  things have to be true at once: with none given, the engine is the FIDE
  engine byte for byte; with some given, they steer the pairing and show up
  in the explanation as a rung of their own.
  """

  use ExUnit.Case, async: true

  alias Ainalrami.{Pairing, Trf}

  defp player(rank, points, games) do
    %{
      name: "P#{rank}",
      title: "",
      federation: "",
      sex: "",
      fide_rating: 2000 - rank * 100,
      fide_number: nil,
      birth_date: "",
      points: points,
      rank: rank,
      games: games
    }
  end

  defp fresh(n), do: for(r <- 1..n, do: player(r, 0.0, []))

  test "with no soft pairs the pairing and the report are exactly the FIDE ones" do
    for path <- Enum.take(Path.wildcard("test/fixtures/**/*.trf"), 8) do
      parsed = path |> File.read!() |> Trf.parse()
      opts = [expected_rounds: 11, forbidden_pairs: parsed.tournament[:forbidden_pairs]]

      plain = Pairing.pair_next_round(parsed.players, opts)
      assert Pairing.pair_next_round(parsed.players, opts ++ [soft_pairs: []]) == plain
      assert Pairing.pair_next_round(parsed.players, opts ++ [soft_pairs: nil]) == plain

      report = Pairing.explain_round(parsed.players, plain, opts)

      refute Enum.any?(report, fn b ->
               Enum.any?(b.rungs, fn {label, _} -> label =~ "soft" end)
             end)
    end
  end

  test "a strong soft pair is avoided even at the cost of the natural S1-S2 pairing" do
    # Round one of six: 1-4, 2-5, 3-6 is the natural pairing. Asking to avoid
    # 1-4 (two players from the same club, say) changes the round.
    natural = Pairing.pair_next_round(fresh(6), [])
    assert Enum.any?(natural, &(&1 in [{1, 4}, {4, 1}]))

    steered = Pairing.pair_next_round(fresh(6), soft_pairs: [[1, 4]])
    refute Enum.any?(steered, &(&1 in [{1, 4}, {4, 1}]))
    # Everybody still plays.
    assert length(steered) == 3
  end

  test "the soft rung is reported, and sits where the arbiter put it" do
    strong =
      Pairing.explain_round(fresh(6), Pairing.pair_next_round(fresh(6), soft_pairs: [[1, 4]]),
        soft_pairs: [[1, 4]]
      )

    [bracket] = strong
    labels = Enum.map(bracket.rungs, &elem(&1, 0))
    assert Enum.at(labels, 1) == "S soft avoid"

    weak_opts = [soft_pairs: [[1, 4]], soft_position: :weak]

    weak =
      Pairing.explain_round(fresh(6), Pairing.pair_next_round(fresh(6), weak_opts), weak_opts)

    [bracket] = weak
    assert List.last(Enum.map(bracket.rungs, &elem(&1, 0))) == "S soft avoid"
  end

  # "Weak" sits below every FIDE criterion, so it may only ever separate
  # rounds the criteria already tie on. In round one that is every legal
  # pairing - the natural S1-S2 order is a tie-break, not a preference - so
  # a weak wish to avoid 1-4 DOES move it, and must cost nothing on any
  # FIDE rung. That is the property, and it is what the test checks.
  test "a weak soft pair steers only among rounds the criteria tie on" do
    weak_opts = [soft_pairs: [[1, 4]], soft_position: :weak]
    plain = Pairing.pair_next_round(fresh(6), [])
    steered = Pairing.pair_next_round(fresh(6), weak_opts)

    refute Enum.any?(steered, &(&1 in [{1, 4}, {4, 1}]))

    without_soft = fn report ->
      Enum.map(report, fn bracket ->
        %{
          bracket
          | rungs: Enum.reject(bracket.rungs, fn {label, _} -> label == "S soft avoid" end)
        }
      end)
    end

    plain_report = Pairing.explain_round(fresh(6), plain, [])
    steered_report = without_soft.(Pairing.explain_round(fresh(6), steered, weak_opts))

    # Different pairs, and not one FIDE rung worse for it.
    assert {:tie, +0.0, _lex} = Ainalrami.Alternatives.compare(plain_report, steered_report)
  end
end
