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

  alias GtfsPlanner.Authorization.Roles

  @doc """
  Returns the stable DOM ID for one member row.

  Parents must configure their member stream with this function
  (`stream(:members, members, dom_id: &Admin.Components.member_dom_id/1)`) so the
  IDs LiveView uses for stream inserts and deletes are the same IDs this
  component renders and tests select.
  """
  def member_dom_id(%{user: %{id: user_id}}), do: "member-#{user_id}"

  @doc """
  Renders the shared organization-member data view.

  `members` accepts either a `Phoenix.LiveView.LiveStream` or a plain list of
  members in the `GtfsPlanner.Organizations.AdminReadAdapter.member/0` shape. A
  LiveStream is not enumerable, so emptiness arrives as the separate `empty?`
  flag the parent already tracks.

  Status follows one precedence: deactivated, then invitation pending, then
  active. Roles are categories, so they render as neutral chips rather than
  coloured state badges.

  ## Examples

      <.member_data_view
        id="members"
        members={@streams.members}
        empty?={@members_empty?}
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

  attr :invite_path, :string,
    default: nil,
    doc: "the route-appropriate invite path; omitted renders no empty-state CTA"

  attr :empty_title, :string, default: "No members yet"

  attr :empty_description, :string,
    default: "Members appear here after you invite someone to this organization."

  attr :invite_label, :string, default: "Invite member"

  attr :resend_event, :string, required: true, doc: "parent event name for Resend invite"
  attr :activate_event, :string, required: true, doc: "parent event name for Activate user"
  attr :deactivate_event, :string, required: true, doc: "parent event name for Deactivate user"

  def member_data_view(assigns) do
    ~H"""
    <.empty_state :if={@empty?} id={"#{@id}-empty"} title={@empty_title}>
      {@empty_description}
      <:action :if={@invite_path}>
        <.button class="min-h-11" navigate={@invite_path}>{@invite_label}</.button>
      </:action>
    </.empty_state>

    <div :if={!@empty?} class="rounded-box border border-base-300 bg-base-100 overflow-hidden">
      <.table
        id={@id}
        rows={@members}
        responsive="stack"
        row_id={&member_dom_id(row_member(&1))}
        row_item={&row_member/1}
      >
        <:col :let={member} label="Email">{member.user.email}</:col>
        <:col :let={member} label="Roles">
          <span class="flex flex-wrap gap-1">
            <span
              :for={role <- member.roles}
              data-role="member-role"
              class="rounded-selector inline-flex items-center border border-base-300 px-2 py-0.5 text-sm"
            >
              {role_label(role)}
            </span>
            <span :if={member.roles == []} class="text-sm text-base-content/70">No roles</span>
          </span>
        </:col>
        <:col :let={member} label="Status">
          <.status_badge data-role="member-status" status={member_status(member)} />
        </:col>

        <:action :let={member}>
          <.button
            :if={member_status(member) == :invitation_pending}
            id={"resend-invite-#{member.user.id}"}
            variant="quiet"
            size="sm"
            class="min-h-11"
            phx-click={@resend_event}
            phx-value-user-id={member.user.id}
            phx-disable-with="Resending invite…"
            aria-label={"Resend invite to #{member.user.email}"}
          >
            Resend invite
          </.button>
        </:action>

        <:action :let={member}>
          <.button
            :if={member_status(member) == :deactivated}
            id={"activate-user-#{member.user.id}"}
            variant="quiet"
            size="sm"
            class="min-h-11"
            phx-click={@activate_event}
            phx-value-user-id={member.user.id}
            phx-disable-with="Activating user…"
            aria-label={"Activate #{member.user.email}"}
          >
            Activate user
          </.button>
          <.button
            :if={member_status(member) != :deactivated}
            id={"deactivate-user-#{member.user.id}"}
            variant="quiet"
            size="sm"
            class="min-h-11"
            phx-click={@deactivate_event}
            phx-value-user-id={member.user.id}
            phx-disable-with="Deactivating user…"
            aria-label={"Deactivate #{member.user.email}"}
          >
            Deactivate user
          </.button>
        </:action>
      </.table>
    </div>
    """
  end

  @doc """
  Resolves one membership status with a fixed precedence.

  Deactivated wins over invitation pending, which wins over active. A revoked
  member is reported as revoked even while their invitation is unaccepted.

  An invitation is pending exactly while the invited account still has no
  password. `GtfsPlanner.Accounts.invite_member/4` creates the user through
  `User.invite_changeset/2`, which sets no password, and
  `Accounts.accept_invite_set_password/2` is the only transition that sets one.
  `Accounts.resend_user_invite/2` uses the same signal and answers
  `{:error, :already_accepted}` once a password exists, so deriving the badge
  from `hashed_password` keeps the rendered status and the offered recovery
  action in agreement.
  """
  def member_status(%{deactivated_at: deactivated_at}) when not is_nil(deactivated_at),
    do: :deactivated

  def member_status(%{user: %{hashed_password: nil}}), do: :invitation_pending
  def member_status(_member), do: :active

  # A LiveStream yields {dom_id, item}; a plain list yields the item itself.
  defp row_member({_dom_id, member}), do: member
  defp row_member(member), do: member

  defp role_label(role) do
    case Roles.get(role) do
      %{name: name} -> name
      nil -> to_string(role)
    end
  end
end
