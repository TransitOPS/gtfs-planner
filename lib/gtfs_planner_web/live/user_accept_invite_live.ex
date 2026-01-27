defmodule GtfsPlannerWeb.UserAcceptInviteLive do
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.User

  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <.header class="text-center">
        Welcome to GTFS Planner
        <:subtitle>Create a password to complete your account setup</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="accept_invite_form"
        phx-submit="accept_invite"
        phx-change="validate"
      >
        <.input
          field={@form[:password]}
          type="password"
          label="Password"
          required
        />

        <.input
          field={@form[:password_confirmation]}
          type="password"
          label="Confirm password"
          required
        />

        <:actions>
          <.button phx-disable-with="Setting password..." class="w-full" variant="primary">
            Accept invite & set password
          </.button>
        </:actions>
      </.simple_form>

      <p class="text-center mt-4 text-sm leading-6 text-base-content/70">
        <.link navigate={~p"/users/log_in"} class="font-semibold link link-primary">
          Log in
        </.link>
      </p>
    </Layouts.auth>
    """
  end

  def mount(%{"token" => token}, _session, socket) do
    case Accounts.get_user_by_invite_token(token) do
      %User{} = user ->
        socket =
          socket
          |> assign(user: user, token: token)
          |> assign_new(:form, fn -> to_form(%{}, as: "user") end)

        {:ok, socket, temporary_assigns: [form: socket.assigns.form]}

      nil ->
        socket =
          socket
          |> put_flash(:error, "Invite link is invalid or it has expired.")
          |> redirect(to: ~p"/")

        {:ok, socket}
    end
  end

  def handle_event("accept_invite", %{"user" => user_params}, socket) do
    %{"password" => password, "password_confirmation" => password_confirmation} = user_params

    case Accounts.accept_invite_set_password(socket.assigns.user, %{
           "password" => password,
           "password_confirmation" => password_confirmation
         }) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> redirect(to: ~p"/users/log_in")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "user"))}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_password(socket.assigns.user, user_params)
    {:noreply, assign(socket, form: to_form(changeset, as: "user"))}
  end
end
