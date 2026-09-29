defmodule GtfsPlanner.Gtfs.Flex.CopyTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Flex
  alias GtfsPlanner.Gtfs.Flex.Geometry
  alias GtfsPlanner.Gtfs.FlexArea
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @actor %{id: "0f3b7f3a-1d8e-4e0a-9c62-6b1a2c3d4e5f", email: "editor@example.com"}

  # The fixture areas: a 0.01° square at 44.6°N, and a second square east of it.
  @square %{
    "type" => "Polygon",
    "coordinates" => [
      [[-124.05, 44.6], [-124.04, 44.6], [-124.04, 44.61], [-124.05, 44.61], [-124.05, 44.6]]
    ]
  }

  @east_square %{
    "type" => "Polygon",
    "coordinates" => [
      [[-124.03, 44.6], [-124.02, 44.6], [-124.02, 44.61], [-124.03, 44.61], [-124.03, 44.6]]
    ]
  }

  @weekday %{area_key: nil, service_id: "weekday", start: "07:00", end: "18:00"}
  @saturday %{area_key: nil, service_id: "saturday", start: "09:00", end: "15:00"}
  @booking_rule %{service_id: nil, when: :earlier_day, days: 1, by: "16:00"}

  describe "copy_from_version/4" do
    test "copies every service and its areas, geometry included, into an empty version" do
      organization = organization_fixture()
      source = gtfs_version_fixture(organization.id)
      target = gtfs_version_fixture(organization.id)

      route_fixture(organization.id, source.id, %{route_id: "R20"})
      stop_fixture(organization.id, source.id, %{stop_id: "S1"})
      trip_fixture(organization.id, source.id, "R20", %{trip_id: "T1"})
      stop_time_fixture(organization.id, source.id, "T1", "S1")

      create_and_save(organization, source, %{
        name: "Newport Dial-a-Ride",
        kind: :area,
        hours: [@weekday],
        booking_rules: [@booking_rule],
        phone: "(541) 555-0142",
        note: "Call to book.",
        areas: [
          %{
            key: "a1",
            name: "Newport",
            source: :census,
            geojson: @square,
            census_geoid: "4152450",
            census_layer: "place",
            census_vintage: "2026"
          },
          %{
            key: "a2",
            name: "Route 20 corridor",
            source: :route_distance,
            route_ids: ["R20"],
            distance_m: 400
          }
        ]
      })

      detour =
        create_and_save(organization, source, %{
          name: "Route 20 detours",
          kind: :detour,
          route_id: "R20",
          distance_m: 1200,
          measure: :stops,
          first_stop_id: "S1",
          last_stop_id: "S3",
          wording: "Ask the driver",
          calendar_service_ids: ["weekday"],
          band_start: "07:00",
          band_end: "18:00",
          ada_only: true,
          dropoffs: :book,
          hours: [@saturday],
          areas: [%{key: "a1", name: "Detour zones", source: :drawn, geojson: @east_square}]
        })

      # Inactive services copy too: the copy carries the authoring, not a
      # selection.
      {:ok, _inactive} = Flex.set_active(organization.id, source.id, detour.id, false)

      before = flex_counts(organization.id, source.id)

      assert {:ok, 2} =
               Flex.copy_from_version(organization.id, target.id, source.id, @actor)

      originals = services_by_key(organization.id, source.id)
      copied = services_by_key(organization.id, target.id)

      assert Map.keys(copied) == Map.keys(originals)

      for {key, copied_service} <- copied do
        original = originals[key]

        assert copied_service.id != original.id
        assert copied_service.name == original.name
        assert copied_service.kind == original.kind
        assert copied_service.active == original.active
        assert copied_service.hours == original.hours
        assert copied_service.booking_rules == original.booking_rules
        assert copied_service.phone == original.phone
        assert copied_service.note == original.note
        assert copied_service.route_id == original.route_id
        assert copied_service.distance_m == original.distance_m
        assert copied_service.measure == original.measure
        assert copied_service.first_stop_id == original.first_stop_id
        assert copied_service.last_stop_id == original.last_stop_id
        assert copied_service.wording == original.wording
        assert copied_service.calendar_service_ids == original.calendar_service_ids
        assert copied_service.band_start == original.band_start
        assert copied_service.band_end == original.band_end
        assert copied_service.ada_only == original.ada_only
        assert copied_service.dropoffs == original.dropoffs
        assert copied_service.lock_version == 1

        assert abs(
                 NaiveDateTime.diff(copied_service.inserted_at, NaiveDateTime.utc_now(), :minute)
               ) <= 1

        assert Enum.map(copied_service.areas, & &1.key) ==
                 Enum.map(original.areas, & &1.key)

        for {copied_area, original_area} <- Enum.zip(copied_service.areas, original.areas) do
          assert copied_area.id != original_area.id
          assert copied_area.position == original_area.position
          assert copied_area.name == original_area.name
          assert copied_area.source == original_area.source
          assert copied_area.census_geoid == original_area.census_geoid
          assert copied_area.census_layer == original_area.census_layer
          assert copied_area.census_vintage == original_area.census_vintage
          assert copied_area.route_ids == original_area.route_ids
          assert copied_area.distance_m == original_area.distance_m
          assert copied_area.flex_service_id == copied_service.id
          assert copied_area.organization_id == organization.id
          assert copied_area.gtfs_version_id == target.id

          assert abs(
                   NaiveDateTime.diff(copied_area.inserted_at, NaiveDateTime.utc_now(), :minute)
                 ) <= 1

          assert_same_geometry(original_area, copied_area)
        end
      end

      assert copied["newport-dial-a-ride"].active
      refute copied["route-20-detours"].active

      # The source keeps its own rows, and no flex operation writes `trips` or
      # `stop_times` (R1, CR-4).
      assert flex_counts(organization.id, source.id) == before
      assert flex_counts(organization.id, target.id).trips == 0
      assert flex_counts(organization.id, target.id).stop_times == 0
    end

    test "an occupied target answers :target_not_empty and writes nothing" do
      organization = organization_fixture()
      source = gtfs_version_fixture(organization.id)
      target = gtfs_version_fixture(organization.id)

      {:ok, _source_service} = create_area_service(organization, source)
      {:ok, occupied} = create_area_service(organization, target, "Toledo Dial-a-Ride")
      {:ok, _inactive} = Flex.set_active(organization.id, target.id, occupied.id, false)

      assert {:error, :target_not_empty} =
               Flex.copy_from_version(organization.id, target.id, source.id, @actor)

      # Even an inactive service occupies the target, and the refused copy
      # leaves the target's rows exactly as they were.
      assert Flex.list_services(organization.id, target.id) |> Enum.map(& &1.key) == [
               "toledo-dial-a-ride"
             ]

      assert flex_counts(organization.id, target.id).services == 1
      assert flex_counts(organization.id, target.id).areas == 0
      assert flex_counts(organization.id, source.id).services == 1
    end

    test "copying a version into itself answers :target_not_empty" do
      organization = organization_fixture()
      source = gtfs_version_fixture(organization.id)
      {:ok, _source_service} = create_area_service(organization, source)

      assert {:error, :target_not_empty} =
               Flex.copy_from_version(organization.id, source.id, source.id, @actor)

      assert flex_counts(organization.id, source.id).services == 1
    end

    test "a source version of another organization is :not_found and writes nothing" do
      organization = organization_fixture()
      source = gtfs_version_fixture(organization.id)
      target = gtfs_version_fixture(organization.id)
      {:ok, _source_service} = create_area_service(organization, source)

      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      {:ok, _other_service} =
        create_area_service(other_organization, other_version, "Other Dial-a-Ride")

      assert {:error, :not_found} =
               Flex.copy_from_version(organization.id, target.id, other_version.id, @actor)

      assert {:error, :not_found} =
               Flex.copy_from_version(organization.id, target.id, Ecto.UUID.generate(), @actor)

      assert {:error, :not_found} =
               Flex.copy_from_version(organization.id, target.id, "not-a-uuid", @actor)

      assert Flex.list_services(organization.id, target.id) == []
      assert flex_counts(other_organization.id, other_version.id).services == 1
    end

    test "a staging source is refused even when it holds services" do
      organization = organization_fixture()
      target = gtfs_version_fixture(organization.id)
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})

      # `Flex.create_service/3` refuses a staging version, so the row is
      # inserted directly: the source's publication, not its emptiness, is what
      # the copy must refuse here.
      %FlexService{organization_id: organization.id, gtfs_version_id: staging.id}
      |> FlexService.create_changeset(%{key: "staged", name: "Staged Dial-a-Ride", kind: :area})
      |> Repo.insert!()

      assert {:error, :not_found} =
               Flex.copy_from_version(organization.id, target.id, staging.id, @actor)

      assert Flex.list_services(organization.id, target.id) == []
    end

    test "a foreign or staging target is :not_found and writes nothing" do
      organization = organization_fixture()
      source = gtfs_version_fixture(organization.id)
      {:ok, _source_service} = create_area_service(organization, source)

      other_organization = organization_fixture()
      other_target = gtfs_version_fixture(other_organization.id)

      assert {:error, :not_found} =
               Flex.copy_from_version(organization.id, other_target.id, source.id, @actor)

      {:ok, staging_target} =
        Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})

      assert {:error, :not_found} =
               Flex.copy_from_version(organization.id, staging_target.id, source.id, @actor)

      assert flex_counts(other_organization.id, other_target.id).services == 0
      assert flex_counts(organization.id, staging_target.id).services == 0
    end

    test "an empty published source answers {:ok, 0}" do
      organization = organization_fixture()
      source = gtfs_version_fixture(organization.id)
      target = gtfs_version_fixture(organization.id)

      assert {:ok, 0} = Flex.copy_from_version(organization.id, target.id, source.id, @actor)
      assert Flex.list_services(organization.id, target.id) == []
    end

    test "a copied detour keeps a route reference the target version does not resolve" do
      organization = organization_fixture()
      source = gtfs_version_fixture(organization.id)
      target = gtfs_version_fixture(organization.id)

      route_fixture(organization.id, source.id, %{route_id: "R20"})

      {:ok, _detour} =
        Flex.create_service(organization.id, source.id, %{
          name: "Route 20 detours",
          kind: :detour,
          route_id: "R20"
        })

      assert {:ok, 1} = Flex.copy_from_version(organization.id, target.id, source.id, @actor)

      # The target has no R20, so the copied reference is the missing route that
      # `Flex.Checks.run/3` reports once step 10 exists; this case pins the
      # copied value until then.
      assert [copied] = Flex.list_services(organization.id, target.id)
      assert copied.kind == :detour
      assert copied.route_id == "R20"
      assert count(Route, organization.id, target.id) == 0
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp create_area_service(organization, version, name \\ "Newport Dial-a-Ride") do
    Flex.create_service(organization.id, version.id, %{name: name, kind: :area})
  end

  defp create_and_save(organization, version, attrs) do
    attrs = Map.new(attrs)
    {areas, service_attrs} = Map.pop(attrs, :areas, [])
    create_attrs = Map.take(service_attrs, [:name, :kind, :route_id])

    {:ok, service} = Flex.create_service(organization.id, version.id, create_attrs)
    {:ok, loaded} = Flex.get_service(organization.id, version.id, service.id)

    {:ok, saved} =
      Flex.save_service(
        organization.id,
        version.id,
        loaded,
        Map.drop(service_attrs, [:name, :kind, :route_id]),
        areas
      )

    saved
  end

  defp services_by_key(organization_id, version_id) do
    organization_id
    |> Flex.list_services(version_id)
    |> Map.new(&{&1.key, &1})
  end

  # A copied area is the same shape under ST_Equals; a `:route_distance` area
  # has no geometry on either side. Presence is read through the production
  # reader, and ST_Equals is the independent oracle.
  defp assert_same_geometry(original_area, copied_area) do
    case original_area.source do
      :route_distance ->
        assert geometry_presence(copied_area.id) == :missing
        assert Geometry.get_geojson([copied_area.id]) == %{}

      _other ->
        assert geometry_presence(original_area.id) == :present
        assert geometry_presence(copied_area.id) == :present
        assert st_equals?(original_area.id, copied_area.id)
    end
  end

  defp geometry_presence(area_id) do
    if Map.has_key?(Geometry.get_geojson([area_id]), area_id), do: :present, else: :missing
  end

  defp st_equals?(source_area_id, copied_area_id) do
    %Postgrex.Result{rows: [[equal]]} =
      Repo.query!(
        """
        SELECT ST_Equals(
                 (SELECT geom FROM flex_areas WHERE id = $1),
                 (SELECT geom FROM flex_areas WHERE id = $2)
               )
        """,
        [Ecto.UUID.dump!(source_area_id), Ecto.UUID.dump!(copied_area_id)]
      )

    equal
  end

  defp flex_counts(organization_id, version_id) do
    %{
      services: count(FlexService, organization_id, version_id),
      areas: count(FlexArea, organization_id, version_id),
      trips: count(Trip, organization_id, version_id),
      stop_times: count(StopTime, organization_id, version_id)
    }
  end

  defp count(schema, organization_id, version_id) do
    Repo.aggregate(
      from(row in schema,
        where: row.organization_id == ^organization_id and row.gtfs_version_id == ^version_id
      ),
      :count
    )
  end
end
