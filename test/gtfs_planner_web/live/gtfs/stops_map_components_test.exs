defmodule GtfsPlannerWeb.Gtfs.StopsMapComponentsTest do
  @moduledoc """
  The map's route badge: the map's own key names in, the shared badge's colour
  policy out.

  A route written through `Route.changeset/2` cannot carry a malformed colour,
  so the persisted Map view never reaches these inputs. They are a legacy or a
  directly-built component's inputs, which is why the adapter is asserted here
  rather than through a mounted page: the panel's own query would reject the
  fixture before any badge existed.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias GtfsPlannerWeb.Gtfs.StopsMapComponents

  # The badge the adapter renders, as a document so an assertion is about the
  # element and its own attributes rather than about a markup string.
  defp badge(route) do
    assigns = %{route: route}

    ~H"""
    <StopsMapComponents.route_badge route={@route} />
    """
    |> rendered_to_string()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("span")
  end

  defp class(element), do: element |> LazyHTML.attribute("class") |> List.first()
  defp style(element), do: element |> LazyHTML.attribute("style") |> List.first()
  defp title(element), do: element |> LazyHTML.attribute("title") |> List.first()
  defp label(element), do: element |> LazyHTML.text() |> String.trim()

  describe "route_badge/1" do
    test "renders the map's compact badge on the route's own colour" do
      element =
        badge(%{
          route_id: "1",
          short_name: "1",
          long_name: "Coast Highway",
          color: "1F5FBF"
        })

      assert class(element) =~ "rounded-badge"
      assert class(element) =~ "h-5 min-w-6 px-1.5 text-[12px]"
      assert style(element) == "background-color: #1F5FBF; color: #FFFFFF"
      assert title(element) == "Coast Highway"
      assert label(element) == "1"
    end

    test "a malformed background never reaches the style attribute" do
      # Six bytes that are not hex are what the map's own resolver accepted
      # before this adapter: the value has to be dropped, not parsed.
      for color <- ["ZZZZZZ", "#12345G", "FFF", "FFFFFFFF", "", nil] do
        element = badge(%{short_name: "1", color: color})

        assert style(element) == nil, "#{inspect(color)} reached the style attribute"

        assert class(element) =~
                 "bg-canvas text-strong ring-1 ring-inset ring-subtle"
      end
    end

    test "a malformed foreground on a valid background uses automatic ink" do
      element = badge(%{short_name: "1", color: "FFFFFF", text_color: "ZZZZZZ"})

      assert style(element) == "background-color: #FFFFFF; color: #000000"
    end

    test "a pale background takes black ink and the shared edge" do
      element = badge(%{short_name: "5", color: "FFE066", text_color: "FFFFFF"})

      assert style(element) == "background-color: #FFE066; color: #000000"
      assert class(element) =~ "ring-1 ring-inset ring-subtle"
    end

    test "a named foreground that reads on white is honoured" do
      element = badge(%{short_name: "7", color: "FFFFFF", text_color: "1F5FBF"})

      assert style(element) == "background-color: #FFFFFF; color: #1F5FBF"
    end

    test "a route with no foreground renders" do
      element = badge(%{route_id: "1", short_name: "1", color: "1F5FBF"})

      assert style(element) == "background-color: #1F5FBF; color: #FFFFFF"
      assert label(element) == "1"
    end

    test "a blank short name falls back to the route ID" do
      element = badge(%{route_id: "R-100", short_name: "  ", color: "D32F2F"})

      assert label(element) == "R-100"
    end

    test "a route with no identity reads as Unknown route" do
      element = badge(%{color: "D32F2F"})

      assert label(element) == "Unknown route"
    end

    test "the tooltip prefers the long name, then the short name, then nothing" do
      long = badge(%{short_name: "1", long_name: "Coast Highway", color: "1F5FBF"})
      short = badge(%{short_name: "1", color: "1F5FBF"})
      none = badge(%{color: "1F5FBF"})

      assert title(long) == "Coast Highway"
      assert title(short) == "1"
      assert title(none) == nil
    end

    test "the tooltip is carried as text rather than as markup" do
      element = badge(%{short_name: "1", long_name: ~s(A & "B"), color: "1F5FBF"})

      assert title(element) == ~s(A & "B")
    end
  end
end
