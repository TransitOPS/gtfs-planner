defmodule GtfsPlanner.Gtfs.Validator.Result do
  @moduledoc """
  Represents the result of a GTFS validation run.

  Contains summary statistics, detailed notices, timing information,
  and metadata about when the validation was performed.

  The optional provenance fields describe the exact input the validator was given.
  They default to nil, so existing callers and retained reports stay valid; only a
  run that actually captured its input bytes and settings carries them.
  """

  @enforce_keys [:summary, :notices, :duration_ms, :validated_at]
  defstruct [
    :summary,
    :notices,
    :duration_ms,
    :validated_at,
    :checked_zip_sha256,
    :checked_export_profile,
    :validator_version
  ]

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
          validated_at: DateTime.t(),
          checked_zip_sha256: String.t() | nil,
          checked_export_profile:
            GtfsPlanner.Validations.ValidationRun.checked_export_profile() | nil,
          validator_version: String.t() | nil
        }
end
