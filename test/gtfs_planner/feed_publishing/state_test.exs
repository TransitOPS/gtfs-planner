defmodule GtfsPlanner.FeedPublishing.StateTest do
  @moduledoc """
  Merge evidence (EV-2) for CL-2 and CL-5: a first public claim is decided by the
  database, a claimed prefix is permanent, and organization deletion is refused
  while publication state remains (AC-2, AC-3, AC-23; FH-2, FH-5).

  Every case calls the production commands `FeedPublishing.claim_namespace/1`,
  `FeedPublishing.status/1` and `Organizations.delete_organization/1` against real
  Ecto transactions, `Authorization.lock_editor!/1` and real foreign keys. Nothing
  here contacts storage or the network.

  The racing-claim case commits its own disposable organization, editor and
  membership on an own connection, because two concurrent claims must each see and
  decide the other's insert; `cleanup_committed_scope/1` deletes exactly those rows
  in `on_exit`, even when the case fails. Its proof boundary is one PostgreSQL
  server: the unique indexes and `ON CONFLICT DO NOTHING` decide one owner, while
  lock scheduling, multi-node deployment and network partitions are outside it.

  The focused gate command is deferred to branch review:
  `MIX_TEST_PARTITION=_feedpub mix test test/gtfs_planner/feed_publishing/state_test.exs`.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.FeedPublishing
  alias GtfsPlanner.FeedPublishing.Attempt
  alias GtfsPlanner.FeedPublishing.Namespace
  alias GtfsPlanner.FeedPublishing.Publication
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo

  @moduletag timeout: 120_000

  @task_timeout 15_000

  describe "claim_namespace/1" do
    test "claims the current alias once with a fresh opaque claim" do
      organization = organization_fixture(%{alias: "rivercity"})
      scope = editor_scope(organization)

      assert {:ok, %Namespace{} = namespace} = FeedPublishing.claim_namespace(scope)
      assert namespace.prefix == "rivercity"
      assert namespace.organization_id == organization.id
      assert byte_size(namespace.public_claim) > 16
      refute namespace.public_claim == organization.alias

      assert {:ok, ^namespace} = FeedPublishing.claim_namespace(scope)
      assert namespace_count(organization) == 1
    end

    test "two concurrent first claims of one alias yield one owner" do
      scope = committed_scope()
      on_exit(fn -> cleanup_committed_scope(scope) end)

      results =
        [1, 2]
        |> Enum.map(fn _ ->
          Task.async(fn -> unboxed(fn -> FeedPublishing.claim_namespace(scope) end) end)
        end)
        |> Enum.map(&Task.await(&1, @task_timeout))

      assert [{:ok, %Namespace{} = first} | _] = results
      assert Enum.all?(results, &match?({:ok, %Namespace{}}, &1))
      assert [owner] = results |> Enum.map(fn {:ok, namespace} -> namespace.id end) |> Enum.uniq()
      assert owner == first.id
      assert unboxed(fn -> committed_namespace_count(scope) end) == 1
    end

    test "an alias rename preserves the claimed prefix and claim" do
      organization = organization_fixture(%{alias: "rivercity"})
      scope = editor_scope(organization)
      assert {:ok, first} = FeedPublishing.claim_namespace(scope)

      admin = system_admin_fixture(organization)

      assert {:ok, renamed} =
               Organizations.update_organization(admin, organization, %{alias: "river-city-metro"})

      assert renamed.alias == "river-city-metro"

      assert {:ok, ^first} = FeedPublishing.claim_namespace(scope)
      assert namespace_count(organization) == 1
    end

    test "another tenant cannot adopt a claimed prefix" do
      organization = organization_fixture(%{alias: "rivercity"})
      scope = editor_scope(organization)
      assert {:ok, namespace} = FeedPublishing.claim_namespace(scope)

      other = organization_fixture(%{alias: "southbank"})
      other_scope = editor_scope(other)

      assert {:ok, %Namespace{prefix: "southbank"}} = FeedPublishing.claim_namespace(other_scope)
      assert namespace_count(other) == 1
      assert Repo.aggregate(from(n in Namespace, where: n.prefix == "rivercity"), :count) == 1

      # A third organization that has claimed nothing is the only one whose own
      # insert can reach the permanent prefix's unique index; `other` already
      # holds a namespace, so its organization index would fire first.
      unclaimed = organization_fixture(%{alias: "eastbank"})

      assert_raise Ecto.ConstraintError, ~r/feed_publication_namespaces_prefix_index/, fn ->
        Repo.insert!(
          Namespace.claim_changeset(unclaimed.id, "rivercity", "another-claim"),
          mode: :savepoint
        )
      end

      assert Repo.get!(Namespace, namespace.id).organization_id == organization.id
    end

    test "reserved and unsafe segments fail visibly without renaming the organization" do
      for reserved <- ["images", "fonts"] do
        organization = organization_fixture(%{alias: reserved})
        scope = editor_scope(organization)

        assert {:error, :reserved_prefix} = FeedPublishing.claim_namespace(scope)
        assert Repo.get!(Organization, organization.id).alias == reserved
        assert namespace_count(organization) == 0
      end

      for unsafe <- ["River City Transit", "-rivercity", "rivercity-", "river city/../admin"] do
        organization = unsafe_alias_organization(unsafe)
        scope = editor_scope(organization)

        assert {:error, :invalid_prefix} = FeedPublishing.claim_namespace(scope)
        assert Repo.get!(Organization, organization.id).alias == unsafe
        assert namespace_count(organization) == 0
      end
    end

    test "a revoked editor membership refuses a first claim" do
      organization = organization_fixture(%{alias: "rivercity"})
      scope = editor_scope(organization)
      deactivate_membership_fixture(membership_for(scope))

      assert {:error, :forbidden} = FeedPublishing.claim_namespace(scope)
      assert namespace_count(organization) == 0
    end

    test "a scope without a current editor membership is forbidden" do
      organization = organization_fixture(%{alias: "rivercity"})

      assert {:error, :forbidden} =
               FeedPublishing.claim_namespace(%{organization_id: organization.id, actor_id: nil})

      other = organization_fixture()

      assert {:error, :forbidden} =
               FeedPublishing.claim_namespace(%{
                 organization_id: Ecto.UUID.generate(),
                 actor_id: editor_scope(organization).actor_id
               })

      assert {:error, :forbidden} =
               FeedPublishing.claim_namespace(%{
                 organization_id: other.id,
                 actor_id: editor_scope(organization).actor_id
               })
    end
  end

  describe "status/1" do
    test "lists the organization's channels with their namespace and attempt" do
      organization = organization_fixture(%{alias: "rivercity"})
      scope = editor_scope(organization)
      assert {:ok, namespace} = FeedPublishing.claim_namespace(scope)

      publication =
        Repo.insert!(%Publication{
          organization_id: organization.id,
          namespace_id: namespace.id,
          channel: :alerts,
          status: :current
        })

      assert {:ok, [%Publication{} = listed]} = FeedPublishing.status(scope)
      assert listed.id == publication.id
      assert listed.status == :current
      assert listed.desired_revision == 0
      assert listed.next_sequence == 1
      assert %Namespace{id: namespace_id} = listed.namespace
      assert namespace_id == namespace.id
      assert listed.active_attempt == nil
    end

    test "is empty before any channel exists and refuses other tenants" do
      organization = organization_fixture(%{alias: "rivercity"})
      scope = editor_scope(organization)

      assert {:ok, []} = FeedPublishing.status(scope)

      other = organization_fixture()
      other_scope = editor_scope(other)

      assert {:error, :forbidden} =
               FeedPublishing.status(%{
                 organization_id: organization.id,
                 actor_id: other_scope.actor_id
               })

      assert {:error, :forbidden} = FeedPublishing.status(%{organization_id: nil, actor_id: nil})
    end
  end

  describe "delete_organization/1" do
    test "is refused while a channel is current, staged or unknown" do
      for status <- [:current, :pending, :staging, :switching, :reconciling, :blocked, :failed] do
        alias_name = "rivercity-#{status}"
        organization = organization_fixture(%{alias: alias_name})
        scope = editor_scope(organization)
        assert {:ok, namespace} = FeedPublishing.claim_namespace(scope)

        Repo.insert!(%Publication{
          organization_id: organization.id,
          namespace_id: namespace.id,
          channel: :alerts,
          status: status
        })

        assert {:error, {:publications_retained, [:alerts]}} =
                 Organizations.delete_organization(organization)

        assert Repo.get!(Organization, organization.id).alias == alias_name
        assert namespace_count(organization) == 1
      end
    end

    test "is refused while only an attempt or namespace remains, and deleted without them" do
      organization = organization_fixture(%{alias: "rivercity"})
      scope = editor_scope(organization)
      assert {:ok, namespace} = FeedPublishing.claim_namespace(scope)

      publication =
        Repo.insert!(%Publication{
          organization_id: organization.id,
          namespace_id: namespace.id,
          channel: :full
        })

      attempt =
        Repo.insert!(%Attempt{
          publication_id: publication.id,
          organization_id: organization.id,
          sequence: 1,
          generation: "generation-#{System.unique_integer([:positive])}",
          desired_revision: 0,
          manifest_body: "{}",
          manifest_sha256: String.duplicate("a", 64),
          state: "pending"
        })

      assert {:error, {:publications_retained, [:full]}} =
               Organizations.delete_organization(organization)

      Repo.delete!(attempt)
      Repo.delete!(publication)
      Repo.delete!(namespace)

      assert {:ok, %Organization{}} = Organizations.delete_organization(organization)
      refute Repo.get(Organization, organization.id)
    end

    test "leaves an organization without publication state deletable" do
      organization = organization_fixture()
      assert {:ok, %Organization{}} = Organizations.delete_organization(organization)
      refute Repo.get(Organization, organization.id)
    end

    test "the database refuses a delete that bypasses the command" do
      organization = organization_fixture(%{alias: "rivercity"})
      scope = editor_scope(organization)
      assert {:ok, _namespace} = FeedPublishing.claim_namespace(scope)

      assert_raise Postgrex.Error, ~r/feed_publication_namespaces_organization_id_fkey/, fn ->
        Repo.transaction(fn -> Repo.delete!(organization) end)
      end

      assert Repo.get!(Organization, organization.id)
      assert namespace_count(organization) == 1
    end
  end

  describe "tenant-correct durable records" do
    setup do
      organization = organization_fixture(%{alias: "rivercity"})
      other = organization_fixture(%{alias: "southbank"})

      namespace = Repo.insert!(namespace_record(organization))
      other_namespace = Repo.insert!(namespace_record(other))

      %{
        organization: organization,
        other: other,
        namespace: namespace,
        other_namespace: other_namespace
      }
    end

    test "a publication may not name another organization's namespace", %{
      other: other,
      namespace: namespace
    } do
      assert_raise Ecto.ConstraintError, ~r/feed_publications_namespace_owner_fkey/, fn ->
        Repo.insert!(
          %Publication{
            organization_id: other.id,
            namespace_id: namespace.id,
            channel: :alerts
          },
          mode: :savepoint
        )
      end
    end

    test "an attempt may not name another organization's publication", %{
      organization: organization,
      other: other,
      other_namespace: other_namespace
    } do
      other_publication =
        Repo.insert!(%Publication{
          organization_id: other.id,
          namespace_id: other_namespace.id,
          channel: :alerts
        })

      assert_raise Ecto.ConstraintError,
                   ~r/feed_publication_attempts_publication_owner_fkey/,
                   fn ->
                     attempt_record(organization, other_publication)
                     |> Repo.insert!(mode: :savepoint)
                   end
    end

    test "a channel may not point at another organization's attempt", %{
      organization: organization,
      other: other,
      namespace: namespace,
      other_namespace: other_namespace
    } do
      publication =
        Repo.insert!(%Publication{
          organization_id: organization.id,
          namespace_id: namespace.id,
          channel: :full
        })

      other_publication =
        Repo.insert!(%Publication{
          organization_id: other.id,
          namespace_id: other_namespace.id,
          channel: :full
        })

      foreign_attempt = Repo.insert!(attempt_record(other, other_publication))

      assert_raise Ecto.ConstraintError, ~r/feed_publications_active_attempt_owner_fkey/, fn ->
        publication
        |> Ecto.Changeset.change(active_attempt_id: foreign_attempt.id)
        |> Repo.update!(mode: :savepoint)
      end

      attempt = Repo.insert!(attempt_record(organization, publication))

      publication =
        Repo.update!(Ecto.Changeset.change(publication, active_attempt_id: attempt.id))

      assert publication.active_attempt_id == attempt.id
    end

    test "unknown channels and statuses are refused", %{
      organization: organization,
      namespace: namespace
    } do
      # Ecto's `Ecto.Enum` field refuses an unknown channel or status before the
      # statement is built, so the database check constraints are only reachable
      # through raw SQL. The savepoint keeps the sandbox transaction usable for the
      # second assertion.
      assert_raise Postgrex.Error, ~r/feed_publications_channel_known/, fn ->
        Repo.query!(
          """
          INSERT INTO feed_publications
            (id, organization_id, namespace_id, channel, status, inserted_at, updated_at)
          VALUES
            (gen_random_uuid(), $1::text::uuid, $2::text::uuid, 'tods', 'never_published',
             now(), now())
          """,
          [organization.id, namespace.id],
          mode: :savepoint
        )
      end

      assert_raise Postgrex.Error, ~r/feed_publications_status_known/, fn ->
        Repo.query!(
          """
          INSERT INTO feed_publications
            (id, organization_id, namespace_id, channel, status, inserted_at, updated_at)
          VALUES
            (gen_random_uuid(), $1::text::uuid, $2::text::uuid, 'alerts', 'disabled',
             now(), now())
          """,
          [organization.id, namespace.id],
          mode: :savepoint
        )
      end
    end

    test "one organization cannot hold the same channel twice", %{
      organization: organization,
      namespace: namespace
    } do
      Repo.insert!(%Publication{
        organization_id: organization.id,
        namespace_id: namespace.id,
        channel: :alerts
      })

      assert_raise Ecto.ConstraintError,
                   ~r/feed_publications_organization_id_channel_index/,
                   fn ->
                     Repo.insert!(
                       %Publication{
                         organization_id: organization.id,
                         namespace_id: namespace.id,
                         channel: :alerts
                       },
                       mode: :savepoint
                     )
                   end
    end
  end

  # A real editor and the server-side scope map the commands receive.
  defp editor_scope(organization) do
    actor = editor_fixture(organization)

    %{organization_id: organization.id, actor_id: actor.id}
  end

  defp membership_for(scope) do
    Repo.one!(
      from(m in UserOrgMembership,
        where: m.organization_id == ^scope.organization_id and m.user_id == ^scope.actor_id
      )
    )
  end

  # An organization whose stored alias is not a usable public segment. The
  # organization schema normalizes aliases on write, so this row is inserted the
  # way a legacy or imported row can look, to prove the claim refuses it.
  defp unsafe_alias_organization(alias) do
    Repo.insert!(
      Ecto.Changeset.change(
        %Organization{alias: alias, name: "Unsafe Alias"},
        %{alias: alias}
      )
    )
  end

  defp namespace_record(organization) do
    Namespace.claim_changeset(
      organization.id,
      organization.alias,
      Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    )
  end

  defp attempt_record(organization, publication) do
    %Attempt{
      publication_id: publication.id,
      organization_id: organization.id,
      sequence: System.unique_integer([:positive]),
      generation: "generation-#{System.unique_integer([:positive])}",
      desired_revision: 0,
      manifest_body: "{}",
      manifest_sha256: String.duplicate("a", 64),
      state: "pending"
    }
  end

  defp namespace_count(organization) do
    Repo.aggregate(from(n in Namespace, where: n.organization_id == ^organization.id), :count)
  end

  # Committed fixtures for the racing-claim case: the two claims each run on their
  # own connection and must see and decide the same rows.
  defp committed_scope do
    unboxed(fn ->
      organization = organization_fixture(%{alias: "rivercity-race"})
      actor = editor_fixture(organization)

      %{organization_id: organization.id, actor_id: actor.id}
    end)
  end

  defp committed_namespace_count(scope) do
    from(n in Namespace, where: n.organization_id == ^scope.organization_id)
    |> Repo.aggregate(:count)
  end

  defp cleanup_committed_scope(scope) do
    unboxed(fn ->
      Repo.delete_all(from(a in Attempt, where: a.organization_id == ^scope.organization_id))
      Repo.delete_all(from(p in Publication, where: p.organization_id == ^scope.organization_id))
      Repo.delete_all(from(n in Namespace, where: n.organization_id == ^scope.organization_id))
      Repo.delete_all(from(o in Organization, where: o.id == ^scope.organization_id))
      Repo.delete_all(from(u in GtfsPlanner.Accounts.User, where: u.id == ^scope.actor_id))
    end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
