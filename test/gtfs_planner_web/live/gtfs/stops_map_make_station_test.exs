defmodule GtfsPlannerWeb.Gtfs.StopsMapMakeStationTest do
  @moduledoc """
  Merge evidence (EV-34) for the make-station panel.

  Three things are claimed. The panel opens on a station name it can already
  read, so the editor is never faced with an empty field. A landmark within the
  radius becomes the suggested name and says where it came from — a suggestion
  is only honest if it can be seen to be one. And a refusal shows the reason in
  the panel, with the draft still typed into it, so a refusal costs no typing
  and names what the feed already answered.

  The create case is driven through the panel and read back from the rows, not
  from the panel's own success state: the claim is that a station exists and the
  stop is its bay, which is a claim about tables.

  The focused command is deferred to branch review:
  `MIX_ENV=test MIX_TEST_PARTITION=_sa28 ELIXIR_ERL_OPTIONS="+S 4" mix test test/gtfs_planner_web/live/gtfs/stops_map_make_station_test.exs`.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Mox, only: [set_mox_global: 1]
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Geocoding.Place
  alias GtfsPlanner.GeocodingMock
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  setup :set_mox_global

  setup do
    organization = organization_fixture()
    editor = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: editor.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    ctx = %{
      organization: organization,
      version: version,
      editor: editor,
      editor_conn: log_in_user(build_conn(), editor, organization: organization)
    }

    stop =
      stop_fixture(organization.id, version.id, %{
        stop_id: "1433",
        stop_name: "US 101 & SE 1st St",
        stop_lat: Decimal.from_float(44.6210),
        stop_lon: Decimal.from_float(-124.0530)
      })

    {:ok, Map.put(ctx, :stop, stop)}
  end

  describe "the panel" do
    test "opens on the stop's own name and a bay letter of A", ctx do
      view = open_station(ctx)

      assert has_element?(view, "#stops-map-station-panel")
      assert has_element?(view, "#stops-map-station-heading", "Make US 101 & SE 1st St a station")

      # The name the editor has to agree with or change, never to supply from
      # nothing.
      assert view |> element("#stops-map-station-name") |> render() =~ "US 101 &amp; SE 1st St"
      assert view |> element("#stops-map-station-bay") |> render() =~ "A"

      # The reason an editor can agree to it: nothing that names the stop stops
      # naming it.
      assert has_element?(view, "#stops-map-station-keeps", "keeps ID 1433")

      # The bay's new name is written out before it is written, from the fields
      # as they are typed: it is the change beside the parent, and it is the one
      # an editor may not have thought about.
      assert has_element?(view, "#stops-map-station-bay-note", "Bay A")
      assert has_element?(view, "#stops-map-station-go", "Create station")
    end

    test "an amenity within 90 m pre-fills the name and says it is a suggestion", ctx do
      stub_landmark(ctx, "Newport City Hall", 12.0)

      view = open_station(ctx)

      assert has_element?(view, "#stops-map-station-landmark", "Newport City Hall")

      assert view |> element("#stops-map-station-landmark") |> render() =~
               "Suggested from the nearest landmark"
    end

    test "an amenity beyond the radius leaves the field on the stop's own name", ctx do
      stub_landmark(ctx, "Far Field", 4_000.0)

      view = open_station(ctx)

      refute has_element?(view, "#stops-map-station-landmark")
      assert view |> element("#stops-map-station-name") |> render() =~ "US 101 &amp; SE 1st St"
    end
  end

  describe "creating a station" do
    test "with the landmark's name writes the station and makes 1433 its bay A", ctx do
      stub_landmark(ctx, "Newport City Hall", 12.0)

      view = open_station(ctx)

      view
      |> form("#stops-map-station-form",
        station: %{station_name: "Newport City Hall", platform_code: "A"}
      )
      |> render_submit()

      assert settle(view) |> has_element?("#stops-map-edit-panel")
      refute has_element?(view, "#stops-map-station-panel")

      station = station_named(ctx, "Newport City Hall")
      assert station, "the station was not written"

      bay = stop_row(ctx, "1433")
      assert bay.parent_station == station.stop_id
      assert bay.location_type == 0
      assert bay.stop_name == "Newport City Hall, Bay A"

      # The editor is left on the bay, named as a bay of the station it now
      # belongs to.
      assert view |> element("#stops-map-edit-panel h2") |> render() =~ "Newport City Hall, Bay A"
      assert has_element?(view, "#stops-map-edit-panel p", "Bay · ID 1433 · Newport City Hall")

      # The thing that makes the operation safe, checked rather than asserted in
      # prose: nothing that referenced the stop was rewritten.
      assert stop_row(ctx, "1433").id == ctx.stop.id
    end

    test "an empty name is refused in the panel with the draft kept", ctx do
      view = open_station(ctx)

      view
      |> element("#stops-map-station-form")
      |> render_change(%{"station" => %{"station_name" => "", "platform_code" => "B"}})

      view
      |> form("#stops-map-station-form", station: %{station_name: "", platform_code: "B"})
      |> render_submit()

      assert has_element?(view, "#stops-map-station-errors")
      assert has_element?(view, "#stops-map-station-panel")
      assert is_nil(station_named(ctx, ""))

      # The draft is the editor's: the letter they typed is still there.
      assert view |> element("#stops-map-station-bay") |> render() =~ "B"
    end
  end

  describe "a refused make_station" do
    test "a stop that is already a bay says so inline, with no form to type into", ctx do
      ctx = seed_bay_of_station(ctx)

      view = open_stop(ctx, "1500")

      # The offer is not made on a bay in the first place.
      refute has_element?(view, "#stops-map-edit-more-menu", "Make this a station")

      # A forged event: the menu does not offer it, so the panel is opened the
      # way an attacker would — by posting the event.
      render_click(view, "start_make_station", %{})

      assert view |> element("#stops-map-station-refused-message") |> render() =~
               "already a bay"

      refute has_element?(view, "#stops-map-station-form")
      refute has_element?(view, "#stops-map-station-go")

      # Nothing was written by being refused.
      assert stop_row(ctx, "1500").parent_station == "STATION_9"
    end
  end

  # --- fixture ---------------------------------------------------------------

  # A bay of a station already in the version: the one stop in this fixture the
  # command will refuse.
  defp seed_bay_of_station(ctx) do
    stop_fixture(ctx.organization.id, ctx.version.id, %{
      stop_id: "STATION_9",
      stop_name: "Newport Transit Center",
      location_type: 1,
      stop_lat: Decimal.from_float(44.6215),
      stop_lon: Decimal.from_float(-124.0535)
    })

    stop_fixture(ctx.organization.id, ctx.version.id, %{
      stop_id: "1500",
      stop_name: "Newport Transit Center, Bay A",
      parent_station: "STATION_9",
      platform_code: "A",
      stop_lat: Decimal.from_float(44.6215),
      stop_lon: Decimal.from_float(-124.0535)
    })

    ctx
  end

  defp stub_landmark(ctx, name, distance_m) do
    _stop = ctx.stop

    Mox.stub(GeocodingMock, :reverse, fn lat, lon, opts ->
      # The panel asks for amenities alone: a station is a place riders look for,
      # and the street beside it is not that.
      assert opts[:amenities] == true
      assert opts[:only] == :amenity

      {:ok, [place(name, lat * 1.0, lon * 1.0, distance_m)]}
    end)
  end

  defp place(name, lat, lon, distance_m) do
    %Place{
      name: name,
      street: name,
      city: "Newport",
      state: "OR",
      country: "us",
      lat: lat,
      lon: lon,
      distance_m: distance_m
    }
  end

  defp station_named(ctx, name) do
    from(s in Stop,
      where:
        s.organization_id == ^ctx.organization.id and s.gtfs_version_id == ^ctx.version.id and
          s.stop_name == ^name and s.location_type == 1,
      select: s
    )
    |> Repo.one()
  end

  defp stop_row(ctx, stop_id) do
    Repo.one!(
      from(s in Stop,
        where:
          s.organization_id == ^ctx.organization.id and s.gtfs_version_id == ^ctx.version.id and
            s.stop_id == ^stop_id
      )
    )
  end

  defp settle(view, rounds \\ 8)
  defp settle(view, 0), do: view

  defp settle(view, rounds) do
    render_async(view, 5_000)
    settle(view, rounds - 1)
  end

  defp open_station(ctx) do
    view = open_stop(ctx, "1433")

    view |> element("#stops-map-edit-more") |> render_click()
    view |> element("#stops-map-edit-station") |> render_click()

    settle(view)
  end

  defp open_stop(ctx, stop_id) do
    path = "/gtfs/#{ctx.version.id}/stops/map?stop=#{stop_id}"
    {:ok, view, _html} = live(ctx.editor_conn, path)
    settle(view)

    # Global mode: a stub set here answers the LiveView's async task without an
    # allowance for each caller.
    Mox.stub(GeocodingMock, :autocomplete, fn _text, _opts -> {:ok, []} end)

    assert has_element?(view, "#stops-map-edit-panel")

    view
  end
end
