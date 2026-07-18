defmodule GtfsPlanner.Gtfs.Import.PublicationTest do
  @moduledoc """
  Publication orchestration: exact-target import, publishability gate, closure
  exclusively through ImportRuns, failure seams, races, and structured telemetry.

  Exercises the real Repo and filesystem boundaries. Failure seams are narrow and
  controllable: a real PostgreSQL publication constraint for the DB
  publication-failure case, an isolated unwritable uploads root for the
  filesystem case, and crafted input/result shapes for the import/extension/
  archive cases.

  Each test seeds a claimed run via `ImportRuns.create_pending_target/3` +
  `ImportRuns.claim_import/3` and passes the claimed `%Run{}` + lease token to
  `Publication.run/4`.
  """

  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlanner.Gtfs.Import.Publication
  alias GtfsPlanner.Gtfs.Import.Runner
  alias GtfsPlanner.Gtfs.Import.Run
  alias GtfsPlanner.Gtfs.Import.Failure
  alias GtfsPlanner.Gtfs.ImportRuns
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  import GtfsPlanner.OrganizationsFixtures

  @telemetry_event [:gtfs_planner, :import_publication, :transition]

  @levels_content "level_id,level_index,level_name\nL1,0.0,Ground Floor\n"
  @stops_content "stop_id,stop_name,stop_lat,stop_lon,level_id,location_type,wheelchair_boarding\nS1,Main,40.7,-74.0,L1,1,1\n"

  defp actor do
    %{id: Ecto.UUID.generate(), email: "importer@example.com"}
  end

  defp seed_claimed_run(organization, name) do
    {:ok, %{run: run, version: _version}} =
      ImportRuns.create_pending_target(organization.id, actor(), %{name: name})

    {:ok, claimed_run, _version, token} =
      ImportRuns.claim_import(organization.id, run.id, run.lease_token)

    {claimed_run, token}
  end

  describe "run/4 success" do
    setup do
      organization = organization_fixture()
      {run, token} = seed_claimed_run(organization, "New Feed")
      # A prior published version whose rows/files must remain untouched.
      {:ok, prior} = Versions.create_gtfs_version(organization.id, %{name: "Prior"})

      Import.import_files(organization.id, prior.id, [
        %{filename: "levels.txt", content: @levels_content}
      ])

      %{organization: organization, run: run, token: token, prior: prior}
    end

    test "imports only the claimed target, publishes it, and persists coupled run/version state",
         %{
           organization: organization,
           run: run,
           token: token,
           prior: prior
         } do
      files = [
        %{filename: "levels.txt", content: @levels_content},
        %{filename: "stops.txt", content: @stops_content}
      ]

      assert {:ok, published, result} = Publication.run(run, token, files, "import:test")

      assert published.id == run.gtfs_version_id
      assert published.publication_status == "published"
      assert not is_nil(published.published_at)
      assert result.extensions == :not_present
      assert Import.Result.publishable?(result)

      # The claimed target is now externally readable.
      assert %GtfsVersion{} =
               Versions.get_published_gtfs_version_for_org(
                 organization.id,
                 run.gtfs_version_id
               )

      # Prior version rows are untouched (organization fixture also seeds a
      # "First Version", so there are three published versions now).
      assert length(Versions.list_published_gtfs_versions(organization.id)) == 3
      prior_levels = GtfsPlanner.Gtfs.list_levels(organization.id, prior.id)
      assert length(prior_levels) == 1
      # Target received exactly its own writes.
      target_levels = GtfsPlanner.Gtfs.list_levels(organization.id, run.gtfs_version_id)
      assert length(target_levels) == 1
      target_stops = GtfsPlanner.Gtfs.list_stops(organization.id, run.gtfs_version_id)
      assert length(target_stops) == 1

      # The run is coupled to published with complete counts.
      persisted_run =
        from(r in Run, where: r.id == ^run.id, select: r)
        |> Repo.one!()

      assert persisted_run.state == "published"
      assert persisted_run.counts_complete == true
      assert not is_nil(persisted_run.finished_at)
    end

    test "preserves prior-version rows/files throughout and writes only the claimed version", %{
      organization: organization,
      run: run,
      token: token,
      prior: prior
    } do
      uploads = Application.fetch_env!(:gtfs_planner, :uploads_path)

      prior_file =
        Path.join([uploads, "diagrams", organization.id, prior.id, "station", "prior.png"])

      File.mkdir_p!(Path.dirname(prior_file))
      File.write!(prior_file, "prior-bytes")

      files = [%{filename: "levels.txt", content: @levels_content}]

      assert {:ok, _, _} = Publication.run(run, token, files, "import:test")

      # Prior file bytes are byte-identical.
      assert File.read!(prior_file) == "prior-bytes"

      # Prior remains published and queryable.
      assert %GtfsVersion{} =
               Versions.get_published_gtfs_version_for_org(organization.id, prior.id)
    end
  end

  describe "lease loss during closure" do
    setup do
      organization = organization_fixture()
      {run, token} = seed_claimed_run(organization, "Staged")
      %{organization: organization, run: run, token: token}
    end

    test "a wrong lease token yields a non-publishable closure error with no publish", %{
      organization: organization,
      run: run
    } do
      wrong_token = Ecto.UUID.generate()
      files = [%{filename: "levels.txt", content: @levels_content}]

      assert {:error, _version, :lease_lost} =
               Publication.run(run, wrong_token, files, "import:lose")

      # The closure never published: the version stays importing and the run
      # stays running (no insert retry, no second import call).
      final =
        from(v in GtfsVersion,
          where: v.id == ^run.gtfs_version_id,
          select: v.publication_status
        )
        |> Repo.one!()

      assert final == "importing"

      persisted_run =
        from(r in Run, where: r.id == ^run.id, select: r.state)
        |> Repo.one!()

      assert persisted_run == "running"
    end

    test "two concurrent run calls on the same claimed run produce exactly one publisher", %{
      organization: organization,
      run: run,
      token: token
    } do
      parent = self()

      files = [%{filename: "levels.txt", content: @levels_content}]

      task_fn = fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
        Publication.run(run, token, files, "import:race")
      end

      t1 = Task.async(task_fn)
      t2 = Task.async(task_fn)

      results = Task.await_many([t1, t2], 10_000)

      winners = Enum.filter(results, &match?({:ok, _, _}, &1))
      assert length(winners) == 1

      losers = Enum.filter(results, &match?({:error, _, :lease_lost}, &1))
      assert length(losers) == 1

      final =
        from(v in GtfsVersion,
          where: v.id == ^run.gtfs_version_id,
          select: v.publication_status
        )
        |> Repo.one!()

      assert final == "published"

      # Exactly one level row was written (only the winner imported).
      assert length(GtfsPlanner.Gtfs.list_levels(organization.id, run.gtfs_version_id)) == 1
    end
  end

  describe "import and publishability failures close through ImportRuns.fail_import and never publish" do
    setup do
      organization = organization_fixture()
      {run, token} = seed_claimed_run(organization, "Staged")
      %{organization: organization, run: run, token: token}
    end

    test "an import error fails the exact target and never publishes", %{
      organization: organization,
      run: run,
      token: token
    } do
      files = [
        %{filename: "levels.txt", content: "level_id,level_index\nL1,0.0\nL1,0.0"},
        %{filename: "stops.txt", content: @stops_content}
      ]

      assert {:error, target, %Failure{} = failure} =
               Publication.run(run, token, files, "import:fail")

      assert target.id == run.gtfs_version_id
      assert failure.outcome == :failed

      assert %GtfsVersion{} =
               failed =
               Versions.get_gtfs_version_for_lifecycle(organization.id, run.gtfs_version_id)

      assert failed.publication_status == "failed"
      assert is_nil(failed.published_at)
      refute Versions.published_gtfs_version_for_org?(organization.id, run.gtfs_version_id)

      persisted_run =
        from(r in Run, where: r.id == ^run.id, select: r)
        |> Repo.one!()

      assert persisted_run.state == "failed"
    end

    test "a non-publishable result (archive warning) fails the target", %{
      organization: organization,
      run: run,
      token: token
    } do
      files = [%{filename: "bad.zip", content: "not a real zip"}]

      assert {:error, target, %Failure{} = failure} =
               Publication.run(run, token, files, "import:warn")

      assert failure.phase == :phase_2
      assert failure.outcome == :failed

      assert target.id == run.gtfs_version_id

      assert %GtfsVersion{} =
               failed =
               Versions.get_gtfs_version_for_lifecycle(organization.id, run.gtfs_version_id)

      assert failed.publication_status == "failed"
      refute Versions.published_gtfs_version_for_org?(organization.id, run.gtfs_version_id)
    end

    test "an extension image-write failure fails the target", %{
      organization: organization,
      run: run,
      token: token
    } do
      # Own an isolated uploads root so the write failure is controllable.
      previous = Application.get_env(:gtfs_planner, :uploads_path)

      unwritable =
        Path.join(System.tmp_dir!(), "unwritable_#{System.unique_integer([:positive])}")

      File.mkdir_p!(unwritable)
      File.chmod!(unwritable, 0o000)
      Application.put_env(:gtfs_planner, :uploads_path, unwritable)

      on_exit(fn ->
        File.chmod!(unwritable, 0o700)
        File.rm_rf!(unwritable)

        if is_nil(previous) do
          Application.delete_env(:gtfs_planner, :uploads_path)
        else
          Application.put_env(:gtfs_planner, :uploads_path, previous)
        end
      end)

      manifest =
        Jason.encode!(%{
          "version" => 1,
          "exported_at" => "2026-02-25T00:00:00Z",
          "stop_diagram_coordinates" => [],
          "stop_levels" => [
            %{
              "stop_id" => "32095",
              "level_id" => "32095_BUSWAY",
              "diagram_filename" => "lvl.png",
              "scale_point_a" => %{"x" => 10.0, "y" => 20.0},
              "scale_point_b" => %{"x" => 20.0, "y" => 20.0},
              "scale_distance_meters" => "3.0",
              "scale_meters_per_unit" => "0.3"
            }
          ],
          "route_active_flags" => [],
          "diagram_images" => [
            %{
              "station_stop_id" => "32095",
              "filename" => "lvl.png",
              "zip_path" => "_pathways_extensions/diagrams/32095/lvl.png"
            }
          ]
        })

      levels = "level_id,level_index,level_name\n32095_BUSWAY,0.0,Busway"
      stops = "stop_id,stop_name,stop_lat,stop_lon,location_type\n32095,Olney,40.0,-75.0,1"

      {:ok, {_name, zip}} =
        :zip.create(
          ~c"gtfs.zip",
          [
            {~c"levels.txt", levels},
            {~c"stops.txt", stops},
            {~c"_pathways_extensions.json", manifest},
            {~c"_pathways_extensions/diagrams/32095/lvl.png", "fake png"}
          ],
          [:memory]
        )

      files = [%{filename: "gtfs.zip", content: zip}]

      assert {:error, target, %Failure{} = failure} =
               Publication.run(run, token, files, "import:img")

      assert target.id == run.gtfs_version_id
      assert failure.failed_file == nil

      assert %GtfsVersion{} =
               failed =
               Versions.get_gtfs_version_for_lifecycle(organization.id, run.gtfs_version_id)

      assert failed.publication_status == "failed"
      refute Versions.published_gtfs_version_for_org?(organization.id, run.gtfs_version_id)
    end
  end

  describe "late Phase 2 failure after committed batches closes through fail_import (AC-1)" do
    setup do
      organization = organization_fixture()
      {run, token} = seed_claimed_run(organization, "New Feed")

      # A prior published version whose rows must remain untouched by the failed run.
      {:ok, prior} = Versions.create_gtfs_version(organization.id, %{name: "Prior"})

      Import.import_files(organization.id, prior.id, [
        %{filename: "levels.txt", content: @levels_content}
      ])

      %{organization: organization, run: run, token: token, prior: prior}
    end

    test "a semantic error after two committed batches quarantines partial rows and names the source row",
         %{organization: organization, run: run, token: token} do
      # @batch_size is compile-time 1000 with no test override, so generate more
      # than two batch sizes of valid rows followed by one malformed row. The
      # malformed row's chunk is rejected before insertion, so only the two full
      # committed batches persist.
      valid_row_count = 2100

      valid_rows =
        Enum.map_join(1..valid_row_count, "", fn n ->
          "T1,S#{n},#{n},08:00:00,08:00:00\n"
        end)

      stop_times =
        "trip_id,stop_id,stop_sequence,arrival_time,departure_time\n" <>
          valid_rows <>
          "T1,SBAD,not_a_number,08:00:00,08:00:00\n"

      total_data_rows = valid_row_count + 1
      # Header is physical row 1; data rows begin at physical row 2, so the bad
      # record (data row 2101) sits at physical row 2102.
      bad_physical_row = total_data_rows + 1

      files = [
        %{filename: "levels.txt", content: @levels_content},
        %{filename: "stops.txt", content: @stops_content},
        %{filename: "stop_times.txt", content: stop_times}
      ]

      assert {:error, target, %Failure{} = failure} =
               Publication.run(run, token, files, "import:phase2-late")

      assert target.id == run.gtfs_version_id

      # The failure names the source file and the exact physical source row of the
      # bad record (AC-4), not an inserted-row offset. Failure uses
      # `failed_file`/`failed_row`.
      assert failure.failed_file == "stop_times.txt"
      assert failure.failed_row == bad_physical_row

      # At least two committed batches persisted, scoped to the claimed target,
      # and strictly fewer than the total (the error chunk never inserts).
      persisted =
        from(st in GtfsPlanner.Gtfs.StopTime, where: st.gtfs_version_id == ^run.gtfs_version_id)
        |> Repo.aggregate(:count)

      assert persisted >= 2 * 1000
      assert persisted <= 2 * 1000
      assert persisted < total_data_rows

      # The incomplete target is never published (AC-14, INV-3).
      assert %GtfsVersion{} =
               failed =
               Versions.get_gtfs_version_for_lifecycle(organization.id, run.gtfs_version_id)

      assert failed.publication_status == "failed"
      assert is_nil(failed.published_at)
      refute Versions.published_gtfs_version_for_org?(organization.id, run.gtfs_version_id)

      # The run closed through ImportRuns.fail_import as partial with exact
      # committed counts (the ~2000 committed stop_times).
      persisted_run =
        from(r in Run, where: r.id == ^run.id, select: r)
        |> Repo.one!()

      assert persisted_run.state == "partial"
      assert persisted_run.counts_complete == true
      assert persisted_run.committed_counts["stop_times"] == persisted
    end

    test "the prior published version and its records remain unchanged after the failed run",
         %{organization: organization, run: run, token: token, prior: prior} do
      valid_rows =
        Enum.map_join(1..2100, "", fn n -> "T1,S#{n},#{n},08:00:00,08:00:00\n" end)

      stop_times =
        "trip_id,stop_id,stop_sequence,arrival_time,departure_time\n" <>
          valid_rows <>
          "T1,SBAD,not_a_number,08:00:00,08:00:00\n"

      files = [
        %{filename: "levels.txt", content: @levels_content},
        %{filename: "stops.txt", content: @stops_content},
        %{filename: "stop_times.txt", content: stop_times}
      ]

      assert {:error, _target, %Failure{}} =
               Publication.run(run, token, files, "import:phase2-prior")

      # Published-only lookup still returns the prior version.
      assert %GtfsVersion{} =
               Versions.get_published_gtfs_version_for_org(organization.id, prior.id)

      # Its records are untouched.
      assert length(GtfsPlanner.Gtfs.list_levels(organization.id, prior.id)) == 1
      assert GtfsPlanner.Gtfs.list_stops(organization.id, prior.id) == []
    end
  end

  describe "database publication failure after asset writes (AC-9)" do
    setup do
      organization = organization_fixture()
      {run, token} = seed_claimed_run(organization, "Staged")
      %{organization: organization, run: run, token: token}
    end

    @tag :publication_failure
    test "records publication_failed and leaves target importing + externally unavailable", %{
      organization: organization,
      run: run,
      token: token
    } do
      # Install a real, transaction-local CHECK constraint that forbids
      # published_at being set during this test, forcing the importing ->
      # published transition to fail at the database boundary (not a fake
      # internal Versions module). Constraint is dropped on exit.
      constraint_sql = """
      ALTER TABLE gtfs_versions
      ADD CONSTRAINT publication_proof_no_published_at
      CHECK (publication_status <> 'published' OR published_at IS NULL) NOT VALID
      """

      drop_sql = """
      ALTER TABLE gtfs_versions
      DROP CONSTRAINT IF EXISTS publication_proof_no_published_at
      """

      {:ok, _} = Repo.query(constraint_sql)

      on_exit(fn ->
        Repo.query(drop_sql)
      end)

      files = [%{filename: "levels.txt", content: @levels_content}]

      assert {:error, target, {:publication_failed, _reason}} =
               Publication.run(run, token, files, "import:dbfail")

      assert target.id == run.gtfs_version_id

      # Asset writes completed: the level row exists under the claimed version.
      assert length(GtfsPlanner.Gtfs.list_levels(organization.id, run.gtfs_version_id)) == 1

      # The run is recorded as publication_failed by ImportRuns.
      persisted_run =
        from(r in Run, where: r.id == ^run.id, select: r)
        |> Repo.one!()

      assert persisted_run.state == "publication_failed"
      assert persisted_run.counts_complete == true

      # Target version stays importing for later reconciliation.
      final =
        from(v in GtfsVersion,
          where: v.id == ^run.gtfs_version_id,
          select: v.publication_status
        )
        |> Repo.one!()

      assert final == "importing"

      # Externally unavailable.
      refute Versions.published_gtfs_version_for_org?(organization.id, run.gtfs_version_id)
    end

    @tag :publication_failure
    test "retry_publication publishes without a second Import.import_files call", %{
      organization: organization,
      run: run,
      token: token
    } do
      constraint_sql = """
      ALTER TABLE gtfs_versions
      ADD CONSTRAINT publication_proof_no_published_at
      CHECK (publication_status <> 'published' OR published_at IS NULL) NOT VALID
      """

      drop_sql = """
      ALTER TABLE gtfs_versions
      DROP CONSTRAINT IF EXISTS publication_proof_no_published_at
      """

      {:ok, _} = Repo.query(constraint_sql)

      on_exit(fn ->
        Repo.query(drop_sql)
      end)

      files = [%{filename: "levels.txt", content: @levels_content}]

      assert {:error, _target, {:publication_failed, _}} =
               Publication.run(run, token, files, "import:dbfail-retry")

      # Drop the constraint so the guarded retry can publish.
      {:ok, _} = Repo.query(drop_sql)

      assert {:ok, retried_run, retried_version} =
               ImportRuns.retry_publication(organization.id, run.id)

      assert retried_run.state == "published"
      assert retried_version.publication_status == "published"
      assert not is_nil(retried_version.published_at)

      # Exactly one level row was written (no second import call occurred).
      assert length(GtfsPlanner.Gtfs.list_levels(organization.id, run.gtfs_version_id)) == 1
    end
  end

  describe "no fallback under stale route context" do
    setup do
      organization = organization_fixture()
      {run, token} = seed_claimed_run(organization, "Staged")
      {:ok, current} = Versions.create_gtfs_version(organization.id, %{name: "Current"})
      %{organization: organization, run: run, token: token, current: current}
    end

    test "publication uses only the claimed run's target, never the route/current version", %{
      organization: organization,
      run: run,
      token: token,
      current: current
    } do
      files = [%{filename: "levels.txt", content: @levels_content}]

      assert {:ok, published, _result} = Publication.run(run, token, files, "import:exact")
      assert published.id == run.gtfs_version_id

      # The current (route) version received no writes.
      assert GtfsPlanner.Gtfs.list_levels(organization.id, current.id) == []
      # And it remains published and untouched.
      assert %GtfsVersion{} =
               Versions.get_published_gtfs_version_for_org(organization.id, current.id)
    end
  end

  describe "telemetry" do
    setup do
      organization = organization_fixture()
      {run, token} = seed_claimed_run(organization, "Staged")
      %{organization: organization, run: run, token: token}
    end

    test "emits scoped transition telemetry with org, target, prior/new state, failure class", %{
      organization: organization,
      run: run,
      token: token
    } do
      handler_id = make_ref()
      test_pid = self()

      :telemetry.attach(
        handler_id,
        @telemetry_event,
        fn event, _measurements, meta, _config ->
          send(test_pid, {:telemetry, event, meta})
        end,
        %{}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      files = [%{filename: "levels.txt", content: @levels_content}]
      {:ok, _published, _result} = Publication.run(run, token, files, "import:tele")

      published_event =
        receive_telemetry(fn {_ev, meta} ->
          meta.version_id == run.gtfs_version_id and meta.new_state == "published"
        end)

      assert {_event, meta} = published_event
      assert meta.organization_id == organization.id
      assert meta.version_id == run.gtfs_version_id
      assert meta.prior_state == "importing"
      assert meta.new_state == "published"
      # Failure class is present and nil for a successful transition.
      assert Map.has_key?(meta, :failure_class)
      assert is_nil(meta.failure_class)
      # No uploaded content may surface in telemetry metadata.
      refute Map.has_key?(meta, :content)
      refute Map.has_key?(meta, :file)
    end

    test "emits publication-error telemetry on database publication failure", %{
      organization: organization,
      run: run,
      token: token
    } do
      constraint_sql = """
      ALTER TABLE gtfs_versions
      ADD CONSTRAINT publication_proof_no_published_at
      CHECK (publication_status <> 'published' OR published_at IS NULL) NOT VALID
      """

      drop_sql = """
      ALTER TABLE gtfs_versions
      DROP CONSTRAINT IF EXISTS publication_proof_no_published_at
      """

      {:ok, _} = Repo.query(constraint_sql)

      on_exit(fn ->
        Repo.query(drop_sql)
      end)

      handler_id = make_ref()
      test_pid = self()

      :telemetry.attach(
        handler_id,
        @telemetry_event,
        fn event, _measurements, meta, _config ->
          send(test_pid, {:telemetry, event, meta})
        end,
        %{}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      files = [%{filename: "levels.txt", content: @levels_content}]

      {:error, _target, {:publication_failed, _}} =
        Publication.run(run, token, files, "import:telefail")

      error_event =
        receive_telemetry(fn {_ev, meta} ->
          meta.version_id == run.gtfs_version_id and not is_nil(meta.failure_class)
        end)

      assert {_event, meta} = error_event
      assert meta.organization_id == organization.id
      assert meta.version_id == run.gtfs_version_id
      assert meta.failure_class == :publication_failed
      assert meta.prior_state == "importing"
      assert meta.new_state == "importing"
    end

    test "a lost lease reports the non-publishable closure error", %{
      organization: organization,
      run: run
    } do
      wrong_token = Ecto.UUID.generate()

      handler_id = make_ref()
      test_pid = self()

      :telemetry.attach(
        handler_id,
        @telemetry_event,
        fn event, _measurements, meta, _config ->
          send(test_pid, {:telemetry, event, meta})
        end,
        %{}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:error, _target, :lease_lost} =
               Publication.run(run, wrong_token, [], "import:lease-telemetry")

      assert {_event, meta} =
               receive_telemetry(fn {_event, meta} ->
                 meta.version_id == run.gtfs_version_id and
                   meta.failure_class == :lease_lost
               end)

      assert meta.prior_state == "importing"
      assert meta.new_state == "importing"
    end
  end

  # --- end-to-end recovery boundary integration ------------------------------

  describe "end-to-end recovery boundaries (ImportLive -> Runner -> Publication/Recovery -> ImportRuns)" do
    setup do
      organization = organization_fixture()
      {run, token} = seed_claimed_run(organization, "New Feed")
      {:ok, prior} = Versions.create_gtfs_version(organization.id, %{name: "Prior"})

      Import.import_files(organization.id, prior.id, [
        %{filename: "levels.txt", content: @levels_content}
      ])

      %{organization: organization, run: run, token: token, prior: prior}
    end

    # Scenario 1 (AC-4/7): a real multi-batch import plus a separate expired
    # executor lease. The prior published version's rows and diagram files must
    # stay byte-identical, and no target becomes externally visible until
    # guarded publication.
    test "executor loss + reconcile preserves prior published rows/files (AC-4/7)",
         %{organization: organization, prior: prior} do
      uploads = Application.fetch_env!(:gtfs_planner, :uploads_path)

      prior_file =
        Path.join([uploads, "diagrams", organization.id, prior.id, "station", "prior.png"])

      File.mkdir_p!(Path.dirname(prior_file))
      prior_bytes = "prior-bytes-#{String.duplicate("x", 64)}"
      File.write!(prior_file, prior_bytes)

      # Capture the prior level row so we can prove it is untouched.
      prior_level_before =
        from(l in GtfsPlanner.Gtfs.Level,
          where: l.organization_id == ^organization.id and l.gtfs_version_id == ^prior.id
        )
        |> Repo.one!()

      # (AC-6) Drive a REAL supervised runner. It owns the durable outcome and
      # survives the initiating process. Allow the separate runner process DB
      # access (shared sandbox ownership).
      {:ok, %{run: run, version: _version}} =
        ImportRuns.create_pending_target(organization.id, actor(), %{name: "Runner Feed"})

      token = run.lease_token

      files = [
        %{filename: "levels.txt", content: @levels_content},
        %{filename: "stops.txt", content: @stops_content}
      ]

      {:ok, runner_pid} = Runner.start_import(organization.id, run.id, token, files)
      refute runner_pid == self()
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), runner_pid)

      # Wait for the runner's linked import task to finish (monitor, no sleeps).
      for pid <- Task.Supervisor.children(GtfsPlanner.TaskSupervisor) do
        Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 15_000
      end

      runner_ref = Process.monitor(runner_pid)
      assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, _reason}, 15_000

      # The runner closed the run itself: the target is published and externally
      # visible (closure without the LiveView).
      run_after = Repo.get!(Run, run.id)
      assert run_after.state == "published"
      assert Versions.published_gtfs_version_for_org?(organization.id, run.gtfs_version_id)

      # (AC-7) Simulate executor loss on a SEPARATE run: create a running target
      # with an active lease, then force the lease to an expired timestamp and
      # reconcile (no sleeps). No live process holds a connection here, so the
      # reconciliation is deterministic.
      {:ok, %{run: lost_run, version: _lost_version}} =
        ImportRuns.create_pending_target(organization.id, actor(), %{name: "Lost Executor"})

      {:ok, _, _, lost_token} =
        ImportRuns.claim_import(organization.id, lost_run.id, lost_run.lease_token)

      assert Repo.get!(Run, lost_run.id).state == "running"
      assert not is_nil(Repo.get!(Run, lost_run.id).lease_token)

      # Force the lease to a far-past timestamp (no sleeps), then reconcile.
      expired = ~U[2000-01-01 00:00:00.000000Z]

      {1, nil} =
        from(r in Run, where: r.id == ^lost_run.id, update: [set: [lease_expires_at: ^expired]])
        |> Repo.update_all([])

      reconciled = ImportRuns.reconcile_expired(organization.id)
      assert Enum.any?(reconciled, &(&1.id == lost_run.id))

      # The expired run is now interrupted with uncertain counts and the version
      # failed; it is never externally visible.
      after_lost = Repo.get!(Run, lost_run.id)
      assert after_lost.state == "interrupted"
      assert after_lost.counts_complete == false
      assert is_nil(after_lost.lease_token)

      lost_target =
        Versions.get_gtfs_version_for_lifecycle(organization.id, lost_run.gtfs_version_id)

      assert lost_target.publication_status == "failed"
      refute Versions.published_gtfs_version_for_org?(organization.id, lost_run.gtfs_version_id)

      # The prior published version's rows are byte-identical (no writes leaked).
      prior_levels_after = GtfsPlanner.Gtfs.list_levels(organization.id, prior.id)
      assert length(prior_levels_after) == 1

      prior_level_after =
        from(l in GtfsPlanner.Gtfs.Level,
          where: l.organization_id == ^organization.id and l.gtfs_version_id == ^prior.id
        )
        |> Repo.one!()

      assert prior_level_after.level_id == prior_level_before.level_id
      assert prior_level_after.level_name == prior_level_before.level_name
      assert prior_level_after.inserted_at == prior_level_before.inserted_at

      # The prior diagram file is byte-identical.
      assert File.read!(prior_file) == prior_bytes
    end

    # Scenario 3 (AC-8/9): every terminal {:import_run_changed, run_id}
    # corresponds to already-persisted state, and duplicate publication is
    # rejected after the durable winner.
    test "terminal PubSub message matches persisted state; duplicate publish is rejected (AC-8/9)",
         %{organization: organization} do
      # Fresh pending target so the runner claims it itself (like ImportLive).
      {:ok, %{run: run, version: _version}} =
        ImportRuns.create_pending_target(organization.id, actor(), %{name: "Runner Feed"})

      token = run.lease_token
      files = [%{filename: "levels.txt", content: @levels_content}]

      run_id = run.id
      topic = ImportRuns.topic(run_id)
      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, topic)

      # Drive the real runner; it broadcasts {:import_run_changed, run_id} only
      # after durable closure.
      {:ok, runner_pid} = Runner.start_import(organization.id, run_id, token, files)

      assert_receive {:import_run_changed, ^run_id}, 15_000

      # The terminal PubSub message corresponds to already-persisted state.
      persisted = Repo.get!(Run, run.id)
      assert persisted.state == "published"

      published_version =
        Versions.get_published_gtfs_version_for_org(organization.id, run.gtfs_version_id)

      assert published_version.publication_status == "published"

      Process.monitor(runner_pid)

      # Duplicate publish attempts must observe the persisted terminal state
      # rather than re-import.
      parent = self()

      publish_fn = fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
        Publication.run(Repo.get!(Run, run.id), token, files, topic)
      end

      t1 = Task.async(publish_fn)
      t2 = Task.async(publish_fn)

      results = Task.await_many([t1, t2], 10_000)

      # A re-publish after terminal publication must not duplicate rows: the run
      # is no longer `running`, so the closure returns a non-publishable error
      # (the run is already published), and exactly one level row exists.
      assert Enum.all?(results, &match?({:error, _, :lease_lost}, &1))

      assert length(GtfsPlanner.Gtfs.list_levels(organization.id, run.gtfs_version_id)) == 1

      # Exactly one publish winner persisted earlier; the target is published.
      assert Versions.published_gtfs_version_for_org?(organization.id, run.gtfs_version_id)
    end

    # Duplicate cleanup concurrency resolves to exactly one winner.
    test "concurrent cleanup claims resolve to exactly one winner (AC-11)", %{
      organization: organization
    } do
      {:ok, %{run: run, version: _version}} =
        ImportRuns.create_pending_target(organization.id, actor(), %{name: "Reuse Race"})

      {:ok, _, _, token} = ImportRuns.claim_import(organization.id, run.id, run.lease_token)
      {:ok, _, _} = ImportRuns.fail_import(organization.id, run.id, token, make_failure())

      parent = self()

      first = fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())

        ImportRuns.claim_cleanup(organization.id, run.id, %{
          id: Ecto.UUID.generate(),
          email: "a@example.com"
        })
      end

      second = fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())

        ImportRuns.claim_cleanup(organization.id, run.id, %{
          id: Ecto.UUID.generate(),
          email: "b@example.com"
        })
      end

      t1 = Task.async(first)
      t2 = Task.async(second)

      results = Task.await_many([t1, t2], 10_000)
      winners = Enum.count(results, &match?({:ok, _, _, _}, &1))
      losers = Enum.count(results, &match?({:error, :already_claimed}, &1))

      assert winners == 1
      assert losers == 1
      assert Repo.get!(Run, run.id).state == "cleaning"
    end
  end

  # --- helpers ---

  defp make_failure do
    Import.Failure.from_error(:unknown, phase: :phase_2, outcome: :failed, committed_counts: %{})
  end

  defp receive_telemetry(predicate, attempts \\ 20) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      receive do
        {:telemetry, event, meta} ->
          if predicate.({event, meta}) do
            {:halt, {event, meta}}
          else
            {:cont, nil}
          end
      after
        200 -> {:cont, nil}
      end
    end)
  end
end
