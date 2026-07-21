defmodule GtfsPlannerWeb.AssignOrganizationTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.AssignOrganization

  @deactivated_flash "Your account has been deactivated in this organization."
  @missing_org_flash "Your account has no organization assigned. Contact an administrator."
  @not_found_flash "Organization not found"
  @unauthenticated_flash "You must log in to access this page."

  describe "on_mount :optional" do
    test "assigns complete nil/empty shape and system_administrator without organization queries" do
      admin = system_administrator_fixture()
      org = organization_fixture()
      {:ok, _} = Versions.create_gtfs_version(org.id, %{name: "Should Not Load"})

      socket = build_socket(admin)
      session = %{"organization_id" => org.id}

      assert {:cont, socket} = AssignOrganization.on_mount(:optional, %{}, session, socket)

      assert_safe_shape(socket, :system_administrator)

      refute Map.has_key?(socket.private, :lifecycle) and
               lifecycle_has_rename_hook?(socket)
    end

    test "returns available for active membership with published versions only" do
      organization = organization_fixture()
      user = user_fixture()

      {:ok, _} =
        Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: organization.id,
          roles: ["pathways_studio_editor", "pathways_studio_admin"]
        })

      {:ok, older} = Versions.create_gtfs_version(organization.id, %{name: "Older Published"})
      {:ok, newer} = Versions.create_gtfs_version(organization.id, %{name: "Newer Published"})

      {:ok, _staging} =
        Versions.create_staging_gtfs_version(organization.id, %{name: "Staging Only"})

      socket = build_socket(user)
      session = %{"organization_id" => organization.id}

      assert {:cont, socket} = AssignOrganization.on_mount(:optional, %{}, session, socket)

      assert socket.assigns.organization_context_status == :available
      assert socket.assigns.current_organization.id == organization.id

      assert Enum.sort(socket.assigns.user_roles) ==
               ["pathways_studio_admin", "pathways_studio_editor"]

      assert {newer.id, "Newer Published"} in socket.assigns.available_versions
      assert {older.id, "Older Published"} in socket.assigns.available_versions
      assert socket.assigns.current_gtfs_version.id == newer.id
      assert socket.assigns.current_gtfs_version.name == "Newer Published"

      refute Enum.any?(socket.assigns.available_versions, fn {_id, name} ->
               name == "Staging Only"
             end)
    end

    test "returns missing when session has no organization_id" do
      user = user_fixture()
      organization = organization_fixture()

      {:ok, _} =
        Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: organization.id,
          roles: ["pathways_studio_editor"]
        })

      socket = build_socket(user)

      assert {:cont, socket} = AssignOrganization.on_mount(:optional, %{}, %{}, socket)
      assert_safe_shape(socket, :missing)
    end

    test "returns unavailable for absent organization without tenant metadata" do
      user = user_fixture()
      missing_id = Ecto.UUID.generate()
      socket = build_socket(user)
      session = %{"organization_id" => missing_id}

      assert {:cont, socket} = AssignOrganization.on_mount(:optional, %{}, session, socket)
      assert_safe_shape(socket, :unavailable)
    end

    test "returns unavailable for cross-tenant organization without tenant metadata" do
      user = user_fixture()
      own_org = organization_fixture()
      other_org = organization_fixture()

      {:ok, _} =
        Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: own_org.id,
          roles: ["pathways_studio_editor"]
        })

      {:ok, _} = Versions.create_gtfs_version(other_org.id, %{name: "Foreign Secret"})

      socket = build_socket(user)
      session = %{"organization_id" => other_org.id}

      assert {:cont, socket} = AssignOrganization.on_mount(:optional, %{}, session, socket)
      assert_safe_shape(socket, :unavailable)
    end

    test "returns unavailable for non-member of existing organization" do
      user = user_fixture()
      organization = organization_fixture()
      {:ok, _} = Versions.create_gtfs_version(organization.id, %{name: "Hidden"})

      socket = build_socket(user)
      session = %{"organization_id" => organization.id}

      assert {:cont, socket} = AssignOrganization.on_mount(:optional, %{}, session, socket)
      assert_safe_shape(socket, :unavailable)
    end

    test "deactivated membership revokes session token, flashes, redirects, and halts" do
      organization = organization_fixture()
      user = user_fixture()

      {:ok, membership} =
        Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: organization.id,
          roles: ["pathways_studio_editor"]
        })

      deactivate_membership!(membership)

      token = Accounts.generate_user_session_token(user)
      assert Accounts.get_user_by_session_token(token)

      socket =
        user
        |> build_socket()
        |> put_connect_params(%{"user_token" => token})

      session = %{"organization_id" => organization.id}

      assert {:halt, socket} = AssignOrganization.on_mount(:optional, %{}, session, socket)

      assert phoenix_flash(socket, :error) == @deactivated_flash
      assert socket_redirect_to(socket) == "/users/log_in"
      refute Accounts.get_user_by_session_token(token)

      refute Map.has_key?(socket.assigns, :current_organization) and
               match?(%Organizations.Organization{}, socket.assigns[:current_organization])
    end

    test "deactivated membership still halts when connect params omit token" do
      organization = organization_fixture()
      user = user_fixture()

      {:ok, membership} =
        Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: organization.id,
          roles: ["pathways_studio_editor"]
        })

      deactivate_membership!(membership)

      socket = build_socket(user)
      session = %{"organization_id" => organization.id}

      assert {:halt, socket} = AssignOrganization.on_mount(:optional, %{}, session, socket)
      assert phoenix_flash(socket, :error) == @deactivated_flash
      assert socket_redirect_to(socket) == "/users/log_in"
    end
  end

  describe "on_mount :default" do
    test "missing current user redirects instead of raising during membership lookup" do
      organization = organization_fixture()
      socket = build_socket(nil)
      session = %{"organization_id" => organization.id}

      assert {:halt, socket} = AssignOrganization.on_mount(:default, %{}, session, socket)
      assert phoenix_flash(socket, :error) == @unauthenticated_flash
      assert socket_redirect_to(socket) == "/users/log_in"
    end

    test "administrator bypass continues without organization assigns" do
      admin = system_administrator_fixture()
      socket = build_socket(admin)

      assert {:cont, socket} = AssignOrganization.on_mount(:default, %{}, %{}, socket)
      refute Map.has_key?(socket.assigns, :current_organization)
      refute Map.has_key?(socket.assigns, :organization_context_status)
    end

    test "valid membership assigns organization, roles, published versions, and rename hook" do
      organization = organization_fixture()
      user = user_fixture()

      {:ok, _} =
        Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: organization.id,
          roles: ["pathways_studio_admin"]
        })

      {:ok, published} = Versions.create_gtfs_version(organization.id, %{name: "Published"})
      {:ok, _staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})

      socket = build_socket(user)
      session = %{"organization_id" => organization.id}

      assert {:cont, socket} = AssignOrganization.on_mount(:default, %{}, session, socket)

      assert socket.assigns.current_organization.id == organization.id
      assert socket.assigns.user_roles == ["pathways_studio_admin"]
      assert {published.id, "Published"} in socket.assigns.available_versions
      refute Enum.any?(socket.assigns.available_versions, fn {_id, name} -> name == "Staging" end)
      assert socket.assigns.current_gtfs_version.id == published.id
      refute Map.has_key?(socket.assigns, :organization_context_status)
    end

    test "missing organization_id redirects to login" do
      user = user_fixture()
      socket = build_socket(user)

      assert {:halt, socket} = AssignOrganization.on_mount(:default, %{}, %{}, socket)
      assert phoenix_flash(socket, :error) == @missing_org_flash
      assert socket_redirect_to(socket) == "/users/log_in"
    end

    test "stale organization redirects to login" do
      user = user_fixture()
      socket = build_socket(user)
      session = %{"organization_id" => Ecto.UUID.generate()}

      assert {:halt, socket} = AssignOrganization.on_mount(:default, %{}, session, socket)
      assert phoenix_flash(socket, :error) == @not_found_flash
      assert socket_redirect_to(socket) == "/users/log_in"
    end

    test "deactivated membership revokes token, flashes, redirects, and halts" do
      organization = organization_fixture()
      user = user_fixture()

      {:ok, membership} =
        Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: organization.id,
          roles: ["pathways_studio_editor"]
        })

      deactivate_membership!(membership)

      token = Accounts.generate_user_session_token(user)
      assert Accounts.get_user_by_session_token(token)

      socket =
        user
        |> build_socket()
        |> put_connect_params(%{"user_token" => token})

      session = %{"organization_id" => organization.id}

      assert {:halt, socket} = AssignOrganization.on_mount(:default, %{}, session, socket)

      assert phoenix_flash(socket, :error) == @deactivated_flash
      assert socket_redirect_to(socket) == "/users/log_in"
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "rename refresh" do
    test "reloads published tuples and replaces only the matching current version" do
      organization = organization_fixture()
      user = user_fixture()

      {:ok, _} =
        Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: organization.id,
          roles: ["pathways_studio_editor"]
        })

      {:ok, older} = Versions.create_gtfs_version(organization.id, %{name: "Older"})
      {:ok, newer} = Versions.create_gtfs_version(organization.id, %{name: "Newer"})

      socket = build_socket(user)
      session = %{"organization_id" => organization.id}

      assert {:cont, socket} = AssignOrganization.on_mount(:optional, %{}, session, socket)
      assert socket.assigns.current_gtfs_version.id == newer.id

      {:ok, renamed_current} = Versions.update_gtfs_version(newer, %{name: "Newer Renamed"})
      socket = invoke_rename_hook(socket, renamed_current)

      assert socket.assigns.current_gtfs_version.id == newer.id
      assert socket.assigns.current_gtfs_version.name == "Newer Renamed"
      assert {newer.id, "Newer Renamed"} in socket.assigns.available_versions
      assert {older.id, "Older"} in socket.assigns.available_versions

      {:ok, renamed_other} = Versions.update_gtfs_version(older, %{name: "Older Renamed"})
      socket = invoke_rename_hook(socket, renamed_other)

      assert socket.assigns.current_gtfs_version.id == newer.id
      assert socket.assigns.current_gtfs_version.name == "Newer Renamed"
      assert {older.id, "Older Renamed"} in socket.assigns.available_versions
      refute {older.id, "Older"} in socket.assigns.available_versions
    end

    test "required mode rename refresh matches optional available behavior" do
      organization = organization_fixture()
      user = user_fixture()

      {:ok, _} =
        Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: organization.id,
          roles: ["pathways_studio_editor"]
        })

      {:ok, version} = Versions.create_gtfs_version(organization.id, %{name: "Original"})

      socket = build_socket(user)
      session = %{"organization_id" => organization.id}

      assert {:cont, socket} = AssignOrganization.on_mount(:default, %{}, session, socket)

      {:ok, renamed} = Versions.update_gtfs_version(version, %{name: "Renamed"})
      socket = invoke_rename_hook(socket, renamed)

      assert socket.assigns.current_gtfs_version.name == "Renamed"
      assert {version.id, "Renamed"} in socket.assigns.available_versions
    end
  end

  defp system_administrator_fixture do
    admin = user_fixture()
    org = organization_fixture()

    {:ok, _} =
      Accounts.create_user_org_membership(%{
        user_id: admin.id,
        organization_id: org.id,
        roles: ["administrator"]
      })

    admin
  end

  defp deactivate_membership!(membership) do
    membership
    |> Ecto.Changeset.change(%{
      deactivated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update!()
  end

  defp build_socket(user) do
    %Phoenix.LiveView.Socket{
      endpoint: GtfsPlannerWeb.Endpoint,
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_user: user
      },
      private: %{
        connect_params: %{},
        live_temp: %{flash: %{}},
        lifecycle: %Phoenix.LiveView.Lifecycle{}
      }
    }
  end

  defp put_connect_params(socket, params) do
    private = Map.put(socket.private, :connect_params, params)
    %{socket | private: private}
  end

  defp assert_safe_shape(socket, status) do
    assert socket.assigns.organization_context_status == status
    assert socket.assigns.current_organization == nil
    assert socket.assigns.user_roles == []
    assert socket.assigns.available_versions == []
    assert socket.assigns.current_gtfs_version == nil
  end

  defp phoenix_flash(socket, kind) do
    flash = socket.assigns.flash

    cond do
      is_map(flash) and Map.has_key?(flash, Atom.to_string(kind)) ->
        flash[Atom.to_string(kind)]

      is_map(flash) and Map.has_key?(flash, kind) ->
        flash[kind]

      true ->
        Phoenix.Flash.get(flash, kind)
    end
  end

  defp socket_redirect_to(socket) do
    case socket.redirected do
      {:redirect, %{to: to}} -> to
      {:live, :redirect, %{to: to}} -> to
      other -> flunk("expected redirect, got: #{inspect(other)}")
    end
  end

  defp lifecycle_has_rename_hook?(socket) do
    case socket.private[:lifecycle] do
      %Phoenix.LiveView.Lifecycle{handle_info: hooks} ->
        Enum.any?(hooks, fn hook -> hook.id == :refresh_gtfs_versions_after_rename end)

      _ ->
        false
    end
  end

  defp invoke_rename_hook(socket, updated_version) do
    hooks = lifecycle_hooks(socket)

    hook =
      Enum.find(hooks, fn h -> h.id == :refresh_gtfs_versions_after_rename end) ||
        flunk("rename hook not attached")

    msg = {:gtfs_version_renamed, updated_version}

    case hook.stage do
      :handle_info ->
        :ok
    end

    hook.function
    |> invoke_hook(Function.info(hook.function, :arity), msg, socket)
    |> unwrap_hook_result()
  end

  defp lifecycle_hooks(socket) do
    case socket.private[:lifecycle] do
      %Phoenix.LiveView.Lifecycle{handle_info: hooks} -> hooks
      _ -> []
    end
  end

  defp invoke_hook(function, {:arity, 2}, msg, socket), do: function.(msg, socket)
  defp invoke_hook(function, {:arity, 3}, msg, socket), do: function.(msg, %{}, socket)

  defp unwrap_hook_result(result) do
    case result do
      {:halt, socket} -> socket
      {:cont, socket} -> socket
      other -> flunk("unexpected rename hook result: #{inspect(other)}")
    end
  end
end
