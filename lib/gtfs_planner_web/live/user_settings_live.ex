defmodule GtfsPlannerWeb.UserSettingsLive do
  @moduledoc """
  The signed-in person's own account: the address they sign in with, the
  password they sign in with, and what that account can reach.

  This is a credentials page, not a profile page. `GtfsPlanner.Accounts.User`
  carries no name, avatar, or bio, so there is nothing here to edit beyond the
  two fields below — which is why the heading names the account rather than a
  profile, and why the record of who you are (address, confirmation state,
  account created, roles) sits read-only in the aside rather than above the
  forms.

  ## What the code does with an address change

  - An address change is a two-step, confirmation-gated flow, and the page has
    to say so. `Accounts.apply_user_email/3` ends in
    `Ecto.Changeset.apply_action(:update)`, which *validates* and returns an
    updated struct but does **not** write: the sign-in address only changes when
    `Accounts.update_user_email/2` redeems the token at
    `/users/settings/confirm_email/:token`. So after submitting, the account is
    still on the old address, the new one is held only by an emailed token, and
    if the link is never opened nothing changes at all.
  - That also means the app cannot show a "pending change" state. The proposed
    address is not persisted anywhere a page could read it, so the honest thing
    is to tell the reader the old address is still live and that the link is
    what completes the change — not to imply either that it already applied or
    that something is being held for them.
  - Changing the password signs the person out everywhere.
    `Accounts.update_user_password/3` deletes every `UserToken` for the account
    (all sessions, all remember-me cookies, and any pending confirmation link)
    and `UserSessionController.complete_login/4` re-issues only this device's
    session. The callout above the form says so before they press the button.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Authorization.Roles

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

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
      <%!-- FormErrorFocus is the app's shared focus-on-error hook, already
            registered in assets/js/app.js. It replaces the bespoke
            `.SettingsFormFocus` hook this page used to carry, which polled
            every 25ms for up to 250ms because it had no error summary to aim
            at. `focus_scoped_target` names the summary directly: the summary is
            the better landing place than the first invalid control, because it
            lists every problem and links to each field. --%>
      <div id="account-page" phx-hook="FormErrorFocus" class="mx-auto max-w-[1280px]">
        <.header>
          <span id="account-settings-title">Profile settings</span>
          <:subtitle>
            {if @current_organization,
              do: "Your sign-in address, password, and access for #{@current_organization.name}.",
              else: "Your sign-in address and password."}
          </:subtitle>
        </.header>

        <div class="grid items-start gap-6 lg:grid-cols-[minmax(0,1fr)_20rem]">
          <div class="grid min-w-0 gap-6">
            <.email_card
              user={@current_user}
              form={@email_form}
              current_password={@email_current_password}
              current_password_errors={email_password_errors(@email_form)}
              failures={@email_failures}
            />
            <.password_card
              form={@password_form}
              current_password={@password_current_password}
              current_password_errors={password_password_errors(@password_form)}
              mismatch={@password_mismatch}
              failures={@password_failures}
              form_action={@password_form_action}
              trigger_submit={@trigger_submit}
            />
          </div>

          <.account_facts
            user={@current_user}
            roles={@role_details}
            organization={assigns[:current_organization]}
            account_created={format_date(@current_user.inserted_at)}
            confirmed={not is_nil(@current_user.confirmed_at)}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ── Email card ────────────────────────────────────────────────────────────
  attr :user, :map, required: true
  attr :form, :any, required: true
  attr :current_password, :string, required: true
  attr :current_password_errors, :list, required: true
  attr :failures, :list, required: true

  defp email_card(assigns) do
    ~H"""
    <section id="email-settings" class="account-card" aria-labelledby="email-settings-title">
      <div class="account-card-head">
        <div class="min-w-0">
          <h2 id="email-settings-title" class="leading-snug">Email address</h2>
          <p>Where you sign in, and where your confirmations and password reset links are sent.</p>
        </div>
        <span :if={is_nil(@user.confirmed_at)} class="account-badge warning">
          <.icon name="hero-exclamation-triangle" class="size-[15px]" /> Not confirmed
        </span>
      </div>

      <div class="account-card-body">
        <.error_summary
          id="email-error-summary"
          failures={@failures}
          title="We couldn't change your email address"
        />

        <.form
          for={@form}
          id="email_form"
          phx-submit="update_email"
          phx-change="validate_email"
          phx-auto-recover="ignore"
          class="grid gap-5"
        >
          <.input
            field={@form[:email]}
            id="email-address"
            type="email"
            label="Email address"
            help="We'll email a confirmation link to the new address. Your sign-in address only changes once you open that link, so keep using the one above until you do."
            errors={curated_errors(@form, :email)}
            autocomplete="email"
            required
          />

          <.input
            id="email-current-password"
            name="current_password"
            type="password"
            label="Current password"
            help="Your existing password, to confirm the change is really you."
            value={@current_password}
            errors={@current_password_errors}
            autocomplete="current-password"
            required
          />

          <div class="flex flex-wrap items-center gap-x-4 gap-y-3">
            <.button
              id="email-submit"
              type="submit"
              class="min-h-11"
              phx-disable-with="Sending confirmation…"
            >
              Send confirmation link
            </.button>
            <p class="m-0 text-[13px] text-muted">
              You stay signed in while you check the new inbox.
            </p>
          </div>
        </.form>
      </div>
    </section>
    """
  end

  # ── Password card ─────────────────────────────────────────────────────────
  attr :form, :any, required: true
  attr :current_password, :string, required: true
  attr :current_password_errors, :list, required: true
  attr :mismatch, :boolean, required: true
  attr :failures, :list, required: true
  # The password form is a real (non-LiveView) POST: a successful change
  # re-issues the session server-side, so the page has to reload rather than
  # patch. `trigger_submit` is what flips it on success.
  attr :form_action, :string, required: true
  attr :trigger_submit, :boolean, required: true

  defp password_card(assigns) do
    ~H"""
    <section id="password-settings" class="account-card" aria-labelledby="password-settings-title">
      <div class="account-card-head">
        <div class="min-w-0">
          <h2 id="password-settings-title" class="leading-snug">Password</h2>
          <p>The password you use to sign in to Pathways Studio.</p>
        </div>
      </div>

      <div class="account-card-body">
        <%!-- Stated before the button is pressed, not after: the tokens are
              already gone by the time a failure could be reported. --%>
        <div class="account-callout soft mb-5">
          <.icon name="hero-information-circle" class="size-[18px] shrink-0 text-cyan-700" />
          <p class="m-0 min-w-0">
            <strong class="font-bold">Changing your password signs you out everywhere.</strong>
            This device signs back in automatically. On your other devices you'll need to sign in again with the new password.
          </p>
        </div>

        <.error_summary
          id="password-error-summary"
          failures={@failures}
          title="We couldn't change your password"
        />

        <.form
          for={@form}
          id="password_form"
          phx-submit="update_password"
          phx-change="validate_password"
          phx-auto-recover="ignore"
          action={@form_action}
          method="post"
          phx-trigger-action={@trigger_submit}
          class="grid gap-5"
        >
          <.input
            id="password-current-password"
            name="current_password"
            type="password"
            label="Current password"
            help="Your existing password, to confirm the change is really you."
            value={@current_password}
            errors={@current_password_errors}
            autocomplete="current-password"
            required
          />

          <.input
            field={@form[:password]}
            id="password-new-password"
            type="password"
            label="New password"
            help="12 to 72 characters. A short phrase of unrelated words is stronger than one complicated word."
            errors={curated_errors(@form, :password)}
            minlength="12"
            maxlength="72"
            autocomplete="new-password"
            required
          />

          <.input
            field={@form[:password_confirmation]}
            id="password-confirmation"
            type="password"
            label="Confirm new password"
            help="Type the new password once more so we know it arrived."
            errors={curated_errors(@form, :password_confirmation)}
            autocomplete="new-password"
            required
          />

          <%!-- A live result, not a failed submit: the reader is mid-keystroke,
                so it announces politely and gets no error summary. --%>
          <p
            :if={@mismatch}
            id="password-mismatch-message"
            role="status"
            aria-live="polite"
            class="m-0 flex items-start gap-2 text-[13px] leading-relaxed text-error-fg"
          >
            <.icon name="hero-exclamation-triangle" class="mt-px size-[18px] shrink-0" />
            <span>The two new passwords don't match yet. Retype the last one.</span>
          </p>

          <div class="flex flex-wrap items-center gap-x-4 gap-y-3">
            <.button
              id="password-submit"
              type="submit"
              class="min-h-11"
              phx-disable-with="Changing password…"
            >
              Change password
            </.button>
          </div>
        </.form>
      </div>
    </section>
    """
  end

  # ── Error summary ─────────────────────────────────────────────────────────
  attr :id, :string, required: true
  attr :failures, :list, required: true
  attr :title, :string, required: true

  # The summary is the landing place after a rejected submit: it lists every
  # problem at once and links to each field, so the reader does not have to
  # hunt for a second error. Live validation is not a rejection and never
  # produces one.
  defp error_summary(%{failures: []} = assigns) do
    ~H"""
    """
  end

  defp error_summary(assigns) do
    ~H"""
    <div id={@id} role="alert" tabindex="-1" class="account-error-summary mb-5">
      <strong class="font-bold">{@title}</strong>
      <a :for={failure <- @failures} href={failure.href}>{failure.msg}</a>
    </div>
    """
  end

  # ── Account facts aside ───────────────────────────────────────────────────
  attr :user, :map, required: true
  attr :roles, :list, required: true
  attr :organization, :any, required: true
  attr :account_created, :string, required: true
  attr :confirmed, :boolean, required: true

  defp account_facts(assigns) do
    ~H"""
    <aside id="account-facts" class="grid min-w-0 gap-6" aria-labelledby="access-title">
      <section
        :if={@organization}
        id="access-card"
        class="account-card"
        aria-labelledby="access-title"
      >
        <div class="account-card-head">
          <div class="min-w-0">
            <h2 id="access-title" class="leading-snug">Access in this organization</h2>
            <p>{@organization.name}</p>
          </div>
        </div>
        <div class="account-card-body">
          <ul :if={@roles != []} id="access-roles" class="m-0 grid list-none gap-4 p-0">
            <li :for={role <- @roles}>
              <span class="account-badge selected">{role.name}</span>
              <span
                :if={role.description}
                class="mt-1.5 block text-[13px] leading-relaxed text-default"
              >
                {role.description}
              </span>
            </li>
          </ul>
          <p :if={@roles == []} class="m-0 text-[13px] leading-relaxed text-default">
            You have no role in this organization yet, so there is nothing for you to change here.
          </p>
          <p class="mb-0 mt-5 text-[13px] leading-relaxed text-muted">
            Roles are set by an organization administrator. To change yours, ask them on the Users page.
          </p>
          <a
            id="manage-members"
            href={~p"/admin/users"}
            class="mt-3 inline-flex min-h-11 items-center gap-1.5 text-sm font-bold no-underline hover:underline"
          >
            Manage organization members <.icon name="hero-chevron-right" class="size-4" />
          </a>
        </div>
      </section>

      <%!-- `AssignOrganization` is `:optional`, so a system administrator
            reaches this page with no organization and no roles. That is a real
            state, not an error, so it gets a next step rather than an empty
            panel: the invite flow is how access is granted. --%>
      <section
        :if={is_nil(@organization)}
        id="access-card"
        class="account-card"
        aria-labelledby="access-title"
      >
        <div class="account-card-head">
          <div class="min-w-0">
            <h2 id="access-title" class="leading-snug">No organization access</h2>
          </div>
        </div>
        <div class="account-card-body">
          <p class="m-0 text-[13px] leading-relaxed text-default">
            This account isn't a member of any organization, so it has no dataset to work on. You can still change your sign-in details.
          </p>
          <ul class="mt-4 grid list-none gap-2 p-0">
            <li class="flex items-start gap-2.5 text-[13px] leading-relaxed text-default">
              <.icon name="hero-chevron-right" class="mt-px size-[18px] shrink-0 text-muted" />
              <span>Ask an organization administrator to invite this email address.</span>
            </li>
            <li class="flex items-start gap-2.5 text-[13px] leading-relaxed text-default">
              <.icon name="hero-chevron-right" class="mt-px size-[18px] shrink-0 text-muted" />
              <span>
                If you already have another account here, sign out and sign in with that one.
              </span>
            </li>
          </ul>
        </div>
      </section>

      <section id="sign-in-facts" class="account-card" aria-labelledby="facts-title">
        <div class="account-card-head">
          <div class="min-w-0">
            <h2 id="facts-title" class="leading-snug">Your sign-in</h2>
          </div>
        </div>
        <dl class="m-0 grid gap-0 px-5 py-1">
          <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-0.5 border-b border-subtle py-3.5">
            <dt class="text-[13px] text-muted">Email address</dt>
            <dd id="fact-email" class="m-0 min-w-0 break-all text-[13px] font-semibold text-strong">
              {@user.email}
            </dd>
          </div>
          <div class="flex flex-wrap items-center justify-between gap-x-4 gap-y-1 border-b border-subtle py-3.5">
            <dt class="text-[13px] text-muted">Confirmation</dt>
            <dd class="m-0">
              <span :if={@confirmed} id="fact-confirmed" class="account-badge success">
                <.icon name="hero-check-circle" class="size-[15px]" /> Confirmed
              </span>
              <span :if={not @confirmed} id="fact-unconfirmed" class="account-badge warning">
                <.icon name="hero-exclamation-triangle" class="size-[15px]" /> Not confirmed
              </span>
            </dd>
          </div>
          <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-0.5 py-3.5">
            <dt class="text-[13px] text-muted">Account created</dt>
            <dd id="fact-created" class="m-0 text-[13px] font-semibold text-strong tabular-nums">
              {@account_created}
            </dd>
          </div>
        </dl>
      </section>

      <div :if={not @confirmed} id="confirm-reminder" class="account-callout warning">
        <.icon name="hero-exclamation-triangle" class="shrink-0" />
        <p class="m-0 min-w-0">
          <strong class="font-bold">This address isn't confirmed yet.</strong>
          Email confirmations and password reset links are sent here, so you need to be able to read it. Use the button in the email card to send a fresh link, or ask an organization administrator to reset it if it isn't an address you control.
        </p>
      </div>
    </aside>
    """
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    user_roles = socket.assigns[:user_roles] || []

    socket =
      socket
      |> assign(:page_title, "Profile settings")
      |> assign(:user_roles, user_roles)
      |> assign(:role_details, role_details(user_roles))
      |> assign(:email_form, to_form(Accounts.change_user_email(user)))
      |> assign(:password_form, to_form(Accounts.change_user_password(user)))
      |> assign(:email_current_password, "")
      |> assign(:password_current_password, "")
      |> assign(:email_failures, [])
      |> assign(:password_failures, [])
      |> assign(:password_mismatch, false)
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
            # `apply_user_email/3` ends in `apply_action/2`, which validates but
            # does not write, so the account is still on the old address and the
            # link is what completes the change. The flash has to say both, or
            # the reader cannot tell which address to use in the meantime.
            {:noreply,
             socket
             |> put_flash(
               :info,
               "Confirmation link sent to #{user_params["email"]}. Your sign-in address changes when you open it — until then, keep using #{user.email}."
             )
             |> assign(:email_current_password, "")
             |> assign(:email_form, to_form(Accounts.change_user_email(user)))
             |> assign(:email_failures, [])
             |> assign(:trigger_submit, false)}

          {:error, _reason} ->
            # Nothing was written: the address never changed, so the message
            # must not leave the reader believing it did.
            {:noreply,
             socket
             |> assign(:email_current_password, "")
             |> put_flash(
               :error,
               "We couldn't send the confirmation link, so nothing changed. Your sign-in address is still #{user.email} — try again."
             )
             |> assign(:email_form, to_form(%{"email" => user_params["email"]}, as: :user))
             |> assign(:email_failures, [])
             |> assign(:trigger_submit, false)}
        end

      {:error, changeset} ->
        sanitized = sanitize_changeset_secrets(changeset)
        failures = email_failures(sanitized)

        {:noreply,
         socket
         |> assign(:email_current_password, "")
         |> assign(:email_form, to_form(Map.put(sanitized, :action, :insert)))
         |> assign(:email_failures, failures)
         |> assign(:trigger_submit, false)
         |> focus_summary("email-error-summary")}
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
    changeset =
      socket.assigns.current_user
      |> Accounts.change_user_password(user_params)
      |> move_confirmation_mismatch()

    password_form = changeset |> Map.put(:action, :validate) |> to_form()

    # A live result, so the summary stays empty: nothing was submitted and
    # nothing failed. The message under the field carries it instead.
    mismatch? = password_form_mismatch?(changeset)

    {:noreply,
     socket
     |> assign(:password_form, password_form)
     |> assign(:password_current_password, password)
     |> assign(:password_mismatch, mismatch?)}
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
         |> assign(:password_mismatch, false)
         |> assign(:trigger_submit, true)}

      {:error, changeset} ->
        sanitized =
          changeset
          |> sanitize_changeset_secrets()
          |> move_confirmation_mismatch()
          |> Map.put(:action, :insert)

        failures = password_failures(sanitized)

        {:noreply,
         socket
         |> assign(:password_current_password, "")
         |> assign(:password_form, to_form(sanitized))
         |> assign(:password_failures, failures)
         |> assign(:password_mismatch, false)
         |> assign(:trigger_submit, false)
         |> focus_summary("password-error-summary")}
    end
  end

  def handle_event("update_password", _params, socket) do
    {:noreply, socket}
  end

  ## Focus

  # `FormErrorFocus` (assets/js/form_error_focus_hook.js) is the app's shared
  # hook for this, already registered in assets/js/app.js. It focuses a named
  # element it owns and re-asserts once on the next frame, which is enough to
  # beat LiveView's post-submit focus restore — the `.SettingsFormFocus` hook
  # this page used to carry instead polled 10 times at 25ms for the same job.
  defp focus_summary(socket, id) do
    push_event(socket, "focus_scoped_target", %{id: id})
  end

  ## Error summaries

  # The summary is the landing place after a rejected submit: it lists every
  # problem at once and links to each field, so the reader does not have to
  # hunt for a second error. Live validation is not a rejection, and never
  # produces one.
  @email_failure_targets [
    {:email, "#email-address"},
    {:current_password, "#email-current-password"}
  ]

  @password_failure_targets [
    {:current_password, "#password-current-password"},
    {:password, "#password-new-password"},
    {:password_confirmation, "#password-confirmation"}
  ]

  # `errors` arrives newest-first, so reverse it to keep the summary in the
  # order the reader met the problems: the field they typed first comes first.
  defp failures_for(%{errors: errors}, targets) do
    for {field, {msg, opts}} <- Enum.reverse(errors),
        target = Enum.find(targets, fn {f, _href} -> f == field end),
        target != nil do
      %{msg: summary_message(field, msg, opts), href: elem(target, 1)}
    end
  end

  # A summary that says "is invalid" has failed at its only job, which is to
  # tell the reader what to do next. `translate_error/1` falls through to
  # Ecto's own wording whenever gettext has no entry, and on this page that
  # produced "is invalid" for a wrong current password. The mappings below name
  # the field's job instead; anything unmapped still falls back to the shared
  # translation, so no error is ever silently dropped from the summary.
  # `opts` is the changeset's error options list, not the validation alone, so
  # the validation is read out of it here.
  defp summary_message(:current_password, msg, opts),
    do: error_text(msg, opts, "Your current password is not correct.")

  defp summary_message(:email, msg, opts) do
    cond do
      opts[:validation] == :required ->
        "Enter the email address to use."

      String.contains?(msg, "already been taken") ->
        "That address already belongs to another account."

      true ->
        "Enter a valid email address."
    end
  end

  defp summary_message(:password, msg, opts) do
    cond do
      opts[:validation] == :length ->
        "Use between 12 and 72 characters for the new password."

      opts[:validation] == :required ->
        "Enter a new password."

      true ->
        translate_error({msg, opts})
    end
  end

  defp summary_message(:password_confirmation, msg, opts) do
    cond do
      opts[:validation] == :confirmation ->
        "The two new passwords don't match."

      opts[:validation] == :required ->
        "Retype the new password so we can compare them."

      true ->
        translate_error({msg, opts})
    end
  end

  defp summary_message(_field, msg, opts), do: error_text(msg, opts, nil)

  # Fall back to the shared translation, and only to a bare trimmed message if
  # that yields nothing, so an unmapped error is never dropped from the summary.
  defp error_text(msg, opts, preferred) do
    translated = GtfsPlannerWeb.CoreComponents.translate_error({msg, opts})

    cond do
      preferred != nil -> preferred
      is_binary(translated) and translated != "" -> translated
      true -> msg
    end
  end

  defp email_failures(changeset), do: failures_for(changeset, @email_failure_targets)
  defp password_failures(changeset), do: failures_for(changeset, @password_failure_targets)

  ## Confirmation-mismatch placement

  # `validate_confirmation/3` attaches "does not match" to `:password`, so the
  # red border lands on "New password" while the reader is typing in "Confirm
  # new password" — the one field they are not editing. Move just that error to
  # the confirmation field. Accounts is untouched: the changeset it is handed,
  # its params, and every other error are passed through unchanged.
  defp move_confirmation_mismatch(%Ecto.Changeset{} = changeset) do
    {moved, kept} =
      Enum.split_with(changeset.errors, fn {field, {_msg, opts}} ->
        field == :password and Keyword.get(opts, :validation) == :confirmation
      end)

    case moved do
      [] ->
        changeset

      errors ->
        moved_to_confirmation =
          Enum.map(errors, fn {_field, error} -> {:password_confirmation, error} end)

        %{changeset | errors: kept ++ moved_to_confirmation}
    end
  end

  defp password_form_mismatch?(%{errors: errors}) do
    Enum.any?(errors, fn {field, {_msg, opts}} ->
      field == :password_confirmation and Keyword.get(opts, :validation) == :confirmation
    end)
  end

  ## Aside data

  # `memberships.roles` holds strings; `Roles.get/1` takes either. The fallback
  # matches `AdminLive.Components.role_label/1`, so a role with no metadata
  # still renders as something rather than dropping out of the list.
  defp role_details(roles) do
    Enum.map(roles, fn role ->
      case Roles.get(role) do
        %{name: name, description: description} -> %{name: name, description: description}
        nil -> %{name: to_string(role), description: nil}
      end
    end)
  end

  # Built by hand rather than through `Calendar.strftime/3`, whose `%-d` is
  # platform-dependent. The house format is "Mar 3, 2025". Matches on the
  # fields rather than the struct type so it serves both `inserted_at`
  # (`:utc_datetime_usec`) and `confirmed_at` (`:naive_datetime`).
  defp format_date(nil), do: nil

  defp format_date(%{year: year, month: month, day: day}) do
    "#{Enum.at(@months, month - 1)} #{day}, #{year}"
  end

  ## Existing helpers

  # Secrets must not be echoed back into the rendered HTML, so the password
  # values are removed before the changeset becomes a form. Two things are
  # neutralised, and both are load-bearing:
  #
  #   * `changes` — `Phoenix.HTML.FormData.Ecto.Changeset.input_value/3` reads
  #     the field value from `changes` first, so dropping the keys is what
  #     keeps the value out of the `value` attribute.
  #   * `params` — the keys are *blanked, not removed*. `Phoenix.Component.
  #     used_input?/1` treats an absent param as an unused field
  #     (`used_param?/2` falls through to `false` for a missing key), and
  #     `<.input field={...}/>` skips `field.errors` entirely for an unused
  #     field. Dropping the keys therefore made every secret field's errors
  #     invisible: a rejected password change reported its errors in no field at
  #     all, and the summary had nothing consistent to point at. Keeping the key
  #     with an empty value keeps the field "used" while still echoing nothing.
  defp sanitize_changeset_secrets(changeset) do
    secret_string_keys = ["current_password", "password", "password_confirmation"]
    secret_atom_keys = [:current_password, :password, :password_confirmation]

    params =
      changeset.params
      |> blank_secret_params(secret_string_keys)
      |> blank_nested_secret_params(secret_string_keys)

    changes =
      changeset.changes
      |> Map.drop(secret_atom_keys)

    %{changeset | params: params, changes: changes}
  end

  defp blank_secret_params(params, secret_keys) do
    Enum.reduce(secret_keys, params, fn key, acc ->
      case acc do
        %{^key => value} when is_binary(value) -> Map.replace!(acc, key, "")
        %{} -> acc
      end
    end)
  end

  # `password_changeset/2` and `email_changeset/2` are given the inner `user`
  # params, so `changeset.params` is normally flat. Nested form params are
  # handled too, because a change that worked flat must not start leaking a
  # secret if the shape is ever nested.
  defp blank_nested_secret_params(params, secret_keys) do
    Enum.reduce(params, params, fn
      {"user", nested}, acc when is_map(nested) ->
        Map.put(acc, "user", blank_secret_params(nested, secret_keys))

      _pair, acc ->
        acc
    end)
  end

  # The same error appears twice on a rejected submit: once in the summary and
  # once under the field. Both have to read the same, so both go through
  # `summary_message/3` — otherwise the field says "is invalid" while the summary
  # two lines above says "Your current password is not correct."
  #
  # `current_password` is not a cast field on either changeset, so it has no
  # `@form[:current_password]` to read errors from. The form's own `errors` list
  # still carries it, because that list is the changeset's error keyword list.
  defp email_password_errors(form), do: curated_errors(form, :current_password)
  defp password_password_errors(form), do: curated_errors(form, :current_password)

  # Read the form rather than the changeset directly: `to_form/2` empties the
  # error list when the changeset's action is `nil`, and that guard is what keeps
  # a freshly mounted password form from showing "can't be blank" for fields the
  # reader has not touched. Reading `changeset.errors` bypasses it.
  defp curated_errors(form, field) do
    for {f, {msg, opts}} <- form_errors(form), f == field, do: summary_message(f, msg, opts)
  end

  defp form_errors(%Phoenix.HTML.Form{errors: errors}) when is_list(errors), do: errors
  defp form_errors(_form), do: []
end
