defmodule GtfsPlanner.Gtfs.Export.FaresExportTest do
  @moduledoc """
  Merge evidence (EV-27) for the fare files a managed version's export writes:
  the derived `fare_attributes.txt`/`fare_rules.txt`, the zone `areas.txt` and
  `stop_areas.txt`, the `calendar.txt` row of a fare time period, the
  `routes.txt` without its `network_id` column, and the older format kept as
  imported (AC-25, AC-27, AC-28, R2, R7, R10, R14).

  The version enters rows through the production importer and the production
  `Fares.Conversion` writers from `test/fixtures/gtfs/fares/north_coast_v2`,
  and the exports come from the production entry points
  `GtfsPlanner.Gtfs.Export.build_zip/3`, `Export.build_zips/4` and
  `Export.export_to_zip/3`. Every expected value is worked by hand from the
  fixture and the GTFS reference, never read back from the code under test
  (CR-2):

  - the sample's own five single-ride fares are `local_ride` 1.50,
    `valley_ride` 2.50, `coast_ride` 3.50, `valley_coast_ride` 5.00 and
    `intercity_ride` 6.00, each priced for the default rider type on cash;
  - the feed's own `fare_transfer_rules.txt` names `LG_LOCAL`/`LG_INTERCITY`,
    which R3's leg groups — the network ids — do not match, so the two policies
    this sample is read under are written in setup through the production
    `Fares.Transfers.save/5`: two free changes inside 90 minutes on `N_LOCAL`,
    and R6's allowed difference onto `N_INTERCITY`;
  - the sample's `areas.txt` names the three zones the conversion adopted, and
    the conversion gave a zone to twelve of its stops, which is the whole of
    `stop_areas.txt`;
  - the sample's `calendar.txt` is one `weekday` service over September 2026,
    which is the span a fare-only period's calendar row covers (R10);
  - the sample's `routes.txt` carries no `network_id` values, and a managed
    version's does not carry the column at all (R2).

  `Fares.save_time_period/2` writes R10's weekday peak, `Fares.set_older_format/2`
  chooses the imported source, `FareZones.update_zone/4` renames a zone and
  `GtfsPlanner.Gtfs.Flex` creates the flex service, so every case is the
  production writer's own answer rather than a row built by hand.

  Every read here filters by `organization_id` and `gtfs_version_id` together
  (INV-5), and no stored `fare_attributes`, `fare_rules`, `areas`, `stop_areas`
  or `routes.network_id` value is written or changed (INV-3).
  """
  use GtfsPlanner.DataCase, async: true

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures, only: [editor_fixture: 2]
  import GtfsPlanner.FaresFixtures, only: [import!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.FareAttribute
  alias GtfsPlanner.Gtfs.FareLegRule
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Gtfs.Fares.Transfers
  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.Gtfs.Flex
  alias GtfsPlanner.Repo

  @attributes "fare_attributes.txt"
  @rules "fare_rules.txt"

  @calendar_header [
    "service_id",
    "monday",
    "tuesday",
    "wednesday",
    "thursday",
    "friday",
    "saturday",
    "sunday",
    "start_date",
    "end_date"
  ]

  # The sample's own `weekday` service, September 2026, which is the span a
  # fare-only period's calendar row covers (R10).
  @weekday_row ["weekday", "1", "1", "1", "1", "1", "0", "0", "20260901", "20260930"]
  @weekday_peak_row [
    "fare_weekday_peak",
    "1",
    "1",
    "1",
    "1",
    "1",
    "0",
    "0",
    "20260901",
    "20260930"
  ]

  # The thirteen routes of `N_LOCAL` in `route_networks.txt`, which are the
  # routes a `NPT -> TOL` or `TOL -> NPT` cell is narrowed to, because Route 10
  # also serves stops in both zones.
  @local_routes ~w(1 11 12 2 20 21 3 30 4 40 5 6 7)

  # The three zones the sample's `areas.txt` declares, which the conversion
  # adopts as fare zones, and the stops it gave each one.
  @areas [{"CST", "Coast zone"}, {"NPT", "Newport local"}, {"TOL", "Toledo and valley"}]

  @stop_areas [
    {"CST", "DEPOE"},
    {"CST", "LCTC"},
    {"CST", "SEAL"},
    {"CST", "WALDPORT"},
    {"CST", "YACHATS"},
    {"NPT", "AGATE"},
    {"NPT", "HOSP"},
    {"NPT", "NTC"},
    {"NPT", "NYE"},
    {"NPT", "SBPR"},
    {"TOL", "SILETZ"},
    {"TOL", "TOLEDO"}
  ]

  # The zones the imported `fare_rules.txt` addresses, and the fare charging
  # each, which `fare_rules.txt` states with a blank `route_id` because no route
  # outside `N_LOCAL` serves both ends of those pairs.
  @blank_cells [
    {"CST", "CST", "local_ride"},
    {"CST", "NPT", "coast_ride"},
    {"CST", "TOL", "valley_coast_ride"},
    {"NPT", "CST", "coast_ride"},
    {"NPT", "NPT", "local_ride"},
    {"TOL", "CST", "valley_coast_ride"},
    {"TOL", "TOL", "local_ride"}
  ]

  setup do
    organization =
      organization_fixture(%{alias: "fares-export-#{System.unique_integer([:positive])}"})

    # An explicit email rather than `user_fixture/0`: the smokes on this shared
    # partition commit a `user-1@example.com`, and `System.unique_integer/1`
    # restarts per BEAM, so the default email collides on the second run.
    actor =
      editor_fixture(organization, %{
        email: "fares-export-#{System.unique_integer([:positive])}@example.com"
      })

    version = gtfs_version_fixture(organization.id, %{name: "North Coast managed export"})
    import!(organization, version, "north_coast_v2")

    context = %{
      organization: organization,
      version: version,
      actor: actor,
      scope: scope(organization, version, actor)
    }

    {:ok, plan} = Conversion.preview(organization.id, version.id)
    {:ok, _converted} = Conversion.apply(context.scope, plan.fingerprint, [])

    # Two free changes inside 90 minutes on the local network, which is the
    # allowance `fare_attributes` states as `transfers` 2 and
    # `transfer_duration` 5400, and a change onto the Intercity paying the
    # difference, which is what the sample's own journey prices under.
    {:ok, _free} =
      Transfers.save(
        context.scope,
        "N_LOCAL",
        "N_LOCAL",
        %{pay: :free, count: 2, minutes: 90},
        nil
      )

    {:ok, _difference} =
      Transfers.save(
        context.scope,
        "N_LOCAL",
        "N_INTERCITY",
        %{pay: :difference, minutes: 90},
        nil
      )

    context
  end

  describe "the older-format files of a managed version" do
    test "are the derived rows, and never a stored one", context do
      exported = full(context)

      # This sample was imported as Fares v2, so it holds no stored older-format
      # rows at all, and the exported file is the five derived ones.
      assert stored_fare_ids(context, FareAttribute) == []

      assert rows(exported, @attributes) == [
               [
                 "fare_id",
                 "price",
                 "currency_type",
                 "payment_method",
                 "transfers",
                 "agency_id",
                 "transfer_duration"
               ],
               ["coast_ride", "3.50", "USD", "0", "2", "NCT", "5400"],
               ["intercity_ride", "6.00", "USD", "0", "0", "NCT", ""],
               ["local_ride", "1.50", "USD", "0", "2", "NCT", "5400"],
               ["valley_coast_ride", "5.00", "USD", "0", "2", "NCT", "5400"],
               ["valley_ride", "2.50", "USD", "0", "2", "NCT", "5400"]
             ]

      rules = rows(exported, @rules)

      assert hd(rules) == ["fare_id", "route_id", "origin_id", "destination_id", "contains_id"]

      # One row per zone pair (7), the two pairs Route 10 also serves narrowed
      # to the thirteen local routes each (13 + 13), and the Intercity cell
      # narrowed to Route 10 alone (1).
      assert length(rules) == 35

      blank =
        rules
        |> tl()
        |> Enum.filter(&(Enum.at(&1, 1) == ""))
        |> Enum.map(fn [fare_id, _route_id, origin_id, destination_id, _contains_id] ->
          {origin_id, destination_id, fare_id}
        end)
        |> Enum.sort()

      assert blank == Enum.sort(@blank_cells)

      for {from_area_id, to_area_id} <- [{"NPT", "TOL"}, {"TOL", "NPT"}] do
        assert cell_routes(rules, from_area_id, to_area_id) == @local_routes
      end

      # The Intercity cell names no area at all and is narrowed to the one route
      # outside `N_LOCAL` that serves its open ends.
      assert ["intercity_ride", "10", "", "", ""] in tl(rules)
    end

    test "are the stored rows when the older format is kept as imported", context do
      # `north_coast_v1` is the sample's own older-format feed, so the version
      # converted from it holds both sets of rows (R13).
      v1 = converted_v1(context)

      assert {:ok, _result} = Fares.set_older_format(v1.scope, :imported)

      exported = full(v1)

      # The five ids and prices are the fixture's own `fare_attributes.txt`.
      assert rows(exported, @attributes) |> tl() |> Enum.map(&Enum.take(&1, 2)) == [
               ["LOCAL", "1.50"],
               ["VALLEY", "2.50"],
               ["COAST", "3.50"],
               ["VALCOAST", "5.00"],
               ["INTERCITY", "6.00"]
             ]

      # The fixture's own eleven `fare_rules.txt` rows, one of them naming a
      # route and two a `contains_id` the newer format cannot express, which is
      # the whole reason an operator asks for the imported source.
      assert length(rows(exported, @rules)) == 12
      assert stored_fare_ids(v1, FareAttribute) == ~w(COAST INTERCITY LOCAL VALCOAST VALLEY)
    end
  end

  describe "the zone files of a managed version" do
    test "are the inventory's zones and the stops that name one", context do
      exported = full(context)

      assert rows(exported, "areas.txt") == [
               ["area_id", "area_name"] ++ Enum.map(@areas, &Tuple.to_list/1)
             ]

      assert rows(exported, "stop_areas.txt") ==
               [["area_id", "stop_id"] ++ Enum.map(@stop_areas, &Tuple.to_list/1)]
    end

    test "follow a zone rename onto the areas the leg rules reference", context do
      # R7's example: renaming `NPT` to `NEW` leaves every exported
      # `from_area_id`/`to_area_id` present in `areas.txt` (AC-24).
      assert {:ok, _zone} =
               FareZones.update_zone(
                 context.scope.audit,
                 "NPT",
                 %{zone_id: "NEW"}
               )

      exported = full(context)
      areas = exported |> rows("areas.txt") |> tl() |> Enum.map(&hd/1)
      referenced = leg_rule_areas(context)

      assert "NEW" in areas
      assert "NPT" not in areas
      assert referenced != []
      assert Enum.uniq(referenced) -- areas == []
    end
  end

  describe "the routes and calendar files of a managed version" do
    test "state a route's network in route_networks.txt, not in routes.txt", context do
      exported = full(context)

      assert header(exported, "routes.txt") ==
               "route_id,agency_id,route_short_name,route_long_name,route_desc,route_type," <>
                 "route_url,route_color,route_text_color,route_sort_order,continuous_pickup," <>
                 "continuous_drop_off"

      assert Map.has_key?(exported, "route_networks.txt")
      assert hd(rows(exported, "route_networks.txt")) == ["network_id", "route_id"]
    end

    test "append one calendar row per fare time period, over the version's span", context do
      exported = full(context)

      # Before a period exists, the sample's own calendar is the whole file.
      assert rows(exported, "calendar.txt") == [@calendar_header, @weekday_row]

      assert {:ok, _period} = Fares.save_time_period(context.scope, weekday_peak_form())
      exported = full(context)

      assert rows(exported, "calendar.txt") == [
               @calendar_header,
               @weekday_row,
               @weekday_peak_row
             ]

      # The period's ranges are the fare-only service its calendar row names,
      # and the feed's own service is untouched.
      assert exported["timeframes.txt"] =~ "weekday_peak,06:00:00,09:00:00,fare_weekday_peak"
      assert exported["timeframes.txt"] =~ "weekday_peak,15:00:00,18:00:00,fare_weekday_peak"
    end

    test "re-suffix a period's service id when a calendar already holds it", context do
      assert {:ok, _period} = Fares.save_time_period(context.scope, weekday_peak_form())

      # A calendar imported after the period was saved can take the id the
      # writer made unique, so the export re-checks it (R10). The period's own
      # `timeframes` rows are renamed with it, or a fare rule would name a
      # service the calendar does not carry.
      assert {:ok, _calendar} = insert_calendar(context, "fare_weekday_peak")

      exported = full(context)

      # The stored `calendars` rows stream first, in `service_id` order, and the
      # fare-only service is appended after them under the re-suffixed id.
      assert rows(exported, "calendar.txt") |> tl() |> Enum.map(&hd/1) ==
               ["fare_weekday_peak", "weekday", "fare_weekday_peak_2"]

      assert rows(exported, "timeframes.txt") |> tl() |> Enum.map(&Enum.at(&1, 3)) ==
               ["fare_weekday_peak_2", "fare_weekday_peak_2"]
    end
  end

  describe "the other builds of a managed version" do
    test "carry the same fare files as the full export", context do
      assert {:ok, _period} = Fares.save_time_period(context.scope, weekday_peak_form())
      main = full(context)

      assert {:ok, operations, _warnings} =
               Export.build_zip(context.organization.id, context.version.id, :operations)

      shared =
        [
          @attributes,
          @rules,
          "areas.txt",
          "stop_areas.txt",
          "calendar.txt",
          "routes.txt",
          "route_networks.txt"
        ]

      for file <- shared do
        assert operations[file] == main[file], "#{file} differs from the full export"
      end

      # The flex zip is the full file set written again with the flex rows
      # appended, so every fare file beside `routes.txt` is the same bytes.
      area_flex_service(context)

      assert {:ok, %{flex: flex}} =
               Export.build_zips(context.organization.id, context.version.id, :full,
                 include_flex: true
               )

      assert is_binary(flex)
      flexed = entries(flex)

      for file <- shared -- ["routes.txt"] do
        assert flexed[file] == main[file], "#{file} differs from the main build"
      end

      # `routes.txt` is the main one plus the flex route, and the flex route's
      # own row carries the columns the managed spec has.
      assert header(flexed, "routes.txt") == header(main, "routes.txt")
      assert length(rows(flexed, "routes.txt")) == length(rows(main, "routes.txt")) + 1
    end

    test "leave the pathways export unchanged", context do
      assert {:ok, zip} =
               Export.export_to_zip(context.organization.id, context.version.id, :pathways)

      exported = entries(zip)

      # The pathways profile carries stops, levels and pathways only, and drops
      # the fare columns from `stops.txt`, so no fare file and no `zone_id`
      # reaches it.
      assert Enum.sort(Map.keys(exported)) == ["stops.txt"]
      refute header(exported, "stops.txt") =~ "zone_id"
      refute header(exported, "stops.txt") =~ "network_id"
    end
  end

  # -- The version, read the way the export reads it -----------------------------

  # The `:full` ZIP's entries, built by the production entry point.
  defp full(context) do
    assert {:ok, zip, _warnings} =
             Export.build_zip(context.organization.id, context.version.id, :full)

    entries(zip)
  end

  defp entries(zip) do
    {:ok, files} = :zip.unzip(zip, [:memory])
    Map.new(files, fn {name, content} -> {to_string(name), to_string(content)} end)
  end

  defp rows(exported, filename) do
    exported
    |> Map.fetch!(filename)
    |> String.trim_trailing("\n")
    |> String.split("\n")
    |> Enum.map(&String.split(&1, ","))
  end

  defp header(exported, filename) do
    exported |> Map.fetch!(filename) |> String.split("\n") |> hd()
  end

  # The `route_id` values of the rows of one zone pair, in the order the file
  # carries them.
  defp cell_routes(rules, from_area_id, to_area_id) do
    rules
    |> tl()
    |> Enum.filter(fn [_fare_id, _route_id, origin_id, destination_id, _contains_id] ->
      origin_id == from_area_id and destination_id == to_area_id
    end)
    |> Enum.map(&Enum.at(&1, 1))
  end

  defp stored_fare_ids(context, schema) do
    schema
    |> where([row], row.organization_id == ^context.organization.id)
    |> where([row], row.gtfs_version_id == ^context.version.id)
    |> select([row], row.fare_id)
    |> Repo.all()
    |> Enum.sort()
  end

  # The `from_area_id`/`to_area_id` values the version's leg rules carry, which
  # `areas.txt` must cover (AC-24, R7).
  defp leg_rule_areas(context) do
    FareLegRule
    |> where([row], row.organization_id == ^context.organization.id)
    |> where([row], row.gtfs_version_id == ^context.version.id)
    |> select([row], {row.from_area_id, row.to_area_id})
    |> Repo.all()
    |> Enum.flat_map(fn {from_area_id, to_area_id} -> [from_area_id, to_area_id] end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # An area flex service over the sample's own Newport stop, so the flex zip is
  # built and its fare files can be compared with the main build's.
  defp area_flex_service(context) do
    assert {:ok, service} =
             Flex.create_service(context.organization.id, context.version.id, %{
               name: "Newport Dial-a-Ride",
               kind: :area
             })

    assert {:ok, _service} =
             Flex.save_service(
               context.organization.id,
               context.version.id,
               service,
               %{
                 phone: "(541) 555-0142",
                 hub_stop_ids: ["NTC"],
                 hours: [%{area_key: "a1", service_id: "weekday", start: "07:00", end: "18:00"}],
                 booking_rules: []
               },
               [
                 %{
                   key: "a1",
                   name: "Newport",
                   source: :drawn,
                   geojson: %{
                     "type" => "Polygon",
                     "coordinates" => [
                       [
                         [-124.075, 44.595],
                         [-124.02, 44.595],
                         [-124.02, 44.625],
                         [-124.075, 44.625],
                         [-124.075, 44.595]
                       ]
                     ]
                   }
                 }
               ]
             )
  end

  # A weekly `weekday` service under an id of the caller's choosing, which is
  # what a feed imported after a fare period was saved can do.
  defp insert_calendar(context, service_id) do
    %Calendar{}
    |> Ecto.Changeset.change(%{
      service_id: service_id,
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0,
      start_date: ~D[2026-09-01],
      end_date: ~D[2026-09-30],
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id
    })
    |> Repo.insert()
  end

  # A version converted from the sample's own older-format feed, so it holds
  # both the stored v1 rows and the derived v2 rows.
  defp converted_v1(context) do
    organization =
      organization_fixture(%{
        alias: "fares-export-v1-#{context.organization.id}-#{System.unique_integer([:positive])}"
      })

    version = gtfs_version_fixture(organization.id, %{name: "North Coast older format"})
    import!(organization, version, "north_coast_v1")

    scope = scope(organization, version, context.actor)
    {:ok, plan} = Conversion.preview(organization.id, version.id)
    {:ok, _converted} = Conversion.apply(scope, plan.fingerprint, [])

    %{organization: organization, version: version, scope: scope}
  end

  # R10's weekday peak: 06:00–09:00 and 15:00–18:00 on Monday through Friday.
  defp weekday_peak_form do
    %{
      name: "Weekday peak",
      weekdays: 31,
      ranges: [
        %{start_seconds: 6 * 3600, end_seconds: 9 * 3600},
        %{start_seconds: 15 * 3600, end_seconds: 18 * 3600}
      ],
      until_end_of_day?: false
    }
  end

  defp scope(organization, version, actor) do
    %{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end
end
