defmodule Ainalrami.InitialColourTest do
  @moduledoc """
  Article 5.2.5, and which number its parity is taken on.

  > **5.2.5** If the higher ranked player has an odd TPN, give them the
  > initial-colour; otherwise, give them the opposite colour.

  The question this file used to exist to defend was whether that number is
  the TPN as C.04.2 Article 2 fixes it for the tournament, or a numbering
  that skips players who have never been paired. This engine implemented the
  first reading; both bbpPairings and Gacrux implement the second.

  Both of them, identically. A second claim circulated in this repo - that
  the two references renumbered differently from *each other*, so that
  "agree with the references" was not even a well-defined target. That was
  false when it was written: it was the hypothesis held before the probes
  ran, and the probes refuted it. Re-confirmed against the local binary on
  2026-08-27. Matching them exactly is a well-defined target and is now the
  requirement.

  The FIDE Systems of Pairings and Programs Commission answered on
  2026-08-27, and answered against this engine. Its reasoning is C.04.2
  Article 2.4:

  > **2.4** A Late Entry is a participant who is only taken into account for
  > the pairing of rounds after the first. If admitted to the tournament,
  > late entries receive no points for unplayed rounds […] and are given an
  > appropriate TPN and **paired only when they actually arrive**.

  Both sides argued from that one sentence. This engine read it as granting
  the number up front and making only the PAIRING wait; the SPP reads it as
  withholding the number until the arrival. We read it the wrong way round,
  and the SPP is the authority on C.04.3, so the matter is closed.

  So 5.2.5's parity is taken on the player's position among the players who
  have ARRIVED - recomputed every round, and shifted for everyone below a
  late entrant the moment that entrant arrives. It is not a TPN and this
  file does not call it one.

  The distinction is invisible on a full field, where position and TPN
  coincide. It appears the moment anyone sits a round out, which is why
  every one of these cases has a bye in it.

  ## What counts as having arrived

  Narrower than "arrive" suggests, and pinned against bbpPairings v6.0.0
  rather than reasoned from the text. A player who never sits at a board but
  is entered into a pairing - one who takes the pairing-allocated bye, or
  whose opponent forfeits - HAS arrived. A player handed a half-point or
  full-point bye by the arbiter before the round was paired has NOT.
  `Ainalrami.Trf.participated_in_pairing?/1` expresses the whole of it, and
  the `describe` block below is that probe table turned into assertions.

  ## Where the evidence for each half of this lives

  Worth stating, because the two numberings were NOT measured the same way
  and the headline figures invite the assumption that they were.

  - `arrival_numbers/2`, the ALLOCATION's numbering, is what the corpus
    measured: `Ainalrami.BbppairingsComparisonTest` supplies
    `initial_colour:` on every comparison and `FuzzTournament` writes the
    matching `152`, so those runs exercise the allocation and nothing else.
  - `arrival_numbers_at/2`, the INFERENCE's numbering, is unreachable from
    that harness for exactly the same reason - a stated `152`
    short-circuits `pair_next_round/2`'s `||`. Its coverage is the last
    `describe` block in this file, plus the two no-`152` tests against the
    real binary in `Ainalrami.BbppairingsComparisonTest`, which are its
    only contact with a reference.

  These cases run with no binary present, so they are the part that holds
  on a fresh checkout.
  """

  use ExUnit.Case, async: true

  alias Ainalrami.Pairing

  describe "5.2.5 takes the parity of the arrival numbering" do
    test "a full field alternates the initial colour down the ranking" do
      pairs = Pairing.pair_next_round(field(10), expected_rounds: 5, initial_colour: "w")

      # Board by board: the higher-ranked player of each pair takes White on
      # an odd number and Black on an even one. Nobody sits out, so every
      # player has arrived, the numbering is the identity and rank IS the
      # number. This is the case both readings always agreed on, and after
      # the ruling it is the control that proves the renumbering left the
      # clean field alone.
      for {white, black} <- pairs, black != nil do
        [top, bottom] = Enum.sort([white, black])
        expected_white = if rem(top, 2) == 1, do: top, else: bottom

        assert white == expected_white,
               "board #{top}v#{bottom}: #{top} is " <>
                 "#{if rem(top, 2) == 1, do: "odd, so it takes White", else: "even, so it takes Black"}"
      end
    end

    test "a player who has never been paired does not get a number, and everyone below shifts" do
      # TPN 1 takes a zero-point bye and has never been paired, so under
      # C.04.2 2.4 they have no number at all. TPN 2 is therefore number 1 -
      # odd - and takes the initial colour, where the fixed-TPN reading gave
      # them its opposite.
      #
      # This is the whole dispute reduced to one board, and it is the board
      # the SPP decided. Both references answer White here; so, now, do we.
      pairs = Pairing.pair_next_round(field(10, [1]), expected_rounds: 5, initial_colour: "w")

      {white, black} = Enum.find(pairs, fn {w, b} -> 2 in [w, b] and b != nil end)

      assert white == 2,
             "TPN 1 has never been paired, so TPN 2 is arrival number 1 - " <>
               "odd - and 5.2.5 gives them the initial colour"

      refute black == 2
    end

    test "only players whose own parity the renumbering changes take a different colour" do
      # TPNs 1 and 3 have never been paired, so the numbered players are
      # 2,4,5,6,7,8,9,10 -> numbers 1..8. That flips the parity of TPN 2
      # (number 1) and leaves 4, 5 and 6 alone (numbers 2, 3, 4), because
      # an even count of skipped players above you preserves your parity.
      #
      # So exactly one of the four boards moves and three do not, which is a
      # far sharper signature than "all the colours changed" - and it is the
      # signature actually measured against the real binary.
      players = field(10, [1, 3])
      pairs = Pairing.pair_next_round(players, expected_rounds: 5, initial_colour: "w")

      # The numbering, restated here from the rule rather than read out of
      # the engine: a test that asked the engine for its own numbering could
      # not catch the engine getting it wrong.
      numbers =
        [2, 4, 5, 6, 7, 8, 9, 10] |> Enum.with_index(1) |> Map.new()

      assert Map.fetch!(numbers, 2) == 1, "the numbering itself, pinned"
      assert Map.fetch!(numbers, 4) == 2

      for {white, black} <- pairs, black != nil do
        [top, bottom] = Enum.sort([white, black])
        number = Map.fetch!(numbers, top)
        expected_white = if rem(number, 2) == 1, do: top, else: bottom

        assert white == expected_white,
               "board #{top}v#{bottom}: #{top} is arrival number #{number}"
      end

      # And the one board that differs from the overturned reading, named
      # outright so a regression cannot pass by changing the loop above.
      {white, _black} = Enum.find(pairs, fn {w, b} -> 2 in [w, b] and b != nil end)
      assert white == 2, "TPN 2 is number 1: this is the board the ruling moved"
    end

    test "the initial colour is read, not assumed: 152 B mirrors everything" do
      white_draw = Pairing.pair_next_round(field(10), expected_rounds: 5, initial_colour: "w")
      black_draw = Pairing.pair_next_round(field(10), expected_rounds: 5, initial_colour: "b")

      # Key each board by its two ranks so the two runs are compared board
      # for board. Sorting the pairs themselves would not do it: flipping a
      # colour rewrites `{3, 8}` as `{8, 3}`, which sorts to a different
      # position, and zipping the two sorted lists would then line up
      # boards that are not the same board.
      by_board = fn pairs ->
        for {w, b} <- pairs, b != nil, into: %{}, do: {Enum.sort([w, b]), w}
      end

      whites = by_board.(white_draw)
      blacks = by_board.(black_draw)

      assert Map.keys(whites) |> Enum.sort() == Map.keys(blacks) |> Enum.sort(),
             "the drawing of lots decides colours, never who plays whom"

      for {board, white_under_w} <- whites do
        refute Map.fetch!(blacks, board) == white_under_w,
               "board #{inspect(board)} must flip when the draw flips"
      end
    end
  end

  # ------------------------------------------------------------------
  # Which round-one entries are an ARRIVAL
  # ------------------------------------------------------------------
  #
  # Every case below is one row of a table probed against bbpPairings
  # v6.0.0: a six-player position per row, rebuilt here and read the same
  # way the probe read it. What those probes established is exactly this
  # table - for each round-one entry code, whether the player holding it is
  # given a number in the next round's parity, or skipped - and this block
  # is the record of it rather than a pointer to one. A row that is not
  # asserted here is a row nobody can reproduce, whatever became of the
  # scripts that produced it.
  #
  # The instrument: TPN 1 holds the entry under test in round one and sits
  # round two out, TPNs 2-5 have never been paired and are all paired in
  # round two, and TPN 6 mirrors TPN 1's entry when the case needs a real
  # opponent. Exactly ONE player of uncertain status sits above the board
  # being read - one, never two, because an even number of skipped players
  # preserves parity and would prove nothing - so TPN 2 is arrival number 1
  # when TPN 1 is skipped and number 2 when it is not.
  #
  # 5.2.5 is only reached where NEITHER player holds a colour preference,
  # which by Article 1.7.4 means neither has played a game. TPNs 2-5 have
  # nothing but a zero-point bye, so the board TPN 2 is on is a direct
  # readout of TPN 2's parity, and nothing else can be deciding it.
  describe "what counts as an arrival" do
    test "a played game against a real opponent counts" do
      assert arrival(g(6, "w", "="), 0.5, g(1, "b", "="), 0.5) == :counted
    end

    test "a played game spelled with a letter counts, like the symbol it is" do
      # W/D/L are ordinary played results that simply do not reach the
      # rating report. `game_was_played?/1` already says so; this pins that
      # the arrival test agrees.
      assert arrival(g(6, "w", "W"), 1.0, g(1, "b", "L"), 0.0) == :counted
    end

    test "a forfeit WIN against a real opponent counts" do
      assert arrival(g(6, "w", "+"), 1.0, g(1, "b", "-"), 0.0) == :counted
    end

    test "a forfeit LOSS against a real opponent counts, both ways round" do
      # Double forfeit, and the opponent-takes-the-win spelling. Both are
      # arrivals: the pairing happened, whatever became of the game.
      assert arrival(g(6, "w", "-"), 0.0, g(1, "b", "-"), 0.0) == :counted
      assert arrival(g(6, "w", "-"), 0.0, g(1, "b", "+"), 1.0) == :counted
    end

    test "the pairing-allocated bye counts - it is an arrival with no opponent" do
      assert arrival(bye("U"), 1.0) == :counted
    end

    test "an opponentless forfeit WIN counts" do
      # `0000 - +`. bbpPairings' test is
      # `opponent != id || resultChar == 'U' || resultChar == '+'`, and the
      # last disjunct is why this counts with nothing in the opponent field.
      assert arrival(bye("+"), 1.0) == :counted
    end

    test "an arbiter's zero-point bye does NOT count" do
      assert arrival(bye("Z"), 0.0) == :skipped
    end

    test "an arbiter's half-point bye does NOT count" do
      assert arrival(bye("H"), 0.5) == :skipped
    end

    test "an arbiter's FULL-point bye does not count, though it scores what the U bye scores" do
      # The sharpest row in the table. `F` and `U` are both worth 1.0 and
      # both leave the player without an opponent, and they land on opposite
      # sides of the rule - so the discriminator is the result CODE, and an
      # implementation that reached for the score would get exactly this
      # case wrong and nothing else.
      assert arrival(bye("F"), 1.0) == :skipped
      assert arrival(bye("U"), 1.0) == :counted
    end

    test "an opponentless forfeit LOSS does not count, though `2 w -` does" do
      # `-` is the only code whose membership turns on the opponent field.
      # This pair is the split, asserted together so neither half can be
      # changed without the other being looked at.
      assert arrival(bye("-"), 0.0) == :skipped
      assert arrival(g(6, "w", "-"), 0.0, g(1, "b", "-"), 0.0) == :counted
    end

    test "a blank round does not count" do
      assert arrival(blank(), 0.0) == :skipped
    end
  end

  describe "the numbering is a function of the round" do
    test "being in THIS round's pairing pool is enough, even having never played" do
      # TPN 1 has a blank round one - never paired, so under every case
      # above it would be skipped. Here it is available for round two, alone
      # on 0.0 against four half-point-bye players, so it enters the pairing
      # and takes the pairing-allocated bye rather than an opponent.
      #
      # It is counted anyway. "Paired this round" means ENTERED THE POOL,
      # which is decidable before the pairing runs - not "was given an
      # opponent", which is not.
      players = [
        %{player(1) | points: 0.0, games: [blank()]}
        | for(rank <- 2..5, do: %{player(rank) | points: 0.5, games: [bye("H")]})
      ]

      pairs = Pairing.pair_next_round(players, expected_rounds: 5, initial_colour: "w")

      assert {1, nil} in pairs, "TPN 1 should take the pairing-allocated bye"

      {_white, black} = Enum.find(pairs, fn {w, b} -> 2 in [w, b] and b != nil end)

      assert black == 2,
             "TPN 1 entered the pool, so it is number 1 and TPN 2 is number 2 - even"
    end

    test "a late entrant is skipped until they arrive and counted from then on" do
      # The same player read in two consecutive rounds. TPN 1 has a blank
      # round one, is still absent for round two, arrives in round two by
      # playing TPN 6, and sits round three out.
      #
      # Round two: TPN 1 has never been paired, so TPN 2 is number 1.
      # Round three: TPN 1 arrived, so TPN 2 is number 2 - and TPN 2's board
      # flips colour without TPN 2's own history changing at all. The
      # numbering is a function of the round, not a property of a player.
      round_two = [
        %{player(1) | points: 0.0, games: [blank(), bye("Z")]},
        %{player(2) | points: 0.0, games: [bye("Z")]},
        %{player(3) | points: 0.0, games: [bye("Z")]},
        %{player(4) | points: 0.0, games: [bye("Z")]},
        %{player(5) | points: 0.0, games: [bye("Z")]},
        %{player(6) | points: 0.0, games: [bye("Z"), bye("Z")]}
      ]

      pairs_two = Pairing.pair_next_round(round_two, expected_rounds: 5, initial_colour: "w")
      {white_two, _} = Enum.find(pairs_two, fn {w, b} -> 2 in [w, b] and b != nil end)

      assert white_two == 2, "round two: TPN 1 has not arrived, so TPN 2 is number 1"

      # Now play round two: TPN 1 meets TPN 6, and everyone sits round three
      # out except 2-5.
      round_three = [
        %{player(1) | points: 0.5, games: [blank(), g(6, "w", "="), bye("Z")]},
        %{player(2) | points: 0.0, games: [bye("Z"), bye("Z")]},
        %{player(3) | points: 0.0, games: [bye("Z"), bye("Z")]},
        %{player(4) | points: 0.0, games: [bye("Z"), bye("Z")]},
        %{player(5) | points: 0.0, games: [bye("Z"), bye("Z")]},
        %{player(6) | points: 0.5, games: [bye("Z"), g(1, "b", "="), bye("Z")]}
      ]

      pairs_three = Pairing.pair_next_round(round_three, expected_rounds: 5, initial_colour: "w")
      {_, black_three} = Enum.find(pairs_three, fn {w, b} -> 2 in [w, b] and b != nil end)

      assert black_three == 2,
             "round three: TPN 1 arrived in round two, so TPN 2 is number 2 - even"
    end

    test "withdrawing does not un-arrive a player" do
      # TPN 1 played rounds one and two and then withdrew. It is still
      # counted in round three: 2.4 gates the arrival, and nothing gives the
      # number back.
      players = [
        %{player(1) | points: 1.0, games: [g(6, "w", "="), g(6, "b", "="), bye("Z")]},
        %{player(2) | points: 0.0, games: [bye("Z"), bye("Z")]},
        %{player(3) | points: 0.0, games: [bye("Z"), bye("Z")]},
        %{player(4) | points: 0.0, games: [bye("Z"), bye("Z")]},
        %{player(5) | points: 0.0, games: [bye("Z"), bye("Z")]},
        %{player(6) | points: 1.0, games: [g(1, "b", "="), g(1, "w", "="), bye("Z")]}
      ]

      pairs = Pairing.pair_next_round(players, expected_rounds: 5, initial_colour: "w")
      {_white, black} = Enum.find(pairs, fn {w, b} -> 2 in [w, b] and b != nil end)

      assert black == 2, "a withdrawn player who arrived keeps their number"
    end
  end

  describe "inferring the drawing of lots from a file that omits 152" do
    test "round one's own colours are the record of the draw" do
      # A file with no `152` has not lost the draw: 5.2.5 wrote it into
      # round one. Arrival number 1 is odd, so whatever colour that player
      # holds IS the initial colour.
      played = played_field(8, "w")
      assert Pairing.pair_next_round(played, expected_rounds: 5) == pair_with(played, "w")

      flipped = played_field(8, "b")
      assert Pairing.pair_next_round(flipped, expected_rounds: 5) == pair_with(flipped, "b")
    end

    test "an explicit 152 always wins over the inference" do
      played = played_field(8, "w")

      assert Pairing.pair_next_round(played, expected_rounds: 5, initial_colour: "b") ==
               pair_with(played, "b"),
             "a file that states the draw is not second-guessed by reading it back"
    end

    test "the inference renumbers too, on a round one only part of the field played" do
      # This is the case `infer_initial_colour/1` exists for, and the two
      # tests above cannot reach it: they use full fields, where the
      # numbering is the identity and the inference cannot be caught
      # applying the wrong one.
      #
      # Here TPNs 1 and 6 sat round one out and have never been paired, so
      # the numbering IN THAT ROUND was 2->1, 3->2, 4->3, 5->4. Board 2v4
      # was played with 2 White, which on number 1 - odd - means the draw
      # was White. Read against the raw TPN it would say Black instead, and
      # every no-preference board in every later round would invert.
      #
      # The number 5.2.5 runs backwards on is the same number it runs
      # forwards on, and it has to be taken as of the round being read.
      # (The PLAYER it is read off is not always the same one - see the
      # test below.)
      field = [
        %{player(1) | points: 0.0, games: [bye("Z")]},
        %{player(2) | points: 0.5, games: [g(4, "w", "=")]},
        %{player(3) | points: 0.5, games: [g(5, "b", "=")]},
        %{player(4) | points: 0.5, games: [g(2, "b", "=")]},
        %{player(5) | points: 0.5, games: [g(3, "w", "=")]},
        %{player(6) | points: 0.0, games: [bye("Z")]}
      ]

      assert Pairing.pair_next_round(field, expected_rounds: 5) == pair_with(field, "w"),
             "number 1 held White in round one, so the draw was White"

      refute Pairing.pair_next_round(field, expected_rounds: 5) == pair_with(field, "b")
    end

    test "the parity is read off the player holding the colour, not the top of their board" do
      # THE ONE PLACE THE INFERENCE IS NOT AN EXACT INVERSE, pinned so it
      # cannot be "tidied up" without the evidence being re-read.
      #
      # `assign_colour_round_one/3` takes the parity of the TOP of the
      # board, where top is Article 1.2 - SCORE first, TPN only to break the
      # tie. The inference takes it off whichever player holds a colour,
      # without asking whether they were top or bottom. The two agree
      # whenever the first coloured round is round ONE (everyone on zero, so
      # top is the lower TPN, and the lowest-ranked coloured player in the
      # field is necessarily a top) and can disagree after that.
      #
      # Here round one is nothing but arbiter byes, so it records no colour
      # and the inference must read round TWO. Entering round two the scores
      # are 1:0.5 2:0.5 3:1.0 4:0.0, so board 1v3 is a downfloat whose TOP
      # is 3 - and 3, on number 3, took Black. So the draw was BLACK, and an
      # exact inverse would recover Black.
      #
      # This engine recovers WHITE: player 1 is the lowest-ranked holder of
      # a colour, holds White, and is number 1. bbpPairings v6.0.0 recovers
      # White from the same file too - measured 38 times out of 38 on
      # positions where the two readings split, with 0 for the exact
      # inverse (`tools/inference_numbering_probe.exs`, INP_COUNT=200
      # INP_ROUNDS=7, 2026-08-28) - so the asymmetry is copied deliberately. 5.1 leaves the
      # initial colour to a drawing of lots and C.04.3 says nothing at all
      # about recovering a lost one, which makes the reference the only rule
      # there is. `Ainalrami.BbppairingsComparisonTest` runs the same
      # position against the real binary.
      field = [
        %{player(1) | points: 1.0, games: [bye("H"), g(3, "w", "=")]},
        %{player(2) | points: 1.0, games: [bye("H"), g(4, "w", "=")]},
        %{player(3) | points: 1.5, games: [bye("F"), g(1, "b", "=")]},
        %{player(4) | points: 0.5, games: [bye("Z"), g(2, "b", "=")]},
        %{player(5) | points: 0.0, games: [bye("Z"), bye("Z")]},
        %{player(6) | points: 0.0, games: [bye("Z"), bye("Z")]},
        %{player(7) | points: 0.0, games: [bye("Z"), bye("Z")]},
        %{player(8) | points: 0.0, games: [bye("Z"), bye("Z")]}
      ]

      # The position has to be informative, or the assertion below is empty.
      refute pair_with(field, "w") == pair_with(field, "b"),
             "the two draws must pair this field differently"

      assert Pairing.pair_next_round(field, expected_rounds: 9) == pair_with(field, "w"),
             "the parity is read off player 1 (number 1, odd, White), not off " <>
               "player 3 (the top of that board, number 3, odd, Black)"
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  # Runs the six-player instrument described above and reports whether TPN 1
  # was given an arrival number.
  #
  # TPN 2 is the top of whatever board it lands on - it is the lowest
  # numbered active player - so the board is read the same way regardless of
  # who it was paired with.
  defp arrival(entry, points, partner_entry \\ nil, partner_points \\ 0.0) do
    partner_entry = partner_entry || bye("Z")

    players = [
      %{player(1) | points: points, games: [entry, bye("Z")]},
      %{player(2) | points: 0.0, games: [bye("Z")]},
      %{player(3) | points: 0.0, games: [bye("Z")]},
      %{player(4) | points: 0.0, games: [bye("Z")]},
      %{player(5) | points: 0.0, games: [bye("Z")]},
      %{player(6) | points: partner_points, games: [partner_entry, bye("Z")]}
    ]

    pairs = Pairing.pair_next_round(players, expected_rounds: 5, initial_colour: "w")
    board = Enum.find(pairs, fn {w, b} -> 2 in [w, b] and b != nil end)

    assert board != nil, "TPN 2 must be paired for this instrument to read anything"

    # Number 1 is odd and takes the initial colour (White); number 2 is even
    # and takes its opposite.
    case board do
      {2, _} -> :skipped
      {_, 2} -> :counted
    end
  end

  defp g(opponent, colour, result),
    do: %{opponent_rank: opponent, colour: colour, result: result}

  defp bye(code), do: %{opponent_rank: nil, colour: nil, result: code}

  defp blank, do: %{opponent_rank: nil, colour: nil, result: nil}

  defp pair_with(players, colour) do
    Pairing.pair_next_round(players, expected_rounds: 5, initial_colour: colour)
  end

  # A field where round one has been played under `initial`, so the draw is
  # recoverable from the colours alone. Full, so the arrival numbering is
  # the identity.
  defp played_field(n, initial) do
    half = div(n, 2)

    for rank <- 1..n do
      {opponent, colour} =
        if rank <= half do
          {rank + half, if(rem(rank, 2) == 1, do: initial, else: invert(initial))}
        else
          top = rank - half
          {top, if(rem(top, 2) == 1, do: invert(initial), else: initial)}
        end

      %{
        player(rank)
        | points: 0.5,
          games: [%{opponent_rank: opponent, colour: colour, result: "="}]
      }
    end
  end

  defp invert("w"), do: "b"
  defp invert("b"), do: "w"

  defp field(n, byes \\ []) do
    for rank <- 1..n do
      if rank in byes do
        %{player(rank) | games: [bye("Z")]}
      else
        player(rank)
      end
    end
  end

  defp player(rank) do
    %{
      rank: rank,
      name: "P#{rank}",
      sex: "",
      title: "",
      federation: "",
      fide_rating: 2400 - rank * 10,
      fide_number: nil,
      birth_date: "",
      points: 0.0,
      games: []
    }
  end
end
