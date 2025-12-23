defmodule GtfsPlannerWeb.AssignOrganization do
  @moduledoc """
  Plug to assign the organization from URL parameters.

  This plug extracts the `org_alias` parameter from the connection,
  fetches the corresponding organization, and assigns it to the
  connection as `:current_organization`. If the organization is
  not found, it returns a 404 Not Found response.
  """

  import Plug.Conn
  alias GtfsPlanner.Organizations

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
      {:ok, organization} ->
        assign(conn, :current_organization, organization)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> Phoenix.Controller.html({GtfsPlannerWeb.ErrorHTML, :render_template, "404.html", %{}})
        |> halt()
    end
  end

  def call(conn, _opts), do: conn
end
