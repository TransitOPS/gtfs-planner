defmodule GtfsPlannerWeb.UserAuth do
  @moduledoc """
  Provides authentication and authorization functionality for users.

  This module handles:
  - User login and logout
  - Session management with tokens
  - Remember-me functionality
  - LiveView authentication hooks
  - Route protection plugs
  """

  import Plug.Conn
  import Phoenix.Controller

  alias GtfsPlanner.Accounts

  @max_age 60 * 60 * 24 * 60

  @doc """
  Logs the user in.

  It renews the session ID and clears the whole session
  to avoid fixation attacks.
  """
  def log_in_user(conn, user, params \\ %{}) do
    token = Accounts.generate_user_session_token(user)
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> renew_session()
    |> put_session(:user_token, token)
    |> maybe_write_remember_me_cookie(token, params)
    |> assign(:current_user, user)
    |> Phoenix.Controller.redirect(to: user_return_to || signed_in_path(conn))
  end

  @doc """
  Logs the user out.

  It clears all session data for safety.
  """
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      GtfsPlannerWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> delete_resp_cookie("user_remember_me")
    |> Phoenix.Controller.redirect(to: "/users/log_in")
  end

  @doc """
  Authenticates user by looking into the session
  and remember me token.
  """
  def fetch_current_user(conn, _opts) do
    conn = fetch_session(conn)
    {user_token, conn} = ensure_user_token(conn)
    user = user_token && Accounts.get_user_by_session_token(user_token)

    assign(conn, :current_user, user)
  end

  @doc """
  Used for routes that require the user to not be authenticated.
  """
  def redirect_if_user_is_authenticated(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
      |> Phoenix.Controller.redirect(to: signed_in_path(conn))
      |> halt()
    else
      conn
    end
  end

  @doc """
  Used for routes that require the user to be authenticated.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> maybe_store_return_to()
      |> Phoenix.Controller.redirect(to: "/users/log_in")
      |> halt()
    end
  end

  @doc """
  Used for authenticated routes to redirect unauthenticated users.
  """
  def redirect_logged_out_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> Phoenix.Controller.put_flash(:error, "You must log in to access this page.")
      |> Phoenix.Controller.redirect(to: "/users/log_in")
      |> halt()
    end
  end

  @doc """
  Handles mounting and authenticating the current_user in LiveViews.
  """
  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, mount_current_user(socket, session)}
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: "/users/log_in")

      {:halt, socket}
    end
  end

  def on_mount(:redirect_if_user_is_authenticated, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns[:current_user] do
      {:halt, Phoenix.LiveView.redirect(socket, to: signed_in_path(socket))}
    else
      {:cont, socket}
    end
  end

  def on_mount(:default, _params, session, socket) do
    socket = mount_current_user(socket, session)
    {:cont, socket}
  end

  defp mount_current_user(socket, session) do
    user = session["user_token"] && Accounts.get_user_by_session_token(session["user_token"])
    Phoenix.Component.assign(socket, :current_user, user)
  end

  defp ensure_user_token(conn) do
    if user_token = get_session(conn, :user_token) do
      {user_token, conn}
    else
      conn = fetch_cookies(conn, [])
      cookie = conn.cookies["user_remember_me"]

      if user_token = cookie do
        {user_token, put_session(conn, :user_token, user_token)}
      else
        {nil, conn}
      end
    end
  end

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}) do
    put_resp_cookie(
      conn,
      "user_remember_me",
      token,
      max_age: @max_age,
      secure: true,
      http_only: true,
      same_site: "Lax"
    )
  end

  defp maybe_write_remember_me_cookie(conn, _token, _params) do
    conn
  end

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  defp signed_in_path(_conn), do: "/organizations"
  defp signed_in_path(_socket), do: "/organizations"
end
