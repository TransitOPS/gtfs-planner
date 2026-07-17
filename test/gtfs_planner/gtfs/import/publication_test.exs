defmodule GtfsPlanner.Gtfs.Import.PublicationTest do
  @moduledoc """
  Publication orchestration: exact-target claim, import, publishability gate,
  conditional close, failure seams, races, and structured telemetry.

  Exercises the real Repo and filesystem boundaries. Failure seams are narrow
  and controllable: a real PostgreSQL publication constraint for the DB
  publication-failure case, an isolated unwritable uploads root for the
  filesystem case, and crafted input/result shapes for the import/extension/
  archive cases.
  """

  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlanner.Gtfs.Import.Publication
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  import GtfsPlanner.OrganizationsFixtures

  @telemetry_event [:gtfs_planner, :import_publication, :transition]

  @levels_content "level_id,level_index,level_name\nL1,0.0,Ground Floor\n"
  @stops_content "stop_id,stop_name,stop_lat,stop_lon,level_id,location_type,wheelchair_boarding\nS1,Main,40.7,-74.0,L1,1,1\n"

  describe "run/3 success" do
    setup do
      organization = organization_fixture()
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "New Feed"})
      # A prior published version whose rows/files must remain untouched.
      {:ok, prior} = Versions.create_gtfs_version(organization.id, %{name: "Prior"})

      Import.import_files(organization.id, prior.id, [
        %{filename: "levels.txt", content: @levels_content}
      ])

      %{organization: organization, staging: staging, prior: prior}
    end

    test "claims exactly the target, imports only it, and publishes it", %{
      organization: organization,
      staging: staging,
      prior: prior
    } do
      files = [
        %{filename: "levels.txt", content: @levels_content},
        %{filename: "stops.txt", content: @stops_content}
      ]

      assert {:ok, published, result} = Publication.run(staging, files, "import:test")

      assert published.id == staging.id
      assert published.publication_status == "published"
      assert not is_nil(published.published_at)
      assert result.extensions == :not_present
      assert Import.Result.publishable?(result)

      # The claimed target is now externally readable.
      assert %GtfsVersion{} =
               Versions.get_published_gtfs_version_for_org(organization.id, staging.id)

      # Prior version rows are untouched (organization fixture also seeds a
      # "First Version", so there are three published versions now).
      assert length(Versions.list_published_gtfs_versions(organization.id)) == 3
      prior_levels = GtfsPlanner.Gtfs.list_levels(organization.id, prior.id)
      assert length(prior_levels) == 1
      # Target received exactly its own writes.
      target_levels = GtfsPlanner.Gtfs.list_levels(organization.id, staging.id)
      assert length(target_levels) == 1
      target_stops = GtfsPlanner.Gtfs.list_stops(organization.id, staging.id)
      assert length(target_stops) == 1
    end

    test "preserves prior-version rows/files throughout and writes only the claimed version", %{
      organization: organization,
      staging: staging,
      prior: prior
    } do
      uploads = Application.fetch_env!(:gtfs_planner, :uploads_path)

      prior_file =
        Path.join([uploads, "diagrams", organization.id, prior.id, "station", "prior.png"])

      File.mkdir_p!(Path.dirname(prior_file))
      File.write!(prior_file, "prior-bytes")

      files = [%{filename: "levels.txt", content: @levels_content}]

      assert {:ok, _, _} = Publication.run(staging, files, "import:test")

      # Prior file bytes are byte-identical.
      assert File.read!(prior_file) == "prior-bytes"

      # Prior remains published and queryable.
      assert %GtfsVersion{} =
               Versions.get_published_gtfs_version_for_org(organization.id, prior.id)
    end
  end

  describe "losing claim before any write" do
    setup do
      organization = organization_fixture()
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staged"})
      %{organization: organization, staging: staging}
    end

    test "a losing claim returns before import and performs no writes", %{
      organization: organization,
      staging: staging
    } do
      # Pre-claim so the publication's internal claim will lose.
      {:ok, _} = Versions.claim_staging_gtfs_version(organization.id, staging.id)

      files = [%{filename: "levels.txt", content: @levels_content}]

      assert {:error, target, :invalid_status_transition} =
               Publication.run(staging, files, "import:lose")

      assert target.id == staging.id

      # Nothing was written: no levels belong to the target, still importing.
      final =
        from(v in GtfsVersion, where: v.id == ^staging.id, select: v.publication_status)
        |> Repo.one!()

      assert final == "importing"
      assert GtfsPlanner.Gtfs.list_levels(organization.id, staging.id) == []
    end

    test "two concurrent run calls for one staging target produce exactly one claim winner", %{
      organization: organization,
      staging: staging
    } do
      parent = self()

      files = [%{filename: "levels.txt", content: @levels_content}]

      task_fn = fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
        Publication.run(staging, files, "import:race")
      end

      t1 = Task.async(task_fn)
      t2 = Task.async(task_fn)

      results = Task.await_many([t1, t2], 10_000)

      winners = Enum.filter(results, &match?({:ok, _, _}, &1))
      assert length(winners) == 1

      losers = Enum.filter(results, &match?({:error, _, :invalid_status_transition}, &1))
      assert length(losers) == 1

      final =
        from(v in GtfsVersion, where: v.id == ^staging.id, select: v.publication_status)
        |> Repo.one!()

      assert final == "published"

      # Exactly one level row was written (only the winner imported).
      assert length(GtfsPlanner.Gtfs.list_levels(organization.id, staging.id)) == 1
    end
  end

  describe "import and publishability failures mark target failed and never publish" do
    setup do
      organization = organization_fixture()
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staged"})
      %{organization: organization, staging: staging}
    end

    test "an import error fails the exact target and never publishes", %{
      organization: organization,
      staging: staging
    } do
      files = [
        %{filename: "levels.txt", content: "level_id,level_index\nL1,0.0\nL1,0.0"},
        %{filename: "stops.txt", content: @stops_content}
      ]

      assert {:error, target, _reason} = Publication.run(staging, files, "import:fail")
      assert target.id == staging.id

      assert %GtfsVersion{} =
               failed = Versions.get_gtfs_version_for_lifecycle(organization.id, staging.id)

      assert failed.publication_status == "failed"
      assert is_nil(failed.published_at)
      refute Versions.published_gtfs_version_for_org?(organization.id, staging.id)
    end

    test "a non-publishable result (archive warning) fails the target", %{
      organization: organization,
      staging: staging
    } do
      files = [%{filename: "bad.zip", content: "not a real zip"}]

      assert {:error, target, {:import_not_publishable, _result}} =
               Publication.run(staging, files, "import:warn")

      assert target.id == staging.id

      assert %GtfsVersion{} =
               failed = Versions.get_gtfs_version_for_lifecycle(organization.id, staging.id)

      assert failed.publication_status == "failed"
      refute Versions.published_gtfs_version_for_org?(organization.id, staging.id)
    end

    test "an extension image-write failure fails the target", %{
      organization: organization,
      staging: staging
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

      assert {:error, target, {:image_restore_failed, _}} =
               Publication.run(staging, files, "import:img")

      assert target.id == staging.id

      assert %GtfsVersion{} =
               failed = Versions.get_gtfs_version_for_lifecycle(organization.id, staging.id)

      assert failed.publication_status == "failed"
      refute Versions.published_gtfs_version_for_org?(organization.id, staging.id)
    end
  end

  describe "database publication failure after asset writes" do
    setup do
      organization = organization_fixture()
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staged"})
      %{organization: organization, staging: staging}
    end

    @tag :publication_failure
    test "returns publication_failed and leaves target importing + externally unavailable", %{
      organization: organization,
      staging: staging
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
               Publication.run(staging, files, "import:dbfail")

      assert target.id == staging.id

      # Asset writes completed: the level row exists under the claimed version.
      assert length(GtfsPlanner.Gtfs.list_levels(organization.id, staging.id)) == 1

      # Target is left importing for later reconciliation.
      final =
        from(v in GtfsVersion, where: v.id == ^staging.id, select: v.publication_status)
        |> Repo.one!()

      assert final == "importing"

      # Externally unavailable.
      refute Versions.published_gtfs_version_for_org?(organization.id, staging.id)
    end
  end

  describe "no fallback under stale route context" do
    setup do
      organization = organization_fixture()
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staged"})
      {:ok, current} = Versions.create_gtfs_version(organization.id, %{name: "Current"})
      %{organization: organization, staging: staging, current: current}
    end

    test "publication uses only the passed target id, never the route/current version", %{
      organization: organization,
      staging: staging,
      current: current
    } do
      files = [%{filename: "levels.txt", content: @levels_content}]

      assert {:ok, published, _result} = Publication.run(staging, files, "import:exact")
      assert published.id == staging.id

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
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staged"})
      %{organization: organization, staging: staging}
    end

    test "emits scoped transition telemetry with org, target, prior/new state, failure class", %{
      organization: organization,
      staging: staging
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
      {:ok, _published, _result} = Publication.run(staging, files, "import:tele")

      published_event =
        receive_telemetry(fn {_ev, meta} ->
          meta.version_id == staging.id and meta.new_state == "published"
        end)

      assert {_event, meta} = published_event
      assert meta.organization_id == organization.id
      assert meta.version_id == staging.id
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
      staging: staging
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
        Publication.run(staging, files, "import:telefail")

      error_event =
        receive_telemetry(fn {_ev, meta} ->
          meta.version_id == staging.id and not is_nil(meta.failure_class)
        end)

      assert {_event, meta} = error_event
      assert meta.organization_id == organization.id
      assert meta.version_id == staging.id
      assert meta.failure_class == :publication_failed
      assert not is_nil(meta.prior_state)
      assert not is_nil(meta.new_state)
    end
  end

  # --- helpers ---

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
