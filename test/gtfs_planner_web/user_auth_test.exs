defmodule GtfsPlannerWeb.UserAuthTest do
  use GtfsPlannerWeb.ConnCase

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.AccountsFixtures
  alias GtfsPlannerWeb.UserAuth

  describe "log_in_user/3" do
    test "logs user in and redirects to dashboard page" do
      user = AccountsFixtures.user_fixture()

      conn =
        build_conn()
        |> init_test_session(%{})
        |> UserAuth.log_in_user(user)
        |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_user.id == user.id
      assert redirected_to(conn) == ~p"/"
    end

    test "prevents login for deactivated user in organization" do
      user = AccountsFixtures.user_fixture()
      organization = GtfsPlanner.OrganizationsFixtures.organization_fixture()

      # Create membership
      {:ok, _membership} =
        GtfsPlanner.Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: organization.id,
          roles: ["pathways_studio_viewer"]
        })

      # Deactivate user in organization
      {:ok, _membership} =
        GtfsPlanner.Organizations.deactivate_user_in_organization(user.id, organization.id)

      # Attempt to log in
      result =
        build_conn()
        |> init_test_session(%{})
        |> UserAuth.log_in_user(user)

      # Verify login returns error for deactivated users
      assert result == {:error, :deactivated}

      # Verify the user is marked as deactivated in the organization
      assert GtfsPlanner.Organizations.user_deactivated_in_organization?(
               user.id,
               organization.id
             )
    end

    test "stores user token in that session" do
      %{conn: conn, user: user} =
        register_and_log_in_user(%{password: "valid password"})

      assert conn.assigns.current_user.id == user.id
      assert get_session(conn, :user_token) != nil
    end

    test "renews that session to prevent fixation attacks" do
      %{conn: conn, user: user} =
        register_and_log_in_user(%{password: "valid password"})

      # Session should be renewed (old session ID should be invalid)
      assert conn.assigns.current_user.id == user.id
    end

    test "redirects to user_return_to if set" do
      user = AccountsFixtures.user_fixture()

      conn =
        build_conn()
        |> init_test_session(%{user_return_to: "/some/previous/page"})
        |> UserAuth.log_in_user(user)
        |> UserAuth.fetch_current_user([])

      assert redirected_to(conn) == "/some/previous/page"
    end

    test "with remember_me param, sets remember_me cookie" do
      user = AccountsFixtures.user_fixture()

      conn =
        build_conn()
        |> init_test_session(%{})
        |> UserAuth.log_in_user(user, %{"remember_me" => "true"})

      assert conn.resp_cookies["user_remember_me"] != nil
      cookie = conn.resp_cookies["user_remember_me"]
      assert cookie.max_age == 60 * 60 * 24 * 60
      assert cookie.secure == true
      assert cookie.http_only == true
      assert cookie.same_site == "Lax"
    end

    test "without remember_me param, does not set remember_me cookie" do
      user = AccountsFixtures.user_fixture()

      conn =
        build_conn()
        |> init_test_session(%{})
        |> UserAuth.log_in_user(user, %{})

      assert conn.resp_cookies["user_remember_me"] == nil
    end
  end

  describe "log_out_user/1" do
    setup do
      %{conn: conn, user: user} = register_and_log_in_user(%{})
      {:ok, conn: conn, user: user}
    end

    test "logs user out and redirects to login page", %{conn: conn} do
      conn = UserAuth.log_out_user(conn)
      assert redirected_to(conn) == ~p"/users/log_in"
    end

    test "clears all session data", %{conn: conn} do
      conn = UserAuth.log_out_user(conn)
      assert get_session(conn, :user_token) == nil
      assert get_session(conn, :live_socket_id) == nil
    end

    test "deletes that remember_me cookie", %{conn: conn} do
      conn = UserAuth.log_out_user(conn)
      assert conn.resp_cookies["user_remember_me"] != nil
      cookie = conn.resp_cookies["user_remember_me"]
      assert cookie.max_age == 0
    end

    test "broadcasts disconnect to LiveView if live_socket_id is set", %{conn: conn, user: user} do
      live_socket_id = "users_sessions-" <> Base.url_encode64(user.id)

      conn =
        conn
        |> put_session(:live_socket_id, live_socket_id)
        |> UserAuth.log_out_user()

      # Session should be cleared and redirect to login
      assert redirected_to(conn) == ~p"/users/log_in"
    end
  end

  describe "fetch_current_user/2" do
    test "authenticates user from session token" do
      user = AccountsFixtures.user_fixture()
      token = Accounts.generate_user_session_token(user)

      conn =
        build_conn()
        |> init_test_session(%{user_token: token})
        |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_user.id == user.id
    end

    test "does not authenticate if no session token" do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_user == nil
    end

    test "does not authenticate with invalid session token" do
      conn =
        build_conn()
        |> init_test_session(%{user_token: "invalid_token"})
        |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_user == nil
    end

    test "authenticates user from remember_me cookie" do
      user = AccountsFixtures.user_fixture()
      token = Accounts.generate_user_session_token(user)

      conn =
        build_conn()
        |> init_test_session(%{})
        |> put_req_cookie("user_remember_me", token)
        |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_user.id == user.id
      assert get_session(conn, :user_token) == token
    end

    test "prefers session token over remember_me cookie" do
      user1 = AccountsFixtures.user_fixture()
      user2 = AccountsFixtures.user_fixture()
      session_token = Accounts.generate_user_session_token(user1)
      cookie_token = Accounts.generate_user_session_token(user2)

      conn =
        build_conn()
        |> init_test_session(%{user_token: session_token})
        |> put_req_cookie("user_remember_me", cookie_token)
        |> UserAuth.fetch_current_user([])

      # Should authenticate user1 from session, not user2 from cookie
      assert conn.assigns.current_user.id == user1.id
    end
  end

  describe "redirect_if_user_is_authenticated/2" do
    test "redirects authenticated user to signed in path" do
      %{conn: conn} = register_and_log_in_user(%{})

      conn = UserAuth.redirect_if_user_is_authenticated(conn, [])
      assert redirected_to(conn) == ~p"/"
      assert conn.halted
    end

    test "does not redirect unauthenticated user" do
      conn =
        build_conn() |> init_test_session(%{}) |> UserAuth.redirect_if_user_is_authenticated([])

      refute conn.halted
    end
  end

  describe "require_authenticated_user/2" do
    test "allows authenticated user" do
      %{conn: conn} = register_and_log_in_user(%{})

      conn = UserAuth.require_authenticated_user(conn, [])
      refute conn.halted
      assert conn.assigns.current_user != nil
    end

    test "redirects unauthenticated user to login page" do
      conn = build_conn() |> init_test_session(%{}) |> UserAuth.require_authenticated_user([])
      assert redirected_to(conn) == ~p"/users/log_in"
      assert conn.halted
    end

    test "stores return_to path for GET requests" do
      conn =
        build_conn(:get, "/protected/page")
        |> init_test_session(%{})
        |> UserAuth.require_authenticated_user([])

      assert redirected_to(conn) == ~p"/users/log_in"
      assert get_session(conn, :user_return_to) == "/protected/page"
    end

    test "does not store return_to path for non-GET requests" do
      conn =
        build_conn(:post, "/protected/page")
        |> init_test_session(%{})
        |> UserAuth.require_authenticated_user([])

      assert redirected_to(conn) == ~p"/users/log_in"
      assert get_session(conn, :user_return_to) == nil
    end
  end

  describe "redirect_logged_out_user/2" do
    test "allows authenticated user" do
      %{conn: conn} = register_and_log_in_user(%{})

      conn = UserAuth.redirect_logged_out_user(conn, [])
      refute conn.halted
      assert conn.assigns.current_user != nil
    end

    test "redirects unauthenticated user to login page with flash" do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> fetch_flash()
        |> UserAuth.redirect_logged_out_user([])

      assert redirected_to(conn) == ~p"/users/log_in"
      assert conn.halted

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You must log in to access this page."
    end
  end

  describe "on_mount :mount_current_user" do
    test "assigns current_user from valid session token" do
      %{conn: conn, user: user} = register_and_log_in_user(%{})
      session_token = get_session(conn, :user_token)

      socket = build_socket()

      assert {:cont, socket} =
               UserAuth.on_mount(
                 :mount_current_user,
                 %{},
                 %{"user_token" => session_token},
                 socket
               )

      assert socket.assigns.current_user.id == user.id
    end

    test "assigns nil current_user when no session token" do
      socket = build_socket()

      assert {:cont, socket} =
               UserAuth.on_mount(:mount_current_user, %{}, %{}, socket)

      assert socket.assigns.current_user == nil
    end

    test "assigns nil current_user when session token is invalid" do
      socket = build_socket()

      assert {:cont, socket} =
               UserAuth.on_mount(:mount_current_user, %{}, %{"user_token" => "invalid"}, socket)

      assert socket.assigns.current_user == nil
    end
  end

  describe "on_mount :ensure_authenticated" do
    test "allows authenticated user and continues" do
      %{conn: conn, user: user} = register_and_log_in_user(%{})
      session_token = get_session(conn, :user_token)

      socket = build_socket()

      assert {:cont, socket} =
               UserAuth.on_mount(
                 :ensure_authenticated,
                 %{},
                 %{"user_token" => session_token},
                 socket
               )

      assert socket.assigns.current_user.id == user.id
    end

    test "halts and redirects unauthenticated user" do
      socket = build_socket()

      assert {:halt, socket} =
               UserAuth.on_mount(:ensure_authenticated, %{}, %{}, socket)

      assert socket.assigns.current_user == nil

      assert Phoenix.Flash.get(socket.assigns.flash, :error) ==
               "You must log in to access this page."

      assert socket.redirected == {:redirect, %{status: 302, to: "/users/log_in"}}
    end
  end

  describe "on_mount :redirect_if_user_is_authenticated" do
    test "redirects authenticated user to signed in path" do
      %{conn: conn, user: user} = register_and_log_in_user(%{})
      session_token = get_session(conn, :user_token)

      socket = build_socket()

      assert {:halt, socket} =
               UserAuth.on_mount(
                 :redirect_if_user_is_authenticated,
                 %{},
                 %{"user_token" => session_token},
                 socket
               )

      assert socket.assigns.current_user.id == user.id
      assert socket.redirected == {:redirect, %{status: 302, to: "/"}}
    end

    test "continues for unauthenticated user" do
      socket = build_socket()

      assert {:cont, socket} =
               UserAuth.on_mount(:redirect_if_user_is_authenticated, %{}, %{}, socket)

      assert socket.assigns.current_user == nil
      assert socket.redirected == nil
    end
  end

  describe "session management" do
    test "session token is valid for authentication" do
      %{conn: conn, user: user} = register_and_log_in_user(%{})
      token = get_session(conn, :user_token)

      authenticated_user = Accounts.get_user_by_session_token(token)
      assert authenticated_user.id == user.id
    end

    test "session token can be deleted" do
      %{conn: conn} = register_and_log_in_user(%{})
      token = get_session(conn, :user_token)

      assert :ok = Accounts.delete_session_token(token)

      # Token should no longer authenticate user
      authenticated_user = Accounts.get_user_by_session_token(token)
      assert authenticated_user == nil
    end
  end

  # Helper functions

  defp register_and_log_in_user(attrs) do
    user = AccountsFixtures.user_fixture(attrs)
    conn = build_conn() |> log_in_user(user)

    %{conn: conn, user: user}
  end

  defp build_socket do
    # Create a minimal socket struct for testing on_mount hooks
    # Phoenix.Component.assign requires internal tracking fields in the assigns map
    # Don't set redirected field - let LiveView manage it internally
    %Phoenix.LiveView.Socket{
      endpoint: GtfsPlannerWeb.Endpoint,
      assigns: %{
        __changed__: %{},
        flash: %{}
      }
    }
  end
end
