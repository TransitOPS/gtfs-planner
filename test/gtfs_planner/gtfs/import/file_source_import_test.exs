defmodule GtfsPlanner.Gtfs.Import.FileSourceImportTest do
  @moduledoc """
  Full imports from staged files. Uploads are copied into the run's private directory
  by `SourceStorage.stage/4`; the real `Runner` and `Publication` pass the returned
  descriptors to `Import.import_files/5`, which streams each file from its path.

  Each test stages through the real storage under the test artifact root and
  removes what it staged. The runner cases use the default worker (`Publication`).
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlanner.Gtfs.Import.{Publication, Run, Runner, SourceStorage}
  alias GtfsPlanner.Gtfs.ImportRuns
  alias GtfsPlanner.Support.RunnerSlots
  alias GtfsPlanner.Versions

  @levels_content """
  level_id,level_index,level_name
  L1,0.0,Ground Floor
  L2,1.0,Platform
  """

  @stops_content """
  stop_id,stop_name,stop_lat,stop_lon,level_id,location_type,wheelchair_boarding
  S1,Main Station,40.7128,-74.0060,L1,1,1
  S2,Platform A,40.7129,-74.0061,L2,0,2
  """

  @stop_times_header "trip_id,stop_id,stop_sequence,arrival_time,departure_time\n"

  # Import worker that reports the files the runner handed it, then waits for `:finish`.
  defmodule SpyImportWorker do
    def run(_run, _lease_token, files, _topic) do
      owner = Application.fetch_env!(:gtfs_planner, :spy_import_worker_owner)
      send(owner, {:spy_import_worker_started, self(), files})

      receive do
        :finish -> :ok
      end
    end
  end

  setup do
    RunnerSlots.await_idle()
    %{organization: GtfsPlanner.OrganizationsFixtures.organization_fixture()}
  end

  describe "importing the fixture feed from staged files" do
    test "produces the row counts import_test.exs expects for the same feed", %{
      organization: organization
    } do
      version = gtfs_version_fixture(organization.id)
      run_id = Ecto.UUID.generate()

      staged =
        stage(organization, run_id, [
          %{filename: "levels.txt", content: @levels_content},
          %{filename: "stops.txt", content: @stops_content}
        ])

      assert {:ok, result} =
               Import.import_files(organization.id, version.id, staged, nil,
                 expand_dir: expand_dir(organization, run_id)
               )

      assert result.counts.levels == 2
      assert result.counts.stops == 2
      assert result.counts.routes == 0
      assert result.counts.pathways == 0
      assert result.counts.route_patterns == 0
      assert result.unrecognized_files == []
      assert result.archive_warnings == []
      assert result.extensions == :not_present
      assert Import.Result.publishable?(result)
      assert length(Gtfs.list_levels(organization.id, version.id)) == 2
      assert length(Gtfs.list_stops(organization.id, version.id)) == 2
    end

    test "produces the same counts when the feed arrives as a zip extracted into the run directory",
         %{organization: organization} do
      {run, token} = claimed_run(organization, "Zipped Feed")

      {:ok, {_name, zip}} =
        :zip.create(
          ~c"feed.zip",
          [{~c"levels.txt", @levels_content}, {~c"stops.txt", @stops_content}],
          [:memory]
        )

      staged = stage(organization, run.id, [%{filename: "feed.zip", content: zip}])

      assert {:ok, _published, result} = Publication.run(run, token, staged, "import:zip")

      assert result.counts.levels == 2
      assert result.counts.stops == 2
      assert result.archive_warnings == []

      {:ok, run_dir} = SourceStorage.run_dir(organization.id, run.id)
      assert File.read!(Path.join([run_dir, "expanded", "0", "levels.txt"])) == @levels_content
      assert File.read!(Path.join([run_dir, "expanded", "0", "stops.txt"])) == @stops_content
    end
  end

  describe "a stop_times.txt with an invalid UTF-8 byte after 1,500 rows" do
    test "commits no stop_times row, fails with invalid_utf8 and never publishes", %{
      organization: organization
    } do
      run = pending_run(organization, "Late Invalid Byte")
      runner = start_runner(organization, run, late_invalid_utf8_feed())

      await_exit(runner)

      persisted_run = Repo.get!(Run, run.id)
      assert persisted_run.state == "partial"
      assert persisted_run.reason_code == "invalid_utf8"
      assert persisted_run.failed_file == "stop_times.txt"
      assert persisted_run.committed_counts["stop_times"] == 0
      assert persisted_run.committed_counts["levels"] == 2
      assert stop_time_count(run) == 0

      target = Versions.get_gtfs_version_for_lifecycle(organization.id, run.gtfs_version_id)
      assert target.publication_status == "failed"
      refute Versions.published_gtfs_version_for_org?(organization.id, run.gtfs_version_id)
    end
  end

  describe "a row longer than 1,048,576 bytes" do
    test "fails the import with record_too_long at that row and commits nothing", %{
      organization: organization
    } do
      version = gtfs_version_fixture(organization.id)
      run_id = Ecto.UUID.generate()
      oversized_name = String.duplicate("x", 1_048_577)

      staged =
        stage(organization, run_id, [
          %{
            filename: "levels.txt",
            content: "level_id,level_index,level_name\nL1,0.0," <> oversized_name <> "\n"
          }
        ])

      assert {:error, %Import.Failure{} = failure} =
               Import.import_files(organization.id, version.id, staged, nil,
                 expand_dir: expand_dir(organization, run_id)
               )

      assert failure.reason_code == "record_too_long"
      assert failure.failed_file == "levels.txt"
      assert failure.failed_row == 2
      assert Gtfs.list_levels(organization.id, version.id) == []
    end
  end

  describe "the run's source directory" do
    test "is removed after a publish", %{organization: organization} do
      run = pending_run(organization, "Published Feed")

      runner =
        start_runner(organization, run, [
          %{filename: "levels.txt", content: @levels_content},
          %{filename: "stops.txt", content: @stops_content}
        ])

      {:ok, run_dir} = SourceStorage.run_dir(organization.id, run.id)
      assert File.dir?(run_dir)

      await_exit(runner)

      assert Repo.get!(Run, run.id).state == "published"
      refute File.exists?(run_dir)
    end

    test "is removed after a terminal failure", %{organization: organization} do
      run = pending_run(organization, "Failed Feed")
      runner = start_runner(organization, run, late_invalid_utf8_feed())

      {:ok, run_dir} = SourceStorage.run_dir(organization.id, run.id)
      assert File.dir?(run_dir)

      await_exit(runner)

      assert Repo.get!(Run, run.id).state == "partial"
      refute File.exists?(run_dir)
    end
  end

  describe "a running Import.Runner" do
    setup do
      previous = %{
        worker: Application.fetch_env(:gtfs_planner, :import_worker_module),
        owner: Application.fetch_env(:gtfs_planner, :spy_import_worker_owner)
      }

      Application.put_env(:gtfs_planner, :import_worker_module, SpyImportWorker)
      Application.put_env(:gtfs_planner, :spy_import_worker_owner, self())

      on_exit(fn ->
        RunnerSlots.await_idle()
        restore_env(:import_worker_module, previous.worker)
        restore_env(:spy_import_worker_owner, previous.owner)
      end)

      :ok
    end

    test "holds descriptors, not file contents, in its state and its worker's input", %{
      organization: organization
    } do
      run = pending_run(organization, "Large Source")

      large_stop_times =
        @stop_times_header <> String.duplicate("T1,S1,1,08:00:00,08:00:00\n", 3_000)

      runner =
        start_runner(organization, run, [%{filename: "stop_times.txt", content: large_stop_times}])

      assert_receive {:spy_import_worker_started, worker, worker_files}, 5_000

      assert byte_size(large_stop_times) > 4_096
      assert largest_binary(:sys.get_state(runner)) <= 4_096
      assert largest_binary(worker_files) <= 4_096

      assert [%{filename: "stop_times.txt", path: path}] = worker_files
      assert File.read!(path) == large_stop_times

      send(worker, :finish)
      await_exit(runner)
    end
  end

  # Writes each file to a temporary upload path, as LiveView does for a consumed
  # upload, and copies them into the run's source directory. Removes both on exit.
  defp stage(organization, run_id, files) do
    uploads_dir = Path.join(System.tmp_dir!(), "file-source-import-#{Ecto.UUID.generate()}")
    File.mkdir_p!(uploads_dir)

    on_exit(fn ->
      File.rm_rf!(uploads_dir)
      SourceStorage.remove(organization.id, run_id)
    end)

    uploads =
      files
      |> Enum.with_index()
      |> Enum.map(fn {%{filename: filename, content: content}, index} ->
        path = Path.join(uploads_dir, "upload-#{index}")
        File.write!(path, content)
        %{path: path, filename: filename}
      end)

    {:ok, staged} = SourceStorage.stage(organization.id, run_id, uploads)
    staged
  end

  defp expand_dir(organization, run_id) do
    {:ok, run_dir} = SourceStorage.run_dir(organization.id, run_id)
    Path.join(run_dir, "expanded")
  end

  # The actor is an active editor with a collision-proof email: committed rows left by
  # other test files can already hold the sequential `user-N@example.com` addresses.
  defp pending_run(organization, name) do
    editor = user_fixture(%{email: "file-source-#{Ecto.UUID.generate()}@example.com"})
    organization_membership_fixture(editor, organization)

    {:ok, %{run: run}} =
      ImportRuns.create_pending_target(
        organization.id,
        %{id: editor.id, email: editor.email},
        %{name: name}
      )

    run
  end

  defp claimed_run(organization, name) do
    run = pending_run(organization, name)

    {:ok, claimed, _version, token} =
      ImportRuns.claim_import(organization.id, run.id, run.lease_token)

    {claimed, token}
  end

  defp start_runner(organization, run, files) do
    staged = stage(organization, run.id, files)
    {:ok, runner} = Runner.start_import(organization.id, run.id, run.lease_token, staged)
    runner
  end

  # Waits until the runner is gone. A runner that already stopped answers the monitor
  # with `:noproc`, so the reason is not matched; callers assert on the run's state.
  defp await_exit(runner) do
    ref = Process.monitor(runner)
    assert_receive {:DOWN, ^ref, :process, ^runner, _reason}, 30_000
  end

  # 1,500 valid rows fill one 1,000-row batch and half of the next before the
  # invalid byte, so only a whole-file check can keep every row out.
  defp late_invalid_utf8_feed do
    valid_rows = Enum.map_join(1..1_500, "", fn n -> "T1,S#{n},#{n},08:00:00,08:00:00\n" end)
    invalid_row = "T1,S" <> <<0xFF>> <> ",1501,08:00:00,08:00:00\n"

    [
      %{filename: "levels.txt", content: @levels_content},
      %{filename: "stops.txt", content: @stops_content},
      %{filename: "stop_times.txt", content: @stop_times_header <> valid_rows <> invalid_row}
    ]
  end

  defp stop_time_count(run) do
    Repo.aggregate(
      from(st in Gtfs.StopTime, where: st.gtfs_version_id == ^run.gtfs_version_id),
      :count
    )
  end

  # The size in bytes of the largest binary anywhere in `term`.
  defp largest_binary(term) when is_binary(term), do: byte_size(term)
  defp largest_binary([head | tail]), do: max(largest_binary(head), largest_binary(tail))
  defp largest_binary(term) when is_tuple(term), do: term |> Tuple.to_list() |> largest_binary()
  defp largest_binary(term) when is_map(term), do: term |> Map.to_list() |> largest_binary()
  defp largest_binary(_term), do: 0

  defp restore_env(key, {:ok, value}), do: Application.put_env(:gtfs_planner, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:gtfs_planner, key)
end
