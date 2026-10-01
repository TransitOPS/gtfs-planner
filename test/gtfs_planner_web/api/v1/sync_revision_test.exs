defmodule GtfsPlannerWeb.Api.V1.SyncRevisionTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.ConcurrencyHelpers
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.{User, UserOrgMembership}
  alias GtfsPlanner.Gtfs.{ChangeLog, JournalEntry, Pathway, Stop}
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @rendezvous_timeout 10_000
  @collect_timeout 15_000

  setup do
    org = organization_fixture()
    version = gtfs_version_fixture(org.id)
    user = editor_fixture(org)
    station = stop_fixture(org.id, version.id, location_type: 1)
    from = child_stop_fixture(org.id, version.id, station.stop_id)
    to = child_stop_fixture(org.id, version.id, station.stop_id)
    pathway = pathway_fixture(org.id, version.id, from.stop_id, to.stop_id)
    token = Accounts.generate_api_session_token(user)

    %{
      org: org,
      version: version,
      user: user,
      station: station,
      from: from,
      to: to,
      pathway: pathway,
      token: token
    }
  end

  test "bundle revisions round-trip through sync, and replay writes no second history", scope do
    second =
      pathway_fixture(scope.org.id, scope.version.id, scope.from.stop_id, scope.to.stop_id)

    initial = bundle(scope)
    initial_revision = bundle_pathway(initial, scope.pathway.id)["revision"]
    second_revision = bundle_pathway(initial, second.id)["revision"]
    assert initial_revision == Repo.get!(Pathway, scope.pathway.id).lock_version
    assert second_revision == Repo.get!(Pathway, second.id).lock_version

    body = %{
      "pathways" => [
        %{"id" => scope.pathway.id, "revision" => initial_revision, "traversal_time" => 45},
        %{"id" => second.id, "revision" => second_revision, "field_notes" => "inspected"}
      ]
    }

    response = sync(scope, body)

    assert %{
             "data" => %{
               "synced_count" => 2,
               "revisions" => [
                 %{"id" => id, "revision" => new_revision},
                 %{"id" => second_id, "revision" => second_new_revision}
               ]
             }
           } = json_response(response, 200)

    assert id == scope.pathway.id
    assert second_id == second.id
    assert new_revision == initial_revision + 1
    assert second_new_revision == second_revision + 1
    assert Repo.get!(Pathway, id).lock_version == new_revision
    assert Repo.get!(Pathway, id).traversal_time == 45
    assert Repo.get!(Pathway, second_id).field_notes == "inspected"
    assert bundle_pathway(bundle(scope), id)["revision"] == new_revision
    assert bundle_pathway(bundle(scope), second_id)["revision"] == second_new_revision
    assert change_log_count(scope, id) == 1
    assert change_log_count(scope, second_id) == 1

    replay = sync(scope, body)

    assert %{
             "data" => %{
               "synced_count" => 0,
               "revisions" => [],
               "errors" => [
                 %{"id" => ^id, "code" => "stale", "current_revision" => ^new_revision},
                 %{
                   "id" => ^second_id,
                   "code" => "stale",
                   "current_revision" => ^second_new_revision
                 }
               ]
             }
           } = json_response(replay, 200)

    assert change_log_count(scope, id) == 1
    assert change_log_count(scope, second_id) == 1
    assert Repo.get!(Pathway, id).lock_version == new_revision
    assert Repo.get!(Pathway, second_id).lock_version == second_new_revision
  end

  test "missing and string revisions fail per entry without a write", scope do
    second =
      pathway_fixture(scope.org.id, scope.version.id, scope.from.stop_id, scope.to.stop_id)

    body = %{
      "pathways" => [
        %{"id" => scope.pathway.id, "field_notes" => "must not persist"},
        %{"id" => second.id, "revision" => "3", "field_notes" => "invalid"}
      ]
    }

    assert %{
             "data" => %{
               "synced_count" => 0,
               "revisions" => [],
               "errors" => [%{"code" => "invalid_revision"}, %{"code" => "invalid_revision"}]
             }
           } = sync(scope, body) |> json_response(200)

    assert Repo.get!(Pathway, scope.pathway.id).field_notes != "must not persist"
    assert Repo.get!(Pathway, second.id).field_notes != "invalid"
    assert change_log_count(scope, scope.pathway.id) == 0
    assert change_log_count(scope, second.id) == 0
  end

  test "more than 100 pathways reject the whole envelope before writes", scope do
    first = %{
      "id" => scope.pathway.id,
      "revision" => scope.pathway.lock_version,
      "traversal_time" => 61
    }

    other = fn -> %{"id" => Ecto.UUID.generate(), "revision" => 1} end
    journal_id = Ecto.UUID.generate()

    body = %{
      "pathways" => [first | Enum.map(1..100, fn _ -> other.() end)],
      "journal_entries" => [
        %{
          "id" => journal_id,
          "target_type" => "station",
          "captured_at" => "2025-06-01T12:00:00Z"
        }
      ]
    }

    assert %{
             "error" => %{
               "code" => "bad_request",
               "message" => "Request may include at most 100 pathways."
             }
           } = sync(scope, body) |> json_response(400)

    assert Repo.get!(Pathway, scope.pathway.id).traversal_time != 61
    assert change_log_count(scope, scope.pathway.id) == 0
    assert Repo.get(JournalEntry, journal_id) == nil
  end

  test "duplicate pathway IDs reject the whole envelope before writes", scope do
    entry = %{
      "id" => scope.pathway.id,
      "revision" => scope.pathway.lock_version,
      "traversal_time" => 61
    }

    assert %{
             "error" => %{
               "code" => "bad_request",
               "message" => "Each pathway may appear once per request."
             }
           } = sync(scope, %{"pathways" => [entry, entry]}) |> json_response(400)

    assert Repo.get!(Pathway, scope.pathway.id).traversal_time != 61
    assert change_log_count(scope, scope.pathway.id) == 0
  end

  test "a request body over 8,000,000 bytes returns 413 before any write", scope do
    conn =
      scope
      |> authed_conn()
      |> post(sync_url(scope), String.duplicate(" ", 8_000_001))

    assert conn.status == 413
    assert change_log_count(scope, scope.pathway.id) == 0
  end

  test "swapping endpoints succeeds and another pair is refused without a write", scope do
    first = %{
      "id" => scope.pathway.id,
      "revision" => scope.pathway.lock_version,
      "from_stop_id" => scope.pathway.to_stop_id,
      "to_stop_id" => scope.pathway.from_stop_id
    }

    assert %{"data" => %{"revisions" => [%{"revision" => revision}]}} =
             sync(scope, %{"pathways" => [first]}) |> json_response(200)

    swapped = Repo.get!(Pathway, scope.pathway.id)

    assert {swapped.from_stop_id, swapped.to_stop_id} ==
             {scope.pathway.to_stop_id, scope.pathway.from_stop_id}

    second = %{
      "id" => scope.pathway.id,
      "revision" => revision,
      "from_stop_id" => "outside-station",
      "to_stop_id" => swapped.to_stop_id,
      "field_notes" => "must not persist"
    }

    assert %{"data" => %{"errors" => [%{"code" => "invalid_endpoints"}]}} =
             sync(scope, %{"pathways" => [second]}) |> json_response(200)

    assert Repo.get!(Pathway, scope.pathway.id).field_notes != "must not persist"
    assert change_log_count(scope, scope.pathway.id) == 1
  end

  @tag :unboxed
  test "revocation queued behind the first pathway write forbids remaining entries", _scope do
    # This case uses committed rows because separate database connections must see
    # the row locks. Its own records are deleted by id in on_exit.
    scope = unboxed(&seed_unboxed_scope/0)
    on_exit(fn -> unboxed(fn -> cleanup_unboxed_scope(scope) end) end)
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
    parent = self()

    holder =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            Repo.one!(
              from(p in Pathway, where: p.id == ^scope.pathways.p1.id, lock: "FOR UPDATE")
            )

            send(parent, {:holder_ready, backend_pid()})
            await_release()
          end)
        end)
      end)

    assert_receive {:holder_ready, holder_backend}, @rendezvous_timeout

    request =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          Repo.checkout(fn ->
            send(parent, {:request_ready, backend_pid()})

            sync(scope, %{
              "pathways" =>
                Enum.map([scope.pathways.p1, scope.pathways.p2, scope.pathways.p3], fn p ->
                  %{"id" => p.id, "revision" => p.lock_version, "traversal_time" => 75}
                end)
            })
          end)
        end)
      end)

    assert_receive {:request_ready, request_backend}, @rendezvous_timeout
    assert :ok == unboxed(fn -> await_blocker(request_backend, holder_backend, deadline()) end)

    revocation =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          Repo.checkout(fn ->
            send(parent, {:revocation_ready, backend_pid()})

            Organizations.deactivate_user_in_organization(
              scope.admin,
              scope.user.id,
              scope.org.id
            )
          end)
        end)
      end)

    assert_receive {:revocation_ready, revocation_backend}, @rendezvous_timeout

    assert :ok ==
             unboxed(fn -> await_blocker(revocation_backend, request_backend, deadline()) end)

    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, @collect_timeout)

    assert {:ok, %UserOrgMembership{deactivated_at: %DateTime{}}} =
             Task.await(revocation, @collect_timeout)

    assert %{
             "data" => %{
               "synced_count" => 1,
               "revisions" => [%{"id" => p1_id}],
               "errors" => [
                 %{"id" => p2_id, "code" => "forbidden"},
                 %{"id" => p3_id, "code" => "forbidden"}
               ]
             }
           } = request |> Task.await(@collect_timeout) |> json_response(200)

    assert {p1_id, p2_id, p3_id} ==
             {scope.pathways.p1.id, scope.pathways.p2.id, scope.pathways.p3.id}

    assert unboxed(fn -> Repo.get!(Pathway, p1_id).traversal_time end) == 75
    assert unboxed(fn -> Repo.get!(Pathway, p2_id).traversal_time end) != 75
    assert unboxed(fn -> Repo.get!(Pathway, p3_id).traversal_time end) != 75
    assert unboxed(fn -> change_log_count(scope, p1_id) end) == 1
    assert unboxed(fn -> change_log_count(scope, p2_id) end) == 0
    assert unboxed(fn -> change_log_count(scope, p3_id) end) == 0
  end

  defp seed_unboxed_scope do
    org = organization_fixture()
    version = gtfs_version_fixture(org.id)
    user = editor_fixture(org)
    admin = system_admin_fixture(org)
    station = stop_fixture(org.id, version.id, location_type: 1)
    from = child_stop_fixture(org.id, version.id, station.stop_id)
    to = child_stop_fixture(org.id, version.id, station.stop_id)

    pathways = %{
      p1: pathway_fixture(org.id, version.id, from.stop_id, to.stop_id),
      p2: pathway_fixture(org.id, version.id, from.stop_id, to.stop_id),
      p3: pathway_fixture(org.id, version.id, from.stop_id, to.stop_id)
    }

    token = Accounts.generate_api_session_token(user)

    %{
      org: org,
      version: version,
      user: user,
      admin: admin,
      station: station,
      pathways: pathways,
      token: token
    }
  end

  defp cleanup_unboxed_scope(scope) do
    org_id = scope.org.id
    Repo.delete_all(from(row in ChangeLog, where: row.organization_id == ^org_id))
    Repo.delete_all(from(row in Pathway, where: row.organization_id == ^org_id))
    Repo.delete_all(from(row in Stop, where: row.organization_id == ^org_id))
    Repo.delete_all(from(row in UserOrgMembership, where: row.organization_id == ^org_id))
    Repo.delete_all(from(row in GtfsVersion, where: row.organization_id == ^org_id))
    Repo.delete_all(from(row in Organization, where: row.id == ^org_id))
    Repo.delete_all(from(row in User, where: row.id in ^[scope.user.id, scope.admin.id]))
  end

  defp await_release do
    receive do
      :release -> :ok
    after
      @rendezvous_timeout -> raise "pathway row lock was not released"
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + @rendezvous_timeout

  defp bundle(scope) do
    scope
    |> authed_conn()
    |> get("/api/v1/versions/#{scope.version.id}/stations/#{scope.station.id}/bundle")
    |> json_response(200)
  end

  defp bundle_pathway(%{"data" => %{"pathways" => pathways}}, id) do
    Enum.find(pathways, &(&1["id"] == id))
  end

  defp sync(scope, body), do: scope |> authed_conn() |> post(sync_url(scope), body)

  defp authed_conn(scope) do
    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{scope.token}")
  end

  defp sync_url(scope),
    do: "/api/v1/versions/#{scope.version.id}/stations/#{scope.station.id}/sync"

  defp change_log_count(scope, id) do
    ChangeLog
    |> where([log], log.organization_id == ^scope.org.id and log.entity_id == ^id)
    |> Repo.aggregate(:count, :id)
  end
end
