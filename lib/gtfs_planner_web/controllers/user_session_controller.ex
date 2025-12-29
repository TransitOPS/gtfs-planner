defmodule GtfsPlannerWeb.UserSessionController do
  use GtfsPlannerWeb, :controller
  import Phoenix.Component

  alias GtfsPlanner.Accounts
  alias GtfsPlannerWeb.UserAuth

  plug :fetch_current_user when action in [:new]

  defp fetch_current_user(conn, opts), do: UserAuth.fetch_current_user(conn, opts)

  def new(conn, _params) do
    form = to_form(%{}, as: :user)
    render(conn, :new, error_message: nil, form: form)
  end

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
        form = to_form(%{"email" => email}, as: :user)

        render(conn, :new,
          error_message: "Your account has no organization assigned. Contact an administrator.",
          form: form
        )
      end
    else
      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      form = to_form(%{"email" => email}, as: :user)
      render(conn, :new, error_message: "Invalid email or password", form: form)
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
