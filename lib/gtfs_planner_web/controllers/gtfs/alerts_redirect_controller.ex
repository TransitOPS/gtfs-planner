defmodule GtfsPlannerWeb.Gtfs.AlertsRedirectController do
  @moduledoc """
  The versioned Alerts paths this package moved into the organization.

  Alerts is organization-owned, so `/gtfs/:version/alerts…` no longer selects
  anything: the destination is the same page without a version. These actions
  exist only so an old bookmark, a shared link or a page cached before the move
  lands on the page that now owns the work instead of a 404 (AC-8).

  The reader is authenticated and their organization resolved by the browser
  pipeline before this controller runs, and `:authorize_version` then re-checks
  the version in the path against that organization. A bookmark carrying
  another tenant's version - or no organization at all - is refused with the
  same answer `AssignGtfsVersion` gives, so a version is never used as a way
  around tenant scoping.

  Only the alert identity the bookmark named is carried across. No version,
  query string or form value is forwarded, so the destination reads nothing
  this controller trusted.
  """

  use GtfsPlannerWeb, :controller

  plug :authorize_version

  alias GtfsPlanner.Versions

  @version_missing "GTFS version not found"
  @no_organization "GTFS pages belong to an organization. Sign in as a member of the organization to open them."

  @doc "Sends the versioned list to the organization's list."
  def index(conn, _params), do: redirect(conn, to: ~p"/alerts")

  @doc "Sends the versioned editor's start card to the organization's editor."
  def new(conn, _params), do: redirect(conn, to: ~p"/alerts/new")

  @doc "Sends the versioned alert settings page to the organization's settings page."
  def settings(conn, _params), do: redirect(conn, to: ~p"/alerts/settings")

  @doc """
  Sends a versioned alert to the same alert in the organization.

  The identifier is carried as it arrived and re-scoped by the destination, so a
  foreign or unknown identifier reveals nothing here and is refused there.
  """
  def edit(conn, %{"alert_id" => alert_id}) do
    redirect(conn, to: ~p"/alerts/#{alert_id}")
  end

  defp authorize_version(%{halted: true} = conn, _opts), do: conn

  defp authorize_version(conn, _opts) do
    case conn.assigns[:current_organization] do
      %{id: organization_id} ->
        if Versions.get_published_gtfs_version_for_org(
             organization_id,
             conn.path_params["version"]
           ) do
          conn
        else
          refuse(conn, @version_missing)
        end

      _organization ->
        refuse(conn, @no_organization)
    end
  end

  defp refuse(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/")
    |> halt()
  end
end
