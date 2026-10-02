defmodule GtfsPlannerWeb.Home.AccessComponents do
  @moduledoc """
  The homepage states that come before the work: system administration, an
  account without an organization, an organization without a published version,
  a member without an editing role, and an organization administrator without an
  editing role.

  Each component renders one state's root id — the page's state contract — and
  the page head, so every state has exactly one `h1` and at most one primary
  action. Data arrives as attrs from `DashboardLive`, which reads it through
  `home_source/0`; this module never loads or writes.

  Copy and composition come from
  `.specs/26-homepage/references/planner-home-next-step.html` (states `sysadmin`,
  `noorg`, `noversion`, `notask`, `admin`). The two role states that depend on an
  organization administrator are product-independent, so `no_version/1` and
  `no_task/1` keep the Planner wording for both products; `admin_only/1` uses
  the Pathways Studio wording when the organization runs that product
  (`.specs/26-homepage/references/pathways-home-next-step.html`, state `admin`).
  """
  use Phoenix.Component
  use GtfsPlannerWeb, :verified_routes

  import GtfsPlannerWeb.CoreComponents, only: [icon: 1]
  import GtfsPlannerWeb.Home.SharedComponents, only: [home_head: 1]

  alias GtfsPlanner.Wording

  # The reference's three control shapes: the state's single primary action, a
  # bordered secondary action, and an inline text action beside a primary.
  defp primary_link do
    "inline-flex min-h-11 items-center justify-center gap-2 rounded-control bg-action px-4 py-2.5 text-sm font-[650] text-white no-underline hover:bg-action-hover"
  end

  defp secondary_link do
    "mt-5 inline-flex min-h-11 items-center justify-center gap-2 rounded-control border border-control bg-white px-4 py-2.5 text-sm font-[650] text-strong no-underline hover:bg-canvas"
  end

  defp text_link do
    "inline-flex min-h-11 items-center gap-1.5 text-sm font-bold text-action no-underline hover:underline"
  end

  @doc """
  System administrator: the organizations dataset, not a member organization.
  """
  attr :organization_count, :integer, required: true

  def sysadmin(assigns) do
    ~H"""
    <div id="dashboard-system-administrator">
      <.home_head
        title="System administration"
        lede={Wording.count_noun(@organization_count, "organization")}
      />
      <section
        id="system-admin"
        aria-labelledby="system-admin-title"
        class="max-w-[760px] rounded-card border border-subtle bg-white p-6 sm:p-8"
      >
        <span class="grid size-11 place-items-center rounded-control bg-soft text-cyan-700">
          <.icon name="hero-building-office-2" class="size-[22px]" />
        </span>
        <h2
          id="system-admin-title"
          class="mt-4 text-[17px] font-bold leading-snug tracking-[-0.01em] text-strong"
        >
          Organizations
        </h2>
        <p class="mt-1 max-w-[60ch] text-sm text-default">
          Create an organization for each agency, set whether it uses GTFS Planner or Pathways Studio, and invite its first administrator.
        </p>
        <div class="mt-5 flex flex-wrap items-center gap-x-5 gap-y-2">
          <a href={~p"/admin/organizations"} class={primary_link()}>Manage organizations</a>
          <a href={~p"/admin/organizations/new"} class={text_link()}>Create organization</a>
        </div>
      </section>
    </div>
    """
  end

  @doc """
  No organization: `:missing` has no organization in the session, and
  `:unavailable` names one that is gone or belongs to somebody else.

  Both render the same copy and never the organization's name, its members'
  emails, or any link into tenant data (AC-2); only the root id differs.
  """
  attr :state, :atom, required: true, values: [:missing, :unavailable]

  def no_org(assigns) do
    ~H"""
    <div id={no_org_root(@state)}>
      <.home_head title="Home" />
      <section class="max-w-[760px]">
        <div class="flex gap-3 rounded-card border border-info-line bg-info-bg px-5 py-5 text-info-fg">
          <.icon name="hero-information-circle" class="mt-0.5 size-5 shrink-0" />
          <div>
            <h2 class="text-base font-bold leading-snug text-info-fg">
              Your account is not part of an organization yet
            </h2>
            <p class="mt-1 text-sm">
              Ask the person who invited you to add this account to their organization. If you were expecting a different account, log out and sign in again.
            </p>
          </div>
        </div>
        <.link href={~p"/users/log_out"} method="delete" class={secondary_link()}>Log out</.link>
      </section>
    </div>
    """
  end

  @doc """
  No published version: the organization exists but has no version to work in.
  """
  attr :organization, :map, required: true
  attr :admins, :list, required: true, doc: "the organization's active administrator emails"

  def no_version(assigns) do
    ~H"""
    <div id="dashboard-no-version">
      <.home_head title={@organization.name} />
      <section class="max-w-[760px]">
        <div class="flex gap-3 rounded-card border border-warning-line bg-warning-bg px-5 py-5 text-warning-fg">
          <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0" />
          <div>
            <h2 class="text-base font-bold leading-snug text-warning-fg">
              There is no service data to work on yet
            </h2>
            <p class="mt-1 text-sm">
              Routes, calendars and stops open once {@organization.name} has a version. An organization administrator can import a feed or create one.
            </p>
          </div>
        </div>
        <.admins_list admins={@admins} />
      </section>
    </div>
    """
  end

  @doc """
  No task access: a member of the organization with no editing role yet.
  """
  attr :organization, :map, required: true
  attr :admins, :list, required: true, doc: "the organization's active administrator emails"

  def no_task(assigns) do
    ~H"""
    <div id="dashboard-no-task-access">
      <.home_head title={@organization.name} />
      <section class="max-w-[760px]">
        <div class="flex gap-3 rounded-card border border-info-line bg-info-bg px-5 py-5 text-info-fg">
          <.icon name="hero-information-circle" class="mt-0.5 size-5 shrink-0" />
          <div>
            <h2 class="text-base font-bold leading-snug text-info-fg">
              Your account is in {@organization.name} but cannot edit yet
            </h2>
            <p class="mt-1 text-sm">
              Ask an organization administrator for the Editor role to work on routes, calendars and stops.
            </p>
          </div>
        </div>
        <.admins_list admins={@admins} />
      </section>
    </div>
    """
  end

  @doc """
  Organization administrator without an editing role: people are the task.
  """
  attr :organization, :map, required: true
  attr :product, :atom, required: true, values: [:planner, :pathways]
  attr :member_count, :integer, required: true, doc: "the organization's active members"

  def admin_only(assigns) do
    assigns = assign(assigns, editor_note: editor_note(assigns.product))

    ~H"""
    <div id="home-admin-only">
      <.home_head title={@organization.name} />
      <section class="max-w-[760px]">
        <div class="rounded-card border border-subtle bg-white p-6 sm:p-8">
          <span class="grid size-11 place-items-center rounded-control bg-soft text-cyan-700">
            <.icon name="hero-user-group" class="size-[22px]" />
          </span>
          <h2 class="mt-4 text-[17px] font-bold leading-snug tracking-[-0.01em] text-strong">
            People at {@organization.name}
          </h2>
          <p class="mt-1 max-w-[60ch] text-sm text-default">
            Invite colleagues, give them the Editor role so they can {role_task(@product)}, and remove access for people who have moved on. {member_count_text(
              @member_count
            )}
          </p>
          <div class="mt-5 flex flex-wrap items-center gap-x-5 gap-y-2">
            <a href={~p"/admin/users"} class={primary_link()}>Manage users</a>
            <a href={~p"/admin/users/organization-settings"} class={text_link()}>
              Organization settings
            </a>
          </div>
        </div>
        <div class="mt-4 flex gap-3 rounded-card bg-white px-5 py-4 text-sm text-default">
          <.icon name="hero-information-circle" class="mt-px size-5 shrink-0 text-muted" />
          <p>{@editor_note}</p>
        </div>
      </section>
    </div>
    """
  end

  @doc """
  Who can grant the Editor role: the organization's active administrators.

  The no-version and no-task states end here, because asking one of these people
  is their next step (AC-3, AC-4). A deactivated administrator is not listed;
  with no active administrator there is nobody to ask, so the list is absent.
  """
  attr :admins, :list, required: true, doc: "the organization's active administrator emails"

  def admins_list(assigns) do
    ~H"""
    <section
      :if={@admins != []}
      id="org-admins"
      aria-labelledby="org-admins-title"
      class="mt-6 max-w-[760px] rounded-card border border-subtle bg-white px-5 py-4"
    >
      <h2 id="org-admins-title" class="text-sm font-bold text-strong">
        Organization administrators
      </h2>
      <ul class="mt-1 flex flex-wrap gap-x-8">
        <li :for={email <- @admins}>
          <a
            href={"mailto:" <> email}
            class="inline-flex min-h-11 items-center text-sm font-semibold text-action no-underline hover:underline"
          >
            {email}
          </a>
        </li>
      </ul>
    </section>
    """
  end

  defp no_org_root(:missing), do: "dashboard-no-organization"
  defp no_org_root(:unavailable), do: "dashboard-organization-unavailable"

  defp member_count_text(1), do: "1 person has access today."
  defp member_count_text(count), do: "#{count} people have access today."

  defp role_task(:pathways), do: "map stations"
  defp role_task(:planner), do: "work on routes and stops"

  defp editor_note(:pathways),
    do: "Editing stations needs the Editor role. You can give it to yourself on the Users page."

  defp editor_note(:planner),
    do:
      "Editing routes, calendars and stops needs the Editor role. You can give it to yourself on the Users page."
end
