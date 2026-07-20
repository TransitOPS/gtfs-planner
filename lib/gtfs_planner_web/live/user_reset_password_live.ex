defmodule GtfsPlannerWeb.UserResetPasswordLive do
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts

  # Failed submits must not return secrets to the browser: both password keys
  # (string and atom) are dropped from params and changes.
  @secret_keys ["password", "password_confirmation", :password, :password_confirmation]
  @secret_changes [:password, :password_confirmation]

  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <div id="reset-password-page" phx-hook="FormErrorFocus">
        <.header class="text-center">
          Set new password
          <:subtitle>Enter your new password below</:subtitle>
        </.header>

        <.simple_form
          for={@form}
          id="reset_password_form"
          phx-change="validate"
          phx-submit="reset_password"
          class="phx-submit-loading:opacity-60"
        >
          <.input
            field={@form[:password]}
            id="reset-password-new-password"
            type="password"
            label="New password"
            help="Use 12–72 characters."
            errors={@password_errors}
            phx-debounce="blur"
            phx-blur="validate"
            required
          />

          <.input
            field={@form[:password_confirmation]}
            id="reset-password-confirmation"
            type="password"
            label="Confirm new password"
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
              Back to log in
            </.link>
          </:actions>

          <:actions>
            <.button
              id="reset-password-submit"
              type="submit"
              phx-disable-with="Resetting password…"
              variant="primary"
            >
              Reset password
            </.button>
          </:actions>
        </.simple_form>
      </div>
    </Layouts.auth>
    """
  end

  def mount(%{"token" => token}, _session, socket) do
    case Accounts.get_user_by_reset_password_token(token) do
      %GtfsPlanner.Accounts.User{} = user ->
        {:ok,
         socket
         |> assign(page_title: "Set new password")
         |> assign(user: user)
         |> assign_form(Accounts.change_user_password(user))}

      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Reset password link is invalid or it has expired.")
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

  # `phx-blur` payloads carry only event metadata (`%{"key" => _, "value" => _}`), never
  # form values. The `phx-debounce="blur"` form change that accompanies every field blur
  # delivers the values and is handled by the clause above, so metadata-only payloads
  # intentionally change nothing.
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("reset_password", %{"user" => user_params}, socket) do
    case Accounts.reset_user_password(socket.assigns.user, user_params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Password reset. Log in with your new password.")
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
         |> push_event("focus_form_error", %{form_id: "reset_password_form", fallback_id: nil})}
    end
  end

  defp assign_form(socket, changeset) do
    socket
    |> assign(form: to_form(changeset, as: "user"))
    |> assign(password_errors: [])
    |> assign(password_confirmation_errors: [])
  end

  # Drops the secret keys from a failed-submit changeset while retaining the
  # errors, the action, and every non-secret value, so the rendered form keeps
  # the actionable correction context without returning either password.
  defp sanitize_secrets(%Ecto.Changeset{} = changeset) do
    %{
      changeset
      | params: changeset.params && Map.drop(changeset.params, @secret_keys),
        changes: Map.drop(changeset.changes, @secret_changes)
    }
  end
end
