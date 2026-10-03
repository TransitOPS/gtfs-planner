defmodule GtfsPlanner.Gtfs.RouteLifecycleExportTest do
  @moduledoc """
  R6 snapshot export composition for the route lifecycle (spec 16, step 16).

  Every case runs through the ordinary public export entrypoints —
  `Export.build_zip/3`, `Export.export_specs_to_directory/4` and the normal
  export worker/download chain — with the production `Snapshot.Repo`
  repeatable-read adapter and `StreamBuilder` over real `Repo` streams. Fixtures
  are committed rows outside the shared Sandbox (the export owns its own
  transaction), and the concurrent cases reuse `export_test.exs`'s telemetry
  barrier setup so a real status writer can commit mid-export without sleeps or
  repo mocks.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.Attribution
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Export.FileSpec
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.Export.Snapshot
  alias GtfsPlanner.Gtfs.Export.Worker
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Routes
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @actor %{id: Ecto.UUID.generate(), email: "export-composition@example.com"}

  setup do
    previous_snapshot = Application.fetch_env(:gtfs_planner, :gtfs_export_snapshot)
    previous_tx = Application.fetch_env(:gtfs_planner, :reviewed_apply_transaction)

    # Default production composition: only external boundaries (the artifact
    # filesystem root) are replaced; internal adapters stay concrete.
    Application.put_env(:gtfs_planner, :gtfs_export_snapshot, Snapshot.Repo)
    Application.put_env(:gtfs_planner, :reviewed_apply_transaction, ReviewedApplyTransaction.Repo)

    root = Path.join(System.tmp_dir!(), "route16-export-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      File.rm_rf(root)
      restore_env(:gtfs_export_snapshot, previous_snapshot)
      restore_env(:reviewed_apply_transaction, previous_tx)

      if previous_root,
        do: Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, previous_root),
        else: Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_path)
    end)

    :ok
  end

  describe "one snapshot never mixes route/trip selection" do
    test "a deactivation committed mid-export cannot mix route and trip rows" do
      parent = self()
      fixture = unboxed(fn -> lifecycle_fixture() end)
      on_exit(fn -> unboxed(fn -> cleanup_fixture(fixture) end) end)

      toggle =
        unboxed(fn -> seed_toggle_pair!(fixture.organization.id, fixture.version.id, true) end)

      dirs_before = export_temp_dirs()

      task =
        Task.async(fn ->
          receive do
            :start_export -> :ok
          end

          unboxed(fn -> Export.build_zip(fixture.organization.id, fixture.version.id, :full) end)
        end)

      handler_id = {__MODULE__, :deactivate_race}
      attach_trips_barrier(handler_id, parent, task.pid)
      on_exit(fn -> :telemetry.detach(handler_id) end)

      exporter = task.pid
      send(exporter, :start_export)
      assert_receive {:export_paused, ^exporter}, 10_000

      # The real public status writer commits the deactivation while the
      # export's repeatable-read snapshot is open.
      assert {:ok, %{route: deactivated}} =
               unboxed(fn ->
                 Gtfs.set_route_active("R_TOGGLE", false, Routes.source(toggle), fixture.audit)
               end)

      assert deactivated.active == false

      send(exporter, :resume_export)
      assert {:ok, zip_binary, []} = Task.await(task, 15_000)
      files = zip_files!(zip_binary)

      # The whole archive describes exactly the pre-change revision: route and
      # trip selection can never disagree (FH-6) because both come from one
      # snapshot. A per-statement reader would emit the post-change sets here.
      assert column(csv_rows(files["routes.txt"]), "route_id") == ["R_KEEP", "R_TOGGLE"]
      assert column(csv_rows(files["trips.txt"]), "trip_id") == ["T_KEEP", "T_TOGGLE"]

      # The concurrent change itself is live for later snapshots.
      assert unboxed(fn -> reload_active(fixture, "R_TOGGLE") end) == false
      assert_no_export_temp_dir_leak(dirs_before)
    end

    test "a reactivation committed mid-export cannot mix route and trip rows" do
      parent = self()
      fixture = unboxed(fn -> lifecycle_fixture() end)
      on_exit(fn -> unboxed(fn -> cleanup_fixture(fixture) end) end)

      toggle =
        unboxed(fn -> seed_toggle_pair!(fixture.organization.id, fixture.version.id, false) end)

      dirs_before = export_temp_dirs()

      task =
        Task.async(fn ->
          receive do
            :start_export -> :ok
          end

          unboxed(fn -> Export.build_zip(fixture.organization.id, fixture.version.id, :full) end)
        end)

      handler_id = {__MODULE__, :reactivate_race}
      attach_trips_barrier(handler_id, parent, task.pid)
      on_exit(fn -> :telemetry.detach(handler_id) end)

      exporter = task.pid
      send(exporter, :start_export)
      assert_receive {:export_paused, ^exporter}, 10_000

      assert {:ok, %{route: reactivated}} =
               unboxed(fn ->
                 Gtfs.set_route_active("R_TOGGLE", true, Routes.source(toggle), fixture.audit)
               end)

      assert reactivated.active == true

      send(exporter, :resume_export)
      assert {:ok, zip_binary, []} = Task.await(task, 15_000)
      files = zip_files!(zip_binary)

      # The pre-change snapshot excludes the closure from both streams: a mix
      # would surface a trip whose route is absent from routes.txt.
      assert column(csv_rows(files["routes.txt"]), "route_id") == ["R_KEEP"]
      assert column(csv_rows(files["trips.txt"]), "trip_id") == ["T_KEEP"]

      assert unboxed(fn -> reload_active(fixture, "R_TOGGLE") end) == true
      assert_no_export_temp_dir_leak(dirs_before)
    end
  end

  describe "R6 composition across the real output paths" do
    test "full and operations ZIP bytes share the R6 row sets" do
      fixture = unboxed(fn -> lifecycle_fixture() end)
      on_exit(fn -> unboxed(fn -> cleanup_fixture(fixture) end) end)
      unboxed(fn -> seed_r6_closure!(fixture.organization.id, fixture.version.id) end)

      assert {:ok, zip_full, []} =
               unboxed(fn ->
                 Export.build_zip(fixture.organization.id, fixture.version.id, :full)
               end)

      assert_r6_rows!(zip_files!(zip_full))

      assert {:ok, zip_operations, warnings} =
               unboxed(fn ->
                 Export.build_zip(fixture.organization.id, fixture.version.id, :operations)
               end)

      assert_r6_rows!(zip_files!(zip_operations))
      assert Enum.any?(warnings, &(&1.code == "tods_file_omitted"))
    end

    test "directory materialization streams the same R6 selection as the ZIP" do
      fixture = unboxed(fn -> lifecycle_fixture() end)
      on_exit(fn -> unboxed(fn -> cleanup_fixture(fixture) end) end)
      unboxed(fn -> seed_r6_closure!(fixture.organization.id, fixture.version.id) end)

      output_dir =
        Path.join(System.tmp_dir!(), "route16_export_dir_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(output_dir) end)

      assert {:ok, file_paths} =
               unboxed(fn ->
                 Export.export_specs_to_directory(
                   fixture.organization.id,
                   fixture.version.id,
                   FileSpec.get_specs(:full),
                   output_dir
                 )
               end)

      files =
        Map.new(file_paths, fn path -> {Path.basename(path), File.read!(path)} end)

      assert_r6_rows!(files)
    end

    test "the normal export worker/download publishes bytes with the same R6 selection" do
      fixture = unboxed(fn -> lifecycle_fixture() end)
      on_exit(fn -> unboxed(fn -> cleanup_fixture(fixture) end) end)
      unboxed(fn -> seed_r6_closure!(fixture.organization.id, fixture.version.id) end)

      run =
        unboxed(fn ->
          {:ok, run} =
            ExportRuns.create_pending(
              fixture.organization.id,
              fixture.version.id,
              @actor,
              :full
            )

          {:ok, claimed, generation, token} =
            ExportRuns.claim(fixture.organization.id, run.id, :build)

          assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))
          run
        end)

      assert %Run{state: :ready, artifact_sha256: sha} =
               unboxed(fn -> Repo.get!(Run, run.id) end)

      assert is_binary(sha)

      claim =
        unboxed(fn ->
          {:ok, claim} =
            ExportRuns.claim_download(fixture.organization.id, fixture.version.id, run.id)

          claim
        end)

      bytes = File.read!(claim.path)
      assert claim.size == byte_size(bytes)
      assert_r6_rows!(zip_files!(bytes))
    end

    test "pathways selection is unchanged by route status" do
      fixture = unboxed(fn -> lifecycle_fixture() end)
      on_exit(fn -> unboxed(fn -> cleanup_fixture(fixture) end) end)

      toggle =
        unboxed(fn ->
          stop1 = stop_fixture(fixture.organization.id, fixture.version.id, stop_id: "PATH_STOP1")
          stop2 = stop_fixture(fixture.organization.id, fixture.version.id, stop_id: "PATH_STOP2")

          level_fixture(fixture.organization.id, fixture.version.id, level_id: "PATH_LEVEL1")

          pathway_fixture(
            fixture.organization.id,
            fixture.version.id,
            stop1.id,
            stop2.id,
            pathway_id: "PATH1"
          )

          route = route_fixture(fixture.organization.id, fixture.version.id, route_id: "R_PATH")
          trip_fixture(fixture.organization.id, fixture.version.id, "R_PATH", trip_id: "T_PATH")
          route
        end)

      before_files =
        zip_files!(
          unboxed(fn ->
            {:ok, zip, []} =
              Export.build_zip(fixture.organization.id, fixture.version.id, :pathways)

            zip
          end)
        )

      assert {:ok, _} =
               unboxed(fn ->
                 Gtfs.set_route_active("R_PATH", false, Routes.source(toggle), fixture.audit)
               end)

      after_files =
        zip_files!(
          unboxed(fn ->
            {:ok, zip, []} =
              Export.build_zip(fixture.organization.id, fixture.version.id, :pathways)

            zip
          end)
        )

      for {filename, column_name} <- [
            {"stops.txt", "stop_id"},
            {"levels.txt", "level_id"},
            {"pathways.txt", "pathway_id"}
          ] do
        assert column(csv_rows(before_files[filename]), column_name) ==
                 column(csv_rows(after_files[filename]), column_name)
      end

      assert column(csv_rows(after_files["pathways.txt"]), "pathway_id") == ["PATH1"]
      refute Map.has_key?(after_files, "routes.txt")
      refute Map.has_key?(after_files, "trips.txt")
    end

    test "completed archives keep their bytes across lifecycle changes and reactivation restores output" do
      fixture = unboxed(fn -> lifecycle_fixture() end)
      on_exit(fn -> unboxed(fn -> cleanup_fixture(fixture) end) end)

      toggle =
        unboxed(fn -> seed_toggle_pair!(fixture.organization.id, fixture.version.id, true) end)

      run =
        unboxed(fn ->
          {:ok, run} =
            ExportRuns.create_pending(
              fixture.organization.id,
              fixture.version.id,
              @actor,
              :full
            )

          {:ok, claimed, generation, token} =
            ExportRuns.claim(fixture.organization.id, run.id, :build)

          assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))
          run
        end)

      claim =
        unboxed(fn ->
          {:ok, claim} =
            ExportRuns.claim_download(fixture.organization.id, fixture.version.id, run.id)

          claim
        end)

      completed_bytes = File.read!(claim.path)

      assert %Run{artifact_sha256: sha_before, artifact_size_bytes: size_before} =
               unboxed(fn -> Repo.get!(Run, run.id) end)

      assert is_binary(sha_before)

      assert {:ok, %{route: _}} =
               unboxed(fn ->
                 Gtfs.set_route_active("R_TOGGLE", false, Routes.source(toggle), fixture.audit)
               end)

      # The completed archive is never rewritten: the served bytes and durable
      # artifact metadata are byte-identical after the lifecycle change (R6,
      # AC-12), while a later snapshot observes the change completely.
      assert File.read!(claim.path) == completed_bytes

      assert %Run{artifact_sha256: ^sha_before, artifact_size_bytes: ^size_before} =
               unboxed(fn -> Repo.get!(Run, run.id) end)

      post_zip =
        unboxed(fn ->
          {:ok, zip, []} =
            Export.build_zip(fixture.organization.id, fixture.version.id, :full)

          zip
        end)

      post_files = zip_files!(post_zip)
      assert column(csv_rows(post_files["routes.txt"]), "route_id") == ["R_KEEP"]
      assert column(csv_rows(post_files["trips.txt"]), "trip_id") == ["T_KEEP"]

      assert {:ok, %{route: _}} =
               unboxed(fn ->
                 Gtfs.set_route_active(
                   "R_TOGGLE",
                   true,
                   fresh_source(fixture, "R_TOGGLE"),
                   fixture.audit
                 )
               end)

      restored_files =
        zip_files!(
          unboxed(fn ->
            {:ok, zip, []} =
              Export.build_zip(fixture.organization.id, fixture.version.id, :full)

            zip
          end)
        )

      assert column(csv_rows(restored_files["routes.txt"]), "route_id") == ["R_KEEP", "R_TOGGLE"]
      assert column(csv_rows(restored_files["trips.txt"]), "trip_id") == ["T_KEEP", "T_TOGGLE"]
    end
  end

  # -- fixtures ----------------------------------------------------------------

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp lifecycle_fixture do
    stamp = System.system_time(:nanosecond)

    organization = organization_fixture(%{alias: "route16-export-#{stamp}"})
    version = gtfs_version_fixture(organization.id)

    actor =
      user_fixture(%{email: "route16-export-#{stamp}@example.com"})

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: actor.id,
        organization_id: organization.id,
        roles: [
          "pathways_studio_editor"
        ]
      })

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      actor_id: actor.id,
      actor_email: actor.email
    }

    %{organization: organization, version: version, actor: actor, audit: audit}
  end

  defp seed_toggle_pair!(org_id, version_id, toggle_active) do
    route_fixture(org_id, version_id, route_id: "R_KEEP", active: true)
    toggle = route_fixture(org_id, version_id, route_id: "R_TOGGLE", active: toggle_active)
    trip_fixture(org_id, version_id, "R_KEEP", trip_id: "T_KEEP", service_id: "SVC1")
    trip_fixture(org_id, version_id, "R_TOGGLE", trip_id: "T_TOGGLE", service_id: "SVC1")
    toggle
  end

  # One complete inactive route closure plus eligible, NULL-active, dangling and
  # shared rows, with expected row sets taken from R6's examples (step 14's
  # proven output orderings).
  defp seed_r6_closure!(org_id, version_id) do
    agency_fixture(org_id, version_id, agency_id: "AGENCY1")
    stop_fixture(org_id, version_id, stop_id: "STOP1")
    stop_fixture(org_id, version_id, stop_id: "STOP2")

    route_fixture(org_id, version_id, route_id: "R_ACTIVE", active: true)
    route_fixture(org_id, version_id, route_id: "R_NULL", active: nil)
    route_fixture(org_id, version_id, route_id: "R_INACTIVE", active: false)

    trip_fixture(org_id, version_id, "R_ACTIVE", trip_id: "T_ACTIVE", service_id: "SVC1")
    trip_fixture(org_id, version_id, "R_NULL", trip_id: "T_NULL", service_id: "SVC1")
    trip_fixture(org_id, version_id, "R_INACTIVE", trip_id: "T_INACTIVE", service_id: "SVC1")
    trip_fixture(org_id, version_id, "MISSING_ROUTE", trip_id: "T_DANGLING", service_id: "SVC1")

    stop_time_fixture(org_id, version_id, "T_ACTIVE", "STOP1", stop_sequence: 1)
    stop_time_fixture(org_id, version_id, "T_INACTIVE", "STOP1", stop_sequence: 1)

    frequency_fixture(org_id, version_id, "T_ACTIVE",
      start_time: "06:00:00",
      end_time: "07:00:00"
    )

    frequency_fixture(org_id, version_id, "T_INACTIVE",
      start_time: "06:00:00",
      end_time: "07:00:00"
    )

    route_pattern_fixture(org_id, version_id, %{
      route_pattern_id: "P_ACTIVE",
      route_id: "R_ACTIVE"
    })

    route_pattern_fixture(org_id, version_id, %{
      route_pattern_id: "P_INACTIVE",
      route_id: "R_INACTIVE"
    })

    transfer_fixture(org_id, version_id, %{
      from_stop_id: "STOP1",
      to_stop_id: "STOP2",
      from_route_id: "R_ACTIVE"
    })

    transfer_fixture(org_id, version_id, %{
      from_stop_id: "STOP1",
      to_stop_id: "STOP2",
      from_route_id: "R_INACTIVE"
    })

    transfer_fixture(org_id, version_id, %{
      from_stop_id: "STOP1",
      to_stop_id: "STOP2",
      from_trip_id: "T_INACTIVE"
    })

    fare_rule_fixture(org_id, version_id, fare_id: "FARE1", route_id: "R_ACTIVE")
    fare_rule_fixture(org_id, version_id, fare_id: "FARE1", route_id: "R_INACTIVE")

    attribution_fixture(org_id, version_id, attribution_id: "AT_ACTIVE", route_id: "R_ACTIVE")

    attribution_fixture(org_id, version_id,
      attribution_id: "AT_TRIP_INACTIVE",
      trip_id: "T_INACTIVE"
    )
  end

  defp fare_rule_fixture(org_id, version_id, attrs) do
    %FareRule{}
    |> FareRule.changeset(
      Map.merge(
        %{organization_id: org_id, gtfs_version_id: version_id},
        Map.new(attrs)
      )
    )
    |> Repo.insert!()
  end

  defp attribution_fixture(org_id, version_id, attrs) do
    %Attribution{}
    |> Attribution.changeset(
      Map.merge(
        %{
          organization_name: "Fixture Attribution",
          organization_id: org_id,
          gtfs_version_id: version_id
        },
        Map.new(attrs)
      )
    )
    |> Repo.insert!()
  end

  defp reload_active(fixture, route_id) do
    Repo.one!(
      from r in Route,
        where: r.organization_id == ^fixture.organization.id and r.route_id == ^route_id,
        select: r.active
    )
  end

  # A real change requires the exact saved revision, so Undo/reactivation takes
  # a fresh source from the reloaded row (the step 9 source contract).
  defp fresh_source(fixture, route_id) do
    Routes.source(
      Repo.one!(
        from r in Route,
          where: r.organization_id == ^fixture.organization.id and r.route_id == ^route_id
      )
    )
  end

  defp cleanup_fixture(fixture) do
    org_id = fixture.organization.id

    trip_ids =
      Repo.all(from t in Trip, where: t.organization_id == ^org_id, select: t.trip_id)

    pattern_ids =
      Repo.all(from p in RoutePattern, where: p.organization_id == ^org_id, select: p.id)

    Repo.delete_all(from s in StopTime, where: s.trip_id in ^trip_ids)
    Repo.delete_all(from f in Frequency, where: f.trip_id in ^trip_ids)
    Repo.delete_all(from t in Trip, where: t.trip_id in ^trip_ids)
    Repo.delete_all(from o in RoutePatternStop, where: o.organization_id == ^org_id)
    Repo.delete_all(from p in RoutePattern, where: p.id in ^pattern_ids)
    Repo.delete_all(from t in Transfer, where: t.organization_id == ^org_id)
    Repo.delete_all(from f in FareRule, where: f.organization_id == ^org_id)
    Repo.delete_all(from a in Attribution, where: a.organization_id == ^org_id)
    Repo.delete_all(from r in Route, where: r.organization_id == ^org_id)
    Repo.delete_all(from s in Stop, where: s.organization_id == ^org_id)
    Repo.delete_all(from l in Level, where: l.organization_id == ^org_id)
    Repo.delete_all(from p in Pathway, where: p.organization_id == ^org_id)
    Repo.delete_all(from a in Agency, where: a.organization_id == ^org_id)
    Repo.delete_all(from l in ChangeLog, where: l.organization_id == ^org_id)
    Repo.delete_all(from r in Run, where: r.organization_id == ^org_id)

    Repo.delete_all(
      from m in UserOrgMembership,
        where: m.organization_id == ^org_id or m.user_id == ^fixture.actor.id
    )

    delete_versions!(from v in GtfsVersion, where: v.organization_id == ^org_id)
    Repo.delete_all(from o in Organization, where: o.id == ^org_id)
    Repo.delete_all(from u in User, where: u.id == ^fixture.actor.id)
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:gtfs_planner, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:gtfs_planner, key)

  # -- R6 row-set oracle ---------------------------------------------------------

  # Independent expected row sets from R6: explicit-false routes and their
  # dependent service references are excluded whole; true/NULL-active, dangling
  # and shared rows survive. Output orderings follow the established schema keys.
  defp assert_r6_rows!(files) do
    assert column(csv_rows(files["routes.txt"]), "route_id") == ["R_ACTIVE", "R_NULL"]

    trips_rows = csv_rows(files["trips.txt"])
    assert column(trips_rows, "trip_id") == ["T_DANGLING", "T_ACTIVE", "T_NULL"]

    assert MapSet.new(column(csv_rows(files["stop_times.txt"]), "trip_id")) ==
             MapSet.new(["T_ACTIVE"])

    assert column(csv_rows(files["frequencies.txt"]), "trip_id") == ["T_ACTIVE"]
    assert column(csv_rows(files["route_patterns.txt"]), "route_pattern_id") == ["P_ACTIVE"]

    transfers = csv_rows(files["transfers.txt"])
    assert length(transfers) == 1
    assert column(transfers, "from_route_id") == ["R_ACTIVE"]
    assert column(transfers, "from_trip_id") == [""]

    assert column(csv_rows(files["fare_rules.txt"]), "route_id") == ["R_ACTIVE"]
    assert column(csv_rows(files["attributions.txt"]), "attribution_id") == ["AT_ACTIVE"]

    assert column(csv_rows(files["agency.txt"]), "agency_id") == ["AGENCY1"]
    assert column(csv_rows(files["stops.txt"]), "stop_id") == ["STOP1", "STOP2"]
  end

  # -- export_test.exs barrier setup (reused) ------------------------------------

  # The first `trips` query of the export is the selection existence check,
  # inside the read snapshot but before any file rows are streamed. Pausing
  # there lets a real writer commit a status change while the snapshot is open.
  defp attach_trips_barrier(handler_id, parent, exporter_pid) do
    :telemetry.attach(
      handler_id,
      [:gtfs_planner, :repo, :query],
      fn _event, _measurements, metadata, {owner, exporter} ->
        if self() == exporter and metadata[:source] == "trips" do
          :telemetry.detach(handler_id)
          send(owner, {:export_paused, self()})

          receive do
            :resume_export -> :ok
          after
            30_000 -> :ok
          end
        end
      end,
      {parent, exporter_pid}
    )
  end

  defp zip_files!(zip_binary) do
    {:ok, files} = :zip.unzip(zip_binary, [:memory])
    Map.new(files, fn {name, content} -> {to_string(name), content} end)
  end

  defp csv_rows(content) do
    [header | rows] = String.split(to_string(content), "\n", trim: true)
    columns = String.split(header, ",")

    Enum.map(rows, fn row ->
      columns |> Enum.zip(String.split(row, ",")) |> Map.new()
    end)
  end

  defp column(rows, name), do: Enum.map(rows, &Map.fetch!(&1, name))

  defp export_temp_dirs do
    Path.wildcard(Path.join(System.tmp_dir!(), "gtfs_export_*"))
  end

  defp assert_no_export_temp_dir_leak(before, attempts \\ 20) do
    leaked = export_temp_dirs() -- before

    cond do
      leaked == [] ->
        :ok

      attempts == 0 ->
        flunk("temporary export directories were left behind: #{inspect(leaked)}")

      true ->
        Process.sleep(50)
        assert_no_export_temp_dir_leak(before, attempts - 1)
    end
  end
end
