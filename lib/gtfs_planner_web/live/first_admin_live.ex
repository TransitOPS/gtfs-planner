defmodule GtfsPlannerWeb.FirstAdminLive do
  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.AuthComponents

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.FirstAdminForm
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlannerWeb.AuthForm

  # Field name to control id, in the page's order: the order of the summary
  # links and of the first invalid control that takes focus.
  @fields [
    organization_name: "first-admin-organization-name",
    organization_alias: "first-admin-organization-alias",
    email: "first-admin-email",
    password: "first-admin-password",
    password_confirmation: "first-admin-password-confirmation"
  ]

  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <div id="first-admin-page" phx-hook=".FirstAdminErrorFocus">
        <.auth_title id="first-admin-title">
          Set up your organization
          <:lede>
            You're the first one here. Name your organization and create your administrator login.
          </:lede>
        </.auth_title>

        <%!-- The summary stays until the next submit, so the form does not shift
              under the pointer while the person fixes it. A setup failure has no
              field to link to, so it names the consequence instead of a list. --%>
        <.auth_error
          :if={@summary_entries != []}
          id="first-admin-error-summary"
          tabindex="-1"
          title={
            if setup_failed?(@summary_entries),
              do: "Setup didn't finish",
              else: "Some details need fixing"
          }
        >
          <ul :if={!setup_failed?(@summary_entries)} class="mt-1 grid">
            <li :for={entry <- @summary_entries}>
              <a :if={entry.target} href={"##{entry.target}"} class="inline-block py-0.5 underline">
                {entry.message}
              </a>
              <span :if={!entry.target} class="inline-block py-0.5">{entry.message}</span>
            </li>
          </ul>
          <p class="mt-2 text-pretty">
            <%= if setup_failed?(@summary_entries) do %>
              Nothing was saved. Enter both passwords again and try once more. If it keeps happening, ask whoever set up this server to check its logs.
            <% else %>
              We cleared both password fields to keep them private. Enter them again.
            <% end %>
          </p>
        </.auth_error>

        <.form
          for={@form}
          id="first_admin_form"
          phx-change="validate"
          phx-submit="setup"
          novalidate
          class="auth-form mt-6 grid gap-6 phx-submit-loading:opacity-60"
        >
          <fieldset class="min-w-0">
            <legend class={legend_class()}>Your organization</legend>
            <div class="mt-3 grid gap-3">
              <.input
                field={@form[:organization_name]}
                id="first-admin-organization-name"
                type="text"
                label="Organization name"
                placeholder="e.g. North Coast Transit"
                errors={@field_errors.organization_name}
                autocomplete="organization"
                autofocus
                phx-debounce="blur"
                phx-blur="validate"
                required
              />

              <%!-- The short name is optional and generated from the organization
                    name, so it stays collapsed with its value showing. The client
                    owns `open`: a patch must not close it while the person types,
                    and the hook opens it when a field inside has an error. --%>
              <details
                id="first-admin-alias-details"
                open={alias_open?(@form, @field_errors)}
                phx-mounted={JS.ignore_attributes("open")}
                class="group"
              >
                <summary class="flex min-h-11 cursor-pointer list-none items-center gap-2 text-sm text-default [&::-webkit-details-marker]:hidden">
                  <.icon
                    name="hero-chevron-right"
                    class="size-4 shrink-0 text-muted transition-transform group-open:rotate-90 motion-reduce:transition-none"
                  />
                  <span class="min-w-0 break-words">
                    Short name:
                    <span id="first-admin-alias-value" class="font-semibold text-strong">
                      {alias_label(alias_value(@form))}
                    </span>
                  </span>
                  <span class="ml-auto shrink-0 font-semibold text-action group-open:hidden">
                    Change
                  </span>
                </summary>
                <div class="pb-1 pt-2">
                  <.input
                    field={@form[:organization_alias]}
                    id="first-admin-organization-alias"
                    type="text"
                    label="Short name (optional)"
                    help="Letters, numbers and hyphens. Leave blank to make it from the organization name. The organizations list calls this the alias."
                    errors={@field_errors.organization_alias}
                    autocomplete="off"
                    autocapitalize="none"
                    spellcheck="false"
                    phx-debounce="blur"
                    phx-blur="validate"
                  />
                </div>
              </details>
            </div>
          </fieldset>

          <fieldset class="min-w-0">
            <legend class={legend_class()}>Administrator login</legend>
            <div class="mt-3 grid gap-4">
              <.input
                field={@form[:email]}
                id="first-admin-email"
                type="email"
                label="Email"
                errors={@field_errors.email}
                autocomplete="email"
                autocapitalize="none"
                spellcheck="false"
                phx-debounce="blur"
                phx-blur="validate"
                required
              />
              <.input
                field={@form[:password]}
                id="first-admin-password"
                type="password"
                label="Password"
                help="At least 12 characters. A short phrase of a few words works well."
                errors={@field_errors.password}
                autocomplete="new-password"
                phx-debounce="blur"
                phx-blur="validate"
                required
              />
              <.input
                field={@form[:password_confirmation]}
                id="first-admin-password-confirmation"
                type="password"
                label="Confirm password"
                errors={@field_errors.password_confirmation}
                autocomplete="new-password"
                phx-debounce="blur"
                phx-blur="validate"
                required
              />
            </div>
          </fieldset>

          <.auth_submit id="first-admin-submit" class="mt-0" phx-disable-with="Creating account…">
            Create administrator account
          </.auth_submit>
        </.form>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".FirstAdminErrorFocus">
        export default {
          mounted() {
            this.handleEvent("focus_first_admin_error", () => {
              const form = document.getElementById("first_admin_form");
              const invalid = form && form.querySelector('[aria-invalid="true"]');

              this.focusControl(invalid || document.getElementById("first-admin-error-summary"));
            });

            this.el.addEventListener("click", (event) => {
              const link = event.target.closest('#first-admin-error-summary a[href^="#"]');
              const target = link && document.getElementById(link.getAttribute("href").slice(1));
              if (!target) return;

              event.preventDefault();
              this.focusControl(target);
            });
          },

          // The short name sits in a collapsed disclosure that has to open
          // before it can take focus. A phx-submit round trip then restores
          // focus to the submit button after this event runs, so focus is
          // asserted once more on the next frame if something else took it.
          focusControl(target) {
            if (!target) return;

            const details = target.closest("details");
            if (details) details.open = true;

            target.focus();
            requestAnimationFrame(() => {
              if (document.activeElement !== target && document.contains(target)) target.focus();
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
       |> assign(page_title: "Set up your organization")
       |> assign(summary_entries: [])
       |> assign_form(Accounts.change_first_admin())}
    end
  end

  def handle_event("validate", %{"admin" => admin_params}, socket) do
    changeset =
      admin_params
      |> AuthForm.defer_blank_errors()
      |> Accounts.change_first_admin()
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  # `phx-blur` payloads carry only event metadata (`%{"key" => _, "value" => _}`), never
  # form values. The `phx-debounce="blur"` form change that accompanies every field blur
  # delivers the values and is handled by the clause above, so metadata-only payloads
  # intentionally change nothing.
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("setup", %{"admin" => admin_params}, socket) do
    case Accounts.register_first_admin(admin_params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Administrator account created. Log in to continue.")
         |> redirect(to: ~p"/users/log_in")}

      {:error, :already_set_up} ->
        {:noreply,
         socket
         |> put_flash(:error, "Setup is already complete. Log in with the administrator account.")
         |> redirect(to: ~p"/users/log_in")}

      {:error, changeset} ->
        # Read the errors before the passwords are dropped: a failed submit has
        # no used-field state, so they come from the changeset directly, and the
        # confirmation copy depends on the params as submitted.
        changeset = drop_derived_alias_error(changeset)
        field_errors = submit_errors(changeset)
        changeset = FirstAdminForm.sanitize_secrets(changeset)

        {:noreply,
         socket
         |> assign(form: to_form(changeset, as: :admin))
         |> assign(field_errors: field_errors)
         |> assign(summary_entries: summary_entries(field_errors, changeset))
         |> push_event("focus_first_admin_error", %{})}
    end
  end

  defp assign_form(socket, changeset) do
    changeset = drop_derived_alias_error(changeset)
    form = to_form(changeset, as: :admin)

    field_errors =
      Map.new(@fields, fn {field, _control_id} ->
        {field,
         AuthForm.used_errors(form[field], &error_message(field, &1, changeset.params || %{}))}
      end)

    socket
    |> assign(form: form)
    |> assign(field_errors: field_errors)
  end

  defp submit_errors(changeset) do
    Map.new(@fields, fn {field, _control_id} ->
      {field,
       for(
         {^field, error} <- changeset.errors,
         do: error_message(field, error, changeset.params || %{})
       )}
    end)
  end

  # A blank short name falls back to the organization name, so the changeset's
  # "can't be blank" on it only repeats the organization name's own error.
  defp drop_derived_alias_error(changeset) do
    errors =
      Enum.reject(changeset.errors, fn
        {:organization_alias, {_message, opts}} -> opts[:validation] == :required
        _other -> false
      end)

    %{changeset | errors: errors}
  end

  # One entry per message, in page order, each linking to its control; setup
  # failures (base errors) link nowhere.
  defp summary_entries(field_errors, changeset) do
    field_entries =
      for {field, control_id} <- @fields,
          message <- field_errors[field] do
        %{target: control_id, message: message}
      end

    base_entries =
      for {:base, {message, _opts}} <- changeset.errors, do: %{target: nil, message: message}

    field_entries ++ base_entries
  end

  # Plain-language versions of the changeset messages, chosen by the rule that
  # failed rather than by its text.
  defp error_message(:password, error, _params), do: AuthForm.password_error(error)

  defp error_message(:password_confirmation, error, params),
    do: AuthForm.confirmation_error(error, params)

  defp error_message(:email, {_message, opts} = error, _params) do
    case opts[:validation] do
      :required -> "Enter your email address."
      :format -> "Enter an email address with an @ and no spaces."
      _other -> translate_error(error)
    end
  end

  defp error_message(:organization_name, {_message, opts} = error, _params) do
    case opts[:validation] do
      :required -> "Enter your organization's name."
      _other -> translate_error(error)
    end
  end

  defp error_message(:organization_alias, {_message, opts} = error, params) do
    if opts[:constraint] == :unique,
      do: alias_taken(params),
      else: translate_error(error)
  end

  # Names the short name that collided. A blank short name is made from the
  # organization name, as `FirstAdminForm` does, and `Organization.changeset/2`
  # normalizes either one.
  defp alias_taken(params) do
    typed = String.trim(params["organization_alias"] || "")
    candidate = if typed == "", do: params["organization_name"], else: typed

    taken =
      %Organization{}
      |> Organization.changeset(%{alias: candidate})
      |> Ecto.Changeset.get_field(:alias)

    "Another organization already uses #{taken}. Enter a different short name."
  end

  defp alias_value(form), do: form[:organization_alias].value |> to_string() |> String.trim()

  defp alias_label(""), do: "set automatically"
  defp alias_label(value), do: value

  defp alias_open?(form, field_errors),
    do: field_errors.organization_alias != [] or alias_value(form) != ""

  # A setup failure is the only summary with no field to link to.
  defp setup_failed?(entries), do: entries != [] and Enum.all?(entries, &is_nil(&1.target))

  defp legend_class,
    do: "font-display text-[19px] font-semibold leading-tight tracking-[-0.02em] text-strong"
end
