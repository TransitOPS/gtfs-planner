defmodule GtfsPlannerWeb.UserForgotPasswordLive do
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts

  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <.header class="text-center">
        Forgot your password?
        <:subtitle>We'll send a password reset link to your inbox</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="reset_password_form"
        phx-submit="send_instructions"
        phx-change="validate"
      >
        <.input
          field={@form[:email]}
          type="email"
          label="Email"
          placeholder="your@email.com"
          required
        />

        <:actions>
          <.button phx-disable-with="Sending..." variant="primary">
            Send password reset instructions
          </.button>
        </:actions>
      </.simple_form>

      <p class="text-center mt-4 text-sm leading-6 text-base-content/70">
        <.link navigate={~p"/users/log_in"} class="font-semibold link link-primary">
          Log in
        </.link>
        to your account
      </p>
    </Layouts.auth>
    """
  end

  def mount(_params, _session, socket) do
    socket = assign(socket, form: to_form(%{}, as: "user"))
    {:ok, socket, temporary_assigns: [form: socket.assigns.form]}
  end

  def handle_event("send_instructions", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_user_reset_password_instructions(
        user,
        &url(~p"/users/reset_password/#{&1}")
      )
    end

    # Regardless of whether the user exists, we show the same success message
    # to prevent email enumeration attacks
    info =
      "If your email is in our system, you will receive instructions to reset your password shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> redirect(to: ~p"/")}
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    {:noreply, assign(socket, form: to_form(user_params, as: "user"))}
  end
end
