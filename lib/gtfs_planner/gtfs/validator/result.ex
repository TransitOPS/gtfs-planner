defmodule GtfsPlanner.Gtfs.Validator.Result do
  @moduledoc """
  Represents the result of a GTFS validation run.

  Contains summary statistics, detailed notices, timing information,
  and metadata about when the validation was performed.
  """

  @enforce_keys [:summary, :notices, :duration_ms, :validated_at]
  defstruct [:summary, :notices, :duration_ms, :validated_at]

  @type t :: %__MODULE__{
          summary: %{
            errors: non_neg_integer(),
            warnings: non_neg_integer(),
            infos: non_neg_integer()
          },
          notices: [
            %{
              code: String.t(),
              severity: String.t(),
              total_notices: non_neg_integer(),
              notices: [map()]
            }
          ],
          duration_ms: non_neg_integer(),
          validated_at: DateTime.t()
        }
end
