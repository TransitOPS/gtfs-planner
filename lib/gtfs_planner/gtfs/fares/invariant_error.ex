defmodule GtfsPlanner.Gtfs.Fares.InvariantError do
  @moduledoc """
  Raised when a managed version's stored fare rows already break an invariant the
  operator's own edit would leave behind.

  `GtfsPlanner.Gtfs.Fares.Normalize.run!/2` raises it when the version's rider
  categories do not leave exactly one default (R8), the rule the validator reports
  as `fare_product_with_multiple_default_rider_categories` and the export's own
  `rider_categories.txt` column. Normalize runs inside the writer's transaction,
  so the raise rolls that whole write back: a version whose stored rows are
  already broken is a state for the operator to repair in the editor, not one to
  re-import silently. A writer that cannot commit its own edit raises this rather
  than returning an error tuple, because the invariant is not about its argument.
  """

  defexception [:message]
end
