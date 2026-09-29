defmodule GtfsPlannerWeb.AssignGtfsVersion do
  @moduledoc """
  LiveView mount hook to assign GTFS version from URL parameters.

  This hook extracts the `:version` parameter from the route params,
  validates that the version exists and belongs to the current organization,
  and assigns it to the LiveView socket as `:current_gtfs_version`.
  If the version is not found or doesn't belong to the organization,
  it redirects to the dashboard with an error. It does the same when no
  organization is assigned, as for a system administrator, whom
  `GtfsPlannerWeb.AssignOrganization` lets through without one.
  """

  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2]
  import Phoenix.Component, only: [assign: 3]
  alias GtfsPlanner.Versions

  @no_organization_flash "GTFS pages belong to an organization. Sign in as a member of the organization to open them."

  @doc """
  LiveView mount hook to assign GTFS version from URL parameters.

  ## Parameters
    - :default: The hook name
    - params: The route parameters containing :version
    - _session: The session (unused)
    - socket: The LiveView socket

  ## Returns
    - `{:cont, socket}` with `:current_gtfs_version` assigned if found and valid
    - `{:halt, socket}` with flash error and redirect if version not found or invalid,
      or if no organization is assigned
  """
  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(
        :default,
        %{"version" => version_id},
        _session,
        %{assigns: %{current_organization: %{} = current_organization}} = socket
      ) do
    case Versions.get_published_gtfs_version_for_org(current_organization.id, version_id) do
      %Versions.GtfsVersion{} = version ->
        # Get available versions for dropdown
        available_versions = Versions.list_gtfs_versions_for_dropdown(current_organization.id)

        socket =
          socket
          |> assign(:current_gtfs_version, version)
          |> assign(:available_versions, available_versions)

        {:cont, socket}

      nil ->
        socket =
          socket
          |> put_flash(:error, "GTFS version not found")
          |> redirect(to: "/")

        {:halt, socket}
    end
  end

  def on_mount(:default, %{"version" => _version_id}, _session, socket) do
    socket =
      socket
      |> put_flash(:error, @no_organization_flash)
      |> redirect(to: "/")

    {:halt, socket}
  end
end
