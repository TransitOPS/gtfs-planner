defmodule GtfsPlannerWeb.UserAcceptInviteLive do
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.User

  @secret_keys ["password", "password_confirmation", :password, :password_confirmation]
  @secret_changes [:password, :password_confirmation]

  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <div id="accept-invite-page" phx-hook="FormErrorFocus">
        <.header class="text-center">
          Set password
          <:subtitle>Create a password to complete your account setup</:subtitle>
        </.header>

        <.simple_form
          for={@form}
          id="accept_invite_form"
          phx-change="validate"
          phx-submit="accept_invite"
          class="phx-submit-loading:opacity-60"
        >
          <.input
            field={@form[:password]}
            id="invite-password"
            type="password"
            label="Password"
            help="Use 12–72 characters."
            errors={@password_errors}
            phx-debounce="blur"
            phx-blur="validate"
            required
          />

          <.input
            field={@form[:password_confirmation]}
            id="invite-password-confirmation"
            type="password"
            label="Confirm password"
            help="Must match the password above."
            errors={@password_confirmation_errors}
            phx-debounce="blur"
            phx-blur="validate"
            required
          />

          <:actions>
            <.link
              navigate={~p"/users/log_in"}
              class="text-sm font-semibold link link-hover text-base-content/70"
            >
              Log in
            </.link>
          </:actions>

          <:actions>
            <.button
              id="accept-invite-submit"
              type="submit"
              phx-disable-with="Setting password…"
              variant="primary"
            >
              Set password
            </.button>
          </:actions>
        </.simple_form>
      </div>
    </Layouts.auth>
    """
  end

  def mount(%{"token" => token}, _session, socket) do
    case Accounts.get_user_by_invite_token(token) do
      %User{} = user ->
        {:ok,
         socket
         |> assign(page_title: "Set password")
         |> assign(user: user, token: token)
         |> assign_form(Accounts.change_user_password(user))}

      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Invite link is invalid or it has expired.")
         |> redirect(to: ~p"/users/log_in")}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset =
      socket.assigns.user
      |> Accounts.change_user_password(user_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("accept_invite", %{"user" => user_params}, socket) do
    case Accounts.accept_invite_set_password(socket.assigns.user, user_params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Invitation accepted. Log in to continue.")
         |> redirect(to: ~p"/users/log_in")}

      {:error, changeset} ->
        changeset = sanitize_secrets(changeset)

        {:noreply,
         socket
         |> assign(form: to_form(changeset, as: "user"))
         |> assign(password_errors: translate_errors(changeset.errors, :password))
         |> assign(
           password_confirmation_errors:
             translate_errors(changeset.errors, :password_confirmation)
         )
         |> push_event("focus_form_error", %{form_id: "accept_invite_form", fallback_id: nil})}
    end
  end

  defp assign_form(socket, changeset) do
    socket
    |> assign(form: to_form(changeset, as: "user"))
    |> assign(password_errors: [])
    |> assign(password_confirmation_errors: [])
  end

  defp sanitize_secrets(%Ecto.Changeset{} = changeset) do
    %{
      changeset
      | params: changeset.params && Map.drop(changeset.params, @secret_keys),
        changes: Map.drop(changeset.changes, @secret_changes)
    }
  end
end
