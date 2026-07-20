defmodule GtfsPlannerWeb.ErrorHTMLTest do
  use GtfsPlannerWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  @missing_html_path "/this-route-does-not-exist-018-dsa-step-1"

  test "renders 404.html" do
    assert render_to_string(GtfsPlannerWeb.ErrorHTML, "404", "html", []) == "Not Found"
  end

  test "renders 500.html" do
    assert render_to_string(GtfsPlannerWeb.ErrorHTML, "500", "html", []) ==
             "Internal Server Error"
  end

  describe "endpoint error documents" do
    test "unknown HTML GET returns a 404 root document with app assets", %{conn: conn} do
      conn = get(conn, @missing_html_path)

      assert conn.status == 404
      assert response_content_type(conn, :html) =~ "charset=utf-8"

      document =
        conn
        |> response(404)
        |> LazyHTML.from_document()

      assert document |> LazyHTML.query("html[lang]") |> LazyHTML.attribute("lang") ==
               ["en"]

      assert document
             |> LazyHTML.query("link[rel='stylesheet'][href*='/assets/css/app.css']")
             |> Enum.any?()

      assert document
             |> LazyHTML.query("script[src*='/assets/js/app.js']")
             |> Enum.any?()
    end

    test "unknown JSON GET returns the exact ErrorJSON envelope and no HTML wrapper", %{
      conn: conn
    } do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get(@missing_html_path)

      assert conn.status == 404
      assert response_content_type(conn, :json) =~ "charset=utf-8"

      assert json_response(conn, 404) == %{"errors" => %{"detail" => "Not Found"}}

      refute response(conn, 404) =~ "<html"
    end
  end
end
