defmodule GtfsPlannerWeb.Gtfs.RouteCreateDrawerTest do
  @moduledoc """
  Step 21's behavioral cases for the Create route drawer.

  Every case drives the ordinary public entrypoint — the catalog page's
  `#new-route-trigger` and the real `#new-route-form` — so the assertions
  observe `RoutesLive` composed with the concrete adapters
  (`Gtfs.create_editor_route/3` → `Routes.create_editor_route/3` →
  `ReviewedApplyTransaction.Repo` / `Repo`). No case injects a private assign or
  reaches past the LiveView to build a controller by hand.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Repo

  setup :editor_scope

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

  defp north_coast(organization, version) do
    agency_fixture(organization.id, version.id, %{
      agency_id: "NCT",
      agency_name: "North Coast Transit"
    })
  end

  defp open_drawer(view), do: view |> element("#new-route-trigger") |> render_click()

  defp scoped_routes(organization, version) do
    Repo.all(
      from r in Route,
        where: r.organization_id == ^organization.id and r.gtfs_version_id == ^version.id,
        order_by: r.route_id
    )
  end

  defp scoped_route_count(organization, version), do: length(scoped_routes(organization, version))

  # R1's allowlist is the only key set the drawer accepts, so a crafted submit
  # uses exactly the same shape a browser would.
  defp drawer_submit(view, attrs) do
    view |> form("#new-route-form", route: attrs) |> render_submit()
  end

  describe "opening the drawer" do
    test "the ordinary list trigger opens the 520px Create route drawer", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      north_coast(organization, version)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      assert has_element?(view, "#new-route-drawer-overlay[data-open='false']")
      refute has_element?(view, "#new-route-form")

      open_drawer(view)

      assert has_element?(view, "#new-route-drawer-overlay[data-open='true']")
      assert has_element?(view, "#new-route-drawer-title", "Create route")
      assert has_element?(view, "#new-route-form-panel #new-route-form")

      # The reference's drawer width, the shared controls from step 18/20, and
      # the drawer's own identifier block and live preview.
      assert has_element?(view, "#new-route-drawer[class*='520px']")
      assert has_element?(view, "#new-route-identity")
      assert has_element?(view, "#new-route-color-fields")
      assert has_element?(view, "#new-route-identity-fields")
      assert has_element?(view, "#new-route-preview")

      # A clean opening is not a draft, so no unsaved badge and no discard ask.
      refute has_element?(view, "#new-route-unsaved")
      refute has_element?(view, "#new-route-discard")
    end

    test "opening mints one signed attempt the browser cannot restate", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      north_coast(organization, version)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      open_drawer(view)
      attempt = view |> element("#new-route-attempt") |> render() |> attribute_of("value")

      assert is_binary(attempt) and attempt != ""

      # A field edit keeps the same attempt: R3 mints it on open, never on
      # change, so a browser cannot obtain a fresh one by typing.
      render_change(view, "validate_new_route", %{
        "route" => draft_params(%{"route_short_name" => "5"})
      })

      assert view |> element("#new-route-attempt") |> render() |> attribute_of("value") == attempt
    end

    test "the version's agencies and modes come from the scoped read", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      north_coast(organization, version)

      agency_fixture(organization.id, version.id, %{
        agency_id: "HBR",
        agency_name: "Harbor Shuttle"
      })

      other_version = gtfs_version_fixture(organization.id)

      agency_fixture(organization.id, other_version.id, %{
        agency_id: "OTHER",
        agency_name: "Other Transit"
      })

      route_fixture(organization.id, version.id, %{route_id: "B1", route_type: 3})
      route_fixture(organization.id, version.id, %{route_id: "R1", route_type: 2})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")
      open_drawer(view)

      html = render(view)
      doc = LazyHTML.from_fragment(html)

      # Only this version's agencies, as option values.
      assert LazyHTML.attribute(LazyHTML.query(doc, "#new-route-agency option"), "value") ==
               Enum.sort(["", "HBR", "NCT"])

      # The modes this version already uses lead the chips, most used first,
      # and the remaining supported modes stay reachable behind "Other mode…".
      assert has_element?(view, "#new-route-mode-3")
      assert has_element?(view, "#new-route-mode-2")
      assert has_element?(view, "label[for='new-route-mode-other']")
      assert has_element?(view, "#new-route-mode-group", "Bus")

      # Another version's agency is never offered.
      refute html =~ "Other Transit"
    end

    test "a version with no agency opens agency setup instead of an empty drawer", %{
      conn: conn,
      version: version
    } do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      open_drawer(view)

      # The header trigger still opens agency setup (the existing AC-24 rule);
      # the onboarding link inside the drawer is the version's own escape hatch.
      assert has_element?(view, "#routes-agency-drawer-overlay[data-open='true']")
      refute has_element?(view, "#new-route-form")
    end
  end

  # A full `route[...]` payload: the shared controls submit one name for the
  # mode (radio chips or the "Other mode…" select) and one for the agency.
  defp draft_params(overrides) do
    base = %{
      "route_short_name" => "",
      "route_long_name" => "",
      "route_type" => "",
      "agency_id" => "",
      "route_desc" => "",
      "route_url" => "",
      "route_color" => "",
      "route_text_color" => ""
    }

    Map.merge(base, overrides)
  end

  describe "the generated identifier" do
    test "previews the value the command allocates, and the saved row agrees", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      north_coast(organization, version)

      # Two same-mode bus examples whose IDs end in their own numbers give the
      # shared prefix the R3 inference needs (>=2 examples, >=60% agreement).
      route_fixture(organization.id, version.id, %{
        route_id: "B12-101",
        route_short_name: "101",
        route_type: 3,
        agency_id: "NCT"
      })

      route_fixture(organization.id, version.id, %{
        route_id: "B12-202",
        route_short_name: "202",
        route_type: 3,
        agency_id: "NCT"
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")
      open_drawer(view)

      render_change(
        view,
        "validate_new_route",
        %{"route" => draft_params(%{"route_short_name" => "303", "route_type" => "3"})}
      )

      assert has_element?(view, "#new-route-id-value", "B12-303")
      assert has_element?(view, "#new-route-id-reason", "Follows the pattern")
      refute has_element?(view, "#new-route-id-manual")

      drawer_submit(view, %{"route_short_name" => "303", "route_type" => "3"})

      # The preview never became persisted truth on its own: the saved row is
      # what the command allocated (INV-6).
      assert [route] =
               Enum.reject(
                 scoped_routes(organization, version),
                 &(&1.route_id in ["B12-101", "B12-202"])
               )

      assert route.route_id == "B12-303"
      assert route.route_short_name == "303"
    end

    test "falls back to the route number when no pattern supports a prefix", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      north_coast(organization, version)

      route_fixture(organization.id, version.id, %{
        route_id: "B12-101",
        route_short_name: "101",
        route_type: 3,
        agency_id: "NCT"
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")
      open_drawer(view)

      render_change(view, "validate_new_route", %{
        "route" => draft_params(%{"route_short_name" => "5"})
      })

      # One example is never enough for a prefix (R3 needs at least two).
      assert has_element?(view, "#new-route-id-value", "5")
      assert has_element?(view, "#new-route-id-reason", "Made from the route number")
    end

    test "a taken generated value is suffixed rather than refused", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      north_coast(organization, version)

      route_fixture(organization.id, version.id, %{
        route_id: "77",
        route_short_name: "77",
        route_type: 3
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")
      open_drawer(view)

      drawer_submit(view, %{"route_short_name" => "77", "route_type" => "3"})

      assert [route] = Enum.reject(scoped_routes(organization, version), &(&1.route_id == "77"))
      assert route.route_id == "77-2"
    end
  end

  describe "the manual override" do
    test "Change opens the override field and keeps what was typed", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      north_coast(organization, version)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")
      open_drawer(view)

      view |> element("#new-route-id-edit") |> render_click()
      assert has_element?(view, "#new-route-id-manual")

      render_change(view, "validate_new_route", %{"route" => draft_params(%{"route_id" => "R-9"})})

      # The override survives a re-render; the earlier defect dropped it.
      assert has_element?(view, "#new-route-id-manual[value='R-9']")
      assert has_element?(view, "#new-route-id-auto", "Use the generated ID")
    end

    test "a duplicate explicit ID is refused inline and saves nothing", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      north_coast(organization, version)
      route_fixture(organization.id, version.id, %{route_id: "DUP1", agency_id: "NCT"})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")
      open_drawer(view)

      view |> element("#new-route-id-edit") |> render_click()

      drawer_submit(view, %{
        "route_id" => "DUP1",
        "route_short_name" => "D",
        "route_long_name" => "Kept",
        "route_type" => "3"
      })

      # R3: a manual duplicate is never suffixed and never renamed.
      assert has_element?(view, "#new-route-id-error", "has already been taken")
      assert has_element?(view, "#new-route-id-manual[value='DUP1']")
      assert has_element?(view, "#new-route-form-error")
      assert has_element?(view, "#new-route-drawer-overlay[data-open='true']")
      assert_push_event(view, "focus_form_error", %{form_id: "new-route-form"})

      assert Enum.map(scoped_routes(organization, version), & &1.route_id) == ["DUP1"]
    end

    test "returning to the generated ID drops the override", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      north_coast(organization, version)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")
      open_drawer(view)

      view |> element("#new-route-id-edit") |> render_click()

      render_change(view, "validate_new_route", %{"route" => draft_params(%{"route_id" => "R-9"})})

      view |> element("#new-route-id-auto") |> render_click()

      refute has_element?(view, "#new-route-id-manual")
      assert has_element?(view, "#new-route-id-generated")
    end
  end

  describe "saving through the audited command" do
    test "one submit creates one scoped route and opens its Details", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      north_coast(organization, version)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")
      open_drawer(view)

      drawer_submit(view, %{
        "route_short_name" => " N1 ",
        "route_long_name" => "Crosstown",
        "route_type" => "3",
        "route_color" => "",
        "route_text_color" => ""
      })

      assert [route] = scoped_routes(organization, version)
      assert route.organization_id == organization.id
      assert route.gtfs_version_id == version.id
      # The version's only agency is resolved under the version write lock
      # (seam S-1), and R1's name/trim rules applied.
      assert route.agency_id == "NCT"
      assert route.route_short_name == "N1"
      assert route.route_long_name == "Crosstown"
      assert route.route_type == 3
      assert route.route_color == "FFFFFF"
      assert route.route_text_color == "000000"
      assert route.active == true
      assert route.continuous_pickup == 1
      assert route.continuous_drop_off == 1
      assert route.route_sort_order == nil
      assert route.network_id == nil

      # Success navigates to the *saved* route's Details, so the target carries
      # the identifier the command actually allocated rather than the preview.
      assert_redirect(view, "/gtfs/#{version.id}/routes/#{route.route_id}?created=1")

      {:ok, details, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}?created=1")

      assert has_element?(details, "#route-details-heading", "Crosstown")

      assert has_element?(
               details,
               "#route-details-workspace[data-focus-on-mount='route-details-heading']"
             )
    end

    test "the audit is written by the same transaction, with the attempt and digest", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      north_coast(organization, version)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")
      open_drawer(view)

      drawer_submit(view, %{"route_short_name" => "9", "route_type" => "3"})

      assert [route] = scoped_routes(organization, version)

      log =
        Repo.one!(
          from l in ChangeLog,
            where:
              l.organization_id == ^organization.id and l.gtfs_version_id == ^version.id and
                l.entity_type == "route" and l.entity_id == ^route.id and l.action == "created",
            select: l
        )

      assert log.changed_fields["creation_attempt_id"]
      assert String.starts_with?(log.changed_fields["request_digest"], "sha256:")
    end

    test "a double submit while a save is in flight creates one route", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      north_coast(organization, version)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")
      open_drawer(view)

      render_submit(view, "save_new_route", %{
        "_attempt" => attempt_value(view),
        "text_mode" => "automatic",
        "route" => draft_params(%{"route_short_name" => "5", "route_type" => "3"})
      })

      assert_redirect(view, "/gtfs/#{version.id}/routes/5?created=1")
      assert scoped_route_count(organization, version) == 1
    end

    test "an invalid submit marks each invalid field and saves nothing", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      north_coast(organization, version)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")
      open_drawer(view)

      view |> element("#new-route-id-edit") |> render_click()

      drawer_submit(view, %{
        "route_id" => "",
        "route_type" => "",
        "route_short_name" => "",
        "route_long_name" => "",
        "route_color" => "#FF0000"
      })

      # The shared controls own the field-level errors; the identifier's own
      # inline refusal is covered by the duplicate case above.
      assert has_element?(view, "#new-route-mode-error")
      assert has_element?(view, "#new-route-names-error")
      assert has_element?(view, "#new-route-color-error")
      assert has_element?(view, "#new-route-form-error")
      assert has_element?(view, "#new-route-drawer-overlay[data-open='true']")

      assert scoped_route_count(organization, version) == 0
    end

    test "several agencies make the agency a required choice", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      north_coast(organization, version)

      agency_fixture(organization.id, version.id, %{
        agency_id: "HBR",
        agency_name: "Harbor Shuttle"
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")
      open_drawer(view)

      drawer_submit(view, %{"route_short_name" => "A", "route_type" => "3"})

      assert has_element?(
               view,
               "#new-route-agency-error",
               "must be selected when the version has multiple agencies"
             )

      assert scoped_route_count(organization, version) == 0

      drawer_submit(view, %{"route_short_name" => "A", "route_type" => "3", "agency_id" => "HBR"})
      assert [route] = scoped_routes(organization, version)
      assert route.agency_id == "HBR"
    end

    test "an agency from another version is refused on the field and saves nothing", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      north_coast(organization, version)

      agency_fixture(organization.id, version.id, %{
        agency_id: "HBR",
        agency_name: "Harbor Shuttle"
      })

      other_version = gtfs_version_fixture(organization.id)

      agency_fixture(organization.id, other_version.id, %{
        agency_id: "A_OTHER",
        agency_name: "Other Transit"
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")
      open_drawer(view)

      # Another version's agency is never an option, so it has to be crafted to
      # reach the command's own resolution under the version lock (seam S-1).
      render_submit(view, "save_new_route", %{
        "_attempt" => attempt_value(view),
        "text_mode" => "automatic",
        "route" =>
          draft_params(%{
            "route_short_name" => "A",
            "route_type" => "3",
            "agency_id" => "A_OTHER"
          })
      })

      assert has_element?(view, "#new-route-agency-error", "is not available in this version")
      assert has_element?(view, "#new-route-form-error")
      assert has_element?(view, "#new-route-drawer-overlay[data-open='true']")
      assert scoped_route_count(organization, version) == 0
    end
  end

  describe "the write boundary" do
    test "crafted scope and unexposed fields never reach the route", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)
      north_coast(organization, version)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")
      open_drawer(view)

      render_submit(view, "save_new_route", %{
        "_attempt" => attempt_value(view),
        "text_mode" => "automatic",
        "route" =>
          draft_params(%{
            "route_short_name" => "T",
            "route_type" => "3",
            "organization_id" => other_organization.id,
            "gtfs_version_id" => other_version.id,
            "active" => "false",
            "route_sort_order" => "9",
            "network_id" => "N",
            "continuous_pickup" => "0",
            "continuous_drop_off" => "0"
          })
      })

      assert [route] = scoped_routes(organization, version)
      assert route.active == true
      assert route.organization_id == organization.id
      assert route.gtfs_version_id == version.id
      assert route.route_sort_order == nil
      assert route.network_id == nil
      assert route.continuous_pickup == 1
      assert route.continuous_drop_off == 1

      assert Repo.aggregate(
               from(r in Route, where: r.gtfs_version_id == ^other_version.id),
               :count
             ) == 0
    end

    test "a save without the server's attempt writes nothing", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      north_coast(organization, version)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")
      open_drawer(view)

      # A forged or expired token is R3's "no blind save": the draft survives
      # and the operator is told to start a fresh drawer.
      render_submit(view, "save_new_route", %{
        "_attempt" => "forged-token",
        "text_mode" => "automatic",
        "route" => draft_params(%{"route_short_name" => "F", "route_type" => "3"})
      })

      assert scoped_route_count(organization, version) == 0
      assert has_element?(view, "#new-route-failure")
      assert has_element?(view, "#new-route-drawer-overlay[data-open='true']")
      assert_push_event(view, "focus_scoped_target", %{id: "new-route-failure"})
    end

    test "a save while the drawer is closed writes nothing", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      render_submit(view, "save_new_route", %{
        "_attempt" => "anything",
        "route" => draft_params(%{"route_short_name" => "C", "route_type" => "3"})
      })

      assert scoped_route_count(organization, version) == 0
    end

    test "a removed editor role blocks creation", %{
      conn: conn,
      organization: organization,
      version: version,
      user: user
    } do
      north_coast(organization, version)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")
      open_drawer(view)

      Accounts.get_user_org_membership(user.id, organization.id)
      |> Ecto.Changeset.change(roles: [])
      |> Repo.update!()

      drawer_submit(view, %{"route_short_name" => "R", "route_type" => "3"})

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
      north_coast(organization, version)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")
      open_drawer(view)

      Accounts.get_user_org_membership(user.id, organization.id)
      |> Ecto.Changeset.change(deactivated_at: DateTime.utc_now(:second))
      |> Repo.update!()

      drawer_submit(view, %{"route_short_name" => "D", "route_type" => "3"})

      assert scoped_route_count(organization, version) == 0
      assert has_element?(view, "#flash-error", "no longer have editor access")
    end
  end

  describe "closing and discarding" do
    test "Cancel on a clean draft closes the drawer and leaves the filters intact", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      north_coast(organization, version)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes?search=N&agency_id=NCT")

      # A filtered catalog that has not matched anything yet.
      assert has_element?(view, "#routes-count", "0")

      open_drawer(view)
      view |> element("#new-route-cancel") |> render_click()

      assert has_element?(view, "#new-route-drawer-overlay[data-open='false']")
      assert has_element?(view, "#route-filter-form")
      assert has_element?(view, "#route-search-form input[value='N']")
      assert has_element?(view, "#route-filter-form #active")
      assert has_element?(view, "#route-filter-form #route_type")
      assert has_element?(view, "#routes-count", "0")
      assert scoped_route_count(organization, version) == 0
    end

    test "a changed draft asks once before discarding it", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      north_coast(organization, version)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes?search=N&agency_id=NCT")
      open_drawer(view)

      render_change(view, "validate_new_route", %{
        "route" => draft_params(%{"route_long_name" => "Draft"})
      })

      assert has_element?(view, "#new-route-unsaved")

      view |> element("#new-route-cancel") |> render_click()
      assert has_element?(view, "#new-route-discard")
      assert has_element?(view, "#new-route-drawer-overlay[data-open='true']")

      # Keeping the draft leaves both the drawer and the filters alone.
      view |> element("#new-route-discard-cancel") |> render_click()
      assert has_element?(view, "#new-route-drawer-overlay[data-open='true']")
      assert has_element?(view, "#new-route-long[value='Draft']")
      assert has_element?(view, "#route-search-form input[value='N']")

      view |> element("#new-route-cancel") |> render_click()
      view |> element("#new-route-discard-confirm") |> render_click()

      assert has_element?(view, "#new-route-drawer-overlay[data-open='false']")
      assert has_element?(view, "#route-search-form input[value='N']")
      assert scoped_route_count(organization, version) == 0
    end

    test "reopening starts from a clean draft", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      north_coast(organization, version)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      open_drawer(view)

      render_change(view, "validate_new_route", %{
        "route" => draft_params(%{"route_long_name" => "Draft"})
      })

      view |> element("#new-route-drawer-close") |> render_click()
      view |> element("#new-route-discard-confirm") |> render_click()

      open_drawer(view)

      refute has_element?(view, "#new-route-long[value='Draft']")
      refute has_element?(view, "#new-route-unsaved")
      refute has_element?(view, "#new-route-failure")
    end
  end

  describe "recovering uncertain client state" do
    # R3's uncertain-result recovery, driven through the LiveView's own public
    # recovery event with the drawer's signed attempt. The "server committed,
    # the drawer never heard" state is reproduced by committing through the
    # real audited command with the same verified attempt the drawer minted.
    test "a committed create recovers to its original UUID without another insert or audit", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      north_coast(organization, version)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")
      open_drawer(view)
      token = attempt_value(view)

      assert {:ok, %{route: route}} =
               Gtfs.create_editor_route(
                 draft_params(%{
                   "route_short_name" => "W1",
                   "route_long_name" => "North Coast",
                   "route_type" => "3",
                   "agency_id" => "NCT"
                 }),
                 verified_attempt(token),
                 audit_context(user, organization, version)
               )

      view |> render_click("recover_new_route", %{"_attempt" => token})

      # Recovery lands on the original UUID, and the retained create log is
      # still the only audit: reconcile never inserts and never re-audits.
      assert_redirect(view, "/gtfs/#{version.id}/routes/#{route.route_id}?created=1")
      assert scoped_route_count(organization, version) == 1

      assert Repo.one!(
               from l in ChangeLog,
                 where:
                   l.organization_id == ^organization.id and
                     l.gtfs_version_id == ^version.id and l.entity_type == "route" and
                     l.action == "created",
                 select: count(l.id)
             ) == 1
    end

    test "a before-commit loss keeps the same attempt retryable", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      north_coast(organization, version)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")
      open_drawer(view)
      token = attempt_value(view)

      view |> render_click("recover_new_route", %{"_attempt" => token})

      # Nothing committed, so the offline block clears and the drawer keeps
      # its entries and its original signed attempt.
      assert_push_event(view, "route_recovery", %{state: "retryable"})
      assert has_element?(view, "#new-route-form")
      assert attempt_value(view) == token

      # The same attempt still creates, exactly once.
      drawer_submit(view, %{"route_short_name" => "7", "route_type" => "3", "agency_id" => "NCT"})
      assert [_one] = scoped_routes(organization, version)
    end

    test "revoked access keeps the draft without an enabled commit", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      north_coast(organization, version)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")
      open_drawer(view)
      token = attempt_value(view)

      render_change(view, "validate_new_route", %{
        "route" => draft_params(%{"route_short_name" => "W9"}),
        "text_mode" => "automatic"
      })

      Accounts.get_user_org_membership(user.id, organization.id)
      |> Ecto.Changeset.change(roles: [])
      |> Repo.update!()

      view |> render_click("recover_new_route", %{"_attempt" => token})

      # The draft and every typed value stay on screen with the attempt, but
      # the commit is disabled: recovery never re-enables what access forbids.
      assert_push_event(view, "route_recovery", %{state: "blocked"})
      assert has_element?(view, "#new-route-form")
      assert has_element?(view, "#new-route-failure", "no longer have editor access")
      assert attempt_value(view) == token
      assert element(view, "#new-route-short") |> render() =~ "W9"
      assert element(view, "#new-route-submit") |> render() =~ "disabled"

      # A crafted submit cannot sneak past the block.
      render_submit(view, "save_new_route", %{
        "_attempt" => token,
        "text_mode" => "automatic",
        "route" => draft_params(%{"route_short_name" => "W9", "route_type" => "3"})
      })

      assert scoped_route_count(organization, version) == 0
    end

    test "an unknown attempt keeps the draft without an enabled commit", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      north_coast(organization, version)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")
      open_drawer(view)

      render_change(view, "validate_new_route", %{
        "route" => draft_params(%{"route_short_name" => "X1"}),
        "text_mode" => "automatic"
      })

      view |> render_click("recover_new_route", %{"_attempt" => "tampered-token"})

      assert_push_event(view, "route_recovery", %{state: "blocked"})
      assert has_element?(view, "#new-route-form")
      assert has_element?(view, "#new-route-failure", "no longer valid")
      assert element(view, "#new-route-submit") |> render() =~ "disabled"
      assert scoped_route_count(organization, version) == 0
    end
  end

  # The drawer's signed-attempt contract: the same production verification the
  # LiveView performs before any domain call, used here only to reproduce the
  # uncertain "committed but unheard" state with the real command.
  defp verified_attempt(token) do
    {:ok, attempt} =
      Phoenix.Token.verify(GtfsPlannerWeb.Endpoint, "route_creation_attempt", token,
        max_age: 14_400
      )

    attempt
  end

  defp audit_context(user, organization, version) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      actor_id: user.id,
      actor_email: user.email
    }
  end

  defp attempt_value(view) do
    view |> element("#new-route-attempt") |> render() |> attribute_of("value")
  end

  defp attribute_of(html, name) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute(name)
    |> List.first()
  end
end
