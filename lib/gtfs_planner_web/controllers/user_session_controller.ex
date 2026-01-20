defmodule GtfsPlannerWeb.UserSessionController do
  use GtfsPlannerWeb, :controller

  alias GtfsPlanner.Accounts
  alias GtfsPlannerWeb.UserAuth

  def create(conn, %{"user" => user_params}) do
    %{"email" => email, "password" => password} = user_params

    if user = Accounts.get_user_by_email_and_password(email, password) do
      # Check if user has organization membership or is administrator
      if UserAuth.is_administrator?(user) || UserAuth.fetch_user_organization(user) do
        conn
        |> put_flash(:info, "Welcome back!")
        |> UserAuth.log_in_user(user, user_params)
      else
        # User has no organization membership and is not an administrator
        conn
        |> put_flash(
          :error,
          "Your account has no organization assigned. Contact an administrator."
        )
        |> redirect(to: ~p"/users/log_in")
      end
    else
      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      conn
      |> put_flash(:error, "Invalid email or password")
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/users/log_in")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
