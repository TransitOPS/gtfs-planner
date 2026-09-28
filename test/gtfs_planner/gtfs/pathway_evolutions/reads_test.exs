defmodule GtfsPlanner.Gtfs.PathwayEvolutionsReadsTest do
  @moduledoc """
  Scoped closure reads through the ordinary `Gtfs` facade
  (`station_closures/3`, `closure_calendars/2`, `count_closures/2`): station
  membership including nested boarding areas, native calendar choices and
  scope refusals. Expectations are hand-authored from the acceptance cases.
  """
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.PathwayEvolutions
  alias GtfsPlanner.Versions

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    level_fixture(organization.id, version.id, %{level_id: "L_STREET", level_index: 0.0})
    level_fixture(organization.id, version.id, %{level_id: "L_PLAT", level_index: -1.0})

    station =
      stop_fixture(organization.id, version.id, %{stop_id: "STN_1", location_type: 1})

    entrance =
      stop_fixture(organization.id, version.id, %{
        stop_id: "ENT_1",
        location_type: 2,
        parent_station: "STN_1",
        level_id: "L_STREET"
      })

    platform =
      stop_fixture(organization.id, version.id, %{
        stop_id: "PLAT_1",
        location_type: 0,
        parent_station: "STN_1",
        level_id: "L_PLAT"
      })

    boarding_area =
      stop_fixture(organization.id, version.id, %{
        stop_id: "BA_1",
        location_type: 4,
        parent_station: "PLAT_1",
        level_id: "L_PLAT"
      })

    outside = stop_fixture(organization.id, version.id, %{stop_id: "OUT_1", location_type: 0})

    entry_pathway =
      pathway_fixture(organization.id, version.id, entrance.stop_id, platform.stop_id, %{
        pathway_id: "PW_ENTRY",
        pathway_mode: 2
      })

    boarding_pathway =
      pathway_fixture(organization.id, version.id, platform.stop_id, boarding_area.stop_id, %{
        pathway_id: "PW_BA",
        pathway_mode: 1
      })

    inbound_pathway =
      pathway_fixture(organization.id, version.id, outside.stop_id, platform.stop_id, %{
        pathway_id: "PW_IN",
        pathway_mode: 5
      })

    %{
      organization: organization,
      version: version,
      station: station,
      entrance: entrance,
      platform: platform,
      boarding_area: boarding_area,
      outside: outside,
      entry_pathway: entry_pathway,
      boarding_pathway: boarding_pathway,
      inbound_pathway: inbound_pathway
    }
  end

  describe "Gtfs.station_closures/3" do
    test "lists closures whose pathway has either endpoint in the station, boarding areas included",
         context do
      entry_closure =
        pathway_evolution_fixture(context.organization.id, context.version.id, %{
          pathway_id: "PW_ENTRY",
          service_id: "SVC_A",
          start_time: "09:00",
          end_time: "10:00"
        })

      boarding_closure =
        pathway_evolution_fixture(context.organization.id, context.version.id, %{
          pathway_id: "PW_BA",
          service_id: "SVC_A",
          start_time: "11:00",
          end_time: "12:00"
        })

      inbound_closure =
        pathway_evolution_fixture(context.organization.id, context.version.id, %{
          pathway_id: "PW_IN",
          service_id: "SVC_A",
          start_time: "13:00",
          end_time: "14:00"
        })

      assert {:ok, result} =
               Gtfs.station_closures(context.organization.id, context.version.id, "STN_1")

      assert result.station.stop_id == "STN_1"
      assert Enum.sort(Enum.map(result.child_stops, & &1.stop_id)) == ["BA_1", "ENT_1", "PLAT_1"]
      assert Enum.map(result.pathways, & &1.pathway_id) == ["PW_BA", "PW_ENTRY", "PW_IN"]

      closure_ids = Enum.map(result.closures, & &1.evolution.id)

      assert Enum.sort(closure_ids) ==
               Enum.sort([entry_closure.id, boarding_closure.id, inbound_closure.id])

      rows_by_pathway = Map.new(result.closures, &{&1.pathway.pathway_id, &1})

      assert rows_by_pathway["PW_ENTRY"].evolution.id == entry_closure.id
      assert rows_by_pathway["PW_ENTRY"].pathway.pathway_mode == 2
      assert rows_by_pathway["PW_BA"].pathway.pathway_mode == 1
      assert rows_by_pathway["PW_BA"].pathway.to_stop.stop_id == "BA_1"
      assert rows_by_pathway["PW_IN"].pathway.pathway_mode == 5
      assert rows_by_pathway["PW_IN"].pathway.from_stop.stop_id == "OUT_1"
    end

    test "excludes closures from other stations, versions and organizations", context do
      mine =
        pathway_evolution_fixture(context.organization.id, context.version.id, %{
          pathway_id: "PW_ENTRY",
          service_id: "SVC_A",
          start_time: "09:00",
          end_time: "10:00"
        })

      # Another station in the same version.
      other_station =
        stop_fixture(context.organization.id, context.version.id, %{
          stop_id: "STN_2",
          location_type: 1
        })

      other_child =
        stop_fixture(context.organization.id, context.version.id, %{
          stop_id: "PLAT_2",
          location_type: 0,
          parent_station: other_station.stop_id,
          level_id: "L_PLAT"
        })

      other_outside =
        stop_fixture(context.organization.id, context.version.id, %{
          stop_id: "OUT_2",
          location_type: 0
        })

      pathway_fixture(
        context.organization.id,
        context.version.id,
        other_child.stop_id,
        other_outside.stop_id,
        %{pathway_id: "PW_OTHER"}
      )

      other_station_closure =
        pathway_evolution_fixture(context.organization.id, context.version.id, %{
          pathway_id: "PW_OTHER",
          service_id: "SVC_A",
          start_time: "09:00",
          end_time: "10:00"
        })

      # The same natural pathway_id in another version of the same organization.
      other_version = gtfs_version_fixture(context.organization.id, %{name: "Other version"})

      pathway_fixture(context.organization.id, other_version.id, "V2_ENT", "V2_PLAT", %{
        pathway_id: "PW_ENTRY"
      })

      _other_version_closure =
        pathway_evolution_fixture(context.organization.id, other_version.id, %{
          pathway_id: "PW_ENTRY",
          service_id: "SVC_A",
          start_time: "09:00",
          end_time: "10:00"
        })

      # The same natural IDs in another organization.
      other_org = organization_fixture()
      foreign_version = gtfs_version_fixture(other_org.id)

      pathway_fixture(other_org.id, foreign_version.id, "F_ENT", "F_PLAT", %{
        pathway_id: "PW_ENTRY"
      })

      _foreign_closure =
        pathway_evolution_fixture(other_org.id, foreign_version.id, %{
          pathway_id: "PW_ENTRY",
          service_id: "SVC_A",
          start_time: "09:00",
          end_time: "10:00"
        })

      assert {:ok, result} =
               Gtfs.station_closures(context.organization.id, context.version.id, "STN_1")

      assert Enum.map(result.closures, & &1.evolution.id) == [mine.id]

      assert {:ok, other_result} =
               Gtfs.station_closures(context.organization.id, context.version.id, "STN_2")

      assert Enum.map(other_result.closures, & &1.evolution.id) == [other_station_closure.id]
    end

    test "sorts closures by pathway_id, start_time, service_id, end_time and id", context do
      organization_id = context.organization.id
      version_id = context.version.id

      pathway_evolution_fixture(organization_id, version_id, %{
        pathway_id: "PW_ENTRY",
        service_id: "SVC_A",
        start_time: 100,
        end_time: 200
      })

      pathway_evolution_fixture(organization_id, version_id, %{
        pathway_id: "PW_BA",
        service_id: "SVC_A",
        start_time: 10,
        end_time: 20
      })

      pathway_evolution_fixture(organization_id, version_id, %{
        pathway_id: "PW_ENTRY",
        service_id: "SVC_B",
        start_time: 50,
        end_time: 100
      })

      pathway_evolution_fixture(organization_id, version_id, %{
        pathway_id: "PW_ENTRY",
        service_id: "SVC_A",
        start_time: 50,
        end_time: 150
      })

      pathway_evolution_fixture(organization_id, version_id, %{
        pathway_id: "PW_ENTRY",
        service_id: "SVC_A",
        start_time: 50,
        end_time: 90
      })

      assert {:ok, result} = Gtfs.station_closures(organization_id, version_id, "STN_1")

      assert Enum.map(
               result.closures,
               &{&1.evolution.pathway_id, &1.evolution.start_time, &1.evolution.service_id,
                &1.evolution.end_time}
             ) == [
               {"PW_BA", 10, "SVC_A", 20},
               {"PW_ENTRY", 50, "SVC_A", 90},
               {"PW_ENTRY", 50, "SVC_A", 150},
               {"PW_ENTRY", 50, "SVC_B", 100},
               {"PW_ENTRY", 100, "SVC_A", 200}
             ]
    end

    test "keeps whitespace-distinct pathway identifiers on their exact pathways", context do
      organization_id = context.organization.id
      version_id = context.version.id

      pathway_fixture(organization_id, version_id, "ENT_1", "PLAT_1", %{
        pathway_id: "PW 1",
        pathway_mode: 1
      })

      pathway_fixture(organization_id, version_id, "ENT_1", "PLAT_1", %{
        pathway_id: "PW1",
        pathway_mode: 1
      })

      spaced =
        pathway_evolution_fixture(organization_id, version_id, %{
          pathway_id: "PW 1",
          service_id: "SVC_A",
          start_time: 10,
          end_time: 20
        })

      tight =
        pathway_evolution_fixture(organization_id, version_id, %{
          pathway_id: "PW1",
          service_id: "SVC_A",
          start_time: 30,
          end_time: 40
        })

      assert {:ok, result} = Gtfs.station_closures(organization_id, version_id, "STN_1")

      assert Map.new(result.closures, &{&1.evolution.id, &1.pathway.pathway_id}) == %{
               spaced.id => "PW 1",
               tight.id => "PW1"
             }
    end

    test "computes one fingerprint per closure row over the persisted row", context do
      organization_id = context.organization.id
      version_id = context.version.id

      first =
        pathway_evolution_fixture(organization_id, version_id, %{
          pathway_id: "PW_ENTRY",
          service_id: "SVC_A",
          start_time: "09:00",
          end_time: "10:00"
        })

      second =
        pathway_evolution_fixture(organization_id, version_id, %{
          pathway_id: "PW_ENTRY",
          service_id: "SVC_B",
          start_time: "11:00",
          end_time: "12:00"
        })

      assert {:ok, result} = Gtfs.station_closures(organization_id, version_id, "STN_1")
      assert {:ok, again} = Gtfs.station_closures(organization_id, version_id, "STN_1")

      [row_first, row_second] = result.closures

      assert row_first.evolution.id == first.id
      assert row_second.evolution.id == second.id
      assert row_first.fingerprint == PathwayEvolutions.fingerprint(row_first.evolution)
      assert row_second.fingerprint == PathwayEvolutions.fingerprint(row_second.evolution)
      assert row_first.fingerprint =~ ~r/\A[0-9a-f]{64}\z/
      refute row_first.fingerprint == row_second.fingerprint

      assert Enum.map(result.closures, & &1.fingerprint) ==
               Enum.map(again.closures, & &1.fingerprint)
    end
  end

  describe "Gtfs.closure_calendars/2" do
    test "excludes metadata-only services and keeps dates-only and unnamed native services",
         context do
      organization_id = context.organization.id
      version_id = context.version.id

      calendar_fixture(organization_id, version_id, %{service_id: "SVC_WEEK"})

      calendar_attribute_fixture(organization_id, version_id, %{
        service_id: "SVC_WEEK",
        service_description: "Weekday Service"
      })

      calendar_date_fixture(organization_id, version_id, %{
        service_id: "SVC_DATES",
        date: ~D[2026-07-04],
        exception_type: 1
      })

      calendar_date_fixture(organization_id, version_id, %{
        service_id: "SVC_DATES",
        date: ~D[2026-07-06],
        exception_type: 1
      })

      calendar_attribute_fixture(organization_id, version_id, %{
        service_id: "SVC_DATES",
        service_description: "Holiday Shuttle"
      })

      calendar_fixture(organization_id, version_id, %{service_id: "SVC_PLAIN"})
      calendar_fixture(organization_id, version_id, %{service_id: "SVC_BLANK"})

      calendar_attribute_fixture(organization_id, version_id, %{
        service_id: "SVC_BLANK",
        service_description: ""
      })

      calendar_attribute_fixture(organization_id, version_id, %{
        service_id: "SVC_META",
        service_description: "Metadata Only"
      })

      assert {:ok, options} = Gtfs.closure_calendars(organization_id, version_id)

      assert Enum.sort(Enum.map(options, & &1.service_id)) ==
               ["SVC_BLANK", "SVC_DATES", "SVC_PLAIN", "SVC_WEEK"]

      assert Map.new(options, &{&1.service_id, &1.label}) == %{
               "SVC_BLANK" => "SVC_BLANK",
               "SVC_DATES" => "Holiday Shuttle",
               "SVC_PLAIN" => "SVC_PLAIN",
               "SVC_WEEK" => "Weekday Service"
             }
    end

    test "returns effective date summaries, trip counts and closure counts", context do
      organization_id = context.organization.id
      version_id = context.version.id

      calendar_fixture(organization_id, version_id, %{
        service_id: "SVC_WEEK",
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 1,
        sunday: 1,
        start_date: ~D[2026-01-01],
        end_date: ~D[2026-01-03]
      })

      calendar_date_fixture(organization_id, version_id, %{
        service_id: "SVC_DATES",
        date: ~D[2026-07-04],
        exception_type: 1
      })

      calendar_date_fixture(organization_id, version_id, %{
        service_id: "SVC_DATES",
        date: ~D[2026-07-06],
        exception_type: 1
      })

      route = route_fixture(organization_id, version_id, %{route_id: "R_A"})
      trip_fixture(organization_id, version_id, route.route_id, %{service_id: "SVC_WEEK"})
      trip_fixture(organization_id, version_id, route.route_id, %{service_id: "SVC_WEEK"})

      pathway_evolution_fixture(organization_id, version_id, %{
        pathway_id: "PW_ENTRY",
        service_id: "SVC_WEEK",
        start_time: "09:00",
        end_time: "10:00"
      })

      # A closure on a self-provisioned pathway still counts toward the
      # scope-wide service usage.
      pathway_evolution_fixture(organization_id, version_id, %{
        service_id: "SVC_WEEK",
        start_time: "11:00",
        end_time: "12:00"
      })

      assert {:ok, options} = Gtfs.closure_calendars(organization_id, version_id)
      options_by_service = Map.new(options, &{&1.service_id, &1})

      assert options_by_service["SVC_WEEK"] == %{
               service_id: "SVC_WEEK",
               name: nil,
               label: "SVC_WEEK",
               first_active_date: ~D[2026-01-01],
               last_active_date: ~D[2026-01-03],
               active_date_count: 3,
               trip_count: 2,
               closure_count: 2
             }

      assert options_by_service["SVC_DATES"] == %{
               service_id: "SVC_DATES",
               name: nil,
               label: "SVC_DATES",
               first_active_date: ~D[2026-07-04],
               last_active_date: ~D[2026-07-06],
               active_date_count: 2,
               trip_count: 0,
               closure_count: 0
             }
    end

    test "attaches native calendar options to closure rows and nil for other services", context do
      organization_id = context.organization.id
      version_id = context.version.id

      calendar_fixture(organization_id, version_id, %{service_id: "SVC_WEEK"})

      calendar_attribute_fixture(organization_id, version_id, %{
        service_id: "SVC_WEEK",
        service_description: "Weekday Service"
      })

      calendar_attribute_fixture(organization_id, version_id, %{
        service_id: "SVC_META",
        service_description: "Metadata Only"
      })

      pathway_evolution_fixture(organization_id, version_id, %{
        pathway_id: "PW_ENTRY",
        service_id: "SVC_WEEK",
        start_time: "09:00",
        end_time: "10:00"
      })

      pathway_evolution_fixture(organization_id, version_id, %{
        pathway_id: "PW_ENTRY",
        service_id: "SVC_META",
        start_time: "11:00",
        end_time: "12:00"
      })

      pathway_evolution_fixture(organization_id, version_id, %{
        pathway_id: "PW_ENTRY",
        service_id: "SVC_GHOST",
        start_time: "13:00",
        end_time: "14:00"
      })

      assert {:ok, result} = Gtfs.station_closures(organization_id, version_id, "STN_1")
      assert {:ok, options} = Gtfs.closure_calendars(organization_id, version_id)

      assert Enum.map(options, & &1.service_id) == ["SVC_WEEK"]
      week_option = Enum.find(options, &(&1.service_id == "SVC_WEEK"))

      assert Map.new(result.closures, &{&1.evolution.service_id, &1.calendar}) == %{
               "SVC_WEEK" => week_option,
               "SVC_META" => nil,
               "SVC_GHOST" => nil
             }
    end
  end

  describe "Gtfs.count_closures/2" do
    test "counts closure rows in the published scope only", context do
      organization_id = context.organization.id
      version_id = context.version.id

      # Defaults self-provision the referenced pathway and weekly calendar.
      pathway_evolution_fixture(organization_id, version_id)
      pathway_evolution_fixture(organization_id, version_id)
      pathway_evolution_fixture(organization_id, version_id)

      other_version = gtfs_version_fixture(organization_id, %{name: "Other version"})
      pathway_evolution_fixture(organization_id, other_version.id)

      other_org = organization_fixture()
      foreign_version = gtfs_version_fixture(other_org.id)
      pathway_evolution_fixture(other_org.id, foreign_version.id)

      assert Gtfs.count_closures(organization_id, version_id) == 3
      assert Gtfs.count_closures(organization_id, other_version.id) == 1
    end
  end

  describe "scope refusals" do
    test "returns not_found for unknown and non-station stops", context do
      organization_id = context.organization.id
      version_id = context.version.id

      pathway_evolution_fixture(organization_id, version_id, %{
        pathway_id: "PW_ENTRY",
        service_id: "SVC_A",
        start_time: "09:00",
        end_time: "10:00"
      })

      assert Gtfs.station_closures(organization_id, version_id, "NOPE") == {:error, :not_found}
      assert Gtfs.station_closures(organization_id, version_id, "PLAT_1") == {:error, :not_found}
      assert Gtfs.station_closures(organization_id, version_id, nil) == {:error, :not_found}
    end

    test "returns not_found without rows for unpublished and foreign scopes", context do
      organization_id = context.organization.id
      version_id = context.version.id

      {:ok, staging} = Versions.create_staging_gtfs_version(organization_id, %{name: "Staging"})
      level_fixture(organization_id, staging.id, %{level_id: "L_PLAT", level_index: -1.0})

      staging_station =
        stop_fixture(organization_id, staging.id, %{stop_id: "STN_S", location_type: 1})

      staging_child =
        stop_fixture(organization_id, staging.id, %{
          stop_id: "PLAT_S",
          location_type: 0,
          parent_station: "STN_S",
          level_id: "L_PLAT"
        })

      pathway_fixture(organization_id, staging.id, staging_child.stop_id, "OUT_S", %{
        pathway_id: "PW_S"
      })

      _staging_closure =
        pathway_evolution_fixture(organization_id, staging.id, %{
          pathway_id: "PW_S",
          service_id: "SVC_A",
          start_time: "09:00",
          end_time: "10:00"
        })

      assert Gtfs.station_closures(organization_id, staging.id, staging_station.stop_id) ==
               {:error, :not_found}

      assert Gtfs.closure_calendars(organization_id, staging.id) == {:error, :not_found}
      assert Gtfs.count_closures(organization_id, staging.id) == 0

      other_org = organization_fixture()
      foreign_version = gtfs_version_fixture(other_org.id)

      pathway_fixture(other_org.id, foreign_version.id, "F_ENT", "F_PLAT", %{
        pathway_id: "PW_ENTRY"
      })

      _foreign_closure =
        pathway_evolution_fixture(other_org.id, foreign_version.id, %{
          pathway_id: "PW_ENTRY",
          service_id: "SVC_A",
          start_time: "09:00",
          end_time: "10:00"
        })

      assert Gtfs.station_closures(organization_id, foreign_version.id, "STN_1") ==
               {:error, :not_found}

      assert Gtfs.closure_calendars(organization_id, foreign_version.id) == {:error, :not_found}
      assert Gtfs.count_closures(organization_id, foreign_version.id) == 0

      # The unpublished scope's closure rows stay out of published-scope counts.
      assert Gtfs.count_closures(organization_id, version_id) == 0
    end

    test "returns not_found for malformed scope identifiers", context do
      organization_id = context.organization.id
      version_id = context.version.id

      assert Gtfs.station_closures("not-a-uuid", version_id, "STN_1") == {:error, :not_found}
      assert Gtfs.station_closures(organization_id, "12345", "STN_1") == {:error, :not_found}
      assert Gtfs.closure_calendars("not-a-uuid", "12345") == {:error, :not_found}
      assert Gtfs.count_closures("not-a-uuid", version_id) == 0
      assert Gtfs.count_closures(organization_id, "12345") == 0
    end
  end
end
