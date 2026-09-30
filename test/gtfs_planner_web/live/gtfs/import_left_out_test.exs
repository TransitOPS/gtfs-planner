defmodule GtfsPlannerWeb.Gtfs.ImportLeftOutTest do
  @moduledoc """
  The import result's "aren't in a pattern" block: what a finished import reports
  about the trips it could not group, grouped by route, and nothing at all when
  it grouped them all.

  The counts are the ones the trip-grouping prototype's `import-attention` state
  shows for the North Coast Transit scenario: 24 direction-less supplement trips
  and 2 out-of-order trips on route 1, and 1 trip serving a station on route 6.
  No production function computes an expected value; the feeds below are the
  literal GTFS rows that produce them.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @routes """
  route_id,route_type,route_short_name,route_long_name,route_color
  1,3,1,Coast Highway,1F5FBF
  6,3,6,Depoe Bay Shuttle,267548
  """

  # `1_D` is a station (location_type 1), so the one trip that serves it and
  # nothing boardable cannot be placed in a pattern.
  @stops """
  stop_id,stop_name,stop_lat,stop_lon,location_type
  1_A,Lincoln City Transit Center,44.0000,-124.0000,0
  1_B,Otter Rock,44.1000,-124.1000,0
  1_C,Depoe Bay,44.2000,-124.2000,0
  1_D,Newport Transit Center,44.3000,-124.3000,1
  6_A,Depoe Bay City Hall,44.2000,-124.2000,0
  """

  # 24 supplement trips with no direction, 2 with times out of order, 2 that
  # group cleanly, and 1 on route 6 that only serves the station.
  @trips """
  trip_id,route_id,service_id,direction_id
  R1-S-1,1,WK,
  R1-S-2,1,WK,
  R1-S-3,1,WK,
  R1-S-4,1,WK,
  R1-S-5,1,WK,
  R1-S-6,1,WK,
  R1-S-7,1,WK,
  R1-S-8,1,WK,
  R1-S-9,1,WK,
  R1-S-10,1,WK,
  R1-S-11,1,WK,
  R1-S-12,1,WK,
  R1-S-13,1,WK,
  R1-S-14,1,WK,
  R1-S-15,1,WK,
  R1-S-16,1,WK,
  R1-S-17,1,WK,
  R1-S-18,1,WK,
  R1-S-19,1,WK,
  R1-S-20,1,WK,
  R1-S-21,1,WK,
  R1-S-22,1,WK,
  R1-S-23,1,WK,
  R1-S-24,1,WK,
  R1-C-1,1,WK,0
  R1-C-2,1,WK,0
  R1-OK-1,1,WK,0
  R1-OK-2,1,WK,0
  R6-S-1,6,WK,0
  """

  @stop_times """
  trip_id,stop_id,stop_sequence,arrival_time,departure_time
  R1-S-1,1_A,1,08:00:00,08:00:00
  R1-S-1,1_B,2,08:05:00,08:05:00
  R1-S-1,1_C,3,08:10:00,08:10:00
  R1-S-2,1_A,1,08:30:00,08:30:00
  R1-S-2,1_B,2,08:35:00,08:35:00
  R1-S-2,1_C,3,08:40:00,08:40:00
  R1-S-3,1_A,1,09:00:00,09:00:00
  R1-S-3,1_B,2,09:05:00,09:05:00
  R1-S-3,1_C,3,09:10:00,09:10:00
  R1-S-4,1_A,1,09:30:00,09:30:00
  R1-S-4,1_B,2,09:35:00,09:35:00
  R1-S-4,1_C,3,09:40:00,09:40:00
  R1-S-5,1_A,1,10:00:00,10:00:00
  R1-S-5,1_B,2,10:05:00,10:05:00
  R1-S-5,1_C,3,10:10:00,10:10:00
  R1-S-6,1_A,1,10:30:00,10:30:00
  R1-S-6,1_B,2,10:35:00,10:35:00
  R1-S-6,1_C,3,10:40:00,10:40:00
  R1-S-7,1_A,1,11:00:00,11:00:00
  R1-S-7,1_B,2,11:05:00,11:05:00
  R1-S-7,1_C,3,11:10:00,11:10:00
  R1-S-8,1_A,1,11:30:00,11:30:00
  R1-S-8,1_B,2,11:35:00,11:35:00
  R1-S-8,1_C,3,11:40:00,11:40:00
  R1-S-9,1_A,1,12:00:00,12:00:00
  R1-S-9,1_B,2,12:05:00,12:05:00
  R1-S-9,1_C,3,12:10:00,12:10:00
  R1-S-10,1_A,1,12:30:00,12:30:00
  R1-S-10,1_B,2,12:35:00,12:35:00
  R1-S-10,1_C,3,12:40:00,12:40:00
  R1-S-11,1_A,1,13:00:00,13:00:00
  R1-S-11,1_B,2,13:05:00,13:05:00
  R1-S-11,1_C,3,13:10:00,13:10:00
  R1-S-12,1_A,1,13:30:00,13:30:00
  R1-S-12,1_B,2,13:35:00,13:35:00
  R1-S-12,1_C,3,13:40:00,13:40:00
  R1-S-13,1_A,1,14:00:00,14:00:00
  R1-S-13,1_B,2,14:05:00,14:05:00
  R1-S-13,1_C,3,14:10:00,14:10:00
  R1-S-14,1_A,1,14:30:00,14:30:00
  R1-S-14,1_B,2,14:35:00,14:35:00
  R1-S-14,1_C,3,14:40:00,14:40:00
  R1-S-15,1_A,1,15:00:00,15:00:00
  R1-S-15,1_B,2,15:05:00,15:05:00
  R1-S-15,1_C,3,15:10:00,15:10:00
  R1-S-16,1_A,1,15:30:00,15:30:00
  R1-S-16,1_B,2,15:35:00,15:35:00
  R1-S-16,1_C,3,15:40:00,15:40:00
  R1-S-17,1_A,1,16:00:00,16:00:00
  R1-S-17,1_B,2,16:05:00,16:05:00
  R1-S-17,1_C,3,16:10:00,16:10:00
  R1-S-18,1_A,1,16:30:00,16:30:00
  R1-S-18,1_B,2,16:35:00,16:35:00
  R1-S-18,1_C,3,16:40:00,16:40:00
  R1-S-19,1_A,1,17:00:00,17:00:00
  R1-S-19,1_B,2,17:05:00,17:05:00
  R1-S-19,1_C,3,17:10:00,17:10:00
  R1-S-20,1_A,1,17:30:00,17:30:00
  R1-S-20,1_B,2,17:35:00,17:35:00
  R1-S-20,1_C,3,17:40:00,17:40:00
  R1-S-21,1_A,1,18:00:00,18:00:00
  R1-S-21,1_B,2,18:05:00,18:05:00
  R1-S-21,1_C,3,18:10:00,18:10:00
  R1-S-22,1_A,1,18:30:00,18:30:00
  R1-S-22,1_B,2,18:35:00,18:35:00
  R1-S-22,1_C,3,18:40:00,18:40:00
  R1-S-23,1_A,1,19:00:00,19:00:00
  R1-S-23,1_B,2,19:05:00,19:05:00
  R1-S-23,1_C,3,19:10:00,19:10:00
  R1-S-24,1_A,1,19:30:00,19:30:00
  R1-S-24,1_B,2,19:35:00,19:35:00
  R1-S-24,1_C,3,19:40:00,19:40:00
  R1-C-1,1_A,1,09:00:00,09:00:00
  R1-C-1,1_B,2,08:30:00,08:30:00
  R1-C-1,1_C,3,08:45:00,08:45:00
  R1-C-2,1_A,1,09:30:00,09:30:00
  R1-C-2,1_B,2,09:00:00,09:00:00
  R1-C-2,1_C,3,09:15:00,09:15:00
  R1-OK-1,1_A,1,07:00:00,07:00:00
  R1-OK-1,1_B,2,07:05:00,07:05:00
  R1-OK-1,1_C,3,07:10:00,07:10:00
  R1-OK-2,1_A,1,07:30:00,07:30:00
  R1-OK-2,1_B,2,07:35:00,07:35:00
  R1-OK-2,1_C,3,07:40:00,07:40:00
  R6-S-1,6_A,1,06:00:00,06:00:00
  R6-S-1,1_D,2,06:10:00,06:10:00
  """

  # The clean feed: every trip has a direction and a readable stop order, so
  # import groups them all and the block has nothing to report.
  @clean_trips """
  trip_id,route_id,service_id,direction_id
  R1-OK-1,1,WK,0
  R1-OK-2,1,WK,0
  R1-OK-3,1,WK,0
  """

  @clean_stop_times """
  trip_id,stop_id,stop_sequence,arrival_time,departure_time
  R1-OK-1,1_A,1,07:00:00,07:00:00
  R1-OK-1,1_B,2,07:05:00,07:05:00
  R1-OK-1,1_C,3,07:10:00,07:10:00
  R1-OK-2,1_A,1,07:30:00,07:30:00
  R1-OK-2,1_B,2,07:35:00,07:35:00
  R1-OK-2,1_C,3,07:40:00,07:40:00
  R1-OK-3,1_A,1,08:00:00,08:00:00
  R1-OK-3,1_B,2,08:05:00,08:05:00
  R1-OK-3,1_C,3,08:10:00,08:10:00
  """

  setup do
    organization =
      organization_fixture(%{alias: "import-left-out-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "import-left-out-#{System.unique_integer([:positive])}@example.com"})

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

    # The version the page was opened on. It is never the version the import
    # publishes, which is what makes the reported counts a boundary worth proving.
    current = gtfs_version_fixture(organization.id, %{name: "August 2026 service"})

    %{user: user, organization: organization, current: current}
  end

  test "a completed import whose trips were left out reports them by route and reason", context do
    {view, _html} = import_feed(context, "September 2026 service", attention_feed())

    assert has_element?(view, "#import-patterns")
    assert has_element?(view, "#import-left-out")

    # The heading counts every reason of every route: 24 + 2 on route 1, 1 on
    # route 6.
    assert has_element?(view, "#import-patterns-title", "27 trips aren’t in a pattern")

    # Route 1 leads with its own badge and name, and its own total.
    table =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#import-left-out")
      |> LazyHTML.text()

    assert table =~ "Coast Highway"
    assert table =~ "Depoe Bay Shuttle"

    # The reason rows are the reader's own rows, worded for the operator, with
    # the counts the feed produced.
    assert has_element?(
             view,
             "#import-left-out-1-missing_direction",
             "24 trips have no direction"
           )

    assert has_element?(
             view,
             "#import-left-out-1-invalid_chronology",
             "2 trips have times out of order"
           )

    assert has_element?(view, "#import-left-out-6-unusable_stops", "1 trip serves a station")

    # Only a trip with no direction can be grouped, so that row is the one that
    # offers the review, and it points at the published version's own route.
    published = published_version(context, "September 2026 service")

    assert has_element?(
             view,
             "#import-left-out-group-1[href='/gtfs/#{published.id}/routes/1/patterns?review=group']",
             "Group 24 trips"
           )

    refute has_element?(view, "#import-left-out-group-6")

    # The raw codes stay in the disclosure under the table.
    assert has_element?(view, "#import-left-out-codes", "missing_direction")
    assert has_element?(view, "#import-left-out-codes", "invalid_chronology")
  end

  test "an import that grouped every trip renders no left-out block", context do
    {view, _html} = import_feed(context, "Clean Feed", clean_feed())

    assert has_element?(view, "#gtfs-import-result")
    refute has_element?(view, "#import-patterns")
    refute has_element?(view, "#import-left-out")
  end

  test "the counts are the imported version's, not the selected version's", context do
    # The version the page was opened on already has 5 left-out trips of its own,
    # under a route id the imported feed does not use.
    stale_trip(context.organization, context.current, "99", "missing_direction", 5)

    {view, _html} = import_feed(context, "Scoped Feed", attention_feed())

    # Only the imported version's route 1 is reported.
    assert has_element?(
             view,
             "#import-left-out-1-missing_direction",
             "24 trips have no direction"
           )

    refute has_element?(view, "#import-left-out-99-missing_direction")

    # And the reader agrees: the version in the URL still owns its own 5.
    assert Enum.sum(
             Enum.map(
               Gtfs.left_out_trips(context.organization.id, context.current.id),
               & &1.trip_count
             )
           ) ==
             5
  end

  # ── the import, through the page ──────────────────────────────────────────

  defp import_feed(context, version_name, feed) do
    conn = log_in_user(build_conn(), context.user, organization: context.organization)
    {:ok, view, _html} = live(conn, "/gtfs/#{context.current.id}/import")

    zip = gtfs_zip(feed)

    view
    |> file_input("#gtfs-import-form", :gtfs_files, [zip])
    |> then(fn upload -> render_upload(upload, "gtfs.zip") end)

    view
    |> form("#gtfs-import-form", %{"gtfs_import_form" => %{"version_name" => version_name}})
    |> render_submit()

    {view, await_import_task(view)}
  end

  # Deterministically wait for the supervised publication task to finish, then
  # flush the LiveView mailbox by rendering. No sleeps: the task is monitored and
  # the re-render waits for the terminal transition to be applied.
  defp await_import_task(view) do
    for pid <- Task.Supervisor.children(GtfsPlanner.TaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 15_000
    end

    await_import_settled(view, 100)
  end

  defp await_import_settled(view, 0), do: render(view)

  defp await_import_settled(view, tries) do
    html = render(view)

    if html =~ "Imported “" do
      html
    else
      await_import_settled(view, tries - 1)
    end
  end

  # A single .zip entry bundles multiple GTFS files. The LiveView test harness
  # only reliably consumes one upload channel per submit, and the importer
  # expands the archive, so a zip is the deterministic way to import several
  # files in one submission.
  defp gtfs_zip(entries) do
    zip_entries = Enum.map(entries, fn {name, content} -> {String.to_charlist(name), content} end)
    {:ok, {_name, binary}} = :zip.create(~c"gtfs.zip", zip_entries, [:memory])
    %{name: "gtfs.zip", content: binary, type: "application/zip"}
  end

  defp attention_feed do
    [
      {"routes.txt", @routes},
      {"stops.txt", @stops},
      {"trips.txt", @trips},
      {"stop_times.txt", @stop_times}
    ]
  end

  defp clean_feed do
    [
      {"routes.txt", @routes},
      {"stops.txt", @stops},
      {"trips.txt", @clean_trips},
      {"stop_times.txt", @clean_stop_times}
    ]
  end

  defp published_version(context, name) do
    Enum.find(Versions.list_gtfs_versions(context.organization.id), &(&1.name == name))
  end

  # A trip left outside patterns the way import and derivation leave them:
  # `custom` with the reason that classified it. The trips check constraint wants
  # a stop order, so these go through the trip fixture.
  defp stale_trip(organization, version, route_id, reason, count) do
    stop_fixture(organization.id, version.id, %{
      stop_id: "#{route_id}_S1",
      stop_name: "#{route_id} Stop 1",
      location_type: 0
    })

    trip =
      trip_fixture(organization.id, version.id, route_id, %{
        trip_id: "#{route_id}-#{reason}-1",
        direction_id: 0
      })

    stop_time_fixture(organization.id, version.id, trip.trip_id, "#{route_id}_S1", %{
      stop_sequence: 1,
      arrival_time: "08:00:00",
      departure_time: "08:00:00"
    })

    trip_pattern_metadata_fixture(trip, %{
      pattern_derivation_state: "custom",
      pattern_derivation_reason: reason
    })

    for index <- 2..count do
      extra =
        trip_fixture(organization.id, version.id, route_id, %{
          trip_id: "#{route_id}-#{reason}-#{index}",
          direction_id: 0
        })

      stop_time_fixture(organization.id, version.id, extra.trip_id, "#{route_id}_S1", %{
        stop_sequence: 1,
        arrival_time: "08:00:00",
        departure_time: "08:00:00"
      })

      trip_pattern_metadata_fixture(extra, %{
        pattern_derivation_state: "custom",
        pattern_derivation_reason: reason
      })
    end

    Repo.get_by(Trip, gtfs_version_id: version.id, trip_id: "#{route_id}-#{reason}-1")
  end
end
