defmodule GtfsPlannerWeb.Admin.Components do
  @moduledoc """
  Presentation components shared by the administration LiveViews.

  `member_data_view/1` is the single owner of organization-member presentation.
  Both `GtfsPlannerWeb.Admin.UsersLive` and `GtfsPlannerWeb.Admin.OrganizationsLive`
  render their member collection through it so one table, one status vocabulary,
  one role treatment, and one set of row/action IDs exist across both surfaces.

  It is a function component, never a LiveComponent. It queries no context, owns
  no mutation or pending state, and keeps no duplicate collection: the parent
  owns the stream, the empty flag, the route, the feedback, and every event
  handler. The component only emits the parent's event names with the selected
  user's ID as the sole event value.
  """
  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents,
    only: [choice_cards: 1, drawer_footer: 1, first_use: 1, form_error_summary: 1, message: 1]

  alias GtfsPlanner.Accounts.InviteForm
  alias GtfsPlanner.Authorization.Roles
  alias GtfsPlannerWeb.CoreComponents

  # What each organization role lets a person do, in the words an administrator
  # chooses by. Editor comes first because most invitees are editors. The
  # administrator role does not include feed data: `require_gtfs_access` needs the
  # editor role, so someone who does both work holds both roles.
  @access_summaries [
    {"pathways_studio_editor",
     "Edits routes, calendars, stops and stations, and runs GTFS imports and exports."},
    {"pathways_studio_admin",
     "Invites and deactivates users, and edits organization settings. Does not include editing feed data."}
  ]

  @doc """
  Returns the stable DOM ID for one member row.

  Parents must configure their member stream with this function
  (`stream(:members, members, dom_id: &Admin.Components.member_dom_id/1)`) so the
  IDs LiveView uses for stream inserts and deletes are the same IDs this
  component renders and tests select.
  """
  def member_dom_id(%{user: %{id: user_id}}), do: "member-#{user_id}"

  @doc """
  The organization roles an invitation can grant, each with a one-sentence
  summary of what it allows. Labels come from `InviteForm.available_roles/0`, so
  the table, the legend and the invitation form name a role the same way.
  """
  @spec access_levels() :: [%{value: String.t(), label: String.t(), description: String.t()}]
  def access_levels do
    labels = Map.new(InviteForm.available_roles(), fn {label, value} -> {value, label} end)

    for {value, description} <- @access_summaries, label = labels[value] do
      %{value: value, label: label, description: description}
    end
  end

  @doc """
  Counts members by status, for the one-line summary above the rows.

  Uses `member_status/1`, so a count and the badge on each row cannot disagree.
  """
  @spec count_members([map()]) :: %{
          total: non_neg_integer(),
          active: non_neg_integer(),
          invitation_pending: non_neg_integer(),
          deactivated: non_neg_integer()
        }
  def count_members(members) do
    by_status = Enum.frequencies_by(members, &member_status/1)

    %{
      total: length(members),
      active: Map.get(by_status, :active, 0),
      invitation_pending: Map.get(by_status, :invitation_pending, 0),
      deactivated: Map.get(by_status, :deactivated, 0)
    }
  end

  @doc """
  Renders the shared organization-member data view.

  `members` accepts either a `Phoenix.LiveView.LiveStream` or a plain list of
  members in the `GtfsPlanner.Organizations.AdminReadAdapter.member/0` shape. A
  LiveStream is not enumerable, so emptiness arrives as the separate `empty?`
  flag the parent already tracks, and the one-line summary as `counts`.

  Status follows one precedence: deactivated, then invitation pending, then
  active. Roles are categories, so they render as neutral chips rather than
  coloured state badges. The card ends with a legend of what each role allows,
  next to the column that uses it.

  A `LiveStream` item only re-renders when it is inserted again, so the parent
  resets the stream whenever `marked_id` changes.

  ## Examples

      <.member_data_view
        id="members"
        members={@streams.members}
        empty?={@members_empty?}
        counts={@member_counts}
        invite_path={~p"/admin/users/invite"}
        resend_event="resend_invite"
        activate_event="activate_user"
        deactivate_event="request_deactivation"
      />
  """
  attr :id, :string, required: true

  attr :members, :any,
    required: true,
    doc: "the member LiveStream, or a plain member list for static rendering"

  attr :empty?, :boolean,
    required: true,
    doc: "the parent-owned empty flag; a LiveStream cannot be enumerated"

  attr :counts, :map,
    default: nil,
    doc: "`count_members/1` of the loaded members; omitted renders no summary line"

  attr :marked_id, :string,
    default: nil,
    doc: "the user ID whose row an outcome message is about; that row is tinted"

  attr :first_use?, :boolean,
    default: false,
    doc: "the list holds only the viewer: show the panel that says who to invite next"

  attr :noun, :string, default: "user", doc: "what the summary and table call a member"

  attr :invite_path, :string,
    default: nil,
    doc: "the route-appropriate invite path; omitted renders no empty-state CTA"

  attr :empty_title, :string, default: "No members yet"
  attr :empty_icon, :string, default: nil, doc: "a hero icon name shown above the empty title"

  attr :empty_description, :string,
    default: "Members appear here after you invite someone to this organization."

  attr :invite_label, :string, default: "Invite member"

  attr :resend_event, :string, required: true, doc: "parent event name for Resend invite"
  attr :activate_event, :string, required: true, doc: "parent event name for Activate user"
  attr :deactivate_event, :string, required: true, doc: "parent event name for Deactivate user"

  def member_data_view(assigns) do
    assigns = assign(assigns, :access_levels, access_levels())

    ~H"""
    <.first_use :if={@empty?} id={"#{@id}-empty"} title={@empty_title} icon={@empty_icon}>
      {@empty_description}
      <:action :if={@invite_path}>
        <.button class="min-h-11" navigate={@invite_path}>
          <.icon name="hero-plus" class="size-4" /> {@invite_label}
        </.button>
      </:action>
    </.first_use>

    <section
      :if={!@empty?}
      id={"#{@id}-workbench"}
      aria-label={String.capitalize(@noun) <> "s"}
      class="overflow-clip rounded-card border border-subtle bg-white"
    >
      <div
        :if={@counts}
        id={"#{@id}-summary"}
        class="flex min-h-[52px] flex-wrap items-center gap-x-4 gap-y-0.5 border-b border-subtle px-4 py-2 md:px-5"
      >
        <p id={"#{@id}-count"} role="status" class="text-base font-bold tabular-nums text-strong">
          {count_label(@counts.total, @noun)}
        </p>
        <p
          :if={@counts.active != @counts.total}
          class="text-[13px] tabular-nums text-muted"
        >
          {breakdown(@counts)}
        </p>
      </div>

      <div id={"#{@id}-container"}>
        <table class="member-table ds-stack-table w-full border-collapse text-left text-sm">
          <caption class="sr-only">
            {String.capitalize(@noun) <> "s"} in this organization, ordered by email
          </caption>
          <thead>
            <tr>
              <th scope="col" class={[table_head_class(), "pl-5 pr-4"]}>
                {String.capitalize(@noun)}
              </th>
              <th scope="col" class={[table_head_class(), "w-[230px] px-4"]}>Access</th>
              <th scope="col" class={[table_head_class(), "w-[190px] px-4"]}>Status</th>
              <th scope="col" class={[table_head_class(), "w-[300px] pl-4 pr-5 text-right"]}>
                <span class="sr-only">Actions</span>
              </th>
            </tr>
          </thead>
          <tbody id={@id} phx-update={is_struct(@members, Phoenix.LiveView.LiveStream) && "stream"}>
            <.member_row
              :for={row <- @members}
              id={row_id(row)}
              member={row_member(row)}
              label={String.capitalize(@noun)}
              marked?={row_member(row).user.id == @marked_id}
              resend_event={@resend_event}
              activate_event={@activate_event}
              deactivate_event={@deactivate_event}
            />
          </tbody>
        </table>
      </div>

      <div
        :if={@first_use? and @invite_path}
        id={"#{@id}-first-use"}
        class="border-t border-subtle px-5 py-6"
      >
        <div class="max-w-[560px]">
          <h2 class="text-base font-bold text-strong">You are the only {@noun} so far</h2>
          <p class="mt-1 text-sm text-muted">
            Invite the people who will work in this organization, and choose what each of them can do.
          </p>
          <.button id="first-use-invite" class="mt-4 min-h-11" patch={@invite_path}>
            <.icon name="hero-plus" class="size-4" /> {@invite_label}
          </.button>
        </div>
      </div>

      <div
        id={"#{@id}-legend"}
        class="border-t border-subtle bg-canvas px-4 py-4 md:px-5"
      >
        <h3 class="text-[13px] font-bold text-strong">What each access level allows</h3>
        <dl class="mt-2 grid gap-x-8 gap-y-3 text-[13px] leading-snug md:grid-cols-2">
          <div :for={level <- @access_levels}>
            <dt class="font-[650] text-strong">{level.label}</dt>
            <dd class="mt-0.5 text-default">{level.description}</dd>
          </div>
        </dl>
        <p class="mt-3 text-[13px] text-default">
          Choose both for someone who edits feed data and manages users.
        </p>
      </div>
    </section>
    """
  end

  @doc "The classes of a column heading in an administration table."
  def table_head_class,
    do: "border-b border-subtle bg-canvas py-0 text-[13px] font-[650] leading-[44px] text-default"

  attr :id, :string, required: true
  attr :member, :map, required: true
  attr :label, :string, required: true, doc: "the identity column's heading"
  attr :marked?, :boolean, required: true
  attr :resend_event, :string, required: true
  attr :activate_event, :string, required: true
  attr :deactivate_event, :string, required: true

  defp member_row(assigns) do
    assigns = assign(assigns, :status, member_status(assigns.member))

    ~H"""
    <tr
      id={@id}
      data-marked={@marked? || nil}
      class={[
        "border-b border-subtle last:border-b-0",
        if(@marked?, do: "bg-soft", else: "hover:bg-canvas")
      ]}
    >
      <td data-label={@label} class="py-3 pl-5 pr-4 align-middle">
        <span class="font-semibold text-strong [overflow-wrap:anywhere]">
          {@member.user.email}
        </span>
      </td>
      <td data-label="Access" class="px-4 py-3 align-middle">
        <span class="flex flex-wrap gap-1.5">
          <span
            :for={role <- @member.roles}
            data-role="member-role"
            class="inline-flex min-h-6 items-center rounded-badge border border-subtle bg-white px-2 text-[13px] font-semibold text-default"
          >
            {role_label(role)}
          </span>
          <span :if={@member.roles == []} class="text-sm text-muted">No roles</span>
        </span>
      </td>
      <td data-label="Status" class="px-4 py-3 align-middle">
        <.member_status_badge status={@status} />
      </td>
      <td data-label="Actions" class="py-1.5 pl-4 pr-3 align-middle">
        <div class="flex flex-wrap items-center justify-end gap-1 lg:flex-nowrap">
          <.button
            :if={@status == :invitation_pending}
            id={"resend-invite-#{@member.user.id}"}
            variant="secondary"
            class="min-h-11 px-3"
            phx-click={@resend_event}
            phx-value-user-id={@member.user.id}
            phx-disable-with="Resending invite…"
            aria-label={"Resend invite to #{@member.user.email}"}
          >
            Resend invite
          </.button>
          <.button
            :if={@status == :deactivated}
            id={"activate-user-#{@member.user.id}"}
            variant="secondary"
            class="min-h-11 px-3"
            phx-click={@activate_event}
            phx-value-user-id={@member.user.id}
            phx-disable-with="Activating user…"
            aria-label={"Activate #{@member.user.email}"}
          >
            Activate user
          </.button>
          <.button
            :if={@status != :deactivated and "administrator" not in @member.roles}
            id={"deactivate-user-#{@member.user.id}"}
            variant="quiet"
            class="min-h-11 px-3"
            phx-click={@deactivate_event}
            phx-value-user-id={@member.user.id}
            phx-disable-with="Deactivating user…"
            aria-label={"Deactivate #{@member.user.email}"}
          >
            Deactivate user
          </.button>
        </div>
      </td>
    </tr>
    """
  end

  # Green is Active and nothing else. A deactivated member is neutral, not an error:
  # the account is kept, and Activate user reverses it.
  @status_badges %{
    active: {"Active", "bg-success-bg text-success-fg", "bg-success-line"},
    invitation_pending:
      {"Invitation pending", "bg-warning-bg text-warning-fg", "bg-warning-line"},
    deactivated:
      {"Deactivated", "bg-canvas text-muted ring-1 ring-inset ring-subtle", "bg-control"}
  }

  attr :status, :atom, required: true, values: [:active, :invitation_pending, :deactivated]

  defp member_status_badge(assigns) do
    {word, tone, dot} = Map.fetch!(@status_badges, assigns.status)
    assigns = assign(assigns, word: word, tone: tone, dot: dot)

    ~H"""
    <span
      data-role="member-status"
      class={[
        "inline-flex items-center gap-1.5 whitespace-nowrap rounded-badge px-2 py-0.5 text-[13px] font-semibold",
        @tone
      ]}
    >
      <span class={["size-2 shrink-0 rounded-full", @dot]} aria-hidden="true"></span>{@word}
    </span>
    """
  end

  defp count_label(1, noun), do: "1 #{noun}"
  defp count_label(count, noun), do: "#{count} #{noun}s"

  # "3 active · 2 invitations pending · 1 deactivated", leaving out empty parts.
  defp breakdown(counts) do
    [
      counts.active > 0 && "#{counts.active} active",
      counts.invitation_pending > 0 &&
        "#{counts.invitation_pending} #{pluralize(counts.invitation_pending, "invitation")} pending",
      counts.deactivated > 0 && "#{counts.deactivated} deactivated"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"

  @doc """
  Resolves one membership status with a fixed precedence.

  Deactivated wins over invitation pending, which wins over active. A revoked
  member is reported as revoked even while their invitation is unaccepted.

  An invitation is pending exactly while the invited account still has no
  password. `GtfsPlanner.Accounts.invite_member/4` creates the user through
  `User.invite_changeset/2`, which sets no password, and
  `Accounts.accept_invite_set_password/2` is the only transition that sets one.
  `Accounts.resend_user_invite/4` uses the same signal and answers
  `{:error, :already_accepted}` once a password exists, so deriving the badge
  from `hashed_password` keeps the rendered status and the offered recovery
  action in agreement.
  """
  def member_status(%{deactivated_at: deactivated_at}) when not is_nil(deactivated_at),
    do: :deactivated

  def member_status(%{user: %{hashed_password: nil}}), do: :invitation_pending
  def member_status(_member), do: :active

  @doc """
  Explains why `GtfsPlanner.Organizations.deactivate_user_in_organization/3`
  refused or failed, for the member action feedback.
  """
  def deactivation_error(:system_administrator, email),
    do: "#{email} is a system administrator and can't be deactivated here."

  def deactivation_error(:last_organization_admin, email),
    do:
      "#{email} is the only administrator of this organization. " <>
        "Add another administrator before deactivating them."

  def deactivation_error(_reason, email), do: "#{email} could not be deactivated."

  # A LiveStream yields {dom_id, item}; a plain list yields the item itself.
  defp row_member({_dom_id, member}), do: member
  defp row_member(member), do: member

  defp row_id({dom_id, _member}), do: dom_id
  defp row_id(member), do: member_dom_id(member)

  defp role_label(role) do
    case Roles.get(role) do
      %{name: name} -> name
      nil -> to_string(role)
    end
  end

  # ---------------------------------------------------------------------------
  # Invitation drawer and deactivation dialog
  #
  # Organization-admin users and system-admin organization detail invite and
  # deactivate through the same drawer and dialog. The parent owns the events,
  # the form assigns (`GtfsPlannerWeb.Admin.InviteFormState`) and the routes.
  # ---------------------------------------------------------------------------

  @doc """
  The invitation form for the planner-chrome drawer: an email, the access-level
  cards, and a persistent footer with Cancel and Send invite.

  Expects the assigns `GtfsPlannerWeb.Admin.InviteFormState.assign_invite_form/2`
  sets, and the parent's `validate_invite` and `send_invite` events.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :email_errors, :list, required: true
  attr :roles_error, :string, default: nil
  attr :base_error, :string, default: nil
  attr :failures, :list, required: true
  attr :cancel_path, :string, required: true, doc: "where Cancel patches back to"

  def invite_form(assigns) do
    assigns =
      assigns
      |> assign(:selected_roles, assigns.form[:roles].value || [])
      |> assign(:access_levels, access_levels())

    ~H"""
    <.form
      for={@form}
      id="invite-form"
      novalidate
      phx-change="validate_invite"
      phx-submit="send_invite"
      class="flex min-h-0 flex-1 flex-col"
    >
      <div class="grid flex-1 content-start gap-5 overflow-y-auto px-5 py-5 sm:px-6">
        <.message
          :if={@base_error}
          id="invite-service-error"
          tabindex="-1"
          kind="error"
          title={@base_error}
        >
          Nothing was saved. Correct the details or try again.
        </.message>

        <.form_error_summary
          id="invite-error-summary"
          title="Invitation not sent. Fix these fields:"
          failures={@failures}
          class=""
        />

        <.input
          field={@form[:email]}
          id="invite-email"
          type="email"
          label="Email address"
          help="If this address already has an account, that person is added right away."
          autocomplete="off"
          spellcheck="false"
          errors={@email_errors}
          required
        />

        <.choice_cards
          id="invite-roles"
          name="invite[roles][]"
          label="Access level"
          help="Choose at least one. Choose both for someone who edits feed data and manages users."
          options={@access_levels}
          selected={@selected_roles}
          error={@roles_error}
        />
      </div>

      <.drawer_footer>
        <.button variant="secondary" class="min-h-11" patch={@cancel_path}>Cancel</.button>
        <.button type="submit" class="min-h-11 min-w-[132px]" phx-disable-with="Sending invite…">
          Send invite
        </.button>
      </.drawer_footer>
    </.form>
    """
  end

  @doc "The deactivation dialog's title: names the person, or the action while none is chosen."
  def deactivation_title(nil), do: "Deactivate user"
  def deactivation_title(%{user: user}), do: "Deactivate #{user.email}?"

  @doc """
  The deactivation dialog's body: the consequence for this person in this
  organization. Someone who has not accepted yet has no password and so no
  session to end, so the dialog does not claim one.
  """
  def deactivation_body(%{user: %{hashed_password: nil} = user}, organization) do
    "#{user.email} has not accepted their invitation yet. Deactivating keeps them on this list without access to #{organization.name}. You can activate them again from this list."
  end

  def deactivation_body(%{user: user}, organization) do
    "#{user.email} loses access to #{organization.name} and is signed out of every web and mobile session immediately. The account is kept and can be activated again from this list."
  end

  @doc """
  One sentence for a failed organization field, chosen by the rule that failed so
  it says what to enter instead of repeating the changeset's wording. An alias
  that collides with another organization's is only known on save.
  """
  def organization_error_message(field, {_message, opts} = error) do
    case {field, opts[:validation], opts[:kind], opts[:constraint]} do
      {:name, :required, _kind, _constraint} ->
        "Enter an organization name."

      {:alias, :required, _kind, _constraint} ->
        "Enter an alias using letters, numbers or hyphens."

      {_field, :length, :max, _constraint} ->
        "Use #{opts[:count]} characters or fewer."

      {:alias, _validation, _kind, :unique} ->
        "Another organization already uses this alias. Choose a different one."

      _other ->
        CoreComponents.translate_error(error)
    end
  end
end
