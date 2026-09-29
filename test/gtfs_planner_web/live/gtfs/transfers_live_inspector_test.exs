defmodule GtfsPlannerWeb.Gtfs.TransfersLiveInspectorTest do
  @moduledoc """
  Merge evidence (EV-18) for the context pane's general rule inspector.

  The inspector must render the selected catalog row from real data: the type,
  both endpoints with the scope each side carries, what the rule means for
  riders, the one-way line ending in "View the reverse rule" only when the
  catalog resolved an exact mirror and "Create the reverse rule" otherwise, one
  station-coverage line per distinct station endpoint with its child count, the
  overlap note whose compare view lists the competing rules with their own
  effects, every other attention reason as text, the Technical details
  disclosure with the stored GTFS values, and links to the arrival stop and the
  rules' routes.

  The cases assert literal copy, counts and patched URLs against the shared
  fixture network and the catalog's own competition verdict, so an inspector that
  offers a reverse link without a mirror, drops a competitor from the compare
  view, miscounts the station's children, hides an attention reason or links to a
  route the version does not hold is rejected here. EV-18 does not prove the
  rendered pixels; the `inspector:` journey in `assets/e2e/transfers.spec.js`
  (EV-29, step 30) and the captures in `evidence/step-019/` cover those.

  Edit, reverse-create and delete controls belong to steps 22 and 25 and are not
  asserted here.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.TransfersFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)
    transfer_network_fixture(organization.id, version.id)

    %{
      conn: log_in_user(conn, user, organization: organization),
      organization: organization,
      version: version
    }
  end

  describe "the selected rule's summary" do
    test "names the type, both endpoints with their scope and the rider meaning", ctx do
      scoped =
        rule!(ctx, %{
          from_stop_id: "CEN-A",
          to_stop_id: "CEN-C",
          from_route_id: "12",
          to_route_id: "24",
          transfer_type: 2,
          min_transfer_time: 180
        })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: scoped.id))

      assert text_of(view, "#transfer-inspector h2") == "Minimum time"

      inspector = text_of(view, "#transfer-inspector")

      assert inspector =~ "Riders arrive at"
      assert inspector =~ "Central · Bay A"
      assert inspector =~ "Route 12"
      assert inspector =~ "Riders board at"
      assert inspector =~ "Central · Bay C"
      assert inspector =~ "Route 24"

      assert text_of(view, "#transfer-inspector-sentence") ==
               "Trip planners offer this connection only if riders have at least 3 min between arriving on Route 12 and boarding Route 24."

      refute has_element?(view, "#transfer-inspector-empty")
    end

    test "a minimum-time rule without a time asks for one", ctx do
      missing_time =
        rule!(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 2})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: missing_time.id))

      assert has_element?(
               view,
               "#transfer-inspector-sentence",
               "Trip planners need a minimum time for this connection."
             )

      assert has_element?(
               view,
               "#transfer-inspector-attention",
               "This rule needs a minimum time."
             )
    end

    test "each type carries its own rider meaning", ctx do
      # Distinct stop pairs, because the six-field key is unique per version.
      meanings = [
        {0, "MKT", "HBR",
         "Trip planners prefer this place when riders switch from any route to any route. It does not make a vehicle wait."},
        {1, "MKT", "MUS",
         "Departing vehicles wait for arriving vehicles, so riders can connect."},
        {3, "HBR", "MUS",
         "Trip planners will not offer a connection from any route to any route."}
      ]

      for {type, from, to, sentence} <- meanings do
        row = rule!(ctx, %{from_stop_id: from, to_stop_id: to, transfer_type: type})

        {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: row.id))

        assert text_of(view, "#transfer-inspector-sentence") == sentence
      end
    end
  end

  describe "the reverse rule affordance" do
    test "offers the mirror and patches the rule to it", ctx do
      forward =
        rule!(ctx, %{
          from_stop_id: "CEN-A",
          to_stop_id: "CEN-C",
          from_route_id: "12",
          to_route_id: "24",
          transfer_type: 2,
          min_transfer_time: 180
        })

      mirror =
        rule!(ctx, %{
          from_stop_id: "CEN-C",
          to_stop_id: "CEN-A",
          from_route_id: "24",
          to_route_id: "12",
          transfer_type: 2,
          min_transfer_time: 240
        })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: forward.id))

      assert has_element?(view, "#transfer-inspector-reverse-inspect", "View the reverse rule")
      refute has_element?(view, "#transfer-inspector-reverse-create")

      assert has_element?(
               view,
               "#transfer-inspector-direction",
               "Works one way only: Route 12 to Route 24."
             )

      view |> element("#transfer-inspector-reverse-inspect") |> render_click()

      assert_patched(view, ~p"/gtfs/#{ctx.version.id}/transfers?rule=#{mirror.id}")

      assert has_element?(view, "#transfer-select-#{mirror.id}[aria-current='true']")
      assert has_element?(view, "#transfer-inspector", "Central · Bay C")
    end

    test "inspecting the mirror names it on the bare list", ctx do
      forward =
        rule!(ctx, %{
          from_stop_id: "CEN-A",
          to_stop_id: "CEN-C",
          from_route_id: "12",
          to_route_id: "24",
          transfer_type: 0
        })

      mirror =
        rule!(ctx, %{
          from_stop_id: "CEN-C",
          to_stop_id: "CEN-A",
          from_route_id: "24",
          to_route_id: "12",
          transfer_type: 0
        })

      {:ok, view, _html} =
        live(ctx.conn, transfers_path(ctx.version, q: "Bay", rule: forward.id))

      assert has_element?(view, "#transfer-inspector-reverse-inspect")

      view |> element("#transfer-inspector-reverse-inspect") |> render_click()

      # The mirror is named on the bare list, so the search that narrowed the
      # list and the request's own page cannot hide it.
      assert_patched(view, ~p"/gtfs/#{ctx.version.id}/transfers?rule=#{mirror.id}")

      assert has_element?(view, "#transfer-select-#{mirror.id}[aria-current='true']")
    end

    test "a rule without a mirror offers to create the reverse rule", ctx do
      solo =
        rule!(ctx, %{
          from_stop_id: "CEN-A",
          to_stop_id: "CEN-C",
          from_route_id: "12",
          to_route_id: "24",
          transfer_type: 2,
          min_transfer_time: 180
        })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: solo.id))

      refute has_element?(view, "#transfer-inspector-reverse-inspect")

      assert has_element?(
               view,
               "#transfer-inspector-reverse-create",
               "Create the reverse rule"
             )
    end
  end

  describe "station coverage" do
    test "counts the station's child platforms and not its entrance", ctx do
      station = rule!(ctx, %{from_stop_id: "CEN", to_stop_id: "CEN", transfer_type: 0})
      platform = rule!(ctx, %{from_stop_id: "CEN-A", to_stop_id: "CEN-C", transfer_type: 0})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: station.id))

      assert has_element?(
               view,
               "#transfer-inspector-coverage",
               "Central Station includes 2 platforms, so this rule applies at every one."
             )

      assert has_element?(
               view,
               "#transfer-inspector-coverage",
               "Covers the whole station"
             )

      view |> element("#transfer-select-#{platform.id}") |> render_click()

      refute has_element?(view, "#transfer-inspector-coverage")
    end

    test "names each distinct station endpoint once", ctx do
      # A station on the arrival side and a platform on the departure side is one
      # coverage fact, so the pane keeps one line for it.
      station_to_station =
        rule!(ctx, %{from_stop_id: "CEN", to_stop_id: "CEN-C", transfer_type: 0})

      {:ok, view, _html} =
        live(ctx.conn, transfers_path(ctx.version, rule: station_to_station.id))

      assert has_element?(
               view,
               "#transfer-inspector-coverage",
               "Central Station includes 2 platforms, so this rule applies at every one."
             )
    end

    test "a rule whose endpoints are both platforms has no coverage line", ctx do
      platform = rule!(ctx, %{from_stop_id: "CEN-A", to_stop_id: "CEN-C", transfer_type: 1})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: platform.id))

      refute has_element?(view, "#transfer-inspector-coverage")
    end
  end

  describe "competing rules" do
    test "the overlap callout and compare view list every competing rule", ctx do
      arrival =
        rule!(ctx, %{
          from_stop_id: "CEN",
          to_stop_id: "CEN",
          from_route_id: "12",
          transfer_type: 2,
          min_transfer_time: 120
        })

      _departure =
        rule!(ctx, %{
          from_stop_id: "CEN",
          to_stop_id: "CEN",
          to_route_id: "24",
          transfer_type: 3
        })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: arrival.id))

      assert has_element?(
               view,
               "#transfer-inspector-overlap",
               "1 other rule of equal priority can apply to some of the same trips"
             )

      refute has_element?(view, "#transfer-inspector-attention")

      view |> element("#transfer-inspector-compare") |> render_click()

      assert has_element?(
               view,
               "#transfer-compare-dialog",
               "Rules that match the same trips"
             )

      dialog = text_of(view, "#transfer-compare-dialog")

      assert dialog =~
               "These rules can apply to some of the same trips and none is more specific, so a trip planner can’t tell which one wins."

      assert dialog =~
               "Keep the one you intend, then narrow the other to a route or trip, or delete it."

      # Both rules, each with its own effect and its own scope: the selected
      # minimum-time rule and the competing one that forbids the transfer.
      assert dialog =~ "Selected rule"
      assert dialog =~ "Minimum time · 2 min"
      assert dialog =~ "Not possible"
      refute dialog =~ "Not possible ·"
      assert dialog =~ "Route 12 to Any departing route"
      assert dialog =~ "Any arriving route to Route 24"
      assert dialog =~ "Central Station to Central Station"

      view |> element("#transfer-compare-dialog-cancel") |> render_click()

      refute has_element?(view, "#transfer-compare-dialog")
    end

    test "a rule the catalog found no competitor for has no overlap callout", ctx do
      clean = rule!(ctx, %{from_stop_id: "CEN-A", to_stop_id: "CEN-C", transfer_type: 0})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: clean.id))

      refute has_element?(view, "#transfer-inspector-overlap")
      refute has_element?(view, "#transfer-inspector-compare")
      refute has_element?(view, "#transfer-inspector-attention")
    end

    test "the compare view opens only while the selected rule competes", ctx do
      clean = rule!(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 1})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: clean.id))

      view |> render_click("open_compare", %{})

      refute has_element?(view, "#transfer-compare-dialog")
    end

    test "a new load closes the compare view", ctx do
      competing =
        rule!(ctx, %{
          from_stop_id: "CEN",
          to_stop_id: "CEN",
          from_route_id: "12",
          transfer_type: 2,
          min_transfer_time: 120
        })

      other =
        rule!(ctx, %{
          from_stop_id: "CEN",
          to_stop_id: "CEN",
          to_route_id: "24",
          transfer_type: 3
        })

      unrelated = rule!(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 0})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: competing.id))

      view |> element("#transfer-inspector-compare") |> render_click()
      assert has_element?(view, "#transfer-compare-dialog")

      view |> element("#transfer-select-#{unrelated.id}") |> render_click()

      refute has_element?(view, "#transfer-compare-dialog")
      refute has_element?(view, "#transfer-inspector-overlap")

      view |> element("#transfer-select-#{other.id}") |> render_click()

      assert has_element?(view, "#transfer-inspector-overlap")
      refute has_element?(view, "#transfer-compare-dialog")
    end
  end

  describe "attention reasons" do
    test "renders a dangling selector as text", ctx do
      damaged =
        rule!(ctx, %{
          from_stop_id: "CEN-A",
          to_stop_id: "CEN-C",
          to_route_id: "R404",
          transfer_type: 0
        })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: damaged.id))

      assert has_element?(
               view,
               "#transfer-inspector-attention",
               "The departing route “R404” is not in this version."
             )
    end

    test "renders every reason the row carries", ctx do
      damaged =
        rule!(ctx, %{
          from_stop_id: "LOC-1",
          to_stop_id: "GHOST",
          transfer_type: 2
        })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: damaged.id))

      attention = text_of(view, "#transfer-inspector-attention")

      assert attention =~ "3 things need attention"
      assert attention =~ "The arriving stop “LOC-1” is not in this version."
      assert attention =~ "The departing stop “GHOST” is not in this version."
      assert attention =~ "This rule needs a minimum time."
    end
  end

  describe "the technical details disclosure" do
    test "names the specificity, the type and the stored values", ctx do
      scoped =
        rule!(ctx, %{
          from_stop_id: "CEN-A",
          to_stop_id: "CEN-C",
          from_route_id: "12",
          to_route_id: "24",
          transfer_type: 2,
          min_transfer_time: 180
        })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: scoped.id))

      assert has_element?(view, "#transfer-inspector-details", "Technical details")

      details = text_of(view, "#transfer-inspector-details")

      assert details =~ "Route-specific"
      assert details =~ "GTFS specificity 4 of 6"
      assert details =~ "Minimum time required"

      assert stored_values(view) == %{
               "from_stop_id" => "CEN-A",
               "to_stop_id" => "CEN-C",
               "from_route_id" => "12",
               "to_route_id" => "24",
               "transfer_type" => "2",
               "min_transfer_time" => "180 seconds"
             }

      assert details =~
               "Trip and route choices narrow a rule. Rules with the same specificity that overlap need review."
    end

    test "a trip rule is trip-specific and names its trips and min time as required", ctx do
      trips =
        rule!(ctx, %{
          from_stop_id: "CEN-A",
          to_stop_id: "CEN-C",
          from_trip_id: "12-0815",
          to_trip_id: "24-0840",
          transfer_type: 2
        })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: trips.id))

      details = text_of(view, "#transfer-inspector-details")

      assert details =~ "Specific trips"
      assert details =~ "GTFS specificity 1 of 6"

      assert stored_values(view) == %{
               "from_stop_id" => "CEN-A",
               "to_stop_id" => "CEN-C",
               "from_trip_id" => "12-0815",
               "to_trip_id" => "24-0840",
               "transfer_type" => "2",
               "min_transfer_time" => "required seconds"
             }
    end

    test "a default rule is the stop and station default", ctx do
      default = rule!(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 0})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: default.id))

      details = text_of(view, "#transfer-inspector-details")

      assert details =~ "Every service at these stops"
      assert details =~ "GTFS specificity 6 of 6"
      assert details =~ "Recommended transfer point"

      assert stored_values(view) == %{
               "from_stop_id" => "MKT",
               "to_stop_id" => "HBR",
               "transfer_type" => "0"
             }
    end
  end

  describe "related links" do
    test "link to the arrival stop and to the rules' routes", ctx do
      scoped =
        rule!(ctx, %{
          from_stop_id: "CEN",
          to_stop_id: "CEN",
          from_route_id: "12",
          to_route_id: "24",
          transfer_type: 0
        })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: scoped.id))

      assert has_element?(
               view,
               "#transfer-inspector-stop-link[href='/gtfs/#{ctx.version.id}/stops/CEN']",
               "View Central Station"
             )

      assert has_element?(
               view,
               "#transfer-inspector-route-link-from[href='/gtfs/#{ctx.version.id}/routes/12']",
               "View route 12"
             )

      assert has_element?(
               view,
               "#transfer-inspector-route-link-to[href='/gtfs/#{ctx.version.id}/routes/24']",
               "View route 24"
             )
    end

    test "a rule with one selector links only the side the version holds", ctx do
      scoped =
        rule!(ctx, %{
          from_stop_id: "CEN-A",
          to_stop_id: "CEN-C",
          to_route_id: "R404",
          transfer_type: 0
        })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: scoped.id))

      assert has_element?(
               view,
               "#transfer-inspector-stop-link[href='/gtfs/#{ctx.version.id}/stops/CEN-A']",
               "View Central · Bay A"
             )

      refute has_element?(view, "#transfer-inspector-route-link-from")
      refute has_element?(view, "#transfer-inspector-route-link-to")
    end
  end

  describe "the context pane without a selected rule" do
    test "a version with no general rules shows the empty context pane", ctx do
      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      assert has_element?(view, "#transfer-inspector-empty", "Connections appear here")
      refute has_element?(view, "#transfer-inspector")
      refute has_element?(view, "#transfer-compare-dialog")
    end

    test "the first page's first rule is inspected before a rule is named", ctx do
      first = rule!(ctx, %{from_stop_id: "CEN-A", to_stop_id: "CEN-C", transfer_type: 0})
      second = rule!(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 1})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      assert has_element?(view, "#transfer-select-#{first.id}[aria-current='true']")
      assert has_element?(view, "#transfer-inspector", "Preferred transfer point")

      view |> element("#transfer-select-#{second.id}") |> render_click()

      assert has_element?(view, "#transfer-inspector", "Timed transfer")
      refute has_element?(view, "#transfer-inspector-empty")
    end
  end

  defp transfers_path(version, params \\ []) do
    query = if params == [], do: "", else: "?" <> URI.encode_query(params)
    "/gtfs/#{version.id}/transfers#{query}"
  end

  defp rule!(ctx, attrs), do: transfer_fixture(ctx.organization.id, ctx.version.id, attrs)

  # The stored GTFS columns the disclosure lists, as `%{column => value}`: one term
  # and one definition per column, so a column that is missing, extra or paired
  # with the wrong value fails here.
  defp stored_values(view) do
    document = view |> render() |> LazyHTML.from_fragment()

    terms = document |> LazyHTML.query("#transfer-inspector-details dt") |> Enum.map(&node_text/1)

    values =
      document |> LazyHTML.query("#transfer-inspector-details dd") |> Enum.map(&node_text/1)

    Map.new(Enum.zip(terms, values))
  end

  defp node_text(node), do: node |> LazyHTML.text() |> String.trim()

  defp text_of(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.trim()
  end
end
