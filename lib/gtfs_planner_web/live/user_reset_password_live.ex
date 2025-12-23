defmodule GtfsPlannerWeb.UserResetPasswordLive do
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-sm">
      <.header class="text-center">
        Reset password
        <:subtitle>Enter your new password below</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="reset_password_form"
        phx-submit="reset_password"
        phx-change="validate"
      >
        <.input
          field={@form[:password]}
          type="password"
          label="New password"
          required
        />

        <.input
          field={@form[:password_confirmation]}
          type="password"
          label="Confirm new password"
          required
        />

        <:actions>
          <.button phx-disable-with="Resetting..." class="w-full">
            Reset password
          </.button>
        </:actions>
      </.simple_form>

      <p class="text-center mt-4 text-sm leading-6 text-zinc-600">
        <.link navigate={~p"/users/log_in"} class="font-semibold text-brand hover:underline">
          Log in
        </.link>
      </p>
    </div>
    """
  end

  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.get_user_by_reset_password_token(token) do
        {:ok, user} ->
          assign(socket, user: user, token: token, form: to_form(%{}, as: "user"))

        :error ->
          socket
          |> put_flash(:error, "Reset password link is invalid or it has expired.")
          |> redirect(to: ~p"/")
      end

    {:ok, socket, temporary_assigns: [form: socket.assigns.form]}
  end

  def handle_event("reset_password", %{"user" => user_params}, socket) do
    %{"password" => password, "password_confirmation" => password_confirmation} = user_params

    case Accounts.reset_user_password(socket.assigns.token, %{
           "password" => password,
           "password_confirmation" => password_confirmation
         }) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Password reset successfully.")
         |> redirect(to: ~p"/users/log_in")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_password(socket.assigns.user, user_params)
    {:noreply, assign(socket, form: to_form(changeset))}
  end
end
