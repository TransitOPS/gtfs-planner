defmodule GtfsPlannerWeb.UserResetPasswordLive do
  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.AuthComponents

  alias GtfsPlanner.Accounts
  alias GtfsPlannerWeb.AuthForm

  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <div id="reset-password-page" phx-hook="FormErrorFocus">
        <.auth_title id="reset-password-title">Choose a new password</.auth_title>

        <%!-- A rejected save clears both fields, because the server never sends a
              password back to the browser. The banner says so; the fields say
              what to fix, and FormErrorFocus moves focus to the first one. --%>
        <.auth_error
          :if={@submit_failed}
          id="reset-password-banner"
          role="alert"
          title="We couldn't save your new password"
        >
          <p class="text-pretty">
            Fix the highlighted fields, then type the new password again. We clear both fields after an error to keep them private.
          </p>
        </.auth_error>

        <.form
          for={@form}
          id="reset_password_form"
          phx-change="validate"
          phx-submit="reset_password"
          novalidate
          class="auth-form mt-6 phx-submit-loading:opacity-60"
        >
          <div class="grid gap-5">
            <.input
              field={@form[:password]}
              id="reset-password-new-password"
              type="password"
              label="New password"
              help="At least 12 characters. A short phrase of a few words works well."
              errors={@password_errors}
              autocomplete="new-password"
              phx-debounce="blur"
              phx-blur="validate"
              required
            />

            <.input
              field={@form[:password_confirmation]}
              id="reset-password-confirmation"
              type="password"
              label="Confirm new password"
              errors={@password_confirmation_errors}
              autocomplete="new-password"
              phx-debounce="blur"
              phx-blur="validate"
              required
            />
          </div>

          <%!-- reset_user_password/2 deletes every token for the account, so every
                logged-in device loses its session and nobody is logged in here. --%>
          <p class="mt-5 flex items-start gap-2 text-[13px] leading-relaxed text-muted">
            <.icon name="hero-information-circle" class="mt-px size-4 shrink-0" />
            <span>
              Saving signs this account out on every device. You'll log in again with the new password.
            </span>
          </p>

          <.auth_submit id="reset-password-submit" phx-disable-with="Saving password…">
            Save new password
          </.auth_submit>
        </.form>

        <p class="-mb-2.5 mt-3">
          <.auth_link navigate={~p"/users/log_in"}>Back to log in</.auth_link>
        </p>
      </div>
    </Layouts.auth>
    """
  end

  def mount(%{"token" => token}, _session, socket) do
    case Accounts.get_user_by_reset_password_token(token) do
      %GtfsPlanner.Accounts.User{} = user ->
        {:ok,
         socket
         |> assign(page_title: "Choose a new password")
         |> assign(user: user, submit_failed: false)
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
      |> Accounts.change_user_password(AuthForm.defer_blank_errors(user_params))
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
        # Read the errors before the passwords are dropped: a failed submit has
        # no used-field state, so they come from the changeset directly, and the
        # confirmation copy depends on the params as submitted.
        params = changeset.params
        changeset = AuthForm.sanitize_secrets(changeset)

        {:noreply,
         socket
         |> assign(form: to_form(changeset, as: "user"))
         |> assign(submit_failed: true)
         |> assign(
           password_errors: for({:password, error} <- changeset.errors, do: password_error(error))
         )
         |> assign(
           password_confirmation_errors:
             for(
               {:password_confirmation, error} <- changeset.errors,
               do: AuthForm.confirmation_error(error, params)
             )
         )
         |> push_event("focus_form_error", %{form_id: "reset_password_form", fallback_id: nil})}
    end
  end

  defp assign_form(socket, changeset) do
    form = to_form(changeset, as: "user")

    socket
    |> assign(form: form)
    |> assign(password_errors: AuthForm.used_errors(form[:password], &password_error/1))
    |> assign(
      password_confirmation_errors:
        AuthForm.used_errors(
          form[:password_confirmation],
          &AuthForm.confirmation_error(&1, form.params)
        )
    )
  end

  defp password_error(error), do: AuthForm.password_error(error, "Enter a new password.")
end
