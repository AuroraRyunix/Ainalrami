defmodule Ainalrami.TeamPairing.Explanation do
  @default_limit 10
  @look_past 50

  @moduledoc """
  The reasons behind a team round, as `Ainalrami.TeamPairing.pair_round/2`
  reports them when called with `explain: true`.

  An arbiter asked "why did this team float?" or "why White?" needs the
  engine's own reasons, not a host's reconstruction of them - a
  reconstruction explains what the host THINKS the rule is. So the recording
  happens inside the walk that makes the decision, and nowhere else.

  ## Shape

      %{
        limit: 10,
        bye: nil | %{
          tpn: tpn, score: n, matches_played: n,
          ineligible: [%{tpn: tpn, reasons: [:had_pab | :won_by_forfeit]}],
          ineligible_omitted: n,
          passed_over: [%{tpn: tpn, score: n, matches_played: n}],
          passed_over_omitted: n,
          next: nil | %{tpn: tpn, score: n, matches_played: n},
          decided_by: nil | "3.4.2" | "3.4.3" | "3.4.4"
        },
        brackets: [%{
          score: n, residents: [tpn], upfloaters: [tpn],
          selection: %{
            c4: n,
            sizes_without_legal_set: [n],
            chosen: set,
            runner_up: nil | set,
            decided_by: nil | "C4" | "C5" | "C6" | "C7" | "3.5.4",
            considered: [set], considered_omitted: n,
            rejected: [rejected_set], rejected_omitted: n
          }
        }],
        pairs: [%{white: tpn, black: tpn, first_team: tpn,
                  first_team_rule: "4.2.n", colour_rule: "4.3.n"}]
      }

      set          = %{upfloaters: [tpn], c4: n, c5: [score], c6: n | nil, c7: n | nil}
      rejected_set = %{upfloaters: [tpn], c4: n, c5: [score], failed: "C1" | "C3"}

  `brackets` and `pairs` are in the same order as the result's own
  `brackets` and `pairs`.

  ### The bye (3.4)

  `ineligible` are the teams [C2] took out, with which clause. `passed_over`
  are the eligible teams ahead of the bye in 3.4.2-3.4.4's order that the
  engine tried and found would leave the rest unpairable (3.4.1) - the
  engine's own failed checks, in order. `next` is the eligible team right
  behind the bye in that order, and `decided_by` the first of 3.4.2 (lower
  score), 3.4.3 (more matches played) or 3.4.4 (larger TPN) on which the bye
  ranks ahead of it; nil when nobody is behind it. `next` was not itself
  checked against 3.4.1 and did not need to be.

  ### Upfloaters (3.5)

  A set's `upfloaters` are in 3.5.3's order (score descending, then TPN).
  `c4` is its size, `c5` its [C5] profile - the upfloaters' scores in
  ASCENDING order, a lexicographically larger list being better - `c6` the
  extra upfloaters the following scoregroup's bracket would need, and `c7`
  the upfloaters that floated last round (0 in the last two rounds). `c6` and
  `c7` are nil for a set whose [C5] profile already lost, because the engine
  never works them out.

  `rejected` are sets of the sizes tried that no legal pairing exists for:
  `"C1"` when the bracket itself cannot be paired without a rematch, `"C3"`
  when it can but the teams left below it cannot. `sizes_without_legal_set`
  are the sizes smaller than `c4` at which every set was rejected.

  `decided_by` names the FIRST criterion, in 2.3's priority, on which
  `chosen` beats `runner_up`, the best other set that can be paired:

    * `"C5"`, `"C6"`, `"C7"` - a worse profile, more extra upfloaters below,
      more previous floaters;
    * `"3.5.4"` - equal on all of those, and later in the lexicographic order;
    * `"C4"` - no other set of this size can be paired at all, so any
      alternative has more upfloaters (`runner_up` is nil). This includes a
      scoregroup that needs no upfloaters: the empty set is the only set of
      size zero;
    * nil - the runner-up search stopped at its bound first (see below), so
      the engine does not claim a reason.

  ## Finding the runner-up, and why the pairing cannot change

  3.5.5 takes the FIRST set that complies, so the walk stops as soon as it
  can prove nothing later is better - which usually means it never looks at
  the set that came second. Naming the deciding criterion needs that set, so
  when explaining, the walk's own stopping point is followed by a short
  look past it, in the same order, for the best other legal set.

  That look past runs after the choice is made and only reads: it cannot
  alter `chosen`. A budget or oracle limit hit while looking past ends the
  look, marks `decided_by` nil, and never turns a round into an error. The
  validation suite checks the other half - that a round paired with
  `explain: true` returns exactly the `pairs`, `bye` and `brackets` it returns
  without.

  ## The bound

  Recorded lists are capped at `limit` entries each (`:explain_limit`,
  default #{@default_limit}): per bracket `considered` and `rejected`, and for the bye
  `ineligible` and `passed_over`. What is cut is counted in the matching
  `*_omitted` field. `chosen`, `runner_up`, `next` and one entry per pair are
  always kept. The look past the stopping point examines at most
  #{@look_past} further sets per bracket. So a bracket's record is O(limit) whatever
  the field size, and the work added is at most fifty legality checks (and
  [C6] look-aheads) per bracket.
  """

  @doc false
  def default_limit, do: @default_limit

  @doc false
  def look_past, do: @look_past

  @doc """
  The first criterion, in C.04.6 2.3's priority, on which `chosen` beats
  `runner_up`. Both are `set` maps as in the moduledoc; nil `runner_up` is
  `"C4"`.

  [C5]'s profile compares as a list of ascending scores where LARGER is
  better, [C6] and [C7] as counts where smaller is better. A runner-up that
  ties on all four is beaten on 3.5.4's order.
  """
  def decided_by(_chosen, nil), do: "C4"

  def decided_by(chosen, runner_up) do
    cond do
      chosen.c4 != runner_up.c4 -> "C4"
      chosen.c5 != runner_up.c5 -> "C5"
      chosen.c6 != runner_up.c6 -> "C6"
      chosen.c7 != runner_up.c7 -> "C7"
      true -> "3.5.4"
    end
  end

  @doc """
  The criterion of 3.4.2-3.4.4 on which the bye team ranks ahead of `next`,
  the eligible team after it; nil when there is none.
  """
  def bye_decided_by(_chosen, nil), do: nil

  def bye_decided_by(chosen, next) do
    cond do
      chosen.score != next.score -> "3.4.2"
      chosen.matches_played != next.matches_played -> "3.4.3"
      true -> "3.4.4"
    end
  end

  # ------------------------------------------------------------------
  # Bounded lists: the first `limit` entries, and a count of the rest.
  # ------------------------------------------------------------------

  @doc false
  def bounded, do: %{items: [], total: 0}

  @doc false
  def push(%{items: items, total: total}, item, limit) do
    if total < limit,
      do: %{items: [item | items], total: total + 1},
      else: %{items: items, total: total + 1}
  end

  @doc false
  def items(%{items: items}), do: Enum.reverse(items)

  @doc false
  def omitted(%{items: items, total: total}), do: total - length(items)
end
