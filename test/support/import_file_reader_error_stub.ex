defmodule GtfsPlanner.Support.ImportFileReaderErrorStub do
  @moduledoc """
  Deterministic import-file reader adapter that always fails.

  Used only by the focused `ImportLive` upload-consumption failure test to
  exercise the post-create read-error path without touching the real
  filesystem. Production remains wired to `File.read/1` via application
  configuration.
  """

  @doc """
  Mirrors `File.read/1`'s contract but always returns a read error.
  """
  @spec read(Path.t()) :: {:error, File.posix()}
  def read(_path), do: {:error, :eio}
end
