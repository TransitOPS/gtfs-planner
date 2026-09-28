defmodule GtfsPlanner.Gtfs.Routes.ValidationTest do
  use GtfsPlanner.DataCase

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Route

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    route =
      route_fixture(organization.id, version.id, %{
        route_id: "R1",
        route_short_name: "32",
        route_long_name: "Original",
        route_color: "0000FF",
        route_text_color: "AABBCC",
        route_sort_order: 7,
        continuous_pickup: 2,
        continuous_drop_off: 3,
        network_id: "net-1"
      })

    %{organization: organization, version: version, route: route}
  end

  describe "name requirements" do
    test "saves a created route with only a short name", %{
      organization: organization,
      version: version
    } do
      attrs = %{route_id: "R-SHORT", route_type: 3, route_short_name: "12"}

      {:ok, route} =
        %Route{organization_id: organization.id, gtfs_version_id: version.id}
        |> Route.editor_changeset(attrs, :create)
        |> Repo.insert()

      reloaded = Repo.reload(route)

      assert reloaded.route_short_name == "12"
      assert reloaded.route_long_name == nil
    end

    test "saves a created route with only a long name", %{
      organization: organization,
      version: version
    } do
      attrs = %{route_id: "R-LONG", route_type: 3, route_long_name: "Crosstown"}

      {:ok, route} =
        %Route{organization_id: organization.id, gtfs_version_id: version.id}
        |> Route.editor_changeset(attrs, :create)
        |> Repo.insert()

      reloaded = Repo.reload(route)

      assert reloaded.route_long_name == "Crosstown"
      assert reloaded.route_short_name == nil
    end

    test "rejects a created route with both names blank", %{
      organization: organization,
      version: version
    } do
      attrs = %{route_id: "R-BLANK", route_type: 3, route_short_name: "   ", route_long_name: ""}

      changeset =
        %Route{organization_id: organization.id, gtfs_version_id: version.id}
        |> Route.editor_changeset(attrs, :create)

      refute changeset.valid?

      assert "at least one of route_short_name or route_long_name must be present" in errors_on(
               changeset
             ).route_short_name

      assert {:error, _changeset} = Repo.insert(changeset)
    end

    test "saves an edit that clears one name while the other remains", %{route: route} do
      {:ok, updated} =
        route
        |> Route.editor_changeset(%{route_long_name: ""}, :edit)
        |> Repo.update()

      reloaded = Repo.reload(updated)

      assert reloaded.route_long_name == nil
      assert reloaded.route_short_name == "32"
    end

    test "rejects an edit that would leave both names blank", %{route: route} do
      changeset =
        Route.editor_changeset(route, %{route_short_name: "", route_long_name: "  "}, :edit)

      refute changeset.valid?

      assert "at least one of route_short_name or route_long_name must be present" in errors_on(
               changeset
             ).route_short_name

      assert {:error, _changeset} = Repo.update(changeset)

      reloaded = Repo.reload(route)

      assert reloaded.route_short_name == "32"
      assert reloaded.route_long_name == "Original"
    end

    test "keeps the import changeset accepting a whitespace-only short name", %{
      organization: organization,
      version: version
    } do
      # A feed row's whitespace-only name is held on the row struct (Ecto's
      # cast maps a submitted blank to nil before validation); the base
      # revision's nil-based rule accepted these rows and kept the stored value.
      attrs = %{
        route_id: "R-IMPORT-WS",
        route_type: 3,
        organization_id: organization.id,
        gtfs_version_id: version.id
      }

      changeset = Route.changeset(%Route{route_short_name: "   "}, attrs)

      assert changeset.valid?

      {:ok, imported} = Repo.insert(changeset)
      reloaded = Repo.reload(imported)

      assert reloaded.route_short_name == "   "
      assert reloaded.route_long_name == nil
    end

    test "rejects a whitespace-only short name with no long name in the editor", %{
      organization: organization,
      version: version
    } do
      data_held =
        %Route{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          route_short_name: "   "
        }
        |> Route.editor_changeset(%{route_id: "R-EDITOR-WS", route_type: 3}, :create)

      refute data_held.valid?

      assert "at least one of route_short_name or route_long_name must be present" in errors_on(
               data_held
             ).route_short_name

      submitted =
        %Route{organization_id: organization.id, gtfs_version_id: version.id}
        |> Route.editor_changeset(
          %{route_id: "R-EDITOR-WS", route_type: 3, route_short_name: "   "},
          :create
        )

      refute submitted.valid?

      assert {:error, _changeset} = Repo.insert(data_held)
    end
  end

  describe "field validation" do
    test "caps text fields at 255 code points", %{route: route} do
      at_limit = Route.editor_changeset(route, %{route_desc: String.duplicate("é", 255)}, :edit)

      assert at_limit.valid?

      over_limit = Route.editor_changeset(route, %{route_desc: String.duplicate("é", 256)}, :edit)

      refute over_limit.valid?
      assert "should be at most 255 character(s)" in errors_on(over_limit).route_desc
    end

    test "rejects an unsupported route mode", %{route: route} do
      changeset = Route.editor_changeset(route, %{route_type: 99}, :edit)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).route_type
    end

    test "rejects boarding values outside 0..3", %{route: route} do
      changeset = Route.editor_changeset(route, %{continuous_pickup: 4}, :edit)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).continuous_pickup
    end

    test "rejects negative or non-integer sort order", %{route: route} do
      negative = Route.editor_changeset(route, %{route_sort_order: -1}, :edit)

      refute negative.valid?
      assert "must be greater than or equal to 0" in errors_on(negative).route_sort_order

      non_integer = Route.editor_changeset(route, %{route_sort_order: "first"}, :edit)

      refute non_integer.valid?
      assert "is invalid" in errors_on(non_integer).route_sort_order
    end

    test "rejects URLs that are not HTTP(S) with a host", %{route: route} do
      ftp = Route.editor_changeset(route, %{route_url: "ftp://example.com/32"}, :edit)

      refute ftp.valid?
      assert "must be an http(s) URL with a nonempty host" in errors_on(ftp).route_url

      bare = Route.editor_changeset(route, %{route_url: "example.com/32"}, :edit)

      refute bare.valid?
      assert "must be an http(s) URL with a nonempty host" in errors_on(bare).route_url

      clearing = Route.editor_changeset(route, %{route_url: ""}, :edit)

      assert clearing.valid?
    end
  end

  describe "changed-field normalization" do
    test "trims edited text fields", %{route: route} do
      {:ok, updated} =
        route
        |> Route.editor_changeset(%{route_short_name: "  44  "}, :edit)
        |> Repo.update()

      assert Repo.reload(updated).route_short_name == "44"
    end

    test "normalizes changed blank colors to the defaults", %{route: route} do
      {:ok, updated} =
        route
        |> Route.editor_changeset(%{route_color: "", route_text_color: ""}, :edit)
        |> Repo.update()

      reloaded = Repo.reload(updated)

      assert reloaded.route_color == "FFFFFF"
      assert reloaded.route_text_color == "000000"
    end

    test "preserves an untouched imported blank color on an unrelated edit", %{
      organization: organization,
      version: version
    } do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "R-BLANK-COLORS",
          route_color: nil,
          route_text_color: nil
        })

      {:ok, updated} =
        route
        |> Route.editor_changeset(%{route_url: "https://example.com/blank"}, :edit)
        |> Repo.update()

      reloaded = Repo.reload(updated)

      assert reloaded.route_color == nil
      assert reloaded.route_text_color == nil
    end

    test "resolves automatic text color server-side", %{route: route} do
      {:ok, light} =
        route
        |> Route.editor_changeset(
          %{route_color: "FFFFFF", route_text_color: "ABCDEF", text_mode: "automatic"},
          :edit
        )
        |> Repo.update()

      assert light.route_text_color == "000000"

      {:ok, dark} =
        light
        |> Route.editor_changeset(%{route_color: "000000", text_mode: "automatic"}, :edit)
        |> Repo.update()

      assert dark.route_text_color == "FFFFFF"

      changeset =
        Route.editor_changeset(
          route,
          %{route_text_color: "ABCDEF", text_mode: "automatic"},
          :edit
        )

      refute Map.has_key?(changeset.changes, :text_mode)
      assert changeset.changes.route_text_color == "FFFFFF"
    end

    test "an automatic save with no color change is a no-op for the custom text color", %{
      route: route
    } do
      before_update = Repo.reload(route)

      changeset =
        Route.editor_changeset(
          route,
          %{
            route_short_name: route.route_short_name,
            route_long_name: route.route_long_name,
            route_type: route.route_type,
            agency_id: route.agency_id,
            route_desc: route.route_desc,
            route_url: route.route_url,
            route_color: route.route_color,
            route_text_color: route.route_text_color,
            route_sort_order: route.route_sort_order,
            continuous_pickup: route.continuous_pickup,
            continuous_drop_off: route.continuous_drop_off,
            network_id: route.network_id,
            text_mode: "automatic"
          },
          :edit
        )

      assert changeset.changes == %{}

      {:ok, updated} = Repo.update(changeset)
      reloaded = Repo.reload(updated)

      assert reloaded.route_text_color == "AABBCC"
      assert reloaded.updated_at == before_update.updated_at
    end

    test "changing the background with automatic text mode recomputes the text color", %{
      route: route
    } do
      {:ok, updated} =
        route
        |> Route.editor_changeset(%{route_color: "FFFFFF", text_mode: "automatic"}, :edit)
        |> Repo.update()

      reloaded = Repo.reload(updated)

      assert reloaded.route_color == "FFFFFF"
      assert reloaded.route_text_color == "000000"
    end

    test "persists a custom text color as entered", %{route: route} do
      {:ok, updated} =
        route
        |> Route.editor_changeset(
          %{route_color: "FFFFFF", route_text_color: "1a2b3c", text_mode: "custom"},
          :edit
        )
        |> Repo.update()

      assert Repo.reload(updated).route_text_color == "1a2b3c"
    end

    test "rejects an unknown text mode", %{route: route} do
      changeset =
        Route.editor_changeset(route, %{route_text_color: "AABBCC", text_mode: "rainbow"}, :edit)

      refute changeset.valid?
      assert "must be automatic or custom" in errors_on(changeset).text_mode
    end
  end

  describe "preservation on unrelated edits" do
    test "changing the URL leaves untouched route fields and trip rows intact", %{
      organization: organization,
      version: version,
      route: route
    } do
      trip =
        trip_fixture(organization.id, version.id, route.route_id, %{trip_headsign: "Inbound"})

      route = route |> change(pattern_derivation_error: "missing shape") |> Repo.update!()

      before_route = Repo.reload(route)
      before_trip = Repo.reload(trip)

      {:ok, updated} =
        route
        |> Route.editor_changeset(%{route_url: "https://example.com/routes/32"}, :edit)
        |> Repo.update()

      reloaded = Repo.reload(updated)

      assert reloaded.route_url == "https://example.com/routes/32"

      assert Map.drop(reloaded, [:route_url, :updated_at, :__meta__]) ==
               Map.drop(before_route, [:route_url, :updated_at, :__meta__])

      assert reloaded.route_text_color == "AABBCC"
      assert reloaded.continuous_pickup == 2
      assert reloaded.continuous_drop_off == 3
      assert Repo.reload(trip) == before_trip
    end

    test "changing the color leaves untouched route fields and trip rows intact", %{
      organization: organization,
      version: version,
      route: route
    } do
      trip =
        trip_fixture(organization.id, version.id, route.route_id, %{trip_headsign: "Inbound"})

      before_trip = Repo.reload(trip)

      {:ok, updated} =
        route
        |> Route.editor_changeset(%{route_color: "FF8800"}, :edit)
        |> Repo.update()

      reloaded = Repo.reload(updated)

      assert reloaded.route_color == "FF8800"
      assert reloaded.route_text_color == "AABBCC"
      assert reloaded.route_sort_order == 7
      assert reloaded.network_id == "net-1"
      assert reloaded.route_id == "R1"
      assert reloaded.continuous_pickup == 2
      assert reloaded.continuous_drop_off == 3
      assert Repo.reload(trip) == before_trip
    end

    test "rejects invalid hex colors and never persists them", %{route: route} do
      background = Route.editor_changeset(route, %{route_color: "12345"}, :edit)

      refute background.valid?
      assert "must be a valid 6-character hex color code" in errors_on(background).route_color

      text =
        Route.editor_changeset(route, %{route_text_color: "zzzzzz", text_mode: "custom"}, :edit)

      refute text.valid?
      assert "must be a valid 6-character hex color code" in errors_on(text).route_text_color

      assert {:error, _changeset} = Repo.update(background)

      reloaded = Repo.reload(route)

      assert reloaded.route_color == "0000FF"
      assert reloaded.route_text_color == "AABBCC"
    end
  end

  describe "trusted scope and identity" do
    test "ignores forged scope, identity, active and derivation keys", %{
      organization: organization,
      version: version,
      route: route
    } do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)
      route = route |> change(pattern_derivation_error: "missing shape") |> Repo.update!()

      forged = %{
        "route_desc" => "Rider notes",
        "organization_id" => other_organization.id,
        "gtfs_version_id" => other_version.id,
        "id" => Ecto.UUID.generate(),
        "route_id" => "HACKED",
        "active" => false,
        "pattern_derivation_error" => "cleared"
      }

      changeset = Route.editor_changeset(route, forged, :edit)

      assert Map.keys(changeset.changes) == [:route_desc]

      {:ok, updated} = Repo.update(changeset)
      reloaded = Repo.reload(updated)

      assert reloaded.route_desc == "Rider notes"
      assert reloaded.organization_id == organization.id
      assert reloaded.gtfs_version_id == version.id
      assert reloaded.id == route.id
      assert reloaded.route_id == "R1"
      assert reloaded.active == true
      assert reloaded.pattern_derivation_error == "missing shape"
    end

    test "keeps the generic import changeset casting scope, natural ID and active", %{
      organization: organization,
      version: version
    } do
      attrs = %{
        route_id: "R-IMPORTED",
        route_type: 3,
        route_short_name: "9",
        organization_id: organization.id,
        gtfs_version_id: version.id,
        active: false
      }

      changeset = Route.changeset(%Route{}, attrs)

      assert changeset.valid?
      assert changeset.changes.route_id == "R-IMPORTED"
      assert changeset.changes.active == false
      assert changeset.changes.organization_id == organization.id
      assert changeset.changes.gtfs_version_id == version.id

      {:ok, route} = Repo.insert(changeset)

      assert Repo.reload(route).active == false
    end
  end
end
