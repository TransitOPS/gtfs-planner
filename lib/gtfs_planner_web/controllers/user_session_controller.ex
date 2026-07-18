defmodule GtfsPlannerWeb.UserSessionController do
  @moduledoc """
  Handles browser-session credential transitions.

  Owns normal login, logout, and the authenticated password-update POST.
  Both login entrypoints share one membership/deactivation policy so a
  post-password-change renewal behaves exactly like a normal login.
  """

  use GtfsPlannerWeb, :controller

  alias GtfsPlanner.Accounts
  alias GtfsPlannerWeb.UserAuth

  def create(conn, %{"user" => user_params}) do
    %{"email" => email, "password" => password} = user_params

    if user = Accounts.get_user_by_email_and_password(email, password) do
      complete_login(conn, user, user_params, nil)
    else
      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      conn
      |> put_flash(:error, "Invalid email or password")
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/users/log_in")
    end
  end

  def update_password(conn, %{
        "current_password" => current_password,
        "user" => %{
          "password" => password,
          "password_confirmation" => password_confirmation
        }
      }) do
    user = conn.assigns.current_user
    attrs = %{"password" => password, "password_confirmation" => password_confirmation}

    case Accounts.update_user_password(user, current_password, attrs) do
      {:ok, {updated_user, expired_tokens}} ->
        :ok = UserAuth.disconnect_sessions(expired_tokens)

        conn
        |> UserAuth.clear_remember_me_cookie()
        |> put_session(:user_return_to, ~p"/users/settings")
        |> complete_login(updated_user, %{}, "Password updated successfully.")

      {:error, _changeset} ->
        reject_password_update(conn)
    end
  end

  def update_password(conn, _params) do
    reject_password_update(conn)
  end

  def delete(conn, _params) do
    conn
    |> UserAuth.log_out_user()
  end

  # Rejects a malformed or failed direct POST without mutating the current
  # session, cookies, or stored credentials.
  defp reject_password_update(conn) do
    conn
    |> put_flash(:error, "Password change failed. Please try again.")
    |> redirect(to: ~p"/users/settings")
  end

  # Shared login-policy completion for normal login and post-password-change
  # renewal. The membership precheck and UserAuth's deactivation check must
  # both hold before any session token is issued; policy rejection redirects
  # to login without a token and without the success flash.
  defp complete_login(conn, user, params, success_flash) do
    if UserAuth.is_administrator?(user) || UserAuth.fetch_user_organization(user) do
      attempt_conn = if success_flash, do: put_flash(conn, :info, success_flash), else: conn

      case UserAuth.log_in_user(attempt_conn, user, params) do
        {:error, :deactivated} ->
          conn
          |> put_flash(
            :error,
            "Your account has been deactivated. Contact your administrator."
          )
          |> redirect(to: ~p"/users/log_in")

        %Plug.Conn{} = conn ->
          conn
      end
    else
      # User has no organization membership and is not an administrator
      conn
      |> put_flash(
        :error,
        "Your account has no organization assigned. Contact an administrator."
      )
      |> redirect(to: ~p"/users/log_in")
    end
  end
end
