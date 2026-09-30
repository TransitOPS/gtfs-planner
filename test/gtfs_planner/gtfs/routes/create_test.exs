defmodule GtfsPlanner.Gtfs.Routes.CreateTest do
  use ExUnit.Case

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  describe "create_editor_route/3 replay protection" do
    test "two requests with one signed attempt create one route and one created audit" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      attrs = route_attrs()

      assert {:ok, %{route: route, replayed?: false}} =
               create_route(attrs, fixture.attempt, fixture.audit)

      assert {:ok, %{route: replay, replayed?: true}} =
               create_route(attrs, fixture.attempt, fixture.audit)

      assert replay.id == route.id
      assert replay.route_id == route.route_id

      assert [%Route{id: stored_id}] = scoped_routes(fixture)
      assert stored_id == route.id

      assert [log] = created_logs(fixture)

      assert log.entity_id == route.id
      assert log.entity_external_id == route.route_id
      assert log.actor_id == fixture.audit.actor_id
      assert log.actor_email == fixture.audit.actor_email

      assert log.changed_fields["creation_attempt_id"] ==
               fixture.attempt.creation_attempt_id

      assert String.starts_with?(log.changed_fields["request_digest"], "sha256:")
      assert log.changed_fields["before"] == nil
      assert log.changed_fields["after"]["route_short_name"] == "15"
      assert log.changed_fields["after"]["route_type"] == 3
    end

    test "a lost response reconciles to the original route and an unused attempt is not started" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      assert {:error, :not_started} = reconcile(fixture.attempt, fixture.audit)

      assert {:ok, %{route: route}} = create_route(route_attrs(), fixture.attempt, fixture.audit)

      # The browser lost the response and recovers through the same attempt:
      # reconciliation and an identical retry both return the original route.
      assert {:ok, %Route{id: reconciled_id}} = reconcile(fixture.attempt, fixture.audit)
      assert reconciled_id == route.id

      assert {:ok, %{route: retried, replayed?: true}} =
               create_route(route_attrs(), fixture.attempt, fixture.audit)

      assert retried.id == route.id
      assert [%Route{id: ^reconciled_id}] = scoped_routes(fixture)
      assert [_log] = created_logs(fixture)
    end

    test "a changed request digest on one attempt does not create a copy" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      assert {:ok, %{route: route}} = create_route(route_attrs(), fixture.attempt, fixture.audit)

      changed = route_attrs(%{route_long_name: "Fifteen Renamed"})

      assert {:error, {:attempt_mismatch, link}} =
               create_route(changed, fixture.attempt, fixture.audit)

      assert link.route_uuid == route.id
      assert link.route_id == route.route_id
      assert [%Route{id: route_id}] = scoped_routes(fixture)
      assert route_id == route.id
      assert [_log] = created_logs(fixture)
    end

    test "a deleted result consumes the attempt without a suffixed copy" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      attrs = route_attrs()

      assert {:ok, %{route: route}} = create_route(attrs, fixture.attempt, fixture.audit)
      unboxed(fn -> Repo.delete!(route) end)

      assert {:error, :attempt_consumed} = create_route(attrs, fixture.attempt, fixture.audit)
      assert {:error, :attempt_consumed} = reconcile(fixture.attempt, fixture.audit)

      assert scoped_routes(fixture) == []
      # The create log stays retained as the attempt record.
      assert [_log] = created_logs(fixture)
    end
  end

  describe "create_editor_route/3 authorization and scope" do
    test "a deactivated editor cannot create a route or its audit record" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      unboxed(fn ->
        membership =
          Repo.get_by!(UserOrgMembership,
            user_id: fixture.actor.id,
            organization_id: fixture.organization.id
          )

        deactivate_membership_fixture(membership)
      end)

      assert {:error, :forbidden} = create_route(route_attrs(), fixture.attempt, fixture.audit)
      assert scoped_routes(fixture) == []
      assert created_logs(fixture) == []
    end

    test "a denied actor writes nothing and loses no access" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      outsider =
        unboxed(fn -> user_fixture(%{email: "route-create-outsider-#{stamp()}@example.com"}) end)

      # Current membership removal denies the mutation but retains every row.
      unboxed(fn ->
        Repo.delete_all(
          from m in UserOrgMembership,
            where:
              m.user_id == ^fixture.actor.id and m.organization_id == ^fixture.organization.id
        )
      end)

      assert {:error, :forbidden} = create_route(route_attrs(), fixture.attempt, fixture.audit)
      assert {:error, :forbidden} = reconcile(fixture.attempt, fixture.audit)

      other_tenant_audit = %{fixture.audit | actor_id: outsider.id}

      assert {:error, :forbidden} =
               create_route(route_attrs(), fixture.attempt, other_tenant_audit)

      assert scoped_routes(fixture) == []
      assert created_logs(fixture) == []

      unboxed(fn -> Repo.delete!(outsider) end)
    end

    test "foreign or unpublished scope returns not-found and another tenant is denied" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      foreign = create_fixture()
      on_exit(fn -> cleanup_fixture(foreign) end)

      # A claimed version outside the audit organization is foreign scope:
      # not-found with no counts and no writes.
      foreign_version_attempt = %{fixture.attempt | gtfs_version_id: foreign.version.id}
      foreign_version_audit = %{fixture.audit | gtfs_version_id: foreign.version.id}

      assert {:error, :not_found} =
               create_route(route_attrs(), foreign_version_attempt, foreign_version_audit)

      # Another tenant's fully scoped request is a denial that retains data.
      tenant_attempt = %{
        fixture.attempt
        | organization_id: foreign.organization.id,
          gtfs_version_id: foreign.version.id
      }

      tenant_audit = %{
        fixture.audit
        | organization_id: foreign.organization.id,
          gtfs_version_id: foreign.version.id
      }

      assert {:error, :forbidden} = create_route(route_attrs(), tenant_attempt, tenant_audit)

      unboxed(fn ->
        Repo.update_all(
          from(v in GtfsVersion, where: v.id == ^fixture.version.id),
          set: [publication_status: "failed", published_at: nil]
        )
      end)

      assert {:error, :not_found} = create_route(route_attrs(), fixture.attempt, fixture.audit)
      assert {:error, :not_found} = reconcile(fixture.attempt, fixture.audit)

      assert scoped_routes(fixture) == []
      assert created_logs(fixture) == []
      assert scoped_routes(foreign) == []
    end
  end

  describe "create_editor_route/3 scoped agency validation" do
    test "zero agencies accept a blank assignment and reject an unknown one" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      assert {:ok, %{route: route}} = create_route(route_attrs(), fixture.attempt, fixture.audit)
      assert route.agency_id == nil

      assert {:error, %Ecto.Changeset{} = changeset} =
               create_route(
                 route_attrs(%{agency_id: "ghost"}),
                 next_attempt(fixture),
                 fixture.audit
               )

      assert {"is not available in this version", _} = changeset.errors[:agency_id]
      assert [_route] = scoped_routes(fixture)
    end

    test "one read-only agency resolves automatically" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      agency = unboxed(fn -> agency_fixture(fixture.organization.id, fixture.version.id) end)

      assert {:ok, %{route: route}} = create_route(route_attrs(), fixture.attempt, fixture.audit)
      assert route.agency_id == agency.agency_id

      assert {:ok, %{route: explicit}} =
               create_route(
                 route_attrs(%{agency_id: agency.agency_id}),
                 next_attempt(fixture),
                 fixture.audit
               )

      assert explicit.agency_id == agency.agency_id

      assert {:error, %Ecto.Changeset{} = changeset} =
               create_route(
                 route_attrs(%{agency_id: "other"}),
                 next_attempt(fixture),
                 fixture.audit
               )

      assert {"is not available in this version", _} = changeset.errors[:agency_id]
    end

    test "multiple agencies require a selected scoped agency" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      {agency, other} =
        unboxed(fn ->
          {
            agency_fixture(fixture.organization.id, fixture.version.id),
            agency_fixture(fixture.organization.id, fixture.version.id)
          }
        end)

      assert {:error, %Ecto.Changeset{} = changeset} =
               create_route(route_attrs(), fixture.attempt, fixture.audit)

      assert {"must be selected when the version has multiple agencies", _} =
               changeset.errors[:agency_id]

      assert {:ok, %{route: route}} =
               create_route(
                 route_attrs(%{agency_id: agency.agency_id}),
                 next_attempt(fixture),
                 fixture.audit
               )

      assert route.agency_id == agency.agency_id

      assert {:error, %Ecto.Changeset{} = rejected} =
               create_route(
                 route_attrs(%{agency_id: "unknown"}),
                 next_attempt(fixture),
                 fixture.audit
               )

      assert {"is not available in this version", _} = rejected.errors[:agency_id]

      assert {:ok, %{route: second}} =
               create_route(
                 route_attrs(%{agency_id: other.agency_id}),
                 next_attempt(fixture),
                 fixture.audit
               )

      assert second.agency_id == other.agency_id
    end
  end

  describe "create_editor_route/3 identifier allocation" do
    test "generated identifiers infer from same-mode examples and suffix duplicates" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      unboxed(fn ->
        route_fixture(fixture.organization.id, fixture.version.id, %{
          route_id: "B10",
          route_short_name: "10",
          route_type: 3
        })

        route_fixture(fixture.organization.id, fixture.version.id, %{
          route_id: "B12",
          route_short_name: "12",
          route_type: 3
        })
      end)

      assert {:ok, %{route: route}} = create_route(route_attrs(), fixture.attempt, fixture.audit)
      assert route.route_id == "B15"

      assert {:ok, %{route: suffixed}} =
               create_route(route_attrs(), next_attempt(fixture), fixture.audit)

      assert suffixed.route_id == "B15-2"
      assert length(created_logs(fixture)) == 2
    end

    test "a manual override collision fails inline without renaming" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      unboxed(fn ->
        route_fixture(fixture.organization.id, fixture.version.id, %{route_id: "R1"})
      end)

      assert {:error, %Ecto.Changeset{} = changeset} =
               create_route(route_attrs(%{route_id: "R1"}), fixture.attempt, fixture.audit)

      assert {"This route ID is already used in this version. Choose another.", _} =
               changeset.errors[:route_id]

      assert {:ok, %{route: manual}} =
               create_route(route_attrs(%{route_id: "R9"}), next_attempt(fixture), fixture.audit)

      assert manual.route_id == "R9"
      assert [_log] = created_logs(fixture)
    end
  end

  describe "create_editor_route/3 audit atomicity" do
    test "a failed audit rolls back the created route" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      failed_audit = %{fixture.audit | actor_email: nil}

      assert {:error, :failed_audit} = create_route(route_attrs(), fixture.attempt, failed_audit)

      assert scoped_routes(fixture) == []
      assert created_logs(fixture) == []
    end
  end

  describe "concurrent generated/manual IDs obey scoped validation" do
    test "concurrent generated creates suffix deterministically under the version lock" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      outcomes =
        run_concurrently([fixture.attempt, next_attempt(fixture)], fn attempt ->
          create_route(route_attrs(%{route_short_name: "7"}), attempt, fixture.audit)
        end)

      assert Enum.all?(outcomes, &match?({:ok, %{route: %Route{}}}, &1))

      route_ids =
        fixture
        |> scoped_routes()
        |> Enum.map(& &1.route_id)
        |> Enum.sort()

      assert route_ids == ["7", "7-2"]
      assert length(created_logs(fixture)) == 2
    end

    test "concurrent manual duplicates fail inline without a second route" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      outcomes =
        run_concurrently([fixture.attempt, next_attempt(fixture)], fn attempt ->
          create_route(route_attrs(%{route_id: "M1"}), attempt, fixture.audit)
        end)

      assert {:ok, %{route: %Route{route_id: "M1"}}} =
               Enum.find(outcomes, &match?({:ok, _}, &1))

      assert {:error, %Ecto.Changeset{} = failed} =
               Enum.find(outcomes, &match?({:error, _}, &1))

      assert {"This route ID is already used in this version. Choose another.", _} =
               failed.errors[:route_id]

      assert [%Route{route_id: "M1"}] = scoped_routes(fixture)
      assert [_log] = created_logs(fixture)
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp stamp, do: System.system_time(:nanosecond)

  # The real public domain entrypoint runs outside the shared Sandbox against
  # committed fixtures, so the serializable create transaction is real.
  defp create_route(attrs, attempt, audit),
    do: unboxed(fn -> Gtfs.create_editor_route(attrs, attempt, audit) end)

  defp reconcile(attempt, audit),
    do: unboxed(fn -> Gtfs.reconcile_creation(attempt, audit) end)

  defp create_fixture do
    unboxed(fn ->
      organization = organization_fixture(%{alias: "route-create-#{stamp()}"})
      version = gtfs_version_fixture(organization.id)

      actor =
        user_fixture(%{email: "route-create-#{System.unique_integer([:positive])}@example.com"})

      {:ok, _membership} =
        Organizations.add_user_to_organization(actor.id, organization.id, [
          "pathways_studio_editor"
        ])

      audit = %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        actor_id: actor.id,
        actor_email: actor.email
      }

      attempt = %{
        creation_attempt_id: Ecto.UUID.generate(),
        actor_id: actor.id,
        organization_id: organization.id,
        gtfs_version_id: version.id
      }

      %{
        organization: organization,
        version: version,
        actor: actor,
        audit: audit,
        attempt: attempt
      }
    end)
  end

  defp next_attempt(fixture) do
    %{fixture.attempt | creation_attempt_id: Ecto.UUID.generate()}
  end

  defp route_attrs(overrides \\ %{}) do
    Enum.into(overrides, %{
      route_short_name: "15",
      route_long_name: "Fifteen",
      route_type: 3,
      route_color: "1B4F72",
      text_mode: "automatic"
    })
  end

  defp scoped_routes(fixture) do
    unboxed(fn ->
      Repo.all(
        from r in Route,
          where:
            r.organization_id == ^fixture.organization.id and
              r.gtfs_version_id == ^fixture.version.id,
          order_by: r.route_id
      )
    end)
  end

  defp created_logs(fixture) do
    unboxed(fn ->
      Repo.all(
        from l in ChangeLog,
          where:
            l.organization_id == ^fixture.organization.id and
              l.gtfs_version_id == ^fixture.version.id and
              l.entity_type == "route" and l.action == "created",
          order_by: l.inserted_at
      )
    end)
  end

  # Two supervised tasks race the real public entrypoint against committed
  # fixtures with an explicit start barrier, outside the shared Sandbox.
  defp run_concurrently(attempts, command) do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
    parent = self()

    workers =
      attempts
      |> Enum.with_index()
      |> Enum.map(fn {attempt, index} ->
        Task.Supervisor.async_nolink(supervisor, fn ->
          send(parent, {:writer_ready, index})

          receive do
            {:commit, ^index} ->
              result = command.(attempt)
              send(parent, {:writer_done, index, result})
              result
          end
        end)
      end)

    for index <- 0..(length(attempts) - 1) do
      assert_receive {:writer_ready, ^index}, 10_000
    end

    for index <- 0..(length(attempts) - 1) do
      send(Enum.at(workers, index).pid, {:commit, index})
    end

    outcomes =
      for _ <- attempts do
        assert_receive {:writer_done, _index, result}, 10_000
        result
      end

    Enum.each(workers, &Task.await(&1, 10_000))
    outcomes
  end

  defp cleanup_fixture(fixture) do
    unboxed(fn ->
      Repo.delete_all(
        from l in ChangeLog,
          where:
            l.organization_id == ^fixture.organization.id or
              l.gtfs_version_id == ^fixture.version.id
      )

      Repo.delete_all(
        from r in Route,
          where:
            r.organization_id == ^fixture.organization.id or
              r.gtfs_version_id == ^fixture.version.id
      )

      Repo.delete_all(
        from a in Agency,
          where:
            a.organization_id == ^fixture.organization.id or
              a.gtfs_version_id == ^fixture.version.id
      )

      Repo.delete_all(
        from m in UserOrgMembership,
          where: m.organization_id == ^fixture.organization.id or m.user_id == ^fixture.actor.id
      )

      Repo.delete_all(from v in GtfsVersion, where: v.id == ^fixture.version.id)
      Repo.delete_all(from u in User, where: u.id == ^fixture.actor.id)
      Repo.delete_all(from o in Organization, where: o.id == ^fixture.organization.id)
      :ok
    end)
  end
end
