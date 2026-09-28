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

  defp label_with_optional(label, true), do: "#{label} (optional)"
  defp label_with_optional(label, false), do: label
end
