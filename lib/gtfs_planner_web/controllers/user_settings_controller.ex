defmodule GtfsPlannerWeb.UserSettingsController do
  @moduledoc """
  Completes account-settings email changes over HTTP.

  Consumes the one-time change-email token behind the authenticated browser
  pipeline. The affected user is always derived from
  `conn.assigns.current_user`; the token grants no authority for any other
  account.
  """

  use GtfsPlannerWeb, :controller

  alias GtfsPlanner.Accounts

  def confirm_email(conn, %{"token" => token}) do
    case Accounts.update_user_email(conn.assigns.current_user, token) do
      :ok ->
        conn
        |> put_flash(:info, "Email changed successfully.")
        |> redirect(to: ~p"/users/settings")

      :error ->
        conn
        |> put_flash(:error, "Email change link is invalid or it has expired.")
        |> redirect(to: ~p"/users/settings")
    end
  end
end
