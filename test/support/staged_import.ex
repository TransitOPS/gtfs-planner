defmodule GtfsPlanner.Support.StagedImport do
  @moduledoc """
  Test adapter from in-memory feed files to the staged file descriptors that
  `Import.import_files/5`, `Import.Publication.run/4` and `Import.Runner.start_import/4`
  take.

  Each call writes the `%{filename, content}` maps to a fresh private directory, one
  file per entry under a generated name, so an uploaded name may repeat or contain a
  path. The descriptors are `%{filename, path}`, the shape `SourceStorage.stage/4`
  returns, minus the size and checksum the importer does not read.
  """

  alias GtfsPlanner.Gtfs.Import

  @doc """
  Stages `files` and returns their descriptors. Call it from the test process (or a
  `setup` block): the directory is removed when the test exits, so the files outlive
  the call for runners and tasks that read them later.
  """
  @spec stage([%{filename: String.t(), content: binary()}]) :: [map()]
  def stage(files) do
    directory = new_directory()
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(directory) end)
    write_sources(files, directory)
  end

  @doc """
  `Import.import_files/5` over in-memory `files`. The staged files and the archive
  expansion directory are removed before it returns, so it is safe in any process.
  """
  @spec import_files(Ecto.UUID.t(), Ecto.UUID.t(), [map()], String.t() | nil, keyword()) ::
          term()
  def import_files(organization_id, gtfs_version_id, files, topic \\ nil, opts \\ []) do
    directory = new_directory()

    try do
      Import.import_files(
        organization_id,
        gtfs_version_id,
        write_sources(files, directory),
        topic,
        Keyword.put_new(opts, :expand_dir, Path.join(directory, "expanded"))
      )
    after
      File.rm_rf(directory)
    end
  end

  defp new_directory do
    Path.join(System.tmp_dir!(), "staged-import-#{Ecto.UUID.generate()}")
  end

  defp write_sources(files, directory) do
    source_directory = Path.join(directory, "source")
    File.mkdir_p!(source_directory)

    files
    |> Enum.with_index()
    |> Enum.map(fn {%{filename: filename, content: content}, index} ->
      path = Path.join(source_directory, "#{index}.source")
      File.write!(path, content)
      %{filename: filename, path: path}
    end)
  end
end
