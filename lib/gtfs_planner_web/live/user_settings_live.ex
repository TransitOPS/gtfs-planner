defmodule GtfsPlannerWeb.UserSettingsLive do
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      user_roles={@user_roles}
      current_organization={assigns[:current_organization]}
      current_gtfs_version={assigns[:current_gtfs_version]}
      available_versions={assigns[:available_versions] || []}
    >
      <div id="account-settings" phx-hook=".SettingsFormFocus" class="space-y-12">
        <.header>
          <span id="account-settings-title">Account settings</span>
          <:subtitle>Manage your email address and password.</:subtitle>
        </.header>

        <section id="email-settings" class="w-full max-w-[40rem] space-y-4">
          <h2 id="email-settings-title" class="text-lg font-semibold leading-7">
            Change email
          </h2>
          <.form
            for={@email_form}
            id="email_form"
            phx-submit="update_email"
            phx-change="validate_email"
            phx-auto-recover="ignore"
          >
            <.input
              field={@email_form[:email]}
              id="email-address"
              type="email"
              label="Email"
              autocomplete="email"
              required
            />

            <.input
              id="email-current-password"
              name="current_password"
              type="password"
              label="Current password"
              value={@email_current_password}
              errors={email_form_errors_for(@email_form, :current_password)}
              autocomplete="current-password"
              required
            />

            <.button
              id="email-submit"
              type="submit"
              variant="secondary"
              class="min-h-11"
              phx-disable-with="Sending confirmation…"
            >
              Send confirmation
            </.button>
          </.form>
        </section>

        <div class="border-t border-base-300" role="separator"></div>

        <section id="password-settings" class="w-full max-w-[40rem] space-y-4">
          <h2 id="password-settings-title" class="text-lg font-semibold leading-7">
            Change password
          </h2>
          <.form
            for={@password_form}
            id="password_form"
            phx-submit="update_password"
            phx-change="validate_password"
            phx-auto-recover="ignore"
            action={@password_form_action}
            method="post"
            phx-trigger-action={@trigger_submit}
          >
            <.input
              id="password-current-password"
              name="current_password"
              type="password"
              label="Current password"
              value={@password_current_password}
              errors={password_form_errors_for(@password_form, :current_password)}
              autocomplete="current-password"
              required
            />

            <.input
              field={@password_form[:password]}
              id="password-new-password"
              type="password"
              label="New password"
              help="Use 12–72 characters."
              autocomplete="new-password"
              required
            />

            <.input
              field={@password_form[:password_confirmation]}
              id="password-confirmation"
              type="password"
              label="Confirm new password"
              autocomplete="new-password"
              required
            />

            <.button
              id="password-submit"
              type="submit"
              variant="secondary"
              class="min-h-11"
              phx-disable-with="Changing password…"
            >
              Change password
            </.button>
          </.form>
        </section>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".SettingsFormFocus">
        export default {
          mounted() {
            this._focusTimer = null;
            this.handleEvent("focus_settings_error", (data) => {
              const formId = data.form_id;
              if (!["email_form", "password_form"].includes(formId)) return;

              if (this._focusTimer) {
                clearInterval(this._focusTimer);
                this._focusTimer = null;
              }

              const focusFirstInvalid = () => {
                const form = document.getElementById(formId);
                if (!form) return false;
                const invalid = form.querySelector('[aria-invalid="true"]');
                if (!invalid) return false;
                if (document.activeElement === invalid) return true;
                invalid.focus({ preventScroll: false });
                return document.activeElement === invalid;
              };

              // LiveView may restore focus onto the submit control after
              // phx-disable-with ends. Keep correcting until the invalid field
              // holds focus or the window expires.
              let attempts = 0;
              this._focusTimer = setInterval(() => {
                attempts += 1;
                if (focusFirstInvalid() || attempts >= 40) {
                  clearInterval(this._focusTimer);
                  this._focusTimer = null;
                }
              }, 25);
            });
          },
          destroyed() {
            if (this._focusTimer) clearInterval(this._focusTimer);
          }
        }
      </script>
    </Layouts.app>
    """
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    user_roles = socket.assigns[:user_roles] || []

    socket =
      socket
      |> assign(:page_title, "Account settings")
      |> assign(:user_roles, user_roles)
      |> assign(:email_form, to_form(Accounts.change_user_email(user)))
      |> assign(:password_form, to_form(Accounts.change_user_password(user)))
      |> assign(:email_current_password, "")
      |> assign(:password_current_password, "")
      |> assign(:trigger_submit, false)
      |> assign(:password_form_action, ~p"/users/update_password")

    {:ok, socket}
  end

  def handle_event(
        "validate_email",
        %{"user" => user_params, "current_password" => password},
        socket
      ) do
    email_form =
      socket.assigns.current_user
      |> Accounts.change_user_email(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply,
     socket
     |> assign(:email_form, email_form)
     |> assign(:email_current_password, password)}
  end

  def handle_event("validate_email", _params, socket) do
    {:noreply, socket}
  end

  def handle_event(
        "update_email",
        %{"user" => user_params, "current_password" => password},
        socket
      ) do
    user = socket.assigns.current_user

    case Accounts.apply_user_email(user, password, user_params) do
      {:ok, applied_user} ->
        case Accounts.deliver_user_update_email_instructions(
               applied_user,
               user.email,
               &url(~p"/users/settings/confirm_email/#{&1}")
             ) do
          {:ok, _email} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               "A link to confirm your email change has been sent to the new address."
             )
             |> assign(:email_current_password, "")
             |> assign(:email_form, to_form(Accounts.change_user_email(user)))
             |> assign(:trigger_submit, false)}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign(:email_current_password, "")
             |> put_flash(
               :error,
               "We couldn't send the confirmation email. Please try again."
             )
             |> assign(:email_form, to_form(%{"email" => user_params["email"]}, as: :user))
             |> assign(:trigger_submit, false)}
        end

      {:error, changeset} ->
        sanitized = sanitize_changeset_secrets(changeset)

        {:noreply,
         socket
         |> assign(:email_current_password, "")
         |> assign(:email_form, to_form(Map.put(sanitized, :action, :insert)))
         |> assign(:trigger_submit, false)
         |> push_event("focus_settings_error", %{form_id: "email_form"})}
    end
  end

  def handle_event("update_email", _params, socket) do
    {:noreply, socket}
  end

  def handle_event(
        "validate_password",
        %{"user" => user_params, "current_password" => password},
        socket
      ) do
    password_form =
      socket.assigns.current_user
      |> Accounts.change_user_password(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply,
     socket
     |> assign(:password_form, password_form)
     |> assign(:password_current_password, password)}
  end

  def handle_event("validate_password", _params, socket) do
    {:noreply, socket}
  end

  def handle_event(
        "update_password",
        %{"user" => user_params, "current_password" => password},
        socket
      ) do
    user = socket.assigns.current_user

    case Accounts.apply_user_password(user, password, user_params) do
      {:ok, _applied_user} ->
        {:noreply,
         socket
         |> assign(:trigger_submit, true)}

      {:error, changeset} ->
        sanitized =
          changeset
          |> sanitize_changeset_secrets()
          |> Map.put(:action, :insert)

        {:noreply,
         socket
         |> assign(:password_current_password, "")
         |> assign(:password_form, to_form(sanitized))
         |> assign(:trigger_submit, false)
         |> push_event("focus_settings_error", %{form_id: "password_form"})}
    end
  end

  def handle_event("update_password", _params, socket) do
    {:noreply, socket}
  end

  defp sanitize_changeset_secrets(changeset) do
    secret_string_keys = ["current_password", "password", "password_confirmation"]
    secret_atom_keys = [:current_password, :password, :password_confirmation]

    params =
      changeset.params
      |> Map.drop(secret_string_keys)

    changes =
      changeset.changes
      |> Map.drop(secret_atom_keys)

    %{changeset | params: params, changes: changes}
  end

  defp email_form_errors_for(%Phoenix.HTML.Form{source: source}, field) do
    errors = if is_map(source), do: Map.get(source, :errors, []), else: []

    errors
    |> Enum.filter(fn {f, _} -> f == field end)
    |> Enum.map(fn {_, {msg, opts}} -> translate_error(msg, opts) end)
  end

  defp email_form_errors_for(_form, _field), do: []

  defp password_form_errors_for(%Phoenix.HTML.Form{source: source}, field) do
    errors = if is_map(source), do: Map.get(source, :errors, []), else: []

    errors
    |> Enum.filter(fn {f, _} -> f == field end)
    |> Enum.map(fn {_, {msg, opts}} -> translate_error(msg, opts) end)
  end

  defp password_form_errors_for(_form, _field), do: []

  defp translate_error(msg, opts) do
    GtfsPlannerWeb.CoreComponents.translate_error({msg, opts})
  end
end
