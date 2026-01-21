defmodule GtfsPlannerWeb.AssignGtfsVersion do
  @moduledoc """
  LiveView mount hook to assign GTFS version from URL parameters.

  This hook extracts the `:version` parameter from the route params,
  validates that the version exists and belongs to the current organization,
  and assigns it to the LiveView socket as `:current_gtfs_version`.
  If the version is not found or doesn't belong to the organization,
  it redirects to the dashboard with an error.
  """

  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2]
  import Phoenix.Component, only: [assign: 3]
  alias GtfsPlanner.Versions

  @doc """
  LiveView mount hook to assign GTFS version from URL parameters.

  ## Parameters
    - :default: The hook name
    - params: The route parameters containing :version
    - _session: The session (unused)
    - socket: The LiveView socket

  ## Returns
    - `{:cont, socket}` with `:current_gtfs_version` assigned if found and valid
    - `{:halt, socket}` with flash error and redirect if version not found or invalid
  """
  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, %{"version" => version_id}, _session, socket) do
    current_organization = socket.assigns[:current_organization]

    try do
      version = Versions.get_gtfs_version!(version_id)

      if version.organization_id == current_organization.id do
        # Get available versions for dropdown
        available_versions = Versions.list_gtfs_versions_for_dropdown(current_organization.id)

        socket =
          socket
          |> assign(:current_gtfs_version, version)
          |> assign(:available_versions, available_versions)

        {:cont, socket}
      else
        socket =
          socket
          |> put_flash(:error, "GTFS version not found")
          |> redirect(to: "/")

        {:halt, socket}
      end
    rescue
      Ecto.NoResultsError ->
        socket =
          socket
          |> put_flash(:error, "GTFS version not found")
          |> redirect(to: "/")

        {:halt, socket}
    end
  end

  def on_mount(:default, _params, _session, socket) do
    current_organization = socket.assigns[:current_organization]

    # Get available versions for dropdown
    available_versions = Versions.list_gtfs_versions_for_dropdown(current_organization.id)

    # Get latest version for fallback
    latest_result = Versions.get_latest_gtfs_version(current_organization.id)

    socket =
      socket
      |> assign(:gtfs_version_pending, true)
      |> assign(:available_versions, available_versions)
      |> assign(:latest_gtfs_version, latest_result)

    {:cont, socket}
  end
end