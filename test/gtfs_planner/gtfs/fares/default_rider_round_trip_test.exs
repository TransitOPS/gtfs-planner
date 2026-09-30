defmodule GtfsPlanner.Gtfs.Fares.DefaultRiderRoundTripTest do
  @moduledoc """
  Merge evidence (EV-2) for the `is_default_fare_category` round trip.

  - `RowParser.rider_category_row_to_attrs/3` stores a literal 1, a literal 0
    and a blank field as `1`, `0` and `nil`, read back through
    `Gtfs.list_rider_categories/2`.
  - A full `Export.export_to_zip/3` writes `rider_categories.txt` with an
    `is_default_fare_category` column carrying the same `1`, `0` and empty field
    for the North Coast v2 fixture, and re-importing that exported file into a
    second version stores `1`, `0` and `nil` again.

  Every expected value below is a hand-written literal taken from the North Coast
  sample fixture, so neither the parser nor the exporter can confirm its own
  output.
  """
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.FaresFixtures, only: [import!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 0]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 1]

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Import

  # The importer stores 1, 0 and nil for a literal 1, a literal 0 and a blank field.
  @rider_categories_csv """
  rider_category_id,rider_category_name,is_default_fare_category,eligibility_url
  adult,Adult,1,
  reduced,Reduced fare,0,https://northcoast.example/reduced-fare
  senior,Seniors,,
  """

  @stored_defaults %{
    "adult" => 1,
    "reduced" => 0,
    "senior" => nil
  }

  # The North Coast v2 sample, whose `rider_categories.txt` carries the column
  # in its fourth position. `min_age`/`max_age` follow in the export's own order.
  @fixture_header "rider_category_id,rider_category_name,is_default_fare_category," <>
                    "min_age,max_age,eligibility_url"

  # Row order is the export's `rider_category_id` order. A nil
  # `is_default_fare_category` is written as an empty field.
  @fixture_rows [
    "adult,Adult,1,,,",
    "child,Children under 6,0,0,5,",
    "reduced,Reduced fare,0,,,https://northcoast.example/reduced-fare",
    "youth,Youth (6-18),0,6,18,"
  ]

  @fixture_stored_defaults %{
    "adult" => 1,
    "child" => 0,
    "reduced" => 0,
    "youth" => 0
  }

  setup do
    organization = organization_fixture()

    %{organization: organization, version: gtfs_version_fixture(organization.id)}
  end

  describe "import" do
    test "stores 1, 0 and nil for a default flag of 1, 0 and blank", %{
      organization: organization,
      version: version
    } do
      assert {:ok, result} =
               Import.import_files(organization.id, version.id, [
                 %{filename: "rider_categories.txt", content: @rider_categories_csv}
               ])

      assert result.counts[:rider_categories] == 3

      assert stored_defaults(organization.id, version.id) == @stored_defaults
    end
  end

  describe "export" do
    test "writes the column with 1, 0 and an empty field, and re-imports them", %{
      organization: organization,
      version: version
    } do
      import!(organization, version, "north_coast_v2")

      assert stored_defaults(organization.id, version.id) == @fixture_stored_defaults

      assert {:ok, zip} = Export.export_to_zip(organization.id, version.id, :full)
      {:ok, entries} = :zip.unzip(zip, [:memory])
      text = entry!(entries, "rider_categories.txt")

      assert [header | rows] = String.split(text, "\n", trim: true)
      assert header == @fixture_header
      assert rows == @fixture_rows

      second_version = gtfs_version_fixture(organization.id)

      assert {:ok, reimport} =
               Import.import_files(organization.id, second_version.id, [
                 %{filename: "rider_categories.txt", content: text}
               ])

      assert reimport.counts[:rider_categories] == 4
      assert stored_defaults(organization.id, second_version.id) == @fixture_stored_defaults
    end
  end

  # Stored `is_default_fare_category` keyed by `rider_category_id`, so one
  # comparison covers the stored 1, the stored 0 and the stored NULL.
  defp stored_defaults(organization_id, gtfs_version_id) do
    organization_id
    |> Gtfs.list_rider_categories(gtfs_version_id)
    |> Map.new(&{&1.rider_category_id, &1.is_default_fare_category})
  end

  defp entry!(entries, filename) do
    case Enum.find(entries, fn {name, _content} -> to_string(name) == filename end) do
      nil -> flunk("expected #{filename} in the export")
      {_name, content} -> to_string(content)
    end
  end
end
