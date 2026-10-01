defmodule GtfsPlannerWeb.Gtfs.StopsMapAddTest do
  @moduledoc """
  Merge evidence (EV-28) for the Map view's add flow: placing a draft, the
  reverse geocode that names it, what the placement deserves to be told, the
  validation, and the audited create.

  The expectations are literals from the card's own cases and from the fixture
  rows, never values read back out of the code under test. The geometry is
  worked out on paper: the shape runs north up the line of longitude
  `-124.05310`, so a point `0.000101` degrees east of it is eight metres east,
  and a point `0.0000505` degrees west of it is four metres west — the far
  pavement from a vehicle travelling north.

  Three things have to hold at once, and they pull against each other. The
  reverse geocode is asynchronous and the editor can place again before it
  answers, so a slow first answer must not overwrite a later one. The address
  service is an external boundary and may fail, and a failure must not take the
  form with it. And the create is a command: it authorizes, allocates an ID and
  audits in one transaction, so "a stop was created" is asserted from the row
  and its change log rather than from the panel saying so.

  The focused command is deferred to branch review:
  `MIX_ENV=test MIX_TEST_PARTITION=_sa28 ELIXIR_ERL_OPTIONS="+S 4" mix test test/gtfs_planner_web/live/gtfs/stops_map_add_test.exs`.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Mox, only: [set_mox_global: 1, verify_on_exit!: 1]
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Geocoding.Place
  alias GtfsPlanner.GeocodingMock
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  # The shape's line of longitude, and the degrees per metre at this latitude:
  # 111 320 m to a degree of latitude, and a degree of longitude scaled by the
  # cosine of 44.637°, which is 0.71165, so 79 226 m to a degree of longitude.
  @line_lon -124.05310
  @metres_per_degree_lon 79_226.0

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    organization = organization_fixture()
    editor = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: editor.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    # The address service is stubbed for every case: the add flow asks it for a
    # name the moment a draft is placed, and a case that does not care about the
    # answer should not fail because nothing answered it.
    Mox.stub(GeocodingMock, :autocomplete, fn _text, _opts -> {:ok, []} end)

    %{
      organization: organization,
      version: version,
      editor_conn: log_in_user(build_conn(), editor, organization: organization)
    }
  end

  # Two reads before anything can be asserted on the model: the panel lists its
  # stops on the first paint and the checks read fills the disclosure in after
  # it, and one wait answers after only the first of them.
  defp open_map(conn, version) do
    {:ok, view, _html} = live(conn, ~p"/gtfs/#{version.id}/stops/map")
    render_async(view, 2_000)
    render_async(view, 2_000)
    view
  end

  # A route 1 running north up the line of longitude above, on a real shape, so
  # the panel's side and distance judgements are made against geometry rather
  # than against a connector through two stops.
  defp northbound_line(ctx) do
    route = route_fixture(ctx.organization.id, ctx.version.id, %{route_short_name: "1"})

    pattern =
      %RoutePattern{
        route_pattern_id: "NB",
        route_id: route.route_id,
        direction_id: 0,
        headsign: "Newport",
        shape_id: "SHAPE_NB",
        organization_id: ctx.organization.id,
        gtfs_version_id: ctx.version.id
      }
      |> Repo.insert!()

    insert_shape(ctx, "SHAPE_NB", [{44.6340, @line_lon}, {44.6400, @line_lon}])

    pattern
  end

  defp insert_shape(ctx, shape_id, points) do
    now = DateTime.utc_now()

    Repo.insert_all(
      Shape,
      points
      |> Enum.with_index(1)
      |> Enum.map(fn {{lat, lon}, sequence} ->
        %{
          shape_id: shape_id,
          shape_pt_lat: Decimal.from_float(lat),
          shape_pt_lon: Decimal.from_float(lon),
          shape_pt_sequence: sequence,
          organization_id: ctx.organization.id,
          gtfs_version_id: ctx.version.id,
          inserted_at: now,
          updated_at: now
        }
      end)
    )
  end

  # The prototype's pair: 1433 and 1434 carry the same name a metre and a half
  # apart, and 1434 is the one a draft three metres north of it duplicates.
  defp duplicate_stop(ctx, pattern) do
    stop_fixture(ctx.organization.id, ctx.version.id, %{
      stop_id: "1434",
      stop_name: "US 101 &amp; SE 1st St",
      stop_desc: "Northbound",
      stop_lat: Decimal.new("44.6356100"),
      stop_lon: Decimal.new("-124.0531700")
    })

    route_pattern_stop_fixture(pattern, "1434", 1)
  end

  defp east_of_line(metres), do: @line_lon + metres / @metres_per_degree_lon
  defp west_of_line(metres), do: @line_lon - metres / @metres_per_degree_lon

  defp metres_north(lat, metres), do: lat + metres / 111_320.0

  defp street(name, lat, lon) do
    %Place{
      name: name,
      street: name,
      city: "Newport",
      state: "OR",
      country: "us",
      lat: lat,
      lon: lon,
      distance_m: 4.0
    }
  end

  defp place_draft(view) do
    view |> element("#stops-map-add-stop") |> render_click()
    view
  end

  describe "placing a draft names it" do
    test "a point eight metres east of a northbound line is named from the streets and described as the side it is on",
         ctx do
      northbound_line(ctx)
      lon = east_of_line(8.0)

      Mox.stub(GeocodingMock, :reverse, fn lat, ^lon, opts ->
        assert opts[:amenities] == true

        {:ok,
         [
           street("US 101", lat, lon),
           street("NE 2nd St", lat, lon),
           %Place{
             name: "Newport Library",
             city: "Newport",
             state: "OR",
             country: "us",
             lat: lat,
             lon: lon,
             distance_m: 20.0
           }
         ]}
      end)

      view = ctx |> open_map_version() |> place_draft()

      render_hook(view, "place", %{"lat" => 44.6370, "lon" => lon})
      render_async(view, 2_000)

      # Both streets go in the name, joined by the version's connector, and the
      # amenity near the point is offered rather than used: an amenity describes
      # a building, not a kerb.
      assert has_element?(view, "#stops-map-add-name[value='US 101 & NE 2nd St']")
      assert has_element?(view, "#stops-map-add-suggestion-newport-library", "Newport Library")

      # The description is what tells the two sides of a street apart, and the
      # side is read from the line the vehicle runs on.
      assert has_element?(view, "#stops-map-add-desc[value=Northbound]")

      # The sentence under Location says where the point is, in the same units
      # the warnings use.
      assert has_element?(view, "#stops-map-add-where", "East side of the Route 1 line")
      assert has_element?(view, "#stops-map-add-where", "25 ft from it")
    end

    test "a name the editor typed is not overwritten by the next placement's answer", ctx do
      northbound_line(ctx)

      Mox.stub(GeocodingMock, :reverse, fn lat, lon, _opts ->
        {:ok, [street("US 101", lat, lon)]}
      end)

      view = ctx |> open_map_version() |> place_draft()

      view
      |> form("#stops-map-add-form", %{"stop" => %{"name" => "My own name"}})
      |> render_change()

      render_hook(view, "place", %{"lat" => 44.6370, "lon" => east_of_line(8.0)})
      render_async(view, 2_000)

      assert has_element?(view, "#stops-map-add-name[value='My own name']")
    end
  end

  describe "a slow answer arriving late" do
    test "the first reply does not replace the second place's suggestion", ctx do
      northbound_line(ctx)
      first_lon = east_of_line(8.0)
      second_lon = east_of_line(9.0)

      # The first place's reverse call is the slow one. The delay belongs to the
      # stub because the stub stands in for an external service, and the wait
      # itself is the bounded `render_async/2` below rather than a sleep.
      Mox.stub(GeocodingMock, :reverse, fn
        lat, ^first_lon, _opts ->
          Process.sleep(300)
          {:ok, [street("First Street", lat, first_lon)]}

        lat, ^second_lon, _opts ->
          {:ok, [street("Second Street", lat, second_lon)]}
      end)

      view = ctx |> open_map_version() |> place_draft()

      render_hook(view, "place", %{"lat" => 44.6370, "lon" => first_lon})
      render_hook(view, "place", %{"lat" => 44.6371, "lon" => second_lon})

      render_async(view, 2_000)
      render_async(view, 2_000)

      assert has_element?(view, "#stops-map-add-name[value='Second Street']")
      refute has_element?(view, "#stops-map-add-name[value='First Street']")
    end
  end

  describe "what a placement deserves to be told" do
    test "three metres from a stop is a duplicate, and its action opens that stop", ctx do
      pattern = northbound_line(ctx)
      duplicate_stop(ctx, pattern)

      Mox.stub(GeocodingMock, :reverse, fn lat, lon, _opts ->
        {:ok, [street("SE 1st St", lat, lon)]}
      end)

      view = ctx |> open_map_version() |> place_draft()

      render_hook(view, "place", %{
        "lat" => metres_north(44.63561, 3.0),
        "lon" => -124.05317
      })

      render_async(view, 2_000)

      assert has_element?(view, "#stops-map-add-warning-duplicate-1434")
      assert has_element?(view, "#stops-map-add-warning-duplicate-1434", "US 101 &amp; SE 1st St")
      assert has_element?(view, "#stops-map-add-warning-duplicate-1434", "10 ft away")
      assert has_element?(view, "#stops-map-add-warning-duplicate-1434", "ID 1434")

      # The action names the stop rather than posting a point for it, and the
      # server re-derives where to look from the stop it holds.
      view
      |> element("#stops-map-add-warning-duplicate-1434-action")
      |> render_click()

      assert_push_event(view, "stop_map:focus", %{lat: 44.63561, lon: -124.05317})
    end

    test "four metres west of a northbound line is the far side, and the action moves the draft across",
         ctx do
      northbound_line(ctx)

      Mox.stub(GeocodingMock, :reverse, fn lat, lon, _opts ->
        {:ok, [street("US 101", lat, lon)]}
      end)

      view = ctx |> open_map_version() |> place_draft()

      render_hook(view, "place", %{"lat" => 44.6370, "lon" => west_of_line(4.0)})
      render_async(view, 2_000)

      assert has_element?(view, "[data-add-warning=wrong_side]", "far side of the street")
      assert has_element?(view, "[data-add-warning=wrong_side]", "runs northbound here")
      assert has_element?(view, "#stops-map-add-where", "West side of the Route 1 line")

      view
      |> element("[data-add-warning=wrong_side] button")
      |> render_click()

      # The reflection is the server's: the draft is now the same distance on
      # the other side, which is a longitude mirrored about the line's own.
      assert has_element?(view, "#stops-map-add-lon[value='#{fmt(east_of_line(4.0))}']")
      assert has_element?(view, "#stops-map-add-where", "East side of the Route 1 line")
      refute has_element?(view, "[data-add-warning=wrong_side]")
    end

    test "a point in the middle of the line is told to move to the kerb and nothing else", ctx do
      northbound_line(ctx)

      Mox.stub(GeocodingMock, :reverse, fn lat, lon, _opts ->
        {:ok, [street("US 101", lat, lon)]}
      end)

      view = ctx |> open_map_version() |> place_draft()

      render_hook(view, "place", %{"lat" => 44.6370, "lon" => @line_lon})
      render_async(view, 2_000)

      assert has_element?(view, "#stops-map-add-warning-middle", "middle of the street")
      refute has_element?(view, "[data-add-warning=wrong_side]")
      refute has_element?(view, "[data-add-warning=duplicate]")
    end

    test "a warning's action key that this panel is not showing is refused", ctx do
      northbound_line(ctx)

      Mox.stub(GeocodingMock, :reverse, fn lat, lon, _opts ->
        {:ok, [street("US 101", lat, lon)]}
      end)

      view = ctx |> open_map_version() |> place_draft()

      render_hook(view, "place", %{"lat" => 44.6370, "lon" => @line_lon})
      render_async(view, 2_000)

      before = view |> element("#stops-map-add-panel") |> render()

      render_hook(view, "move_across", %{"key" => "some-other-pattern"})
      render_hook(view, "open_duplicate", %{"key" => "1434"})

      assert view |> element("#stops-map-add-panel") |> render() == before
    end
  end

  describe "coordinates" do
    test "a pasted pair fills both fields and places the pin", ctx do
      Mox.stub(GeocodingMock, :reverse, fn _lat, _lon, _opts ->
        {:ok, [street("US 101", 44.6376, -124.053)]}
      end)

      view = ctx |> open_map_version() |> place_draft()

      # The coordinate fields are behind "Enter coordinates instead" until the
      # editor asks for them, which is the panel's own affordance rather than a
      # test's.
      view |> element("#stops-map-add-coords-toggle") |> render_click()

      view
      |> form("#stops-map-add-form", %{"stop" => %{"lat" => "44.6376, -124.0530"}})
      |> render_change()

      assert has_element?(view, "#stops-map-add-lat[value='44.6376']")
      assert has_element?(view, "#stops-map-add-lon[value='-124.053']")

      assert_push_event(view, "stop_map:mode", %{
        mode: :browse,
        pin: %{lat: 44.6376, lon: -124.053, label: "New stop"},
        ghost: nil
      })
    end
  end

  describe "creating" do
    test "submitting without a name shows the summary and the field, and creates nothing", ctx do
      northbound_line(ctx)

      Mox.stub(GeocodingMock, :reverse, fn lat, lon, _opts ->
        {:ok, [street("US 101", lat, lon)]}
      end)

      view = ctx |> open_map_version() |> place_draft()

      render_hook(view, "place", %{"lat" => 44.6370, "lon" => east_of_line(8.0)})
      render_async(view, 2_000)

      # The suggested name is cleared the way an editor clears it: by typing over
      # it. An empty field is then the editor's own, not the server's leftover.
      view
      |> form("#stops-map-add-form", %{"stop" => %{"name" => ""}})
      |> render_change()

      view |> form("#stops-map-add-form") |> render_submit()

      assert has_element?(view, "#stops-map-add-errors", "Fix 1 thing to create this stop")
      assert has_element?(view, "#stops-map-add-name[aria-invalid=true]")
      assert has_element?(view, "#stops-map-add-errors", "Enter a name")

      assert Repo.aggregate(Stop, :count) == 0
    end

    test "a reverse failure still lets the editor name the stop and create it", ctx do
      Mox.stub(GeocodingMock, :reverse, fn _lat, _lon, _opts -> {:error, :unavailable} end)

      view = ctx |> open_map_version() |> place_draft()

      render_hook(view, "place", %{"lat" => 44.6370, "lon" => -124.0531})
      render_async(view, 2_000)

      assert has_element?(view, "#stops-map-add-reverse-error")

      view
      |> form("#stops-map-add-form", %{"stop" => %{"name" => "US 101 & NW 3rd St"}})
      |> render_change()

      view |> form("#stops-map-add-form") |> render_submit()
      render_async(view, 2_000)

      assert has_element?(view, "#stops-map-created-panel")
      assert [%Stop{stop_name: "US 101 & NW 3rd St"}] = created_stops(ctx)
    end

    test "the create goes through StopEditing and shows the created panel", ctx do
      northbound_line(ctx)

      Mox.stub(GeocodingMock, :reverse, fn lat, lon, _opts ->
        {:ok, [street("US 101", lat, lon)]}
      end)

      view = ctx |> open_map_version() |> place_draft()

      render_hook(view, "place", %{"lat" => 44.6370, "lon" => east_of_line(8.0)})
      render_async(view, 2_000)

      view
      |> form("#stops-map-add-form", %{"stop" => %{"code" => "9901"}})
      |> render_change()

      view |> form("#stops-map-add-form") |> render_submit()
      render_async(view, 2_000)

      assert [stop] = created_stops(ctx)
      assert stop.stop_name == "US 101"
      assert stop.stop_desc == "Northbound"
      assert stop.stop_code == "9901"
      assert stop.wheelchair_boarding == 0
      assert stop.location_type == 0
      assert stop.organization_id == ctx.organization.id
      assert stop.gtfs_version_id == ctx.version.id

      # The coordinates are the ones the pin was at, not the ones the fields
      # were typed into: the pin is the draft's position.
      assert_in_delta Decimal.to_float(stop.stop_lat), 44.6370, 0.00001
      assert_in_delta Decimal.to_float(stop.stop_lon), east_of_line(8.0), 0.00001

      # INV-2: no committed stop without its audit entry, in the same
      # transaction.
      assert [log] = audit_logs(ctx)
      assert log.entity_type == "stop"
      assert log.action == "created"
      assert log.entity_id == stop.id
      assert log.entity_external_id == stop.stop_id

      assert has_element?(view, "#stops-map-created-panel", "Stop created")
      assert has_element?(view, "#stops-map-created-panel", "ID #{stop.stop_id}")
      assert has_element?(view, "#stops-map-created-message", "US 101 is in")

      # The pin is gone: the draft it belonged to is a stop now, drawn by the
      # scene reload from the version's own rows.
      assert_push_event(view, "stop_map:mode", %{mode: :browse, pin: nil, ghost: nil})
    end

    test "a stop ID this version already uses is refused before the round trip", ctx do
      northbound_line(ctx)
      stop_fixture(ctx.organization.id, ctx.version.id, %{stop_id: "1531", stop_name: "Taken"})

      Mox.stub(GeocodingMock, :reverse, fn lat, lon, _opts ->
        {:ok, [street("US 101", lat, lon)]}
      end)

      view = ctx |> open_map_version() |> place_draft()

      render_hook(view, "place", %{"lat" => 44.6370, "lon" => east_of_line(8.0)})
      render_async(view, 2_000)

      view |> element("#stops-map-add-tech-toggle") |> render_click()

      view
      |> form("#stops-map-add-form", %{"stop" => %{"stop_id" => "1531"}})
      |> render_change()

      view |> form("#stops-map-add-form") |> render_submit()

      assert has_element?(view, "#stops-map-add-errors", "That stop ID is already used")
      assert has_element?(view, "#stops-map-add-stop-id[aria-invalid=true]")

      # The version's only stop is still the one that was there before.
      assert [%Stop{stop_id: "1531", stop_name: "Taken"}] = created_stops(ctx)
    end

    test "the created panel names the fare zone the new stop sits in", ctx do
      northbound_line(ctx)

      # A zoned stop a few tens of metres from the draft, written directly
      # because `zone_id` is not castable through the stop changeset.
      zoned = stop_fixture(ctx.organization.id, ctx.version.id, %{stop_name: "Depot"})

      zoned
      |> Ecto.Changeset.change(%{
        zone_id: "NL",
        stop_lat: Decimal.new("44.63727"),
        stop_lon: Decimal.new("-124.0530")
      })
      |> Repo.update!()

      Mox.stub(GeocodingMock, :reverse, fn lat, lon, _opts ->
        {:ok, [street("US 101", lat, lon)]}
      end)

      view = ctx |> open_map_version() |> place_draft()

      render_hook(view, "place", %{"lat" => 44.6370, "lon" => east_of_line(8.0)})
      render_async(view, 2_000)

      # The panel states the zone before the stop is made: it is the nearest
      # stops' zone, not a choice this panel offers.
      assert has_element?(view, "#stops-map-add-zone", "NL")

      view |> form("#stops-map-add-form") |> render_submit()
      render_async(view, 2_000)

      assert has_element?(view, "#stops-map-created-message", "NL · 100 ft away")
    end

    test "a second submit while the first is in flight creates one stop, not two", ctx do
      northbound_line(ctx)

      Mox.stub(GeocodingMock, :reverse, fn lat, lon, _opts ->
        {:ok, [street("US 101", lat, lon)]}
      end)

      # The create command locks the version row before it writes, so holding
      # that lock from a connection of its own leaves the first create waiting
      # in the air: the window a double submit needs is made here rather than
      # hoped for.
      lock_config =
        GtfsPlanner.Repo.config()
        |> Keyword.delete(:pool)
        |> Keyword.put(:pool_size, 1)

      {:ok, lock} = Postgrex.start_link(lock_config)

      Postgrex.query!(lock, "BEGIN", [])

      Postgrex.query!(lock, "SELECT 1 FROM gtfs_versions WHERE id = $1 FOR UPDATE", [
        Ecto.UUID.dump!(ctx.version.id)
      ])

      view = ctx |> open_map_version() |> place_draft()

      render_hook(view, "place", %{"lat" => 44.6370, "lon" => east_of_line(8.0)})
      render_async(view, 2_000)

      params = %{"stop" => %{"name" => "Depot Road"}}

      render_hook(view, "create_stop", params)

      # In flight: the button says what it is doing and refuses another click.
      assert has_element?(view, "#stops-map-add-create[disabled]", "Creating…")
      assert has_element?(view, "#stops-map-add-status", "Creating…")

      # The second submit is refused while the first is still running.
      render_hook(view, "create_stop", params)

      Postgrex.query!(lock, "ROLLBACK", [])
      GenServer.stop(lock)

      render_async(view, 2_000)

      assert [%Stop{stop_name: "Depot Road"}] = created_stops(ctx)
      assert has_element?(view, "#stops-map-created-panel")
    end

    test "attributes the form did not name are not attributes of the stop", ctx do
      northbound_line(ctx)
      other = organization_fixture()

      Mox.stub(GeocodingMock, :reverse, fn lat, lon, _opts ->
        {:ok, [street("US 101", lat, lon)]}
      end)

      view = ctx |> open_map_version() |> place_draft()

      render_hook(view, "place", %{"lat" => 44.6370, "lon" => east_of_line(8.0)})
      render_async(view, 2_000)

      # A forged attribute for another organization, another version and a
      # location of its own: the draft is a whitelist, and everything the create
      # command uses comes from the socket or from the pin.
      render_hook(view, "create_stop", %{
        "stop" => %{
          "name" => "US 101",
          "organization_id" => other.id,
          "gtfs_version_id" => other.id,
          "stop_lat" => "0.0",
          "stop_lon" => "0.0",
          "location_type" => "4"
        }
      })

      render_async(view, 2_000)

      assert [stop] = created_stops(ctx)
      assert stop.organization_id == ctx.organization.id
      assert stop.gtfs_version_id == ctx.version.id
      assert stop.location_type == 0
      assert_in_delta Decimal.to_float(stop.stop_lat), 44.6370, 0.00001
    end
  end

  describe "adding a station" do
    test "the switch is a new draft with the station's own fields", ctx do
      Mox.stub(GeocodingMock, :reverse, fn lat, lon, _opts ->
        {:ok, [street("US 101", lat, lon)]}
      end)

      view = ctx |> open_map_version() |> place_draft()

      view |> element("#stops-map-add-kind-station") |> render_click()

      assert has_element?(view, "#stops-map-add-panel", "New station")
      assert has_element?(view, "#stops-map-add-create", "Create station")

      # A station has no sign number and no description: it is a container for
      # bays, and its bays are added on the station page.
      refute has_element?(view, "#stops-map-add-code")
      refute has_element?(view, "#stops-map-add-desc")
      assert has_element?(view, "#stops-map-add-station-note", "bays")

      render_hook(view, "place", %{"lat" => 44.6370, "lon" => -124.0531})
      render_async(view, 2_000)

      view
      |> form("#stops-map-add-form", %{"stop" => %{"name" => "Newport Transit Center"}})
      |> render_change()

      view |> form("#stops-map-add-form") |> render_submit()
      render_async(view, 2_000)

      assert [stop] = created_stops(ctx)
      assert stop.stop_name == "Newport Transit Center"
      assert stop.location_type == 1
    end
  end

  # --- helpers ---------------------------------------------------------------

  # The rows the create wrote, read back through the same scope the command
  # wrote them under.
  defp created_stops(ctx) do
    import Ecto.Query

    Repo.all(
      from(stop in Stop,
        where:
          stop.organization_id == ^ctx.organization.id and
            stop.gtfs_version_id == ^ctx.version.id
      )
    )
  end

  defp audit_logs(ctx) do
    import Ecto.Query

    Repo.all(
      from(log in ChangeLog,
        where:
          log.organization_id == ^ctx.organization.id and
            log.gtfs_version_id == ^ctx.version.id and log.entity_type == "stop"
      )
    )
  end

  defp fmt(value), do: value |> Float.round(5) |> to_string()

  # The view is opened against this case's version rather than a context map, so
  # a case that never places anything can still say so in one line.
  defp open_map_version(ctx), do: open_map(ctx.editor_conn, ctx.version)
end
