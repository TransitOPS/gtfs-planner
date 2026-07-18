defmodule GtfsPlanner.Gtfs.Import.Failure do
  @moduledoc """
  Truthful, sanitized failure contract for a full-feed GTFS import.

  A `Failure` records where an import stopped (`phase`), what kind of terminal
  outcome it is (`outcome`), the durable counts committed before the failure
  (`committed_counts`), whether those counts are certain (`counts_complete`),
  the sanitized source file/row that triggered the failure, and a fixed
  `reason_code` drawn from a bounded vocabulary.

  `from_error/2` normalizes the many internal error shapes produced by the batch
  processor, core importer, and extension importer into this contract. It never
  stores source row contents, exception messages, SQL, stack traces, or
  filesystem paths (INV-3). `to_run_attrs/1` emits only bounded, sanitized
  attributes that the `Import.Run` changeset accepts; the caller sets `state`,
  lease, and timestamp fields separately through the system-owned changeset.
  """

  alias GtfsPlanner.Gtfs.Import.ParseError

  @enforce_keys [:outcome, :phase, :committed_counts, :counts_complete, :reason_code]
  defstruct [
    :outcome,
    :phase,
    :committed_counts,
    :counts_complete,
    :failed_file,
    :failed_row,
    :reason_code
  ]

  @type outcome :: :failed | :partial | :interrupted
  @type phase :: :upload | :phase_1 | :phase_2 | :extensions | :publication | :cleanup

  @type t :: %__MODULE__{
          outcome: outcome(),
          phase: phase(),
          committed_counts: map(),
          counts_complete: boolean(),
          failed_file: String.t() | nil,
          failed_row: pos_integer() | nil,
          reason_code: String.t()
        }

  # Fixed reason vocabulary. Parser reasons reuse the bounded, sanitized
  # `ParseError` vocabulary; every other error shape maps to one of the codes
  # below. Anything unrecognized normalizes to "unknown_error".
  @parse_reason_codes ~w(
    empty_content invalid_utf8 blank_header duplicate_header wrong_field_count
    unterminated_quote malformed_quote forbidden_control_character
    missing_natural_key_header blank_natural_key duplicate_natural_key
    semantic_row unexpected_parser_failure archive_unreadable archive_too_large
    nested_archive duplicate_entity_file
  )

  @reason_codes @parse_reason_codes ++
                  ~w(
                    row_invalid constraint_violation database_error
                    missing_references image_write_failed missing_image
                    filesystem_error verification_failed executor_lost unknown_error
                  )

  @failed_file_max 255

  @doc """
  Returns the fixed reason-code vocabulary produced by `from_error/2`.
  """
  @spec reason_codes() :: [String.t()]
  def reason_codes, do: @reason_codes

  @doc """
  Maps a failure outcome to its terminal import-run state.

  `:failed` and `:partial` map to their identically named run states; `:interrupted`
  maps to `interrupted` (the uncertain-counts terminal state used when an
  executor or node is lost mid-import).
  """
  @spec outcome_to_state(t()) :: String.t()
  def outcome_to_state(%__MODULE__{outcome: outcome}) do
    Atom.to_string(outcome)
  end

  @doc """
  Normalizes an internal error term into a sanitized `Failure`.

  Options carry the context the failing term cannot supply:

    * `:phase` (required) - the import phase in which the error occurred
    * `:outcome` - defaults to `:failed`
    * `:committed_counts` - defaults to `%{}`
    * `:counts_complete` - defaults to `true` (ordinary returned failures)
    * `:failed_file` / `:failed_row` - override the values derived from the term

  The returned struct never contains row contents, exception messages, SQL,
  stack traces, or filesystem paths.
  """
  @spec from_error(term(), keyword()) :: t()
  def from_error(term, opts) do
    {reason_code, failed_file, failed_row} = classify(term)

    %__MODULE__{
      outcome: Keyword.get(opts, :outcome, :failed),
      phase: Keyword.fetch!(opts, :phase),
      committed_counts: Keyword.get(opts, :committed_counts, %{}),
      counts_complete: Keyword.get(opts, :counts_complete, true),
      failed_file: Keyword.get(opts, :failed_file, failed_file),
      failed_row: Keyword.get(opts, :failed_row, failed_row),
      reason_code: reason_code
    }
  end

  @doc """
  Serializes the failure into the bounded, sanitized attributes accepted by the
  `Import.Run` changeset.

  Only `phase`, `committed_counts`, `counts_complete`, `failed_file`,
  `failed_row`, and `reason_code` are emitted. The caller owns `state` and all
  lease/timestamp fields.
  """
  @spec to_run_attrs(t()) :: map()
  def to_run_attrs(%__MODULE__{} = failure) do
    %{
      phase: Atom.to_string(failure.phase),
      committed_counts: failure.committed_counts,
      counts_complete: failure.counts_complete,
      failed_file: failure.failed_file,
      failed_row: failure.failed_row,
      reason_code: failure.reason_code
    }
  end

  # -- classification ---------------------------------------------------------

  defp classify(%ParseError{reason: reason, file: file, row: row}) do
    {parse_reason_code(reason), sanitize_file(file), sanitize_row(row)}
  end

  # BatchProcessor row-conversion error: the row's attrs function returned an
  # error. The `reason` is a free-form message and must never be stored.
  defp classify(%{file: file, row: row, reason: _reason}) do
    {"row_invalid", sanitize_file(file), sanitize_row(row)}
  end

  # Ecto.ConstraintError / Postgrex constraint maps from the batch processor.
  defp classify(%{file: file, constraint: _constraint} = _map) do
    {"constraint_violation", sanitize_file(file), nil}
  end

  # Generic exception captured by the batch processor.
  defp classify(%{file: file, error: _message}) do
    {"database_error", sanitize_file(file), nil}
  end

  defp classify({:missing_references, _missing}) do
    {"missing_references", nil, nil}
  end

  defp classify({:image_restore_failed, inner}), do: classify(inner)

  defp classify({:missing_binary, _zip_path}), do: {"missing_image", nil, nil}

  defp classify({:write_failed, _zip_path, _reason}), do: {"image_write_failed", nil, nil}

  defp classify(:executor_lost), do: {"executor_lost", nil, nil}

  defp classify(_other), do: {"unknown_error", nil, nil}

  defp parse_reason_code(reason) when is_atom(reason) do
    code = Atom.to_string(reason)

    if code in @parse_reason_codes do
      code
    else
      "unexpected_parser_failure"
    end
  end

  defp parse_reason_code(_reason), do: "unexpected_parser_failure"

  # -- sanitizers -------------------------------------------------------------

  # A GTFS file entry is a bounded filename. Strip any directory component so no
  # filesystem path can leak, and cap the length defensively.
  defp sanitize_file(file) when is_binary(file) do
    file
    |> Path.basename()
    |> String.slice(0, @failed_file_max)
  end

  defp sanitize_file(_file), do: nil

  defp sanitize_row(row) when is_integer(row) and row > 0, do: row
  defp sanitize_row(_row), do: nil
end
