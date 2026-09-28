defmodule GtfsPlannerWeb.Gtfs.RouteCreateDrawerTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Repo

  defp editor_scope(%{conn: conn}) do
    organization = organization_fixture()

    user =
      user_fixture(%{
        email: "route-create-drawer-#{System.unique_integer([:positive])}@example.com"
      })

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)
    conn = log_in_user(conn, user, organization: organization)

    %{conn: conn, user: user, organization: organization, version: version}
  end

  defp open_drawer(view) do
    view |> element("#new-route-trigger") |> render_click()
  end

  defp unused_route_params do
    fields =
      ~w(route_id route_short_name route_long_name route_type agency_id route_desc route_url route_color route_text_color)

    params =
      fields
      |> Map.new(&{&1, ""})
      |> Map.put("route_long_name", "Crosstown")

    Map.merge(params, Map.new(fields, &{"_unused_" <> &1, ""}))
  end

  describe "opening and validating" do
    setup :editor_scope

    test "Create route opens the drawer with the route form", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      agency_fixture(organization.id, version.id, %{
        agency_id: "A1",
        agency_name: "Alpha Transit"
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      open_drawer(view)

      assert has_element?(view, "#new-route-drawer-overlay[data-open='true']")
      assert has_element?(view, "#new-route-form-panel #new-route-form")

      doc = LazyHTML.from_fragment(render(view))
      assert Enum.count(LazyHTML.query(doc, "[id='new-route-drawer']")) == 1

      option_values = LazyHTML.attribute(LazyHTML.query(doc, "#route_route_type option"), "value")
      assert Enum.count(option_values, &(&1 != "")) == 10
    end

    test "the drawer is closed until opened", %{conn: conn, version: version} do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      assert has_element?(view, "#new-route-drawer-overlay[data-open='false']")
      refute has_element?(view, "#new-route-form")
    end

    test "agency select lists this version's agencies only", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      agency_fixture(organization.id, version.id, %{agency_id: "A1", agency_name: "Alpha Transit"})

      agency_fixture(organization.id, version.id, %{agency_id: "A2", agency_name: "Beta Transit"})

      other_version = gtfs_version_fixture(organization.id)

      agency_fixture(organization.id, other_version.id, %{
        agency_id: "A3",
        agency_name: "Gamma Transit"
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      open_drawer(view)

      html = render(view)
      assert html =~ "Alpha Transit (A1)"
      assert html =~ "Beta Transit (A2)"
      refute html =~ "Gamma Transit (A3)"

      labels =
        LazyHTML.query(LazyHTML.from_fragment(html), "#new-route-form-panel label span.label")

      assert "Agency" in Enum.map(labels, &LazyHTML.text/1)

      doc = LazyHTML.from_fragment(html)

      # Several agencies and no filter: the blank option is the prompt, and
      # nothing is selected until the editor chooses (AC-23).
      assert LazyHTML.attribute(LazyHTML.query(doc, "#route_agency_id option"), "value") == [
               "",
               "A1",
               "A2"
             ]

      assert has_element?(view, "#route_agency_id option", "Choose agency")
      assert LazyHTML.attribute(LazyHTML.query(doc, "#route_agency_id option"), "selected") == []
    end

    test "one agency preselects the Agency field and drops the optional label", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      agency_fixture(organization.id, version.id, %{
        agency_id: "NCT",
        agency_name: "North Coast Transit"
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      open_drawer(view)

      doc = LazyHTML.from_fragment(render(view))

      labels =
        doc
        |> LazyHTML.query("#new-route-form-panel label span.label")
        |> Enum.map(&LazyHTML.text/1)

      assert "Agency" in labels
      refute "Agency (optional)" in labels

      # The only agency is the only choice, so the field is already set and
      # there is no blank option to fall back to (AC-23).
      assert LazyHTML.attribute(LazyHTML.query(doc, "#route_agency_id option"), "value") == [
               "NCT"
             ]

      assert LazyHTML.attribute(LazyHTML.query(doc, "#route_agency_id option[selected]"), "value") ==
               ["NCT"]

      assert has_element?(
               view,
               "#route_agency_id-help",
               "agency_id — the agency that operates this route."
             )
    end

    test "the list's agency filter preselects the Agency field", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      agency_fixture(organization.id, version.id, %{
        agency_id: "NCT",
        agency_name: "North Coast Transit"
      })

      agency_fixture(organization.id, version.id, %{
        agency_id: "HBR",
        agency_name: "Harbor Shuttle"
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes?agency_id=HBR")

      open_drawer(view)

      doc = LazyHTML.from_fragment(render(view))

      assert LazyHTML.attribute(LazyHTML.query(doc, "#route_agency_id option"), "value") == [
               "HBR",
               "NCT"
             ]

      assert LazyHTML.attribute(LazyHTML.query(doc, "#route_agency_id option[selected]"), "value") ==
               ["HBR"]

      refute has_element?(view, "#route_agency_id option", "Choose agency")
    end

    test "trigger is secondary beside the first-use import action", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      # A version with an agency but no routes keeps the first-use empty state;
      # step 21 replaced only the no-agency branch with the onboarding.
      agency_fixture(organization.id, version.id, %{
        agency_id: "A1",
        agency_name: "Alpha Transit"
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      assert has_element?(view, "#new-route-trigger.btn-outline")

      assert has_element?(
               view,
               "#routes-first-use-empty",
               "Routes appear here after you import a GTFS feed or create a route."
             )

      assert has_element?(view, "#routes-first-use-empty", "Import feed")
    end

    test "trigger is primary on a populated catalog", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      route_fixture(organization.id, version.id, %{route_id: "POP1"})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      assert has_element?(view, "#new-route-trigger.btn-primary")
    end

    test "closing clears the entered values", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      agency_fixture(organization.id, version.id, %{
        agency_id: "A1",
        agency_name: "Alpha Transit"
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      open_drawer(view)

      view
      |> form("#new-route-form", route: %{route_long_name: "Crosstown"})
      |> render_change()

      view |> element("#new-route-drawer-close") |> render_click()
      refute has_element?(view, "#new-route-form")

      open_drawer(view)
      assert has_element?(view, "#route_route_long_name")
      refute has_element?(view, "#route_route_long_name[value='Crosstown']")
    end

    test "validation hides errors for unused fields", %{conn: conn, version: version} do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      open_drawer(view)

      render_change(view, "validate_new_route", %{"route" => unused_route_params()})

      refute has_element?(view, "#route_route_id-error")
      refute has_element?(view, "#route_route_type-error")
    end

    test "validation shows the error for a used blank field", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      agency_fixture(organization.id, version.id, %{
        agency_id: "A1",
        agency_name: "Alpha Transit"
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      open_drawer(view)

      params = Map.delete(unused_route_params(), "_unused_route_id")

      render_change(view, "validate_new_route", %{"route" => params})

      assert has_element?(view, "#route_route_id-error")
    end
  end

  defp scoped_route_count(organization, version) do
    from(r in Route,
      where: r.organization_id == ^organization.id and r.gtfs_version_id == ^version.id
    )
    |> Repo.aggregate(:count)
  end

  describe "creating a route" do
    setup :editor_scope

    test "a valid submit creates one scoped route and lists it", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      agency_fixture(organization.id, version.id, %{
        agency_id: "NCT",
        agency_name: "North Coast Transit"
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      open_drawer(view)

      view
      |> form("#new-route-form",
        route: %{
          route_id: "  NEW1 ",
          route_short_name: " N1 ",
          route_type: "3",
          route_color: "",
          route_text_color: ""
        }
      )
      |> render_submit()

      route =
        Repo.one!(
          from r in Route,
            where: r.organization_id == ^organization.id and r.gtfs_version_id == ^version.id
        )

      assert route.route_id == "NEW1"
      assert route.organization_id == organization.id
      assert route.gtfs_version_id == version.id
      # The version's only agency is preselected in the drawer and resolved
      # under the version lock on insert (AC-23, R4).
      assert route.agency_id == "NCT"
      assert route.route_short_name == "N1"
      assert route.route_long_name == nil
      assert route.route_desc == nil
      assert route.route_color == "FFFFFF"
      assert route.route_text_color == "000000"
      assert route.active == true
      assert route.continuous_pickup == 1
      assert route.continuous_drop_off == 1
      assert route.route_sort_order == nil
      assert route.network_id == nil

      assert has_element?(view, "#new-route-drawer-overlay[data-open='false']")
      assert has_element?(view, "#flash-info", "Route NEW1 created.")
      assert has_element?(view, "#routes a", "NEW1")
      refute has_element?(view, "#routes-first-use-empty")
    end

    test "creating keeps the active search", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      agency_fixture(organization.id, version.id, %{
        agency_id: "NCT",
        agency_name: "North Coast Transit"
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes?search=NEW")

      open_drawer(view)

      view
      |> form("#new-route-form",
        route: %{route_id: "NEW2", route_short_name: "N2", route_type: "3"}
      )
      |> render_submit()

      path = assert_patch(view)

      assert path =~ "search=NEW"
      assert has_element?(view, "#routes a", "NEW2")
    end

    test "a duplicate route_id is reported on Route ID and saves nothing", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      agency_fixture(organization.id, version.id, %{
        agency_id: "NCT",
        agency_name: "North Coast Transit"
      })

      route_fixture(organization.id, version.id, %{route_id: "DUP1", agency_id: "NCT"})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      open_drawer(view)

      view
      |> form("#new-route-form",
        route: %{
          route_id: "DUP1",
          route_type: "3",
          route_short_name: "D",
          route_long_name: "Kept"
        }
      )
      |> render_submit()

      dup_count =
        from(r in Route,
          where:
            r.organization_id == ^organization.id and r.gtfs_version_id == ^version.id and
              r.route_id == "DUP1"
        )
        |> Repo.aggregate(:count)

      assert dup_count == 1
      assert has_element?(view, "#route_route_id-error", "has already been taken")
      assert has_element?(view, "#new-route-form-error")
      assert has_element?(view, "#new-route-drawer-overlay[data-open='true']")
      assert has_element?(view, "#route_route_long_name[value='Kept']")

      assert_push_event(view, "focus_form_error", %{
        form_id: "new-route-form",
        fallback_id: "new-route-form-error"
      })
    end

    test "an invalid submit marks each invalid field and saves nothing", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      agency_fixture(organization.id, version.id, %{
        agency_id: "A1",
        agency_name: "Alpha Transit"
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      open_drawer(view)

      view
      |> form("#new-route-form",
        route: %{
          route_id: "",
          route_type: "",
          route_short_name: "",
          route_long_name: "",
          route_color: "#FF0000",
          route_desc: String.duplicate("a", 256)
        }
      )
      |> render_submit()

      assert has_element?(view, "#route_route_id-error")
      assert has_element?(view, "#route_route_type-error")
      assert has_element?(view, "#route_route_short_name-error")
      assert has_element?(view, "#route_route_color-error")
      assert has_element?(view, "#route_route_desc-error")

      assert scoped_route_count(organization, version) == 0
      assert render(view)
    end
  end

  describe "write boundary" do
    setup :editor_scope

    test "crafted scope and unexposed fields are ignored", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      agency_fixture(organization.id, version.id, %{
        agency_id: "A1",
        agency_name: "Alpha Transit"
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      open_drawer(view)

      render_submit(view, "save_new_route", %{
        "route" => %{
          "route_id" => "T1",
          "route_type" => "3",
          "route_short_name" => "T",
          "organization_id" => other_organization.id,
          "gtfs_version_id" => other_version.id,
          "active" => "false",
          "route_sort_order" => "9",
          "network_id" => "N",
          "continuous_pickup" => "0",
          "continuous_drop_off" => "0"
        }
      })

      route =
        Repo.one!(
          from r in Route,
            where:
              r.organization_id == ^organization.id and r.gtfs_version_id == ^version.id and
                r.route_id == "T1"
        )

      assert route.active == true
      assert route.agency_id == "A1"
      assert route.route_sort_order == nil
      assert route.network_id == nil
      assert route.continuous_pickup == 1
      assert route.continuous_drop_off == 1

      other_count =
        from(r in Route,
          where: r.gtfs_version_id == ^other_version.id and r.route_id == "T1"
        )
        |> Repo.aggregate(:count)

      assert other_count == 0
    end

    test "a save while the drawer is closed writes nothing", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      render_submit(view, "save_new_route", %{
        "route" => %{
          "route_id" => "CLOSED1",
          "route_type" => "3",
          "route_short_name" => "C"
        }
      })

      assert scoped_route_count(organization, version) == 0
    end

    test "an agency from another version is rejected", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      agency_fixture(organization.id, version.id, %{
        agency_id: "A1",
        agency_name: "Alpha Transit"
      })

      other_version = gtfs_version_fixture(organization.id)

      agency_fixture(organization.id, other_version.id, %{
        agency_id: "A_OTHER",
        agency_name: "Other Transit"
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      open_drawer(view)

      render_submit(view, "save_new_route", %{
        "route" => %{
          "route_id" => "AG1",
          "route_type" => "3",
          "route_short_name" => "A",
          "agency_id" => "A_OTHER"
        }
      })

      assert has_element?(view, "#route_agency_id-error", "is not an agency in this version")
      assert scoped_route_count(organization, version) == 0
    end

    test "several agencies make Agency required", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      agency_fixture(organization.id, version.id, %{
        agency_id: "A1",
        agency_name: "Alpha Transit"
      })

      agency_fixture(organization.id, version.id, %{
        agency_id: "A2",
        agency_name: "Beta Transit"
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      open_drawer(view)

      view
      |> form("#new-route-form",
        route: %{route_id: "AG2", route_type: "3", route_short_name: "A"}
      )
      |> render_submit()

      assert has_element?(view, "#route_agency_id-error", "can't be blank")
      assert scoped_route_count(organization, version) == 0

      view
      |> form("#new-route-form",
        route: %{route_id: "AG2", route_type: "3", route_short_name: "A", agency_id: "A1"}
      )
      |> render_submit()

      route =
        Repo.one!(
          from r in Route,
            where:
              r.organization_id == ^organization.id and r.gtfs_version_id == ^version.id and
                r.route_id == "AG2"
        )

      assert route.agency_id == "A1"
    end

    test "a removed editor role blocks creation", %{
      conn: conn,
      organization: organization,
      version: version,
      user: user
    } do
      agency_fixture(organization.id, version.id, %{
        agency_id: "A1",
        agency_name: "Alpha Transit"
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      open_drawer(view)

      Accounts.get_user_org_membership(user.id, organization.id)
      |> Ecto.Changeset.change(roles: [])
      |> Repo.update!()

      view
      |> form("#new-route-form",
        route: %{route_id: "REVOKED1", route_type: "3", route_short_name: "R"}
      )
      |> render_submit()

      assert scoped_route_count(organization, version) == 0
      assert has_element?(view, "#new-route-drawer-overlay[data-open='false']")
      assert has_element?(view, "#flash-error", "no longer have editor access")
    end

    test "a deactivated membership blocks creation", %{
      conn: conn,
      organization: organization,
      version: version,
      user: user
    } do
      agency_fixture(organization.id, version.id, %{
        agency_id: "A1",
        agency_name: "Alpha Transit"
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      open_drawer(view)

      Accounts.get_user_org_membership(user.id, organization.id)
      |> Ecto.Changeset.change(deactivated_at: DateTime.utc_now(:second))
      |> Repo.update!()

      view
      |> form("#new-route-form",
        route: %{route_id: "DEACT1", route_type: "3", route_short_name: "D"}
      )
      |> render_submit()

      assert scoped_route_count(organization, version) == 0
      assert has_element?(view, "#new-route-drawer-overlay[data-open='false']")
      assert has_element?(view, "#flash-error", "no longer have editor access")
    end

    test "a crafted unknown agency is refused on the field and saves nothing", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      agency_fixture(organization.id, version.id, %{
        agency_id: "A1",
        agency_name: "Alpha Transit"
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      open_drawer(view)

      # The drawer no longer keeps its own copy of the version's agency IDs, so
      # validating a name the version does not have reports nothing; the refusal
      # has to come from the insert's own resolution (R4, INV-1).
      params = %{
        "route" => %{
          "route_id" => "AG3",
          "route_type" => "3",
          "route_short_name" => "A",
          "agency_id" => "UNKNOWN"
        }
      }

      render_change(view, "validate_new_route", params)
      refute has_element?(view, "#route_agency_id-error")

      render_submit(view, "save_new_route", params)

      assert has_element?(view, "#route_agency_id-error", "is not an agency in this version")
      assert has_element?(view, "#new-route-drawer-overlay[data-open='true']")
      assert scoped_route_count(organization, version) == 0
    end

    test "with no agencies the trigger opens the agency setup instead", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      open_drawer(view)

      # A version with no agency cannot create a route, so the header's Create
      # route opens the agency setup rather than an empty route drawer (AC-24).
      # `#routes-agency-onboarding` covers the same request from the onboarding.
      assert has_element?(view, "#routes-agency-drawer-overlay[data-open='true']")
      assert has_element?(view, "#routes-agency-form")
      assert has_element?(view, "#routes-agency-form_agency_timezone")
      refute has_element?(view, "#new-route-form")

      # A crafted save with no route form behind it inserts nothing.
      render_submit(view, "save_new_route", %{
        "route" => %{"route_id" => "NONE1", "route_type" => "3", "route_short_name" => "N"}
      })

      assert scoped_route_count(organization, version) == 0
    end
  end
end
