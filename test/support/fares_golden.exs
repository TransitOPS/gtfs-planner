# Records and checks the unmanaged full-export bytes of every fare fixture.
#
#     MIX_ENV=test MIX_TEST_PARTITION=_s29 mix run test/support/fares_golden.exs
#     MIX_ENV=test MIX_TEST_PARTITION=_s29 mix run test/support/fares_golden.exs --check
#
# Each fixture is imported into a fresh organization and version on a sandbox
# connection, so nothing is committed: the run rolls back when this script exits.
# Without `--check` the export entries are written to
# `test/fixtures/gtfs/fares/golden/<fixture>/`, one file per export entry. With
# `--check` the recorded files are compared instead and a difference is a failure.
#
# These are the pre-change bytes AC-3 compares an unmanaged version against, so
# regenerate them only on a revision that does not change the export. A fixture the
# importer refuses on this revision is reported and left unrecorded: the C-TRAN
# excerpt needs the widened `fare_products` key before it can import at all.
defmodule GtfsPlanner.FaresGolden do
  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.FaresFixtures
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Export.CsvWriter
  alias GtfsPlanner.Gtfs.Import.CsvParser
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @fixtures_path FaresFixtures.fixtures_path()
  @golden_path Path.join(@fixtures_path, "golden")

  def main(argv) do
    mode = if "--check" in argv, do: :check, else: :write

    # `mix run` in the test environment already owns the sandbox connection.
    case Sandbox.checkout(Repo) do
      {:ok, _pid} -> :ok
      :already_owner -> :ok
      :ok -> :ok
    end

    fixtures = fixtures()
    failures = Enum.flat_map(fixtures, &report(&1, mode))
    Enum.each(failures, &Enum.each(&1, fn line -> IO.puts(:stderr, line) end))

    if failures != [] do
      IO.puts("#{length(failures)} fixture(s) differ from the recorded goldens")
      System.halt(1)
    end

    label = if mode == :check, do: "checked", else: "written"
    IO.puts("#{length(fixtures)} fixture(s) #{label}")
  end

  # Every fixture directory: the North Coast feeds, the refused variants and the
  # trimmed public excerpts.
  defp fixtures do
    (nested("refused") ++
       nested("public") ++
       Enum.reject(File.ls!(@fixtures_path), &(&1 in ["golden", "refused", "public"])))
    |> Enum.filter(&File.dir?(Path.join(@fixtures_path, &1)))
    |> Enum.sort()
  end

  defp nested(group) do
    @fixtures_path
    |> Path.join(group)
    |> File.ls!()
    |> Enum.sort()
    |> Enum.map(&"#{group}/#{&1}")
  end

  defp report(name, mode) do
    case export(name) do
      {:ok, entries} -> compare_or_write(name, entries, mode)
      {:error, reason} -> report_unimportable(name, reason)
    end
  end

  defp compare_or_write(name, entries, :check) do
    directory = Path.join(@golden_path, name)
    recorded = recorded_entries(directory)

    # AC-3 permits only the added default-rider column; its literal values are
    # asserted separately by FaresUnmanagedGoldenTest and DefaultRiderRoundTripTest.
    compared = Map.new(entries, fn {file, bytes} -> {file, baseline_bytes(file, bytes)} end)

    missing = Map.keys(recorded) -- Map.keys(entries)
    added = Map.keys(entries) -- Map.keys(recorded)
    changed = for {file, _bytes} <- entries, recorded[file] != compared[file], do: file

    if directory = System.get_env("FARES_GOLDEN_CAPTURE_DIR") do
      target = Path.join(directory, name)
      File.mkdir_p!(target)
      Enum.each(entries, fn {file, bytes} -> File.write!(Path.join(target, file), bytes) end)
    end

    if missing == [] and added == [] and changed == [] do
      IO.puts("ok #{name} (#{map_size(entries)} entries)")
      []
    else
      [
        [
          "#{name} differs from #{directory}",
          "  only in the export: #{inspect(Enum.sort(added))}",
          "  only in the goldens: #{inspect(missing)}",
          "  different bytes: #{inspect(Enum.sort(changed))}"
        ]
      ]
    end
  end

  defp compare_or_write(name, entries, :write) do
    directory = Path.join(@golden_path, name)
    File.rm_rf!(directory)
    File.mkdir_p!(directory)
    Enum.each(entries, fn {file, bytes} -> File.write!(Path.join(directory, file), bytes) end)
    IO.puts("wrote #{map_size(entries)} entries to #{directory}")
    []
  end

  defp baseline_bytes("rider_categories.txt", bytes) do
    [header | rows] =
      bytes
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        {:ok, fields} = CsvParser.parse_line(line)
        fields
      end)

    case Enum.find_index(header, &(&1 == "is_default_fare_category")) do
      nil ->
        bytes

      index ->
        [header | rows]
        |> Enum.map_join("\n", fn fields ->
          fields |> List.delete_at(index) |> Enum.map_join(",", &CsvWriter.escape_field/1)
        end)
        |> Kernel.<>("\n")
    end
  end

  defp baseline_bytes(_file, bytes), do: bytes

  defp report_unimportable(name, reason) do
    IO.puts("skipped #{name}: the importer refused this fixture (#{reason})")
    []
  end

  defp export(name) do
    {:ok, organization} =
      Organizations.create_organization_unchecked(%{alias: alias_for(name), name: name})

    {:ok, version} = Versions.create_staging_gtfs_version(organization.id, %{name: name})
    {:ok, _version} = Versions.claim_staging_gtfs_version(organization.id, version.id)

    with {:ok, version} <- import(name, organization, version),
         {:ok, version} <- Versions.publish_importing_gtfs_version(organization.id, version.id),
         {:ok, zip} <- Export.export_to_zip(organization.id, version.id, :full),
         {:ok, entries} <- :zip.unzip(zip, [:memory]) do
      {:ok, Map.new(entries, &unzip_entry/1)}
    end
  end

  defp import(name, organization, version) do
    FaresFixtures.import!(organization, version, FaresFixtures.fixture_path!(name))
    {:ok, version}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp unzip_entry({entry, content}), do: {to_string(entry), to_string(content)}

  defp alias_for(name), do: "fares-#{String.replace(name, "/", "-")}"

  defp recorded_entries(directory) do
    case File.ls(directory) do
      {:ok, files} ->
        Map.new(files, fn file -> {file, File.read!(Path.join(directory, file))} end)

      {:error, _reason} ->
        %{}
    end
  end
end

GtfsPlanner.FaresGolden.main(System.argv())
