defmodule GtfsPlannerWeb.Gtfs.RouteDetailLiveTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.TransfersFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.CatalogReadAdapter
  alias GtfsPlanner.Gtfs.CatalogReadAdapterMock
  alias GtfsPlanner.Repo

  @adapter_key :gtfs_catalog_read_adapter

  setup :verify_on_exit!

  # The real context serves every successful read; the adapter substitution
  # exists only to simulate a lost database connection, and is restored on exit.
  defp substitute_read_adapter(_context) do
    previous = Application.fetch_env(:gtfs_planner, @adapter_key)
    Application.put_env(:gtfs_planner, @adapter_key, CatalogReadAdapterMock)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, @adapter_key, value)
        :error -> Application.delete_env(:gtfs_planner, @adapter_key)
      end
    end)

    :ok
  end

  defp shared_setup(%{conn: conn}) do
    organization =
      organization_fixture(%{alias: "route-detail-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "route-detail-#{System.unique_integer([:positive])}@example.com"})

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    gtfs_version = gtfs_version_fixture(organization.id)

    %{
      conn: log_in_user(conn, user, organization: organization),
      user: user,
      organization: organization,
      gtfs_version: gtfs_version
    }
  end

  # The Details workspace itself. The first case mounts the ordinary
  # authenticated route with the default catalog adapter: `RouteDetailLive`
  # reads through `Gtfs.load_route_editor/3` -> `CatalogReadAdapter.Repo`, so the
  # saved row, its agency options and its audit attribution are all production
  # reads (no private assign injection, no substituted adapter).
  describe "details workspace" do
    setup :shared_setup

    test "ordinary authenticated Details renders the saved values in the shared controls", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      agency_fixture(organization.id, version.id, %{
        agency_id: "AG1",
        agency_name: "Harbor Transit",
        agency_url: "https://harbor.example.com"
      })

      route =
        route_fixture(organization.id, version.id, %{
          route_id: "DETAILS1",
          route_short_name: "D1",
          route_long_name: "Details Route",
          route_type: 3,
          agency_id: "AG1",
          route_desc: "Runs along the waterfront.",
          route_url: "https://example.com/d1",
          route_color: "0B6E4F",
          route_text_color: "FFFFFF",
          route_sort_order: 7,
          continuous_pickup: 2,
          continuous_drop_off: 3,
          network_id: "HARBOR"
        })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      # The header is saved identity, and the form carries the same values.
      assert has_element?(view, "#route-details-heading", "Details Route")
      assert has_element?(view, "#route-details-badge")
      assert has_element?(view, "#route-details-mode-label", "Bus")

      assert has_element?(view, "#route-details-form #route-details-identity")
      assert has_element?(view, "#route-details-form #route-details-color-fields")
      assert has_element?(view, "#route-details-form #route-details-rider")
      assert has_element?(view, "#route-details-form #route-details-additional")

      assert has_element?(view, "input#route-details-short[value='D1']")
      assert has_element?(view, "input#route-details-long[value='Details Route']")
      assert has_element?(view, "textarea#route-details-desc", "Runs along the waterfront.")
      assert has_element?(view, "input#route-details-url[value='https://example.com/d1']")
      assert has_element?(view, "input#route-details-sort[value='7']")
      assert has_element?(view, "input#route-details-network[value='HARBOR']")
      assert has_element?(view, "select#route-details-pickup option[value='2'][selected]")
      assert has_element?(view, "select#route-details-dropoff option[value='3'][selected]")
      assert has_element?(view, "input#route-details-color[value='0B6E4F']")
      assert has_element?(view, "input#route-details-text[value='FFFFFF']")
      # A one-agency version reads the assignment, not a select (AC-5).
      assert has_element?(view, "#route-details-agency-readonly")
      assert has_element?(view, "input[type='hidden']#route-details-agency[value='AG1']")

      # The URL is editable content, never interpolated into a link.
      refute render(view) =~ ~s(href="https://example.com/d1")
    end

    test "Additional details is collapsed, summarizes its values and states the route ID read-only",
         %{
           conn: conn,
           organization: organization,
           gtfs_version: version
         } do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "DETAILS2",
          route_short_name: "D2",
          route_sort_order: 4,
          continuous_pickup: 0,
          continuous_drop_off: 1,
          network_id: "BAY"
        })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      # Collapsed by default (R7/AC-18): no `open` attribute, and the summary
      # repeats the values the closed disclosure still owes the operator.
      refute has_element?(view, "#route-details-additional[open]")

      assert has_element?(
               view,
               "#route-details-additional-summary",
               "Display order 4 · Boarding between stops: Anywhere along the route · Network BAY · Route ID DETAILS2"
             )

      # The natural ID is creation-only (R1), so it is stated, not editable.
      assert has_element?(view, "#route-details-route-id", "DETAILS2")
      assert has_element?(view, "#route-details-additional p", "Route ID")
      refute has_element?(view, "input[name='route[route_id]']")
      assert has_element?(view, "#route-details-additional label[for='route-details-sort']")
    end

    test "network and boarding defaults the route does not have are named as unset, not dropped",
         %{
           conn: conn,
           organization: organization,
           gtfs_version: version
         } do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "DETAILS3",
          route_short_name: "D3",
          route_sort_order: nil,
          network_id: nil
        })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      summary = view |> element("#route-details-additional-summary") |> render()

      assert summary =~ "Display order not set"
      assert summary =~ "Route ID DETAILS3"
      refute summary =~ "Network"
    end

    test "the saved-identity line names the real last-saved actor from the route audit", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      agency_fixture(organization.id, version.id, %{
        agency_id: "AG2",
        agency_name: "Harbor Transit",
        agency_url: "https://harbor.example.com"
      })

      route =
        route_fixture(organization.id, version.id, %{
          route_id: "DETAILS4",
          route_short_name: "D4",
          agency_id: "AG2"
        })

      actor = user_fixture()

      audit = %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        actor_id: actor.id,
        actor_email: actor.email
      }

      {:ok, _log} =
        Repo.transaction(fn ->
          case Gtfs.record_change_in_transaction(audit, :route, route, "updated", %{
                 before: %{"route_short_name" => "D3"},
                 after: %{"route_short_name" => "D4"}
               }) do
            {:ok, log} -> log
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      saved = view |> element("#route-details-saved-identity") |> render()
      assert saved =~ "Harbor Transit"
      assert saved =~ "Route ID DETAILS4"
      assert saved =~ "Last saved"
      assert saved =~ actor.email
    end

    test "a route with no audit entry reads as unknown attribution, never as a recent actor", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "DETAILS5",
          route_short_name: "D5",
          agency_id: nil
        })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      assert has_element?(
               view,
               "#route-details-saved-identity",
               "Last saved never — imported or unknown attribution"
             )
    end

    test "the transfers link keeps counting this route's general rules", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      transfer_network_fixture(organization.id, version.id)

      transfer_fixture(organization.id, version.id, %{
        from_stop_id: "MKT",
        to_stop_id: "HBR",
        from_route_id: "24",
        transfer_type: 0
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/24")

      assert has_element?(view, "#route-transfers-link", "Transfers here (1)")
      assert has_element?(view, "#route-details-map-region")
    end
  end

  # The draft preview and the dirty save bar. Every case drives the real
  # `#route-details-form` the browser drives, with the default catalog adapter:
  # the draft is validated through `Route.editor_changeset/3`, the header shows
  # the valid draft, and nothing here writes (R7, C-2, INV-6).
  describe "details draft preview" do
    setup :shared_setup

    test "a changed color previews in the heading badge without saving, and cancel restores the saved row",
         %{
           conn: conn,
           organization: organization,
           gtfs_version: version
         } do
      route =
        details_route(organization.id, version.id, %{
          route_color: "0B6E4F",
          route_text_color: "FFFFFF"
        })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      # A freshly loaded page is not a draft: no bar, no chip, saved identity.
      assert has_element?(view, "#route-details-save-bar[hidden]")
      refute has_element?(view, "#route-details-unsaved-preview")
      assert render(view) =~ "background-color: #0B6E4F"

      view
      |> form("#route-details-form", %{
        route: %{route_color: "5BC5F2"},
        text_mode: "automatic"
      })
      |> render_change()

      # The draft colour is the header's, the save bar names what a save would
      # change, and the chip says the header is describing a draft. The browser
      # always submits the checked text-mode radio, so Automatic also re-derives
      # the text color and the bar names both fields.
      assert render(view) =~ "background-color: #5BC5F2"
      assert has_element?(view, "#route-details-unsaved-preview", "Unsaved preview")
      refute has_element?(view, "#route-details-save-bar[hidden]")
      assert has_element?(view, "#route-details-save-bar-text", "Unsaved: Route color")
      assert has_element?(view, "#route-details-save-bar-text", "Text color")
      assert has_element?(view, "#route-details-save-bar-text", "Ctrl+S saves")

      # A preview is not a save: the row still holds the saved colour and has
      # not been touched (AC-19, AC-21).
      assert saved_route(route).route_color == "0B6E4F"
      assert saved_route(route).updated_at == route.updated_at

      # Cancel restores the saved values, the saved identity and the clean bar.
      view |> element("#route-details-discard") |> render_click()

      assert render(view) =~ "background-color: #0B6E4F"
      refute has_element?(view, "#route-details-unsaved-preview")
      assert has_element?(view, "#route-details-save-bar[hidden]")
      assert has_element?(view, "input#route-details-color[value='0B6E4F']")
      assert has_element?(view, "input#route-details-text[value='FFFFFF']")
      assert saved_route(route).route_color == "0B6E4F"
      assert saved_route(route).updated_at == route.updated_at
    end

    test "a change that matches the saved row again leaves the save bar hidden", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route =
        details_route(organization.id, version.id, %{
          route_color: "0B6E4F",
          route_text_color: "FFFFFF"
        })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      view
      |> form("#route-details-form", %{
        route: %{route_color: "5BC5F2"},
        text_mode: "automatic"
      })
      |> render_change()

      refute has_element?(view, "#route-details-save-bar[hidden]")

      # Typing the saved values back is not a draft any more, so the bar and the
      # chip go away instead of claiming unsaved work (AC-21).
      view
      |> form("#route-details-form", %{
        route: %{route_color: "0B6E4F", route_text_color: "FFFFFF"},
        text_mode: "automatic"
      })
      |> render_change()

      assert has_element?(view, "#route-details-save-bar[hidden]")
      refute has_element?(view, "#route-details-unsaved-preview")
      assert render(view) =~ "background-color: #0B6E4F"
    end

    test "a submitted draft persists through the audited command and reloads saved values", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      route = details_route(organization.id, version.id, %{})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      view
      |> form("#route-details-form", %{
        route: %{route_long_name: "Renamed for real"},
        text_mode: "automatic"
      })
      |> render_submit()

      # The saved row holds the draft, the form and header read it back as
      # saved truth, and the attribution line names the editor who saved.
      saved = saved_route(route)
      assert saved.route_long_name == "Renamed for real"
      assert saved.updated_at != route.updated_at

      assert has_element?(view, "input#route-details-long[value='Renamed for real']")
      assert has_element?(view, "#route-details-heading", "Renamed for real")
      assert has_element?(view, "#route-details-saved", "Changes to Route PREVIEW1 saved.")
      assert has_element?(view, "#route-details-save-bar[hidden]")
      refute has_element?(view, "#route-details-unsaved-preview")
      assert has_element?(view, "#route-details-saved-identity", user.email)
      refute has_element?(view, "#route-conflict")
    end

    test "a no-op submit writes nothing and says so", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route = details_route(organization.id, version.id, %{})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      view
      |> form("#route-details-form", %{text_mode: "automatic"})
      |> render_submit()

      assert saved_route(route).updated_at == route.updated_at
      assert has_element?(view, "#route-details-saved", "Nothing to save")
      assert has_element?(view, "#route-details-save-bar[hidden]")
    end

    test "a server-side error keeps the draft on screen and writes nothing", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      agency_fixture(organization.id, version.id, %{agency_id: "GONE", agency_name: "Vanishing"})

      route = details_route(organization.id, version.id, %{})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      # The agency disappears after the workspace loaded; only the command's
      # in-transaction recheck (seam S-1) can catch the submission.
      gone =
        Repo.get_by!(GtfsPlanner.Gtfs.Agency,
          organization_id: organization.id,
          gtfs_version_id: version.id,
          agency_id: "GONE"
        )

      Repo.delete!(gone)

      view
      |> form("#route-details-form", %{
        route: %{agency_id: "GONE", route_long_name: "Draft kept on failure"},
        text_mode: "automatic"
      })
      |> render_submit()

      saved = saved_route(route)
      assert saved.route_long_name == "Details long name"
      assert saved.agency_id != "GONE"
      assert saved.updated_at == route.updated_at

      assert has_element?(view, "#route-details-save-error", "Not saved.")
      assert has_element?(view, "#route-details-save-error", "Agency")
      assert has_element?(view, "input#route-details-long[value='Draft kept on failure']")
      refute has_element?(view, "#route-details-save-bar[hidden]")
    end

    test "an invalid draft color keeps the input and its error, and never reaches the badge", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route =
        details_route(organization.id, version.id, %{
          route_color: "0B6E4F",
          route_text_color: "FFFFFF"
        })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      view
      |> form("#route-details-form", %{
        route: %{route_color: "ZZZ"},
        text_mode: "automatic"
      })
      |> render_change()

      # The rejected value stays where the operator typed it, with its own
      # message, and the badge keeps the neutral surface `route_badge/1` renders
      # for a value the application cannot draw (R7, AC-2).
      assert has_element?(view, "input#route-details-color[value='ZZZ']")
      assert has_element?(view, "#route-details-color-error", "hex color code")
      assert has_element?(view, "#route-details-badge span.bg-canvas")
      refute render(view) =~ "background-color: #ZZZ"
      assert saved_route(route).route_color == "0B6E4F"
      assert saved_route(route).updated_at == route.updated_at
    end
  end

  # The save and merge outcomes: every case drives the ordinary public
  # entrypoint and the real `Gtfs.update_route/5` command — the "other editor"
  # is a second committed command call with its own audit context, so each
  # conflict is a real stored divergence, never a mocked one.
  describe "details save and merge outcomes" do
    setup :shared_setup

    test "disjoint changes from another editor require one explicit Save both, then apply", %{
      conn: conn,
      organization: organization,
      gtfs_version: version,
      user: user
    } do
      route = details_route(organization.id, version.id, %{})
      other = other_editor(organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      # The other editor saves a disjoint field while this session edits.
      assert {:ok, _saved} =
               other_editor_save(route, %{route_desc: "Saved by the other editor first."}, other)

      view
      |> form("#route-details-form", %{
        route: %{route_long_name: "My disjoint rename"},
        text_mode: "automatic"
      })
      |> render_submit()

      # The comparison is displayed, nothing of mine is written, and the
      # banner names the editor who actually saved and when.
      assert has_element?(view, "#route-conflict", "saved this route")
      assert has_element?(view, "#route-conflict", "while you were editing")
      assert has_element?(view, "#route-conflict", other.email)
      assert has_element?(view, "#route-conflict-table", "Saved by the other editor first.")
      assert has_element?(view, "#route-conflict-table", "My disjoint rename")
      assert has_element?(view, "#route-conflict-save", "Save both changes")
      refute has_element?(view, "#route-conflict fieldset")

      saved = saved_route(route)
      assert saved.route_long_name == "Details long name"
      assert saved.route_desc == "Saved by the other editor first."
      assert saved.updated_at != route.updated_at

      # The deliberate merge carries the draft plus the displayed revision's
      # binding; the command applies both sets and the workspace reloads.
      view
      |> form("#route-details-form", %{
        route: %{route_long_name: "My disjoint rename"},
        text_mode: "automatic"
      })
      |> render_submit(%{"merge_confirm" => "true"})

      saved = saved_route(route)
      assert saved.route_long_name == "My disjoint rename"
      assert saved.route_desc == "Saved by the other editor first."

      assert has_element?(view, "input#route-details-long[value='My disjoint rename']")
      assert has_element?(view, "#route-details-saved", "Changes to Route PREVIEW1 saved.")
      refute has_element?(view, "#route-conflict")
      assert has_element?(view, "#route-details-save-bar[hidden]")
      assert has_element?(view, "#route-details-saved-identity", user.email)
    end

    test "overlapping edits require per-field choices and the loser is never written", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route =
        details_route(organization.id, version.id, %{
          route_color: "0B6E4F",
          route_text_color: "FFFFFF"
        })

      other = other_editor(organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      assert {:ok, _saved} = other_editor_save(route, %{route_long_name: "Their rename"}, other)

      view
      |> form("#route-details-form", %{
        route: %{route_long_name: "My rename", route_color: "5BC5F2"},
        text_mode: "automatic"
      })
      |> render_submit()

      # The overlap demands choices; the disjoint color is listed too.
      assert has_element?(view, "#route-conflict", "choose which value to keep")
      assert has_element?(view, "#route-conflict-save", "Save chosen changes")

      assert has_element?(
               view,
               "#route-conflict input[name='merge[fields][route_long_name]'][value='mine'][required]"
             )

      refute saved_color_changed?(route)
      assert saved_route(route).route_long_name == "Their rename"

      # Keeping theirs for the name keeps my color: one deliberate submission.
      view
      |> form("#route-details-form", %{
        route: %{route_long_name: "My rename", route_color: "5BC5F2"},
        text_mode: "automatic"
      })
      |> render_submit(%{
        "merge_confirm" => "true",
        "merge" => %{"fields" => %{"route_long_name" => "theirs"}}
      })

      saved = saved_route(route)
      assert saved.route_long_name == "Their rename"
      assert saved.route_color == "5BC5F2"
      assert has_element?(view, "input#route-details-long[value='Their rename']")
      assert has_element?(view, "#route-details-saved", "Changes to Route PREVIEW1 saved.")
      refute has_element?(view, "#route-conflict")
    end

    test "a third writer's save during a merge is re-presented, never overwritten", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route = details_route(organization.id, version.id, %{})
      other = other_editor(organization)
      third = other_editor(organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      assert {:ok, _saved} = other_editor_save(route, %{route_long_name: "First rename"}, other)

      view
      |> form("#route-details-form", %{
        route: %{route_long_name: "My rename"},
        text_mode: "automatic"
      })
      |> render_submit()

      assert has_element?(view, "#route-conflict")

      # A third writer commits while the comparison is on screen; the merge
      # was bound to the displayed revision, so the command refuses it.
      assert {:ok, _saved} =
               other_editor_save(route, %{route_long_name: "Third rename"}, third)

      displayed = saved_route(route)

      view
      |> form("#route-details-form", %{
        route: %{route_long_name: "My rename"},
        text_mode: "automatic"
      })
      |> render_submit(%{"merge_confirm" => "true"})

      assert saved_route(route).route_long_name == "Third rename"
      assert has_element?(view, "#route-conflict", "Third rename")
      refute has_element?(view, "#route-details-saved")

      # A fresh comparison, fresh choices, and the merge lands on the newest
      # current with my value.
      view
      |> form("#route-details-form", %{
        route: %{route_long_name: "My rename"},
        text_mode: "automatic"
      })
      |> render_submit(%{
        "merge_confirm" => "true",
        "merge" => %{"fields" => %{"route_long_name" => "mine"}}
      })

      assert saved_route(route).route_long_name == "My rename"
      assert saved_route(route).updated_at != displayed.updated_at
      assert has_element?(view, "input#route-details-long[value='My rename']")
      refute has_element?(view, "#route-conflict")
    end

    test "a base-equal draft against a changed current reloads the latest instead of offering a merge",
         %{
           conn: conn,
           organization: organization,
           gtfs_version: version
         } do
      route = details_route(organization.id, version.id, %{})
      other = other_editor(organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      assert {:ok, _saved} =
               other_editor_save(route, %{route_desc: "Saved while the page was open."}, other)

      view
      |> form("#route-details-form", %{text_mode: "automatic"})
      |> render_submit()

      # A draft that changes nothing has no merge to offer: the latest saved
      # values are loaded and the outcome is announced.
      refute has_element?(view, "#route-conflict")
      assert has_element?(view, "textarea#route-details-desc", "Saved while the page was open.")
      assert saved_route(route).route_long_name == "Details long name"
      assert render(view) =~ "Another editor saved this route while it was open"
    end

    test "discarding during a conflict loads the latest saved route", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route = details_route(organization.id, version.id, %{})
      other = other_editor(organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      assert {:ok, _saved} = other_editor_save(route, %{route_desc: "The latest saved."}, other)

      view
      |> form("#route-details-form", %{
        route: %{route_long_name: "A draft"},
        text_mode: "automatic"
      })
      |> render_submit()

      assert has_element?(view, "#route-conflict")

      view |> element("#route-conflict-discard") |> render_click()

      refute has_element?(view, "#route-conflict")
      assert has_element?(view, "textarea#route-details-desc", "The latest saved.")
      assert has_element?(view, "input#route-details-long[value='Details long name']")
      assert has_element?(view, "#route-details-save-bar[hidden]")
      assert render(view) =~ "Loaded the latest saved route. Your changes were discarded."
      assert saved_route(route).route_long_name == "Details long name"
    end
  end

  # The dirty-navigation guard (AC-22). Every case mounts the ordinary public
  # entrypoint and drives the same events the client guard sends — the version
  # switch events and the intercepted link/back path — with the default catalog
  # adapter, so the guard's decision and the command it can trigger are the
  # production path. The browser half of the mechanics (native beforeunload,
  # history restore, the intercepted option click) is the focused Playwright
  # suite's job.
  describe "dirty navigation guard" do
    setup :shared_setup

    test "cancelling a version change keeps the draft, the URL and the version selection intact",
         %{
           conn: conn,
           organization: organization,
           gtfs_version: version
         } do
      route = details_route(organization.id, version.id, %{})
      other_version = gtfs_version_fixture(organization.id)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      view
      |> form("#route-details-form", %{
        route: %{route_long_name: "Unsaved rename"},
        text_mode: "automatic"
      })
      |> render_change()

      # A dirty draft holds the switch behind the leave dialog instead of
      # dispatching it: the dialog names the route and the field that would be
      # lost, and the selection effect is never sent.
      render_hook(view, "switch_gtfs_version", %{"version" => other_version.id})

      assert has_element?(view, "#route-details-leave[data-open='true']", "Leave without saving?")
      assert has_element?(view, "#route-details-leave-body", "Route PREVIEW1")
      assert has_element?(view, "#route-details-leave-body", "Route name")
      assert has_element?(view, "#route-details-leave-cancel", "Keep editing")
      assert has_element?(view, "#route-details-leave-save", "Save and continue")

      refute_push_event(view, "gtfs_version_selected", %{})

      # Keep editing closes the dialog with the draft exactly as it was, on the
      # same URL, with nothing written (AC-22).
      view |> element("#route-details-leave-cancel") |> render_click()

      refute has_element?(view, "#route-details-leave[data-open='true']")
      assert has_element?(view, "input#route-details-long[value='Unsaved rename']")
      refute has_element?(view, "#route-details-save-bar[hidden]")
      assert saved_route(route).route_long_name == "Details long name"
      assert saved_route(route).updated_at == route.updated_at
    end

    test "a dirty page holds both version-switch events and discard navigates without writing", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route = details_route(organization.id, version.id, %{})
      other_version = gtfs_version_fixture(organization.id)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      view
      |> form("#route-details-form", %{
        route: %{route_long_name: "Unsaved rename"},
        text_mode: "automatic"
      })
      |> render_change()

      render_hook(view, "gtfs_version_loaded", %{"version_id" => other_version.id})
      assert has_element?(view, "#route-details-leave[data-open='true']")

      # Discard navigates and writes nothing: the saved row is untouched, and a
      # cross-version destination takes the switcher's stored selection with it,
      # exactly as an unguarded switch would have.
      view |> element("#route-details-leave-discard") |> render_click()

      assert_redirect(view, "/gtfs/#{other_version.id}/routes/#{route.route_id}")
      other_id = other_version.id
      assert_push_event(view, "gtfs_version_selected", %{version_id: ^other_id})

      assert saved_route(route).route_long_name == "Details long name"
      assert saved_route(route).updated_at == route.updated_at

      # The other switch event is guarded the same way on a fresh mount.
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      view
      |> form("#route-details-form", %{
        route: %{route_long_name: "Unsaved rename"},
        text_mode: "automatic"
      })
      |> render_change()

      render_hook(view, "switch_gtfs_version", %{"version" => other_version.id})
      assert has_element?(view, "#route-details-leave[data-open='true']")

      view |> element("#route-details-leave-discard") |> render_click()
      assert_redirect(view, "/gtfs/#{other_version.id}/routes/#{route.route_id}")
    end

    test "save and continue commits the draft and only then navigates", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route = details_route(organization.id, version.id, %{})
      other_version = gtfs_version_fixture(organization.id)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      view
      |> form("#route-details-form", %{
        route: %{route_long_name: "Saved on the way out"},
        text_mode: "automatic"
      })
      |> render_change()

      render_hook(view, "switch_gtfs_version", %{"version" => other_version.id})
      assert has_element?(view, "#route-details-leave[data-open='true']")

      view |> element("#route-details-leave-save") |> render_click()

      assert_redirect(view, "/gtfs/#{other_version.id}/routes/#{route.route_id}")

      saved = saved_route(route)
      assert saved.route_long_name == "Saved on the way out"
      assert saved.updated_at != route.updated_at
    end

    test "an invalid save-and-continue stays on the page with the draft and its errors", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route = details_route(organization.id, version.id, %{})
      other_version = gtfs_version_fixture(organization.id)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      view
      |> form("#route-details-form", %{
        route: %{route_long_name: "Never lands", route_color: "ZZZ"},
        text_mode: "automatic"
      })
      |> render_change()

      render_hook(view, "switch_gtfs_version", %{"version" => other_version.id})
      assert has_element?(view, "#route-details-leave[data-open='true']")

      # The command rejects the draft, so the navigation never happens: the
      # operator stays here with the draft, its errors and a closed dialog.
      view |> element("#route-details-leave-save") |> render_click()

      assert has_element?(view, "#route-details-save-error", "Not saved")
      assert has_element?(view, "input#route-details-long[value='Never lands']")
      assert has_element?(view, "input#route-details-color[value='ZZZ']")
      refute has_element?(view, "#route-details-leave[data-open='true']")
      refute has_element?(view, "#route-details-save-bar[hidden]")

      assert saved_route(route).route_long_name == "Details long name"
      assert saved_route(route).updated_at == route.updated_at
    end

    test "an unchanged page navigates from the guard without a dialog, and a foreign path is ignored",
         %{
           conn: conn,
           organization: organization,
           gtfs_version: version
         } do
      route = details_route(organization.id, version.id, %{})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      # A clean page navigates straight away when the client guard reports a
      # departure it intercepted before dispatch.
      render_hook(view, "guard_details_navigation", %{"path" => "/gtfs/#{version.id}/routes"})

      assert_redirect(view, "/gtfs/#{version.id}/routes")

      # Only same-origin absolute paths are resolved; anything else changes
      # nothing and opens nothing.
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      render_hook(view, "guard_details_navigation", %{"path" => "https://evil.example/routes"})

      refute has_element?(view, "#route-details-leave[data-open='true']")
      assert has_element?(view, "#route-details-heading")
    end

    test "an open merge counts as unsaved work, and discarding it writes nothing", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route = details_route(organization.id, version.id, %{})
      other = other_editor(organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      assert {:ok, _saved} = other_editor_save(route, %{route_desc: "The latest saved."}, other)

      view
      |> form("#route-details-form", %{
        route: %{route_long_name: "A draft"},
        text_mode: "automatic"
      })
      |> render_submit()

      assert has_element?(view, "#route-conflict")

      # An unresolved comparison is unsaved work: leaving is guarded, and the
      # discard path navigates without writing either editor's values.
      render_hook(view, "guard_details_navigation", %{"path" => "/gtfs/#{version.id}/routes"})

      assert has_element?(view, "#route-details-leave[data-open='true']")

      view |> element("#route-details-leave-discard") |> render_click()

      assert_redirect(view, "/gtfs/#{version.id}/routes")
      assert saved_route(route).route_long_name == "Details long name"
      assert saved_route(route).route_desc == "The latest saved."
    end
  end

  describe "recovering uncertain client state" do
    setup :shared_setup

    test "reconnect with intact access clears the offline block and keeps the draft", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route = details_route(organization.id, version.id, %{})
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      view
      |> form("#route-details-form", %{text_mode: "automatic"})
      |> render_change(route: %{"route_long_name" => "Renamed while offline"})

      view |> render_click("recover_route_details", %{})

      # Access revalidated, so the block clears — and the workspace was never
      # re-read: the draft is still the unsaved work on screen.
      assert_push_event(view, "route_recovery", %{state: "retryable"})
      assert has_element?(view, "#route-details-save-bar", "Route name")
      assert element(view, "#route-details-long") |> render() =~ "Renamed while offline"
      refute element(view, "#route-save") |> render() =~ "disabled"
    end

    test "revoked access keeps the draft and blocks the commit", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      route = details_route(organization.id, version.id, %{})
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      view
      |> form("#route-details-form", %{text_mode: "automatic"})
      |> render_change(route: %{"route_long_name" => "Renamed while offline"})

      Accounts.get_user_org_membership(user.id, organization.id)
      |> Ecto.Changeset.change(roles: [])
      |> Repo.update!()

      view |> render_click("recover_route_details", %{})

      assert_push_event(view, "route_recovery", %{state: "blocked"})
      assert has_element?(view, "#route-details-save-error", "no longer have editor access")
      assert has_element?(view, "#route-details-save-bar", "Route name")
      assert element(view, "#route-details-long") |> render() =~ "Renamed while offline"
      assert element(view, "#route-save") |> render() =~ "disabled"

      # A crafted submit cannot write past the block.
      view
      |> form("#route-details-form", %{text_mode: "automatic"})
      |> render_submit()

      assert saved_route(route).route_long_name == route.route_long_name
      assert saved_route(route).updated_at == route.updated_at
    end

    test "recovery never rebases the draft on a fresh read", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route = details_route(organization.id, version.id, %{})
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      view
      |> form("#route-details-form", %{text_mode: "automatic"})
      |> render_change(route: %{"route_long_name" => "My offline draft"})

      # While this socket is "offline", another editor saves the same field.
      other = other_editor(organization)
      assert {:ok, _saved} = other_editor_save(route, %{route_long_name: "Their rename"}, other)

      view |> render_click("recover_route_details", %{})
      assert_push_event(view, "route_recovery", %{state: "retryable"})

      # The draft still carries the base it was loaded with, so the save meets
      # the other editor's change as a conflict instead of a silent overwrite.
      assert has_element?(view, "#route-details-save-bar", "Route name")
      assert element(view, "#route-details-long") |> render() =~ "My offline draft"

      view
      |> form("#route-details-form", %{text_mode: "automatic"})
      |> render_submit()

      assert has_element?(view, "#route-conflict")
      assert saved_route(route).route_long_name == "Their rename"
    end
  end

  defp other_editor(organization) do
    user =
      user_fixture(%{email: "other-editor-#{System.unique_integer([:positive])}@example.com"})

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    user
  end

  defp other_editor_save(route, attrs, actor) do
    audit = %AuditContext{
      organization_id: route.organization_id,
      gtfs_version_id: route.gtfs_version_id,
      actor_id: actor.id,
      actor_email: actor.email
    }

    base = GtfsPlanner.Gtfs.Routes.source(Repo.get!(GtfsPlanner.Gtfs.Route, route.id))
    Gtfs.update_route(route.route_id, attrs, base, %{}, audit)
  end

  defp saved_color_changed?(route),
    do: saved_route(route).route_color != route.route_color

  defp details_route(organization_id, gtfs_version_id, overrides) do
    route_fixture(
      organization_id,
      gtfs_version_id,
      Map.merge(
        %{
          route_id: "PREVIEW1",
          route_short_name: "P1",
          route_long_name: "Details long name",
          route_type: 3,
          route_color: "0B6E4F",
          route_text_color: "FFFFFF"
        },
        overrides
      )
    )
  end

  defp saved_route(route), do: Repo.get!(GtfsPlanner.Gtfs.Route, route.id)

  describe "route not found and unavailable" do
    setup :shared_setup

    test "not-found route redirects with flash", %{
      conn: conn,
      gtfs_version: version
    } do
      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, "/gtfs/#{version.id}/routes/MISSING")

      assert to == "/gtfs/#{version.id}/routes"
    end

    test "unavailable route renders error state with retry button", %{
      conn: conn,
      gtfs_version: version
    } do
      substitute_read_adapter(%{})

      stub(CatalogReadAdapterMock, :load_route_editor, fn _org, _ver, _route_id ->
        {:error, :unavailable}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/UNAVAIL")

      assert has_element?(view, "#route-unavailable")
      assert has_element?(view, "#route-retry")
    end

    test "retry restores the workspace after unavailable", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      substitute_read_adapter(%{})

      route =
        route_fixture(organization.id, version.id, %{
          route_id: "RETRY1",
          route_short_name: "R1"
        })

      call_count = :atomics.new(1, [])

      stub(CatalogReadAdapterMock, :load_route_editor, fn org, ver, route_id ->
        count = :atomics.add_get(call_count, 1, 1)

        if count <= 2 do
          {:error, :unavailable}
        else
          CatalogReadAdapter.Repo.load_route_editor(org, ver, route_id)
        end
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/RETRY1")

      assert has_element?(view, "#route-unavailable")

      view
      |> element("#route-retry")
      |> render_click()

      refute has_element?(view, "#route-unavailable")
      assert has_element?(view, "#route-details-form")
      assert has_element?(view, "input#route-details-short[value='R1']")
      assert route.route_id == "RETRY1"
    end
  end

  describe "patterns tab" do
    setup :shared_setup

    test "links into the pattern editor for the selected route", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "PATNAV1",
          route_short_name: "PN"
        })

      {:ok, view, _html} =
        live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      assert has_element?(
               view,
               "nav[aria-label='Route navigation'] a[href='/gtfs/#{version.id}/routes/#{route.route_id}/patterns']"
             )
    end
  end

  describe "route tab bar" do
    setup :shared_setup

    test "every route page renders the three tabs with aria-current on the current one", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "TABS1",
          route_short_name: "TB"
        })

      base = "/gtfs/#{version.id}/routes/#{route.route_id}"
      nav = "nav[aria-label='Route navigation']"

      {:ok, details_view, _html} = live(conn, base)

      assert has_element?(
               details_view,
               "#{nav} a[href='#{base}'][aria-current='page']",
               "Details"
             )

      assert has_element?(details_view, "#{nav} a[href='#{base}/patterns']", "Patterns")
      assert has_element?(details_view, "#{nav} a[href='#{base}/schedules']", "Schedules")
      refute has_element?(details_view, "#{nav} a[href='#{base}/patterns'][aria-current='page']")
      refute has_element?(details_view, "#schedules-deferred")

      {:ok, patterns_view, _html} = live(conn, "#{base}/patterns")

      assert has_element?(
               patterns_view,
               "#{nav} a[href='#{base}/patterns'][aria-current='page']",
               "Patterns"
             )

      assert has_element?(patterns_view, "#{nav} a[href='#{base}/schedules']", "Schedules")
      refute has_element?(patterns_view, "#{nav} a[href='#{base}'][aria-current='page']")

      {:ok, schedules_view, _html} = live(conn, "#{base}/schedules")

      assert has_element?(
               schedules_view,
               "#{nav} a[href='#{base}/schedules'][aria-current='page']",
               "Schedules"
             )

      assert has_element?(schedules_view, "#{nav} a[href='#{base}']", "Details")
      assert has_element?(schedules_view, "#{nav} a[href='#{base}/patterns']", "Patterns")

      refute has_element?(
               schedules_view,
               "#{nav} a[href='#{base}/patterns'][aria-current='page']"
             )

      refute has_element?(schedules_view, "#schedules-deferred")
    end
  end

  describe "route ID with reserved URL characters" do
    setup :shared_setup

    test "encodes the Patterns and Schedules tab links and opens both pages", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route_fixture(organization.id, version.id, %{route_id: "QA/SLASH 1"})
      base = "/gtfs/#{version.id}/routes/QA%2FSLASH%201"
      nav = "nav[aria-label='Route navigation']"

      {:ok, details_view, _html} = live(conn, base)

      assert has_element?(
               details_view,
               "#{nav} a[href='#{base}'][aria-current='page']",
               "Details"
             )

      assert has_element?(details_view, "#{nav} a[href='#{base}/patterns']", "Patterns")
      assert has_element?(details_view, "#{nav} a[href='#{base}/schedules']", "Schedules")

      [patterns_href] = tab_hrefs(details_view, "#{nav} a[href$='/patterns']")
      [schedules_href] = tab_hrefs(details_view, "#{nav} a[href$='/schedules']")

      {:ok, patterns_view, _html} = live(conn, patterns_href)

      assert has_element?(
               patterns_view,
               "#{nav} a[href='#{base}/patterns'][aria-current='page']",
               "Patterns"
             )

      {:ok, schedules_view, _html} = live(conn, schedules_href)

      assert has_element?(
               schedules_view,
               "#{nav} a[href='#{base}/schedules'][aria-current='page']",
               "Schedules"
             )
    end
  end

  defp tab_hrefs(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("href")
  end

  describe "related transfers" do
    setup :shared_setup

    test "the details fact counts this route's general rules and opens the filtered list", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      transfer_network_fixture(organization.id, version.id)

      route_rule =
        transfer_fixture(organization.id, version.id, %{
          from_stop_id: "MKT",
          to_stop_id: "HBR",
          from_route_id: "24",
          transfer_type: 2,
          min_transfer_time: 180
        })

      trip_rule =
        transfer_fixture(organization.id, version.id, %{
          from_stop_id: "CEN-A",
          to_stop_id: "CEN-C",
          from_trip_id: "24-0840",
          transfer_type: 0
        })

      # Both of this in-seat row's trips run on route 24, and it is still not
      # counted: related counts cover general rules only (CR-1, INV-1).
      transfer_fixture(organization.id, version.id, %{
        from_stop_id: "CEN",
        to_stop_id: "CEN",
        from_trip_id: "12-0815",
        to_trip_id: "24-0840",
        transfer_type: 4
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/24")

      assert has_element?(view, "#route-transfers-link", "Transfers here (2)")

      href = link_href(view, "#route-transfers-link")

      assert href == "/gtfs/#{version.id}/transfers?route=24"

      {:ok, list, _html} = live(conn, href)

      assert Enum.sort(row_ids(list)) ==
               Enum.sort(["transfers-#{route_rule.id}", "transfers-#{trip_rule.id}"])
    end

    test "a route with no rules reads zero and opens an empty list", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      transfer_network_fixture(organization.id, version.id)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/24")

      assert has_element?(view, "#route-transfers-link", "Transfers here (0)")

      {:ok, list, _html} = live(conn, link_href(view, "#route-transfers-link"))

      assert row_ids(list) == []
    end

    test "retrying an unavailable route assigns the count as well", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      transfer_network_fixture(organization.id, version.id)

      transfer_fixture(organization.id, version.id, %{
        from_stop_id: "MKT",
        to_stop_id: "HBR",
        from_route_id: "24",
        transfer_type: 0
      })

      substitute_read_adapter(%{})
      call_count = :atomics.new(1, [])

      stub(CatalogReadAdapterMock, :load_route_editor, fn org, ver, route_id ->
        # `live/2` runs `handle_params/3` once for the static render and once for
        # the connected one, as the retry case above records.
        if :atomics.add_get(call_count, 1, 1) <= 2 do
          {:error, :unavailable}
        else
          CatalogReadAdapter.Repo.load_route_editor(org, ver, route_id)
        end
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/24")

      assert has_element?(view, "#route-unavailable")
      refute has_element?(view, "#route-transfers-link")

      view |> element("#route-retry") |> render_click()

      assert has_element?(view, "#route-transfers-link", "Transfers here (1)")
    end
  end

  describe "details advisory field warnings" do
    setup :shared_setup

    # AC-20's two-sided rule: warnings are advisory and changed-field-only, so
    # the imported values this route already carries never warn on their own —
    # but a changed conflicting value produces the advisory and the save still
    # goes through the ordinary audited command.
    test "unchanged imported values warn nothing, and a changed conflicting color advises while staying saveable",
         %{conn: conn, organization: organization, gtfs_version: version} do
      agency_fixture(organization.id, version.id, %{
        agency_id: "AG1",
        agency_name: "Harbor Transit",
        agency_url: "https://harbor.example.com"
      })

      route =
        details_route(organization.id, version.id, %{
          agency_id: "AG1",
          route_url: "https://harbor.example.com",
          route_desc: nil
        })

      # A saved neighbour the draft could collide with: same number once trimmed
      # and case-folded, and a color one hex step away.
      route_fixture(organization.id, version.id, %{
        route_id: "OTHER1",
        route_short_name: "p1",
        route_color: "0B6E4E",
        route_text_color: "FFFFFF"
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      # An unrelated edit earns no advisory from any unchanged imported value.
      view
      |> form("#route-details-form", %{route: %{route_desc: "Runs along the waterfront."}})
      |> render_change()

      refute has_element?(view, "#route-details-short-warn")
      refute has_element?(view, "#route-details-color-warn")
      refute has_element?(view, "#route-details-url-warn")
      refute has_element?(view, "#route-details-cont-warn")

      # The changed conflicting color does warn, and names the neighbour.
      view
      |> form("#route-details-form", %{route: %{route_color: "0B6E4E"}, text_mode: "automatic"})
      |> render_change()

      assert has_element?(view, "#route-details-color-warn", "Looks like Route OTHER1 (#0B6E4E)")
      assert has_element?(view, "#route-details-color-warn", "You can still use it.")

      # Advisory, not an error: the save goes through and writes the draft.
      view
      |> form("#route-details-form", %{route: %{route_color: "0B6E4E"}, text_mode: "automatic"})
      |> render_submit()

      assert saved_route(route).route_color == "0B6E4E"
      assert has_element?(view, "#route-details-saved", "Changes to Route PREVIEW1 saved.")
      refute has_element?(view, "#route-details-color-warn")
    end

    test "duplicate and long numbers warn from the scoped saved candidates",
         %{conn: conn, organization: organization, gtfs_version: version} do
      route =
        details_route(organization.id, version.id, %{
          route_short_name: "N1",
          route_color: "0B6E4F"
        })

      route_fixture(organization.id, version.id, %{
        route_id: "TWIN1",
        route_short_name: "n1",
        route_color: "123456"
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      # Trimmed and case-folded, "n1" is TWIN1's number.
      view
      |> form("#route-details-form", %{route: %{route_short_name: "n1"}})
      |> render_change()

      assert has_element?(view, "#route-details-short-warn", "Route TWIN1")
      assert has_element?(view, "#route-details-short-warn", "already uses the number “n1”")
      assert has_element?(view, "#route-details-short-warn", "You can still save.")

      # A number over 12 code points earns the length note instead.
      view
      |> form("#route-details-form", %{route: %{route_short_name: "1234567890123"}})
      |> render_change()

      assert has_element?(view, "#route-details-short-warn", "longer than 12 characters")
      refute has_element?(view, "#route-details-short-warn", "TWIN1")
    end

    test "the agency home page warns by exact normalized comparison",
         %{conn: conn, organization: organization, gtfs_version: version} do
      agency_fixture(organization.id, version.id, %{
        agency_id: "AG1",
        agency_name: "Harbor Transit",
        agency_url: "https://harbor.example.com"
      })

      route = details_route(organization.id, version.id, %{})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      # Case and a trailing slash do not make the agency home page a route page.
      view
      |> form("#route-details-form", %{route: %{route_url: "HTTPS://HARBOR.Example.com/"}})
      |> render_change()

      assert has_element?(view, "#route-details-url-warn", "This is Harbor Transit’s home page")
      assert has_element?(view, "#route-details-url-warn", "such as its timetable")

      view
      |> form("#route-details-form", %{route: %{route_url: "https://harbor.example.com/d1"}})
      |> render_change()

      refute has_element?(view, "#route-details-url-warn")
    end

    # R7: enabled continuous boarding with *known* missing paths warns with the
    # pattern count; unknown geometry (a referenced stop that does not exist) is
    # unavailable and is never reported missing.
    test "continuous boarding warns with known missing paths and never fabricates them from unavailable geometry",
         %{conn: conn, organization: organization, gtfs_version: version} do
      route =
        details_route(organization.id, version.id, %{
          route_id: "CONT1",
          route_short_name: "C1"
        })

      pattern =
        route_pattern_fixture(organization.id, version.id, %{
          route_pattern_id: "cp1",
          route_id: "CONT1"
        })

      stop_fixture(organization.id, version.id, %{
        stop_id: "located",
        stop_lat: Decimal.new("1.0"),
        stop_lon: Decimal.new("2.0")
      })

      # A stored stop whose coordinates are absent: the path between the two is
      # known missing. An occurrence naming a stop with no row is unknown
      # geometry instead.
      Repo.insert!(%GtfsPlanner.Gtfs.Stop{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        stop_id: "unmapped",
        stop_name: "Stored without coordinates"
      })

      route_pattern_stop_fixture(pattern, "located", 1)
      route_pattern_stop_fixture(pattern, "unmapped", 2)
      route_pattern_stop_fixture(pattern, "ghost", 3)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      # Enabling continuous boarding turns the known gap into one advisory with
      # its own action, and the count names the one pattern that is truly
      # affected — the unknown occurrence is unavailable, not missing.
      view
      |> form("#route-details-form", %{route: %{continuous_pickup: "0"}})
      |> render_change()

      assert has_element?(
               view,
               "#route-details-cont-warn",
               "1 pattern has sections without a path"
             )

      assert has_element?(
               view,
               "#route-details-cont-warn",
               "boarding between stops applies there"
             )

      href =
        view
        |> element("#route-details-cont-warn")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("a")
        |> LazyHTML.attribute("href")
        |> List.first()

      assert href == "/gtfs/#{version.id}/routes/CONT1/patterns"

      # Turning boarding off again silences the advisory without a save.
      view
      |> form("#route-details-form", %{route: %{continuous_pickup: "1"}})
      |> render_change()

      refute has_element?(view, "#route-details-cont-warn")

      # And an unrelated edit warns nothing, even with the gap still in place.
      view
      |> form("#route-details-form", %{route: %{route_desc: "A description."}})
      |> render_change()

      refute has_element?(view, "#route-details-cont-warn")
    end
  end

  defp link_href(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("a")
    |> LazyHTML.attribute("href")
    |> List.first()
  end

  defp row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("tbody#transfers tr")
    |> Enum.map(fn row -> row |> LazyHTML.attribute("id") |> List.first() end)
  end
end
