defmodule GtfsPlannerWeb.Gtfs.StationReportDrawerComponents do
  @moduledoc """
  Shared drawer components for station report entity editing.
  """
  use Phoenix.Component

  import GtfsPlannerWeb.CoreComponents, only: [drawer: 1, input: 1]

  alias GtfsPlanner.Gtfs.{Pathway, Stop}

  attr :drawer_entity, :any, default: nil
  attr :drawer_type, :atom, default: nil
  attr :drawer_form, :any, default: nil
  attr :drawer_error, :string, default: nil

  def entity_drawer(assigns) do
    ~H"""
    <.drawer
      id="report-entity-drawer"
      open={drawer_open?(@drawer_entity, @drawer_error)}
      on_close="close_entity_drawer"
      title={drawer_title(@drawer_type, @drawer_entity)}
    >
      <div :if={@drawer_error} class="mb-4 text-sm text-error">{@drawer_error}</div>

      <.stop_drawer_form
        :if={@drawer_type == :stop && @drawer_entity && @drawer_form}
        entity={@drawer_entity}
        form={@drawer_form}
      />

      <.pathway_drawer_form
        :if={@drawer_type == :pathway && @drawer_entity && @drawer_form}
        entity={@drawer_entity}
        form={@drawer_form}
      />
    </.drawer>
    """
  end

  defp drawer_title(:stop, %{stop_id: stop_id}), do: stop_id
  defp drawer_title(:stop, nil), do: "Stop not found"
  defp drawer_title(:pathway, %{pathway_id: pathway_id}), do: pathway_id
  defp drawer_title(:pathway, nil), do: "Pathway not found"
  defp drawer_title(_, _), do: ""

  defp drawer_open?(drawer_entity, drawer_error),
    do: not is_nil(drawer_entity) or not is_nil(drawer_error)

  attr :entity, :map, required: true
  attr :form, :any, required: true

  defp stop_drawer_form(assigns) do
    ~H"""
    <div class="space-y-4">
      <dl class="space-y-2 text-sm">
        <div class="flex justify-between">
          <dt class="text-base-content/60">stop_id</dt>
          <dd class="font-mono">{@entity.stop_id}</dd>
        </div>
        <div class="flex justify-between">
          <dt class="text-base-content/60">location_type</dt>
          <dd class="font-mono">
            {@entity.location_type} - {Stop.location_type_label(@entity.location_type)}
          </dd>
        </div>
        <div class="flex justify-between">
          <dt class="text-base-content/60">parent_station</dt>
          <dd class="font-mono">{@entity.parent_station || "-"}</dd>
        </div>
      </dl>

      <.form for={@form} id="report-stop-edit-form" phx-submit="save_entity" class="space-y-3">
        <.input field={@form[:stop_name]} label="stop_name" type="text" />
        <div class="grid grid-cols-2 gap-3">
          <.input field={@form[:stop_lat]} label="stop_lat" type="text" />
          <.input field={@form[:stop_lon]} label="stop_lon" type="text" />
        </div>
        <.input field={@form[:level_id]} label="level_id" type="text" />
        <.input
          field={@form[:wheelchair_boarding]}
          label="wheelchair_boarding"
          type="select"
          options={[
            {"", ""},
            {"0 - No info", "0"},
            {"1 - Accessible", "1"},
            {"2 - Not accessible", "2"}
          ]}
        />
        <.input field={@form[:platform_code]} label="platform_code" type="text" />
        <button type="submit" class="btn btn-primary btn-sm w-full">Save changes</button>
      </.form>
    </div>
    """
  end

  attr :entity, :map, required: true
  attr :form, :any, required: true

  defp pathway_drawer_form(assigns) do
    ~H"""
    <div class="space-y-4">
      <dl class="space-y-2 text-sm">
        <div class="flex justify-between">
          <dt class="text-base-content/60">pathway_id</dt>
          <dd class="font-mono">{@entity.pathway_id}</dd>
        </div>
        <div class="flex justify-between">
          <dt class="text-base-content/60">pathway_mode</dt>
          <dd class="font-mono">
            {@entity.pathway_mode} - {Pathway.mode_label(@entity.pathway_mode)}
          </dd>
        </div>
        <div class="flex justify-between">
          <dt class="text-base-content/60">from_stop_id</dt>
          <dd class="font-mono">{@entity.from_stop_id}</dd>
        </div>
        <div class="flex justify-between">
          <dt class="text-base-content/60">to_stop_id</dt>
          <dd class="font-mono">{@entity.to_stop_id}</dd>
        </div>
      </dl>

      <.form for={@form} id="report-pathway-edit-form" phx-submit="save_entity" class="space-y-3">
        <.input field={@form[:traversal_time]} label="traversal_time (seconds)" type="number" />
        <div class="grid grid-cols-2 gap-3">
          <.input field={@form[:length]} label="length (meters)" type="text" />
          <.input field={@form[:min_width]} label="min_width (meters)" type="text" />
        </div>
        <div class="grid grid-cols-2 gap-3">
          <.input field={@form[:stair_count]} label="stair_count" type="number" />
          <.input field={@form[:max_slope]} label="max_slope" type="text" />
        </div>
        <.input
          field={@form[:is_bidirectional]}
          label="is_bidirectional"
          type="select"
          options={[{"Yes", "true"}, {"No", "false"}]}
        />
        <.input field={@form[:signposted_as]} label="signposted_as" type="text" />
        <.input field={@form[:reversed_signposted_as]} label="reversed_signposted_as" type="text" />
        <button type="submit" class="btn btn-primary btn-sm w-full">Save changes</button>
      </.form>
    </div>
    """
  end
end
