defmodule GtfsPlannerWeb.Components.GtfsVersionSwitcher do
  @moduledoc """
  Function component for rendering a GTFS version dropdown switcher.

  This component displays a dropdown that allows users to switch between
  different GTFS versions for their organization. The selected version is
  persisted to localStorage via the GtfsVersionHook JavaScript hook.
  """

  use Phoenix.Component

  @doc """
  Renders a GTFS version switcher dropdown.

  ## Attributes
    - current_version: The currently selected GTFS version (map)
    - versions: List of {id, name} tuples for all available versions
    - organization_id: The current organization ID (integer)

  ## Examples

      <GtfsVersionSwitcher.gtfs_version_switcher
        current_version={@current_gtfs_version}
        versions={@available_versions}
        organization_id={@current_organization.id}
      />
  """
  attr :current_version, :map, required: true, doc: "The currently selected GTFS version"
  attr :versions, :list, required: true, doc: "List of {id, name} tuples for dropdown options"
  attr :organization_id, :integer, required: true, doc: "The current organization ID"

  def gtfs_version_switcher(assigns) do
    ~H"""
    <div
      id="gtfs-version-switcher"
      phx-hook="GtfsVersionHook"
      data-organization-id={@organization_id}
      class="inline-block"
    >
      <select
        name="version"
        phx-change="switch_gtfs_version"
        class="select select-bordered select-sm"
      >
        <option :for={{id, name} <- @versions} value={id} selected={id == @current_version.id}>
          {name}
        </option>
      </select>
    </div>
    """
  end
end
