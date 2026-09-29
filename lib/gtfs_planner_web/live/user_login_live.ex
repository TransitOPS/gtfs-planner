defmodule GtfsPlannerWeb.UserLoginLive do
  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.AuthComponents

  # Fixed presentation for the bounded recovery codes issued by
  # UserSessionController. Each code maps to a tone plus a fixed title and
  # body. Unknown or missing codes render no callout; the controller never
  # passes prose or markup to this view.
  @recovery_messages %{
    "invalid_credentials" =>
      {"error", "Email or password is incorrect", "Check both and try again."},
    "deactivated" =>
      {"warning", "Account deactivated", "Contact an administrator to restore access."},
    "organization_required" =>
      {"warning", "Organization access required",
       "Contact an administrator to add this account to an organization."}
  }

  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <div id="login-page" phx-hook="FormErrorFocus" data-focus-on-mount="login-recovery">
        <.auth_title id="login-title">Log in</.auth_title>

        <div
          :if={@recovery}
          id="login-recovery"
          tabindex="-1"
          class={[
            "mt-5 flex items-start gap-3 rounded-card px-4 py-3.5 text-sm",
            recovery_tone_class(@recovery.tone)
          ]}
        >
          <.icon name={recovery_icon(@recovery.tone)} class="mt-px size-5 shrink-0" />
          <div class="min-w-0">
            <p class="font-semibold">{@recovery.title}</p>
            <p class="text-pretty">{@recovery.body}</p>
          </div>
        </div>

        <.form for={@form} id="login_form" action={~p"/users/log_in"} phx-update="ignore" class="mt-6">
          <div class="grid gap-5">
            <div class="grid gap-1.5">
              <label for="login-email" class="text-sm font-semibold text-strong">Email</label>
              <input
                id="login-email"
                name="user[email]"
                type="email"
                value={@form[:email].value}
                autocomplete="username"
                autocapitalize="none"
                spellcheck="false"
                required
                class="h-11 w-full min-w-0 rounded-control border border-control bg-white px-3 text-base text-strong focus-visible:outline-offset-0"
              />
            </div>
            <div class="grid gap-1.5">
              <label for="login-password" class="text-sm font-semibold text-strong">Password</label>
              <input
                id="login-password"
                name="user[password]"
                type="password"
                autocomplete="current-password"
                required
                class="h-11 w-full min-w-0 rounded-control border border-control bg-white px-3 text-base text-strong focus-visible:outline-offset-0"
              />
            </div>
          </div>

          <label
            for="login-remember-me"
            class="mt-2 flex min-h-11 cursor-pointer items-center gap-2.5 text-sm text-default"
          >
            <input type="hidden" name="user[remember_me]" value="false" />
            <input
              id="login-remember-me"
              name="user[remember_me]"
              type="checkbox"
              value="true"
              checked={@form[:remember_me].value in ["true", true]}
              class="size-[17px] shrink-0 accent-action"
            /> Keep me logged in for 60 days
          </label>

          <.auth_submit id="login-submit" phx-disable-with="Logging in…">Log in</.auth_submit>
        </.form>

        <p class="-mb-2.5 mt-3">
          <.auth_link navigate={~p"/users/reset_password"}>Forgot your password?</.auth_link>
        </p>
      </div>

      <:footer>No account? Ask your organization administrator for an invitation.</:footer>
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
      %{^code => {tone, title, body}} -> %{tone: tone, title: title, body: body}
      _unknown -> nil
    end
  end

  defp recovery_message(_missing), do: nil

  defp recovery_tone_class("error"), do: "bg-error-bg text-error-fg"
  defp recovery_tone_class(_warning), do: "bg-warning-bg text-warning-fg"

  defp recovery_icon("error"), do: "hero-exclamation-circle"
  defp recovery_icon(_warning), do: "hero-exclamation-triangle"
end
