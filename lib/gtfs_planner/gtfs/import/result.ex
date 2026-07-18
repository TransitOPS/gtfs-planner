defmodule GtfsPlanner.Gtfs.Import.Result do
  @moduledoc """
  Typed completion result for a full GTFS feed import.

  Carries the core import counts, unrecognized filenames, the progress topic,
  any archive-expansion warnings, and the extension phase status. A result is
  only publishable when there are no archive warnings and the extension phase
  either was absent or completed fully.
  """

  @enforce_keys [:counts, :unrecognized_files, :topic, :archive_warnings, :extensions]
  defstruct [:counts, :unrecognized_files, :topic, :archive_warnings, :extensions]

  @type extensions_status :: :not_present | :complete
  @type t :: %__MODULE__{
          counts: map(),
          unrecognized_files: [String.t()],
          topic: String.t(),
          archive_warnings: [map()],
          extensions: extensions_status()
        }

  @doc """
  Returns true only when the import is safe to publish.

  Publishability requires no archive warnings and either absent extensions
  (`:not_present`) or a fully completed extension phase (`:complete`). This is a
  total, pure predicate over the two allowed extension statuses.
  """
  @spec publishable?(t()) :: boolean()
  def publishable?(%__MODULE__{
        archive_warnings: archive_warnings,
        extensions: extensions
      }) do
    archive_warnings == [] and extensions in [:not_present, :complete]
  end

  @doc """
  Serializes a successful completion into the bounded, sanitized attributes
  accepted by the `Import.Run` changeset.

  A successful import has complete, durable counts, so `counts_complete` is
  always `true`. Only non-negative integer counts are emitted; the caller owns
  `state` and all lease/timestamp fields.
  """
  @spec to_run_attrs(t()) :: map()
  def to_run_attrs(%__MODULE__{counts: counts}) do
    %{
      committed_counts: sanitize_counts(counts),
      counts_complete: true
    }
  end

  defp sanitize_counts(counts) when is_map(counts) do
    counts
    |> Enum.filter(fn {_key, value} -> is_integer(value) and value >= 0 end)
    |> Map.new()
  end

  defp sanitize_counts(_counts), do: %{}
end
