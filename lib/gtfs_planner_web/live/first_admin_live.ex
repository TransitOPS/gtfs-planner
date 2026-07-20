defmodule GtfsPlannerWeb.FirstAdminLive do
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.FirstAdminForm

  @summary_fields [
    email: "first-admin-email",
    password: "first-admin-password",
    password_confirmation: "first-admin-password-confirmation",
    organization_name: "first-admin-organization-name",
    organization_alias: "first-admin-organization-alias"
  ]

  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <div id="first-admin-page" phx-hook=".FirstAdminErrorFocus">
        <.header class="text-center">
          Welcome to Pathways Studio
          <:subtitle>Set up your administrator account and organization</:subtitle>
        </.header>

        <section
          :if={@summary_entries != []}
          id="first-admin-error-summary"
          tabindex="-1"
          aria-labelledby="first-admin-error-summary-title"
          class="mb-6 rounded-lg border border-error/30 bg-error/5 p-4"
        >
          <h2 id="first-admin-error-summary-title" class="font-semibold text-error">
            There is a problem with this form
          </h2>
          <ul class="mt-2 space-y-1 text-sm text-error">
            <li :for={entry <- @summary_entries}>
              <%= if entry.target do %>
                <a href={"##{entry.target}"} class="link">{entry.message}</a>
              <% else %>
                {entry.message}
              <% end %>
            </li>
          </ul>
        </section>

        <.form for={@form} id="first_admin_form" phx-change="validate" phx-submit="setup">
          <div class="space-y-6">
            <.input
              field={@form[:email]}
              id="first-admin-email"
              type="email"
              label="Email"
              placeholder="admin@company.com"
              required
            />
            <.input
              field={@form[:password]}
              id="first-admin-password"
              type="password"
              label="Password"
              errors={@password_errors}
              required
            />
            <.input
              field={@form[:password_confirmation]}
              id="first-admin-password-confirmation"
              type="password"
              label="Confirm password"
              errors={@password_confirmation_errors}
              required
            />
            <.input
              field={@form[:organization_name]}
              id="first-admin-organization-name"
              type="text"
              label="Organization name"
              placeholder="My Transit Agency"
              required
            />
            <.input
              field={@form[:organization_alias]}
              id="first-admin-organization-alias"
              type="text"
              label="Organization alias (optional)"
              placeholder="my-transit-agency"
              help="Used in URLs, e.g., /gtfs/my-transit-agency"
            />
          </div>
          <div class="mt-8">
            <.button
              id="first-admin-submit"
              type="submit"
              phx-disable-with="Setting up..."
              class="w-full"
              variant="primary"
            >
              Create administrator account
            </.button>
          </div>
        </.form>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".FirstAdminErrorFocus">
        export default {
          mounted() {
            this.handleEvent("focus_first_admin_error", () => {
              const form = document.getElementById("first_admin_form");
              const invalid = form && form.querySelector('[aria-invalid="true"]');

              if (invalid) {
                invalid.focus();
                return;
              }

              const summary = document.getElementById("first-admin-error-summary");
              if (summary) summary.focus();
            });
          }
        }
      </script>
    </Layouts.auth>
    """
  end

  def mount(_params, _session, socket) do
    if Accounts.count_users() > 0 do
      {:ok, redirect(socket, to: ~p"/")}
    else
      {:ok,
       socket
       |> assign(page_title: "Setup Administrator")
       |> assign_form(Accounts.change_first_admin())}
    end
  end

  def handle_event("validate", %{"admin" => admin_params}, socket) do
    changeset =
      admin_params
      |> Accounts.change_first_admin()
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("setup", %{"admin" => admin_params}, socket) do
    case Accounts.register_first_admin(admin_params) do
      {:ok, _user} ->
        {:noreply, redirect(socket, to: ~p"/users/log_in")}

      {:error, changeset} ->
        changeset = FirstAdminForm.sanitize_secrets(changeset)
        summary_entries = error_summary_entries(changeset)

        {:noreply,
         socket
         |> assign(form: to_form(changeset, as: :admin))
         |> assign(summary_entries: summary_entries)
         |> assign(password_errors: translate_errors(changeset.errors, :password))
         |> assign(
           password_confirmation_errors:
             translate_errors(changeset.errors, :password_confirmation)
         )
         |> push_event("focus_first_admin_error", %{})}
    end
  end

  defp assign_form(socket, changeset) do
    socket
    |> assign(form: to_form(changeset, as: :admin))
    |> assign(summary_entries: [])
    |> assign(password_errors: [])
    |> assign(password_confirmation_errors: [])
  end

  defp error_summary_entries(changeset) do
    field_entries =
      for {field, control_id} <- @summary_fields,
          message <- translate_errors(changeset.errors, field) do
        %{target: control_id, message: message}
      end

    base_entries =
      for message <- translate_errors(changeset.errors, :base) do
        %{target: nil, message: message}
      end

    field_entries ++ base_entries
  end
end
