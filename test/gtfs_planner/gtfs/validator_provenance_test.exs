# Step 002 — Capture the input the validator was actually given
#
# Provenance tests (EV-2). The Java executable is the only faked boundary:
# `test/support/fixtures/fake_validator.sh` copies the ZIP it is handed, so the
# digest the run records can be checked against the bytes on disk. Export,
# defaults, validation-run lease writes and report parsing are real.
# Grouped/flat report normalization itself is covered by
# `validator_cli_process_test.exs`.

defmodule GtfsPlanner.Gtfs.ValidatorProvenanceTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.FlexFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Gtfs.Validator
  alias GtfsPlanner.Gtfs.Validator.Result
  alias GtfsPlanner.Validations

  @moduletag :capture_log

  @fake_java Path.expand("../../support/fixtures/fake_validator.sh", __DIR__)

  # Anchors 08:00 and 08:10 over stored distances 0/200/400/2400/3000: the
  # distance shares are 40/80/480 seconds and the even shares are 150 each, so
  # the ZIP bytes themselves prove which estimate produced them.
  @distance_times [
    {"S1", "08:00:00"},
    {"S2", "08:00:40"},
    {"S3", "08:01:20"},
    {"S4", "08:08:00"},
    {"S5", "08:10:00"}
  ]

  setup do
    put_env(:java_path, @fake_java)

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    seed_fillable_trip(organization.id, version.id)

    %{organization: organization, version: version, zip_copy: copy_path()}
  end

  test "records the digest of the exact ZIP Java was given and persists it", ctx do
    put_env(:gtfs_validator_path, "report@" <> ctx.zip_copy)
    {:ok, run} = create_run(ctx, "mobility_data")

    assert {:ok, %Result{} = result} = validate(ctx, run)

    assert result.checked_zip_sha256 == sha256(File.read!(ctx.zip_copy))
    assert result.checked_export_profile == primary_profile()
    assert result.validator_version == "fake"

    {:ok, _claimed, token} = Validations.claim_run(ctx.organization.id, run.id)
    assert {:ok, written} = Validations.complete_run(ctx.organization.id, run.id, token, result)

    persisted = Repo.reload!(written)
    assert persisted.checked_zip_sha256 == sha256(File.read!(ctx.zip_copy))
    assert persisted.validator_version == "fake"

    # jsonb reads the profile back with string keys and the same values.
    assert persisted.checked_export_profile == %{
             "schema_version" => 1,
             "export_type" => "full",
             "include_flex" => false,
             "artifact_kind" => "primary",
             "estimate_method" => "distance"
           }

    assert persisted.result_json == %{"notices" => []}
  end

  test "records the estimate the export used, not defaults read again afterwards", ctx do
    put_env(:gtfs_validator_path, "report_after_release@" <> ctx.zip_copy)
    {:ok, run} = create_run(ctx, "mobility_data")

    task = Task.async(fn -> validate(ctx, run) end)

    # The fake has copied the ZIP and is waiting: the export is done, so
    # changing the defaults now cannot affect the bytes being validated.
    await_file(ctx.zip_copy <> ".waiting")

    {:ok, _defaults} =
      ExportDefaults.update(ctx.organization.id, editor_fixture(ctx.organization), %{
        estimate_method: :even
      })

    File.touch!(ctx.zip_copy <> ".release")

    assert {:ok, %Result{} = result} = Task.await(task, 30_000)

    assert result.checked_export_profile.estimate_method == "distance"
    assert zip_trip_times(ctx.zip_copy) == @distance_times
    assert ExportDefaults.get(ctx.organization.id).estimate_method == :even
  end

  test "a flex run records the companion flex artifact it was given", ctx do
    flex_representative_fixture(ctx.organization, ctx.version)
    put_env(:gtfs_validator_path, "report@" <> ctx.zip_copy)
    {:ok, run} = create_run(ctx, "mobility_data_flex")

    assert {:ok, %Result{} = result} = validate(ctx, run)

    assert result.checked_export_profile == %{
             schema_version: 1,
             export_type: "full",
             include_flex: true,
             artifact_kind: "flex",
             estimate_method: "distance"
           }

    assert result.checked_zip_sha256 == sha256(File.read!(ctx.zip_copy))
  end

  test "leaves provenance nil when nothing was captured", ctx do
    result = %Result{
      summary: %{errors: 0, warnings: 0, infos: 0},
      notices: [],
      duration_ms: 1,
      validated_at: DateTime.utc_now()
    }

    {:ok, run} = create_run(ctx, "mobility_data")
    {:ok, _claimed, token} = Validations.claim_run(ctx.organization.id, run.id)

    assert {:ok, written} = Validations.complete_run(ctx.organization.id, run.id, token, result)

    persisted = Repo.reload!(written)
    assert persisted.checked_zip_sha256 == nil
    assert persisted.checked_export_profile == nil
    assert persisted.validator_version == nil
  end

  # --- helpers ----------------------------------------------------------------

  defp create_run(ctx, run_type) do
    Validations.create_validation_run(ctx.organization.id, ctx.version.id, run_type)
  end

  defp validate(ctx, run) do
    Validator.validate(ctx.organization.id, ctx.version.id, validation_run_id: run.id)
  end

  defp primary_profile do
    %{
      schema_version: 1,
      export_type: "full",
      include_flex: false,
      artifact_kind: "primary",
      estimate_method: "distance"
    }
  end

  defp copy_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "validator_provenance_#{System.unique_integer([:positive])}.zip"
      )

    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp sha256(bytes) do
    :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
  end

  # The only handle on an external shell process is the file it writes, so the
  # barrier is observed by polling for it. The attempt count is a deadline for
  # diagnosis, not the mechanism the assertion depends on.
  defp await_file(path, attempts \\ 500) do
    cond do
      File.exists?(path) ->
        :ok

      attempts == 0 ->
        flunk("#{path} never appeared")

      true ->
        Process.sleep(10)
        await_file(path, attempts - 1)
    end
  end

  defp zip_trip_times(zip_path) do
    {:ok, entries} = :zip.unzip(String.to_charlist(zip_path), [:memory])

    {_name, content} =
      Enum.find(entries, fn {name, _content} -> List.to_string(name) == "stop_times.txt" end)

    [header | lines] = content |> to_string() |> String.split("\n", trim: true)
    columns = String.split(header, ",")

    lines
    |> Enum.map(fn line -> columns |> Enum.zip(String.split(line, ",")) |> Map.new() end)
    |> Enum.filter(&(&1["trip_id"] == "T1"))
    |> Enum.sort_by(&String.to_integer(&1["stop_sequence"]))
    |> Enum.map(&{&1["stop_id"], &1["arrival_time"]})
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
        arrival_time: anchor_time(sequence, "08:00:00", "08:10:00"),
        departure_time: anchor_time(sequence, "08:00:00", "08:10:00"),
        timepoint: if(sequence in [1, 5], do: 1, else: nil),
        shape_dist_traveled: Decimal.new(Enum.at(distances, sequence - 1))
      })
    end
  end

  defp anchor_time(1, first, _last), do: first
  defp anchor_time(5, _first, last), do: last
  defp anchor_time(_sequence, _first, _last), do: nil
end
