defmodule GtfsPlannerWeb.UserForgotPasswordLive do
  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.AuthComponents

  require Logger

  alias GtfsPlanner.Accounts

  # Absent account, successful delivery, a throttled repeat request, and delivery
  # failure all produce this identical login outcome so the response never
  # discloses whether the address belongs to an account.
  @reset_request_message "If an account can receive password resets, instructions are on the way. Check your inbox and spam folder, or try again."

  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <div id="reset-password-request-page" phx-hook="FormErrorFocus">
        <.auth_title id="reset-password-request-title">
          Reset your password
          <:lede>Enter the email you log in with. We'll send a link to choose a new one.</:lede>
        </.auth_title>

        <.form
          for={@form}
          id="reset_password_form"
          phx-change="validate"
          phx-submit="send_instructions"
          novalidate
          class="auth-form mt-6 phx-submit-loading:opacity-60"
        >
          <.input
            field={@form[:email]}
            id="reset-password-email"
            type="email"
            label="Email"
            errors={email_errors(@form[:email])}
            autocomplete="username"
            autocapitalize="none"
            spellcheck="false"
            phx-debounce="blur"
            phx-blur="validate"
            required
          />

          <.auth_submit
            id="reset-password-request-submit"
            phx-disable-with="Sending reset link…"
            class="mt-5"
          >
            Send reset link
          </.auth_submit>
        </.form>

        <p class="-mb-2.5 mt-3">
          <.auth_link navigate={~p"/users/log_in"}>Back to log in</.auth_link>
        </p>
      </div>

      <:footer>No account? Ask your organization administrator for an invitation.</:footer>
    </Layouts.auth>
    """
  end

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Reset password")
     |> assign(form: to_form(Accounts.change_password_reset_request(), as: :user))}
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset =
      user_params
      |> Accounts.change_password_reset_request()
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: :user))}
  end

  # `phx-blur` payloads carry only event metadata (`%{"key" => _, "value" => _}`), never
  # form values. The `phx-debounce="blur"` form change that accompanies every field blur
  # delivers the values and is handled by the clause above, so metadata-only payloads
  # intentionally change nothing.
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("send_instructions", %{"user" => user_params}, socket) do
    case user_params
         |> Accounts.change_password_reset_request()
         |> Ecto.Changeset.apply_action(:insert) do
      {:ok, request} ->
        maybe_deliver_reset_instructions(request.email)

        {:noreply,
         socket
         |> put_flash(:info, @reset_request_message)
         |> redirect(to: ~p"/users/log_in")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset, as: :user))
         |> push_event("focus_form_error", %{form_id: "reset_password_form", fallback_id: nil})}
    end
  end

  # Plain-language versions of the request form's changeset messages, chosen by
  # the rule that failed rather than by its text. Errors show only once the
  # field has been used, as `<.input>` does by default.
  defp email_errors(field) do
    if Phoenix.Component.used_input?(field), do: Enum.map(field.errors, &email_error/1), else: []
  end

  defp email_error({_message, opts} = error) do
    case {opts[:validation], opts[:kind]} do
      {:required, _kind} -> "Enter the email you log in with."
      {:format, _kind} -> "Include an @ and no spaces, like name@agency.example."
      {:length, :max} -> "Use an address of #{opts[:count]} characters or fewer."
      _other -> translate_error(error)
    end
  end

  # Delivers reset instructions only when the address belongs to an account.
  # An absent account, a throttled repeat request, and a delivery failure are all
  # silent to the caller so the browser outcome stays identical
  # (anti-enumeration); a delivery failure logs a safe outcome class only — never
  # the address, token, mail content, or the inspected adapter reason.
  defp maybe_deliver_reset_instructions(email) do
    with %GtfsPlanner.Accounts.User{} = user <- Accounts.get_user_by_email(email),
         {:ok, _delivered} <-
           Accounts.deliver_user_reset_password_instructions(
             user,
             &url(~p"/users/reset_password/#{&1}")
           ) do
      :ok
    else
      nil -> :ok
      {:error, :throttled} -> :ok
      {:error, _reason} -> Logger.warning("Password reset instructions could not be delivered")
    end
  end
end
