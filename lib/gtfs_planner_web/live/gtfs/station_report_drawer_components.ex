defmodule GtfsPlannerWeb.Gtfs.StationReportDrawerComponents do
  @moduledoc """
  The one editing surface the station report can reach: a stop drawer.

  The report links a stop by name from a failed check, and that link is the
  only way in. There is no pathway form here — the report never rendered a
  pathway link, so the pathway branch was unreachable and is gone. Pathway
  editing belongs to the station diagram editor, which owns its own form.

  ## Contracts consumed

  Shared `drawer/1`, `input/1`, `button/1`, and `callout/1` supply the
  structure, labels, error association, and actions. `drawer/1` also owns
  opener restoration: the caller passes `return_focus_id`, and the shipped
  `OverlayDialog` hook returns focus there when the dialog closes.

  The wrapper carries `phx-hook="FormErrorFocus"`, the existing scoped focus
  hook. On a rejected save the LiveView pushes `focus_form_error` naming this
  form and `#report-stop-form-error` as the bounded fallback.

  ## Layout

  One column at every width, capped at 40rem so the fields stay a readable
  measure inside the wider drawer panel. Labels are sentence case and always
  visible; raw GTFS keys appear as secondary help under each control, never
  as the label. Optional fields say so in the label — that is the only
  required/optional system used here.
  """
  use Phoenix.Component

  import GtfsPlannerWeb.CoreComponents, only: [button: 1, callout: 1, drawer: 1, input: 1]

  alias GtfsPlanner.Gtfs.Stop

  @form_id "report-stop-edit-form"
  @error_summary_id "report-stop-form-error"

  @wheelchair_options [
    {"No value", ""},
    {"0 — No information", "0"},
    {"1 — Accessible", "1"},
    {"2 — Not accessible", "2"}
  ]

  @doc "The stable id of the stop edit form, shared with the focus event."
  def form_id, do: @form_id

  @doc "The stable id of the failed-save summary, used as the focus fallback."
  def error_summary_id, do: @error_summary_id

  attr :drawer_entity, :any, default: nil
  attr :drawer_entity_id, :string, default: nil
  attr :drawer_form, :any, default: nil
  attr :drawer_error, :string, default: nil

  attr :drawer_return_focus_id, :string,
    default: nil,
    doc: "id of the report control that opened the drawer, restored on close"

  def entity_drawer(assigns) do
    ~H"""
    <.drawer
      id="report-entity-drawer"
      open={drawer_open?(@drawer_entity, @drawer_error)}
      on_close="close_entity_drawer"
      title={drawer_title(@drawer_entity)}
      initial_focus={:first_field}
      return_focus_id={@drawer_return_focus_id}
    >
      <div id="report-stop-drawer" phx-hook="FormErrorFocus" class="max-w-[40rem]">
        <.lookup_recovery :if={@drawer_error} message={@drawer_error} />

        <.stop_drawer_form
          :if={@drawer_entity && @drawer_form}
          entity={@drawer_entity}
          form={@drawer_form}
        />
      </div>
    </.drawer>
    """
  end

  defp drawer_title(%{stop_name: stop_name, stop_id: stop_id}),
    do: presence(stop_name) || stop_id

  defp drawer_title(_entity), do: "Stop not found"

  defp drawer_open?(drawer_entity, drawer_error),
    do: not is_nil(drawer_entity) or not is_nil(drawer_error)

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  # -- Lookup recovery --------------------------------------------------------

  attr :message, :string, required: true

  defp lookup_recovery(assigns) do
    ~H"""
    <div class="space-y-4">
      <.callout id="report-stop-lookup-error" kind="error" title="Stop not found" tabindex="-1">
        {@message}
      </.callout>

      <.button
        id="report-stop-lookup-retry"
        type="button"
        class="min-h-11"
        phx-click="retry_entity_lookup"
      >
        Retry lookup
      </.button>
    </div>
    """
  end

  # -- Stop form --------------------------------------------------------------

  attr :entity, :map, required: true
  attr :form, :any, required: true

  defp stop_drawer_form(assigns) do
    assigns =
      assigns
      |> assign(:save_failed?, save_failed?(assigns.form))
      |> assign(:level_required?, level_required?(assigns.entity))
      |> assign(:wheelchair_options, @wheelchair_options)
      |> assign(:form_id, @form_id)
      |> assign(:error_summary_id, @error_summary_id)

    ~H"""
    <div class="space-y-6">
      <section aria-labelledby="report-stop-identity-title" class="space-y-2">
        <h3 id="report-stop-identity-title" class="text-sm font-semibold">Stop identity</h3>
        <p class="text-sm text-base-content/70">These fields are not editable from the report.</p>

        <dl class="divide-y divide-base-300 border border-base-300">
          <.identity_row label="Stop ID" gtfs_key="stop_id" value={@entity.stop_id} />
          <.identity_row
            label="Location type"
            gtfs_key="location_type"
            value={
              "#{@entity.location_type} — #{Stop.location_type_label(@entity.location_type)}"
            }
          />
          <.identity_row
            label="Parent station"
            gtfs_key="parent_station"
            value={presence(@entity.parent_station) || "None"}
          />
        </dl>
      </section>

      <%!--
        `novalidate` is deliberate. The numeric range attributes below are real
        input affordances (spinner clamping, decimal keypads), but leaving native
        constraint validation on would let the browser block the submit before
        LiveView ever sees it — the range error would surface as a transient
        native bubble while `level_id` still needed a server message. One error
        system: the changeset decides, and every message is rendered inline and
        associated through `aria-describedby`.
      --%>
      <.form
        for={@form}
        id={@form_id}
        novalidate
        phx-change="validate_entity"
        phx-submit="save_entity"
        class="space-y-1"
      >
        <div :if={@save_failed?} class="mb-4">
          <.callout
            id={@error_summary_id}
            kind="error"
            title="Check the highlighted fields"
            tabindex="-1"
          >
            Nothing was saved. Correct the fields marked below, then save again.
          </.callout>
        </div>

        <.input
          field={@form[:stop_name]}
          type="text"
          label="Stop name (optional)"
          help="stop_name — the rider-facing name shown on the report."
        />

        <%!--
          Field width tracks the expected input, but the constraint belongs on
          the wrapper rather than the control: `<.input>` lays its label and
          control out inline, so narrowing the control alone pulls the label
          beside it and breaks the top-aligned label contract.
        --%>
        <div class="sm:max-w-[16rem]">
          <.input
            field={@form[:stop_lat]}
            type="number"
            label="Latitude (optional)"
            step="0.000001"
            min="-90"
            max="90"
            inputmode="decimal"
            help="stop_lat — decimal degrees between -90 and 90. Leave blank if unknown."
          />
        </div>

        <div class="sm:max-w-[16rem]">
          <.input
            field={@form[:stop_lon]}
            type="number"
            label="Longitude (optional)"
            step="0.000001"
            min="-180"
            max="180"
            inputmode="decimal"
            help="stop_lon — decimal degrees between -180 and 180. Leave blank if unknown."
          />
        </div>

        <div class="sm:max-w-[20rem]">
          <.input
            field={@form[:level_id]}
            type="text"
            label={if @level_required?, do: "Level", else: "Level (optional)"}
            help={level_help(@level_required?)}
          />
        </div>

        <div class="sm:max-w-[20rem]">
          <.input
            field={@form[:wheelchair_boarding]}
            type="select"
            label="Wheelchair boarding (optional)"
            options={@wheelchair_options}
            help="wheelchair_boarding — leave with no value to inherit the station's accessibility."
          />
        </div>

        <div class="sm:max-w-[16rem]">
          <.input
            field={@form[:platform_code]}
            type="text"
            label="Platform code (optional)"
            help="platform_code — the platform number or letter riders see, such as 3 or B."
          />
        </div>

        <div class="flex flex-wrap items-center gap-3 pt-3">
          <.button type="submit" class="min-h-11" phx-disable-with="Saving…">Save changes</.button>
          <.button
            type="button"
            variant="quiet"
            class="min-h-11"
            phx-click="close_entity_drawer"
          >
            Cancel
          </.button>
        </div>
      </.form>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :gtfs_key, :string, required: true
  attr :value, :string, required: true

  defp identity_row(assigns) do
    ~H"""
    <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-0.5 px-3 py-2">
      <dt class="text-sm">
        {@label}
        <span class="ml-1 font-mono text-xs text-base-content/70">{@gtfs_key}</span>
      </dt>
      <dd class="font-mono text-sm break-all">{@value}</dd>
    </div>
    """
  end

  defp level_help(true),
    do: "level_id — required for a stop inside a station. Must match a level in this version."

  defp level_help(false),
    do: "level_id — must match a level in this version. Leave blank if the stop has no level."

  defp level_required?(%{parent_station: parent_station}),
    do: not is_nil(presence(parent_station))

  defp level_required?(_entity), do: false

  # A failed save is the only state that earns a view-level banner. Validation
  # on change marks its own fields and must not shout about a save that was
  # never attempted.
  defp save_failed?(%Phoenix.HTML.Form{source: %Ecto.Changeset{action: action}, errors: errors})
       when action in [:update, :insert] and errors != [],
       do: true

  defp save_failed?(_form), do: false
end
