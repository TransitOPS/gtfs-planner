defmodule GtfsPlannerWeb.ErrorHTMLTest do
  use GtfsPlannerWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  @missing_html_path "/this-route-does-not-exist-018-dsa-step-2"

  # Endpoint error rendering receives kind/reason/stack assigns when an exception
  # is raised. The custom 404/500 templates must never read them; passing
  # unmistakable sentinels through the renderer lets the tests assert no
  # diagnostic data leaks into the response without constructing a fake view.
  @diagnostic_sentinels %{
    "kind" => "SENTINEL_KIND_LEAK",
    "reason" => "SENTINEL_REASON_LEAK",
    "stack" => "SENTINEL_STACK_LEAK"
  }

  describe "direct template rendering" do
    test "404 produces one heading, the Error 404 status label, and one home anchor to slash" do
      html =
        render_to_string(GtfsPlannerWeb.ErrorHTML, "404", "html", @diagnostic_sentinels)

      doc = LazyHTML.from_fragment(html)

      assert doc |> LazyHTML.query("#error-page-404") |> Enum.count() == 1
      assert doc |> LazyHTML.query("#error-page-404 h1") |> Enum.count() == 1

      status = doc |> LazyHTML.query("#error-page-404-status")
      assert LazyHTML.text(status) =~ "404"

      home = doc |> LazyHTML.query("#error-page-404-home")
      assert LazyHTML.attribute(home, "href") == ["/"]
      assert LazyHTML.text(home) =~ "Return home"

      # Exactly one recovery anchor — no back, history, or authenticated controls.
      assert doc |> LazyHTML.query("#error-page-404 a") |> Enum.count() == 1

      refute html =~ "SENTINEL_KIND_LEAK"
      refute html =~ "SENTINEL_REASON_LEAK"
      refute html =~ "SENTINEL_STACK_LEAK"

      refute html =~ ~r/<form[\s>]/
      refute html =~ ~r/users\/log_(out|in)/i
      refute html =~ "Log out"
    end

    test "500 produces one heading, the Error 500 status label, primary reload, and secondary home" do
      html =
        render_to_string(GtfsPlannerWeb.ErrorHTML, "500", "html", @diagnostic_sentinels)

      doc = LazyHTML.from_fragment(html)

      assert doc |> LazyHTML.query("#error-page-500") |> Enum.count() == 1
      assert doc |> LazyHTML.query("#error-page-500 h1") |> Enum.count() == 1

      status = doc |> LazyHTML.query("#error-page-500-status")
      assert LazyHTML.text(status) =~ "500"

      reload = doc |> LazyHTML.query("#error-page-500-reload")
      assert LazyHTML.attribute(reload, "href") == [""]
      assert LazyHTML.text(reload) =~ "Try again"

      home = doc |> LazyHTML.query("#error-page-500-home")
      assert LazyHTML.attribute(home, "href") == ["/"]
      assert LazyHTML.text(home) =~ "Return home"

      # Exactly two recovery anchors — one primary GET reload, one home escape.
      assert doc |> LazyHTML.query("#error-page-500 a") |> Enum.count() == 2

      refute html =~ "SENTINEL_KIND_LEAK"
      refute html =~ "SENTINEL_REASON_LEAK"
      refute html =~ "SENTINEL_STACK_LEAK"

      # No form that could replay a failed mutation body.
      refute html =~ ~r/<form[\s>]/
      refute html =~ ~r/users\/log_(out|in)/i
      refute html =~ "Log out"
    end

    test "rendering 422.html still returns the Phoenix status phrase through the catch-all" do
      assert render_to_string(GtfsPlannerWeb.ErrorHTML, "422", "html", []) =~
               "Unprocessable Content"
    end
  end

  describe "endpoint error documents" do
    test "unknown HTML GET returns a 404 root document with the shared app shell", %{
      conn: conn
    } do
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

      assert document |> LazyHTML.query("#app-header") |> Enum.count() == 1
      assert document |> LazyHTML.query("#main-content") |> Enum.count() == 1
      assert document |> LazyHTML.query("#error-page-404") |> Enum.count() == 1
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
