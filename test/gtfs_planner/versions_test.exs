defmodule GtfsPlanner.VersionsTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion
  alias GtfsPlanner.Repo

  import GtfsPlanner.ConcurrencyHelpers
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @contention_timeout 10_000
  @collect_timeout 15_000

  @published_status "published"
  @staging_status "staging"
  @importing_status "importing"
  @failed_status "failed"

  describe "gtfs_versions" do
    test "create_gtfs_version/2 creates a published version with valid attrs" do
      organization = organization_fixture()
      attrs = %{name: "Spring 2024"}

      assert {:ok, version} = Versions.create_gtfs_version(organization.id, attrs)
      assert version.name == "Spring 2024"
      assert version.organization_id == organization.id
      assert version.publication_status == @published_status
      assert not is_nil(version.published_at)

      assert {:ok, %{rows: [[database_now]]}} =
               Repo.query("SELECT CURRENT_TIMESTAMP::timestamp")

      assert DateTime.to_naive(version.published_at) == database_now
    end

    test "create_gtfs_version/2 returns error with invalid attrs" do
      organization = organization_fixture()
      attrs = %{name: nil}

      assert {:error, changeset} = Versions.create_gtfs_version(organization.id, attrs)
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "create_default_version/1 creates a published version named 'First Version'" do
      org = organization_without_version_fixture()

      assert {:ok, version} = Versions.create_default_version(org.id)
      assert version.name == "First Version"
      assert version.organization_id == org.id
      assert version.publication_status == @published_status
      assert not is_nil(version.published_at)
    end

    test "create_staging_gtfs_version/2 creates a staging version with nil published_at" do
      organization = organization_fixture()

      assert {:ok, version} =
               Versions.create_staging_gtfs_version(organization.id, %{name: "Staged Feed"})

      assert version.name == "Staged Feed"
      assert version.organization_id == organization.id
      assert version.publication_status == @staging_status
      assert is_nil(version.published_at)
    end

    test "create_staging_gtfs_version/2 is unavailable through published listings" do
      organization = organization_without_version_fixture()
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staged"})

      assert nil == Versions.get_published_gtfs_version_for_org(organization.id, staging.id)
      assert [] == Versions.list_published_gtfs_versions(organization.id)
      refute Versions.published_gtfs_version_for_org?(organization.id, staging.id)
    end

    test "list_gtfs_versions/1 returns only published versions for the given organization" do
      org1 = organization_fixture()
      org2 = organization_fixture()

      {:ok, staging} = Versions.create_staging_gtfs_version(org1.id, %{name: "Hidden"})
      {:ok, published2} = Versions.create_gtfs_version(org1.id, %{name: "Second Version"})

      versions = Versions.list_gtfs_versions(org1.id)

      assert Enum.any?(versions, fn v -> v.id == published2.id end)
      refute Enum.any?(versions, fn v -> v.id == staging.id end)
      assert Enum.all?(versions, fn v -> v.publication_status == @published_status end)
      assert Enum.any?(versions, fn v -> v.name == "First Version" end)

      org2_versions = Versions.list_gtfs_versions(org2.id)
      assert length(org2_versions) == 1
      assert hd(org2_versions).organization_id == org2.id
    end

    test "list_published_gtfs_versions/1 excludes non-published states" do
      organization = organization_fixture()
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staged"})
      {:ok, _published} = Versions.create_gtfs_version(organization.id, %{name: "Published One"})

      published = Versions.list_published_gtfs_versions(organization.id)

      refute Enum.any?(published, fn v -> v.id == staging.id end)
      assert Enum.all?(published, fn v -> v.publication_status == @published_status end)
    end

    test "get_latest_gtfs_version/1 returns latest published version when multiple exist" do
      organization = organization_without_version_fixture()

      {:ok, version1} = Versions.create_gtfs_version(organization.id, %{name: "Version 1"})
      {:ok, version2} = Versions.create_gtfs_version(organization.id, %{name: "Version 2"})

      # Force a deterministic published_at ordering distinct from insertion order.
      set_published_at(version1, ~U[2024-01-01 00:00:00Z])
      set_published_at(version2, ~U[2024-03-01 00:00:00Z])

      assert {:ok, latest} = Versions.get_latest_gtfs_version(organization.id)
      assert latest.id == version2.id
      assert latest.name == "Version 2"
    end

    test "get_latest_gtfs_version/1 ignores staging versions in ordering" do
      organization = organization_without_version_fixture()
      {:ok, published} = Versions.create_gtfs_version(organization.id, %{name: "Published"})
      {:ok, _staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staged"})

      assert {:ok, latest} = Versions.get_latest_gtfs_version(organization.id)
      assert latest.id == published.id
    end

    test "get_latest_gtfs_version/1 returns error when organization has no published versions" do
      org = organization_without_version_fixture()

      assert {:error, :no_versions} = Versions.get_latest_gtfs_version(org.id)
    end

    test "list_gtfs_versions_for_dropdown/1 returns only published tuples ordered by published_at DESC" do
      organization = organization_fixture()

      {:ok, version1} = Versions.create_gtfs_version(organization.id, %{name: "Version 1"})
      {:ok, version2} = Versions.create_gtfs_version(organization.id, %{name: "Version 2"})
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staged"})

      set_published_at(version1, ~U[2024-01-01 00:00:00Z])
      set_published_at(version2, ~U[2024-02-01 00:00:00Z])

      versions = Versions.list_gtfs_versions_for_dropdown(organization.id)

      # 2 published + 1 from fixture (First Version, published_at ~now is newest)
      assert length(versions) == 3
      refute Enum.any?(versions, fn {id, _} -> id == staging.id end)

      assert Enum.map(versions, fn {_id, name} -> name end) == [
               "First Version",
               "Version 2",
               "Version 1"
             ]
    end

    test "list_gtfs_versions_for_dropdown/1 excludes staging with org without auto version" do
      organization = organization_without_version_fixture()

      {:ok, version1} = Versions.create_gtfs_version(organization.id, %{name: "Version 1"})
      {:ok, version2} = Versions.create_gtfs_version(organization.id, %{name: "Version 2"})
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staged"})

      set_published_at(version1, ~U[2024-01-01 00:00:00Z])
      set_published_at(version2, ~U[2024-02-01 00:00:00Z])

      versions = Versions.list_gtfs_versions_for_dropdown(organization.id)

      assert length(versions) == 2
      refute Enum.any?(versions, fn {id, _} -> id == staging.id end)
      assert Enum.map(versions, fn {_id, name} -> name end) == ["Version 2", "Version 1"]
    end

    test "list_gtfs_versions_for_dropdown/1 returns empty list when organization has no versions" do
      org = organization_without_version_fixture()

      versions = Versions.list_gtfs_versions_for_dropdown(org.id)
      assert versions == []
    end
  end

  describe "organization isolation" do
    test "get_published_gtfs_version_for_org/2 is scoped to the organization" do
      org1 = organization_fixture()
      org2 = organization_fixture()
      {:ok, published} = Versions.create_gtfs_version(org1.id, %{name: "Org1 Published"})

      assert nil == Versions.get_published_gtfs_version_for_org(org2.id, published.id)

      assert %GtfsVersion{} =
               found = Versions.get_published_gtfs_version_for_org(org1.id, published.id)

      assert found.id == published.id
    end

    test "get_published_gtfs_version_for_org!/2 raises for foreign organization" do
      org1 = organization_fixture()
      org2 = organization_fixture()
      {:ok, published} = Versions.create_gtfs_version(org1.id, %{name: "Org1 Published"})

      assert_raise Ecto.NoResultsError, fn ->
        Versions.get_published_gtfs_version_for_org!(org2.id, published.id)
      end

      found = Versions.get_published_gtfs_version_for_org!(org1.id, published.id)
      assert found.id == published.id
    end

    test "published_gtfs_version_for_org?/2 is scoped to the organization" do
      org1 = organization_fixture()
      org2 = organization_fixture()
      {:ok, published} = Versions.create_gtfs_version(org1.id, %{name: "Org1 Published"})

      assert Versions.published_gtfs_version_for_org?(org1.id, published.id)
      refute Versions.published_gtfs_version_for_org?(org2.id, published.id)
    end

    test "get_gtfs_version_for_lifecycle/2 is scoped to the organization" do
      org1 = organization_fixture()
      org2 = organization_fixture()
      {:ok, staging} = Versions.create_staging_gtfs_version(org1.id, %{name: "Staged"})

      assert nil == Versions.get_gtfs_version_for_lifecycle(org2.id, staging.id)
      assert %GtfsVersion{} = found = Versions.get_gtfs_version_for_lifecycle(org1.id, staging.id)
      assert found.id == staging.id
    end
  end

  describe "update_gtfs_version/3" do
    setup do
      organization = organization_fixture()
      editor = user_fixture()
      membership = organization_membership_fixture(editor, organization)
      {:ok, version} = Versions.create_gtfs_version(organization.id, %{name: "Original"})

      %{
        organization: organization,
        editor: editor,
        membership: membership,
        version: version,
        scope: %{actor_id: editor.id, organization_id: organization.id}
      }
    end

    test "renames the version for a current editor", %{scope: scope, version: version} do
      assert {:ok, %GtfsVersion{name: "Renamed"}} =
               Versions.update_gtfs_version(scope, version.id, %{name: "Renamed"})

      assert Repo.get!(GtfsVersion, version.id).name == "Renamed"
    end

    test "writes only the name, ignoring lifecycle fields in the attrs", %{
      scope: scope,
      version: version
    } do
      assert {:ok, _version} =
               Versions.update_gtfs_version(scope, version.id, %{
                 name: "Renamed",
                 publication_status: @failed_status
               })

      assert Repo.get!(GtfsVersion, version.id).publication_status == @published_status
    end

    test "rejects an editor whose membership was deactivated after the page loaded", %{
      scope: scope,
      version: version,
      membership: membership
    } do
      deactivate_membership_fixture(membership)

      assert {:error, :forbidden} =
               Versions.update_gtfs_version(scope, version.id, %{name: "Renamed"})

      assert Repo.get!(GtfsVersion, version.id).name == "Original"
    end

    test "rejects a member who holds no editor role", %{
      organization: organization,
      version: version
    } do
      admin = user_fixture()
      organization_membership_fixture(admin, organization, ["pathways_studio_admin"])
      scope = %{actor_id: admin.id, organization_id: organization.id}

      assert {:error, :forbidden} =
               Versions.update_gtfs_version(scope, version.id, %{name: "Renamed"})

      assert Repo.get!(GtfsVersion, version.id).name == "Original"
    end

    test "rejects a scope with no actor", %{organization: organization, version: version} do
      scope = %{actor_id: nil, organization_id: organization.id}

      assert {:error, :forbidden} =
               Versions.update_gtfs_version(scope, version.id, %{name: "Renamed"})

      assert Repo.get!(GtfsVersion, version.id).name == "Original"
    end

    test "returns not found for another organization's version", %{scope: scope} do
      other_organization = organization_fixture()
      {:ok, foreign} = Versions.create_gtfs_version(other_organization.id, %{name: "Foreign"})

      assert {:error, :not_found} =
               Versions.update_gtfs_version(scope, foreign.id, %{name: "Renamed"})

      assert Repo.get!(GtfsVersion, foreign.id).name == "Foreign"
    end

    test "rejects an editor of one organization who claims another organization", %{
      editor: editor,
      version: version
    } do
      other_organization = organization_fixture()
      {:ok, foreign} = Versions.create_gtfs_version(other_organization.id, %{name: "Foreign"})
      scope = %{actor_id: editor.id, organization_id: other_organization.id}

      assert {:error, :forbidden} =
               Versions.update_gtfs_version(scope, foreign.id, %{name: "Renamed"})

      assert {:error, :forbidden} =
               Versions.update_gtfs_version(scope, version.id, %{name: "Renamed"})

      assert Repo.get!(GtfsVersion, foreign.id).name == "Foreign"
      assert Repo.get!(GtfsVersion, version.id).name == "Original"
    end

    test "returns the changeset for a duplicate name and leaves the name unchanged", %{
      scope: scope,
      organization: organization,
      version: version
    } do
      {:ok, _other} = Versions.create_gtfs_version(organization.id, %{name: "Taken"})

      assert {:error, changeset} =
               Versions.update_gtfs_version(scope, version.id, %{name: "Taken"})

      assert %{name: ["A version with this name already exists"]} = errors_on(changeset)
      assert Repo.get!(GtfsVersion, version.id).name == "Original"
    end
  end

  describe "lifecycle transitions" do
    test "claim_staging_gtfs_version/2 transitions staging -> importing exactly once" do
      organization = organization_fixture()
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staged"})

      assert {:ok, claimed} = Versions.claim_staging_gtfs_version(organization.id, staging.id)
      assert claimed.publication_status == @importing_status
      assert is_nil(claimed.published_at)

      # Repeated claim is rejected (no longer staging)
      assert {:error, :invalid_status_transition} =
               Versions.claim_staging_gtfs_version(organization.id, staging.id)
    end

    test "claim_staging_gtfs_version/2 rejects non-staging states" do
      organization = organization_fixture()
      {:ok, published} = Versions.create_gtfs_version(organization.id, %{name: "Published"})

      assert {:error, :invalid_status_transition} =
               Versions.claim_staging_gtfs_version(organization.id, published.id)
    end

    test "claim_staging_gtfs_version/2 returns not_found for unknown id" do
      organization = organization_fixture()

      assert {:error, :not_found} =
               Versions.claim_staging_gtfs_version(organization.id, Ecto.UUID.generate())
    end

    test "two concurrent claims for one staging id produce one importing winner and one loser" do
      organization = organization_fixture()
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staged"})

      parent = self()

      task_fn = fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
        Versions.claim_staging_gtfs_version(organization.id, staging.id)
      end

      t1 = Task.async(task_fn)
      t2 = Task.async(task_fn)

      results = Task.await_many([t1, t2], 5000)

      winners = Enum.filter(results, &match?({:ok, _}, &1))
      assert length(winners) == 1

      claimed =
        from(v in GtfsVersion, where: v.id == ^staging.id, select: v.publication_status)
        |> Repo.one!()

      assert claimed == @importing_status
    end

    test "publish_importing_gtfs_version/2 transitions importing -> published with DB time" do
      organization = organization_fixture()
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staged"})
      {:ok, _claimed} = Versions.claim_staging_gtfs_version(organization.id, staging.id)

      assert {:ok, published} =
               Versions.publish_importing_gtfs_version(organization.id, staging.id)

      assert published.publication_status == @published_status
      assert not is_nil(published.published_at)
      # published_at is set by the database clock, not the application clock
      assert DateTime.compare(published.published_at, DateTime.utc_now()) in [:eq, :lt]
    end

    test "publish_importing_gtfs_version/2 rejects non-importing states" do
      organization = organization_fixture()
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staged"})

      assert {:error, :invalid_status_transition} =
               Versions.publish_importing_gtfs_version(organization.id, staging.id)
    end

    test "publish_importing_gtfs_version/2 returns not_found for unknown id" do
      organization = organization_fixture()

      assert {:error, :not_found} =
               Versions.publish_importing_gtfs_version(organization.id, Ecto.UUID.generate())
    end

    test "two concurrent publishes for one importing id close exactly once without stale overwrite" do
      organization = organization_fixture()
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staged"})
      {:ok, _claimed} = Versions.claim_staging_gtfs_version(organization.id, staging.id)

      parent = self()

      task_fn = fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
        Versions.publish_importing_gtfs_version(organization.id, staging.id)
      end

      t1 = Task.async(task_fn)
      t2 = Task.async(task_fn)

      results = Task.await_many([t1, t2], 5000)

      winners = Enum.filter(results, &match?({:ok, _}, &1))
      assert length(winners) == 1

      final =
        from(v in GtfsVersion,
          where: v.id == ^staging.id,
          select: {v.publication_status, v.published_at}
        )
        |> Repo.one!()

      assert elem(final, 0) == @published_status
      assert not is_nil(elem(final, 1))
    end

    test "concurrent publish and fail produce one terminal state with matching telemetry" do
      organization = organization_fixture()
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staged"})
      {:ok, _claimed} = Versions.claim_staging_gtfs_version(organization.id, staging.id)

      handler_id = make_ref()
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:gtfs_planner, :import_publication, :transition],
        fn _event, _measurements, meta, _config ->
          send(test_pid, {:terminal_race_telemetry, meta})
        end,
        %{}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      parent = self()
      supervisor = start_supervised!(Task.Supervisor)

      publish_task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
          Versions.publish_importing_gtfs_version(organization.id, staging.id)
        end)

      fail_task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
          Versions.fail_unpublished_gtfs_version(organization.id, staging.id)
        end)

      results = Task.await_many([publish_task, fail_task], 5000)

      assert Enum.count(results, &match?({:ok, %GtfsVersion{}}, &1)) == 1
      assert Enum.count(results, &match?({:error, :invalid_status_transition}, &1)) == 1

      final = Repo.get!(GtfsVersion, staging.id)
      assert final.publication_status in [@published_status, @failed_status]

      if final.publication_status == @published_status do
        assert not is_nil(final.published_at)
      else
        assert is_nil(final.published_at)
      end

      telemetry =
        for _ <- 1..2 do
          assert_receive {:terminal_race_telemetry, meta}, 1000
          meta
        end

      assert success_meta = Enum.find(telemetry, &is_nil(&1.failure_class))
      assert success_meta.prior_state == @importing_status
      assert success_meta.new_state == final.publication_status

      assert invalid_meta =
               Enum.find(telemetry, &(&1.failure_class == :invalid_status_transition))

      assert invalid_meta.prior_state == final.publication_status
      assert invalid_meta.new_state == final.publication_status
    end

    test "fail_unpublished_gtfs_version/2 transitions staging -> failed" do
      organization = organization_fixture()
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staged"})

      assert {:ok, failed} = Versions.fail_unpublished_gtfs_version(organization.id, staging.id)
      assert failed.publication_status == @failed_status
      assert is_nil(failed.published_at)
    end

    test "fail_unpublished_gtfs_version/2 transitions importing -> failed" do
      organization = organization_fixture()
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staged"})
      {:ok, _claimed} = Versions.claim_staging_gtfs_version(organization.id, staging.id)

      assert {:ok, failed} = Versions.fail_unpublished_gtfs_version(organization.id, staging.id)
      assert failed.publication_status == @failed_status
      assert is_nil(failed.published_at)
    end

    test "failed versions are terminal and cannot be claimed, published, or retried" do
      organization = organization_fixture()
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staged"})
      {:ok, _failed} = Versions.fail_unpublished_gtfs_version(organization.id, staging.id)

      assert {:error, :invalid_status_transition} =
               Versions.claim_staging_gtfs_version(organization.id, staging.id)

      assert {:error, :invalid_status_transition} =
               Versions.publish_importing_gtfs_version(organization.id, staging.id)

      # No failed -> staging/importing/published transition exists
      assert {:error, :invalid_status_transition} =
               Versions.fail_unpublished_gtfs_version(organization.id, staging.id)
    end

    test "fail_unpublished_gtfs_version/2 rejects published states" do
      organization = organization_fixture()
      {:ok, published} = Versions.create_gtfs_version(organization.id, %{name: "Published"})

      assert {:error, :invalid_status_transition} =
               Versions.fail_unpublished_gtfs_version(organization.id, published.id)
    end

    test "failed versions reserve their organization/name for Package 3 cleanup" do
      organization = organization_fixture()
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Doomed"})
      {:ok, _failed} = Versions.fail_unpublished_gtfs_version(organization.id, staging.id)

      # The failed version remains identifiable by org + name for delete-before-retry cleanup.
      found = Versions.get_gtfs_version_for_lifecycle(organization.id, staging.id)
      assert found.publication_status == @failed_status
      assert found.name == "Doomed"
      # It is never externally readable as published.
      refute Versions.published_gtfs_version_for_org?(organization.id, staging.id)
      assert nil == Versions.get_published_gtfs_version_for_org(organization.id, staging.id)
    end
  end

  describe "deterministic publication ordering" do
    test "latest selection follows published_at DESC, inserted_at DESC, id DESC" do
      organization = organization_without_version_fixture()

      {:ok, early} = Versions.create_gtfs_version(organization.id, %{name: "Early"})
      {:ok, mid} = Versions.create_gtfs_version(organization.id, %{name: "Mid"})
      {:ok, late} = Versions.create_gtfs_version(organization.id, %{name: "Late"})

      set_published_at(early, ~U[2024-01-01 00:00:00.000000Z])
      set_published_at(mid, ~U[2024-06-01 00:00:00.000000Z])
      set_published_at(late, ~U[2024-06-01 00:00:00.000000Z])

      # late and mid share a published_at; tie-break by inserted_at then id DESC.
      assert {:ok, latest} = Versions.get_latest_gtfs_version(organization.id)
      assert latest.id == late.id
      assert latest.name == "Late"
    end

    test "list_published_gtfs_versions/1 orders published_at DESC deterministically" do
      organization = organization_without_version_fixture()
      {:ok, a} = Versions.create_gtfs_version(organization.id, %{name: "A"})
      {:ok, b} = Versions.create_gtfs_version(organization.id, %{name: "B"})

      set_published_at(a, ~U[2024-03-01 00:00:00.000000Z])
      set_published_at(b, ~U[2024-09-01 00:00:00.000000Z])

      ordered = Versions.list_published_gtfs_versions(organization.id)
      names = Enum.map(ordered, & &1.name)
      assert names == ["B", "A"]
    end
  end

  describe "transition telemetry" do
    test "create, claim, publish, fail, and invalid transitions emit scoped telemetry" do
      handler_id = make_ref()
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:gtfs_planner, :import_publication, :transition],
        fn event, measurements, meta, _config ->
          send(test_pid, {:telemetry, event, measurements, meta})
        end,
        %{}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      organization = organization_fixture()
      {:ok, _staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staged"})
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staged 2"})

      {:ok, _claimed} = Versions.claim_staging_gtfs_version(organization.id, staging.id)
      {:ok, published} = Versions.publish_importing_gtfs_version(organization.id, staging.id)

      # A separate staging version is failed (terminal transition emits telemetry).
      {:ok, failing} = Versions.create_staging_gtfs_version(organization.id, %{name: "Doomed"})
      {:ok, _failed} = Versions.fail_unpublished_gtfs_version(organization.id, failing.id)

      # invalid transition on the already-published version
      {:error, :invalid_status_transition} =
        Versions.publish_importing_gtfs_version(organization.id, staging.id)

      events =
        Enum.reduce_while(1..6, [], fn _, acc ->
          receive do
            {:telemetry, event, _m, meta} ->
              {:cont, [{event, meta} | acc]}
          after
            1000 -> {:halt, acc}
          end
        end)
        |> Enum.reverse()

      assert length(events) >= 5

      # The published-event metadata must carry the right scoped transition context.
      published_event =
        Enum.find(events, fn {_ev, meta} ->
          meta.version_id == published.id and meta.new_state == "published"
        end)

      assert {_, create_meta} = published_event
      assert create_meta.organization_id == organization.id
      assert create_meta.version_id == published.id
      assert create_meta.prior_state == "importing"
      assert create_meta.new_state == "published"
      assert Map.has_key?(create_meta, :failure_class)
      # No uploaded content may surface in telemetry metadata.
      refute Map.has_key?(create_meta, :content)
      refute Map.has_key?(create_meta, :file)
    end

    test "failed transitions report the status captured before the locked update" do
      organization = organization_fixture()
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staged"})

      handler_id = make_ref()
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:gtfs_planner, :import_publication, :transition],
        fn event, measurements, meta, _config ->
          send(test_pid, {:telemetry, event, measurements, meta})
        end,
        %{}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, _failed} =
               Versions.fail_unpublished_gtfs_version(organization.id, staging.id)

      assert_receive {:telemetry, _, _, meta}
      assert meta.version_id == staging.id
      assert meta.prior_state == @staging_status
      assert meta.new_state == @failed_status
      assert is_nil(meta.failure_class)
    end

    test "invalid and missing transitions emit scoped failure telemetry with actual state" do
      organization = organization_fixture()
      {:ok, published} = Versions.create_gtfs_version(organization.id, %{name: "Published"})
      missing_id = Ecto.UUID.generate()

      handler_id = make_ref()
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:gtfs_planner, :import_publication, :transition],
        fn event, measurements, meta, _config ->
          send(test_pid, {:telemetry, event, measurements, meta})
        end,
        %{}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:error, :invalid_status_transition} =
               Versions.claim_staging_gtfs_version(organization.id, published.id)

      assert {:error, :not_found} =
               Versions.claim_staging_gtfs_version(organization.id, missing_id)

      assert_receive {:telemetry, _, _, invalid_meta}
      assert invalid_meta.organization_id == organization.id
      assert invalid_meta.version_id == published.id
      assert invalid_meta.prior_state == @published_status
      assert invalid_meta.new_state == @published_status
      assert invalid_meta.failure_class == :invalid_status_transition

      assert_receive {:telemetry, _, _, missing_meta}
      assert missing_meta.organization_id == organization.id
      assert missing_meta.version_id == missing_id
      assert missing_meta.prior_state == "unknown"
      assert missing_meta.new_state == "unknown"
      assert missing_meta.failure_class == :not_found
    end
  end

  describe "active schedule: first usable version" do
    test "an organization's default version is its first active schedule" do
      organization = organization_fixture()
      [first] = Versions.list_published_gtfs_versions(organization.id)

      assert selection(organization) == {first.id, 1}
    end

    test "the first usable creation selects once; staging, failed and later versions do not replace it" do
      organization = organization_without_version_fixture()
      {:ok, staged} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staged"})
      {:ok, failing} = Versions.create_staging_gtfs_version(organization.id, %{name: "Failing"})
      {:ok, _failed} = Versions.fail_unpublished_gtfs_version(organization.id, failing.id)

      assert selection(organization) == {nil, 0}
      assert {:error, _invalid} = Versions.create_gtfs_version(organization.id, %{name: nil})
      assert selection(organization) == {nil, 0}

      {:ok, first} = Versions.create_gtfs_version(organization.id, %{name: "First"})
      assert selection(organization) == {first.id, 1}

      {:ok, _later} = Versions.create_gtfs_version(organization.id, %{name: "Later"})
      {:ok, _importing} = Versions.claim_staging_gtfs_version(organization.id, staged.id)
      {:ok, _published} = Versions.publish_importing_gtfs_version(organization.id, staged.id)

      assert selection(organization) == {first.id, 1}
    end

    test "publishing the first imported version selects it, and a refused publish selects nothing" do
      organization = organization_without_version_fixture()
      {:ok, staged} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staged"})

      assert {:error, :invalid_status_transition} =
               Versions.publish_importing_gtfs_version(organization.id, staged.id)

      {:ok, _importing} = Versions.claim_staging_gtfs_version(organization.id, staged.id)
      assert selection(organization) == {nil, 0}

      {:ok, published} = Versions.publish_importing_gtfs_version(organization.id, staged.id)
      assert selection(organization) == {published.id, 1}
    end

    test "a selection is announced when it changes and not when it does not" do
      organization = organization_without_version_fixture()
      subscribe(organization)

      {:ok, first} = Versions.create_gtfs_version(organization.id, %{name: "First"})
      first_id = first.id
      assert_receive {:active_schedule_changed, %{version_id: ^first_id, revision: 1}}

      {:ok, _later} = Versions.create_gtfs_version(organization.id, %{name: "Later"})
      refute_receive {:active_schedule_changed, _token}, 50
    end
  end

  describe "active_schedule/1" do
    test "returns the active version with the token that identifies it" do
      organization = organization_fixture()
      scope = editor_scope(organization)
      [first] = Versions.list_published_gtfs_versions(organization.id)
      first_id = first.id

      assert {:ok, %{version: %GtfsVersion{id: ^first_id}, token: token}} =
               Versions.active_schedule(scope)

      assert token == %{version_id: first_id, revision: 1}
    end

    test "reports an organization with no active schedule by a token with no version" do
      organization = organization_without_version_fixture()

      assert {:ok, %{version: nil, token: %{version_id: nil, revision: 0}}} =
               Versions.active_schedule(editor_scope(organization))
    end

    test "refuses a revoked editor, a non-editor and an editor of another organization" do
      organization = organization_fixture()
      editor = editor_fixture(organization)
      membership = Repo.get_by!(UserOrgMembership, user_id: editor.id)
      scope = %{actor_id: editor.id, organization_id: organization.id}

      admin = user_fixture()
      organization_membership_fixture(admin, organization, ["pathways_studio_admin"])

      assert {:error, :forbidden} =
               Versions.active_schedule(%{actor_id: admin.id, organization_id: organization.id})

      assert {:error, :forbidden} =
               Versions.active_schedule(%{
                 actor_id: editor.id,
                 organization_id: organization_fixture().id
               })

      deactivate_membership_fixture(membership)
      assert {:error, :forbidden} = Versions.active_schedule(scope)
    end
  end

  describe "set_active_schedule/3" do
    setup do
      organization = organization_fixture()
      [first] = Versions.list_published_gtfs_versions(organization.id)
      {:ok, second} = Versions.create_gtfs_version(organization.id, %{name: "Second"})
      scope = editor_scope(organization)
      {:ok, %{token: token}} = Versions.active_schedule(scope)

      %{organization: organization, first: first, second: second, scope: scope, token: token}
    end

    test "selects a published version, advances the revision once and returns the new token", c do
      second_id = c.second.id

      assert {:ok, %{version: %GtfsVersion{id: ^second_id}, token: token}} =
               Versions.set_active_schedule(c.scope, second_id, c.token)

      assert token == %{version_id: second_id, revision: 2}
      assert selection(c.organization) == {second_id, 2}
    end

    test "announces a change after it commits", c do
      subscribe(c.organization)
      second_id = c.second.id

      {:ok, _active} = Versions.set_active_schedule(c.scope, second_id, c.token)

      assert_receive {:active_schedule_changed, %{version_id: ^second_id, revision: 2}}
    end

    test "selecting the version that is already active changes and announces nothing", c do
      subscribe(c.organization)

      assert {:ok, %{token: token}} =
               Versions.set_active_schedule(c.scope, c.first.id, c.token)

      assert token == c.token
      assert selection(c.organization) == {c.first.id, 1}
      refute_receive {:active_schedule_changed, _token}, 50
    end

    test "selects from an organization whose pointer is empty using the empty token", c do
      clear_pointer(c.organization)
      {:ok, %{version: nil, token: empty}} = Versions.active_schedule(c.scope)
      assert empty == %{version_id: nil, revision: 1}

      assert {:ok, %{token: %{version_id: first_id, revision: 2}}} =
               Versions.set_active_schedule(c.scope, c.first.id, empty)

      assert first_id == c.first.id
    end

    test "a return to the same version still leaves an older token stale", c do
      {:ok, %{token: moved}} = Versions.set_active_schedule(c.scope, c.second.id, c.token)
      {:ok, %{token: returned}} = Versions.set_active_schedule(c.scope, c.first.id, moved)

      # `c.token` showed the first version at revision 1 and the first version is active again.
      assert returned == %{version_id: c.first.id, revision: 3}

      assert {:error, :stale_active} = Versions.set_active_schedule(c.scope, c.second.id, c.token)
      assert {:error, :stale_active} = Versions.set_active_schedule(c.scope, c.second.id, moved)
      assert selection(c.organization) == {c.first.id, 3}

      assert {:ok, %{token: %{revision: 4}}} =
               Versions.set_active_schedule(c.scope, c.second.id, returned)
    end

    test "treats a forged or malformed expectation as stale and writes nothing", c do
      first_id = c.first.id

      for forged <- [
            nil,
            "token",
            %{},
            %{version_id: first_id},
            %{version_id: first_id, revision: "1"},
            %{version_id: c.second.id, revision: 1},
            %{version_id: nil, revision: 1}
          ] do
        assert {:error, :stale_active} =
                 Versions.set_active_schedule(c.scope, c.second.id, forged)
      end

      assert selection(c.organization) == {first_id, 1}
    end

    test "refuses staging, importing and failed versions", c do
      {:ok, staging} = Versions.create_staging_gtfs_version(c.organization.id, %{name: "Staging"})
      {:ok, importing} = Versions.create_staging_gtfs_version(c.organization.id, %{name: "Busy"})
      {:ok, _} = Versions.claim_staging_gtfs_version(c.organization.id, importing.id)
      {:ok, failed} = Versions.create_staging_gtfs_version(c.organization.id, %{name: "Failed"})
      {:ok, _} = Versions.fail_unpublished_gtfs_version(c.organization.id, failed.id)

      for unusable <- [staging, importing, failed] do
        assert {:error, :not_usable} =
                 Versions.set_active_schedule(c.scope, unusable.id, c.token)
      end

      assert selection(c.organization) == {c.first.id, 1}
    end

    test "treats another organization's version and a malformed id as not found", c do
      foreign = gtfs_version_fixture(organization_fixture().id)

      for missing <- [foreign.id, Ecto.UUID.generate(), "not-a-uuid", nil] do
        assert {:error, :not_found} = Versions.set_active_schedule(c.scope, missing, c.token)
      end

      assert selection(c.organization) == {c.first.id, 1}
    end

    test "refuses a revoked editor, a non-editor and a scope without an actor", c do
      editor = Repo.get_by!(UserOrgMembership, user_id: c.scope.actor_id)
      admin = user_fixture()
      organization_membership_fixture(admin, c.organization, ["pathways_studio_admin"])

      assert {:error, :forbidden} =
               Versions.set_active_schedule(
                 %{actor_id: admin.id, organization_id: c.organization.id},
                 c.second.id,
                 c.token
               )

      assert {:error, :forbidden} =
               Versions.set_active_schedule(
                 %{actor_id: nil, organization_id: c.organization.id},
                 c.second.id,
                 c.token
               )

      assert {:error, :forbidden} = Versions.set_active_schedule(%{}, c.second.id, c.token)

      deactivate_membership_fixture(editor)

      assert {:error, :forbidden} = Versions.set_active_schedule(c.scope, c.second.id, c.token)
      assert selection(c.organization) == {c.first.id, 1}
    end

    test "an editor of another organization cannot select through a claimed organization", c do
      other = organization_fixture()
      other_scope = editor_scope(other)

      assert {:error, :forbidden} =
               Versions.set_active_schedule(
                 %{other_scope | organization_id: c.organization.id},
                 c.second.id,
                 c.token
               )

      {:ok, %{token: other_token}} = Versions.active_schedule(other_scope)

      assert {:error, :not_found} =
               Versions.set_active_schedule(other_scope, c.second.id, other_token)

      assert selection(c.organization) == {c.first.id, 1}
      assert {_, 1} = selection(other)
    end
  end

  describe "lock_active_schedule!/2" do
    setup do
      organization = organization_fixture()
      [first] = Versions.list_published_gtfs_versions(organization.id)
      {:ok, second} = Versions.create_gtfs_version(organization.id, %{name: "Second"})
      scope = editor_scope(organization)
      {:ok, %{token: token}} = Versions.active_schedule(scope)

      %{organization: organization, first: first, second: second, scope: scope, token: token}
    end

    test "returns the locked active version and its token inside a transaction", c do
      first_id = c.first.id
      token = c.token

      assert {:ok, %{version: %GtfsVersion{id: ^first_id}, token: ^token}} =
               Repo.transaction(fn -> Versions.lock_active_schedule!(c.scope, c.token) end)
    end

    test "rolls the transaction back when the selection moved since the token was read", c do
      {:ok, _active} = Versions.set_active_schedule(c.scope, c.second.id, c.token)

      assert {:error, :stale_active} =
               Repo.transaction(fn -> Versions.lock_active_schedule!(c.scope, c.token) end)
    end

    test "`:current` locks whatever is active, and still refuses without an editor", c do
      {:ok, %{token: moved}} = Versions.set_active_schedule(c.scope, c.second.id, c.token)
      second_id = c.second.id

      assert {:ok, %{version: %GtfsVersion{id: ^second_id}, token: ^moved}} =
               Repo.transaction(fn -> Versions.lock_active_schedule!(c.scope, :current) end)

      deactivate_membership_fixture(Repo.get_by!(UserOrgMembership, user_id: c.scope.actor_id))

      assert {:error, :forbidden} =
               Repo.transaction(fn -> Versions.lock_active_schedule!(c.scope, :current) end)
    end

    test "rolls the transaction back when nothing is selected", c do
      clear_pointer(c.organization)
      {:ok, %{token: empty}} = Versions.active_schedule(c.scope)

      assert {:error, :no_active_schedule} =
               Repo.transaction(fn -> Versions.lock_active_schedule!(c.scope, empty) end)
    end

    test "rolls the transaction back for a revoked editor", c do
      deactivate_membership_fixture(Repo.get_by!(UserOrgMembership, user_id: c.scope.actor_id))

      assert {:error, :forbidden} =
               Repo.transaction(fn -> Versions.lock_active_schedule!(c.scope, c.token) end)
    end

    test "must run inside a transaction", c do
      assert_raise ArgumentError, ~r/inside Repo.transaction/, fn ->
        Versions.lock_active_schedule!(c.scope, c.token)
      end
    end
  end

  describe "activate_full_publication!/3" do
    setup do
      organization = organization_fixture()
      [first] = Versions.list_published_gtfs_versions(organization.id)
      {:ok, second} = Versions.create_gtfs_version(organization.id, %{name: "Second"})

      %{organization: organization, first: first, second: second}
    end

    test "selects a newer receipt's published source once, and a replay changes nothing", c do
      second_id = c.second.id

      assert {:ok, {:changed, %{version_id: ^second_id, revision: 2}}} =
               receipt(c, 1, second_id)

      assert receipt_state(c.organization) == {second_id, 2, 1}

      assert {:ok, :unchanged} = receipt(c, 1, c.first.id)
      assert receipt_state(c.organization) == {second_id, 2, 1}
    end

    test "consumes a newer receipt for the active version without a new revision, and ignores an older one",
         c do
      assert {:ok, :unchanged} = receipt(c, 3, c.first.id)
      assert receipt_state(c.organization) == {c.first.id, 1, 3}

      assert {:ok, :unchanged} = receipt(c, 2, c.second.id)
      assert receipt_state(c.organization) == {c.first.id, 1, 3}
    end

    test "keeps the pointer for an unpublished, foreign, malformed or absent source but consumes the receipt",
         c do
      {:ok, staging} = Versions.create_staging_gtfs_version(c.organization.id, %{name: "Staging"})
      foreign = gtfs_version_fixture(organization_fixture().id)

      sources = [staging.id, foreign.id, "not-a-uuid", nil]

      for {source, sequence} <- Enum.with_index(sources, 1) do
        assert {:ok, :unavailable} = receipt(c, sequence, source)
      end

      assert receipt_state(c.organization) == {c.first.id, 1, 4}
    end

    test "must run inside a transaction", c do
      assert_raise ArgumentError, ~r/inside Repo.transaction/, fn ->
        Versions.activate_full_publication!(c.organization.id, 1, c.second.id)
      end
    end
  end

  describe "deleting versions" do
    setup do
      organization = organization_fixture()
      [first] = Versions.list_published_gtfs_versions(organization.id)
      {:ok, second} = Versions.create_gtfs_version(organization.id, %{name: "Second"})
      scope = editor_scope(organization)
      {:ok, %{token: token}} = Versions.active_schedule(scope)

      %{organization: organization, first: first, second: second, scope: scope, token: token}
    end

    test "the active version cannot be deleted until another one is selected", c do
      assert_raise Postgrex.Error, ~r/organizations_active_gtfs_version_owner_fkey/, fn ->
        Repo.delete_all(from(v in GtfsVersion, where: v.id == ^c.first.id), mode: :savepoint)
      end

      assert Repo.get(GtfsVersion, c.first.id)
      assert selection(c.organization) == {c.first.id, 1}

      {:ok, _active} = Versions.set_active_schedule(c.scope, c.second.id, c.token)

      assert {1, _} = Repo.delete_all(from(v in GtfsVersion, where: v.id == ^c.first.id))
      assert selection(c.organization) == {c.second.id, 2}
    end

    test "a version that is not active deletes without touching the selection", c do
      assert {1, _} = Repo.delete_all(from(v in GtfsVersion, where: v.id == ^c.second.id))

      assert selection(c.organization) == {c.first.id, 1}
    end

    test "the organization still deletes while a version is active", c do
      assert {:ok, _deleted} = Organizations.delete_organization(c.organization)

      refute Repo.get(Organization, c.organization.id)
      assert [] = Repo.all(from(v in GtfsVersion, where: v.organization_id == ^c.organization.id))
    end
  end

  describe "selection under concurrent writers" do
    setup do
      supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
      %{supervisor: supervisor}
    end

    test "two first versions created at once leave one pointer and one revision", %{
      supervisor: supervisor
    } do
      organization = unboxed(&organization_without_version_fixture/0)
      on_exit(fn -> unboxed(fn -> delete_committed_scope!([organization.id]) end) end)

      commands =
        for name <- ["First A", "First B"] do
          start_command(supervisor, fn ->
            Versions.create_gtfs_version(organization.id, %{name: name})
          end)
        end

      Enum.each(commands, &send(&1.pid, :go))
      results = Enum.map(commands, &Task.await(&1.task, @collect_timeout))

      assert [{:ok, a}, {:ok, b}] = results
      {pointer, revision} = unboxed(fn -> selection(organization) end)
      assert revision == 1
      assert pointer in [a.id, b.id]
    end

    test "a selection and a publication racing for an empty pointer leave one consistent winner",
         %{supervisor: supervisor} do
      %{organization: organization, scope: scope, second: second, importing: importing} =
        unboxed(fn ->
          organization = organization_fixture()
          scope = editor_scope(organization)
          {:ok, second} = Versions.create_gtfs_version(organization.id, %{name: "Second"})
          {:ok, staged} = Versions.create_staging_gtfs_version(organization.id, %{name: "Third"})
          {:ok, importing} = Versions.claim_staging_gtfs_version(organization.id, staged.id)
          clear_pointer(organization)
          %{organization: organization, scope: scope, second: second, importing: importing}
        end)

      on_exit(fn -> unboxed(fn -> delete_committed_scope!([organization.id]) end) end)
      empty = %{version_id: nil, revision: 1}

      holder = start_organization_holder(supervisor, organization)

      select =
        start_command(supervisor, fn ->
          Versions.set_active_schedule(scope, second.id, empty)
        end)

      publish =
        start_command(supervisor, fn ->
          Versions.publish_importing_gtfs_version(organization.id, importing.id)
        end)

      Enum.each([select, publish], &send(&1.pid, :go))
      assert_waiting(select)
      assert_waiting(publish)
      send(holder.pid, :release)

      assert {:ok, :held} = Task.await(holder.task, @collect_timeout)
      select_result = Task.await(select.task, @collect_timeout)
      assert {:ok, _published} = Task.await(publish.task, @collect_timeout)

      # Whichever commits first wins and the other either keeps it or reports stale; the
      # revision moved once, and a selection never overwrites the first writer's pointer.
      final = unboxed(fn -> selection(organization) end)

      case select_result do
        {:ok, _active} -> assert final == {second.id, 2}
        {:error, :stale_active} -> assert final == {importing.id, 2}
      end
    end

    test "a held active-schedule lock makes a selection change wait", %{supervisor: supervisor} do
      %{organization: organization, scope: scope, second: second, token: token} =
        unboxed(fn ->
          organization = organization_fixture()
          scope = editor_scope(organization)
          {:ok, second} = Versions.create_gtfs_version(organization.id, %{name: "Second"})
          {:ok, %{token: token}} = Versions.active_schedule(scope)
          %{organization: organization, scope: scope, second: second, token: token}
        end)

      on_exit(fn -> unboxed(fn -> delete_committed_scope!([organization.id]) end) end)

      holder =
        start_holder(supervisor, fn ->
          Versions.lock_active_schedule!(scope, token)
        end)

      select =
        start_command(supervisor, fn ->
          Versions.set_active_schedule(scope, second.id, token)
        end)

      send(select.pid, :go)
      assert_blocked_by(select, holder)
      send(holder.task.pid, :release)

      assert {:ok, :held} = Task.await(holder.task, @collect_timeout)
      assert {:ok, %{token: %{revision: 2}}} = Task.await(select.task, @collect_timeout)
    end

    test "a membership command waiting on the editor's row does not deadlock with a selection",
         %{supervisor: supervisor} do
      %{organization: organization, scope: scope, second: second, token: token, admin: admin} =
        unboxed(fn ->
          organization = organization_fixture()
          scope = editor_scope(organization)
          admin = user_fixture()
          organization_membership_fixture(admin, organization, ["pathways_studio_admin"])
          {:ok, second} = Versions.create_gtfs_version(organization.id, %{name: "Second"})
          {:ok, %{token: token}} = Versions.active_schedule(scope)

          %{
            organization: organization,
            scope: scope,
            second: second,
            token: token,
            admin: admin
          }
        end)

      on_exit(fn -> unboxed(fn -> delete_committed_scope!([organization.id]) end) end)

      # A membership command takes the organization row, then the member's row. It holds the
      # organization here, so the selection waits for it before it holds anything.
      command =
        start_holder(
          supervisor,
          fn -> Authorization.lock_member_admin!(admin, organization.id) end,
          fn ->
            Repo.update_all(
              from(m in UserOrgMembership,
                where: m.user_id == ^scope.actor_id and m.organization_id == ^organization.id
              ),
              set: [deactivated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
            )
          end
        )

      select =
        start_command(supervisor, fn ->
          Versions.set_active_schedule(scope, second.id, token)
        end)

      send(select.pid, :go)
      assert_blocked_by(select, command)
      send(command.pid, :release)

      assert {:ok, :held} = Task.await(command.task, @collect_timeout)
      assert {:error, :forbidden} = Task.await(select.task, @collect_timeout)
      assert {_, 1} = unboxed(fn -> selection(organization) end)
    end
  end

  # --- helpers ---

  defp editor_scope(organization) do
    editor = editor_fixture(organization)
    %{actor_id: editor.id, organization_id: organization.id}
  end

  defp selection(organization) do
    organization = Repo.get!(Organization, organization.id)
    {organization.active_gtfs_version_id, organization.active_gtfs_version_revision}
  end

  defp receipt(c, sequence, source_version_id) do
    Repo.transaction(fn ->
      Versions.activate_full_publication!(c.organization.id, sequence, source_version_id)
    end)
  end

  defp receipt_state(organization) do
    organization = Repo.get!(Organization, organization.id)

    {organization.active_gtfs_version_id, organization.active_gtfs_version_revision,
     organization.active_full_publication_sequence}
  end

  # The state of an organization that predates active selection.
  defp clear_pointer(organization) do
    from(o in Organization, where: o.id == ^organization.id)
    |> Repo.update_all(set: [active_gtfs_version_id: nil])
  end

  defp subscribe(organization) do
    Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, Versions.active_schedule_topic(organization.id))
  end

  # A committing task parked until `:go`, so several commands can start together.
  defp start_command(supervisor, command) do
    parent = self()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          send(parent, {:ready, self(), backend_pid()})

          receive do
            :go -> :ok
          after
            @contention_timeout -> raise "command was not released"
          end

          command.()
        end)
      end)

    assert_receive {:ready, pid, backend}, @contention_timeout
    assert pid == task.pid
    %{task: task, pid: pid, backend: backend}
  end

  # A transaction that holds whatever `acquire` locks until `:release`, then runs `finish`
  # in the same transaction before it commits.
  defp start_holder(supervisor, acquire, finish \\ fn -> :ok end) do
    parent = self()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn -> hold(parent, acquire, finish) end)
      end)

    assert_receive {:held, pid, backend}, @contention_timeout
    assert pid == task.pid
    %{task: task, pid: pid, backend: backend}
  end

  defp hold(parent, acquire, finish) do
    Repo.transaction(fn ->
      acquire.()
      send(parent, {:held, self(), backend_pid()})

      receive do
        :release -> :ok
      after
        @contention_timeout -> raise "holder was not released"
      end

      finish.()
      :held
    end)
  end

  defp start_organization_holder(supervisor, organization) do
    start_holder(supervisor, fn -> Versions.lock_organization!(organization.id) end)
  end

  # The second writer queued behind the same row waits for the first writer, not the holder.
  defp assert_waiting(waiting) do
    deadline = System.monotonic_time(:millisecond) + @contention_timeout
    assert :ok == unboxed(fn -> await_waiting(waiting.backend, deadline) end)
  end

  defp await_waiting(backend, deadline) do
    %Postgrex.Result{rows: [[blockers]]} =
      Repo.query!("SELECT cardinality(pg_blocking_pids($1))", [backend])

    cond do
      blockers > 0 ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :not_waiting}

      true ->
        receive do
        after
          10 -> await_waiting(backend, deadline)
        end
    end
  end

  defp assert_blocked_by(waiting, holder) do
    deadline = System.monotonic_time(:millisecond) + @contention_timeout
    assert :ok == unboxed(fn -> await_blocker(waiting.backend, holder.backend, deadline) end)
  end

  defp organization_without_version_fixture do
    {:ok, org} =
      %GtfsPlanner.Organizations.Organization{}
      |> GtfsPlanner.Organizations.Organization.changeset(%{
        alias: "test-org-#{System.unique_integer()}",
        name: "Test Org"
      })
      |> Repo.insert()

    org
  end

  defp set_published_at(%GtfsVersion{} = version, datetime) do
    from(v in GtfsVersion, where: v.id == ^version.id)
    |> Repo.update_all(set: [published_at: datetime])
  end
end
