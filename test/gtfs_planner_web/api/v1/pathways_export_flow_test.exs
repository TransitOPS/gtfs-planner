defmodule GtfsPlannerWeb.Api.V1.PathwaysExportFlowTest do
  @moduledoc """
  Real-composition proof of the companion-API pathways export flow.

  Every request travels the real router, the real bearer and organization plugs,
  the real `Export.Runner`, `Export.Worker`, exporter, extensions exporter and
  `ArtifactStorage` against the local SQL Sandbox and per-test artifact/upload
  roots. Nothing is faked and no test-only internal interface substitutes for a
  production adapter.

  The content oracle is fixture-authored: every expected CSV identifier, manifest
  value and diagram byte below is a literal written by hand in this file. No
  expected value is produced by `FileSpec`, `CsvWriter`, `Manifest`, the exporter
  or any other generator, so a mis-scoped or over-broad exporter cannot
  self-confirm.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.DiagramStorage
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.Import.CsvParser
  alias GtfsPlanner.Gtfs.PathwayEvolution
  alias GtfsPlanner.Repo

  @password "valid user password 123456"
  @deadline_ms 5_000
  @child_deadline_ms 5_000

  # -- fixture-authored literals ----------------------------------------------

  @station_stop_id "FLOW_STATION_A"
  @station_name "Flow Central Station"
  @platform_a1_id "FLOW_PLATFORM_A1"
  @platform_a1_name "Platform A1 North"
  @platform_a2_id "FLOW_PLATFORM_A2"
  @level_id "FLOW_LEVEL_1"
  @level_name "Flow Concourse"
  @pathway_id "FLOW_PATHWAY_1"
  @service_id "FLOW_WEEKDAY"
  @route_off_id "FLOW_ROUTE_OFF"
  @trip_id "FLOW_TRIP_OFF"
  @diagram_filename "flow-floorplan.png"
  @diagram_zip_path "_pathways_extensions/diagrams/FLOW_STATION_A/flow-floorplan.png"

  @diagram_image <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>> <> "FLOW-DIAGRAM-PIXELS-V1"

  # Decoys: the same record shapes under different identifiers in another
  # version of the same organization and in another organization.
  @other_version_stop_id "OTHERVERSION_STATION_B"
  @other_version_route_id "OTHERVERSION_ROUTE_OFF"
  @foreign_stop_id "FOREIGN_STATION_Z"
  @foreign_route_id "FOREIGN_ROUTE_OFF"
  @sparse_stop_id "FLOW_SPARSE_STOP"

  setup do
    unique = System.unique_integer([:positive])
    artifacts_root = Path.join(System.tmp_dir!(), "pathways-flow-artifacts-#{unique}")
    uploads_root = Path.join(System.tmp_dir!(), "pathways-flow-uploads-#{unique}")
    File.mkdir_p!(artifacts_root)
    File.mkdir_p!(uploads_root)

    previous = %{
      gtfs_task_artifacts_path: Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path),
      uploads_path: Application.get_env(:gtfs_planner, :uploads_path),
      gtfs_task_artifacts_max_total_bytes:
        Application.get_env(:gtfs_planner, :gtfs_task_artifacts_max_total_bytes)
    }

    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, artifacts_root)
    Application.put_env(:gtfs_planner, :uploads_path, uploads_root)

    children_before = runner_child_pids()

    on_exit(fn ->
      # Owned workers must be finished before the sandbox connection and the
      # temporary roots disappear.
      await_new_children(children_before)
      File.rm_rf!(artifacts_root)
      File.rm_rf!(uploads_root)
      Enum.each(previous, fn {key, value} -> restore_env(key, value) end)
    end)

    organization = organization_fixture()
    user = user_fixture(%{password: @password})

    {:ok, membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: []
      })

    %{
      artifacts_root: artifacts_root,
      children_before: children_before,
      organization: organization,
      user: user,
      membership: membership,
      version: gtfs_version_fixture(organization.id, %{name: "Flow Selected Version"}),
      other_version: gtfs_version_fixture(organization.id, %{name: "Flow Other Version"})
    }
  end

  # ---------------------------------------------------------------------------
  # Composed journey
  # ---------------------------------------------------------------------------

  test "login, version discovery, request, status and download compose to a scoped archive", %{
    artifacts_root: artifacts_root,
    organization: organization,
    user: user,
    version: version,
    other_version: other_version
  } do
    foreign_organization = organization_fixture()

    foreign_version =
      gtfs_version_fixture(foreign_organization.id, %{name: "Flow Foreign Version"})

    selected = seed_complete_version(organization.id, version.id)

    # The version really does hold a scheduled closure, so the unchanged file
    # names below are not observed on a closure-free version.
    assert %PathwayEvolution{} = Repo.get(PathwayEvolution, selected.closure.id)
    assert selected.closure.pathway_id == @pathway_id
    assert selected.closure.start_time == 82_800
    assert selected.closure.end_time == 93_600

    seed_decoy_version(
      organization.id,
      other_version.id,
      @other_version_stop_id,
      @other_version_route_id
    )

    seed_decoy_version(
      foreign_organization.id,
      foreign_version.id,
      @foreign_stop_id,
      @foreign_route_id
    )

    token = login!(user, organization.id)

    # Version discovery goes through the real listing route; the request then
    # uses the identifier that route returned.
    listed_ids = listed_version_ids(token, organization.id)
    assert version.id in listed_ids
    assert other_version.id in listed_ids
    refute foreign_version.id in listed_ids

    {created, create_conn} =
      build_conn()
      |> session_conn(token, organization.id)
      |> post(create_path(version.id))
      |> response_with_body(202)

    run_id = created["data"]["id"]
    assert created["data"]["version_id"] == version.id
    assert created["data"]["export_type"] == "pathways"
    assert get_resp_header(create_conn, "location") == [status_path(version.id, run_id)]

    ready = await_ready_run!(organization.id, version.id, run_id)
    assert ready.state == :ready
    assert ready.failure_code == nil

    {shown, show_conn} =
      build_conn()
      |> session_conn(token, organization.id)
      |> get(status_path(version.id, run_id))
      |> response_with_body(200)

    assert shown["data"]["state"] == "ready"
    assert shown["data"]["failure_code"] == nil
    assert shown["data"]["size_bytes"] == ready.artifact_size_bytes
    assert shown["data"]["sha256"] == ready.artifact_sha256
    assert shown["data"]["download_path"] == download_path(version.id, run_id)
    assert shown["data"]["expires_at"] == DateTime.to_iso8601(ready.artifact_expires_at)

    download_conn =
      build_conn()
      |> session_conn(token, organization.id)
      |> get(download_path(version.id, run_id))

    assert download_conn.status == 200
    body = download_conn.resp_body

    # The downloaded bytes are exactly the stored artifact, checked the same way
    # the context checks them before publishing metadata.
    assert Base.encode16(:crypto.hash(:sha256, body), case: :lower) == shown["data"]["sha256"]
    assert byte_size(body) == shown["data"]["size_bytes"]

    assert [content_type] = get_resp_header(download_conn, "content-type")
    assert content_type =~ "application/zip"
    assert get_resp_header(download_conn, "cache-control") == ["private, no-store"]

    assert get_resp_header(download_conn, "content-length") == [
             Integer.to_string(byte_size(body))
           ]

    assert %Run{download_count: 1, download_claimed_until: nil} =
             ExportRuns.get_for_version(organization.id, version.id, run_id)

    # The private storage root never appears in any response of the flow.
    for response_conn <- [create_conn, show_conn, download_conn] do
      refute response_conn.resp_body =~ artifacts_root
    end

    assert_stored_archive(body, selected)
  end

  # ---------------------------------------------------------------------------
  # Sparse and empty fixtures
  # ---------------------------------------------------------------------------

  test "a stops-only version that also holds routes and trips exports stops.txt alone", %{
    organization: organization,
    user: user,
    version: version
  } do
    stop_fixture(organization.id, version.id, stop_id: @sparse_stop_id, stop_name: "Sparse Stop")

    route =
      route_fixture(organization.id, version.id, route_id: "FLOW_SPARSE_ROUTE", active: true)

    trip_fixture(organization.id, version.id, route.id, trip_id: "FLOW_SPARSE_TRIP")

    token = login!(user, organization.id)

    {created, _conn} =
      build_conn()
      |> session_conn(token, organization.id)
      |> post(create_path(version.id))
      |> response_with_body(202)

    run_id = created["data"]["id"]
    assert await_ready_run!(organization.id, version.id, run_id).state == :ready

    {shown, _conn} =
      build_conn()
      |> session_conn(token, organization.id)
      |> get(status_path(version.id, run_id))
      |> response_with_body(200)

    download_conn =
      build_conn()
      |> session_conn(token, organization.id)
      |> get(download_path(version.id, run_id))

    assert download_conn.status == 200
    body = download_conn.resp_body
    assert Base.encode16(:crypto.hash(:sha256, body), case: :lower) == shown["data"]["sha256"]

    # The routes and trips exist in the database but are never exported.
    assert %Gtfs.Route{} = Repo.get_by(Gtfs.Route, route_id: "FLOW_SPARSE_ROUTE")
    assert %Gtfs.Trip{} = Repo.get_by(Gtfs.Trip, trip_id: "FLOW_SPARSE_TRIP")

    assert archive_names(body) == ["stops.txt"]

    stops = parse_csv!("stops.txt", entry!(body, "stops.txt"))
    assert Enum.map(stops.rows, & &1["stop_id"]) == [@sparse_stop_id]
    assert hd(stops.rows)["stop_name"] == "Sparse Stop"
  end

  test "an empty version reaches failed/no_data through the real worker", %{
    organization: organization,
    user: user,
    version: version
  } do
    token = login!(user, organization.id)

    {created, _conn} =
      build_conn()
      |> session_conn(token, organization.id)
      |> post(create_path(version.id))
      |> response_with_body(202)

    run_id = created["data"]["id"]

    terminal = await_terminal_run!(organization.id, version.id, run_id)
    assert terminal.state == :failed
    assert terminal.failure_code == "no_data"

    {shown, _conn} =
      build_conn()
      |> session_conn(token, organization.id)
      |> get(status_path(version.id, run_id))
      |> response_with_body(200)

    assert shown["data"]["state"] == "failed"
    assert shown["data"]["failure_code"] == "no_data"
    assert shown["data"]["size_bytes"] == nil
    assert shown["data"]["sha256"] == nil
    assert shown["data"]["download_path"] == nil
  end

  # ---------------------------------------------------------------------------
  # The success path is explicit about non-ready terminal states
  # ---------------------------------------------------------------------------

  test "failed, interrupted, cancelled and expired runs fail the success path explicitly", %{
    organization: organization
  } do
    children_before = runner_child_pids()

    for {state, failure_code} <- [
          {:failed, "no_data"},
          {:interrupted, "lease_expired"},
          {:cancelled, "cancel_requested"},
          {:expired, "artifact_expired"}
        ] do
      version = gtfs_version_fixture(organization.id, %{name: "Terminal #{state}"})
      run = terminal_run!(organization.id, version.id, state, failure_code)

      error =
        assert_raise ExUnit.AssertionError, fn ->
          await_ready_run!(organization.id, version.id, run.id)
        end

      assert Exception.message(error) =~ to_string(state)
      assert Exception.message(error) =~ failure_code
    end

    # Reading durable state never starts a build.
    assert runner_child_pids() == children_before
  end

  # ---------------------------------------------------------------------------
  # Fixture seeds
  # ---------------------------------------------------------------------------

  # A complete version: one station, two child stops on one level, one pathway,
  # one diagram coordinate, one stop-level link with a stored diagram, and one
  # inactive route that only the extensions manifest reports.
  defp seed_complete_version(organization_id, version_id) do
    level =
      level_fixture(organization_id, version_id, %{
        level_id: @level_id,
        level_index: 0.0,
        level_name: @level_name
      })

    station =
      stop_fixture(organization_id, version_id, %{
        stop_id: @station_stop_id,
        stop_name: @station_name,
        location_type: 1
      })

    platform_a1 =
      stop_fixture(organization_id, version_id, %{
        stop_id: @platform_a1_id,
        stop_name: @platform_a1_name,
        location_type: 0,
        parent_station: @station_stop_id,
        level_id: @level_id,
        platform_code: "A1",
        diagram_coordinate: %{"x" => 30, "y" => 40}
      })

    platform_a2 =
      stop_fixture(organization_id, version_id, %{
        stop_id: @platform_a2_id,
        stop_name: "Platform A2 South",
        location_type: 0,
        parent_station: @station_stop_id,
        level_id: @level_id
      })

    pathway =
      pathway_fixture(organization_id, version_id, station.id, platform_a1.id, %{
        pathway_id: @pathway_id,
        pathway_mode: 1,
        is_bidirectional: true,
        traversal_time: 45
      })

    {:ok, _stop_level} =
      insert_stop_level(%{
        organization_id: organization_id,
        gtfs_version_id: version_id,
        stop_id: station.stop_id,
        level_id: level.level_id,
        diagram_filename: @diagram_filename,
        scale_point_a: %{"x" => 10, "y" => 12},
        scale_point_b: %{"x" => 60, "y" => 58},
        scale_distance_meters: Decimal.new("12.5000"),
        scale_meters_per_unit: Decimal.new("0.02500000")
      })

    :ok =
      DiagramStorage.store_import_image(
        organization_id,
        version_id,
        @station_stop_id,
        @diagram_filename,
        @diagram_image
      )

    route = route_fixture(organization_id, version_id, route_id: @route_off_id, active: false)
    trip_fixture(organization_id, version_id, route.id, trip_id: @trip_id)

    # A native calendar and one scheduled closure on the exported pathway. The
    # companion-API archive is the static pathways profile, so this version is
    # exactly the case where a closure exists and the file names must not move.
    calendar_fixture(organization_id, version_id, %{service_id: @service_id})

    closure =
      %PathwayEvolution{organization_id: organization_id, gtfs_version_id: version_id}
      |> PathwayEvolution.changeset(%{
        pathway_id: @pathway_id,
        service_id: @service_id,
        start_time: "23:00",
        end_time: "26:00",
        note: "APPLICATION-ONLY-NOTE"
      })
      |> Repo.insert!()

    %{
      station: station,
      platform_a1: platform_a1,
      platform_a2: platform_a2,
      pathway: pathway,
      level: level,
      route: route,
      closure: closure
    }
  end

  # A decoy version carries the same record shapes under different identifiers so
  # any cross-version or cross-tenant leakage is visible in the exported text.
  defp seed_decoy_version(organization_id, version_id, stop_id, route_id) do
    stop_fixture(organization_id, version_id, stop_id: stop_id, location_type: 1)

    route = route_fixture(organization_id, version_id, route_id: route_id, active: false)
    trip_fixture(organization_id, version_id, route.id, trip_id: "DECOY_TRIP_#{stop_id}")
  end

  defp terminal_run!(organization_id, version_id, state, failure_code) do
    {:ok, run} =
      ExportRuns.create_pending(
        organization_id,
        version_id,
        %{id: Ecto.UUID.generate(), email: "flow-decoy@example.com"},
        :pathways
      )

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    run
    |> Run.system_changeset(%{
      state: state,
      failure_code: failure_code,
      started_at: now,
      finished_at: now,
      lease_token: nil,
      lease_expires_at: nil
    })
    |> Repo.update!()
  end

  # ---------------------------------------------------------------------------
  # Fixture-authored archive oracle
  # ---------------------------------------------------------------------------

  defp assert_stored_archive(body, selected) do
    names = archive_names(body)

    assert names == [
             "_pathways_extensions.json",
             @diagram_zip_path,
             "levels.txt",
             "pathways.txt",
             "stops.txt"
           ]

    stops_text = to_string(entry!(body, "stops.txt"))
    levels_text = to_string(entry!(body, "levels.txt"))
    pathways_text = to_string(entry!(body, "pathways.txt"))
    manifest_text = to_string(entry!(body, "_pathways_extensions.json"))

    stops = parse_csv!("stops.txt", stops_text)

    assert Enum.sort(Enum.map(stops.rows, & &1["stop_id"])) ==
             Enum.sort([@station_stop_id, @platform_a1_id, @platform_a2_id])

    station_row = row_for!(stops.rows, "stop_id", @station_stop_id)
    assert station_row["stop_name"] == @station_name
    assert station_row["location_type"] == "1"

    a1_row = row_for!(stops.rows, "stop_id", @platform_a1_id)
    assert a1_row["stop_name"] == @platform_a1_name
    assert a1_row["parent_station"] == @station_stop_id
    assert a1_row["level_id"] == @level_id
    assert a1_row["platform_code"] == "A1"

    a2_row = row_for!(stops.rows, "stop_id", @platform_a2_id)
    assert a2_row["parent_station"] == @station_stop_id
    assert a2_row["level_id"] == @level_id

    levels = parse_csv!("levels.txt", levels_text)
    assert length(levels.rows) == 1
    assert hd(levels.rows)["level_id"] == @level_id
    assert hd(levels.rows)["level_name"] == @level_name
    assert hd(levels.rows)["level_index"] == "0.0"

    pathways = parse_csv!("pathways.txt", pathways_text)
    assert length(pathways.rows) == 1

    pathway_row = hd(pathways.rows)
    assert pathway_row["pathway_id"] == @pathway_id
    assert pathway_row["from_stop_id"] == selected.station.id
    assert pathway_row["to_stop_id"] == selected.platform_a1.id
    assert pathway_row["pathway_mode"] == "1"
    assert pathway_row["is_bidirectional"] == "1"
    assert pathway_row["traversal_time"] == "45"

    manifest = Jason.decode!(manifest_text)
    assert manifest["version"] == 1
    assert is_binary(manifest["exported_at"])

    assert manifest["stop_diagram_coordinates"] == [
             %{"stop_id" => @platform_a1_id, "diagram_coordinate" => %{"x" => 30, "y" => 40}}
           ]

    assert manifest["stop_levels"] == [
             %{
               "stop_id" => @station_stop_id,
               "level_id" => @level_id,
               "diagram_filename" => @diagram_filename,
               "scale_point_a" => %{"x" => 10, "y" => 12},
               "scale_point_b" => %{"x" => 60, "y" => 58},
               "scale_distance_meters" => "12.5000",
               "scale_meters_per_unit" => "0.02500000"
             }
           ]

    # New manifests carry no inactive route flags (spec 16, step 15).
    assert manifest["route_active_flags"] == []
    refute manifest_text =~ @route_off_id

    assert manifest["diagram_images"] == [
             %{
               "station_stop_id" => @station_stop_id,
               "filename" => @diagram_filename,
               "zip_path" => @diagram_zip_path
             }
           ]

    # The stored diagram bytes are the fixture bytes, not merely a present file.
    assert entry!(body, @diagram_zip_path) == @diagram_image

    # Decoy identifiers from another version or another tenant never appear.
    for decoy <- [
          @other_version_stop_id,
          @other_version_route_id,
          @foreign_stop_id,
          @foreign_route_id
        ] do
      refute decoy in names
      refute stops_text =~ decoy
      refute levels_text =~ decoy
      refute pathways_text =~ decoy
      refute manifest_text =~ decoy
    end

    # routes.txt and trips.txt are never part of a pathways export.
    refute "routes.txt" in names
    refute "trips.txt" in names

    # A version holding scheduled closures and their native calendar still
    # exports exactly the same static file names: no closure file and no
    # calendar files reach the companion-API archive.
    refute "pathway_evolutions.txt" in names
    refute "calendar.txt" in names
    refute "calendar_dates.txt" in names
    refute "calendar_attributes.txt" in names
  end

  defp archive_names(body) do
    {:ok, files} = :zip.unzip(body, [:memory])
    files |> Enum.map(fn {name, _content} -> to_string(name) end) |> Enum.sort()
  end

  defp entry!(body, filename) do
    {:ok, files} = :zip.unzip(body, [:memory])

    case Enum.find(files, fn {name, _content} -> to_string(name) == filename end) do
      {_name, content} -> content
      nil -> flunk("archive is missing #{filename}")
    end
  end

  defp parse_csv!(filename, content) do
    {:ok, %{headers: headers, events: events}} = CsvParser.stream(filename, content)

    rows =
      Enum.map(events, fn
        {:ok, _row_number, record} ->
          record

        {:error, error} ->
          flunk("#{filename} contains a row the GTFS CSV parser rejects: #{inspect(error)}")
      end)

    %{headers: headers, rows: rows}
  end

  defp row_for!(rows, key, value) do
    case Enum.find(rows, &(&1[key] == value)) do
      nil -> flunk("no CSV row with #{key} == #{inspect(value)}")
      row -> row
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP helpers
  # ---------------------------------------------------------------------------

  defp login!(user, organization_id) do
    response =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")
      |> post("/api/v1/auth/login", %{"email" => user.email, "password" => @password})

    assert %{"data" => data} = json_response(response, 200)
    assert data["organization_id"] == organization_id
    assert data["roles"] == []
    assert is_binary(data["token"])

    data["token"]
  end

  defp listed_version_ids(token, organization_id) do
    response =
      build_conn()
      |> session_conn(token, organization_id)
      |> get("/api/v1/versions")

    assert %{"data" => data} = json_response(response, 200)
    Enum.map(data, & &1["id"])
  end

  defp session_conn(conn, token, organization_id) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("x-organization-id", organization_id)
  end

  defp response_with_body(conn, status) do
    assert conn.status == status
    {Jason.decode!(conn.resp_body), conn}
  end

  defp create_path(version_id), do: "/api/v1/versions/#{version_id}/pathways-exports"

  defp status_path(version_id, export_id),
    do: "/api/v1/versions/#{version_id}/pathways-exports/#{export_id}"

  defp download_path(version_id, export_id), do: "#{status_path(version_id, export_id)}/download"

  # ---------------------------------------------------------------------------
  # Synchronization and owned-worker teardown
  # ---------------------------------------------------------------------------

  # Subscribe before the first durable read: a build that finished between the
  # POST response and this call is already visible in the database, and a build
  # that finishes later is announced. The deadline bounds a lost message, but
  # once it passes with the run still non-terminal, that is a failure: flunk
  # with the run's current state instead of spinning.
  defp await_ready_run!(organization_id, version_id, run_id) do
    run = await_run(organization_id, version_id, run_id)

    case run.state do
      :ready ->
        run

      state ->
        flunk(
          "pathways export run #{run_id} reached terminal state #{inspect(state)} " <>
            "with failure_code #{inspect(run.failure_code)} before it became ready"
        )
    end
  end

  defp await_terminal_run!(organization_id, version_id, run_id) do
    await_run(organization_id, version_id, run_id)
  end

  defp await_run(organization_id, version_id, run_id) do
    Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, ExportRuns.topic(run_id))
    deadline = System.monotonic_time(:millisecond) + @deadline_ms
    do_await_run(organization_id, version_id, run_id, deadline)
  end

  defp do_await_run(organization_id, version_id, run_id, deadline) do
    run = ExportRuns.get_for_version(organization_id, version_id, run_id)

    cond do
      run.state in [:ready, :failed, :interrupted, :cancelled, :expired] ->
        run

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "pathways export run #{run_id} did not reach a terminal state before the deadline; " <>
            "state=#{inspect(run.state)} failure_code=#{inspect(run.failure_code)}"
        )

      true ->
        await_change(run_id, deadline)
        do_await_run(organization_id, version_id, run_id, deadline)
    end
  end

  defp await_change(run_id, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      # Messages carry only the run id, never a state.
      {:export_run_changed, ^run_id} -> :ok
    after
      remaining -> :ok
    end
  end

  defp runner_child_pids do
    for {_id, pid, _type, _modules} <-
          DynamicSupervisor.which_children(GtfsPlanner.Gtfs.Export.RunnerSupervisor),
        is_pid(pid) do
      pid
    end
  end

  # Only children created by this test are awaited or terminated; the
  # application supervisor is never stopped.
  defp await_new_children(children_before) do
    Enum.each(runner_child_pids() -- children_before, &await_child/1)
  end

  defp await_child(pid) do
    # A child that already exited answers with :noproc, which is a normal result.
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      @child_deadline_ms -> kill_child(pid, ref)
    end
  end

  # :kill is untrappable, so both DOWNs below are guaranteed to arrive. The
  # runner's build task (its `task_pid`) holds the sandboxed DB connection, so
  # it must be confirmed dead too before teardown reclaims the connection and
  # the temporary artifact/upload roots.
  defp kill_child(pid, ref) do
    task_pid = runner_task_pid(pid)
    task_ref = task_pid && Process.monitor(task_pid)

    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end

    if task_ref do
      receive do
        {:DOWN, ^task_ref, :process, ^task_pid, _reason} -> :ok
      end
    end
  end

  defp runner_task_pid(pid) do
    %{task_pid: task_pid} = :sys.get_state(pid, @child_deadline_ms)
    task_pid
  catch
    :exit, _ -> nil
  end

  defp restore_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_env(key, value), do: Application.put_env(:gtfs_planner, key, value)
end
