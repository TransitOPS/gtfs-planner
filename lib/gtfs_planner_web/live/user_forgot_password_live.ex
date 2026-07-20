defmodule GtfsPlannerWeb.UserForgotPasswordLive do
  use GtfsPlannerWeb, :live_view

  require Logger

  alias GtfsPlanner.Accounts

  # Absent account, successful delivery, and delivery failure all produce this
  # identical login outcome so the response never discloses whether the address
  # belongs to an account.
  @reset_request_message "If an account can receive password resets, instructions are on the way. Check your inbox and spam folder, or try again."

  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <div id="reset-password-request-page" phx-hook="FormErrorFocus">
        <.header class="text-center">
          Reset password
          <:subtitle>We'll send a password reset link to your inbox</:subtitle>
        </.header>

        <.simple_form
          for={@form}
          id="reset_password_form"
          phx-change="validate"
          phx-submit="send_instructions"
          class="phx-submit-loading:opacity-60"
        >
          <.input
            field={@form[:email]}
            id="reset-password-email"
            type="email"
            label="Email"
            placeholder="your@email.com"
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
              id="reset-password-request-submit"
              type="submit"
              phx-disable-with="Sending reset link…"
              variant="primary"
            >
              Send reset link
            </.button>
          </:actions>
        </.simple_form>
      </div>
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
        if user = Accounts.get_user_by_email(request.email) do
          user
          |> Accounts.deliver_user_reset_password_instructions(
            &url(~p"/users/reset_password/#{&1}")
          )
          |> case do
            {:ok, _email} ->
              :ok

            {:error, _reason} ->
              # Safe outcome class only — never the address, token, mail content,
              # or the inspected adapter reason.
              Logger.warning("Password reset instructions could not be delivered")
          end
        end

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
end
