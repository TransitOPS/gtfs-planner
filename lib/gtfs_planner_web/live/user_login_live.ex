defmodule GtfsPlannerWeb.UserLoginLive do
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-sm">
      <.header class="text-center">
        Log in to account
        <:subtitle>
          Don't have an account?
          <.link navigate={~p"/users/register"} class="font-semibold text-brand hover:underline">
            Sign up
          </.link>
          for an account now.
        </:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="login_form"
        phx-submit="save"
        phx-change="validate"
        action={~p"/users/log_in"}
      >
        <.input field={@form[:email]} type="email" label="Email" required />
        <.input field={@form[:password]} type="password" label="Password" required />

        <:actions>
          <.link
            navigate={~p"/users/reset_password"}
            class="text-sm font-semibold leading-6 text-zinc-900 hover:text-zinc-700"
          >
            Forgot your password?
          </.link>
        </:actions>

        <:actions>
          <.button phx-disable-with="Logging in..." class="w-full">
            Log in <span aria-hidden="true">→</span>
          </.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    email = Phoenix.Flash.get(socket.assigns.flash, :email)
    form = to_form(%{"email" => email}, as: "user")
    {:ok, assign(socket, form: form), temporary_assigns: [form: form]}
  end

  def handle_event("save", %{"user" => user_params}, socket) do
    %{"email" => email, "password" => password} = user_params

    if user = Accounts.get_user_by_email_and_password(email, password) do
      _token = Accounts.generate_user_session_token(user)

      socket
      |> put_flash(:info, "Welcome back!")
      |> redirect(to: ~p"/organizations")
    else
      {:noreply,
       socket
       |> put_flash(:error, "Invalid email or password")
       |> assign(form: to_form(user_params, as: "user"))}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    {:noreply, assign(socket, form: to_form(user_params, as: "user"))}
  end
end
