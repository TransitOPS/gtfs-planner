defmodule GtfsPlanner.Gtfs.StopReferencesUsageTest do
  @moduledoc """
  `StopReferences.usage/3` answers "where is this stop used?" for the delete
  confirmation, the move review, the replace review and the stop page.

  Two properties matter and are checked here. Every kind in `all/0` that has a
  row appears exactly once with the right count and in the right half of the
  split — a kind in the wrong half would either block a delete that should
  succeed or delete a row that changes service. And every count is scoped to the
  stop's own organization and version, so a row naming the same `stop_id` in
  another version never appears.
  """

  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.DeadheadTime
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Gtfs.JournalEntry
  alias GtfsPlanner.Gtfs.ReliefPoint
  alias GtfsPlanner.Gtfs.StopArea
  alias GtfsPlanner.Gtfs.StopReferences
  alias GtfsPlanner.Gtfs.Translation
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    stop =
      stop_fixture(organization.id, version.id, %{
        stop_id: "1434",
        stop_name: "Southeast First Street"
      })

    %{organization: organization, version: version, stop: stop}
  end

  defp usage(stop) do
    StopReferences.usage(stop.organization_id, stop.gtfs_version_id, stop)
  end

  defp blocking_keys(usage), do: Enum.map(usage.blocking, & &1.key) |> Enum.sort()
  defp descriptive_keys(usage), do: Enum.map(usage.descriptive, & &1.key) |> Enum.sort()

  defp item(usage, key) do
    Enum.find(usage.blocking ++ usage.descriptive, &(&1.key == key))
  end

  describe "an unused stop" do
    test "reports nothing in either half", %{stop: stop} do
      assert usage(stop) == %{blocking: [], descriptive: []}
    end
  end

  describe "patterns" do
    setup %{organization: organization, version: version, stop: stop} do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "12",
          route_short_name: "12",
          route_color: "C8102E"
        })

      calendar = calendar_fixture(organization.id, version.id, %{service_id: "WEEKDAYS"})

      north =
        route_pattern_fixture(organization.id, version.id, %{
          route_pattern_id: "12_north",
          route_id: "12",
          headsign: "To Harbor"
        })

      south =
        route_pattern_fixture(organization.id, version.id, %{
          route_pattern_id: "12_south",
          route_id: "12",
          headsign: "To Mill"
        })

      route_pattern_stop_fixture(north, stop.stop_id, 1)
      route_pattern_stop_fixture(south, stop.stop_id, 1)

      # `Trip.changeset/2` casts no `route_pattern_id` — the link is written by the
      # pattern-linking path, not by a trip create — so the fixture sets it the way
      # that path does.
      for id <- ["t1", "t2"] do
        trip =
          trip_fixture(organization.id, version.id, "12", %{
            trip_id: id,
            service_id: calendar.service_id
          })

        Repo.update!(Ecto.Changeset.change(trip, route_pattern_id: "12_north"))
      end

      %{
        route: route,
        north: north,
        south: south,
        calendar: calendar
      }
    end

    test "count both patterns as blocking", %{stop: stop} do
      usage = usage(stop)

      assert :route_pattern_stops in blocking_keys(usage)
      assert item(usage, :route_pattern_stops).count == 2
    end

    test "name each pattern's route, headsign and weekday trips", %{stop: stop} do
      usage = usage(stop)
      details = item(usage, :route_pattern_stops).details

      by_pattern = Map.new(details, &{&1.detail.route_pattern_id, &1})

      north = by_pattern["12_north"]
      assert north.weekday_trips == 2
      assert north.detail.route_short_name == "12"
      assert north.detail.route_color == "C8102E"
      assert north.label =~ "12"
      assert north.label =~ "To Harbor"

      south = by_pattern["12_south"]
      assert south.weekday_trips == 0
      assert south.label =~ "To Mill"
    end

    test "count a trip's stop times under stop_times",
         %{
           organization: organization,
           version: version,
           stop: stop
         } = context do
      stop_time_fixture(organization.id, version.id, "t1", stop.stop_id, %{stop_sequence: 1})
      stop_time_fixture(organization.id, version.id, "t2", stop.stop_id, %{stop_sequence: 5})

      usage = usage(stop)

      assert :stop_times in blocking_keys(usage)
      assert item(usage, :stop_times).count == 2
      assert context.north
    end
  end

  describe "transfers" do
    setup %{organization: organization, version: version, stop: stop} do
      other =
        stop_fixture(organization.id, version.id, %{stop_id: "1435", stop_name: "Bay Street"})

      transfer_fixture(organization.id, version.id, %{
        from_stop_id: stop.stop_id,
        to_stop_id: other.stop_id,
        min_transfer_time: 180
      })

      %{other: other}
    end

    test "count as descriptive and name the other stop", %{stop: stop} do
      usage = usage(stop)

      assert :transfers_from in descriptive_keys(usage)
      assert item(usage, :transfers_from).count == 1

      [detail] = item(usage, :transfers_from).details
      assert detail.label == "Bay Street"
      assert detail.detail.to_stop_id == "1435"
      assert detail.detail.min_transfer_time == 180
    end

    test "count the reverse direction under its own key", %{
      organization: organization,
      version: version,
      stop: stop,
      other: other
    } do
      transfer_fixture(organization.id, version.id, %{
        from_stop_id: other.stop_id,
        to_stop_id: stop.stop_id
      })

      usage = usage(stop)

      assert :transfers_to in descriptive_keys(usage)
      assert item(usage, :transfers_to).count == 1
      assert [detail] = item(usage, :transfers_to).details
      assert detail.detail.from_stop_id == "1435"
    end
  end

  describe "relief points" do
    test "count as blocking", %{organization: organization, version: version, stop: stop} do
      %ReliefPoint{organization_id: organization.id, gtfs_version_id: version.id, stop_id: "1434"}
      |> ReliefPoint.changeset(%{})
      |> Repo.insert!()

      usage = usage(stop)

      assert :relief_points in blocking_keys(usage)
      assert item(usage, :relief_points).count == 1
      assert [detail] = item(usage, :relief_points).details
      assert detail.detail.stop_id == "1434"
    end
  end

  describe "translations" do
    test "count as descriptive and only for the stops table", %{
      organization: organization,
      version: version,
      stop: stop
    } do
      for table <- ["stops", "routes"] do
        %Translation{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          table_name: table,
          field_name: "stop_name",
          language: "es",
          translation: "Calle",
          record_id: "1434"
        }
        |> Translation.changeset(%{})
        |> Repo.insert!()
      end

      usage = usage(stop)

      assert :translations in descriptive_keys(usage)

      assert item(usage, :translations).count == 1,
             "a translation of a route must not count against a stop"
    end
  end

  describe "stop areas and deadhead times" do
    test "both count as descriptive", %{organization: organization, version: version, stop: stop} do
      %StopArea{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        area_id: "zone_a",
        stop_id: stop.stop_id
      }
      |> StopArea.changeset(%{})
      |> Repo.insert!()

      # Deadhead references are stored encoded as `stop:<stop_id>`.
      %DeadheadTime{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        from_ref: "stop:1434",
        to_ref: "garage:#{Ecto.UUID.generate()}"
      }
      |> DeadheadTime.changeset(%{minutes: 12})
      |> Repo.insert!()

      usage = usage(stop)

      assert :stop_areas in descriptive_keys(usage)
      assert :deadhead_from in descriptive_keys(usage)
      assert item(usage, :stop_areas).count == 1
      assert item(usage, :deadhead_from).count == 1

      [detail] = item(usage, :deadhead_from).details
      assert detail.detail.minutes == 12
      assert detail.label =~ "1434"

      refute detail.label =~ "stop:1434",
             "the encoded prefix is not what an editor should read"
    end
  end

  describe "flex services" do
    test "a hub array and a first and last stop each count", %{
      organization: organization,
      version: version,
      stop: stop
    } do
      %FlexService{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        key: "flex_hub",
        name: "Downtown Flex",
        kind: :area,
        hub_stop_ids: ["1301", "1434"]
      }
      |> FlexService.changeset(%{})
      |> Repo.insert!()

      %FlexService{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        key: "flex_first",
        name: "Harbor Flex",
        kind: :area,
        first_stop_id: "1434"
      }
      |> FlexService.changeset(%{})
      |> Repo.insert!()

      %FlexService{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        key: "flex_last",
        name: "Mill Flex",
        kind: :area,
        last_stop_id: "1434"
      }
      |> FlexService.changeset(%{})
      |> Repo.insert!()

      usage = usage(stop)

      assert :flex_hubs in blocking_keys(usage)
      assert :flex_first in blocking_keys(usage)
      assert :flex_last in blocking_keys(usage)
      assert item(usage, :flex_hubs).count == 1
      assert [hub] = item(usage, :flex_hubs).details
      assert hub.label == "Downtown Flex"
    end
  end

  describe "a station's own rows" do
    test "block on floorplans and journal entries, matched by stops.id", %{
      organization: organization,
      version: version
    } do
      station =
        stop_fixture(organization.id, version.id, %{
          stop_id: "ST-NTC",
          stop_name: "NTC Station",
          location_type: 1
        })

      level =
        level_fixture(organization.id, version.id, %{
          level_id: "ST_NTC_L0",
          level_name: "Ground",
          level_index: 0.0
        })

      {:ok, stop_level} =
        GtfsPlanner.GtfsFixtures.insert_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          stop_id: station.stop_id,
          level_id: level.level_id
        })

      assert stop_level

      # `JournalEntry` has no plain changeset — it is written through
      # `StationJournal.create_changeset/3` with a Scope. Inserting the struct
      # directly is the shortest path to the row this test needs: the point is
      # that the usage report finds it by `station_id`.
      Repo.insert!(%JournalEntry{
        id: Ecto.UUID.generate(),
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_id: station.id,
        author_id: Ecto.UUID.generate(),
        target_type: "node",
        target_id: level.id,
        body: "Concourse note",
        captured_at: DateTime.utc_now()
      })

      usage = usage(station)

      assert :stop_levels in blocking_keys(usage)
      assert :journal_entries in blocking_keys(usage)
    end

    test "block on child stops, matched by parent_station", %{
      organization: organization,
      version: version
    } do
      station =
        stop_fixture(organization.id, version.id, %{
          stop_id: "ST-PDX",
          stop_name: "PDX Station",
          location_type: 1
        })

      child =
        stop_fixture(organization.id, version.id, %{
          stop_id: "ST-PDX-A",
          stop_name: "Bay A",
          parent_station: station.stop_id,
          location_type: 0
        })

      usage = usage(station)

      assert :child_stops in blocking_keys(usage)
      assert item(usage, :child_stops).count == 1
      assert [detail] = item(usage, :child_stops).details
      assert detail.label == child.stop_name
    end
  end

  describe "scoping" do
    test "a row in another version never counts", %{organization: organization, stop: stop} do
      other_version = gtfs_version_fixture(organization.id)

      other_stop =
        stop_fixture(organization.id, other_version.id, %{
          stop_id: stop.stop_id,
          stop_name: "Same ID, other version"
        })

      %StopArea{
        organization_id: organization.id,
        gtfs_version_id: other_version.id,
        area_id: "zone_other",
        stop_id: other_stop.stop_id
      }
      |> StopArea.changeset(%{})
      |> Repo.insert!()

      assert usage(stop) == %{blocking: [], descriptive: []}
    end

    test "another organization's row never counts", %{stop: stop} do
      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)

      %StopArea{
        organization_id: other_org.id,
        gtfs_version_id: other_version.id,
        area_id: "zone_foreign",
        stop_id: stop.stop_id
      }
      |> StopArea.changeset(%{})
      |> Repo.insert!()

      assert usage(stop) == %{blocking: [], descriptive: []}
    end
  end

  describe "the item shape" do
    test "every item carries a key, a label, a positive count and details", %{
      organization: organization,
      version: version,
      stop: stop
    } do
      %StopArea{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        area_id: "zone_a",
        stop_id: stop.stop_id
      }
      |> StopArea.changeset(%{})
      |> Repo.insert!()

      [item] = usage(stop).descriptive

      assert is_atom(item.key)
      assert is_binary(item.label) and item.label != ""
      assert is_integer(item.count) and item.count > 0
      assert is_list(item.details)
    end

    test "the split matches each ref's declared kind", %{
      organization: organization,
      version: version,
      stop: stop
    } do
      %StopArea{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        area_id: "zone_a",
        stop_id: stop.stop_id
      }
      |> StopArea.changeset(%{})
      |> Repo.insert!()

      %ReliefPoint{organization_id: organization.id, gtfs_version_id: version.id, stop_id: "1434"}
      |> ReliefPoint.changeset(%{})
      |> Repo.insert!()

      usage = usage(stop)
      kinds = Map.new(StopReferences.all(), &{&1.key, &1.kind})

      for entry <- usage.blocking ++ usage.descriptive do
        assert kinds[entry.key] == entry_side(usage, entry),
               "#{entry.key} is reported on the wrong side of the split"
      end
    end
  end

  defp entry_side(usage, entry) do
    if Enum.any?(usage.blocking, &(&1.key == entry.key)), do: :blocking, else: :descriptive
  end
end
