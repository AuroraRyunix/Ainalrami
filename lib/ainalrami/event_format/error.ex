defmodule Ainalrami.EventFormat.Error do
  @moduledoc """
  Raised by `Ainalrami.EventFormat.pair_next_round/2` when the event's own
  format leaves no round to give: a match's second leg whose first leg
  cannot be replayed as it stands (a player seated in the first leg who has
  a result recorded for the second already, or one who sat the first leg
  out and is in the second), or match format asked for together with
  pairing groups, which OpenPairings does not pair either.
  """
  defexception [:message]
end
