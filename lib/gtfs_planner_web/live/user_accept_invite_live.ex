defmodule GtfsPlannerWeb.UserAcceptInviteLive do
  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.AuthComponents

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.User
  alias GtfsPlannerWeb.AuthForm

  @has_password_message "You already have a password. Sign in to continue."

  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <div id="accept-invite-page" phx-hook="FormErrorFocus">
        <.auth_title id="accept-invite-title">
          Set password
          <:lede>Choose a password to finish setting up your account.</:lede>
        </.auth_title>

        <%!-- A rejected save clears both fields, because the server never sends a
              password back to the browser. The banner says so; the fields say
              what to fix, and FormErrorFocus moves focus to the first one. --%>
        <.auth_error
          :if={@submit_failed}
          id="accept-invite-banner"
          role="alert"
          title="Your password wasn't saved"
        >
          <p class="text-pretty">
            Fix the highlighted field, then enter your password again. We clear both password fields after an error to keep them private.
          </p>
        </.auth_error>

        <.form
          for={@form}
          id="accept_invite_form"
          phx-change="validate"
          phx-submit="accept_invite"
          novalidate
          class="auth-form mt-6 phx-submit-loading:opacity-60"
        >
          <div class="grid gap-5">
            <.input
              field={@form[:password]}
              id="invite-password"
              type="password"
              label="Password"
              help="At least 12 characters. A short phrase of a few words works well."
              errors={@password_errors}
              autocomplete="new-password"
              phx-debounce="blur"
              phx-blur="validate"
              required
            />

            <.input
              field={@form[:password_confirmation]}
              id="invite-password-confirmation"
              type="password"
              label="Confirm password"
              errors={@password_confirmation_errors}
              autocomplete="new-password"
              phx-debounce="blur"
              phx-blur="validate"
              required
            />
          </div>

          <.auth_submit
            id="accept-invite-submit"
            class="mt-6"
            phx-disable-with="Setting password…"
          >
            Set password
          </.auth_submit>
        </.form>

        <p class="-mb-2.5 mt-3">
          <.auth_link id="accept-invite-login" navigate={~p"/users/log_in"}>
            Already set a password? Log in
          </.auth_link>
        </p>
      </div>
    </Layouts.auth>
    """
  end

  def mount(%{"token" => token}, _session, socket) do
    case Accounts.get_user_by_invite_token(token) do
      # An invite never replaces an existing password (tokens issued before that
      # rule may still exist).
      %User{hashed_password: hashed_password} when not is_nil(hashed_password) ->
        {:ok, redirect_to_login_with_password_notice(socket)}

      %User{} = user ->
        {:ok,
         socket
         |> assign(page_title: "Set password")
         |> assign(user: user, token: token, submit_failed: false)
         |> assign_form(Accounts.change_user_password(user))}

      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Invite link is invalid or it has expired.")
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

  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("accept_invite", %{"user" => user_params}, socket) do
    # Only the password fields reach the context; the invite names the organization.
    passwords = Map.take(user_params, ["password", "password_confirmation"])

    case Accounts.accept_invite_set_password(socket.assigns.user, passwords) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Invitation accepted. Log in to continue.")
         |> redirect(to: ~p"/users/log_in")}

      {:error, :already_has_password} ->
        {:noreply, redirect_to_login_with_password_notice(socket)}

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
           password_errors:
             for({:password, error} <- changeset.errors, do: AuthForm.password_error(error))
         )
         |> assign(
           password_confirmation_errors:
             for(
               {:password_confirmation, error} <- changeset.errors,
               do: AuthForm.confirmation_error(error, params)
             )
         )
         |> push_event("focus_form_error", %{form_id: "accept_invite_form", fallback_id: nil})}
    end
  end

  defp redirect_to_login_with_password_notice(socket) do
    socket
    |> put_flash(:info, @has_password_message)
    |> redirect(to: ~p"/users/log_in")
  end

  defp assign_form(socket, changeset) do
    form = to_form(changeset, as: "user")

    socket
    |> assign(form: form)
    |> assign(password_errors: AuthForm.used_errors(form[:password], &AuthForm.password_error/1))
    |> assign(
      password_confirmation_errors:
        AuthForm.used_errors(
          form[:password_confirmation],
          &AuthForm.confirmation_error(&1, form.params)
        )
    )
  end
end
