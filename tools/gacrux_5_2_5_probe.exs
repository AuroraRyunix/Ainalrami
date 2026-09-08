# Adjudicates the Gacrux Article 5.2.5 candidate.
#
#   MIX_ENV=test mix run tools/gacrux_5_2_5_probe.exs [seeds] [min_players] [max_players]
#
# The 2026-08-29 corpus fired `ColourArticle.article_5_2_5_consistency/3`
# seventeen times over ~1,065,000 rounds - every one on Gacrux, every one in
# round 2, with bbpPairings and Ainalrami silent. That check does not need to
# know the initial colour, which Article 5.1 leaves to a drawing of lots: it
# only needs 5.2.5 to give ONE answer per round from ONE constant. An engine
# whose boards imply both colours has broken the article on at least one of
# them, whatever the draw was.
#
# Seventeen firings is not a finding until somebody reads a position. This
# reproduces one locally and prints it board by board, with everything the
# article turns on, so it can be adjudicated by hand rather than counted.
#
# Needs the Gacrux tie-break server (GACRUX_DIR, default ../TieBreakServer)
# and its Python.
#
# ## What the round-2 pattern actually means (2026-09-08)
#
# "All seventeen in round 2" reads like a clue about round 2 and is not one.
# Article 5.2.5 decides a board only where NEITHER player holds a colour
# preference, and after round 1 the thing that gives you a preference is
# having played. So a round-2 board can reach 5.2.5 only between two players
# who both sat round 1 out - and a tournament has two of those only when the
# arbiter granted byes. Round 2 is not where the engine misbehaves; it is the
# last round where the article is reachable at all without absences piling up.
#
# That is why the first version of this probe found nothing: it generated no
# round-1 byes, so `article_5_2_5_consistency/3` returned `:not_applicable`
# for every single round and the search could not have found anything if the
# defect were certain. BYE_PCT (default 20) is what makes the check reachable,
# and a run that reports mostly `:not_applicable` is measuring nothing -
# check that number before believing a zero.
#
# ## SETTLED 2026-09-08: Gacrux does break the article
#
# A recorded position reproduces a contradiction - two boards of one round
# needing opposite initial colours, robust to which numbering you use. See
# docs/finding-gacrux-5-2-5.md and test/fixtures/gacrux_5_2_5/. This probe's
# own clean runs below were never evidence against that; they only ever said
# the behaviour is rare, which the corpus rate already said.
#
# ## Where it stands
#
# 500 seeds at BYE_PCT=45 over 14-30 players: 452 rounds where the article
# applied, ZERO self-contradictions. That does not clear Gacrux - the corpus
# rate was 17 in ~1,065,000 rounds, so a few hundred judgeable rounds expects
# well under one hit - but it does say the behaviour is a rare edge rather
# than something systematic, which a "17 firings" line on its own does not
# distinguish. Adjudicating properly means reading one of the seventeen
# recorded positions (Photon, /root/ain_val_run/), not finding a new one:
# that box was unreachable on 2026-09-08.

alias Ainalrami.{Pairing, Trf}
alias Ainalrami.Test.{ColourArticle, Gacrux}

defmodule Probe do
  def roster(n) do
    for(
      i <- 1..n,
      do: %{rank: i, name: "P#{i}", fide_rating: Enum.random(1000..2800), points: 0.0, games: []}
    )
    |> Enum.shuffle()
    |> Enum.with_index(1)
    |> Enum.map(fn {p, i} -> %{p | rank: i} end)
  end

  def trf(players, rounds) do
    Trf.serialize(%{tournament: %{name: "Probe", type: "swiss"}, players: players}) <>
      "XXR #{rounds}\r\n"
  end

  # Round one's results only. The candidate is entirely in round 2, and a
  # deterministic spread of wins, draws and losses is what puts players on
  # three different scores there - which is what makes 5.2.5 reachable on
  # more than one board at once.
  def apply_round(players, pairs, seed) do
    :rand.seed(:exsss, {seed * 31, seed * 37, seed * 41})

    games =
      Enum.reduce(pairs, %{}, fn
        {w, nil}, acc ->
          Map.put(acc, w, {%{opponent_rank: nil, colour: nil, result: "U"}, 1.0})

        {w, b}, acc ->
          case Enum.random([:white, :black, :draw]) do
            :white ->
              acc
              |> Map.put(w, {%{opponent_rank: b, colour: "w", result: "1"}, 1.0})
              |> Map.put(b, {%{opponent_rank: w, colour: "b", result: "0"}, 0.0})

            :black ->
              acc
              |> Map.put(w, {%{opponent_rank: b, colour: "w", result: "0"}, 0.0})
              |> Map.put(b, {%{opponent_rank: w, colour: "b", result: "1"}, 1.0})

            :draw ->
              acc
              |> Map.put(w, {%{opponent_rank: b, colour: "w", result: "="}, 0.5})
              |> Map.put(b, {%{opponent_rank: w, colour: "b", result: "="}, 0.5})
          end
      end)

    Enum.map(players, fn p ->
      case Map.fetch(games, p.rank) do
        {:ok, {game, points}} -> %{p | points: p.points + points, games: p.games ++ [game]}
        :error -> p
      end
    end)
  end

  # Article 5.2.5 only decides a board where NEITHER player holds a colour
  # preference, and after round 1 a preference is exactly what playing gives
  # you. So a round-2 board is 5.2.5s only between two players who sat round
  # 1 out - which is why all seventeen firings were in round 2 and none was
  # common. A requested bye before round 1 is how a real tournament produces
  # them, and how the corpus did (PAIRING_FUZZ_BYE_PCT).
  def requested_byes(players, pct) do
    Enum.map(players, fn p ->
      if :rand.uniform(100) <= pct do
        {code, points} = Enum.random([{"H", 0.5}, {"Z", 0.0}])

        %{
          p
          | points: p.points + points,
            games: [%{opponent_rank: nil, colour: nil, result: code}]
        }
      else
        p
      end
    end)
  end

  def run(seed, range, rounds) do
    :rand.seed(:exsss, {seed, seed * 7919, seed * 104_729})
    players = roster(Enum.random(range))

    bye_pct = String.to_integer(System.get_env("BYE_PCT", "20"))
    players = requested_byes(players, bye_pct)

    with {:ok, r1} when r1 != [] <- Gacrux.pair(trf(players, rounds)),
         after_r1 = apply_round(players, r1, seed),
         text2 = trf(after_r1, rounds),
         {:ok, r2} when r2 != [] <- Gacrux.pair(text2) do
      parsed = Trf.parse(text2)
      field = parsed.players
      by_rank = Map.new(field, &{&1.rank, &1})
      numbers = Pairing.arrival_numbers(field, 2)
      boards = for {w, b} <- r2, not is_nil(b), do: {w, b}

      case ColourArticle.article_5_2_5_consistency(boards, by_rank, numbers) do
        {:inconsistent, whites, blacks} ->
          {:hit,
           %{
             seed: seed,
             whites: whites,
             blacks: blacks,
             trf: text2,
             boards: boards,
             by_rank: by_rank,
             numbers: numbers,
             field: field,
             r1: r1,
             r2: r2
           }}

        other ->
          {other, seed}
      end
    else
      other -> {:skipped, seed, other}
    end
  rescue
    e -> {:raised, seed, Exception.message(e)}
  end
end

[seeds, lo, hi] =
  case System.argv() do
    [] -> [60, 8, 16]
    args -> Enum.map(args, &String.to_integer/1)
  end

unless Gacrux.available?() do
  IO.puts("Gacrux is not available at #{Gacrux.script_path()} - set GACRUX_DIR.")
  System.halt(1)
end

IO.puts("seeds=#{seeds} players=#{lo}..#{hi}, checking round 2 for a 5.2.5 self-contradiction\n")

results =
  1..seeds
  |> Task.async_stream(&Probe.run(&1, lo..hi, 5),
    max_concurrency: 4,
    timeout: :infinity,
    ordered: true
  )
  |> Enum.map(fn {:ok, r} -> r end)

hits = for {:hit, detail} <- results, do: detail
tally = Enum.frequencies_by(results, &elem(&1, 0))

IO.puts("outcomes: #{inspect(tally)}")
IO.puts("self-contradictions: #{length(hits)}\n")

case hits do
  [] ->
    IO.puts("No round-2 contradiction reproduced in this sample.")

  [detail | _] ->
    IO.puts(
      "=== seed #{detail.seed}: #{detail.whites} board(s) imply White, #{detail.blacks} imply Black ===\n"
    )

    IO.puts("Gacrux round 1: #{inspect(detail.r1)}")
    IO.puts("Gacrux round 2: #{inspect(detail.r2)}\n")

    IO.puts("Every board 5.2.5 decides, and what it implies:")

    for {w, b} <- detail.boards,
        implied = ColourArticle.implied_initial_colour({w, b}, detail.by_rank, detail.numbers),
        not is_nil(implied) do
      a = detail.by_rank[w]
      c = detail.by_rank[b]

      top =
        if {-a.points, a.rank} <= {-c.points, c.rank}, do: a, else: c

      IO.puts(
        "  #{w}(#{a.points}) W vs #{b}(#{c.points}) B - " <>
          "higher placed: #{top.rank}, arrival number #{detail.numbers[top.rank]} " <>
          "(#{if rem(detail.numbers[top.rank], 2) == 1, do: "odd", else: "even"}), " <>
          "took #{if top.rank == w, do: "White", else: "Black"} " <>
          "=> initial colour was #{if implied, do: "WHITE", else: "BLACK"}"
      )
    end

    IO.puts("\nArrival numbers: #{inspect(Enum.sort(detail.numbers))}")

    IO.puts("\nColour history of everyone on a 5.2.5 board (blank = no game played):")

    ranks =
      detail.boards
      |> Enum.flat_map(fn {w, b} -> [w, b] end)
      |> Enum.uniq()
      |> Enum.sort()

    for rank <- ranks do
      p = detail.by_rank[rank]
      colours = p.games |> Enum.map(&(&1[:colour] || "-")) |> Enum.join("")
      IO.puts("  #{rank}: #{p.points} pts, colours #{inspect(colours)}")
    end

    path = Path.join(System.tmp_dir!(), "gacrux_5_2_5_seed#{detail.seed}.trf")
    File.write!(path, detail.trf)
    IO.puts("\nThe round-2 input Gacrux was given: #{path}")
end
