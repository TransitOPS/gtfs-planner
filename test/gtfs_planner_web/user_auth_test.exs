defmodule GtfsPlannerWeb.UserAuthTest do
  use GtfsPlannerWeb.ConnCase

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.AccountsFixtures
  alias GtfsPlannerWeb.UserAuth

  describe "log_in_user/3" do
    test "logs the user in and redirects to organizations page" do
      user = AccountsFixtures.user_fixture()

      conn =
        build_conn()
        |> UserAuth.log_in_user(user)

      assert conn.assigns.current_user.id == user.id
      assert redirected_to(conn) == ~p"/organizations"
    end

    test "stores the user token in the session" do
      %{conn: conn, user: user} =
        register_and_log_in_user(%{password: "valid password"})

      assert conn.assigns.current_user.id == user.id
      assert get_session(conn, :user_token) != nil
    end

    test "renews the session to prevent fixation attacks" do
      %{conn: conn, user: user} =
        register_and_log_in_user(%{password: "valid password"})

      # Session should be renewed (old session ID should be invalid)
      assert conn.assigns.current_user.id == user.id
    end

    test "redirects to user_return_to if set" do
      user = AccountsFixtures.user_fixture()

      conn =
        build_conn()
        |> put_session(:user_return_to, "/some/previous/page")
        |> UserAuth.log_in_user(user)

      assert redirected_to(conn) == "/some/previous/page"
    end

    test "with remember_me param, sets remember_me cookie" do
      user = AccountsFixtures.user_fixture()

      conn =
        build_conn()
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
        |> UserAuth.log_in_user(user, %{})

      assert conn.resp_cookies["user_remember_me"] == nil
    end
  end

  describe "log_out_user/1" do
    setup do
      %{conn: conn, user: user} = register_and_log_in_user(%{})
      {:ok, conn: conn, user: user}
    end

    test "logs the user out and redirects to login page", %{conn: conn} do
      conn = UserAuth.log_out_user(conn)
      assert redirected_to(conn) == ~p"/users/log_in"
    end

    test "clears all session data", %{conn: conn} do
      conn = UserAuth.log_out_user(conn)
      assert get_session(conn, :user_token) == nil
      assert get_session(conn, :live_socket_id) == nil
    end

    test "deletes the remember_me cookie", %{conn: conn} do
      conn = UserAuth.log_out_user(conn)
      assert conn.resp_cookies["user_remember_me"] != nil
      cookie = conn.resp_cookies["user_remember_me"]
      assert cookie.max_age == 0
    end

    test "broadcasts disconnect to LiveView if live_socket_id is set", %{conn: conn, user: user} do
      live_socket_id = "users_sessions:#{Base.url_encode64(user.id)}"

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
      %{conn: conn, user: user} = register_and_log_in_user(%{})

      conn =
        conn
        |> recycle()
        |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_user.id == user.id
    end

    test "does not authenticate if no session token" do
      conn =
        build_conn()
        |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_user == nil
    end

    test "does not authenticate with invalid session token" do
      conn =
        build_conn()
        |> put_session(:user_token, "invalid_token")
        |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_user == nil
    end

    test "authenticates user from remember_me cookie" do
      user = AccountsFixtures.user_fixture()
      token = Accounts.generate_user_session_token(user)

      conn =
        build_conn()
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
        |> put_session(:user_token, session_token)
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
      assert redirected_to(conn) == ~p"/organizations"
      assert conn.halted
    end

    test "does not redirect unauthenticated user" do
      conn = build_conn() |> UserAuth.redirect_if_user_is_authenticated([])
      refute redirected_to(conn)
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
      conn = build_conn() |> UserAuth.require_authenticated_user([])
      assert redirected_to(conn) == ~p"/users/log_in"
      assert conn.halted
    end

    test "stores return_to path for GET requests" do
      conn =
        build_conn(:get, "/protected/page")
        |> UserAuth.require_authenticated_user([])

      assert redirected_to(conn) == ~p"/users/log_in"
      assert get_session(conn, :user_return_to) == "/protected/page"
    end

    test "does not store return_to path for non-GET requests" do
      conn =
        build_conn(:post, "/protected/page")
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
      conn = build_conn() |> UserAuth.redirect_logged_out_user([])
      assert redirected_to(conn) == ~p"/users/log_in"
      assert conn.halted
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "You must log in to access this page."
    end
  end

  describe "on_mount :mount_current_user" do
    test "assigns current_user from valid session token" do
      %{conn: conn, user: user} = register_and_log_in_user(%{})
      session_token = get_session(conn, :user_token)

      socket =
        %Phoenix.LiveView.Socket{endpoint: GtfsPlannerWeb.Endpoint}
        |> Phoenix.LiveView.assign_new(:current_user, fn -> nil end)

      assert {:cont, socket} =
               UserAuth.on_mount(:mount_current_user, %{}, %{"user_token" => session_token}, socket)

      assert socket.assigns.current_user.id == user.id
    end

    test "assigns nil current_user when no session token" do
      socket =
        %Phoenix.LiveView.Socket{endpoint: GtfsPlannerWeb.Endpoint}
        |> Phoenix.LiveView.assign_new(:current_user, fn -> nil end)

      assert {:cont, socket} =
               UserAuth.on_mount(:mount_current_user, %{}, %{}, socket)

      assert socket.assigns.current_user == nil
    end

    test "assigns nil current_user when session token is invalid" do
      socket =
        %Phoenix.LiveView.Socket{endpoint: GtfsPlannerWeb.Endpoint}
        |> Phoenix.LiveView.assign_new(:current_user, fn -> nil end)

      assert {:cont, socket} =
               UserAuth.on_mount(:mount_current_user, %{}, %{"user_token" => "invalid"}, socket)

      assert socket.assigns.current_user == nil
    end
  end

  describe "on_mount :ensure_authenticated" do
    test "allows authenticated user and continues" do
      %{conn: conn, user: user} = register_and_log_in_user(%{})
      session_token = get_session(conn, :user_token)

      socket =
        %Phoenix.LiveView.Socket{endpoint: GtfsPlannerWeb.Endpoint}
        |> Phoenix.LiveView.assign_new(:current_user, fn -> nil end)

      assert {:cont, socket} =
               UserAuth.on_mount(:ensure_authenticated, %{}, %{"user_token" => session_token}, socket)

      assert socket.assigns.current_user.id == user.id
    end

    test "halts and redirects unauthenticated user" do
      socket =
        %Phoenix.LiveView.Socket{endpoint: GtfsPlannerWeb.Endpoint}
        |> Phoenix.LiveView.assign_new(:current_user, fn -> nil end)

      assert {:halt, socket} =
               UserAuth.on_mount(:ensure_authenticated, %{}, %{}, socket)

      assert socket.assigns.current_user == nil
      assert Phoenix.Flash.get(socket.assigns.flash, :error) == "You must log in to access this page."
      assert socket.redirected == true
    end
  end

  describe "on_mount :redirect_if_user_is_authenticated" do
    test "redirects authenticated user to signed in path" do
      %{conn: conn, user: user} = register_and_log_in_user(%{})
      session_token = get_session(conn, :user_token)

      socket =
        %Phoenix.LiveView.Socket{endpoint: GtfsPlannerWeb.Endpoint}
        |> Phoenix.LiveView.assign_new(:current_user, fn -> nil end)

      assert {:halt, socket} =
               UserAuth.on_mount(:redirect_if_user_is_authenticated, %{}, %{"user_token" => session_token}, socket)

      assert socket.assigns.current_user.id == user.id
      assert socket.redirected == true
    end

    test "continues for unauthenticated user" do
      socket =
        %Phoenix.LiveView.Socket{endpoint: GtfsPlannerWeb.Endpoint}
        |> Phoenix.LiveView.assign_new(:current_user, fn -> nil end)

      assert {:cont, socket} =
               UserAuth.on_mount(:redirect_if_user_is_authenticated, %{}, %{}, socket)

      assert socket.assigns.current_user == nil
      refute socket.redirected
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

      assert {:ok, _user} = Accounts.delete_session_token(token)

      # Token should no longer authenticate the user
      authenticated_user = Accounts.get_user_by_session_token(token)
      assert authenticated_user == nil
    end
  end

  # Helper functions

  defp register_and_log_in_user(attrs) do
    user = AccountsFixtures.user_fixture(attrs)
    token = Accounts.generate_user_session_token(user)

    conn =
      build_conn()
      |> put_session(:user_token, token)
      |> UserAuth.fetch_current_user([])

    %{conn: conn, user: user}
  end
end
