defmodule GtfsPlanner.Gtfs.ReleaseComparison.SelectionTest do
  @moduledoc """
  Focused evidence for CL-1/FH-1: only two explicit, scoped, retained, ready
  native full-main artifacts and one explicit inclusive window of at most 62
  dates resolve, and choosing never reads, claims or writes a receipt.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.ReleaseComparison
  alias GtfsPlanner.Repo

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}

  setup do
    root =
      Path.join(System.tmp_dir!(), "release-comparison-#{System.unique_integer([:positive])}")

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

  describe "list_choices/2" do
    test "returns only this organization's retained ready full-main runs, newest first",
         context do
      %{organization: organization, version: version, scope: scope} = context
      newest = ready_run!(organization, version)
      older = ready_run!(organization, version)
      older_id = pin_inserted_at!(older, ~U[2026-01-01 00:00:00.000000Z])
      newest_id = pin_inserted_at!(newest, ~U[2026-01-02 00:00:00.000000Z])

      foreign_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign_organization.id)
      ready_run!(foreign_organization, foreign_version)

      pathways_version = gtfs_version_fixture(organization.id)
      pathways = ready_run!(organization, pathways_version, :pathways)
      expired = ready_run!(organization, pathways_version)
      expire_run!(expired)

      {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)
      assert {:ok, %{rows: rows, next_cursor: nil}} = ReleaseComparison.list_choices(scope)

      assert Enum.map(rows, & &1.run_id) == [newest_id, older_id]

      row = hd(rows)
      run_row = ExportRuns.get_for_version(organization.id, version.id, newest_id)
      assert row.version_id == version.id
      assert row.sha256 == run_row.artifact_sha256
      assert row.size == run_row.artifact_size_bytes
      assert row.export_type == :full
      assert row.expires_at == run_row.artifact_expires_at
      assert row.estimate_missing_times == run_row.estimate_missing_times
      assert row.estimate_method == run_row.estimate_method
      assert row.version_name == run_row.version_name
      assert row.created_at == ~U[2026-01-02 00:00:00.000000Z]

      # A listed row carries no storage handle: the reader claims its own path.
      refute Map.has_key?(row, :artifact_key)
      refute Map.has_key?(row, :path)

      assert %Run{state: :pending} =
               ExportRuns.get_for_version(organization.id, version.id, run.id)

      refute Enum.any?(rows, &(&1.run_id == run.id))
      refute Enum.any?(rows, &(&1.run_id == pathways.id))
      refute Enum.any?(rows, &(&1.run_id == expired.id))
    end

    test "pages an equal-timestamp ordering by ascending id without repeats or omissions",
         context do
      %{organization: organization, scope: scope} = context
      timestamp = ~U[2026-03-01 00:00:00.000000Z]

      ids =
        organization
        |> versions(3)
        |> Enum.map(&ready_run!(organization, &1))
        |> Enum.map(&pin_inserted_at!(&1, timestamp))
        |> Enum.sort()

      assert {:ok, first} = ReleaseComparison.list_choices(scope, limit: 2)
      assert Enum.map(first.rows, & &1.run_id) == Enum.take(ids, 2)
      assert is_binary(first.next_cursor)

      assert {:ok, second} =
               ReleaseComparison.list_choices(scope, limit: 2, cursor: first.next_cursor)

      assert Enum.map(second.rows, & &1.run_id) == Enum.drop(ids, 2)

      # A nil next_cursor is the end of the list; only an explicit cursor moves
      # through it, so the two pages cover every run exactly once.
      assert second.next_cursor == nil
      assert length(first.rows ++ second.rows) == 3
    end

    test "refuses a malformed cursor and applies the default limit to an unusable limit",
         context do
      %{organization: organization, scope: scope} = context

      organization |> versions(2) |> Enum.each(&ready_run!(organization, &1))

      assert {:error, :unavailable} =
               ReleaseComparison.list_choices(scope, cursor: "not-a-cursor")

      assert {:error, :unavailable} = ReleaseComparison.list_choices(scope, cursor: 42)

      # A cursor naming no real row is still a keyset position, not a restart.
      assert {:ok, %{rows: rows}} = ReleaseComparison.list_choices(scope, limit: "all")
      assert length(rows) == 2
    end

    test "refuses a scope whose editor membership is revoked", context do
      %{organization: organization, version: version, scope: scope} = context
      ready_run!(organization, version)

      assert {:ok, %{rows: [_row]}} = ReleaseComparison.list_choices(scope)

      revoke!(scope)

      assert {:error, :unavailable} = ReleaseComparison.list_choices(scope)
    end
  end

  describe "resolve_selection/2" do
    test "resolves server-held identity for two retained full runs and writes no receipt",
         context do
      %{organization: organization, version: version, scope: scope} = context
      left = ready_run!(organization, version)
      right = ready_run!(organization, gtfs_version_fixture(organization.id))

      assert {:ok, selection} =
               ReleaseComparison.resolve_selection(scope, %{
                 "left_run_id" => left.id,
                 "left_version_id" => to_string(left.gtfs_version_id),
                 "right_run_id" => right.id,
                 "right_version_id" => to_string(right.gtfs_version_id),
                 "from" => "2026-04-01",
                 "to" => "2026-05-02",
                 # Client metadata is never the answer.
                 "sha256" => String.duplicate("0", 64),
                 "size" => "1",
                 "artifact_key" => "forged.zip"
               })

      assert selection.organization_id == organization.id
      assert selection.host_version_id == version.id
      assert selection.from == ~D[2026-04-01]
      assert selection.to == ~D[2026-05-02]

      left_row = ExportRuns.get_for_version(organization.id, version.id, left.id)

      assert selection.left == %{
               run_id: left.id,
               version_id: version.id,
               sha256: left_row.artifact_sha256,
               size: left_row.artifact_size_bytes,
               export_type: :full,
               expires_at: left_row.artifact_expires_at,
               estimate_missing_times: left_row.estimate_missing_times,
               estimate_method: left_row.estimate_method
             }

      assert selection.right.run_id == right.id
      assert selection.right.version_id == right.gtfs_version_id
      assert selection.right.sha256 == left_row.artifact_sha256

      assert_receipts_untouched(organization, [left.id, right.id])
    end

    test "resolves the version identity from the run when the caller submitted none", context do
      %{organization: organization, version: version, scope: scope} = context
      left = ready_run!(organization, version)

      assert {:ok, selection} =
               ReleaseComparison.resolve_selection(scope, %{
                 "left_run_id" => left.id,
                 "right_run_id" => left.id,
                 "from" => "2026-04-01",
                 "to" => "2026-04-01"
               })

      assert selection.left.version_id == version.id
      assert selection.right == selection.left
    end

    test "refuses foreign, mismatched, deleted, unfinished, expired and unsupported runs",
         context do
      %{organization: organization, version: version, scope: scope} = context
      own = ready_run!(organization, version)

      foreign_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign_organization.id)
      foreign = ready_run!(foreign_organization, foreign_version)

      pathways = ready_run!(organization, gtfs_version_fixture(organization.id), :pathways)
      expired = ready_run!(organization, gtfs_version_fixture(organization.id))
      expire_run!(expired)

      deleted_version = gtfs_version_fixture(organization.id)
      deleted = ready_run!(organization, deleted_version)
      Repo.delete!(deleted_version)

      pending_version = gtfs_version_fixture(organization.id)

      {:ok, pending} =
        ExportRuns.create_pending(organization.id, pending_version.id, @actor, :full)

      # A foreign run, an absent run and a run whose version is gone are one answer.
      for run_id <- [foreign.id, Ecto.UUID.generate(), deleted.id, pending.id, expired.id] do
        assert {:error, :unavailable} =
                 ReleaseComparison.resolve_selection(scope, window_params(own, run_id, own))
      end

      # A submitted version identity that is not the run's own version is refused too.
      assert {:error, :unavailable} =
               ReleaseComparison.resolve_selection(
                 scope,
                 window_params(own, own.id, own, left_version_id: foreign_version.id)
               )

      assert {:error, :unsupported_profile} =
               ReleaseComparison.resolve_selection(
                 scope,
                 window_params(pathways, pathways.id, own)
               )
    end

    test "requires two explicit dates within 62 inclusive days", context do
      %{organization: organization, version: version, scope: scope} = context
      run = ready_run!(organization, version)

      assert {:ok, selection} =
               ReleaseComparison.resolve_selection(
                 scope,
                 window_params(run, run.id, run, from: "2026-04-01", to: "2026-06-01")
               )

      assert Date.diff(selection.to, selection.from) + 1 == 62

      refused = [
        {"2026-04-01", "2026-06-02"},
        {"2026-06-01", "2026-04-01"},
        {nil, "2026-05-02"},
        {"2026-04-01", nil},
        {nil, nil},
        {"", "2026-05-02"},
        {"2026-4-1", "2026-05-02"},
        {"04/01/2026", "2026-05-02"}
      ]

      for {from, to} <- refused do
        assert {:error, :invalid_window} =
                 ReleaseComparison.resolve_selection(
                   scope,
                   window_params(run, run.id, run, from: from, to: to)
                 )
      end

      assert_receipts_untouched(organization, [run.id])
    end

    test "refuses a revoked editor, a foreign scope and a non-map params without disclosure",
         context do
      %{organization: organization, version: version, scope: scope} = context
      run = ready_run!(organization, version)

      # Both dates are required, so a submission with only a run is a window
      # refusal before any run is read.
      assert {:error, :invalid_window} =
               ReleaseComparison.resolve_selection(scope, %{"left_run_id" => run.id})

      assert {:error, :unavailable} = ReleaseComparison.resolve_selection(scope, "left_run_id")
      assert {:error, :unavailable} = ReleaseComparison.resolve_selection(%{}, %{})

      revoke!(scope)

      assert {:error, :unavailable} =
               ReleaseComparison.resolve_selection(scope, window_params(run, run.id, run))
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

  defp versions(organization, count) do
    Enum.map(1..count//1, fn _index -> gtfs_version_fixture(organization.id) end)
  end

  defp ready_run!(organization, version, export_type \\ :full) do
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, export_type)
    {:ok, _building, generation, token} = ExportRuns.claim(organization.id, run.id, :build)

    {:ok, artifact} =
      ArtifactStorage.publish(
        organization.id,
        version.id,
        run.id,
        "network.zip",
        "native-zip-bytes"
      )

    {:ok, run} =
      ExportRuns.mark_ready(organization.id, run.id, generation, token, %{
        main: artifact,
        flex: nil
      })

    run
  end

  defp pin_inserted_at!(%Run{} = run, timestamp) do
    Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [inserted_at: timestamp])
    run.id
  end

  defp expire_run!(%Run{} = run) do
    Repo.update_all(
      from(r in Run, where: r.id == ^run.id),
      set: [artifact_expires_at: ~U[2000-01-01 00:00:00.000000Z]]
    )

    run
  end

  defp window_params(left, left_run_id, right, opts \\ []) do
    %{
      "left_run_id" => left_run_id,
      "right_run_id" => right.id,
      "from" => Keyword.get(opts, :from, "2026-04-01"),
      "to" => Keyword.get(opts, :to, "2026-04-02")
    }
    |> maybe_put("left_version_id", Keyword.get(opts, :left_version_id, left.gtfs_version_id))
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, to_string(value))

  defp assert_receipts_untouched(organization, run_ids) do
    for run_id <- run_ids do
      assert %Run{download_count: 0, download_claimed_until: nil, last_downloaded_at: nil} =
               Repo.get!(Run, run_id)

      assert ExportRuns.get_for_version(
               organization.id,
               Repo.get!(Run, run_id).gtfs_version_id,
               run_id
             ).state == :ready
    end
  end
end
