defmodule GtfsPlannerWeb.UserConfirmationLive do
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.confirm_user(token) do
        {:ok, _user} ->
          socket
          |> put_flash(:info, "Email confirmed. Log in to continue.")
          |> redirect(to: ~p"/users/log_in")

        :error ->
          socket
          |> put_flash(:error, "Confirmation link is invalid or it has expired.")
          |> redirect(to: ~p"/users/log_in")
      end

    {:ok, socket}
  end
end
