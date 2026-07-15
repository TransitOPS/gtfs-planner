defmodule GtfsPlannerWeb.Design.DesignSystemLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures

  alias GtfsPlannerWeb.Design.DesignSystemLive

  @color_tokens ~w(
    primary secondary accent neutral
    base-100 base-200 base-300
    info success warning error
  )

  @icon_names ~w(
    hero-x-mark hero-map-pin hero-arrow-path
    hero-user-group hero-chevron-left hero-exclamation-circle
  )

  @button_combos for variant <- ~w(primary secondary quiet danger),
                     size <- ~w(sm md lg),
                     do: {variant, size}

  # Pinned independently of core_components.ex: the mapping is the contract the
  # buttons page documents, so the test must fail if either side drifts.
  @variant_classes %{
    "primary" => "btn-primary",
    "secondary" => "btn-outline",
    "quiet" => "btn-ghost",
    "danger" => "btn-error"
  }

  @size_classes %{"sm" => "btn-sm", "md" => nil, "lg" => "btn-lg"}

  setup do
    %{user: user_fixture()}
  end

  describe "access" do
    test "redirects unauthenticated visitors to the log in page", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/design")
    end
  end

  describe "index action" do
    test "lands on the introduction page inside the content column", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = conn |> live(~p"/design") |> follow_redirect(conn)

      assert has_element?(view, "#design-page-content #ds-page-introduction")
    end
  end

  describe "sidebar" do
    test "renders a patch link for every registry entry", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/introduction")

      for %{slug: slug, title: title} <- DesignSystemLive.pages() do
        assert has_element?(view, ~s(#design-sidebar a[href="/design/#{slug}"]), title)
      end
    end

    test "renders both group headings", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/introduction")

      assert has_element?(view, "#design-sidebar", "Foundations")
      assert has_element?(view, "#design-sidebar", "Components")
    end

    test "orders Foundations before Components", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/introduction")

      headings =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#design-sidebar h2")
        |> LazyHTML.text()

      assert headings == "FoundationsComponents"
    end
  end

  describe "show action" do
    test "marks the active link with aria-current and leaves others unmarked", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/colors")

      assert has_element?(view, ~s(#design-sidebar a[href="/design/colors"][aria-current="page"]))
      refute has_element?(view, ~s(#design-sidebar a[href="/design/introduction"][aria-current]))
    end

    test "recovers to the introduction page for an unknown slug", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = conn |> live(~p"/design/does-not-exist") |> follow_redirect(conn)

      assert has_element?(view, "#design-page-content #ds-page-introduction")
    end
  end

  describe "colors page" do
    for token <- @color_tokens do
      test "renders a #{token} swatch labeled with its class name", %{conn: conn, user: user} do
        conn = log_in_user(conn, user)

        {:ok, view, _html} = live(conn, ~p"/design/colors")

        assert has_element?(view, "#ds-page-colors .ds-swatch.bg-#{unquote(token)}")
        assert has_element?(view, "#ds-page-colors .ds-swatch-label", "bg-#{unquote(token)}")
      end
    end

    test "notes the primary-content white override", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/colors")

      assert has_element?(view, "#ds-page-colors", "--color-primary-content")
    end
  end

  describe "typography page" do
    test "names the Inter typeface", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/typography")

      assert has_element?(view, "#ds-page-typography", "Inter")
    end

    test "renders heading, body, and mono scale samples", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/typography")

      assert has_element?(view, "#ds-page-typography .ds-type-sample.text-2xl.font-bold")
      assert has_element?(view, "#ds-page-typography .ds-type-sample.text-xl.font-semibold")
      assert has_element?(view, "#ds-page-typography .ds-type-sample.text-lg.font-semibold")
      assert has_element?(view, "#ds-page-typography .ds-type-sample.font-mono.text-sm")
    end
  end

  describe "icons page" do
    test "renders at least six heroicon samples", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/icons")

      icons =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s(#ds-page-icons span[class^="hero-"]))
        |> Enum.count()

      assert icons >= 6
    end

    for name <- @icon_names do
      test "renders the #{name} sample with a visible name label", %{conn: conn, user: user} do
        conn = log_in_user(conn, user)

        {:ok, view, _html} = live(conn, ~p"/design/icons")

        assert has_element?(view, "#ds-page-icons span.#{unquote(name)}")
        assert has_element?(view, "#ds-page-icons .ds-icon-label", unquote(name))
      end
    end

    test "states the icon size convention", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/icons")

      assert has_element?(view, "#ds-page-icons", "size-4")
    end
  end

  describe "buttons page" do
    for {variant, size} <- @button_combos do
      variant_class = @variant_classes[variant]
      size_class = @size_classes[size]

      selector =
        "#ds-page-buttons button.btn." <>
          variant_class <> if(size_class, do: "." <> size_class, else: "")

      label = "#{variant} / #{size}"

      test "renders the #{label} combination with its daisyUI classes", %{conn: conn, user: user} do
        conn = log_in_user(conn, user)

        {:ok, view, _html} = live(conn, ~p"/design/buttons")

        assert has_element?(view, unquote(selector), unquote(label))
      end
    end

    test "renders a disabled button example", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/buttons")

      assert has_element?(view, "#ds-page-buttons button.btn[disabled]")
    end

    test "renders a button with an icon beside its label", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/buttons")

      assert has_element?(view, "#ds-page-buttons button.btn span.hero-arrow-path")
    end

    test "captions each group with the call that produces it", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/buttons")

      assert has_element?(view, "#ds-page-buttons .ds-code-caption", ~s(variant="primary"))
      assert has_element?(view, "#ds-page-buttons .ds-code-caption", ~s(variant="danger"))
    end
  end

  describe "badges page" do
    test "renders at least three route badges", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/badges")

      badges =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s(#ds-page-badges span[style^="background-color:"]))
        |> Enum.count()

      assert badges >= 3
    end

    test "applies each sample route's colors to its badge", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/badges")

      assert has_element?(
               view,
               ~s(#ds-page-badges span[style="background-color: #D32F2F; color: #FFFFFF"]),
               "42"
             )

      assert has_element?(
               view,
               ~s(#ds-page-badges span[style="background-color: #1976D2; color: #FFFFFF"]),
               "A"
             )

      assert has_element?(
               view,
               ~s(#ds-page-badges span[style="background-color: #43A047; color: #000000"]),
               "7X"
             )
    end

    test "falls back to an em dash for a route with no short name", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/badges")

      assert has_element?(
               view,
               ~s(#ds-page-badges span[style="background-color: #9E9E9E; color: #FFFFFF"]),
               "—"
             )
    end
  end

  describe "inputs page" do
    test "renders text, select, textarea, and checkbox inputs inside the demo form", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/inputs")

      assert has_element?(view, ~s(#ds-inputs-demo-form input#demo_name[type="text"]))
      assert has_element?(view, "#ds-inputs-demo-form select#demo_kind")
      assert has_element?(view, "#ds-inputs-demo-form textarea#demo_notes")
      assert has_element?(view, ~s(#ds-inputs-demo-form input#demo_active[type="checkbox"]))
    end

    test "names each demo input under the demo form scope", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/inputs")

      assert has_element?(view, ~s(#ds-inputs-demo-form input[name="demo[name]"]))
      assert has_element?(view, ~s(#ds-inputs-demo-form select[name="demo[kind]"]))
      assert has_element?(view, ~s(#ds-inputs-demo-form textarea[name="demo[notes]"]))
    end

    test "renders the select prompt and both options", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/inputs")

      assert has_element?(view, ~s(#demo_kind option[value="bus"]), "Bus")
      assert has_element?(view, ~s(#demo_kind option[value="rail"]), "Rail")
    end

    test "carries exactly one form on the page and it is the demo form", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/inputs")

      forms =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#ds-page-inputs form")

      assert Enum.count(forms) == 1
      assert forms |> LazyHTML.attribute("id") == ["ds-inputs-demo-form"]
    end

    test "renders the checkbox_group fieldset with its legend and options", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/inputs")

      assert has_element?(view, "#ds-page-inputs fieldset legend", "Roles")

      assert has_element?(
               view,
               ~s(#ds-page-inputs fieldset input[type="checkbox"][value="admin"])
             )

      assert has_element?(
               view,
               ~s(#ds-page-inputs fieldset input[type="checkbox"][value="editor"])
             )
    end

    test "renders the forced error message on the error-state input", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/inputs")

      assert has_element?(view, "#ds-page-inputs p.text-error", "can't be blank")
      assert has_element?(view, "#ds-page-inputs input#demo_name_error.input-error")
    end

    # The error example reuses the :name field, so it must carry a distinct id or the
    # page would emit two elements with id="demo_name".
    test "gives the error-state input a distinct id from the plain name input", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/inputs")

      ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#ds-page-inputs [id]")
        |> LazyHTML.attribute("id")

      assert Enum.count(ids, &(&1 == "demo_name")) == 1
      assert Enum.count(ids, &(&1 == "demo_name_error")) == 1
      assert ids == Enum.uniq(ids)
    end

    # INV-4: an unhandled phx-* event from a demo crashes the LiveView for every page.
    test "submitting the demo form does not crash the LiveView", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/inputs")

      view
      |> form("#ds-inputs-demo-form", demo: %{name: "Route 42", kind: "bus", notes: "hello"})
      |> render_submit()

      assert has_element?(view, "#ds-page-inputs")
      assert has_element?(view, "#ds-inputs-demo-form")
    end
  end

  describe "page bodies" do
    for %{slug: slug, title: title} <- GtfsPlannerWeb.Design.DesignSystemLive.pages() do
      test "renders the #{slug} page body", %{conn: conn, user: user} do
        conn = log_in_user(conn, user)

        {:ok, view, _html} = live(conn, ~p"/design/#{unquote(slug)}")

        assert has_element?(view, "#design-page-content #ds-page-#{unquote(slug)}")
        assert has_element?(view, "#ds-page-#{unquote(slug)}", unquote(title))
      end
    end
  end
end
