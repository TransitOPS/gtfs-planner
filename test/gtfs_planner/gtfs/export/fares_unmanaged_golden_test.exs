defmodule GtfsPlanner.Gtfs.Export.FaresUnmanagedGoldenTest do
  @moduledoc """
  Merge evidence (EV-28) for AC-3: an unmanaged version's full export is
  byte-identical to the bytes recorded before this package changed the export,
  except for the one column AC-3 names.

  The fixtures enter rows through the production importer and are published
  before the production `GtfsPlanner.Gtfs.Export.export_to_zip/3` runs, exactly
  as `test/support/fares_golden.exs` recorded them. Every expectation is a
  recorded golden file, never a value the code under test produced (CR-2), and
  the goldens themselves are the pre-change bytes — see
  `test/fixtures/gtfs/fares/golden/SOURCE.md`.

  The only permitted difference is `rider_categories.txt`: the golden predates
  the `is_default_fare_category` column this package added, so the expected
  bytes are the golden's with that column inserted after `rider_category_name`
  and its value written for each row. The value is worked by hand from each
  fixture's own `rider_categories.txt` — the row whose column reads 1 is the
  default, `0` is not, and a fixture with no rider categories has no file at
  all — so AC-3's exception is checked, not assumed.

  A version stays unmanaged because nothing in this package makes it managed
  (R1): importing a feed writes no `fare_version_settings` row, so the export
  replaces nothing, appends nothing and keeps its `network_id` column.
  """
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.FaresFixtures
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]

  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Fares

  # The fixtures AC-3 names, in the order the goldens were recorded. The
  # `refused/*` variants are absent because the importer refuses them, and
  # `public/*` is the trimmed published excerpts.
  @fixtures ~w(
    north_coast_v1
    north_coast_v2
    no_fare
    public/ctran
    public/santa_cruz_metro
    public/trimet
  )

  # AC-3's one named exception.
  @rider_categories "rider_categories.txt"
  @default_column "is_default_fare_category"

  # The default rider of each fixture, by its own `rider_categories.txt`. A
  # fixture that is not listed has no `rider_categories.txt` at all.
  @defaults %{
    "north_coast_v2" => %{"adult" => "1", "child" => "0", "reduced" => "0", "youth" => "0"},
    "public/ctran" => %{
      "ADULT" => "1",
      "HONORED_CITIZEN" => "0",
      "YOUTH" => "0"
    },
    "public/santa_cruz_metro" => %{
      "adult" => "1",
      "discount" => "0",
      "senior" => "0",
      "veteran" => "0",
      "youth" => "0"
    },
    "public/trimet" => %{"ADULT" => "1", "HONORED_CITIZEN" => "0", "YOUTH" => "0"}
  }

  for fixture <- @fixtures do
    test "#{fixture} exports the bytes recorded before this package" do
      exported = full_export(unquote(fixture))

      recorded = golden(unquote(fixture))
      expected_names = Map.keys(recorded)

      assert Enum.sort(Map.keys(exported)) == Enum.sort(expected_names)

      for name <- expected_names, name != @rider_categories do
        assert exported[name] == recorded[name],
               "#{unquote(fixture)}/#{name} differs from the recorded golden"
      end
    end
  end

  test "rider_categories.txt is the golden with the is_default_fare_category column inserted" do
    for {fixture, defaults} <- @defaults do
      exported = full_export(fixture)
      recorded = golden(fixture)

      assert [header | rows] = String.split(recorded[@rider_categories], "\n", trim: true)

      # The column goes after `rider_category_name`, which is where
      # `FileSpec.rider_categories_spec/0` writes it.
      assert [id_column, name_column | rest] = String.split(header, ",")

      expected_rows =
        Enum.map(rows, fn row ->
          assert [id, name | fields] = String.split(row, ",")

          assert id_column == "rider_category_id"
          assert name_column == "rider_category_name"

          assert Map.has_key?(defaults, id),
                 "#{fixture} has a rider the hand-worked defaults do not name: #{id}"

          Enum.join([id, name, Map.fetch!(defaults, id) | fields], ",")
        end)

      assert exported[@rider_categories] ==
               Enum.join(
                 [
                   Enum.join([id_column, name_column, @default_column | rest], ",")
                   | expected_rows
                 ],
                 "\n"
               ) <> "\n"
    end
  end

  test "an unmanaged version replaces no fare file and keeps its network_id column" do
    for fixture <- @fixtures do
      organization = organization_fixture(%{alias: alias_for(fixture)})
      version = gtfs_version_fixture(organization.id, %{name: fixture})
      import!(organization, version, fixture)

      refute Fares.managed?(organization.id, version.id)

      # INV-6 rests on this as much as on the bytes: the projection has nothing
      # to say about a version that was never made managed, and `routes.txt`
      # keeps the column the import wrote.
      assert {:ok, zip} = Export.export_to_zip(organization.id, version.id, :full)
      assert exported = entries(zip)

      assert Map.keys(exported) == Map.keys(golden(fixture))
    end
  end

  # -- Fixtures and goldens --------------------------------------------------------

  # The fixture's `:full` ZIP entries, imported and published the way
  # `test/support/fares_golden.exs` recorded the bytes.
  defp full_export(fixture) do
    organization = organization_fixture(%{alias: alias_for(fixture)})
    version = gtfs_version_fixture(organization.id, %{name: fixture})
    import!(organization, version, fixture)

    assert {:ok, zip} = Export.export_to_zip(organization.id, version.id, :full)
    entries(zip)
  end

  defp entries(zip) do
    {:ok, files} = :zip.unzip(zip, [:memory])
    Map.new(files, fn {name, content} -> {to_string(name), to_string(content)} end)
  end

  # The recorded bytes of one fixture's export, one file per entry.
  defp golden(fixture) do
    directory = Path.join([fixtures_path(), "golden", fixture])

    directory
    |> File.ls!()
    |> Map.new(fn name -> {name, File.read!(Path.join(directory, name))} end)
  end

  defp alias_for(fixture),
    do: "fares-golden-#{String.replace(fixture, "/", "-")}-#{System.unique_integer([:positive])}"
end
