defmodule GtfsPlannerWeb.Components.GtfsVersionSwitcher do
  @moduledoc """
  Function component for rendering a GTFS version dropdown switcher.

  This component displays a dropdown that allows users to switch between
  different GTFS versions for their organization. The selected version is
  persisted to localStorage via the GtfsVersionHook JavaScript hook.

  Designed as a labeled pill for placement in the top navigation bar.
  """

  use Phoenix.Component

  @doc """
  Renders a GTFS version switcher as a labeled pill for the navigation bar.

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
      class="flex items-center gap-2 bg-base-200 rounded-full pl-3 pr-1 py-1"
    >
      <label
        for="gtfs-version-select"
        class="text-sm font-medium text-base-content/70 whitespace-nowrap"
      >
        GTFS Version:
      </label>
      <select
        id="gtfs-version-select"
        name="version"
        aria-label="Select GTFS version"
        class="select select-sm select-ghost rounded-full bg-base-100 min-w-[120px] focus:outline-none focus:ring-2 focus:ring-primary"
      >
        <option :for={{id, name} <- @versions} value={id} selected={id == @current_version.id}>
          {name}
        </option>
      </select>
    </div>
    """
  end
end
