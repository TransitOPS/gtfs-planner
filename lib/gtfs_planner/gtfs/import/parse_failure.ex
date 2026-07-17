defmodule GtfsPlanner.Gtfs.Import.ParseFailure do
  @moduledoc """
  Read-only preview and bounded diagnostic summary for a reviewed entity that
  could not become a complete `ParsedEntity`.
  """

  alias GtfsPlanner.Gtfs.Import.ParseError

  @enforce_keys [
    :entity_type,
    :filename,
    :preview_records_by_key,
    :diagnostics,
    :total_error_count,
    :truncated?,
    :source_row_count
  ]
  defstruct [
    :entity_type,
    :filename,
    :preview_records_by_key,
    :diagnostics,
    :total_error_count,
    :truncated?,
    :source_row_count,
    :first_error_row,
    :last_error_row
  ]

  @type t :: %__MODULE__{
          entity_type: :level | :stop | :pathway,
          filename: String.t(),
          preview_records_by_key: %{optional(String.t()) => map()},
          diagnostics: [ParseError.t()],
          total_error_count: pos_integer(),
          truncated?: boolean(),
          source_row_count: non_neg_integer(),
          first_error_row: pos_integer() | nil,
          last_error_row: pos_integer() | nil
        }
end
