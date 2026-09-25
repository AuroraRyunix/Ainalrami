defmodule Ainalrami.TeamPairing.Bracket do
  @moduledoc """
  Article 3.6 - pairing one bracket.

  This is the module where team pairing stops resembling the individual
  system. C.04.3 defines a lexicographic weight ladder and asks for the best
  candidate under it; 3.6 defines an ORDER over pairings and asks for the
  first one satisfying a predicate.

  ## The order (3.6.1-3.6.3)

  A pairing is a set of pairs covering the bracket. In each pair the smaller
  TPN is the *top member*, the larger the *bottom member*. The identifier is
  the top members ascending, followed by their corresponding bottom members;
  pairings sort by that identifier lexicographically. The regulation's own
  example: `11-24  16-6  10-9  8-4` has identifier `4 6 9 11 8 16 10 24`.

  Since the top-half of every identifier has the same length, comparing
  identifiers is: compare the sorted top-member sets, and only on a tie
  compare the bottom sequence.

  ## The predicate (3.6.4), and why it is not simply a filter

  3.6.4 says to take the first pairing "that also complies with criteria
  [C1], [C8], [C9] and [C10]". [C1] is a genuine predicate - no rematches.
  The other three are *minimisation* criteria ("minimise the number of teams
  whose colour preference is not fulfilled"), and a pairing cannot comply
  with a minimisation in isolation: it complies by achieving the minimum
  attainable over the bracket's legal pairings.

  So the answer is the pairing that minimises `{c8, c9, c10}`
  lexicographically, tie-broken by identifier order.

  ## How it is computed (since 2026-09-25): exact, no budget

  1. **The walk, as a fast path.** Top-sets in lexicographic order, and
     within each the bottom assignments in lexicographic order, pruned by
     [C1] and a completion check - so its first complete candidate is the
     first legal pairing in identifier order. If that candidate scores
     `{0, 0, 0}` it is the answer (nothing scores lower, nothing legal comes
     earlier), and that is what this module has always returned there; a
     round-one bracket, or any bracket whose preferences can all be met by
     the first legal pairing, ends here. A walk that finishes without any
     candidate is a proof that no legal pairing exists. The walk is capped at
     20,000 steps; beyond that, or when the first candidate costs
     anything, it hands over to step 2.
  2. **Two minimum-cost perfect matchings** (`exact/1`, method in
     `docs/team-proof-large-fields.md` section 3): the criteria and the
     identifier packed into one integer cost per pair, one matching for the
     least criteria and the first top set, one confined to that top set for
     the first bottom sequence. The matcher is the engine's own
     `Ainalrami.WeightedMatching` (a port of bbpPairings' Galil/Micali/Gabow
     code), not the proof's test-only reference.

  Until 2026-09-25 step 2 was the walk continued under a candidate budget
  (`:max_candidates`, default 200,000) and a step budget (`:max_steps`,
  default 10,000,000), keeping the best pairing found when either ran out.
  On large early-round brackets that returned a legal pairing 3.6 does not
  choose (seed 126 of the large-field proof at the default budget, seed 480
  even at 10,000,000 candidates). Both options are still ACCEPTED, and
  ignored: the result is exact whatever they say, `exhaustive?` is always
  true, and `{:error, :budget_exhausted}` is no longer returned from here.
  """

  alias Ainalrami.TeamPairing.{Matching, Team}
  alias Ainalrami.WeightedMatching

  import Bitwise

  # The fast path's walk budget. The walk's first candidate is found in a few
  # hundred steps on an ordinary bracket (402 for a forty-team round one);
  # only a tangled one runs longer, and then the matching answers instead.
  @fast_path_steps 20_000

  @doc """
  Pairs `teams` (a bracket - an even-sized list) and returns

      {:ok, %{pairs: [{top_tpn, bottom_tpn}], scores: {c8, c9, c10},
              candidates: n, steps: n, exhaustive?: true}}

  or `{:error, :no_legal_pairing}` when [C1] admits none. `pairs` are in the
  identifier's order (tops ascending). `candidates` and `steps` are the fast
  path's walk when it answered, and 0 when the matching did.

  Options:

    * `:type` / `:last_round?` - colour-preference type (1.7), for [C8]/[C9].
    * `:upfloater_tpns` - the TPNs in this bracket that are upfloaters, for
      [C10] (which counts upfloaters' OPPONENTS that were floaters in the
      previous round). Empty for a bracket of residents only.
    * `:last_two_rounds?` - [C7] and [C10] "with the exception of the last
      two rounds". When true, [C10] contributes nothing.
    * `:max_candidates`, `:max_steps` - accepted for compatibility and
      ignored (see the module doc).
  """
