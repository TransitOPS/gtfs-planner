defmodule GtfsPlanner.Gtfs.FeedSettings.AgencyReferenceLockTest do
  # The two cases in the last describe block need a version row that an independent session
  # can see, so they commit their fixtures and remove them again from the test process in a
  # `try/after`. Every row this file commits carries a per-call token: the test database is
  # shared with other unboxed tests, and a counter that restarts with each BEAM run collides
  # with the rows those runs committed earlier.
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.FeedSettings
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  @race_timeout 10_000
  @lock_wait_deadline_ms 5_000

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    token = unique_lock_token()

    %{
      organization: organization,
      version: version,
      actor: lock_editor(token, organization)
    }
  end

  describe "route insert under lock_agency_for_reference!/3 (R4, INV-1)" do
    test "refuses a route when the version has no agency", context do
      assert {:error, :agency_required} =
               insert_version_route(context, route_attrs("r1", nil))

      assert {:error, :agency_required} =
               insert_version_route(context, route_attrs("r1", "NCT"))

      assert route_count(context.version) == 0
    end

    test "resolves a nil or blank choice to the version's only agency", context do
      agency_fixture(
        context.organization.id,
        context.version.id,
        agency_attrs("NCT", "North County Transit")
      )

      for {choice, route_id} <- [{nil, "r1"}, {"", "r2"}, {"   ", "r3"}] do
        assert {:ok, route} = insert_version_route(context, route_attrs(route_id, choice))

        assert route.agency_id == "NCT"
        assert route.organization_id == context.organization.id
        assert route.gtfs_version_id == context.version.id
      end

      assert route_count(context.version) == 3
    end

    test "resolves a listed choice and refuses a padded or unknown one", context do
      agency_fixture(
        context.organization.id,
        context.version.id,
        agency_attrs("NCT", "North County Transit")
      )

      assert {:ok, listed} = insert_version_route(context, route_attrs("r1", "NCT"))
      assert listed.agency_id == "NCT"

      # A padded reference is neither blank nor an exact match, so the single-agency blank
      # rule does not swallow it (R5).
      assert {:error, :agency_not_found} =
               insert_version_route(context, route_attrs("r2", " NCT "))

      assert {:error, :agency_not_found} =
               insert_version_route(context, route_attrs("r3", "OTHER"))

      assert route_count(context.version) == 1
    end

    test "refuses a blank or unknown choice when the version has two agencies", context do
      agency_fixture(
        context.organization.id,
        context.version.id,
        agency_attrs("NCT", "North County")
      )

      agency_fixture(context.organization.id, context.version.id, agency_attrs("MTA", "Metro"))

      for choice <- [nil, "", "   ", "UNKNOWN"] do
        assert {:error, :agency_not_found} =
                 insert_version_route(context, route_attrs("r1", choice))
      end

      assert route_count(context.version) == 0

      assert {:ok, listed} = insert_version_route(context, route_attrs("r1", "MTA"))
      assert listed.agency_id == "MTA"
      assert route_count(context.version) == 1
    end

    test "refuses a route naming an agency a deletion has already removed", context do
      alpha =
        agency_fixture(context.organization.id, context.version.id, agency_attrs("A", "Alpha"))

      bravo =
        agency_fixture(context.organization.id, context.version.id, agency_attrs("B", "Bravo"))

      audit = audit_context(context.organization, context.version, context.actor)

      # Alpha has no routes, so the given receiving agency is ignored (R7) and the apply
      # compares the nil target it reviewed.
      assert {:ok, %{target: nil} = review} =
               FeedSettings.review_agency_deletion(audit, alpha.id, bravo.id)

      assert {:ok, %{moved_routes: 0, target: nil}} =
               FeedSettings.delete_agency(audit, alpha.id, bravo.id, review.fingerprint)

      # The deletion committed first, so the stale choice names an agency the version no
      # longer has: this is the reverse of the interleaving order below.
      assert {:error, :agency_not_found} = insert_version_route(context, route_attrs("r1", "A"))

      assert {:ok, route} = insert_version_route(context, route_attrs("r1", nil))
      assert route.agency_id == "B"
      assert Repo.get(Agency, alpha.id) == nil
      assert route_count(context.version) == 1
    end
  end

  describe "lock_agency_for_reference!/3 (R4, INV-2)" do
    test "resolves the single agency for a blank or matching choice", context do
      agency_fixture(
        context.organization.id,
        context.version.id,
        agency_attrs("NCT", "North County Transit")
      )

      assert {:ok, "NCT"} =
               Repo.transaction(fn ->
                 FeedSettings.lock_agency_for_reference!(
                   context.organization.id,
                   context.version.id,
                   nil
                 )
               end)

      assert {:ok, "NCT"} =
               Repo.transaction(fn ->
                 FeedSettings.lock_agency_for_reference!(
                   context.organization.id,
                   context.version.id,
                   "NCT"
                 )
               end)

      assert {:error, :agency_not_found} =
               Repo.transaction(fn ->
                 FeedSettings.lock_agency_for_reference!(
                   context.organization.id,
                   context.version.id,
                   "UNKNOWN"
                 )
               end)

      assert route_count(context.version) == 0
    end

    test "rolls back an empty version and any scope that is not the published one", context do
      assert {:error, :agency_required} =
               Repo.transaction(fn ->
                 FeedSettings.lock_agency_for_reference!(
                   context.organization.id,
                   context.version.id,
                   nil
                 )
               end)

      {:ok, staging} =
        Versions.create_staging_gtfs_version(context.organization.id, %{name: "Staging"})

      for {organization_id, version_id} <- [
            {context.organization.id, staging.id},
            {Ecto.UUID.generate(), context.version.id},
            {context.organization.id, Ecto.UUID.generate()},
            {context.organization.id, "not-a-uuid"},
            {"not-a-uuid", context.version.id}
          ] do
        assert {:error, :not_found} =
                 Repo.transaction(fn ->
                   FeedSettings.lock_agency_for_reference!(organization_id, version_id, nil)
                 end)
      end
    end
  end

  describe "route insert and agency deletion interleaving (INV-2, AC-26)" do
    test "holds the version row so a FOR UPDATE NOWAIT probe cannot take it" do
      start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
      token = unique_lock_token()
      owner = self()

      try do
        scope = seed_committed_scope(token)

        # Control: with no lock held the same probe takes the row, so the failure below is the
        # reference lock and not the probe.
        assert {:ok, %Postgrex.Result{rows: [[_id]]}} =
                 probe_version_row_nowait(scope.version.id)

        holder =
          Task.Supervisor.async_nolink(__MODULE__.TaskSupervisor, fn ->
            unboxed(fn ->
              Repo.transaction(fn ->
                resolved =
                  FeedSettings.lock_agency_for_reference!(
                    scope.organization.id,
                    scope.version.id,
                    "X"
                  )

                send(owner, {:reference_lock_held, self(), resolved})

                receive do
                  :release_reference_lock -> :ok
                end
              end)
            end)
          end)

        assert_receive {:reference_lock_held, holder_pid, "X"}, @race_timeout
        assert holder_pid == holder.pid

        assert {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} =
                 probe_version_row_nowait(scope.version.id)

        send(holder.pid, :release_reference_lock)
        assert {:ok, :ok} = Task.await(holder, @race_timeout)

        # The lock belongs to the transaction, so the row is free again once it committed.
        assert {:ok, %Postgrex.Result{rows: [[_id]]}} =
                 probe_version_row_nowait(scope.version.id)
      after
        stop_race_tasks()
        cleanup_committed_scope(token)
      end
    end

    test "a deletion reviewed before a held route insert waits and then loses" do
      start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
      token = unique_lock_token()
      owner = self()

      try do
        scope = seed_committed_scope(token)

        # Task 1 resolves the agency and inserts the route in one transaction and keeps it open,
        # so the share lock and the uncommitted route row are both outstanding.
        insert_task =
          Task.Supervisor.async_nolink(__MODULE__.TaskSupervisor, fn ->
            unboxed(fn ->
              Repo.transaction(fn ->
                assert {:ok, route} =
                         insert_route_under_reference_lock(
                           scope.organization.id,
                           scope.version.id,
                           route_attrs("x1", "X")
                         )

                send(owner, {:route_inserted, self(), route.id})

                receive do
                  :release_insert -> :ok
                end

                route
              end)
            end)
          end)

        assert_receive {:route_inserted, insert_pid, inserted_route_id}, @race_timeout
        assert insert_pid == insert_task.pid

        # Task 2 applies the review taken before the insert and records the backend it runs on,
        # so the poll watches exactly the session that is waiting.
        delete_task =
          Task.Supervisor.async_nolink(__MODULE__.TaskSupervisor, fn ->
            unboxed(fn ->
              Repo.checkout(fn ->
                %Postgrex.Result{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
                send(owner, {:deletion_backend, self(), backend_pid})

                result =
                  FeedSettings.delete_agency(
                    scope.audit,
                    scope.agencies["X"].id,
                    scope.agencies["Y"].id,
                    scope.review.fingerprint
                  )

                send(owner, {:deletion_result, self(), result})

                result
              end)
            end)
          end)

        assert_receive {:deletion_backend, delete_pid, backend_pid}, @race_timeout
        assert delete_pid == delete_task.pid

        # The waiting is observed in `pg_stat_activity`, not inferred from timing.
        assert_backend_waits_on_lock!(backend_pid)

        send(insert_task.pid, :release_insert)
        assert {:ok, %Route{id: ^inserted_route_id}} = Task.await(insert_task, @race_timeout)

        assert_receive {:deletion_result, ^delete_pid, {:error, :stale_review}}, @race_timeout
        assert {:error, :stale_review} = Task.await(delete_task, @race_timeout)

        # The version committed by the insert is what the deletion then refused to change: the
        # agency still exists and still owns the route.
        assert Repo.get(Agency, scope.agencies["X"].id) != nil
        assert Repo.get(Agency, scope.agencies["Y"].id) != nil

        assert %Route{agency_id: "X", organization_id: organization_id} =
                 Repo.get(Route, inserted_route_id)

        assert organization_id == scope.organization.id
        assert route_count(scope.version) == 2

        assert Repo.aggregate(
                 from(a in Agency, where: a.gtfs_version_id == ^scope.version.id),
                 :count
               ) == 2

        # Retaking the review changes nothing but the route set, so the lost command lost on
        # the route the insert committed, not on a vanished or replaced target. It runs
        # unboxed: on the shared sandbox connection its `FOR SHARE` version-row lock would
        # outlive this test body and block the cleanup's version delete.
        assert {:ok, retaken} =
                 unboxed(fn ->
                   FeedSettings.review_agency_deletion(
                     scope.audit,
                     scope.agencies["X"].id,
                     scope.agencies["Y"].id
                   )
                 end)

        assert retaken.target.id == scope.agencies["Y"].id
        refute retaken.fingerprint == scope.review.fingerprint
      after
        stop_race_tasks()
        cleanup_committed_scope(token)
      end
    end
  end

  # A committed published version with two agencies, one route for X, an editor and a
  # deletion review taken before the interleaving test's insert. The review names X's route
  # and X → Y, so only the inserted route can make the apply lose. The token names every row
  # this scope commits, so the cleanup can find them even if this function fails halfway.
  defp seed_committed_scope(token) do
    unboxed(fn ->
      organization = organization_fixture(%{alias: organization_alias(token)})

      version = gtfs_version_fixture(organization.id)
      actor = lock_editor(token, organization)

      alpha = agency_fixture(organization.id, version.id, agency_attrs("X", "X Transit"))
      bravo = agency_fixture(organization.id, version.id, agency_attrs("Y", "Y Transit"))

      route_fixture(organization.id, version.id, %{
        route_id: "x0",
        route_short_name: "x0",
        agency_id: "X"
      })

      audit = audit_context(organization, version, actor)

      assert {:ok, %{target: %Agency{}} = review} =
               FeedSettings.review_agency_deletion(audit, alpha.id, bravo.id)

      %{
        organization: organization,
        version: version,
        actor: actor,
        agencies: %{"X" => alpha, "Y" => bravo},
        audit: audit,
        review: review
      }
    end)
  end

  # The committed fixtures are found by the token the seed embedded, deleted in dependency
  # order, and the result is asserted: a leftover row would be invisible to every sandboxed
  # test that follows. The deletion runs in the test process, whose unboxed connection
  # commits. Any body statement that locks a committed row must itself run unboxed: a lock on
  # the shared sandbox connection is held until that transaction ends, which is after this
  # cleanup, so the delete would block until its query timeout canceled it.
  defp cleanup_committed_scope(token) do
    unboxed(fn ->
      organization_ids = token_organization_ids(token)

      Repo.delete_all(from(r in Route, where: r.organization_id in ^organization_ids))
      Repo.delete_all(from(a in Agency, where: a.organization_id in ^organization_ids))

      delete_versions!(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))

      Repo.delete_all(from(u in User, where: u.email == ^actor_email(token)))
      Repo.delete_all(from(o in Organization, where: o.id in ^organization_ids))

      remaining = committed_row_count(organization_ids, actor_email(token))

      if remaining != 0 do
        raise "the committed lock scope left #{remaining} row(s) behind"
      end
    end)
  end

  defp token_organization_ids(token) do
    Repo.all(
      from(o in Organization,
        where: like(o.alias, ^"#{organization_alias(token)}%"),
        select: o.id
      )
    )
  end

  defp committed_row_count(organization_ids, email) do
    Repo.one(from(o in Organization, where: o.id in ^organization_ids, select: count(o.id))) +
      Repo.one(
        from(v in GtfsVersion,
          where: v.organization_id in ^organization_ids,
          select: count(v.id)
        )
      ) +
      Repo.one(
        from(a in Agency, where: a.organization_id in ^organization_ids, select: count(a.id))
      ) +
      Repo.one(
        from(r in Route, where: r.organization_id in ^organization_ids, select: count(r.id))
      ) +
      Repo.one(from(u in User, where: u.email == ^email, select: count(u.id)))
  end

  # The test database is shared with every other unboxed test in this project, so a row
  # committed by an earlier run can still be there. `user_fixture/1`'s address and
  # `System.unique_integer([:positive])` are both counters that restart with each BEAM run
  # and therefore collide with those rows; the OS pid, the monotonic counter and the wall
  # clock do not repeat across runs.
  defp unique_lock_token do
    pid = System.pid()
    counter = System.unique_integer([:positive, :monotonic])
    "#{pid}-#{counter}-#{System.system_time(:microsecond)}"
  end

  defp organization_alias(token), do: "agency-reference-lock-#{token}"
  defp actor_email(token), do: "agency-reference-lock-#{token}@example.com"

  defp lock_editor(token, organization) do
    user = user_fixture(%{email: actor_email(token)})
    organization_membership_fixture(user, organization)
    user
  end

  # A task the body started can still hold the version row lock when an assertion fails, and
  # the cleanup's deletes would wait behind it, so stop them first. A task that already
  # finished is no longer a child.
  defp stop_race_tasks do
    case Process.whereis(__MODULE__.TaskSupervisor) do
      nil ->
        :ok

      supervisor ->
        Task.Supervisor.children(supervisor)
        |> Enum.each(&Task.Supervisor.terminate_child(supervisor, &1))
    end
  end

  # Probes the version row from an independent committing connection. `NOWAIT` resolves
  # immediately instead of waiting, so the assertion stays deterministic.
  defp probe_version_row_nowait(version_id) do
    Task.async(fn ->
      unboxed(fn ->
        Repo.query("select id from gtfs_versions where id = $1::uuid for update nowait", [
          Ecto.UUID.dump!(version_id)
        ])
      end)
    end)
    |> Task.await(@race_timeout)
  end

  # The polling loop re-queries `pg_stat_activity` and is bounded by the monotonic clock
  # instead of sleeping: it exits on the first observed wait, and after five seconds it
  # fails rather than reporting a pass. One query per round trip is the whole cost.
  defp assert_backend_waits_on_lock!(backend_pid) do
    poll_backend_lock(
      backend_pid,
      System.monotonic_time(:millisecond) + @lock_wait_deadline_ms,
      nil
    )
  end

  defp poll_backend_lock(backend_pid, deadline, last_state) do
    state = lock_wait_state(backend_pid)

    cond do
      state == "Lock" ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "the deletion never waited on the version row lock " <>
            "(last wait_event_type: #{inspect(last_state)})"
        )

      true ->
        poll_backend_lock(backend_pid, deadline, state)
    end
  end

  defp lock_wait_state(backend_pid) do
    %Postgrex.Result{rows: rows} =
      Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend_pid])

    case rows do
      [[state]] -> state
      [] -> nil
    end
  end

  defp insert_version_route(context, attrs) do
    insert_route_under_reference_lock(context.organization.id, context.version.id, attrs)
  end

  # The route insert the reference lock exists for: the agency is resolved under the version
  # share lock and the route is inserted in the same transaction.
  defp insert_route_under_reference_lock(organization_id, gtfs_version_id, attrs) do
    Repo.transaction(fn ->
      agency_id =
        FeedSettings.lock_agency_for_reference!(
          organization_id,
          gtfs_version_id,
          attrs["agency_id"]
        )

      %Route{organization_id: organization_id, gtfs_version_id: gtfs_version_id}
      |> Route.changeset(Map.put(attrs, "agency_id", agency_id))
      |> Repo.insert()
      |> case do
        {:ok, route} -> route
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp route_attrs(route_id, agency_id) do
    %{
      "route_id" => route_id,
      "route_type" => 3,
      "route_short_name" => route_id,
      "agency_id" => agency_id
    }
  end

  defp agency_attrs(agency_id, name) do
    %{
      agency_id: agency_id,
      agency_name: name,
      agency_url: "https://#{String.downcase(agency_id)}.example",
      agency_timezone: "America/Chicago"
    }
  end

  defp route_count(version) do
    Repo.aggregate(from(r in Route, where: r.gtfs_version_id == ^version.id), :count)
  end

  defp audit_context(organization, version, actor) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
