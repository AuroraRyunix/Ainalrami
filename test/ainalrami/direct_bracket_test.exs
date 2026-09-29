defmodule Ainalrami.DirectBracketTest do
  @moduledoc """
  The direct brackets (`Ainalrami.Pairing`'s "the direct bracket" and "the
  small bracket" sections) answer a bracket without the refinement stages,
  and are claimed to give the stages' own answer wherever they answer at
  all. Two checks of that claim on generated tournaments:

    * `AINALRAMI_DIRECT=check` - every direct answer is held to the stages'
      answer on the same bracket, from the same state, and a difference
      raises;
    * every round is also paired with `AINALRAMI_DIRECT=off`, and the two
      pairings (or refusals) must be the same.

  Certified mode is forced so the field-graph direct brackets run on small
  fields too, and the counters are read to make sure every kind of direct
  answer was actually given - a test that never reached the code under test
  would pass vacuously.
  """

  use ExUnit.Case, async: false

  alias Ainalrami.Pairing
  alias Ainalrami.Test.FuzzTournament, as: Fuzz

  @axes [
    {"plain 4-40", 1..80, 4..40, %{}},
    {"byes and forfeits 4-40", 201..280, 4..40,
     %{
       "PAIRING_FUZZ_BYE_PCT" => "10",
       "PAIRING_FUZZ_FORFEIT_PCT" => "6",
       "PAIRING_FUZZ_WITHDRAW_PCT" => "2"
     }},
    {"forbidden pairs, acceleration, point systems 4-40", 401..480, 4..40,
     %{
       "PAIRING_FUZZ_FORBIDDEN_PCT" => "10",
       "PAIRING_FUZZ_ACCEL" => "mixed",
       "PAIRING_FUZZ_POINT_SYSTEM" => "mixed",
       "PAIRING_FUZZ_INITIAL_COLOUR" => "mixed"
     }},
    {"large 100-180", 601..603, 100..180,
     %{"PAIRING_FUZZ_BYE_PCT" => "3", "PAIRING_FUZZ_FORFEIT_PCT" => "2"}},
    {"large 101-151", 701..702, 101..151,
     %{"PAIRING_FUZZ_BYE_PCT" => "3", "PAIRING_FUZZ_FORFEIT_PCT" => "2"}}
  ]

  setup do
    saved =
      for key <- ~w(AINALRAMI_DIRECT AINALRAMI_CERT AINALRAMI_CERT_STATS),
          do: {key, System.get_env(key)}

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  @tag timeout: 600_000
  test "direct answers equal the stages', bracket by bracket and round by round" do
    System.put_env("AINALRAMI_CERT", "force")
    System.put_env("AINALRAMI_CERT_STATS", "1")

    {rounds, stats} =
      Enum.reduce(@axes, {0, %{}}, fn {_label, seeds, range, env}, acc ->
        with_env(env, fn ->
          Enum.reduce(seeds, acc, fn seed, {rounds, stats} ->
            {n, s} = play(seed, range)
            {rounds + n, Map.merge(stats, s, fn _k, a, b -> a + b end)}
          end)
        end)
      end)

    assert rounds > 2_000
    assert Map.get(stats, :direct_ok, 0) > 0, "the walk never answered: #{inspect(stats)}"
    assert Map.get(stats, :direct_small_ok, 0) > 0, "the small bracket never answered"

    # The odd field's shapes, each held to the field path's answer by the
    # check mode: the last bracket (the bye), an odd bracket over the bye
    # group, an even bracket of an odd field.
    for kind <- [:last, :odd_bye_group, :even_odd_field] do
      assert Map.get(stats, {:direct_field_checked, kind}, 0) > 0,
             "no #{kind} bracket was answered directly: #{inspect(stats)}"
    end
  end

  defp play(seed, range) do
    {rounds, player_count, forbidden, roster} = Fuzz.begin!(seed, 9, range)

    {n, _players, stats} =
      Enum.reduce_while(1..rounds, {0, roster, %{}}, fn round, {n, players, stats} ->
        Fuzz.withdraw_some(round, player_count)
        {active, pending} = Fuzz.reveal_late_entrants(players, round)
        active = Fuzz.assign_requested_byes(active)

        opts = [
          expected_rounds: rounds,
          forbidden_pairs: forbidden,
          initial_colour: String.downcase(Fuzz.initial_colour()),
          point_system: Fuzz.point_system()
        ]

        System.put_env("AINALRAMI_DIRECT", "check")
        checked = pair(active, opts)
        stats = Map.merge(stats, Pairing.take_cert_stats(), fn _k, a, b -> a + b end)
        System.put_env("AINALRAMI_DIRECT", "off")
        reference = pair(active, opts)
        _ = Pairing.take_cert_stats()

        assert checked == reference,
               "seed #{seed} round #{round}: direct #{inspect(checked)} vs stages #{inspect(reference)}"

        case checked do
          {:ok, pairs} ->
            next = Fuzz.apply_round(active, pairs, Fuzz.simulate_results(pairs))
            {:cont, {n + 1, next ++ pending, stats}}

          _ ->
            {:halt, {n + 1, players, stats}}
        end
      end)

    {n, stats}
  end

  defp pair(players, opts) do
    {:ok, Pairing.pair_next_round(players, opts)}
  rescue
    e in Pairing.NoValidPairingError -> {:refused, e.reason}
  end

  defp with_env(env, fun) do
    previous = Map.new(env, fn {k, _} -> {k, System.get_env(k)} end)
    Enum.each(env, fn {k, v} -> System.put_env(k, v) end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end
end
