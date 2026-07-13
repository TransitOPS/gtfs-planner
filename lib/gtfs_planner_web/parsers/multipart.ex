defmodule GtfsPlannerWeb.Parsers.Multipart do
  @moduledoc """
  Applies the larger multipart request budget exclusively to journal-photo uploads.

  All multipart parsing remains delegated to Plug's production parser. The route
  check happens before routing because endpoint parsers run before the router.
  """

  @behaviour Plug.Parsers

  import Plug.Conn, only: [halt: 1, put_resp_content_type: 2, send_resp: 3]

  @multipart Plug.Parsers.MULTIPART
  @default_limit 8_000_000
  @journal_photo_limit 26 * 1024 * 1024

  @impl Plug.Parsers
  def init(opts) do
    {default_limit, opts} = Keyword.pop(opts, :default_length, @default_limit)
    {journal_photo_limit, opts} = Keyword.pop(opts, :journal_length, @journal_photo_limit)

    %{
      default: @multipart.init(Keyword.put(opts, :length, default_limit)),
      journal_photo: @multipart.init(Keyword.put(opts, :length, journal_photo_limit))
    }
  end

  @impl Plug.Parsers
  def parse(conn, type, subtype, headers, opts) do
    parser_opts = if journal_photo_request?(conn), do: opts.journal_photo, else: opts.default

    case @multipart.parse(conn, type, subtype, headers, parser_opts) do
      {:error, :too_large, conn} = result ->
        if journal_photo_request?(conn),
          do: {:ok, %{}, payload_too_large(conn)},
          else: result

      result ->
        result
    end
  end

  defp journal_photo_request?(%Plug.Conn{
         method: "POST",
         path_info:
           ["api", "v1", "versions", _version_id, "stations", _station_id, "journal-photos"]
       }),
       do: true

  defp journal_photo_request?(_conn), do: false

  defp payload_too_large(conn) do
    conn
    |> GtfsPlannerWeb.Plugs.CORS.call([])
    |> put_resp_content_type("application/json")
    |> send_resp(413, Jason.encode!(%{error: %{code: "payload_too_large"}}))
    |> halt()
  end
end
