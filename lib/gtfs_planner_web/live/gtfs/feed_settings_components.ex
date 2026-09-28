defmodule GtfsPlannerWeb.Gtfs.FeedSettingsComponents do
  @moduledoc """
  Form controls shared by the Feed details and Agencies settings drawers.

  `language_select/1` renders a language choice as the repository's
  `.input type="select"`. The option groups come from
  `GtfsPlanner.Gtfs.LanguageCodes.options/1`, so the feed language adds `mul`,
  the agency and default languages do not, and a stored code the list omits
  keeps its own "Current value" entry instead of being silently replaced (R12).
  One control means the page and every drawer label a code the same way.

  The component carries no state: the caller supplies the form field, and the
  current value is read from it, so an imported code outside the list stays
  selected when the drawer opens.

  `unsaved_guard/1` renders the browser-level half of a drawer's dirty state: a
  hidden element whose `data-dirty` the caller owns, with a colocated
  `beforeunload` listener that asks the browser's own leave-page question while
  a draft is unsaved (AC-6). Server-side close protection stays with the page,
  which owns what "changed" means.

  `timezone_input/1` renders the schedule timezone field with the datalist of
  names PostgreSQL accepts, so the version timezone is chosen from one list in
  both the timezone drawer and the first-agency drawer.

  `agency_form_fields/1` renders the agency drawer's two sections — Agency
  identity and Rider contact — in the prototype's field order. It owns no
  events and no state, so the create drawer, the edit drawer and the onboarding
  drawer describe one agency the same way; only the version's first agency
  carries a timezone field, because every later agency takes the zone the
  version already holds (R2).
  """

  use GtfsPlannerWeb, :html

  alias GtfsPlanner.Gtfs.LanguageCodes

  @doc """
  Renders a language select for `field`.

  Pass `include_mul: true` for the feed language, the only field that accepts
  `mul`. `optional: true` moves the "(optional)" suffix into the visible label,
  which every caller would otherwise spell itself.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :include_mul, :boolean, default: false
  attr :optional, :boolean, default: false
  attr :help, :string, default: nil

  def language_select(assigns) do
    assigns =
      assigns
      |> assign(
        :options,
        LanguageCodes.options(include_mul: assigns.include_mul, current: assigns.field.value)
      )
      |> assign(:label, label_with_optional(assigns.label, assigns.optional))

    ~H"""
    <.input
      field={@field}
      type="select"
      label={@label}
      options={@options}
      prompt="Choose language"
      help={@help}
    />
    """
  end

  @doc """
  Renders the change-guard hook a drawer needs to protect an unsaved draft.

  The element is inert and invisible: it carries `id` only so the hook has a
  stable DOM node, and `dirty` so the page decides when a draft counts as
  changed. While `data-dirty` is "true" the hook answers `beforeunload` with
  `preventDefault()` and an empty `returnValue`, which is how Chromium, Firefox
  and Safari raise their own leave-page prompt; the listener is removed when the
  element goes away. Reachable back-button traversal is not guarded.
  """
  attr :id, :string, required: true
  attr :dirty, :boolean, required: true

  def unsaved_guard(assigns) do
    ~H"""
    <div id={@id} phx-hook=".UnsavedChangesGuard" data-dirty={to_string(@dirty)} hidden></div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".UnsavedChangesGuard">
      export default {
        mounted() {
          this.beforeUnload = (event) => {
            if (this.el.dataset.dirty !== "true") return
            event.preventDefault()
            event.returnValue = ""
          }
          window.addEventListener("beforeunload", this.beforeUnload)
        },
        destroyed() {
          window.removeEventListener("beforeunload", this.beforeUnload)
        }
      }
    </script>
    """
  end

  @doc """
  Renders the schedule timezone field with its datalist of accepted names.

  `zones` is `GtfsPlanner.Gtfs.DisplayClock.zone_names/0`, the same list the
  server validates a submitted name against, so a suggestion and an accepted
  value cannot disagree (INV-4). The control stays free text: a datalist
  suggests, and the server decides whether the name is a zone, which keeps one
  validation rule instead of a browser rule beside it.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :zones, :list, required: true
  attr :id, :string, required: true

  def timezone_input(assigns) do
    ~H"""
    <.input
      field={@field}
      id={@id}
      type="text"
      label="Schedule timezone"
      list={"#{@id}-zones"}
      autocomplete="off"
      help="Search by city or enter an IANA timezone, such as America/New_York."
    />

    <datalist id={"#{@id}-zones"}>
      <option :for={zone <- @zones} value={zone}></option>
    </datalist>
    """
  end

  @doc """
  Renders the agency identity and rider contact fields for `form`.

  `first_agency?: true` shows the schedule timezone field, because the first
  agency decides the version's zone; every other agency shows `zone` in an info
  callout instead, so a create cannot submit a second zone (R2, AC-12).
  `zone_names` is `DisplayClock.zone_names/0`. The optional fields carry their
  "(optional)" marker in the visible label, and the form's own id prefixes the
  generated field ids.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :first_agency?, :boolean, required: true
  attr :zone, :string, default: nil
  attr :zone_names, :list, default: []

  def agency_form_fields(assigns) do
    ~H"""
    <fieldset class="mt-6 border-t border-base-300 pt-5 first:mt-0 first:border-t-0 first:pt-0">
      <legend class="pr-4 text-base font-semibold text-base-content">Agency identity</legend>

      <div class="mt-4">
        <.input field={@form[:agency_name]} type="text" label="Agency name" />
        <.input field={@form[:agency_url]} type="url" label="Website" />

        <.timezone_input
          :if={@first_agency?}
          field={@form[:agency_timezone]}
          zones={@zone_names}
          id={@form[:agency_timezone].id}
        />

        <div :if={!@first_agency?} class="mb-2">
          <.callout
            id="agency-zone-callout"
            kind="info"
            title={@zone}
          >
            Schedule timezone for this version. To update every agency together, use
            Change timezone on the agency list.
          </.callout>
        </div>
      </div>
    </fieldset>

    <fieldset class="mt-6 border-t border-base-300 pt-5">
      <legend class="pr-4 text-base font-semibold text-base-content">Rider contact</legend>

      <div class="mt-4">
        <.language_select field={@form[:agency_lang]} label="Language" optional />

        <.input
          field={@form[:agency_phone]}
          type="tel"
          label="Phone (optional)"
          help="Keep the local formatting riders recognize."
        />

        <.input field={@form[:agency_email]} type="email" label="Email (optional)" />
        <.input field={@form[:agency_fare_url]} type="url" label="Fare website (optional)" />
      </div>
    </fieldset>
    """
  end

  defp label_with_optional(label, true), do: "#{label} (optional)"
  defp label_with_optional(label, false), do: label
end
