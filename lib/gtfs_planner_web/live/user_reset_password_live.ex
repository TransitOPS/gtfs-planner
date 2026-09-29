defmodule GtfsPlannerWeb.UserResetPasswordLive do
  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.AuthComponents

  alias GtfsPlanner.Accounts

  # Failed submits must not return secrets to the browser: both password keys
  # (string and atom) are dropped from params and changes.
  @secret_keys ["password", "password_confirmation", :password, :password_confirmation]
  @secret_changes [:password, :password_confirmation]

  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <div id="reset-password-page" phx-hook="FormErrorFocus">
        <.auth_title id="reset-password-title">Choose a new password</.auth_title>

        <%!-- A rejected save clears both fields, because the server never sends a
              password back to the browser. The banner says so; the fields say
              what to fix, and FormErrorFocus moves focus to the first one. --%>
        <div
          :if={@submit_failed}
          id="reset-password-banner"
          role="alert"
          class="mt-5 flex items-start gap-3 rounded-card border border-error-line bg-error-bg px-4 py-3.5 text-sm text-error-fg"
        >
          <.icon name="hero-exclamation-circle" class="mt-px size-5 shrink-0" />
          <div class="min-w-0">
            <p class="font-semibold">We couldn't save your new password</p>
            <p class="text-pretty">
              Fix the highlighted fields, then type the new password again. We clear both fields after an error to keep them private.
            </p>
          </div>
        </div>

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
         |> assign(submit_failed: true)
         |> assign(
           password_errors: for({:password, error} <- changeset.errors, do: password_error(error))
         )
         |> assign(
           password_confirmation_errors:
             for(
               {:password_confirmation, error} <- changeset.errors,
               do: confirmation_error(error)
             )
         )
         |> push_event("focus_form_error", %{form_id: "reset_password_form", fallback_id: nil})}
    end
  end

  defp assign_form(socket, changeset) do
    form = to_form(changeset, as: "user")

    socket
    |> assign(form: form)
    |> assign(password_errors: used_errors(form[:password], &password_error/1))
    |> assign(
      password_confirmation_errors:
        used_errors(form[:password_confirmation], &confirmation_error/1)
    )
  end

  # Errors show only once the field has been used, as `<.input>` does by
  # default; a failed submit drops the params, so it reads the changeset directly.
  defp used_errors(field, to_message) do
    if Phoenix.Component.used_input?(field), do: Enum.map(field.errors, to_message), else: []
  end

  # Plain-language versions of the password changeset's messages, chosen by the
  # rule that failed rather than by its text. The length limits come from the
  # changeset, so the copy cannot drift from the rule.
  defp password_error({_message, opts} = error) do
    case {opts[:validation], opts[:kind]} do
      {:required, _kind} -> "Enter a new password."
      {:length, :min} -> "Use at least #{opts[:count]} characters."
      {:length, :max} -> "Use #{opts[:count]} characters or fewer."
      _other -> translate_error(error)
    end
  end

  # A blank confirmation reaches here as a mismatch: the form always submits
  # both keys, and Ecto only reports `:required` when the key is absent.
  defp confirmation_error({_message, opts} = error) do
    case opts[:validation] do
      :confirmation -> "The two passwords don't match. Type the same one in both fields."
      _other -> translate_error(error)
    end
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
