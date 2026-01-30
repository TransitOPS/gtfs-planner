defmodule GtfsPlannerWeb.UploadsPlug do
  @moduledoc """
  Serves uploaded files from the configured uploads directory.

  This plug intercepts requests to `/uploads/*` and serves files from the
  directory specified by the `:uploads_path` application configuration.
  If a file is not found, the request is passed to the next plug.

  ## Security

  This plug implements path traversal protection by validating that the
  resolved file path strictly resides within the configured uploads directory.
  Requests attempting to access files outside this directory (e.g., using `..`)
  will receive a 403 Forbidden response.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{path_info: ["uploads" | rest]} = conn, _opts) do
    uploads_base = Application.fetch_env!(:gtfs_planner, :uploads_path)
    uploads_base_expanded = Path.expand(uploads_base)

    file_path = Path.join([uploads_base | rest])
    file_path_expanded = Path.expand(file_path)

    cond do
      not String.starts_with?(file_path_expanded, uploads_base_expanded <> "/") and
          file_path_expanded != uploads_base_expanded ->
        # Path traversal attempt detected
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(403, "Forbidden")
        |> halt()

      File.regular?(file_path_expanded) ->
        conn
        |> send_file(200, file_path_expanded)
        |> halt()

      true ->
        conn
    end
  end

  def call(conn, _opts), do: conn
end
