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
  import Phoenix.LiveView

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.User
  alias GtfsPlannerWeb.Router.Helpers, as: Routes

  @max_age 60 * 60 * 24 * 60

  @doc """
  Logs the user in.

  It renews the session ID and clears the whole session
  to avoid fixation attacks. See the `RenewSession`
  plug for more details.
  """
  def log_in_user(conn, user, params \\ %{}) do
    token = Accounts.generate_user_session_token(user)
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> renew_session()
    |> put_session(:user_token, token)
    |> maybe_write_remember_me_cookie(token, params)
    |> assign(:current_user, user)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  @doc """
  Logs the user out.

  It clears all session data for safety. See the `RenewSession`
  plug for more details.
  """
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_session_token(user)

    if live_socket_id = get_session(conn, :live_socket_id) do
      GtfsPlannerWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> delete_resp_cookie("user_remember_me")
    |> redirect(to: ~p"/users/log_in")
  end

  @doc """
  Authenticates the user by looking into the session
  and remember me token.
  """
  def fetch_current_user(conn, _opts) do
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
      |> redirect(to: signed_in_path(conn))
      |> halt()
    else
      conn
    end
  end

  @doc """
  Used for routes that require the user to be authenticated.

  If you want to enforce the user email is confirmed before
  they use the application at all, here would be a good place.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> maybe_store_return_to()
      |> redirect(to: ~p"/users/log_in")
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
      |> put_flash(:error, "You must log in to access this page.")
      |> redirect(to: ~p"/users/log_in")
      |> halt()
    end
  end

  @doc """
  Handles mounting and authenticating the current_user in LiveViews.

  ## `on_mount` arguments

    * `:mount_current_user` - Assigns current_user to socket assigns based on user_token,
      or nil if no user_token or no session.

    * `:ensure_authenticated` - Authenticates the user from the session, and assigns
      current_user to socket assigns. Redirects to login page if there's no valid
      user_token or if the user_token is invalid.

    * `:redirect_if_user_is_authenticated` - Authenticates the user from the session.
      Redirects to the signed_in_path if the user is authenticated.

  ## Examples

    use GtfsPlannerWeb, :live_view

    on_mount {GtfsPlannerWeb.UserAuth, :mount_current_user}
    on_mount {GtfsPlannerWeb.UserAuth, :ensure_authenticated}
    on_mount {GtfsPlannerWeb.UserAuth, :redirect_if_user_is_authenticated}

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
        |> put_flash(:error, "You must log in to access this page.")
        |> redirect(to: ~p"/users/log_in")

      {:halt, socket}
    end
  end

  def on_mount(:redirect_if_user_is_authenticated, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns[:current_user] do
      {:halt, redirect(socket, to: signed_in_path(socket))}
    else
      {:cont, socket}
    end
  end

  def on_mount(:default, _params, session, socket) do
    socket = mount_current_user(socket, session)
    {:cont, socket}
  end

  # Private functions

  defp mount_current_user(socket, session) do
    if user_token = session["user_token"] do
      user = Accounts.get_user_by_session_token(user_token)
      assign_new(socket, :current_user, fn -> user end)
    else
      assign_new(socket, :current_user, fn -> nil end)
    end
  end

  defp ensure_user_token(conn) do
    if user_token = get_session(conn, :user_token) do
      {user_token, conn}
    else
      conn = fetch_cookies(conn, signed: ~w(user_remember_me))

      if user_token = conn.cookies["user_remember_me"] do
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
    Phoenix.LiveView.configure_session(conn, &(&1))
    delete_csrf_token()
    conn
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  defp signed_in_path(_conn), do: ~p"/organizations"
  defp signed_in_path(socket), do: ~p"/organizations"
end
