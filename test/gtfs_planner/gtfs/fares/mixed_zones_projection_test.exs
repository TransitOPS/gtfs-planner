defmodule GtfsPlanner.Gtfs.Fares.MixedZonesProjectionTest do
  use GtfsPlanner.DataCase, async: false
  import GtfsPlanner.AccountsFixtures, only: [editor_fixture: 2]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]
  alias GtfsPlanner.FaresFixtures
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Gtfs.Fares.Interpreter
  alias GtfsPlanner.Gtfs.Fares.Pricing
  alias GtfsPlanner.Gtfs.Fares.Projection
  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.Support.StagedImport

  test "older projection retains a blanket fare when an ungrouped route has zoned and unzoned stops" do
    org = organization_fixture(%{alias: "binding-mixed-zones"})
    actor = editor_fixture(org, %{email: "binding-mixed-zones@example.com"})
    version = gtfs_version_fixture(org.id, %{name: "mixed zones"})

    files =
      Path.wildcard(Path.join(FaresFixtures.fixture_path!("no_fare"), "*.txt"))
      |> Enum.map(fn path ->
        content = File.read!(path)

        content =
          if Path.basename(path) == "stops.txt",
            do:
              String.replace(
                content,
                "NTC,Newport Transit Center,44.6206,-124.0463,",
                "NTC,Newport Transit Center,44.6206,-124.0463,Z"
              ),
            else: content

        %{filename: Path.basename(path), content: content}
      end)

    files = files ++ [%{filename: "areas.txt", content: "area_id,area_name\nZ,Zone Z\n"}]
    assert {:ok, _} = StagedImport.import_files(org.id, version.id, files)

    scope = %{
      organization_id: org.id,
      gtfs_version_id: version.id,
      audit: %AuditContext{
        organization_id: org.id,
        gtfs_version_id: version.id,
        actor_id: actor.id,
        actor_email: actor.email,
        station_stop_id: nil
      }
    }

    assert {:ok, _} = Conversion.setup(scope, %{kind: :flat, adult: Decimal.new("6")})
    assert {:ok, _} = FareZones.update_zone(scope.audit, "Z", %{name: "Zone Z"})

    assert {:ok, _} =
             Fares.save_fare(scope, %{
               name: "Zoned",
               kind: "single",
               media_ids: ["cash"],
               prices: %{"adult" => "2"}
             })

    assert {:ok, _} =
             Fares.save_rule(
               scope,
               %{fare_product_id: "zoned", from_area_id: "Z", to_area_id: "Z", reviewed: []},
               nil
             )

    runtime = Interpreter.load_rows(org.id, version.id)

    journey = %{
      rider_category_id: "adult",
      fare_media_id: "cash",
      service_date: ~D[2026-09-07],
      legs: [
        %{
          route_id: "3",
          from_stop_id: "NTC",
          to_stop_id: "HOSP",
          departs: 32_400,
          arrives: 33_000
        }
      ]
    }

    actual = Pricing.price_journey(runtime, journey)
    older = Projection.v1_rows(org.id, version.id)

    projected = %{
      runtime
      | fare_attributes: older["fare_attributes.txt"],
        fare_rules: older["fare_rules.txt"]
    }

    older_price = Interpreter.price_journey_v1(projected, journey)
    assert Decimal.equal?(actual.total, Decimal.new("6"))
    assert Enum.map(older["fare_attributes.txt"], & &1.fare_id) == ["local_ride", "zoned"]

    assert Enum.find(older["fare_attributes.txt"], &(&1.fare_id == "local_ride")).price ==
             Decimal.new("6.00")

    assert Enum.find(older["fare_attributes.txt"], &(&1.fare_id == "zoned")).price ==
             Decimal.new("2.00")

    refute older_price.unknown?
    assert Decimal.equal?(older_price.total, Decimal.new("6"))
  end
end
