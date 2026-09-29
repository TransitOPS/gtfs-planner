defmodule GtfsPlanner.Gtfs.FlexServiceTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.FlexArea
  alias GtfsPlanner.Gtfs.FlexBookingRule
  alias GtfsPlanner.Gtfs.FlexHours
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    %{organization: organization, version: version}
  end

  describe "hours rows" do
    test "start and end are 24-hour HH:MM, and an overnight end is allowed", %{
      organization: organization,
      version: version
    } do
      valid =
        build_service(organization, version, %{
          "hours" => [%{"service_id" => "weekday", "start" => "07:00", "end" => "01:00"}]
        })

      assert valid.valid?

      invalid_start =
        build_service(organization, version, %{
          "hours" => [%{"service_id" => "weekday", "start" => "7:00", "end" => "18:00"}]
        })

      refute invalid_start.valid?
      assert [%{start: [_message]}] = errors_on(invalid_start).hours

      invalid_end =
        build_service(organization, version, %{
          "hours" => [%{"service_id" => "weekday", "start" => "07:00", "end" => "25:00"}]
        })

      refute invalid_end.valid?
      assert [%{end: [_message]}] = errors_on(invalid_end).hours
    end

    test "each row needs a calendar and both times" do
      changeset =
        FlexHours.changeset(%FlexHours{}, %{
          "area_key" => "a1",
          "start" => "07:00",
          "end" => "18:00"
        })

      refute changeset.valid?
      assert %{service_id: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "booking rules" do
    test "an earlier-day cut-off stays below 24:00 and horizons are never negative", %{
      organization: organization,
      version: version
    } do
      valid =
        build_service(organization, version, %{
          "booking_rules" => [
            %{"when" => "earlier_day", "days" => 1, "by" => "23:59", "max_days" => 14}
          ]
        })

      assert valid.valid?

      at_midnight =
        build_service(organization, version, %{
          "booking_rules" => [%{"when" => "earlier_day", "days" => 1, "by" => "24:00"}]
        })

      refute at_midnight.valid?
      assert [%{by: [_message]}] = errors_on(at_midnight).booking_rules

      negative_minutes =
        FlexBookingRule.changeset(%FlexBookingRule{}, %{"when" => "same_day", "minutes" => -1})

      refute negative_minutes.valid?
      assert %{minutes: ["must be greater than or equal to 0"]} = errors_on(negative_minutes)
    end
  end

  describe "contact fields" do
    test "the phone is ten digits and the booking link is https", %{
      organization: organization,
      version: version
    } do
      valid =
        build_service(organization, version, %{
          "phone" => "(541) 555-0142",
          "booking_url" => "https://ride.northcoast.example/toledo"
        })

      assert valid.valid?

      short_phone = build_service(organization, version, %{"phone" => "555-014"})
      refute short_phone.valid?
      assert %{phone: [_message]} = errors_on(short_phone)

      insecure_link = build_service(organization, version, %{"booking_url" => "http://x"})
      refute insecure_link.valid?
      assert %{booking_url: [_message]} = errors_on(insecure_link)
    end
  end

  describe "detour distance" do
    test "a detour starts with no distance and rejects a zero distance", %{
      organization: organization,
      version: version
    } do
      not_chosen = build_service(organization, version, %{"kind" => "detour", "route_id" => "20"})

      assert not_chosen.valid?
      assert get_field(not_chosen, :distance_m) == nil

      zero =
        build_service(organization, version, %{
          "kind" => "detour",
          "route_id" => "20",
          "distance_m" => 0
        })

      refute zero.valid?
      assert %{distance_m: ["must be greater than 0"]} = errors_on(zero)
    end
  end

  describe "creation requirements" do
    test "creation requires a name, a kind and a route for a detour", %{
      organization: organization,
      version: version
    } do
      nameless = build_service(organization, version, %{"name" => nil})

      refute nameless.valid?
      assert %{name: ["can't be blank"]} = errors_on(nameless)

      kindless = build_service(organization, version, %{"kind" => nil})

      refute kindless.valid?
      assert %{kind: ["can't be blank"]} = errors_on(kindless)

      routeless = build_service(organization, version, %{"kind" => "detour", "route_id" => nil})

      refute routeless.valid?
      assert %{route_id: ["can't be blank"]} = errors_on(routeless)
    end
  end

  describe "key stability" do
    test "create_changeset/2 casts the derived key", %{
      organization: organization,
      version: version
    } do
      changeset = build_service(organization, version, %{"key" => "newport-dial-a-ride"})

      assert Ecto.Changeset.get_change(changeset, :key) == "newport-dial-a-ride"
    end

    test "changeset/2 ignores a new key on update", %{
      organization: organization,
      version: version
    } do
      {:ok, stored} = insert_service(organization, version)

      changeset = FlexService.changeset(stored, %{"key" => "renamed-key", "name" => "Renamed"})

      assert get_field(changeset, :key) == stored.key
      assert Ecto.Changeset.get_change(changeset, :key) == nil

      {:ok, updated} = Repo.update(changeset)

      assert updated.key == stored.key
      assert updated.name == "Renamed"
    end
  end

  describe "optimistic locking" do
    test "a save built from a stale struct raises Ecto.StaleEntryError", %{
      organization: organization,
      version: version
    } do
      {:ok, stored} = insert_service(organization, version)

      stale = Repo.get!(FlexService, stored.id)
      fresh = Repo.get!(FlexService, stored.id)

      {:ok, _updated} = fresh |> FlexService.changeset(%{"name" => "First save"}) |> Repo.update()

      assert_raise Ecto.StaleEntryError, fn ->
        stale |> FlexService.changeset(%{"name" => "Second save"}) |> Repo.update()
      end
    end
  end

  describe "areas" do
    test "keys are unique per service and areas are deleted with their service", %{
      organization: organization,
      version: version
    } do
      {:ok, service} = insert_service(organization, version)
      {:ok, _first} = insert_area(service, "a1", 0)

      assert {:error, changeset} = insert_area(service, "a1", 1)

      assert {_message, opts} = changeset.errors[:key]
      assert opts[:constraint] == :unique
      assert opts[:constraint_name] == "flex_areas_flex_service_id_key_index"

      {:ok, _second} = insert_area(service, "a2", 1)

      assert area_count(service) == 2

      Repo.delete!(service)

      assert area_count(service) == 0
    end

    test "the geometry column stays outside the Ecto schema" do
      assert %Postgrex.Result{rows: [["USER-DEFINED", "geometry"]]} =
               Repo.query!(
                 "SELECT data_type, udt_name FROM information_schema.columns WHERE table_name = 'flex_areas' AND column_name = 'geom'"
               )

      assert %Postgrex.Result{rows: [["geometry(MultiPolygon,4326)"]]} =
               Repo.query!(
                 "SELECT format_type(atttypid, atttypmod) FROM pg_attribute WHERE attrelid = 'flex_areas'::regclass AND attname = 'geom'"
               )

      assert %Postgrex.Result{rows: [[indexdef]]} =
               Repo.query!(
                 "SELECT indexdef FROM pg_indexes WHERE tablename = 'flex_areas' AND indexname = 'flex_areas_geom_idx'"
               )

      assert indexdef =~ "USING gist"

      refute :geom in FlexArea.__schema__(:fields)
    end
  end

  defp build_service(organization, version, attrs) do
    attrs =
      Map.merge(
        %{
          "key" => "service-#{System.unique_integer([:positive])}",
          "name" => "Newport Dial-a-Ride",
          "kind" => "area"
        },
        attrs
      )

    %FlexService{organization_id: organization.id, gtfs_version_id: version.id}
    |> FlexService.create_changeset(attrs)
  end

  defp insert_service(organization, version, attrs \\ %{}) do
    organization
    |> build_service(version, attrs)
    |> Repo.insert()
  end

  defp insert_area(service, key, position, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{"key" => key, "position" => position, "name" => "Area #{key}", "source" => "drawn"},
        attrs
      )

    %FlexArea{
      flex_service_id: service.id,
      organization_id: service.organization_id,
      gtfs_version_id: service.gtfs_version_id
    }
    |> FlexArea.changeset(attrs)
    |> Repo.insert()
  end

  defp area_count(service) do
    Repo.aggregate(
      from(area in FlexArea, where: area.flex_service_id == ^service.id),
      :count
    )
  end
end
