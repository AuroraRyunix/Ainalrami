defmodule Ainalrami.GeneratorChecklistTest do
  @moduledoc """
  The generator's FIDE checklist options (VCL4THP v13 Q24-Q32), and the
  promise that makes them safe to add: without them, every seed produces
  the bytes it always did. The ~488M-pairing corpus is reproduced from
  seeds, so a generator that drifted would quietly invalidate it.
  """
  use ExUnit.Case, async: true

  alias Ainalrami.{CLI, Generator, Tiebreaks, Trf}
  alias Ainalrami.Tiebreaks.Event

  # SHA-256 of `Generator.generate(opts)`'s text, captured from the
  # generator as it stood at d0f16e8, before any checklist option existed.
  @digests [
    {[seed: 1], "daafea2965b896d394f7150c5777efd454b1891b15d2f2ea33f5c070dd4353ad"},
    {[seed: 2], "47099e5072a5a4332be953fdca0f50b430312953451e9dc036d329ccc59b9d84"},
    {[seed: 42], "738db43e95d964d8838389b6371b63658e6dab464cf5a0ab096466449beb8165"},
    {[seed: 1000], "4a3a993acbbb9a159bbfc51ec5dd2ae83c6ea22efc40a091611c5ef9ac6339e2"},
    {[seed: 7, players: 31, rounds: 9],
     "4b8e4ab232178eda7946499bce8776c8fab2a1f313f349d447db01bc29d32577"},
    {[seed: 11, forfeit_pct: 10],
     "5b606238fc5e3d337c9f9b988ec84f8708f2007b9b294db31ff753bdbe8adce5"},
    {[seed: 12, requested_bye_pct: 15],
     "fcfcf805f59c38a71b0905331579a677f6f02b328c743e124f32b643610cafb0"},
    {[seed: 13, forbidden_pct: 20],
     "221266149db63e9e06c4b1af61c89cae7cf0ade4834de46bd1c0943c07afa39c"},
    {[seed: 14, acceleration: :baku],
     "7474daf2db42e6cfeaad874b98f47a3b9770241d8302cfc9b17f5028bbacb4b0"},
    {[seed: 15, acceleration: :random, forfeit_pct: 5, requested_bye_pct: 5],
     "b0ac12629d1785ec9d8a3b5901de1327a9a34287aad44a1b3057a53871b550df"},
    {[seed: 16, names: :unicode],
     "f455287dfd989435b2b94fbe983c3052dc32c183a3d9bd3df5dcd9aa7d66577a"},
    {[seed: 17, initial_colour: "b"],
     "81b24489844d97e91eba97b46bc450dbf8925d2beb5f44752576865e81c2fc44"}
  ]

  test "without the new options, every seed produces the bytes it always did" do
    for {opts, digest} <- @digests do
      {text, _} = Generator.generate(opts)

      assert Base.encode16(:crypto.hash(:sha256, text), case: :lower) == digest,
             "#{inspect(opts)} no longer produces the same tournament"
    end
  end

  defp results(text) do
    text
    |> Trf.parse()
    |> Map.fetch!(:players)
    |> Enum.flat_map(fn p -> Enum.map(p.games, & &1.result) end)
  end

  describe "ratings (Q27-Q29)" do
    test "a list gives each TPN its rating" do
      {text, _} =
        Generator.generate(seed: 3, players: 4, rounds: 2, ratings: [2400, 2300, 2200, 2100])

      assert text |> Trf.parse() |> Map.fetch!(:players) |> Enum.map(& &1.fide_rating) == [
               2400,
               2300,
               2200,
               2100
             ]
    end

    test "a range bounds them" do
      {text, _} =
        Generator.generate(seed: 3, players: 30, rounds: 2, ratings: {:range, 1800, 1900})

      ratings = text |> Trf.parse() |> Map.fetch!(:players) |> Enum.map(& &1.fide_rating)
      assert Enum.all?(ratings, &(&1 in 1800..1900))
    end

    test "a step spaces them from the top" do
      {text, _} = Generator.generate(seed: 3, players: 3, rounds: 1, ratings: {:step, 2500, 50})

      assert text |> Trf.parse() |> Map.fetch!(:players) |> Enum.map(& &1.fide_rating) == [
               2500,
               2450,
               2400
             ]
    end

    test "a list too short is refused" do
      assert_raise ArgumentError, ~r/TPN 3/, fn ->
        Generator.generate(seed: 3, players: 3, rounds: 1, ratings: [2000, 1900])
      end
    end
  end

  describe "byes and results (Q24)" do
    test "full-, half- and zero-point byes each have their own rate" do
      {text, _} =
        Generator.generate(
          seed: 5,
          players: 20,
          rounds: 7,
          full_bye_pct: 10,
          half_bye_pct: 10,
          zero_bye_pct: 10
        )

      codes = results(text)
      assert "F" in codes and "H" in codes and "Z" in codes
    end

    test "forfeit wins and double forfeits have their own rates" do
      {text, _} =
        Generator.generate(
          seed: 5,
          players: 20,
          rounds: 7,
          forfeit_win_pct: 20,
          double_forfeit_pct: 20
        )

      parsed = Trf.parse(text)

      pairs =
        for p <- parsed.players,
            {g, r} <- Enum.with_index(p.games),
            g.opponent_rank != nil,
            do:
              {g.result,
               Enum.at(Enum.find(parsed.players, &(&1.rank == g.opponent_rank)).games, r).result}

      assert {"+", "-"} in pairs
      assert {"-", "-"} in pairs
    end

    test "unusual over-the-board results appear, each side scored separately" do
      {text, _} = Generator.generate(seed: 5, players: 20, rounds: 7, odd_results_pct: 30)
      parsed = Trf.parse(text)

      pairs =
        for p <- parsed.players,
            {g, r} <- Enum.with_index(p.games),
            g.opponent_rank != nil,
            do:
              {g.result,
               Enum.at(Enum.find(parsed.players, &(&1.rank == g.opponent_rank)).games, r).result}

      assert {"=", "0"} in pairs
      assert {"0", "0"} in pairs
    end
  end

  describe "results by the FIDE rating table (Q32)" do
    # The expectation of every game is the rating table's expected score,
    # so over many games the total scored matches the total expected.
    test "the score over many games matches the expected score" do
      {scored, expected, games} =
        for seed <- 1..120, reduce: {0.0, 0.0, 0} do
          acc ->
            {text, _} =
              Generator.generate(
                seed: seed,
                players: 10,
                rounds: 5,
                ratings: {:step, 2400, 60},
                results: :fide
              )

            parsed = Trf.parse(text)
            rating = Map.new(parsed.players, &{&1.rank, &1.fide_rating})

            for p <- parsed.players, g <- p.games, g.opponent_rank != nil, reduce: acc do
              {s, e, n} ->
                points = Trf.points_for(g.result)

                exp =
                  Tiebreaks.Rating.expected_hundredths(rating[p.rank], rating[g.opponent_rank]) /
                    100

                {s + points, e + exp, n + 1}
            end
        end

      assert games > 2000
      assert abs(scored - expected) / games < 0.02
    end
  end

  describe "a tie-break list (Q31)" do
    test "is written as 202, with final ranks that follow it" do
      {text, _} =
        Generator.generate(seed: 8, players: 16, rounds: 5, tie_breaks: ["BH/C1", "BH", "SB"])

      parsed = Trf.parse(text)

      assert parsed.tournament[:tie_breaks] == ["BH/C1", "BH", "SB"]

      {:ok, standings} = Tiebreaks.rank(Event.from_trf(parsed), ~w(PTS BH/C1 BH SB))
      computed = Map.new(standings, &{&1.id, &1.rank})

      # Each file rank sits inside the computed place (a shared rank covers
      # a range of places).
      shared = Enum.frequencies(Map.values(computed))

      for p <- parsed.players do
        low = computed[p.rank]
        assert p.final_rank in low..(low + shared[low] - 1)
      end
    end

    test "an unknown code is refused" do
      assert_raise ArgumentError, ~r/XYZ/, fn ->
        Generator.generate(seed: 8, players: 6, rounds: 2, tie_breaks: ["XYZ"])
      end
    end
  end

  describe "the checker's standings (Q21)" do
    @tag :tmp_dir
    test "passes a generated file and reports a doctored rank", %{tmp_dir: dir} do
      {text, _} = Generator.generate(seed: 9, players: 12, rounds: 5, tie_breaks: ["BH/C1", "SB"])
      good = Path.join(dir, "good.trf")
      File.write!(good, text)
      assert CLI.run([good, "-c", "-q"]) == 0

      # Swap the final ranks of the first two in the standings.
      parsed = Trf.parse(text)
      [first, second | _] = Enum.sort_by(parsed.players, & &1.final_rank)

      doctored =
        parsed
        |> Map.update!(:players, fn players ->
          Enum.map(players, fn p ->
            cond do
              p.rank == first.rank -> %{p | final_rank: second.final_rank}
              p.rank == second.rank -> %{p | final_rank: first.final_rank}
              true -> p
            end
          end)
        end)
        |> Trf.serialize()

      bad = Path.join(dir, "bad.trf")
      File.write!(bad, doctored)

      # Only a failure when the two were not tied - if they were, either
      # order is the tie's own, and the checker is right to accept it.
      {:ok, standings} = Tiebreaks.rank(Event.from_trf(parsed), ~w(PTS BH/C1 SB))
      rank = Map.new(standings, &{&1.id, &1.rank})
      expected = if rank[first.rank] == rank[second.rank], do: 0, else: 1
      assert CLI.run([bad, "-c", "-q"]) == expected
    end
  end
end
