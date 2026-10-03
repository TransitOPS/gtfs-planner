# Step 4 — Validate the selected artifact (EV-4).
#
# `Validations.start_artifact_run/3` through the application-started
# `Validations.RunnerSupervisor` and the real `Validations.Runner`, the real
# `GtfsPlanner.Gtfs.Validator` and its CLI, and the real `ExportRuns` pin.
#
# The only substituted boundary is the CLI process itself:
# `test/support/fixtures/fake_validator.sh` stands in for `java -jar <jar>`,
# exactly as it does in `validator_cli_process_test.exs`. A `<mode>@<path>` mode
# also copies the input ZIP out, so a case can assert which bytes the validator
# was actually given. Repo, authorization, validation lease, artifact storage,
# pin lease and the runner's supervision are all real.
#
# The completion claim is the central one: once an export artifact is selected,
# changing the version's rows afterwards must change neither the CLI input nor
# the persisted report, and a completed report keeps the counts the CLI actually
# produced rather than a clean summary.

defmodule GtfsPlanner.Validations.ArtifactValidationTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.Export.PublicationPin
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Support.RunnerSlots
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.ValidationRun

  @moduletag :capture_log

  @fake_java Path.expand("../../support/fixtures/fake_validator.sh", __DIR__)
  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}

  setup do
    root =
      Path.join(System.tmp_dir!(), "artifact-validation-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    put_env(:gtfs_task_artifacts_path, root)

    # The real production validator, not the process-owned Mox mock: this step's
    # claim is about the bytes the concrete CLI entrypoint receives.
    put_env(:validator_module, GtfsPlanner.Gtfs.Validator)
    put_env(:java_path, @fake_java)

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    editor = editor_fixture(organization)

    on_exit(fn -> RunnerSlots.await_idle() end)

    %{
      root: root,
      organization: organization,
      version: version,
      editor: editor,
      scope: %{
        actor_id: editor.id,
        organization_id: organization.id,
        user: editor
      }
    }
  end

  describe "start_artifact_run/3" do
    test "refuses a user without a current membership and creates nothing", ctx do
      run = ready_run(ctx, "network.zip", "zip-bytes")

      assert {:error, :forbidden} =
               Validations.start_artifact_run(
                 %{actor_id: Ecto.UUID.generate(), organization_id: ctx.organization.id},
                 run.id,
                 :main
               )

      assert Repo.aggregate(ValidationRun, :count) == 0
      assert Repo.aggregate(PublicationPin, :count) == 0
    end

    test "refuses another tenant's export run and creates nothing", ctx do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)
      run = ready_run(other_organization, other_version, "n.zip", "bytes")

      assert {:error, :not_found} =
               Validations.start_artifact_run(ctx.scope, run.id, :main)

      assert Validations.list_validation_runs(ctx.organization.id, ctx.version.id) == []
      assert Repo.aggregate(PublicationPin, :count) == 0
    end

    test "refuses a slot the run does not carry and creates nothing", ctx do
      run = ready_run(ctx, "network.zip", "zip-bytes")

      assert {:error, :not_found} = Validations.start_artifact_run(ctx.scope, run.id, :flex)

      assert Validations.list_validation_runs(ctx.organization.id, ctx.version.id) == []
      assert Repo.aggregate(PublicationPin, :count) == 0
    end

    test "refuses a slot name that is not a server-chosen one", ctx do
      run = ready_run(ctx, "network.zip", "zip-bytes")

      assert {:error, :invalid_slot} =
               Validations.start_artifact_run(ctx.scope, run.id, "main")

      assert Validations.list_validation_runs(ctx.organization.id, ctx.version.id) == []
    end

    test "a run held by another publisher's pin is refused and creates nothing", ctx do
      run = ready_run(ctx, "network.zip", "zip-bytes")

      assert {:ok, _pin} =
               ExportRuns.pin_publication(
                 ctx.organization.id,
                 ctx.version.id,
                 run.id,
                 :main,
                 "static-publisher"
               )

      assert {:error, :artifact_busy} = Validations.start_artifact_run(ctx.scope, run.id, :main)

      assert Validations.list_validation_runs(ctx.organization.id, ctx.version.id) == []
      assert Repo.one!(PublicationPin).owner_id == "static-publisher"
    end
  end

  describe "a review of a selected artifact" do
    test "feeds the CLI the pinned bytes and records that hash, after the source rows changed",
         ctx do
      seed_fillable_trip(ctx.organization.id, ctx.version.id)
      run = ready_run(ctx, "network.zip", "zip-bytes")
      cli_input = cli_input_path(ctx)
      put_env(:gtfs_validator_path, "report@" <> cli_input)

      # A source edit after the export must not reach the validator: the review
      # is of bytes, not of current database state.
      mutate_source_rows(ctx)

      assert {:ok, review} = Validations.start_artifact_run(ctx.scope, run.id, :main)
      assert await_terminal(review, :validation_completed)

      # The CLI was handed the artifact, byte for byte.
      assert File.read!(cli_input) == "zip-bytes"

      completed = Repo.get!(ValidationRun, review.id)

      assert completed.run_type == "mobility_data_artifact"
      assert completed.status == "completed"
      assert completed.artifact_sha256 == artifact_sha(run)
      assert completed.artifact_export_run_id == run.id
      assert completed.artifact_slot == :main
      assert completed.errors_count == 0
      assert completed.result_json == %{"notices" => []}
      assert completed.completed_at
      assert completed.lease_token == nil

      # The source edit is still there: only the review ignored it.
      assert changed_stop_time(ctx) == "09:30:00"
    end

    test "a report with errors keeps the counts the validator produced", ctx do
      run = ready_run(ctx, "network.zip", "zip-bytes")
      put_env(:gtfs_validator_path, "error_report")

      assert {:ok, review} = Validations.start_artifact_run(ctx.scope, run.id, :main)
      assert await_terminal(review, :validation_completed)

      completed = Repo.get!(ValidationRun, review.id)

      assert completed.status == "completed"
      assert completed.errors_count == 2
      assert completed.warnings_count == 3
      assert completed.artifact_sha256 == artifact_sha(run)
    end

    test "an engine timeout fails the run and never records a clean report", ctx do
      run = ready_run(ctx, "network.zip", "zip-bytes")
      put_env(:gtfs_validator_path, "sleep")
      put_env(:validator_timeout_ms, 200)

      assert {:ok, review} = Validations.start_artifact_run(ctx.scope, run.id, :main)
      assert await_terminal(review, :validation_failed)

      failed = Repo.get!(ValidationRun, review.id)

      assert failed.status == "failed"
      assert failed.error_details == "timeout"
      assert is_nil(failed.result_json)
      assert failed.completed_at
    end

    test "a CLI failure fails the run and never records a clean report", ctx do
      run = ready_run(ctx, "network.zip", "zip-bytes")
      put_env(:gtfs_validator_path, "big_output")

      assert {:ok, review} = Validations.start_artifact_run(ctx.scope, run.id, :main)
      assert await_terminal(review, :validation_failed)

      failed = Repo.get!(ValidationRun, review.id)

      assert failed.status == "failed"
      assert failed.error_details == "cli_failed"
      assert is_nil(failed.result_json)
    end

    test "a malformed report is a failed run, not a clean one", ctx do
      run = ready_run(ctx, "network.zip", "zip-bytes")
      put_env(:gtfs_validator_path, "bad_report")

      assert {:ok, review} = Validations.start_artifact_run(ctx.scope, run.id, :main)
      assert await_terminal(review, :validation_failed)

      failed = Repo.get!(ValidationRun, review.id)

      assert failed.status == "failed"
      assert failed.error_details == "invalid_report"
      assert is_nil(failed.result_json)
    end

    test "bytes that disappear mid-review fail the run rather than reporting on nothing",
         ctx do
      run = ready_run(ctx, "network.zip", "zip-bytes")
      put_env(:gtfs_validator_path, "sleep")
      put_env(:validator_timeout_ms, 5_000)

      assert {:ok, review} = Validations.start_artifact_run(ctx.scope, run.id, :main)

      File.rm!(artifact_path(run))

      assert await_terminal(review, :validation_failed)

      failed = Repo.get!(ValidationRun, review.id)

      assert failed.status == "failed"
      assert failed.error_details == "missing_or_corrupt_artifact"
      assert is_nil(failed.result_json)
    end
  end

  describe "the pin a review holds" do
    test "protects the artifact while the review runs and is released when it finishes",
         ctx do
      run = ready_run(ctx, "network.zip", "zip-bytes")
      put_env(:gtfs_validator_path, "report")

      assert {:ok, review} = Validations.start_artifact_run(ctx.scope, run.id, :main)

      # The review holds a live pin on the artifact while it runs.
      assert Repo.one!(PublicationPin).export_run_id == run.id
      assert File.exists?(artifact_path(run))

      assert await_terminal(review, :validation_completed)

      # Released: the private artifact returns to normal retention.
      assert Repo.aggregate(PublicationPin, :count) == 0

      expire_artifact!(run)
      assert ExportRuns.cleanup_expired(ctx.organization.id) == 1
      assert Repo.get!(Run, run.id).state == :expired
    end

    test "records no download", ctx do
      run = ready_run(ctx, "network.zip", "zip-bytes")
      put_env(:gtfs_validator_path, "report")

      assert {:ok, review} = Validations.start_artifact_run(ctx.scope, run.id, :main)
      assert await_terminal(review, :validation_completed)

      stored = Repo.get!(Run, run.id)

      assert stored.download_count == 0
      assert is_nil(stored.download_claimed_until)
      assert is_nil(stored.last_downloaded_at)
    end
  end

  describe "existing database-export validation" do
    test "an ordinary run keeps its own behavior and carries no artifact binding", ctx do
      seed_fillable_trip(ctx.organization.id, ctx.version.id)
      put_env(:gtfs_validator_path, "report@" <> cli_input_path(ctx))

      assert {:ok, run} =
               Validations.start_mobility_data_run(
                 ctx.organization.id,
                 ctx.version.id,
                 "mobility_data",
                 ctx.editor
               )

      assert await_terminal(run, :validation_completed)

      completed = Repo.get!(ValidationRun, run.id)

      assert completed.run_type == "mobility_data"
      assert completed.status == "completed"
      assert is_nil(completed.artifact_sha256)
      assert is_nil(completed.artifact_slot)
      assert is_nil(completed.artifact_export_run_id)

      # It is still the version's feed check, which an artifact review never is.
      assert Validations.latest_feed_check(ctx.organization.id, ctx.version.id).id == run.id
    end

    test "an artifact review is never listed as the version's feed check", ctx do
      run = ready_run(ctx, "network.zip", "zip-bytes")
      put_env(:gtfs_validator_path, "report")

      assert {:ok, review} = Validations.start_artifact_run(ctx.scope, run.id, :main)
      assert await_terminal(review, :validation_completed)

      assert is_nil(Validations.latest_feed_check(ctx.organization.id, ctx.version.id))
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp ready_run(ctx, filename, bytes) do
    ready_run(ctx.organization, ctx.version, filename, bytes)
  end

  defp ready_run(organization, version, filename, bytes) do
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)
    {:ok, _building, generation, token} = ExportRuns.claim(organization.id, run.id, :build)
    {:ok, main} = ArtifactStorage.publish(organization.id, version.id, run.id, filename, bytes)

    {:ok, ready} =
      ExportRuns.mark_ready(organization.id, run.id, generation, token, %{main: main, flex: nil})

    ready
  end

  defp artifact_path(run) do
    metadata = %{
      organization_id: run.organization_id,
      gtfs_version_id: run.gtfs_version_id,
      run_id: run.id,
      key: run.artifact_key,
      filename: run.artifact_filename,
      sha256: run.artifact_sha256,
      size: run.artifact_size_bytes
    }

    case ArtifactStorage.verify(metadata) do
      {:ok, path} -> path
      {:error, reason} -> raise "artifact not verifiable: #{inspect(reason)}"
    end
  end

  defp artifact_sha(run), do: artifact(run).sha256

  defp artifact(run) do
    %{
      key: run.artifact_key,
      filename: run.artifact_filename,
      sha256: run.artifact_sha256,
      size: run.artifact_size_bytes,
      path: artifact_path(run)
    }
  end

  defp expire_artifact!(run) do
    from(r in Run, where: r.id == ^run.id)
    |> Repo.update_all(set: [artifact_expires_at: ~U[2000-01-01 00:00:00.000000Z]])
  end

  # A real stored row, changed through the database rather than a fixture, so
  # the review has something current-state that differs from the artifact to
  # ignore.
  defp mutate_source_rows(ctx) do
    stop_time =
      Repo.one!(
        from(s in StopTime,
          where:
            s.organization_id == ^ctx.organization.id and
              s.gtfs_version_id == ^ctx.version.id and s.trip_id == "T1",
          order_by: [asc: s.stop_sequence],
          limit: 1
        )
      )

    Repo.update_all(
      from(s in StopTime, where: s.id == ^stop_time.id),
      set: [departure_time: "09:30:00"]
    )
  end

  defp changed_stop_time(ctx) do
    Repo.one!(
      from(s in StopTime,
        where:
          s.organization_id == ^ctx.organization.id and
            s.gtfs_version_id == ^ctx.version.id and s.trip_id == "T1",
        order_by: [asc: s.stop_sequence],
        limit: 1,
        select: s.departure_time
      )
    )
  end

  defp seed_fillable_trip(organization_id, version_id) do
    for index <- 1..5 do
      stop_fixture(organization_id, version_id, stop_id: "S#{index}")
    end

    route_fixture(organization_id, version_id, route_id: "R1")
    trip_fixture(organization_id, version_id, "R1", %{trip_id: "T1"})

    distances = ["0", "200", "400", "2400", "3000"]

    for sequence <- 1..5 do
      stop_time_fixture(organization_id, version_id, "T1", "S#{sequence}", %{
        stop_sequence: sequence,
        arrival_time: "08:00:00",
        departure_time: "08:00:00",
        timepoint: if(sequence in [1, 5], do: 1, else: nil),
        shape_dist_traveled: Decimal.new(Enum.at(distances, sequence - 1))
      })
    end
  end

  defp cli_input_path(ctx) do
    path = Path.join(ctx.root, "cli-input-#{System.unique_integer([:positive])}.zip")
    on_exit(fn -> File.rm(path) end)
    path
  end

  # Subscribing first and then reading the stored status closes the race: either
  # the broadcast arrives after the subscription, or the terminal row is already
  # committed when the row is read.
  defp await_terminal(run, event) do
    run_id = run.id
    Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, Validations.topic(run_id))

    receive do
      {^event, ^run_id} -> true
    after
      0 ->
        status = Validations.get_validation_run(run_id).status

        if (status == "completed" and event == :validation_completed) or
             (status == "failed" and
                event == :validation_failed) do
          true
        else
          receive do
            {^event, ^run_id} -> true
          after
            15_000 -> false
          end
        end
    end
  end

  defp put_env(key, value) do
    previous = Application.fetch_env(:gtfs_planner, key)
    Application.put_env(:gtfs_planner, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:gtfs_planner, key, old)
        :error -> Application.delete_env(:gtfs_planner, key)
      end
    end)
  end
end
