defmodule GtfsPlanner.OrganizationsTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Organizations.AdminReadAdapterMock
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Organizations.ApiKey

  import ExUnit.CaptureLog
  import Mox
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.AccountsFixtures

  @adapter_key :organizations_admin_read_adapter

  describe "list_organizations/0" do
    test "returns all organizations" do
      org1 = organization_fixture()
      org2 = organization_fixture()

      assert Organizations.list_organizations() == [org1, org2]
    end

    test "returns empty list when no organizations exist" do
      assert Organizations.list_organizations() == []
    end
  end

  describe "get_organization/1" do
    test "returns nil if id does not exist" do
      refute Organizations.get_organization(Ecto.UUID.generate())
    end

    test "returns the organization with the given id" do
      organization = organization_fixture()
      assert Organizations.get_organization(organization.id) == organization
    end
  end

  describe "get_organization!/1" do
    test "raises if id does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        Organizations.get_organization!(Ecto.UUID.generate())
      end
    end

    test "returns the organization with the given id" do
      organization = organization_fixture()
      assert Organizations.get_organization!(organization.id) == organization
    end
  end

  describe "get_organization_by_alias/1" do
    test "does not return the organization if the alias does not exist" do
      refute Organizations.get_organization_by_alias("nonexistent")
    end

    test "returns the organization if the alias exists" do
      %{alias: alias} = organization = organization_fixture()
      assert %Organization{id: id} = Organizations.get_organization_by_alias(alias)
      assert id == organization.id
    end

    test "normalizes aliases to lowercase" do
      # Alias "MyOrg" is normalized to "myorg" during creation
      _organization = organization_fixture(%{alias: "MyOrg"})

      # Only lowercase lookup works because aliases are normalized
      assert Organizations.get_organization_by_alias("myorg")
      refute Organizations.get_organization_by_alias("MyOrg")
      refute Organizations.get_organization_by_alias("MYORG")
    end
  end

  describe "create_organization/1" do
    test "requires alias and name to be set" do
      {:error, changeset} = Organizations.create_organization(%{})

      assert %{
               alias: ["can't be blank"],
               name: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "validates alias and name when given" do
      {:error, changeset} =
        Organizations.create_organization(%{alias: "", name: ""})

      assert %{
               alias: ["can't be blank"],
               name: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "validates alias uniqueness" do
      %{alias: alias} = organization_fixture()

      {:error, changeset} =
        Organizations.create_organization(%{
          alias: alias,
          name: "Another Name"
        })

      assert "has already been taken" in errors_on(changeset).alias
    end

    test "creates organization with valid attributes" do
      attrs = valid_organization_attributes()

      assert {:ok, %Organization{} = organization} =
               Organizations.create_organization(attrs)

      assert organization.alias == attrs.alias
      assert organization.name == attrs.name
    end
  end

  describe "update_organization/2" do
    setup do
      %{organization: organization_fixture()}
    end

    test "requires name to be set", %{organization: organization} do
      {:error, changeset} =
        Organizations.update_organization(organization, %{name: ""})

      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates alias uniqueness on update", %{organization: organization} do
      other_org = organization_fixture()

      {:error, changeset} =
        Organizations.update_organization(organization, %{alias: other_org.alias})

      assert "has already been taken" in errors_on(changeset).alias
    end

    test "updates organization with valid attributes", %{organization: organization} do
      new_name = "Updated Organization Name"

      assert {:ok, %Organization{} = updated} =
               Organizations.update_organization(organization, %{name: new_name})

      assert updated.name == new_name
      assert updated.id == organization.id
    end
  end

  describe "delete_organization/1" do
    test "deletes the organization" do
      organization = organization_fixture()

      assert {:ok, %Organization{}} =
               Organizations.delete_organization(organization)

      refute Repo.get(Organization, organization.id)
    end

    test "cascades delete to API keys" do
      organization = organization_fixture()
      {api_key, _token} = api_key_fixture(organization)

      assert {:ok, %Organization{}} =
               Organizations.delete_organization(organization)

      refute Repo.get(Organization, organization.id)
      refute Repo.get(ApiKey, api_key.id)
    end
  end

  describe "change_organization/2" do
    test "returns a changeset" do
      assert %Ecto.Changeset{} =
               changeset = Organizations.change_organization(%Organization{})

      assert changeset.required == [:alias, :name]
    end

    test "allows changes to alias and name" do
      attrs = valid_organization_attributes()

      changeset =
        Organizations.change_organization(%Organization{}, attrs)

      assert changeset.valid?
      assert get_change(changeset, :alias) == attrs.alias
      assert get_change(changeset, :name) == attrs.name
    end
  end

  describe "list_api_keys/1" do
    test "returns API keys for organization" do
      organization = organization_fixture()
      {api_key1, _token1} = api_key_fixture(organization, %{description: "Key 1"})
      {api_key2, _token2} = api_key_fixture(organization, %{description: "Key 2"})

      api_keys = Organizations.list_api_keys(organization.id)

      assert length(api_keys) == 2
      assert api_key1 in api_keys
      assert api_key2 in api_keys
    end

    test "returns empty list for organization with no API keys" do
      organization = organization_fixture()

      api_keys = Organizations.list_api_keys(organization.id)

      assert api_keys == []
    end

    test "does not return API keys from other organizations" do
      org1 = organization_fixture()
      org2 = organization_fixture()

      {api_key, _token} = api_key_fixture(org1)

      api_keys = Organizations.list_api_keys(org2.id)

      refute api_key in api_keys
    end
  end

  describe "get_api_key!/1" do
    setup do
      organization = organization_fixture()
      {api_key, _token} = api_key_fixture(organization)

      %{api_key: api_key}
    end

    test "raises if id does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        Organizations.get_api_key!(Ecto.UUID.generate())
      end
    end

    test "returns the API key with the given id", %{api_key: api_key} do
      assert Organizations.get_api_key!(api_key.id) == api_key
    end
  end

  describe "get_api_key_by_token/1" do
    setup do
      organization = organization_fixture()
      {api_key, token} = api_key_fixture(organization)

      %{api_key: api_key, token: token}
    end

    test "returns API key for valid token", %{api_key: api_key, token: token} do
      assert {:ok, found_key} = Organizations.get_api_key_by_token(token)
      assert found_key.id == api_key.id
    end

    test "returns error for invalid token" do
      assert {:error, :invalid} =
               Organizations.get_api_key_by_token("GtfsPlanner.V1.invalidtoken")
    end

    test "returns error for malformed token" do
      assert {:error, :invalid} =
               Organizations.get_api_key_by_token("invalid")
    end
  end

  describe "create_api_key/2" do
    test "creates API key with valid attributes" do
      organization = organization_fixture()
      attrs = valid_api_key_attributes()

      assert {:ok, {%ApiKey{} = api_key, token}} =
               Organizations.create_api_key(organization.id, attrs)

      assert api_key.organization_id == organization.id
      assert api_key.description == attrs.description
      assert api_key.roles == attrs.roles
      assert api_key.version == 1
      assert is_binary(api_key.secret_hash)
      assert is_binary(token)
      assert String.starts_with?(token, "GtfsPlanner.V1.")
    end

    test "requires description to be set" do
      organization = organization_fixture()

      {:error, changeset} =
        Organizations.create_api_key(organization.id, %{description: ""})

      assert %{description: ["can't be blank"]} = errors_on(changeset)
    end

    test "creates API key with custom roles" do
      organization = organization_fixture()

      {:ok, {%ApiKey{} = api_key, _token}} =
        Organizations.create_api_key(organization.id, %{
          description: "Admin Key",
          roles: ["pathways_studio_admin", "pathways_studio_editor"]
        })

      assert api_key.roles == ["pathways_studio_admin", "pathways_studio_editor"]
    end

    test "creates API key with empty roles" do
      organization = organization_fixture()

      {:ok, {%ApiKey{} = api_key, _token}} =
        Organizations.create_api_key(organization.id, %{
          description: "No Roles Key",
          roles: []
        })

      assert api_key.roles == []
    end
  end

  describe "update_api_key/2" do
    setup do
      organization = organization_fixture()
      {api_key, _token} = api_key_fixture(organization)

      %{api_key: api_key}
    end

    test "updates API key with valid attributes", %{api_key: api_key} do
      new_description = "Updated Description"

      assert {:ok, %ApiKey{} = updated} =
               Organizations.update_api_key(api_key, %{description: new_description})

      assert updated.description == new_description
      assert updated.id == api_key.id
    end

    test "updates API key roles", %{api_key: api_key} do
      new_roles = ["pathways_studio_admin", "pathways_studio_editor"]

      assert {:ok, %ApiKey{} = updated} =
               Organizations.update_api_key(api_key, %{roles: new_roles})

      assert updated.roles == new_roles
    end

    test "returns error with invalid attributes", %{api_key: api_key} do
      {:error, changeset} =
        Organizations.update_api_key(api_key, %{description: nil})

      assert %{description: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "delete_api_key/1" do
    test "deletes the API key" do
      organization = organization_fixture()
      {api_key, _token} = api_key_fixture(organization)

      assert {:ok, %ApiKey{}} = Organizations.delete_api_key(api_key)
      refute Repo.get(ApiKey, api_key.id)
    end
  end

  describe "change_api_key/2" do
    test "returns a changeset" do
      assert %Ecto.Changeset{} =
               changeset = Organizations.change_api_key(%ApiKey{})

      assert changeset.required == [:description]
    end

    test "allows fields to be set" do
      api_key = %ApiKey{}

      changeset =
        Organizations.change_api_key(api_key, %{
          description: "Test Key",
          roles: ["read"]
        })

      assert changeset.valid?
    end
  end

  describe "organization changeset" do
    test "normalizes alias to lowercase with hyphens" do
      changeset =
        Organization.changeset(%Organization{}, %{
          name: "Test Org",
          alias: "  My Test Org!@#  "
        })

      assert changeset.changes.alias == "my-test-org"
    end

    test "validates alias and name length" do
      long_string = String.duplicate("a", 256)

      changeset =
        Organization.changeset(%Organization{}, %{
          name: long_string,
          alias: long_string
        })

      assert "should be at most 255 character(s)" in errors_on(changeset).name
      assert "should be at most 255 character(s)" in errors_on(changeset).alias
    end

    test "trims whitespace from name on create" do
      {:ok, organization} =
        Organizations.create_organization(%{name: "  Acme  ", alias: "acme-trim-create"})

      assert organization.name == "Acme"
    end

    test "trims whitespace from name on update" do
      organization = organization_fixture()

      {:ok, updated} =
        Organizations.update_organization(organization, %{name: "  Trimmed Name  "})

      assert updated.name == "Trimmed Name"
    end

    test "alias normalization is unchanged when input has surrounding whitespace" do
      padded_changeset =
        Organization.changeset(%Organization{}, %{name: "Demo Org", alias: "  Demo Org  "})

      trimmed_changeset =
        Organization.changeset(%Organization{}, %{name: "Demo Org", alias: "Demo Org"})

      assert get_change(padded_changeset, :alias) == get_change(trimmed_changeset, :alias)
      assert get_change(padded_changeset, :alias) == "demo-org"
    end
  end

  describe "api key changeset" do
    test "trims whitespace from description on create" do
      organization = organization_fixture()

      {:ok, {api_key, _token}} =
        Organizations.create_api_key(organization.id, %{description: "  My Key  "})

      assert api_key.description == "My Key"
    end

    test "trims whitespace from description on update" do
      organization = organization_fixture()
      {api_key, _token} = api_key_fixture(organization)

      {:ok, updated} =
        Organizations.update_api_key(api_key, %{description: "  Updated Key  "})

      assert updated.description == "Updated Key"
    end

    test "trims description before length validation" do
      long_string = String.duplicate("a", 255)
      padded = "  " <> long_string <> "  "

      changeset =
        ApiKey.changeset(%ApiKey{}, %{description: padded, organization_id: Ecto.UUID.generate()})

      assert changeset.valid?
      assert get_change(changeset, :description) == long_string
    end
  end

  describe "add_user_to_organization/3" do
    test "adds user with roles" do
      user = user_fixture()
      organization = organization_fixture()

      assert {:ok, membership} =
               Organizations.add_user_to_organization(
                 user.id,
                 organization.id,
                 ["administrator"]
               )

      assert membership.user_id == user.id
      assert membership.organization_id == organization.id
      assert membership.roles == ["administrator"]
    end

    test "adds user without roles" do
      user = user_fixture()
      organization = organization_fixture()

      assert {:ok, membership} =
               Organizations.add_user_to_organization(user.id, organization.id)

      assert membership.user_id == user.id
      assert membership.organization_id == organization.id
      assert membership.roles == []
    end

    test "returns error when user already in organization" do
      user = user_fixture()
      organization = organization_fixture()

      {:ok, _membership1} =
        Organizations.add_user_to_organization(user.id, organization.id)

      assert {:error, changeset} =
               Organizations.add_user_to_organization(user.id, organization.id)

      assert "has already been taken" in errors_on(changeset).user_id
    end
  end

  describe "remove_user_from_organization/2" do
    setup do
      user = user_fixture()
      organization = organization_fixture()

      {:ok, membership} =
        Organizations.add_user_to_organization(user.id, organization.id)

      %{user: user, organization: organization, membership: membership}
    end

    test "removes user from organization", %{
      user: user,
      organization: organization,
      membership: membership
    } do
      assert {:ok, _deleted} =
               Organizations.remove_user_from_organization(user.id, organization.id)

      refute Repo.get(GtfsPlanner.Accounts.UserOrgMembership, membership.id)
    end

    test "returns error when membership does not exist" do
      user = user_fixture()
      organization = organization_fixture()

      assert {:error, :not_found} =
               Organizations.remove_user_from_organization(user.id, organization.id)
    end
  end

  describe "update_user_roles/3" do
    setup do
      user = user_fixture()
      organization = organization_fixture()

      {:ok, _membership} =
        Organizations.add_user_to_organization(
          user.id,
          organization.id,
          ["pathways_studio_editor"]
        )

      %{user: user, organization: organization}
    end

    test "updates user roles", %{user: user, organization: organization} do
      new_roles = ["pathways_studio_admin", "pathways_studio_editor"]

      assert {:ok, membership} =
               Organizations.update_user_roles(user.id, organization.id, new_roles)

      assert membership.roles == new_roles
    end

    test "updates to empty roles", %{user: user, organization: organization} do
      assert {:ok, membership} =
               Organizations.update_user_roles(user.id, organization.id, [])

      assert membership.roles == []
    end

    test "returns error when membership does not exist" do
      user = user_fixture()
      organization = organization_fixture()

      assert {:error, :not_found} =
               Organizations.update_user_roles(user.id, organization.id, ["admin"])
    end
  end

  describe "list_organizations_for_user/1" do
    test "returns user's organizations with roles" do
      user = user_fixture()
      org1 = organization_fixture()
      org2 = organization_fixture()

      {:ok, _} =
        Organizations.add_user_to_organization(user.id, org1.id, ["pathways_studio_admin"])

      {:ok, _} =
        Organizations.add_user_to_organization(user.id, org2.id, ["pathways_studio_editor"])

      orgs = Organizations.list_organizations_for_user(user.id)

      assert length(orgs) == 2

      org1_result = Enum.find(orgs, &(&1.id == org1.id))
      org2_result = Enum.find(orgs, &(&1.id == org2.id))

      assert org1_result.user_roles == ["pathways_studio_admin"]
      assert org2_result.user_roles == ["pathways_studio_editor"]
    end

    test "returns empty list for user with no organizations" do
      user = user_fixture()

      orgs = Organizations.list_organizations_for_user(user.id)

      assert orgs == []
    end
  end

  describe "list_users_in_organization/1" do
    test "returns organization's users with roles" do
      org = organization_fixture()
      user1 = user_fixture()
      user2 = user_fixture()

      {:ok, _} =
        Organizations.add_user_to_organization(user1.id, org.id, ["pathways_studio_admin"])

      {:ok, _} =
        Organizations.add_user_to_organization(user2.id, org.id, ["pathways_studio_editor"])

      users = Organizations.list_users_in_organization(org.id)

      assert length(users) == 2

      user1_result = Enum.find(users, &(&1.user.id == user1.id))
      user2_result = Enum.find(users, &(&1.user.id == user2.id))

      assert user1_result.roles == ["pathways_studio_admin"]
      assert user2_result.roles == ["pathways_studio_editor"]
    end

    test "returns empty list for organization with no users" do
      org = organization_fixture()

      users = Organizations.list_users_in_organization(org.id)

      assert users == []
    end

    test "does not return users from other organizations" do
      org1 = organization_fixture()
      org2 = organization_fixture()

      user = user_fixture()
      {:ok, _} = Organizations.add_user_to_organization(user.id, org1.id)

      users_in_org2 = Organizations.list_users_in_organization(org2.id)

      refute Enum.any?(users_in_org2, &(&1.user.id == user.id))
    end

    test "orders users by email" do
      org = organization_fixture()

      user1 = user_fixture(%{email: "zulu@example.com"})
      user2 = user_fixture(%{email: "alpha@example.com"})

      {:ok, _} = Organizations.add_user_to_organization(user1.id, org.id)
      {:ok, _} = Organizations.add_user_to_organization(user2.id, org.id)

      users = Organizations.list_users_in_organization(org.id)

      assert List.first(users).user.email == "alpha@example.com"
      assert List.last(users).user.email == "zulu@example.com"
    end
  end

  describe "list_organizations_for_admin/0 with the default Repo adapter" do
    test "returns every organization in the same shape as the raw read" do
      org1 = organization_fixture()
      org2 = organization_fixture()

      assert Organizations.list_organizations_for_admin() == {:ok, [org1, org2]}
    end

    test "returns an empty list when no organization exists" do
      assert Organizations.list_organizations_for_admin() == {:ok, []}
    end
  end

  describe "fetch_organization_for_admin/1 with the default Repo adapter" do
    test "returns the organization for a stored id" do
      organization = organization_fixture()

      assert Organizations.fetch_organization_for_admin(organization.id) ==
               {:ok, organization}
    end

    test "returns not_found for a well-formed but absent organization id" do
      assert Organizations.fetch_organization_for_admin(Ecto.UUID.generate()) ==
               {:error, :not_found}
    end

    test "raises rather than reporting unavailable for a malformed organization id" do
      assert_raise Ecto.Query.CastError, fn ->
        Organizations.fetch_organization_for_admin("not-a-uuid")
      end
    end
  end

  describe "list_users_for_admin/1 with the default Repo adapter" do
    test "returns members with the existing user, roles, and deactivated_at shape" do
      org = organization_fixture()
      user = user_fixture(%{email: "alpha@example.com"})

      {:ok, _} =
        Organizations.add_user_to_organization(user.id, org.id, ["pathways_studio_admin"])

      assert {:ok, [member]} = Organizations.list_users_for_admin(org.id)
      assert %{user: %GtfsPlanner.Accounts.User{}, roles: _, deactivated_at: _} = member
      assert Enum.sort(Map.keys(member)) == [:deactivated_at, :roles, :user]
      assert member.user.id == user.id
      assert member.roles == ["pathways_studio_admin"]
      assert member.deactivated_at == nil
    end

    test "returns exactly what the raw member read returns, including ordering" do
      org = organization_fixture()
      zulu = user_fixture(%{email: "zulu@example.com"})
      alpha = user_fixture(%{email: "alpha@example.com"})

      {:ok, _} = Organizations.add_user_to_organization(zulu.id, org.id)
      {:ok, _} = Organizations.add_user_to_organization(alpha.id, org.id)
      {:ok, _} = Organizations.deactivate_user_in_organization(zulu.id, org.id)

      raw = Organizations.list_users_in_organization(org.id)

      assert Organizations.list_users_for_admin(org.id) == {:ok, raw}
      assert Enum.map(raw, & &1.user.email) == ["alpha@example.com", "zulu@example.com"]
      assert Enum.find(raw, &(&1.user.id == zulu.id)).deactivated_at != nil
    end

    test "returns an empty list for an organization with no members" do
      org = organization_fixture()

      assert Organizations.list_users_for_admin(org.id) == {:ok, []}
    end

    test "returns an empty list for a well-formed but absent organization id" do
      assert Organizations.list_users_for_admin(Ecto.UUID.generate()) == {:ok, []}
    end

    test "raises rather than reporting unavailable for a malformed organization id" do
      assert_raise Ecto.Query.CastError, fn ->
        Organizations.list_users_for_admin("not-a-uuid")
      end
    end
  end

  describe "administration reads with a configured adapter" do
    setup :verify_on_exit!

    setup do
      previous = Application.fetch_env(:gtfs_planner, @adapter_key)
      Application.put_env(:gtfs_planner, @adapter_key, AdminReadAdapterMock)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:gtfs_planner, @adapter_key, value)
          :error -> Application.delete_env(:gtfs_planner, @adapter_key)
        end
      end)

      :ok
    end

    test "each wrapper delegates to the configured adapter" do
      organization = organization_fixture()
      member = %{user: user_fixture(), roles: ["pathways_studio_admin"], deactivated_at: nil}

      expect(AdminReadAdapterMock, :list_organizations, fn -> {:ok, [organization]} end)

      expect(AdminReadAdapterMock, :fetch_organization, fn id ->
        assert id == organization.id
        {:ok, organization}
      end)

      expect(AdminReadAdapterMock, :list_users, fn id ->
        assert id == organization.id
        {:ok, [member]}
      end)

      assert Organizations.list_organizations_for_admin() == {:ok, [organization]}
      assert Organizations.fetch_organization_for_admin(organization.id) == {:ok, organization}
      assert Organizations.list_users_for_admin(organization.id) == {:ok, [member]}
    end

    test "each wrapper reports unavailable when the configured adapter reports it" do
      id = Ecto.UUID.generate()

      expect(AdminReadAdapterMock, :list_organizations, fn -> {:error, :unavailable} end)
      expect(AdminReadAdapterMock, :fetch_organization, fn _ -> {:error, :unavailable} end)
      expect(AdminReadAdapterMock, :list_users, fn _ -> {:error, :unavailable} end)

      assert Organizations.list_organizations_for_admin() == {:error, :unavailable}
      assert Organizations.fetch_organization_for_admin(id) == {:error, :unavailable}
      assert Organizations.list_users_for_admin(id) == {:error, :unavailable}
    end

    test "fetch_organization_for_admin/1 reports not_found when the adapter reports it" do
      expect(AdminReadAdapterMock, :fetch_organization, fn _ -> {:error, :not_found} end)

      assert Organizations.fetch_organization_for_admin(Ecto.UUID.generate()) ==
               {:error, :not_found}
    end

    test "raw read APIs keep their current return values while an adapter is configured" do
      organization = organization_fixture()
      user = user_fixture()

      {:ok, _} =
        Organizations.add_user_to_organization(user.id, organization.id, [
          "pathways_studio_admin"
        ])

      assert Organizations.list_organizations() == [organization]
      assert Organizations.get_organization(organization.id) == organization
      assert Organizations.get_organization(Ecto.UUID.generate()) == nil

      assert [%{user: %{id: user_id}, roles: ["pathways_studio_admin"], deactivated_at: nil}] =
               Organizations.list_users_in_organization(organization.id)

      assert user_id == user.id
    end

    test "an adapter exception is not translated into unavailable" do
      expect(AdminReadAdapterMock, :list_organizations, fn -> raise ArgumentError, "boom" end)

      assert_raise ArgumentError, "boom", fn ->
        Organizations.list_organizations_for_admin()
      end
    end

    test "the configured adapter is resolved per call, not memoized at compile time" do
      Application.delete_env(:gtfs_planner, @adapter_key)
      organization = organization_fixture()

      assert Organizations.list_organizations_for_admin() == {:ok, [organization]}
    end
  end

  describe "AdminReadAdapter.Repo connection failures" do
    alias GtfsPlanner.Organizations.AdminReadAdapter

    test "maps only DBConnection.ConnectionError to unavailable" do
      id = Ecto.UUID.generate()

      capture_log(fn ->
        with_unreachable_repo(fn ->
          assert AdminReadAdapter.Repo.list_organizations() == {:error, :unavailable}
          assert AdminReadAdapter.Repo.fetch_organization(id) == {:error, :unavailable}
          assert AdminReadAdapter.Repo.list_users(id) == {:error, :unavailable}
        end)
      end)
    end

    test "leaves a cast error visible instead of reporting unavailable" do
      assert_raise Ecto.Query.CastError, fn ->
        AdminReadAdapter.Repo.fetch_organization("not-a-uuid")
      end

      assert_raise Ecto.Query.CastError, fn ->
        AdminReadAdapter.Repo.list_users("not-a-uuid")
      end
    end
  end

  # Points the calling process at a real but unreachable Postgres pool so that
  # every checkout is dropped from the queue with a DBConnection.ConnectionError.
  defp with_unreachable_repo(fun) do
    {:ok, pid} =
      GtfsPlanner.Repo.start_link(
        name: nil,
        hostname: "127.0.0.1",
        port: 1,
        username: "postgres",
        password: "postgres",
        database: "gtfs_planner_unreachable",
        pool: DBConnection.ConnectionPool,
        pool_size: 1,
        queue_target: 20,
        queue_interval: 20,
        connect_timeout: 100,
        log: false
      )

    previous = GtfsPlanner.Repo.get_dynamic_repo()
    GtfsPlanner.Repo.put_dynamic_repo(pid)

    try do
      fun.()
    after
      GtfsPlanner.Repo.put_dynamic_repo(previous)
      Supervisor.stop(pid)
    end
  end
end
