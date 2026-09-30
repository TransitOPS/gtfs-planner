defmodule GtfsPlanner.FaresFixtures do
  @moduledoc """
  Loads the fare fixtures under `test/fixtures/gtfs/fares/` through the production
  importer, so every fare test enters rows exactly as a user's import would.

  The fixture directories are literal GTFS feeds: `north_coast_v1` and
  `north_coast_v2` are the prototype's sample, `no_fare` is the same feed with no
  fare files, `refused/*` each carry one unrepresentable difference, and
  `public/*` are trimmed excerpts of published agency feeds.
  """

  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlanner.Gtfs.Import.Failure
  alias GtfsPlanner.Gtfs.Import.Result

  @fixtures_path Path.expand("../fixtures/gtfs/fares", __DIR__)

  @doc "The directory holding every fare fixture."
  @spec fixtures_path() :: Path.t()
  def fixtures_path, do: @fixtures_path

  @doc """
  The absolute path of one fixture directory, named relative to the fares
  directory (`"north_coast_v1"`, `"refused/leg_groups"`, `"public/ctran"`).
  """
  @spec fixture_path!(Path.t()) :: Path.t()
  def fixture_path!(name) do
    path = Path.join(@fixtures_path, name)

    if not File.dir?(path) do
      raise ArgumentError, "no fare fixture at #{path}"
    end

    path
  end

  @doc """
  Imports every `.txt` file of a fixture directory into `version` and returns the
  importer's `%Import.Result{}`. Raises when the import fails, so a fixture that
  stops importing is a test failure rather than a silent empty version.
  """
  @spec import!(struct, struct, Path.t() | String.t()) :: Result.t()
  def import!(organization, version, fixture_dir) do
    files = read_files!(fixture_dir)

    case Import.import_files(organization.id, version.id, files) do
      {:ok, result} ->
        result

      {:error, %Failure{} = failure} ->
        raise "fare fixture #{fixture_dir} did not import: #{failure.reason_code}" <>
                " in #{failure.failed_file}#{row(failure)}"
    end
  end

  defp row(%{failed_row: nil}), do: ""
  defp row(%{failed_row: row}), do: " row #{row}"

  defp read_files!(fixture_dir) do
    path =
      if File.dir?(fixture_dir) do
        fixture_dir
      else
        fixture_path!(fixture_dir)
      end

    path
    |> File.ls!()
    |> Enum.filter(&(Path.extname(&1) == ".txt"))
    |> Enum.sort()
    |> Enum.map(&%{filename: &1, content: File.read!(Path.join(path, &1))})
  end
end
