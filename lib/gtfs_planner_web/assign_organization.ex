defmodule GtfsPlannerWeb.AssignOrganization do
  @moduledoc """
  Plug to assign the organization from URL parameters.

  This plug extracts the `org_alias` parameter from the connection,
  fetches the corresponding organization, and assigns it to the
  connection as `:current_organization`. If the organization is
  not found, it returns a 404 Not Found response.
  """

  import Plug.Conn
  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2]
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Organizations.Organization

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @doc """
  Extracts organization from URL params and assigns it to the connection.

  ## Parameters
    - conn: The Plug connection struct
    - opts: Options (currently unused)

  ## Returns
    - The connection with `:current_organization` assigned if found
    - A 404 Not Found response if the organization doesn't exist
  """
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  @impl true
  def call(%Plug.Conn{params: %{"org_alias" => org_alias}} = conn, _opts) do
    case Organizations.get_organization_by_alias(org_alias) do
      %Organization{} = organization ->
        assign(conn, :current_organization, organization)

      nil ->
        conn
        |> put_status(:not_found)
        |> Phoenix.Controller.html({GtfsPlannerWeb.ErrorHTML, :render_template, "404.html", %{}})
        |> halt()
    end
  end

  def call(conn, _opts), do: conn

  @doc """
  LiveView mount hook to assign organization from URL parameters.

  ## Parameters
    - :default: The hook name
    - params: The route parameters
    - _session: The session (unused)
    - socket: The LiveView socket

  ## Returns
    - `{:cont, socket}` with `:current_organization` assigned if found
    - `{:cont, socket}` unchanged if `org_alias` is not in params
    - `{:halt, socket}` with flash error and redirect if organization not found
  """
  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, %{"org_alias" => org_alias} = _params, _session, socket) do
    case Organizations.get_organization_by_alias(org_alias) do
      %Organization{} = organization ->
        {:cont, Phoenix.Component.assign(socket, :current_organization, organization)}

      nil ->
        socket =
          socket
          |> put_flash(:error, "Organization not found")
          |> redirect(to: "/")

        {:halt, socket}
    end
  end

  def on_mount(:default, _params, _session, socket) do
    {:cont, socket}
  end
end
