defmodule GtfsPlannerWeb.ApiKeyAuthTest do
  use GtfsPlannerWeb.ConnCase, async: false

  alias GtfsPlanner.OrganizationsFixtures

  describe "fetch_current_api_key/2" do
    setup do
      %{api_key: api_key, api_key_token: token} = OrganizationsFixtures.complete_fixture()
      %{api_key: api_key, api_key_token: token}
    end

    test "assigns current_api_key with valid Bearer token", %{
      api_key: api_key,
      api_key_token: token
    } do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> GtfsPlannerWeb.ApiKeyAuth.fetch_current_api_key([])

      assert conn.assigns[:current_api_key].id == api_key.id
      assert conn.assigns[:current_api_key].organization_id == api_key.organization_id
    end

    test "assigns current_api_key with valid token in compatibility mode (without Bearer prefix)",
         %{
           api_key: api_key,
           api_key_token: token
         } do
      conn =
        build_conn()
        |> put_req_header("authorization", token)
        |> GtfsPlannerWeb.ApiKeyAuth.fetch_current_api_key([])

      assert conn.assigns[:current_api_key].id == api_key.id
      assert conn.assigns[:current_api_key].organization_id == api_key.organization_id
    end

    test "does not assign current_api_key with missing authorization header" do
      conn =
        build_conn()
        |> GtfsPlannerWeb.ApiKeyAuth.fetch_current_api_key([])

      refute conn.assigns[:current_api_key]
    end

    test "does not assign current_api_key with invalid token" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer invalid_token_here")
        |> GtfsPlannerWeb.ApiKeyAuth.fetch_current_api_key([])

      refute conn.assigns[:current_api_key]
    end

    test "does not assign current_api_key with malformed token format" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer GtfsPlanner.V1.invalid")
        |> GtfsPlannerWeb.ApiKeyAuth.fetch_current_api_key([])

      refute conn.assigns[:current_api_key]
    end
  end

  describe "require_authenticated_api_key/2" do
    setup do
      %{api_key: api_key, api_key_token: token} = OrganizationsFixtures.complete_fixture()
      %{api_key: api_key, api_key_token: token}
    end

    test "allows request with valid API key", %{api_key_token: token} do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> GtfsPlannerWeb.ApiKeyAuth.fetch_current_api_key([])
        |> GtfsPlannerWeb.ApiKeyAuth.require_authenticated_api_key([])

      refute conn.halted
      assert conn.status != 401
    end

    test "halts and returns 401 with missing API key" do
      conn =
        build_conn()
        |> GtfsPlannerWeb.ApiKeyAuth.fetch_current_api_key([])
        |> GtfsPlannerWeb.ApiKeyAuth.require_authenticated_api_key([])

      assert conn.halted
      assert conn.status == 401

      assert conn.resp_body ==
               Jason.encode!(%{error: "Unauthorized", message: "Invalid or missing API key"})
    end

    test "halts and returns 401 with invalid API key" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer invalid_token")
        |> GtfsPlannerWeb.ApiKeyAuth.fetch_current_api_key([])
        |> GtfsPlannerWeb.ApiKeyAuth.require_authenticated_api_key([])

      assert conn.halted
      assert conn.status == 401

      assert conn.resp_body ==
               Jason.encode!(%{error: "Unauthorized", message: "Invalid or missing API key"})
    end

    test "returns JSON content type on unauthorized" do
      conn =
        build_conn()
        |> GtfsPlannerWeb.ApiKeyAuth.fetch_current_api_key([])
        |> GtfsPlannerWeb.ApiKeyAuth.require_authenticated_api_key([])

      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    end
  end

  describe "security features" do
    test "adds random delay on failed authentication (500-800ms)" do
      # Measure time without API key
      start_time = System.monotonic_time(:millisecond)

      build_conn()
      |> GtfsPlannerWeb.ApiKeyAuth.fetch_current_api_key([])
      |> GtfsPlannerWeb.ApiKeyAuth.require_authenticated_api_key([])

      elapsed = System.monotonic_time(:millisecond) - start_time

      # The delay should be between 500 and 800ms
      assert elapsed >= 500 and elapsed <= 850,
             "Expected delay between 500-850ms, got #{elapsed}ms"
    end

    test "no delay on successful authentication" do
      %{api_key_token: token} = OrganizationsFixtures.complete_fixture()

      start_time = System.monotonic_time(:millisecond)

      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> GtfsPlannerWeb.ApiKeyAuth.fetch_current_api_key([])
      |> GtfsPlannerWeb.ApiKeyAuth.require_authenticated_api_key([])

      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should complete quickly without delay (allow some overhead)
      assert elapsed < 100,
             "Expected no delay on successful auth, but took #{elapsed}ms"
    end
  end

  describe "token extraction" do
    test "extracts token from Bearer format" do
      token = "GtfsPlanner.V1.test_token"

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")

      assert {:ok, ^token} = GtfsPlannerWeb.ApiKeyAuth.extract_token(conn)
    end

    test "extracts token from compatibility format" do
      token = "GtfsPlanner.V1.test_token"

      conn =
        build_conn()
        |> put_req_header("authorization", token)

      assert {:ok, ^token} = GtfsPlannerWeb.ApiKeyAuth.extract_token(conn)
    end

    test "returns error for missing authorization header" do
      conn = build_conn()

      assert {:error, :missing} = GtfsPlannerWeb.ApiKeyAuth.extract_token(conn)
    end

    test "returns error for empty authorization header" do
      conn =
        build_conn()
        |> put_req_header("authorization", "")

      assert {:error, :invalid} = GtfsPlannerWeb.ApiKeyAuth.extract_token(conn)
    end
  end
end
