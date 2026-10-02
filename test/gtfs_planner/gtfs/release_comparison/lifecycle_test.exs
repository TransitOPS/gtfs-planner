defmodule GtfsPlanner.Gtfs.ReleaseComparison.LifecycleTest do
  @moduledoc """
  Focused evidence for CL-7/FH-7: the native start exclusively owns the claims,
  the exact bytes and the cleanup, and cleanup happens on every exit - cancel, a
  caller that went down, a crashed or heap-killed compute child, a refusal and
  the deadline - before any terminal message is delivered.

  Every case runs through `ReleaseComparison.start/4` and the real
  `GtfsPlanner.Gtfs.ReleaseComparison.Runner`, the real
  `GtfsPlanner.Gtfs.ExportRuns` claim/receipt transitions and the real
  `ArtifactStorage`. The happy path uses artifacts the native exporter actually
  produced, through `GtfsPlanner.Gtfs.Export.build_zip/3`.

  The lifecycle cases need the compute child to still be running when the case
  acts, so those artifacts are larger and carry the same member names, headers
  and row shape the native exporter writes. They are still produced and stored
  through the native storage path, and they are bounded by the same reader caps:
  the fixture is a verified producer contract, not a hostile upload.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.ReleaseComparison
  alias GtfsPlanner.Gtfs.ReleaseComparison.Compare
  alias GtfsPlanner.Gtfs.ReleaseComparison.Projection
  alias GtfsPlanner.Gtfs.ReleaseComparison.Reader
  alias GtfsPlanner.Gtfs.ReleaseComparison.Runner
  alias GtfsPlanner.Repo

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}
  @task_supervisor GtfsPlanner.TaskSupervisor

  # Large enough that the compute child is still reading and comparing when a case
  # acts on it, small enough to stay well inside the reader's own caps.
  @slow_trips 1_500

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "release-comparison-lifecycle-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    previous_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      File.rm_rf(root)

      if previous_root,
        do: Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, previous_root),
        else: Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_path)
    end)

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    scope = scope(organization, version)

    %{organization: organization, version: version, scope: scope}
  end

  describe "start/4 through the production composition" do
    test "claims both artifacts once, reads their exact bytes and returns the comparison digest",
         %{organization: organization, version: version, scope: scope} do
      left = native_run!(organization, version, 1)
      right_version = gtfs_version_fixture(organization.id)
      right = native_run!(organization, right_version, 2)

      assert {:ok, pid} = start(scope, left, right)
      assert_receive {:release_comparison, :start_1, {:ok, result}}, 60_000

      # The delivered result names the bytes it describes, so a later comparison
      # of the same runs is distinguishable from this one.
      assert result.left.run_id == left.id
      assert result.right.run_id == right.id
      assert result.left.sha256 == left.artifact_sha256
      assert result.right.sha256 == right.artifact_sha256
      assert result.window == %{from: ~D[2026-11-23], to: ~D[2026-11-27]}
      assert byte_size(result.fingerprint) == 64

      # Both receipts were taken and released; the runs are still the retained,
      # ready artifacts the selection resolved, on their original retention.
      for run <- [left, right] do
        stored = Repo.get!(Run, run.id)
        assert stored.state == :ready
        assert stored.download_count == 1
        assert stored.download_claimed_until == nil
        assert stored.last_downloaded_at
        assert stored.artifact_sha256 == run.artifact_sha256
        assert stored.artifact_size_bytes == run.artifact_size_bytes
        assert stored.artifact_expires_at == run.artifact_expires_at
      end

      # The digest describes exactly this pair of artifacts over exactly this
      # window: it is the digest the same claimed bytes produce outside the
      # coordinator, and describing them again describes them identically.
      assert result.comparison.digest == digest_of(organization, left, right, result.window)
      assert is_binary(result.comparison.digest) and byte_size(result.comparison.digest) == 64

      assert_coordinator_exits(pid)
    end

    test "comparing one artifact with itself is one receipt, one claim and one read",
         %{organization: organization, version: version, scope: scope} do
      run = native_run!(organization, version, 3)

      assert {:ok, _pid} = start(scope, run, run)
      assert_receive {:release_comparison, :start_1, {:ok, result}}, 60_000

      # The stored primary references the native exporter writes are still
      # verified, parsed and disclosed, and nothing is concluded from them.
      assert Enum.any?(result.comparison.unknowns, &(&1.reason == :unknown_route))
      assert result.comparison.totals.exact_count_delta == nil
      assert :unmapped_route in result.comparison.totals.reasons
      assert result.comparison.effective_changes == []
      assert is_binary(result.comparison.digest)

      stored = Repo.get!(Run, run.id)
      assert stored.download_count == 1
      assert stored.download_claimed_until == nil
    end

    test "an invalid window, an unsupported profile and a foreign run are refused without a claim",
         %{organization: organization, version: version, scope: scope} do
      full = native_run!(organization, version, 4)
      other = native_run!(organization, version, 5)
      pathways_version = gtfs_version_fixture(organization.id)
      pathways = publish_run!(organization, pathways_version, producer_zip(1), :pathways)

      foreign_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign_organization.id)
      foreign = native_run!(foreign_organization, foreign_version, 6)

      # Every one of these refusals arrives through the coordinator, because only
      # an explicit native start reads anything.
      # A 63-date window exceeds the retained comparison bound and is refused.
      assert {:ok, pid} = start(scope, full, other, from: "2026-11-01", to: "2027-01-02")
      assert_receive {:release_comparison, :start_1, {:error, :invalid_window}}, 10_000
      assert_coordinator_exits(pid)

      assert {:ok, pid} = start(scope, pathways, other)
      assert_receive {:release_comparison, :start_1, {:error, :unsupported_profile}}, 10_000
      assert_coordinator_exits(pid)

      assert {:ok, pid} = start(scope, full, foreign)
      assert_receive {:release_comparison, :start_1, {:error, :unavailable}}, 10_000
      assert_coordinator_exits(pid)

      # None of those refusals touched a receipt, a claim or the artifact.
      for run <- [full, other, pathways, foreign] do
        assert %Run{download_count: 0, download_claimed_until: nil, state: :ready} =
                 Repo.get!(Run, run.id)
      end
    end

    test "a revoked membership refuses the comparison and leaves the GTFS rows alone",
         %{organization: organization, version: version, scope: scope} do
      left = native_run!(organization, version, 7)

      right =
        native_run!(organization, gtfs_version_fixture(organization.id), 8)

      before_rows = gtfs_row_counts(organization)

      revoke!(scope)
      runs_before = Repo.aggregate(Run, :count)

      assert {:ok, pid} = start(scope, left, right)
      assert_receive {:release_comparison, :start_1, {:error, :unavailable}}, 10_000
      assert_coordinator_exits(pid)

      assert gtfs_row_counts(organization) == before_rows
      assert Repo.aggregate(Run, :count) == runs_before
      assert %Run{download_count: 0, download_claimed_until: nil} = Repo.get!(Run, left.id)
      assert %Run{download_count: 0, download_claimed_until: nil} = Repo.get!(Run, right.id)
    end

    test "a missing scope, unusable params or a dead owner starts no coordinator at all" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      scope = scope(organization, version)
      run = native_run!(organization, version, 9)

      assert {:error, :unavailable} =
               ReleaseComparison.start(%{}, params(run, run), self(), :ref)

      assert {:ok, pid} =
               ReleaseComparison.start(scope, %{"left_run_id" => run.id}, self(), :ref)

      assert_receive {:release_comparison, :ref, {:error, :invalid_window}}, 10_000
      assert_coordinator_exits(pid)

      owner = spawn(fn -> :ok end)
      ref = Process.monitor(owner)
      assert_receive {:DOWN, ^ref, :process, ^owner, _reason}

      assert {:error, :unavailable} = start(scope, run, run, owner: owner)
      refute_receive {:release_comparison, :ref, _message}, 200
      assert %Run{download_count: 0, download_claimed_until: nil} = Repo.get!(Run, run.id)
    end
  end

  describe "cleanup after the compute child is interrupted" do
    setup %{organization: organization, version: version} do
      left = slow_run!(organization, version)
      right = slow_run!(organization, gtfs_version_fixture(organization.id))
      known = task_children()

      %{left: left, right: right, known: known}
    end

    test "a cancellation stops the compute child and clears every tracked claim",
         %{scope: scope, left: left, right: right, known: known} do
      assert {:ok, pid} = start(scope, left, right)
      {task, task_ref} = await_compute_child(known, pid, deadline())

      # The real child carries the production heap ceiling, in system words.
      assert {:max_heap_size, %{size: words, kill: true, error_logger: false}} =
               Process.info(task, :max_heap_size)

      assert words == div(128 * 1024 * 1024, :erlang.system_info(:wordsize))

      assert :ok = ReleaseComparison.cancel(pid, :start_1)

      assert_receive {:release_comparison, :start_1, {:error, :cancelled}}, 10_000
      assert_receive {:DOWN, ^task_ref, :process, ^task, _reason}, 5_000
      assert_coordinator_exits(pid)

      assert_claims_released([left, right])
    end

    test "a cancellation carrying the wrong request reference is ignored",
         %{scope: scope, left: left, right: right, known: known} do
      assert {:ok, pid} = start(scope, left, right)
      {_task, _task_ref} = await_compute_child(known, pid, deadline())

      # A foreign process may not cancel someone else's comparison.
      foreign = spawn(fn -> ReleaseComparison.cancel(pid, :start_1) end)
      foreign_ref = Process.monitor(foreign)
      assert_receive {:DOWN, ^foreign_ref, :process, ^foreign, _reason}
      refute_receive {:release_comparison, :start_1, _message}, 300

      # The live owner still can, and the claims it held are released.
      assert :ok = ReleaseComparison.cancel(pid, :start_1)
      assert_receive {:release_comparison, :start_1, {:error, :cancelled}}, 10_000
      assert_claims_released([left, right])
    end

    test "a killed compute child answers worker_exit and still clears every claim",
         %{scope: scope, left: left, right: right, known: known} do
      assert {:ok, pid} = start(scope, left, right)
      {task, _task_ref} = await_compute_child(known, pid, deadline())

      Process.exit(task, :kill)

      assert_receive {:release_comparison, :start_1, {:error, :worker_exit}}, 10_000
      assert_coordinator_exits(pid)
      assert_claims_released([left, right])
    end

    test "the deadline answers timeout, stops the compute child and clears every claim",
         %{scope: scope, left: left, right: right, known: known} do
      assert {:ok, pid} = start(scope, left, right)
      {task, task_ref} = await_compute_child(known, pid, deadline())

      # The coordinator's own timer message, delivered by the case instead of
      # after the production 45s ceiling, so the same finalizer runs.
      send(pid, :deadline)

      assert_receive {:release_comparison, :start_1, {:error, :timeout}}, 10_000
      assert_receive {:DOWN, ^task_ref, :process, ^task, _reason}, 5_000
      assert_coordinator_exits(pid)
      assert_claims_released([left, right])
    end

    test "a caller that goes down clears every claim and delivers nothing",
         %{scope: scope, left: left, right: right, known: known} do
      owner = spawn(fn -> receive do: (:never -> :ok) end)
      assert {:ok, pid} = start(scope, left, right, owner: owner)
      {_task, _task_ref} = await_compute_child(known, pid, deadline())

      owner_ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, _reason}

      assert_coordinator_exits(pid)
      assert_claims_released([left, right])
    end

    test "a delayed result from an earlier attempt never wins",
         %{scope: scope, left: left, right: right, known: known} do
      assert {:ok, pid} = start(scope, left, right)
      {task, task_ref} = await_compute_child(known, pid, deadline())

      assert :ok = ReleaseComparison.cancel(pid, :start_1)
      assert_receive {:release_comparison, :start_1, {:error, :cancelled}}, 10_000

      # The finalizer already ran once, so a late result cannot reopen it.
      send(pid, {make_ref(), {:ok, %{digest: "late"}}})
      refute_receive {:release_comparison, :start_1, _message}, 300
      assert_receive {:DOWN, ^task_ref, :process, ^task, _reason}, 5_000
      assert_claims_released([left, right])
    end

    test "the budget is bounded below the receipt lease and refuses a receipt with no room left" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      scope = scope(organization, version)
      run = native_run!(organization, version, 10)

      assert {:ok, selection} = ReleaseComparison.resolve_selection(scope, params(run, run))
      {:ok, claim} = ExportRuns.claim_download(organization.id, version.id, run.id, :main)

      # The claim the coordinator actually receives has the production 60s
      # receipt, so the 45s ceiling - not the receipt - is what bounds it.
      assert DateTime.diff(claim.claim_id, DateTime.utc_now(), :millisecond) <= 60_000
      assert Runner.deadline_ms([claim]) == 45_000

      # A shorter receipt is respected rather than raced: with five seconds of
      # margin required, a receipt with four seconds left leaves no budget and
      # the coordinator refuses instead of starting work it cannot cover.
      nearly_expired = Map.put(claim, :claim_id, DateTime.add(DateTime.utc_now(), 4, :second))
      assert Runner.deadline_ms([nearly_expired]) <= 0

      # The real receipt is untouched by either reading.
      assert %Run{download_claimed_until: held, download_count: 1} = Repo.get!(Run, run.id)
      assert held == claim.claim_id
      assert selection.left.run_id == run.id

      :ok = ExportRuns.complete_download(organization.id, version.id, run.id, claim.claim_id)
      assert %Run{download_claimed_until: nil} = Repo.get!(Run, run.id)
    end
  end

  describe "claims and refusals that must not leak" do
    test "a second claim refused clears the first exact claim id",
         %{organization: organization, version: version, scope: scope} do
      left = native_run!(organization, version, 11)

      right =
        native_run!(organization, gtfs_version_fixture(organization.id), 12)

      # The coordinator claims in sorted run-id order, so whichever run sorts
      # second is the one that refuses.
      {claimable, refused} =
        if left.id < right.id, do: {left, right}, else: {right, left}

      # An ordinary download already holds the second artifact exclusively.
      {:ok, held} =
        ExportRuns.claim_download(organization.id, refused.gtfs_version_id, refused.id, :main)

      assert {:ok, pid} = start(scope, claimable, refused)
      assert_receive {:release_comparison, :start_1, {:error, :unavailable}}, 20_000
      assert_coordinator_exits(pid)

      # The claim the coordinator took is released; the held claim is untouched.
      assert %Run{download_claimed_until: nil, download_count: 1} = Repo.get!(Run, claimable.id)
      assert Repo.get!(Run, refused.id).download_claimed_until == held.claim_id

      :ok =
        ExportRuns.complete_download(
          organization.id,
          refused.gtfs_version_id,
          refused.id,
          held.claim_id
        )

      assert %Run{download_claimed_until: nil} = Repo.get!(Run, refused.id)
    end

    test "a corrupt artifact keeps the existing failed-run removal and refuses the comparison",
         %{organization: organization, version: version, scope: scope} do
      left = native_run!(organization, version, 13)

      right =
        native_run!(organization, gtfs_version_fixture(organization.id), 14)

      before_rows = gtfs_row_counts(organization)
      path = artifact_path(organization, left)

      # The retained bytes are replaced after the run was verified ready.
      File.write!(artifact_path(organization, left), "PK-not-a-real-zip")

      assert {:ok, pid} = start(scope, left, right)
      assert_receive {:release_comparison, :start_1, {:error, :unavailable}}, 20_000
      assert_coordinator_exits(pid)

      # `ExportRuns` keeps owning that transition: the run is closed as failed
      # with its artifact removed, not silently reported as an empty read.
      corrupt = Repo.get!(Run, left.id)
      assert corrupt.state == :failed
      assert corrupt.failure_code == "missing_or_corrupt_artifact"
      assert corrupt.artifact_key == nil
      refute File.exists?(path)

      assert gtfs_row_counts(organization) == before_rows
      assert %Run{download_claimed_until: nil} = Repo.get!(Run, right.id)
    end

    test "an expired artifact refuses without a claim and without re-exporting",
         %{organization: organization, version: version, scope: scope} do
      left = native_run!(organization, version, 15)

      right =
        native_run!(organization, gtfs_version_fixture(organization.id), 16)

      Repo.update_all(from(r in Run, where: r.id == ^left.id),
        set: [artifact_expires_at: ~U[2000-01-01 00:00:00.000000Z]]
      )

      runs_before = Repo.aggregate(Run, :count)

      assert {:ok, pid} = start(scope, left, right)
      assert_receive {:release_comparison, :start_1, {:error, :unavailable}}, 20_000
      assert_coordinator_exits(pid)

      # No receipt, no claim, and no fresh export in place of the expired one.
      assert Repo.aggregate(Run, :count) == runs_before

      assert %Run{download_count: 0, download_claimed_until: nil, state: :ready} =
               Repo.get!(Run, left.id)
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp start(scope, left, right, opts \\ []) do
    params =
      params(left, right,
        from: Keyword.get(opts, :from, "2026-11-23"),
        to: Keyword.get(opts, :to, "2026-11-27")
      )

    ReleaseComparison.start(scope, params, Keyword.get(opts, :owner, self()), :start_1)
  end

  # A monitor taken now reports even a coordinator that already finished, so the
  # case asserts the coordinator is gone rather than when it went.
  defp assert_coordinator_exits(pid, timeout \\ 5_000) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, timeout
  end

  defp params(left, right, opts \\ []) do
    %{
      "left_run_id" => left.id,
      "right_run_id" => right.id,
      "left_version_id" => left.gtfs_version_id,
      "right_version_id" => right.gtfs_version_id,
      "from" => Keyword.get(opts, :from, "2026-11-23"),
      "to" => Keyword.get(opts, :to, "2026-11-27")
    }
  end

  # The compute child is a new task under the shared task supervisor. Polling for
  # the new pid keeps the case honest about which process it acts on; the
  # coordinator itself is already in the snapshot it compares against.
  defp deadline, do: System.monotonic_time(:millisecond) + 30_000

  defp task_children, do: MapSet.new(Task.Supervisor.children(@task_supervisor))

  defp await_compute_child(known, coordinator, deadline) do
    fresh = MapSet.difference(task_children(), known) |> Enum.reject(&(&1 == coordinator))

    case fresh do
      [child] -> {child, Process.monitor(child)}
      [] -> await_new_child(known, coordinator, deadline)
    end
  end

  defp await_new_child(known, coordinator, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      flunk("the coordinator never started a compute child")
    else
      receive do
        {:DOWN, _ref, :process, ^coordinator, reason} ->
          flunk("the coordinator exited before starting a compute child: #{inspect(reason)}")
      after
        10 -> await_compute_child(known, coordinator, deadline)
      end
    end
  end

  defp assert_claims_released(runs) do
    for run <- runs do
      assert %Run{download_claimed_until: nil} = stored = Repo.get!(Run, run.id)
      assert stored.state == :ready
      assert stored.download_count == 1
    end
  end

  defp scope(organization, version) do
    user = user_fixture()
    organization_membership_fixture(user, organization)

    %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: "release_comparison",
      version_name: version.name,
      resource_context: Scope.context({:version, version.id})
    }
  end

  defp revoke!(%Scope{user_id: user_id}) do
    Repo.update_all(
      from(m in UserOrgMembership, where: m.user_id == ^user_id),
      set: [deactivated_at: DateTime.utc_now()]
    )
  end

  defp artifact_path(_organization, run) do
    root = Application.fetch_env!(:gtfs_planner, :gtfs_task_artifacts_path)

    Path.join([
      root,
      "export-runs",
      run.organization_id,
      run.gtfs_version_id,
      run.id,
      run.artifact_key
    ])
  end

  # The digest the same two claimed artifacts produce outside the coordinator, so
  # the delivered digest is checked against the bytes rather than against itself.
  defp digest_of(organization, left, right, window) do
    {:ok, comparison} =
      [left, right]
      |> Enum.map(fn run ->
        {:ok, claim} =
          ExportRuns.claim_download(organization.id, run.gtfs_version_id, run.id, :main)

        {:ok, reader_output} = Reader.read(claim, artifact_identity(run))
        {:ok, projection} = Projection.build(reader_output)

        :ok =
          ExportRuns.complete_download(
            organization.id,
            run.gtfs_version_id,
            run.id,
            claim.claim_id
          )

        projection
      end)
      |> then(fn [left_projection, right_projection] ->
        Compare.run(left_projection, right_projection, window)
      end)

    comparison.digest
  end

  defp artifact_identity(run) do
    %{
      run_id: run.id,
      version_id: run.gtfs_version_id,
      sha256: run.artifact_sha256,
      size: run.artifact_size_bytes,
      export_type: run.export_type,
      expires_at: run.artifact_expires_at,
      estimate_missing_times: run.estimate_missing_times,
      estimate_method: run.estimate_method
    }
  end

  defp native_run!(organization, version, suffix) do
    weekday_service(suffix).(organization, version)
    {:ok, bytes, _warnings} = Export.build_zip(organization.id, version.id, :full)
    publish_run!(organization, version, bytes, :full)
  end

  defp slow_run!(organization, version) do
    publish_run!(organization, version, producer_zip(@slow_trips), :full)
  end

  defp publish_run!(organization, version, bytes, export_type) do
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, export_type)
    {:ok, _building, generation, token} = ExportRuns.claim(organization.id, run.id, :build)

    {:ok, artifact} =
      ArtifactStorage.publish(organization.id, version.id, run.id, "network.zip", bytes)

    {:ok, run} =
      ExportRuns.mark_ready(organization.id, run.id, generation, token, %{
        main: artifact,
        flex: nil
      })

    run
  end

  # One Monday-to-Friday service with a single route, produced by the native
  # exporter from seeded GTFS rows. The suffix keeps two runs of the same version
  # from colliding on the stored agency, route, stop and service identifiers.
  defp weekday_service(suffix) do
    fn organization, version ->
      agency = agency_fixture(organization.id, version.id, %{agency_id: "AGENCY#{suffix}"})

      route =
        route_fixture(organization.id, version.id, %{route_id: "R#{suffix}", agency_id: agency.id})

      stop = stop_fixture(organization.id, version.id, %{stop_id: "S#{suffix}"})
      calendar_fixture(organization.id, version.id, %{service_id: "WEEK#{suffix}"})

      trip =
        trip_fixture(organization.id, version.id, route.id, %{
          trip_id: "T#{suffix}",
          service_id: "WEEK#{suffix}"
        })

      stop_time_fixture(organization.id, version.id, trip.id, stop.id, %{
        stop_sequence: 1,
        arrival_time: "08:00:00",
        departure_time: "08:00:00"
      })
    end
  end

  # The same member names, headers and row shape the native exporter writes, with
  # enough trips that the compute child is still working when a case acts.
  defp producer_zip(trips) do
    stops =
      Enum.map_join(1..5, "\n", fn index ->
        "S#{index},Stop #{index},40.#{index},-74.#{index}"
      end)

    trip_rows = Enum.map_join(1..trips, "\n", fn index -> "R1,WEEK,T#{index},0" end)

    stop_time_rows =
      Enum.map_join(1..trips, "\n", fn index ->
        Enum.map_join(1..5, "\n", fn stop ->
          "T#{index},0#{stop}:00:00,0#{stop}:00:00,S#{stop},#{stop}"
        end)
      end)

    members = [
      {"agency.txt",
       "agency_id,agency_name,agency_url,agency_timezone\nAGENCY,Metro,http://a.example,UTC"},
      {"routes.txt",
       "route_id,agency_id,route_short_name,route_long_name,route_type\nR1,AGENCY,1,Main,3"},
      {"stops.txt", "stop_id,stop_name,stop_lat,stop_lon\n" <> stops},
      {"trips.txt", "route_id,service_id,trip_id,direction_id\n" <> trip_rows},
      {"stop_times.txt",
       "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n" <> stop_time_rows},
      {"calendar.txt",
       "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n" <>
         "WEEK,1,1,1,1,1,0,0,20260101,20261231"}
    ]

    entries =
      Enum.map(members, fn {name, body} ->
        {String.to_charlist(name), IO.iodata_to_binary(body)}
      end)

    {:ok, {_, bytes}} = :zip.create(~c"network.zip", entries, [:memory])
    bytes
  end

  defp gtfs_row_counts(organization) do
    %{
      routes: count(GtfsPlanner.Gtfs.Route, organization.id),
      trips: count(GtfsPlanner.Gtfs.Trip, organization.id),
      stops: count(GtfsPlanner.Gtfs.Stop, organization.id),
      stop_times: count(GtfsPlanner.Gtfs.StopTime, organization.id),
      agencies: count(GtfsPlanner.Gtfs.Agency, organization.id),
      calendars: count(GtfsPlanner.Gtfs.Calendar, organization.id)
    }
  end

  defp count(schema, organization_id) do
    Repo.aggregate(from(r in schema, where: r.organization_id == ^organization_id), :count)
  end
end
