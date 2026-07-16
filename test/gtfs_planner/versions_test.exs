defmodule GtfsPlanner.VersionsTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion
  alias GtfsPlanner.Repo

  import GtfsPlanner.OrganizationsFixtures

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

    test "get_gtfs_version!/1 returns the version with the given id" do
      organization = organization_fixture()
      {:ok, version} = Versions.create_gtfs_version(organization.id, %{name: "Test Version"})

      fetched_version = Versions.get_gtfs_version!(version.id)
      assert fetched_version.id == version.id
      assert fetched_version.name == "Test Version"
    end

    test "get_gtfs_version!/1 raises for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Versions.get_gtfs_version!(Ecto.UUID.generate())
      end
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
      assert Enum.map(versions, fn {_id, name} -> name end) == ["First Version", "Version 2", "Version 1"]
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
      assert %GtfsVersion{} = found = Versions.get_published_gtfs_version_for_org(org1.id, published.id)
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
        from(v in GtfsVersion, where: v.id == ^staging.id, select: {v.publication_status, v.published_at})
        |> Repo.one!()

      assert elem(final, 0) == @published_status
      assert not is_nil(elem(final, 1))
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

      :telemetry.attach(handler_id, [:gtfs_planner, :import_publication, :transition], fn event,
                                                                                          measurements,
                                                                                          meta,
                                                                                          _config ->
        send(test_pid, {:telemetry, event, measurements, meta})
      end, %{})

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
  end

  # --- helpers ---

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
