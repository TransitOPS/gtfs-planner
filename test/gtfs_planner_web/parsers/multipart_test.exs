defmodule GtfsPlannerWeb.Parsers.MultipartTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias GtfsPlannerWeb.Parsers.Multipart

  @boundary "station-journal-boundary"
  @journal_path [
    "api",
    "v1",
    "versions",
    "version-id",
    "stations",
    "station-id",
    "journal-photos"
  ]

  describe "parse/5" do
    test "accepts exact journal-photo POST multipart bodies below the journal limit" do
      opts = Multipart.init(default_length: 100, journal_length: 1_000)

      assert {:ok, %{"metadata" => metadata}, conn} =
               parse_multipart(
                 "POST",
                 @journal_path,
                 "metadata",
                 String.duplicate("a", 101),
                 opts
               )

      assert metadata == String.duplicate("a", 101)
      refute conn.halted
    end

    test "returns a CORS-enabled JSON 413 for oversized exact journal-photo requests" do
      opts = Multipart.init(default_length: 100, journal_length: 100)

      assert {:ok, %{}, conn} =
               parse_multipart(
                 "POST",
                 @journal_path,
                 "metadata",
                 String.duplicate("a", 101),
                 opts,
                 origin: "http://localhost:51091"
               )

      assert conn.halted
      assert conn.status == 413
      assert conn.resp_body == Jason.encode!(%{error: %{code: "payload_too_large"}})

      assert get_resp_header(conn, "access-control-allow-origin") == [
               "http://localhost:51091"
             ]
    end

    test "uses the default limit for non-POST or non-exact journal-photo routes" do
      opts = Multipart.init(default_length: 100, journal_length: 1_000)

      for {method, path_info} <- [
            {"PUT", @journal_path},
            {"POST",
             ["api", "v1", "versions", "version-id", "stations", "station-id", "journal-photo"]},
            {"POST", @journal_path ++ ["extra"]},
            {"POST", ["api", "v1", "unrelated", "multipart"]}
          ] do
        assert {:error, :too_large, conn} =
                 parse_multipart(method, path_info, "metadata", String.duplicate("a", 101), opts)

        refute conn.halted
      end
    end
  end

  test "keeps URL-encoded and JSON parser behavior outside the multipart parser" do
    parsers =
      Plug.Parsers.init(
        parsers: [:urlencoded, Multipart, :json],
        pass: ["*/*"],
        json_decoder: Jason
      )

    urlencoded =
      conn(:post, "/api/v1/example", "name=journal")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")

    urlencoded = Plug.Parsers.call(urlencoded, parsers)
    assert urlencoded.body_params == %{"name" => "journal"}

    json =
      conn(:post, "/api/v1/example", ~s({"name":"journal"}))
      |> put_req_header("content-type", "application/json")
      |> Plug.Parsers.call(parsers)

    assert json.body_params == %{"name" => "journal"}
  end

  defp parse_multipart(method, path_info, name, value, opts, extra_headers \\ []) do
    body = multipart_body(name, value)

    conn(method, "/" <> Enum.join(path_info, "/"), body)
    |> Map.put(:path_info, path_info)
    |> put_req_header("content-type", "multipart/form-data; boundary=#{@boundary}")
    |> then(fn conn ->
      Enum.reduce(extra_headers, conn, fn {key, header_value}, conn ->
        put_req_header(conn, to_string(key), header_value)
      end)
    end)
    |> Multipart.parse("multipart", "form-data", %{"boundary" => @boundary}, opts)
  end

  defp multipart_body(name, value) do
    "--#{@boundary}\r\n" <>
      "Content-Disposition: form-data; name=\"#{name}\"\r\n\r\n" <>
      value <> "\r\n--#{@boundary}--\r\n"
  end
end
