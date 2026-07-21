defmodule GtfsPlannerWeb.HealthControllerTest do
  use GtfsPlannerWeb.ConnCase, async: true

  describe "GET /health" do
    test "succeeds through the public JSON pipeline without authorization", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get(~p"/health")

      assert json_response(conn, 200) == %{"status" => "ok"}
      refute Map.has_key?(conn.assigns, :current_api_key)
      refute Map.has_key?(conn.assigns, :current_user)
      refute Map.has_key?(conn.assigns, :api_session_token)
    end
  end
end
