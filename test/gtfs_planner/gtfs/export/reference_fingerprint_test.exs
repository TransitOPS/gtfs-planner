defmodule GtfsPlanner.Gtfs.Export.ReferenceFingerprintTest do
  @moduledoc """
  R2's reference fingerprint: the digest `build_zips/4` returns names the six
  reference files and their bytes, so an export can be compared to a prior
  reference without unzipping either. The cases assert relations only — equal,
  differ, 64-hex or nil — and never re-hash the files in the test.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  import GtfsPlanner.FaresFixtures
  import GtfsPlanner.FlexFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.RunsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.{FareAttribute, Flex, StopTime}

  @drawn_area %{
    "type" => "Polygon",
    "coordinates" => [
      [
        [-124.09, 44.57],
        [-124.08, 44.57],
        [-124.08, 44.58],
        [-124.09, 44.58],
        [-124.09, 44.57]
      ]
    ]
  }

  describe "the reference fingerprint" do
    test "full and operations_only agree on unchanged data" do
      %{organization: organization, version: version} = runs_version_fixture()

      {:ok, %{reference_sha256: full}, _warnings} =
        Export.build_zips(organization.id, version.id, :full)

      {:ok, %{reference_sha256: only}, _warnings} =
        Export.build_zips(organization.id, version.id, :operations_only)

      assert_hex(full)
      assert_hex(only)
      assert full == only
    end

    test "two full builds of the same data agree" do
      %{organization: organization, version: version} = runs_version_fixture()

      {:ok, %{reference_sha256: first}, _warnings} =
        Export.build_zips(organization.id, version.id, :full)

      {:ok, %{reference_sha256: second}, _warnings} =
        Export.build_zips(organization.id, version.id, :full)

      assert_hex(first)
      assert_hex(second)
      assert first == second
    end

    test "an edited stop time changes the digest" do
      %{organization: organization, version: version} = runs_version_fixture()

      {:ok, %{reference_sha256: before}, _warnings} =
        Export.build_zips(organization.id, version.id, :full)

      row =
        Repo.one(
          from st in StopTime,
            where: st.organization_id == ^organization.id and st.gtfs_version_id == ^version.id,
            order_by: [asc: st.stop_sequence],
            limit: 1
        )

      {1, _} =
        Repo.update_all(
          from(st in StopTime, where: st.id == ^row.id),
          set: [arrival_time: "23:59:00", departure_time: "23:59:00"]
        )

      {:ok, %{reference_sha256: changed}, _warnings} =
        Export.build_zips(organization.id, version.id, :full)

      assert_hex(before)
      assert_hex(changed)
      assert before != changed
    end

    test "estimation method changes the digest" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      for index <- 1..5 do
        stop_fixture(organization.id, version.id, stop_id: "S#{index}")
      end

      route_fixture(organization.id, version.id, route_id: "R1")
      trip_fixture(organization.id, version.id, "R1", %{trip_id: "T1"})

      rows = [
        %{
          stop_sequence: 1,
          arrival_time: "08:00:00",
          departure_time: "08:00:00",
          shape_dist_traveled: Decimal.new("0")
        },
        %{
          stop_sequence: 2,
          arrival_time: nil,
          departure_time: nil,
          shape_dist_traveled: Decimal.new("200")
        },
        %{
          stop_sequence: 3,
          arrival_time: nil,
          departure_time: nil,
          shape_dist_traveled: Decimal.new("400")
        },
        %{
          stop_sequence: 4,
          arrival_time: nil,
          departure_time: nil,
          shape_dist_traveled: Decimal.new("2400")
        },
        %{
          stop_sequence: 5,
          arrival_time: "08:10:00",
          departure_time: "08:10:00",
          timepoint: 1,
          shape_dist_traveled: Decimal.new("3000")
        }
      ]

      Enum.each(rows, fn attrs ->
        stop_time_fixture(organization.id, version.id, "T1", "S#{attrs.stop_sequence}", attrs)
      end)

      {:ok, %{reference_sha256: distance}, _warnings} =
        Export.build_zips(organization.id, version.id, :full, estimate: :distance)

      {:ok, %{reference_sha256: even}, _warnings} =
        Export.build_zips(organization.id, version.id, :full, estimate: :even)

      assert_hex(distance)
      assert_hex(even)
      assert distance != even
    end

    test "a fare change does not change the digest" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      import!(organization, version, "north_coast_v1")

      {:ok, %{reference_sha256: before}, _warnings} =
        Export.build_zips(organization.id, version.id, :full)

      {1, _} =
        Repo.update_all(
          from(f in FareAttribute,
            where:
              f.organization_id == ^organization.id and f.gtfs_version_id == ^version.id and
                f.fare_id == "LOCAL"
          ),
          set: [price: Decimal.new("9.99")]
        )

      {:ok, %{reference_sha256: changed}, _warnings} =
        Export.build_zips(organization.id, version.id, :full)

      assert_hex(before)
      assert_hex(changed)
      assert before == changed
    end

    test "pathways has no reference digest" do
      %{organization: organization, version: version} = runs_version_fixture()

      {:ok, %{reference_sha256: reference_sha256}, _warnings} =
        Export.build_zips(organization.id, version.id, :pathways)

      assert reference_sha256 == nil
    end

    test "a flex-only feed has no reference digest" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      only_feed_service(organization, version)

      assert {:ok, %{main: nil, flex: flex, reference_sha256: reference_sha256}, warnings} =
               Export.build_zips(organization.id, version.id, :full, include_flex: true)

      assert is_binary(flex)
      assert reference_sha256 == nil
      assert Enum.any?(warnings, &(&1.code == "main_feed_not_produced"))
    end
  end

  defp assert_hex(value) do
    assert is_binary(value)
    assert value =~ ~r/\A[0-9a-f]{64}\z/
  end

  # Agency, one weekday calendar and one drawn-area service: the version has no
  # fixed routes, so R15 makes the flex zip its only feed.
  defp only_feed_service(organization, version) do
    agency_fixture(organization.id, version.id, %{
      agency_id: "SOLO",
      agency_name: "Solo Transit",
      agency_url: "https://example.org",
      agency_timezone: "America/Los_Angeles"
    })

    calendar_fixture(organization.id, version.id, %{
      service_id: "weekday",
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0
    })

    {:ok, service} =
      Flex.create_service(flex_audit_fixture(organization.id, version.id), %{
        name: "Only Feed Shuttle",
        kind: :area
      })

    assert {:ok, _service} =
             Flex.save_service(
               flex_audit_fixture(organization.id, version.id),
               service,
               %{
                 phone: "(541) 555-0142",
                 hours: [%{area_key: "a1", service_id: "weekday", start: "08:00", end: "17:00"}],
                 booking_rules: [%{when: :same_day, minutes: 60}]
               },
               [%{key: "a1", name: "Solo", source: :drawn, geojson: @drawn_area}]
             )
  end
end
