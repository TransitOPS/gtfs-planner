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

  # The demo route rows the tables page renders. Pinned here so the page cannot
  # quietly lose a row.
  @sample_route_rows [
    {"7", "Crosstown Local", "Active"},
    {"42", "Airport Express", "Active"},
    {"108", "Night Owl", "Suspended"},
    {"231", "Harbor Shuttle", "Draft"}
  ]

  # Every custom event any demo on any page can emit. DesignSystemLive owns a
  # handle_event clause for each; an unhandled event crashes the LiveView.
  @handled_events ~w(demo_form_submit paginate open_drawer close_drawer)

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

  describe "tables page" do
    for {id, name, status} <- @sample_route_rows do
      test "renders the #{name} sample row", %{conn: conn, user: user} do
        conn = log_in_user(conn, user)

        {:ok, view, _html} = live(conn, ~p"/design/tables")

        row =
          view
          |> render()
          |> LazyHTML.from_fragment()
          |> LazyHTML.query("#ds-demo-table tr")
          |> Enum.map(&LazyHTML.text/1)
          |> Enum.find(&String.contains?(&1, unquote(name)))

        assert row, "no row containing #{unquote(name)}"
        assert String.contains?(row, unquote(id))
        assert String.contains?(row, unquote(status))
      end
    end

    test "renders exactly the sample rows in a real table body", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/tables")

      assert has_element?(view, "#ds-page-tables table.table tbody#ds-demo-table")

      rows =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#ds-demo-table tr")

      assert Enum.count(rows) == length(@sample_route_rows)
    end

    test "labels every column header, including the screen-reader action header", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/tables")

      headers =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#ds-page-tables table.table thead th")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert headers == ["ID", "Name", "Status", "Actions"]
    end

    # table-row-design.md: numbers right-aligned with tabular numerals so digits line up.
    test "right-aligns the numeric id column with tabular numerals", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/tables")

      assert has_element?(view, "#ds-demo-table td div.text-right.tabular-nums", "108")
    end

    # table-row-design.md: status is colour + text, never colour alone.
    test "pairs each status colour with its status text", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/tables")

      assert has_element?(view, "#ds-demo-table td span.text-success", "Active")
      assert has_element?(view, "#ds-demo-table td span.text-warning", "Suspended")
    end

    test "renders the definition list as a real ul.list of titled pairs", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/tables")

      assert has_element?(view, "#ds-page-tables ul.list")

      items =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#ds-page-tables ul.list li.list-row")

      assert Enum.count(items) == 3
    end

    test "shows the initial pagination range", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/tables")

      assert has_element?(view, "#ds-pagination-demo", "Showing 1–10 of 45")
    end

    test "disables Previous on the first page and leaves Next clickable", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/tables")

      assert has_element?(view, "#ds-pagination-demo button[disabled]", "Previous")
      refute has_element?(view, "#ds-pagination-demo button[disabled]", "Next")
    end

    # Drives the real DOM contract: <.pagination> hardcodes phx-click="paginate" and
    # sends phx-value-page as a string.
    test "advances the range when Next is clicked", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/tables")

      view
      |> element("#ds-pagination-demo button", "Next")
      |> render_click()

      assert has_element?(view, "#ds-pagination-demo", "Showing 11–20 of 45")
      refute has_element?(view, "#ds-pagination-demo button[disabled]", "Previous")
    end

    test "steps back to the first page when Previous is clicked", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/tables")

      view |> element("#ds-pagination-demo button", "Next") |> render_click()
      view |> element("#ds-pagination-demo button", "Previous") |> render_click()

      assert has_element?(view, "#ds-pagination-demo", "Showing 1–10 of 45")
    end

    # The clamp ceiling in DesignSystemLive and the total/per_page rendered by the page
    # are declared in different modules; this pins them to the same demo range.
    test "clamps a page above the demo range to the last page", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/tables")

      render_click(view, "paginate", %{"page" => "99"})

      assert has_element?(view, "#ds-pagination-demo", "Showing 41–45 of 45")
      assert has_element?(view, "#ds-pagination-demo button[disabled]", "Next")
    end

    test "clamps a page below the first page to page one", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/tables")

      render_click(view, "paginate", %{"page" => "0"})

      assert has_element?(view, "#ds-pagination-demo", "Showing 1–10 of 45")
    end

    # INV-4: a demo event must never crash the LiveView, including for a page value no
    # <.pagination> button would emit.
    test "falls back to the first page for a non-numeric page value", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/tables")

      render_click(view, "paginate", %{"page" => "not-a-page"})

      assert has_element?(view, "#ds-pagination-demo", "Showing 1–10 of 45")
    end
  end

  describe "feedback page" do
    # AC-12: both flash examples resolve inside the demo container rather than escaping
    # it as a fixed-position toast.
    test "renders the info and error flash examples inside the demo container", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/feedback")

      assert has_element?(view, "#ds-flash-demo #ds-flash-info", "Sample info message")
      assert has_element?(view, "#ds-flash-demo #ds-flash-error", "Sample error message")
    end

    # The examples must be the real <.flash>, not replica markup: these classes and the
    # role come from core_components.ex and are what the page documents.
    test "renders each example as the real flash component", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/feedback")

      assert has_element?(view, ~s(#ds-flash-info[role="alert"] .alert.alert-info))
      assert has_element?(view, ~s(#ds-flash-error[role="alert"] .alert.alert-error))
    end

    # The containment rule is `#ds-flash-demo .toast { position: static; }`. CSS is not
    # observable from a LiveView test, so this pins the rule's DOM anchor: if <.flash>
    # ever stopped emitting `toast`, or an example moved out of the container, the
    # scoped rule would silently stop containing anything.
    test "keeps every toast root inside the containment container", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/feedback")

      document =
        view
        |> render()
        |> LazyHTML.from_fragment()

      contained = document |> LazyHTML.query("#ds-flash-demo .toast") |> Enum.count()
      on_page = document |> LazyHTML.query("#ds-page-feedback .toast") |> Enum.count()

      assert contained == 2
      assert on_page == contained
    end

    # Hazard: <.flash> defaults its id to "flash-#{kind}", which are the ids the layout's
    # real flash_group uses. Dropping the explicit id would collide with them.
    test "gives the examples ids distinct from the layout's real flash ids", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/feedback")

      refute has_element?(view, "#ds-page-feedback #flash-info")
      refute has_element?(view, "#ds-page-feedback #flash-error")

      ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#ds-page-feedback [id]")
        |> LazyHTML.attribute("id")

      assert ids == Enum.uniq(ids)
    end

    test "renders the loading-variants sample button and caption", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/feedback")

      assert has_element?(view, "#ds-loading-demo button.btn", "Save changes")
      assert has_element?(view, "#ds-page-feedback .ds-code-caption", "phx-click-loading")
      assert has_element?(view, "#ds-page-feedback .ds-code-caption", "phx-submit-loading")
    end

    # The loading state is demonstrated statically, by applying the class LiveView would
    # add, rather than by fabricating a slow round trip.
    test "shows the loading state with the class applied literally beside an idle button", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/feedback")

      buttons =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#ds-loading-demo button")
        |> LazyHTML.attribute("class")
        |> Enum.map(&String.split(&1, " ", trim: true))

      assert Enum.count(buttons) == 2
      assert Enum.count(buttons, &("phx-click-loading" in &1)) == 1
      assert Enum.all?(buttons, &("phx-click-loading:opacity-60" in &1))
    end

    # The demo emits no custom event: <.flash>'s root pushes the built-in
    # `lv:clear-flash`, which LiveView handles internally. The examples render from their
    # inner block, so dismissing one does not remove it.
    test "dismissing a flash example does not crash the LiveView", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/feedback")

      view |> element("#ds-flash-info") |> render_click()

      assert has_element?(view, "#ds-flash-demo #ds-flash-info", "Sample info message")
      assert has_element?(view, "#ds-flash-demo #ds-flash-error", "Sample error message")
    end
  end

  describe "navigation page" do
    # AC-13: the real <.header> with all three slots, not replica markup.
    test "renders the header title, subtitle, and actions slot", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/navigation")

      assert has_element?(view, "#ds-header-demo header h1", "Station detail")
      assert has_element?(view, "#ds-header-demo header p", "GTFS version 2026-01")
      assert has_element?(view, "#ds-header-demo header button.btn", "Edit station")
    end

    # AC-13: both sub-navs render from plain sample maps. The station nav roots at the
    # id core_components.ex:811 hardcodes; the route nav has no id, so it is addressed
    # by its aria-label (`:1013`).
    test "renders both sub-nav root elements from the sample data", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/navigation")

      assert has_element?(view, "#ds-page-navigation nav#station-sub-nav", "Demo Central")

      assert has_element?(
               view,
               ~s(#ds-page-navigation nav[aria-label="Route navigation"]),
               "42 - Crosstown"
             )
    end

    # Hazard: the :diagram tab renders level/upload controls that emit open_add_level,
    # open_edit_level, open_naming_drawer, and upload_diagram — events the styleguide
    # must never wire (INV-4). Pinning the active tab keeps them unrendered.
    test "keeps the station sub-nav on the details tab", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/navigation")

      # HEEx renders `aria-selected={true}` as a valueless attribute, so the marked tab
      # is `[aria-selected]`, never `[aria-selected="true"]`.
      assert has_element?(
               view,
               ~s(#station-sub-nav a[role="tab"][aria-current="page"]),
               "Details"
             )

      assert has_element?(view, ~s(#station-sub-nav a[role="tab"][aria-selected]), "Details")

      refute has_element?(view, "#diagram-upload-form-sub-nav")
      refute has_element?(view, "#station-sub-nav-upload")
    end

    # INV-4: an unhandled event crashes the LiveView for every page. On :details both
    # sub-navs are links only, so this page's event surface must be empty.
    test "emits no client events", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/navigation")

      assert emitted_events(view, "#ds-page-navigation") == []
    end
  end

  describe "overlays page" do
    # AC-14: the drawer is fixed-position with a full-screen overlay, so an
    # open-by-default demo would cover the page.
    test "renders the drawer closed by default inside the demo container", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/overlays")

      assert has_element?(view, "#ds-drawer-demo aside#ds-demo-drawer")
      assert "translate-x-full" in drawer_class_list(view)
      refute "translate-x-0" in drawer_class_list(view)
    end

    test "opening the drawer from the trigger gives it the open-state class", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/overlays")

      view
      |> element("#ds-drawer-demo button[phx-click='open_drawer']", "Open drawer")
      |> render_click()

      assert "translate-x-0" in drawer_class_list(view)
      refute "translate-x-full" in drawer_class_list(view)
    end

    test "pushing close_drawer returns the drawer to the closed state", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/overlays")

      view |> element("#ds-drawer-demo button[phx-click='open_drawer']") |> render_click()
      assert "translate-x-0" in drawer_class_list(view)

      render_click(view, "close_drawer", %{})

      assert "translate-x-full" in drawer_class_list(view)
      refute "translate-x-0" in drawer_class_list(view)
    end

    # The drawer's own close button emits on_close, which defaults to "close_drawer"
    # (core_components.ex:706). This drives the real component's control rather than
    # pushing the event name directly.
    test "the drawer's close button closes it through the real component", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/overlays")

      view |> element("#ds-drawer-demo button[phx-click='open_drawer']") |> render_click()

      view |> element("#ds-demo-drawer button[phx-click='close_drawer']") |> render_click()

      assert "translate-x-full" in drawer_class_list(view)
    end

    # INV-4: every event this page can emit must have a handler in DesignSystemLive.
    # The drawer contributes two close_drawer emitters — the overlay (`:721`) and the
    # header close button (`:745`).
    test "emits only events the LiveView handles", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/overlays")

      events = emitted_events(view, "#ds-page-overlays")

      assert Enum.sort(Enum.uniq(events)) == ["close_drawer", "open_drawer"]
      assert Enum.all?(events, &(&1 in @handled_events))
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

  # The drawer's open/closed state is carried by the class list on its aside
  # (core_components.ex:728-729), so the state assertions read that list directly.
  defp drawer_class_list(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#ds-drawer-demo aside#ds-demo-drawer")
    |> LazyHTML.attribute("class")
    |> Enum.flat_map(&String.split(&1, " ", trim: true))
  end

  # Every custom event the rendered page can push from a click, in DOM order.
  defp emitted_events(view, scope) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{scope} [phx-click]")
    |> LazyHTML.attribute("phx-click")
  end
end
