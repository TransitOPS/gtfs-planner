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
end
