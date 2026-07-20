defmodule GtfsPlannerWeb.UserLoginLive do
  use GtfsPlannerWeb, :live_view

  # Fixed presentation for the bounded recovery codes issued by
  # UserSessionController. Unknown or missing codes render no callout; the
  # controller never passes prose or markup to this view.
  @recovery_messages %{
    "invalid_credentials" => {"Log in failed", "Check your email and password, then try again."},
    "deactivated" => {"Account deactivated", "Contact an administrator to restore access."},
    "organization_required" =>
      {"Organization access required",
       "Contact an administrator to add this account to an organization."}
  }

  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <div id="login-page" phx-hook="FormErrorFocus" data-focus-on-mount="login-recovery">
        <.header class="text-center">
          Log in
        </.header>

        <div :if={@recovery} class="mb-6">
          <.callout kind="error" id="login-recovery" title={@recovery.title} tabindex="-1">
            {@recovery.body}
          </.callout>
        </div>

        <.simple_form
          for={@form}
          id="login_form"
          action={~p"/users/log_in"}
          phx-update="ignore"
          class="phx-submit-loading:opacity-60"
        >
          <.input field={@form[:email]} id="login-email" type="email" label="Email" required />
          <.input
            field={@form[:password]}
            id="login-password"
            type="password"
            label="Password"
            required
          />

          <.input
            field={@form[:remember_me]}
            id="login-remember-me"
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
            <.button
              id="login-submit"
              type="submit"
              phx-disable-with="Logging in…"
              variant="primary"
            >
              Log in
            </.button>
          </:actions>
        </.simple_form>
      </div>
    </Layouts.auth>
    """
  end

  def mount(_params, _session, socket) do
    email = Phoenix.Flash.get(socket.assigns.flash, :email)

    {:ok,
     socket
     |> assign(page_title: "Log in")
     |> assign(form: to_form(%{"email" => email}, as: "user"))
     |> assign(
       recovery: recovery_message(Phoenix.Flash.get(socket.assigns.flash, :login_recovery))
     )}
  end

  defp recovery_message(code) when is_binary(code) do
    case @recovery_messages do
      %{^code => {title, body}} -> %{title: title, body: body}
      _unknown -> nil
    end
  end

  defp recovery_message(_missing), do: nil
end
