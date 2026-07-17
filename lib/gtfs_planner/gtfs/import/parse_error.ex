defmodule GtfsPlanner.Gtfs.Import.ParseError do
  @moduledoc """
  Finite, sanitized diagnostic contract shared by strict CSV parsing, reviewed
  entity parsing, archive normalization, importer errors, and LiveView copy.

  `metadata` may contain bounded values needed for rendering, such as expected
  and actual field counts or a duplicate key, but must not contain stack traces,
  arbitrary exception messages, source row contents, or uploaded file contents.
  Unexpected failures are logged with sanitized operator context and exposed to
  the UI only as `:unexpected_parser_failure`.
  """

  @type reason ::
          :empty_content
          | :invalid_utf8
          | :blank_header
          | :duplicate_header
          | :wrong_field_count
          | :unterminated_quote
          | :malformed_quote
          | :forbidden_control_character
          | :missing_natural_key_header
          | :blank_natural_key
          | :duplicate_natural_key
          | :semantic_row
          | :unexpected_parser_failure
          | :archive_unreadable
          | :archive_too_large
          | :nested_archive
          | :duplicate_entity_file

  @enforce_keys [:file, :reason]
  defstruct [:file, :row, :field, :reason, metadata: %{}]

  @type t :: %__MODULE__{
          file: String.t(),
          row: pos_integer() | nil,
          field: String.t() | nil,
          reason: reason(),
          metadata: map()
        }
end
