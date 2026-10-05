defmodule GtfsPlannerWeb.GtfsVersionNavigation do
  @moduledoc """
  Shared published-version eligibility for the version-switch events.

  Export, Feed Details, Blocks and Garages each keep their own same-version
  rule, selection event and destination, and share only this check: a version
  is eligible when it is published and belongs to the organization the server
  assigned to the socket. Event params never name the organization.
  """

  alias GtfsPlanner.Versions

  @doc """
  Returns whether `version_id` names a published version of the socket's
  current organization.
  """
  @spec published_for_current_organization?(Phoenix.LiveView.Socket.t(), Ecto.UUID.t()) ::
          boolean()
  def published_for_current_organization?(socket, version_id) do
    Versions.published_gtfs_version_for_org?(socket.assigns.current_organization.id, version_id)
  end
end
