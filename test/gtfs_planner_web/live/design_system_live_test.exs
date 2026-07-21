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

  # Every word `#ds-status-badge-demo` renders, in page order. Pinned independently
  # of core_components.ex: the vocabulary is the contract the normative pages
  # document, so the test must fail if either side drifts.
  @status_demo_words [
    "Pass",
    "Completed",
    "Running",
    "In progress",
    "Info",
    "Warning",
    "Failed",
    "Error",
    "Started",
    "Draft",
    "Active",
    "Deactivated",
    "Invitation pending",
    "Unknown"
  ]

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
  @handled_events ~w(
    demo_form_submit paginate open_drawer close_drawer
    open_confirm cancel_confirm run_confirm confirm_success confirm_error
    live_select_change change address-form live_select_blur
    save_location delete_location count_strip_filter
  )

  # The one geocoding result every autocomplete test searches for. Mirrors the shape
  # GtfsPlanner.Geocoding.autocomplete/2 returns from the real Geoapify adapter.
  @regent %GtfsPlanner.Geocoding.Result{
    formatted_address: "Regent Street, London, UK",
    lat: 51.5105,
    lon: -0.1367,
    country: "UK",
    state: "England",
    city: "London"
  }

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

    test "renders all three group headings", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/introduction")

      assert has_element?(view, "#design-sidebar", "Foundations")
      assert has_element?(view, "#design-sidebar", "Components")
      assert has_element?(view, "#design-sidebar", "Proposals")
    end

    test "orders Foundations, Components, Proposals", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/introduction")

      headings =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#design-sidebar h2")
        |> LazyHTML.text()

      assert headings == "FoundationsComponentsProposals"
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

    test "renders the diagram palette production contract", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/colors")

      assert has_element?(view, "#ds-diagram-palette-demo")
      assert has_element?(view, "#ds-diagram-palette-demo [data-diagram-role=\"active_stop\"]")
      assert has_element?(view, "#ds-diagram-palette-demo", "--diagram-label-halo")
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
    test "renders route badges with validated inline styles", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/badges")

      assert has_element?(
               view,
               ~s(#ds-page-badges span[style="background-color: #D32F2F; color: #FFFFFF"]),
               "42"
             )
    end

    test "corrects low-contrast foreground to black", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/badges")

      assert has_element?(
               view,
               ~s(#ds-page-badges span[style="background-color: #FFFF00; color: #000000"]),
               "A"
             )
    end

    test "renders neutral treatment for invalid background without inline style", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/badges")

      html = render(view)
      assert html =~ "7X"
      refute html =~ "ZZZZZZ"
    end

    test "falls back to route ID when short name is missing", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/badges")

      assert has_element?(view, "#ds-page-badges span", "R-99")
    end

    test "renders known and unknown status badges", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/badges")

      assert has_element?(view, "#ds-status-badge-demo", "Pass")
      assert has_element?(view, "#ds-status-badge-demo", "In progress")
      assert has_element?(view, "#ds-status-badge-demo", "Unknown")
    end

    test "renders the transit presentation production contracts", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/badges")

      assert has_element?(view, "#ds-transit-presentation-demo")

      assert has_element?(
               view,
               "#ds-transit-presentation-demo [data-accessibility=\"accessible\"]"
             )

      assert has_element?(view, "#ds-transit-presentation-demo [data-pathway-summary]")
    end
  end

  describe "counts page" do
    test "renders the display-only report vocabulary as non-buttons", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/counts")

      assert has_element?(view, "#ds-count-strip-report[data-mode=\"display\"]")
      assert has_element?(view, "#ds-count-strip-report-item-stops", "Stops")
      assert has_element?(view, "#ds-count-strip-report-item-stops", "128")
      assert has_element?(view, "#ds-count-strip-report-item-missing_coordinates", "3")
      refute has_element?(view, "#ds-count-strip-report button")
      refute has_element?(view, "#ds-count-strip-report [aria-pressed]")
    end

    test "renders a zero display count without inventing a label", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/counts")

      assert has_element?(view, "#ds-count-strip-report-item-unreachable_platforms", "0")
    end

    test "renders the filter vocabulary as buttons with explicit pressed state", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/counts")

      assert has_element?(view, "#ds-count-strip-history[data-mode=\"filter\"]")

      assert has_element?(
               view,
               "#ds-count-strip-history button#ds-count-strip-history-item-name[aria-pressed=\"true\"]"
             )

      assert has_element?(
               view,
               "#ds-count-strip-history-item-location[aria-pressed=\"false\"]"
             )

      assert has_element?(
               view,
               "#ds-count-strip-history-item-signposted_as[aria-pressed=\"false\"]"
             )
    end

    test "renders a long filter label in full", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/counts")

      assert has_element?(
               view,
               "#ds-count-strip-history-item-signposted_as",
               "Parent station and pathway signposted name"
             )
    end

    test "marks the zero-count filter item aria-disabled while keeping it focusable", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/counts")

      selector = "#ds-count-strip-history-item-wheelchair_boarding"

      assert has_element?(view, "#{selector}[aria-disabled=\"true\"]")
      refute has_element?(view, "#{selector}[disabled]")
      refute has_element?(view, "#{selector}[tabindex]")
      assert has_element?(view, selector, "No changes in this version")
    end

    test "selecting an available key presses exactly that button", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/counts")

      view |> element("#ds-count-strip-history-item-location") |> render_click()

      assert has_element?(view, "#ds-count-strip-history-item-location[aria-pressed=\"true\"]")
      assert has_element?(view, "#ds-count-strip-history-item-name[aria-pressed=\"false\"]")
      assert has_element?(view, "#ds-count-strip-filter-outcome", "Location")
    end

    test "a zero-count click is dispatched but produces no accepted selection", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/counts")

      view |> element("#ds-count-strip-history-item-location") |> render_click()
      view |> element("#ds-count-strip-history-item-wheelchair_boarding") |> render_click()

      assert has_element?(
               view,
               "#ds-count-strip-history-item-wheelchair_boarding[aria-pressed=\"false\"]"
             )

      assert has_element?(view, "#ds-count-strip-history-item-location[aria-pressed=\"true\"]")
      assert has_element?(view, "#ds-count-strip-filter-outcome", "Ignored")
    end

    test "an unknown key is rejected by the consumer handler", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/counts")

      render_click(view, "count_strip_filter", %{"key" => "not_a_field"})

      assert has_element?(view, "#ds-count-strip-filter-outcome", "Ignored")
      assert has_element?(view, "#ds-count-strip-history-item-name[aria-pressed=\"true\"]")
      refute has_element?(view, "#ds-count-strip-history-item-not_a_field")
    end

    test "documents that the consumer owns labels, counts, and rejection", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/counts")

      assert has_element?(view, "#ds-page-counts", "They never calculate counts")
      assert has_element?(view, "#ds-page-counts", "reject unknown or zero-count keys")
    end

    test "emits only events the LiveView handles", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/counts")

      events = emitted_events(view, "#ds-page-counts")

      assert "count_strip_filter" in events
      assert Enum.all?(events, &(&1 in @handled_events))
    end
  end

  describe "version diff page" do
    setup %{conn: conn} do
      user = user_fixture()
      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/design/version-diff")
      %{view: view}
    end

    test "documents every action and status as a word, not a color", %{view: view} do
      for word <- ~w(Added Modified Removed Conflict) do
        assert has_element?(view, "[data-role='version-diff-action']", word)
      end

      for word <- ~w(Applied Pending Rejected Failed) do
        assert has_element?(view, "[data-role='version-diff-status']", word)
      end
    end

    test "shows a long value complete and false, zero and nil as themselves", %{view: view} do
      html = render(view)

      assert html =~ "Kendall/MIT Northbound Platform Upper Mezzanine Entrance Alpha"

      values =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#ds-version-diff-modify [data-role='version-diff-after']")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert "0" in values
      assert "nil" in values
      assert "false" in values
    end

    test "shows a human label beside its raw source key", %{view: view} do
      assert has_element?(view, "[data-role='version-diff-change-label']", "Stop name")
      assert has_element?(view, "[data-role='version-diff-change-key']", "stop_name")
    end

    test "documents that the caller owns the vocabulary and that values are never cut",
         %{view: view} do
      assert has_element?(view, "#ds-page-version-diff", "Never pre-truncate a value")
      assert has_element?(view, "#ds-page-version-diff", "The row never invents an action")
    end

    test "a collapsed row keeps its values in the document but hidden", %{view: view} do
      assert has_element?(
               view,
               "#ds-version-diff-conflict [data-role='version-diff-changes'][hidden]"
             )
    end

    test "emits no event the LiveView does not handle", %{view: view} do
      assert Enum.all?(emitted_events(view, "#ds-page-version-diff"), &(&1 in @handled_events))
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

    test "renders the shared upload and segmented-control contracts on the Components route", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/inputs")

      assert has_element?(
               view,
               "#ds-upload-field-demo input[type='file'][aria-labelledby='ds-component-upload-label']"
             )

      assert has_element?(view, "#ds-segmented-control-demo #ds-component-mode")

      assert has_element?(
               view,
               "#ds-component-mode input[name='component_mode'][value='map'][disabled]"
             )

      assert has_element?(view, "#ds-component-mode-option-map-reason", "Upload a diagram first")
    end

    test "handles native segmented-control changes without a focus-push side effect", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/inputs")

      view
      |> form("#ds-component-mode-form", component_mode: "list")
      |> render_change()

      assert has_element?(view, "#ds-component-mode input[value='list'][checked]")
      refute has_element?(view, "#ds-component-mode [phx-focus]")
    end

    test "keeps the standalone segmented-control form separate from the input demo form", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/inputs")

      forms =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#ds-page-inputs form")

      assert Enum.count(forms) == 2

      assert forms |> LazyHTML.attribute("id") == [
               "ds-inputs-demo-form",
               "ds-component-mode-form"
             ]
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

    test "documents the repaired error contract", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/inputs")

      assert has_element?(view, "#ds-inputs-error-contract")

      contract_text =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#ds-inputs-error-contract")
        |> LazyHTML.text()
        |> String.replace(~r/\s+/, " ")

      assert contract_text =~ "aria-describedby"
      assert contract_text =~ "aria-invalid"
      assert contract_text =~ "deterministic"
    end
  end

  describe "tables page" do
    test "documents the production version-diff row contract in responsive desktop and mobile structure",
         %{
           conn: conn,
           user: user
         } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/tables")

      assert has_element?(view, "#ds-version-diff-row-demo [data-version-diff-row]")
      assert has_element?(view, "#ds-version-diff-row-demo [class*='sm:grid']")
      assert has_element?(view, "#ds-version-diff-row-demo [aria-controls$='-details']")
      assert has_element?(view, "#ds-version-diff-row-demo #ds-version-diff-row-action.min-h-11")

      assert has_element?(view, "#ds-page-tables", "TransitPresentation.version_diff_row")
      assert has_element?(view, "#ds-page-tables", "Consumer owns actions and disclosure state")
    end

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
        |> LazyHTML.query("#ds-demo-table-wrapper thead th")
        # The ID column carries a sort indicator, so strip the arrow glyph to compare labels.
        |> Enum.map(
          &(&1
            |> LazyHTML.text()
            |> String.replace(["▲", "▼", "↕"], "")
            |> String.trim())
        )

      assert headers == ["ID", "Name", "Status", "Actions"]
    end

    # table-row-design.md: numbers right-aligned with tabular numerals so digits line up.
    test "right-aligns the numeric id column with tabular numerals", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/tables")

      assert has_element?(view, "#ds-demo-table td.text-right span.tabular-nums", "108")
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

    # The examples must be the real <.flash>, not replica markup: these classes come from
    # core_components.ex and are what the page documents.
    test "renders each example as the real flash component", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/feedback")

      assert has_element?(view, ~s(#ds-flash-info .alert.alert-info))
      assert has_element?(view, ~s(#ds-flash-error .alert.alert-error))
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
    # The close button is the only element that dismisses the flash. Clicking it sends
    # `lv:clear-flash`, which LiveView handles internally. The examples render from their
    # inner block, so dismissing one does not remove it.
    test "dismissing a flash example does not crash the LiveView", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/feedback")

      view |> element("#ds-flash-info button[aria-label='Dismiss message']") |> render_click()

      assert has_element?(view, "#ds-flash-demo #ds-flash-info", "Sample info message")
      assert has_element?(view, "#ds-flash-demo #ds-flash-error", "Sample error message")
    end

    # AC-7: the administration membership states are documented on the normative
    # page, so a consumer reads them from the design system instead of inventing
    # a local badge.
    test "documents the administration membership statuses", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/feedback")

      assert has_element?(view, "#ds-status-badge-demo", "Active")
      assert has_element?(view, "#ds-status-badge-demo", "Deactivated")
      assert has_element?(view, "#ds-status-badge-demo", "Invitation pending")
    end

    # C-007: the normative example is the whole vocabulary, in order. Pinned here
    # independently of core_components.ex so that adding a status to one side
    # without the other fails.
    test "renders the full status vocabulary in one demo", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/feedback")

      assert demo_status_words(render(view)) == @status_demo_words
    end
  end

  # C-007: the two normative status demos document one vocabulary. If a status is
  # added to either page alone, the pages disagree about what the app can say.
  describe "status vocabulary synchronization" do
    test "badges and feedback pages render the same status vocabulary", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, badges_view, _html} = live(conn, ~p"/design/badges")
      {:ok, feedback_view, _html} = live(conn, ~p"/design/feedback")

      assert demo_status_words(render(badges_view)) == demo_status_words(render(feedback_view))
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

      assert has_element?(view, "#ds-page-navigation #station-sub-nav", "Demo Central")

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

      assert has_element?(
               view,
               ~s(#station-sub-nav a[aria-current="page"]),
               "Details"
             )

      refute has_element?(view, ~s(#station-sub-nav [role="tablist"]))
      refute has_element?(view, ~s(#station-sub-nav [role="tab"]))

      refute has_element?(view, "#diagram-upload-form-sub-nav")
      refute has_element?(view, "#station-sub-nav-upload")
    end

    test "documents long-content wrapping and ordinary nav semantics", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/navigation")

      assert has_element?(view, "#ds-page-navigation", "break-words")
      assert has_element?(view, "#ds-page-navigation", "min-h-11")
      assert has_element?(view, "#ds-page-navigation", ~s(aria-current="page"))
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
    test "renders the drawer closed by default with inert and aria-hidden", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/overlays")

      assert has_element?(view, "dialog#ds-demo-drawer-overlay[data-open='false']")
      assert has_element?(view, "dialog#ds-demo-drawer-overlay[inert]")
      assert has_element?(view, "dialog#ds-demo-drawer-overlay[aria-hidden='true']")
      assert has_element?(view, "#ds-drawer-demo aside#ds-demo-drawer")
    end

    test "opening the drawer sets data-open=true and applies role=dialog", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/overlays")

      view
      |> element("#ds-drawer-demo button[phx-click='open_drawer']", "Open drawer")
      |> render_click()

      assert has_element?(view, "dialog#ds-demo-drawer-overlay[data-open='true']")
      assert has_element?(view, "dialog#ds-demo-drawer-overlay[role='dialog']")
      assert has_element?(view, "dialog#ds-demo-drawer-overlay[aria-modal='true']")
      refute has_element?(view, "dialog#ds-demo-drawer-overlay[inert]")
    end

    test "closing the drawer sets data-open=false and restores inert", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/overlays")

      view |> element("#ds-drawer-demo button[phx-click='open_drawer']") |> render_click()
      assert has_element?(view, "dialog#ds-demo-drawer-overlay[data-open='true']")

      render_click(view, "close_drawer", %{})

      assert has_element?(view, "dialog#ds-demo-drawer-overlay[data-open='false']")
      assert has_element?(view, "dialog#ds-demo-drawer-overlay[inert]")
    end

    test "the drawer's close button closes it through the real component", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/overlays")

      view |> element("#ds-drawer-demo button[phx-click='open_drawer']") |> render_click()

      view |> element("#ds-demo-drawer-close") |> render_click()

      assert has_element?(view, "dialog#ds-demo-drawer-overlay[data-open='false']")
    end

    test "the close button has data-dialog-dismiss and aria-label", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/overlays")

      assert has_element?(view, "#ds-demo-drawer-close[data-dialog-dismiss]")
      assert has_element?(view, "#ds-demo-drawer-close[aria-label]")
    end

    test "opening the confirmation from the drawer does not close the drawer", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/overlays")

      view |> element("#ds-drawer-demo button[phx-click='open_drawer']") |> render_click()
      view |> element("button[phx-click='open_confirm']") |> render_click()

      assert has_element?(view, "dialog#ds-demo-drawer-overlay[data-open='true']")
      assert has_element?(view, "dialog#ds-demo-confirm[data-open='true']")
      assert has_element?(view, "dialog#ds-demo-confirm[role='alertdialog']")
    end

    test "cancelling the confirmation closes it but leaves the drawer open", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/overlays")

      view |> element("#ds-drawer-demo button[phx-click='open_drawer']") |> render_click()
      view |> element("button[phx-click='open_confirm']") |> render_click()

      render_click(view, "cancel_confirm", %{})

      assert has_element?(view, "dialog#ds-demo-drawer-overlay[data-open='true']")
      assert has_element?(view, "dialog#ds-demo-confirm[data-open='false']")
    end

    test "confirmation success closes child and shows result in still-open drawer", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/overlays")

      view |> element("#ds-drawer-demo button[phx-click='open_drawer']") |> render_click()
      view |> element("button[phx-click='open_confirm']") |> render_click()
      view |> element("#ds-demo-confirm-confirm") |> render_click()
      view |> element("button[phx-click='confirm_success']") |> render_click()

      assert has_element?(view, "dialog#ds-demo-drawer-overlay[data-open='true']")
      assert has_element?(view, "dialog#ds-demo-confirm[data-open='false']")

      assert has_element?(
               view,
               "dialog#ds-demo-confirm[data-return-focus-id='ds-confirm-result']"
             )

      assert has_element?(view, "#ds-confirm-result", "Route deleted successfully.")
    end

    test "non-success confirmation events clear a prior return-focus override", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/overlays")

      render_click(view, "confirm_success", %{})

      assert has_element?(
               view,
               "dialog#ds-demo-confirm[data-return-focus-id='ds-confirm-result']"
             )

      render_click(view, "open_confirm", %{})
      refute has_element?(view, "dialog#ds-demo-confirm[data-return-focus-id]")

      render_click(view, "confirm_success", %{})
      render_click(view, "cancel_confirm", %{})
      refute has_element?(view, "dialog#ds-demo-confirm[data-return-focus-id]")

      render_click(view, "confirm_success", %{})
      render_click(view, "confirm_error", %{})
      refute has_element?(view, "dialog#ds-demo-confirm[data-return-focus-id]")
    end

    test "confirmation pending disables confirm and dismiss controls", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/overlays")

      view |> element("#ds-drawer-demo button[phx-click='open_drawer']") |> render_click()
      view |> element("button[phx-click='open_confirm']") |> render_click()
      view |> element("#ds-demo-confirm-confirm") |> render_click()

      assert has_element?(view, "#ds-demo-confirm-confirm[disabled]")
      assert has_element?(view, "#ds-demo-confirm-cancel[disabled]")
      assert has_element?(view, "dialog#ds-demo-confirm[data-pending='true']")
      assert has_element?(view, "#ds-demo-confirm-confirm", "Deleting…")
    end

    test "confirmation error clears pending in place", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/overlays")

      view |> element("#ds-drawer-demo button[phx-click='open_drawer']") |> render_click()
      view |> element("button[phx-click='open_confirm']") |> render_click()
      view |> element("#ds-demo-confirm-confirm") |> render_click()
      view |> element("button[phx-click='confirm_error']") |> render_click()

      assert has_element?(view, "dialog#ds-demo-confirm[data-open='true']")
      assert has_element?(view, "dialog#ds-demo-confirm[data-pending='false']")
      refute has_element?(view, "#ds-demo-confirm-confirm[disabled]")
      refute has_element?(view, "#ds-demo-confirm-cancel[disabled]")
      assert has_element?(view, "#ds-demo-confirm-confirm", "Delete route")
    end

    test "emits only events the LiveView handles", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/overlays")

      events =
        view
        |> emitted_events("#ds-page-overlays")
        |> Enum.reject(&String.starts_with?(&1, "["))

      handled =
        Enum.sort(Enum.uniq(events))

      assert "close_drawer" in handled
      assert "open_drawer" in handled
      assert "open_confirm" in handled
      assert Enum.all?(events, &(&1 in @handled_events))
    end
  end

  # Ported from the retired GtfsPlannerWeb.ComponentsLiveTest. GtfsPlanner.GeocodingMock
  # (config/test.exs:26) fakes only the final external boundary — the Geoapify HTTP
  # call. Everything between the router and Geocoding.autocomplete/2 is production code.
  describe "autocomplete page" do
    # INV-5: these two ids are the contract the demo carries over from /components.
    test "renders the address form and the LiveSelect field", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/autocomplete")

      assert has_element?(view, "#ds-page-autocomplete form#address-form")
      assert has_element?(view, "#ds-page-autocomplete #address_autocomplete")
    end

    test "does not display a selected location initially", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/autocomplete")

      refute has_element?(view, "#ds-page-autocomplete h3", "Selected Location")
      refute has_element?(view, "#ds-page-autocomplete dt", "Address")
      refute has_element?(view, "#ds-page-autocomplete dt", "Latitude")
      refute has_element?(view, "#ds-page-autocomplete dt", "Longitude")
    end

    test "updates on address selection", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/autocomplete")

      refute has_element?(view, "#ds-page-autocomplete dt", "Address")

      Mox.expect(GtfsPlanner.GeocodingMock, :autocomplete, fn "Regent", _opts ->
        {:ok, [@regent]}
      end)

      render_hook(view, "live_select_change", %{
        "text" => "Regent",
        "id" => "address_autocomplete"
      })

      render_change(view, "address-form", %{
        "address_search" => %{"address_autocomplete" => "Regent Street, London, UK"}
      })

      assert has_element?(view, "#ds-page-autocomplete dt", "Address")
      assert has_element?(view, "#ds-page-autocomplete dd", "Regent Street, London, UK")
      assert has_element?(view, "#ds-page-autocomplete dd", "51.5105")
      assert has_element?(view, "#ds-page-autocomplete dd", "-0.1367")
    end

    test "applies selection from live_select_change string-keyed payload", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/autocomplete")

      render_hook(view, "live_select_change", %{
        "text" => "Regent",
        "id" => "address_autocomplete",
        "field" => "address_search[address_autocomplete]",
        "selection" => %{
          "tag" => %{
            "formatted_address" => "Regent Street, London, UK",
            "lat" => 51.5105,
            "lon" => -0.1367,
            "country" => "UK",
            "state" => "England",
            "city" => "London"
          }
        }
      })

      assert has_element?(view, "#ds-page-autocomplete dt", "Address")
      assert has_element?(view, "#ds-page-autocomplete dd", "Regent Street, London, UK")
    end

    test "unmatched non-empty input clears selected state", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/autocomplete")

      Mox.expect(GtfsPlanner.GeocodingMock, :autocomplete, fn "Regent", _opts ->
        {:ok, [@regent]}
      end)

      render_hook(view, "live_select_change", %{
        "text" => "Regent",
        "id" => "address_autocomplete"
      })

      render_change(view, "address-form", %{
        "address_search" => %{"address_autocomplete" => "Regent Street, London, UK"}
      })

      assert has_element?(view, "#ds-page-autocomplete dt", "Address")

      render_change(view, "address-form", %{
        "address_search" => %{"address_autocomplete" => "Unknown Place"}
      })

      refute has_element?(view, "#ds-page-autocomplete h3", "Selected Location")
    end

    test "autocomplete error clears cached results and stale selection is not reapplied", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/autocomplete")

      Mox.expect(GtfsPlanner.GeocodingMock, :autocomplete, fn "Regent", _opts ->
        {:ok, [@regent]}
      end)

      Mox.expect(GtfsPlanner.GeocodingMock, :autocomplete, fn "Regent next", _opts ->
        {:error, :network_error}
      end)

      render_hook(view, "live_select_change", %{
        "text" => "Regent",
        "id" => "address_autocomplete"
      })

      render_change(view, "address-form", %{
        "address_search" => %{"address_autocomplete" => "Regent Street, London, UK"}
      })

      assert has_element?(view, "#ds-page-autocomplete dt", "Address")

      render_hook(view, "live_select_change", %{
        "text" => "Regent next",
        "id" => "address_autocomplete"
      })

      render_change(view, "address-form", %{
        "address_search" => %{"address_autocomplete" => "Regent Street, London, UK"}
      })

      refute has_element?(view, "#ds-page-autocomplete h3", "Selected Location")
    end

    test "saves the selected location to the table and deletes it again", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/autocomplete")

      Mox.expect(GtfsPlanner.GeocodingMock, :autocomplete, fn "Regent", _opts ->
        {:ok, [@regent]}
      end)

      render_hook(view, "live_select_change", %{
        "text" => "Regent",
        "id" => "address_autocomplete"
      })

      render_change(view, "address-form", %{
        "address_search" => %{"address_autocomplete" => "Regent Street, London, UK"}
      })

      refute has_element?(view, "#ds-page-autocomplete h2", "Saved Locations")

      view
      |> element("#ds-page-autocomplete button[phx-click='save_location']")
      |> render_click()

      assert has_element?(view, "#ds-page-autocomplete h2", "Saved Locations")
      assert has_element?(view, "#ds-page-autocomplete td", "Regent Street, London, UK")
      assert has_element?(view, "#ds-page-autocomplete td", "London")

      view
      |> element("#ds-page-autocomplete button[phx-click='delete_location']")
      |> render_click()

      refute has_element?(view, "#ds-page-autocomplete td", "Regent Street, London, UK")
      refute has_element?(view, "#ds-page-autocomplete h2", "Saved Locations")
    end

    # save_location is a no-op without a selection: the button cannot be clicked in that
    # state, so this drives the handler directly (the step-005 finding-2 pattern).
    test "saving with no selection adds no row", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/autocomplete")

      render_click(view, "save_location", %{})

      refute has_element?(view, "#ds-page-autocomplete h2", "Saved Locations")
    end

    # INV-4: every event this page pushes to the LiveView must have a clause, including
    # the ones LiveSelect emits from inside itself. Events carrying phx-target are the
    # component's own and never reach DesignSystemLive.
    test "emits only events the LiveView handles", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/autocomplete")

      Mox.expect(GtfsPlanner.GeocodingMock, :autocomplete, fn "Regent", _opts ->
        {:ok, [@regent]}
      end)

      render_hook(view, "live_select_change", %{
        "text" => "Regent",
        "id" => "address_autocomplete"
      })

      render_change(view, "address-form", %{
        "address_search" => %{"address_autocomplete" => "Regent Street, London, UK"}
      })

      view
      |> element("#ds-page-autocomplete button[phx-click='save_location']")
      |> render_click()

      events = untargeted_events(view, "#ds-page-autocomplete")

      assert "save_location" in events
      assert "delete_location" in events
      assert Enum.all?(events, &(&1 in @handled_events))
    end
  end

  describe "retired /components route" do
    # A plain string path, not ~p"/components": the sigil no longer compiles once the
    # route is gone, which is itself the point of the deletion.
    #
    # Not assert_error_sent/2: Phoenix renders NoRouteError and then deliberately does
    # NOT reraise it (`maybe_raise(:error, %NoRouteError{}, _)` in
    # phoenix/endpoint/render_errors.ex), so the request returns a plain sent 404 and
    # assert_error_sent flunks with "response sent 404 without error". The status is the
    # observable fact anyway. The user is logged in so a 404 cannot be an auth redirect
    # in disguise: this same request returned the demo page before the route was deleted.
    test "no longer routes", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      conn = get(conn, "/components")

      assert conn.status == 404
    end
  end

  describe "proposals pages" do
    # These pages are recommendations mocked in plain HTML. The assertions pin the
    # demo containers each page promises, not the mockups' markup: a proposal's
    # implementation is free to change, but a section silently vanishing is not.
    test "improvements page renders the gap table", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/improvements")

      assert has_element?(view, "#ds-page-improvements")
      assert has_element?(view, "#ds-gaps-table")
    end

    test "content page renders the tables and wayfinding demos", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/content")

      for id <-
            ~w(ds-version-chip-demo ds-breadcrumb-demo ds-search-demo
               ds-terminology-table ds-formats-table ds-microcopy-demo) do
        assert has_element?(view, "##{id}")
      end

      assert has_element?(view, "#ds-breadcrumb-demo [aria-current='page']", "Platform A")
    end

    test "transit page renders every pattern demo", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/transit")

      for id <-
            ~w(ds-route-guard-demo ds-stop-sequence-demo ds-service-day-demo
               ds-calendar-demo ds-tri-state-demo ds-pathway-demo
               ds-severity-demo) do
        assert has_element?(view, "##{id}")
      end

      refute has_element?(view, "#ds-diff-demo")
    end

    test "service-day times keep the next-day marker", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/design/transit")

      assert has_element?(view, "#ds-service-day-demo", "25:14:00")
      assert has_element?(view, "#ds-service-day-demo", "+1")
    end

    test "proposal pages emit no untargeted events", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      for slug <- ~w(improvements content transit) do
        {:ok, view, _html} = live(conn, ~p"/design/#{slug}")

        assert untargeted_events(view, "#ds-page-#{slug}") == []
      end
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

  # Click events the page pushes to the LiveView itself. A phx-target routes the event
  defp emitted_events(view, scope) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{scope} [phx-click]")
    |> LazyHTML.attribute("phx-click")
  end

  # Click events the page pushes to the LiveView itself. A phx-target routes the event
  # to a live component instead, so those are excluded — DesignSystemLive never sees them.
  defp untargeted_events(view, scope) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{scope} [phx-click]:not([phx-target])")
    |> LazyHTML.attribute("phx-click")
  end

  # The rendered word of each badge in the status demo, in page order.
  # <.status_badge> puts the label in the `font-medium` span beside its
  # aria-hidden dot, so this reads what a sighted user actually sees.
  defp demo_status_words(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#ds-status-badge-demo span.font-medium")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
end
