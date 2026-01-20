defmodule GtfsPlannerWeb.UserLoginLive do
  use GtfsPlannerWeb, :live_view

  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <.header class="text-center">
        Log in to account
      </.header>

      <.simple_form
        for={@form}
        id="login_form"
        action={~p"/users/log_in"}
        phx-update="ignore"
      >
        <.input field={@form[:email]} type="email" label="Email" required />
        <.input field={@form[:password]} type="password" label="Password" required />

        <.input
          field={@form[:remember_me]}
          type="checkbox"
          label="Keep me logged in for 60 days"
        />

        <:actions>
          <.link
            navigate={~p"/users/reset_password"}
            class="text-sm font-semibold link link-hover text-base-content/70"
          >
            Forgot your password?
          </.link>
        </:actions>

        <:actions>
          <.button phx-disable-with="Logging in..." variant="primary">
            Log in <span aria-hidden="true">→</span>
          </.button>
        </:actions>
      </.simple_form>
    </Layouts.auth>
    """
  end

  def mount(_params, _session, socket) do
    email = Phoenix.Flash.get(socket.assigns.flash, :email)
    form = to_form(%{"email" => email}, as: "user")
    {:ok, assign(socket, form: form), temporary_assigns: [form: form]}
  end
end
