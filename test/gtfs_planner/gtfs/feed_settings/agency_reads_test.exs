defmodule GtfsPlanner.Gtfs.FeedSettings.AgencyReadsTest do
  use GtfsPlanner.DataCase

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.FeedSettings
  alias GtfsPlanner.Gtfs.Import.RowParser
  alias GtfsPlanner.Gtfs.Route

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    %{organization: organization, version: version}
  end

  describe "list_agencies/2" do
    test "a single agency counts its exact and blank-agency routes", %{
      organization: organization,
      version: version
    } do
      agency =
        agency_fixture(organization.id, version.id, %{
          agency_id: "NCT",
          agency_name: "North County Transit",
          agency_timezone: "America/New_York"
        })

      for agency_id <- ["NCT", "NCT", nil, "", "  "] do
        route_fixture(organization.id, version.id, %{agency_id: agency_id})
      end

      assert [%{agency: %Agency{id: agency_row_id}, route_count: 5}] =
               FeedSettings.list_agencies(organization.id, version.id)

      assert agency_row_id == agency.id

      assert %{agency_count: 1, unassigned_routes: 0, zone: {:ok, "America/New_York"}} =
               FeedSettings.agency_health(organization.id, version.id)
    end

    test "two agencies count exact matches only", %{organization: organization, version: version} do
      alpha = agency_fixture(organization.id, version.id, %{agency_id: "A", agency_name: "Alpha"})
      beta = agency_fixture(organization.id, version.id, %{agency_id: "B", agency_name: "Beta"})

      for agency_id <- ["A", "B", "B", nil] do
        route_fixture(organization.id, version.id, %{agency_id: agency_id})
      end

      assert [
               %{agency: %Agency{id: alpha_row_id}, route_count: 1},
               %{agency: %Agency{id: beta_row_id}, route_count: 2}
             ] = FeedSettings.list_agencies(organization.id, version.id)

      assert alpha_row_id == alpha.id
      assert beta_row_id == beta.id

      assert %{agency_count: 2, unassigned_routes: 1} =
               FeedSettings.agency_health(organization.id, version.id)
    end

    test "no agency leaves every route unassigned", %{
      organization: organization,
      version: version
    } do
      for agency_id <- [nil, "", "  ", "A"] do
        route_fixture(organization.id, version.id, %{agency_id: agency_id})
      end

      assert FeedSettings.list_agencies(organization.id, version.id) == []

      assert %{agency_count: 0, unassigned_routes: 4, zone: {:unresolved, :missing}} =
               FeedSettings.agency_health(organization.id, version.id)
    end

    test "a reference without a matching agency row stays unassigned", %{
      organization: organization,
      version: version
    } do
      agency_fixture(organization.id, version.id, %{agency_id: "A", agency_name: "Alpha"})

      route_fixture(organization.id, version.id, %{agency_id: "A"})
      route_fixture(organization.id, version.id, %{agency_id: "GHOST"})

      # The import path bypasses the changesets, so a padded reference reaches the table
      # verbatim. It is neither blank nor the exact ID "A" (R5), so it stays unassigned
      # instead of being trimmed into a match.
      insert_imported_route!(organization, version, " A ")

      assert [%{route_count: 1}] = FeedSettings.list_agencies(organization.id, version.id)

      assert %{agency_count: 1, unassigned_routes: 2} =
               FeedSettings.agency_health(organization.id, version.id)
    end

    test "another version's and another organization's routes are not counted", %{
      organization: organization,
      version: version
    } do
      agency =
        agency_fixture(organization.id, version.id, %{agency_id: "A", agency_name: "Alpha"})

      route_fixture(organization.id, version.id, %{agency_id: "A"})

      other_version = gtfs_version_fixture(organization.id)
      agency_fixture(organization.id, other_version.id, %{agency_id: "A", agency_name: "Alpha"})

      for _route <- 1..3 do
        route_fixture(organization.id, other_version.id, %{agency_id: "A"})
      end

      other_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(other_organization.id)
      agency_fixture(other_organization.id, foreign_version.id, %{agency_id: "A"})

      for _route <- 1..2 do
        route_fixture(other_organization.id, foreign_version.id, %{agency_id: "A"})
      end

      assert [%{agency: %Agency{id: agency_row_id}, route_count: 1}] =
               FeedSettings.list_agencies(organization.id, version.id)

      assert agency_row_id == agency.id

      assert %{agency_count: 1, unassigned_routes: 0} =
               FeedSettings.agency_health(organization.id, version.id)

      assert [%{route_count: 3}] = FeedSettings.list_agencies(organization.id, other_version.id)
    end

    test "rows follow the context's scoped read order", %{
      organization: organization,
      version: version
    } do
      delta = agency_fixture(organization.id, version.id, %{agency_id: "D", agency_name: "Delta"})
      alpha = agency_fixture(organization.id, version.id, %{agency_id: "A", agency_name: "Alpha"})

      charlie =
        agency_fixture(organization.id, version.id, %{agency_id: "C", agency_name: "Charlie"})

      bravo = agency_fixture(organization.id, version.id, %{agency_id: "B", agency_name: "Bravo"})

      rows = FeedSettings.list_agencies(organization.id, version.id)

      assert Enum.map(rows, & &1.agency.id) == [alpha.id, bravo.id, charlie.id, delta.id]
      assert Enum.map(rows, & &1.agency) == Gtfs.list_agencies(organization.id, version.id)
    end
  end

  describe "agency_health/2 zone" do
    test "one valid zone resolves to {:ok, zone}", %{organization: organization, version: version} do
      agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})

      assert %{zone: {:ok, "America/New_York"}} =
               FeedSettings.agency_health(organization.id, version.id)
    end

    test "two valid zones are unresolved", %{organization: organization, version: version} do
      agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})
      agency_fixture(organization.id, version.id, %{agency_timezone: "America/Chicago"})

      assert %{zone: {:unresolved, :conflicting}} =
               FeedSettings.agency_health(organization.id, version.id)
    end

    test "a stored zone outside the display clock's catalog is unresolved", %{
      organization: organization,
      version: version
    } do
      # The base changeset keeps whatever an import stored (R9), so the reader has to
      # report the display clock's fallback instead of echoing the value.
      agency_fixture(organization.id, version.id, %{agency_timezone: "Not/a_zone"})

      assert %{zone: {:unresolved, :invalid}} =
               FeedSettings.agency_health(organization.id, version.id)

      assert %{fallback?: true, fallback_reason: :invalid} =
               DisplayClock.resolve_zone(organization.id, version.id)
    end
  end

  describe "get_agency/3" do
    test "returns the agency for its own scope", %{organization: organization, version: version} do
      agency =
        agency_fixture(organization.id, version.id, %{
          agency_id: "NCT",
          agency_name: "North County Transit"
        })

      assert %Agency{id: agency_row_id, agency_id: "NCT"} =
               FeedSettings.get_agency(organization.id, version.id, agency.id)

      assert agency_row_id == agency.id
    end

    test "a malformed or unknown id returns nil", %{
      organization: organization,
      version: version
    } do
      agency_fixture(organization.id, version.id)

      assert FeedSettings.get_agency(organization.id, version.id, "not-a-uuid") == nil
      assert FeedSettings.get_agency(organization.id, version.id, Ecto.UUID.generate()) == nil
      assert FeedSettings.get_agency(organization.id, version.id, nil) == nil
    end

    test "another version's or organization's agency id returns nil", %{
      organization: organization,
      version: version
    } do
      agency = agency_fixture(organization.id, version.id, %{agency_id: "A"})

      other_version = gtfs_version_fixture(organization.id)
      other_version_agency = agency_fixture(organization.id, other_version.id, %{agency_id: "A"})

      other_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(other_organization.id)

      foreign_agency =
        agency_fixture(other_organization.id, foreign_version.id, %{agency_id: "A"})

      assert %Agency{id: agency_row_id} =
               FeedSettings.get_agency(organization.id, version.id, agency.id)

      assert agency_row_id == agency.id

      assert FeedSettings.get_agency(organization.id, version.id, other_version_agency.id) == nil

      assert FeedSettings.get_agency(organization.id, version.id, foreign_agency.id) == nil

      assert FeedSettings.get_agency(organization.id, other_version.id, agency.id) == nil

      assert FeedSettings.get_agency(other_organization.id, foreign_version.id, agency.id) == nil
    end
  end

  defp insert_imported_route!(organization, version, agency_id) do
    {:ok, attrs} =
      RowParser.route_row_to_attrs(
        %{
          "route_id" => "imported_#{System.unique_integer([:positive])}",
          "route_type" => "3",
          "agency_id" => agency_id
        },
        organization.id,
        version.id
      )

    now = DateTime.utc_now()

    {1, _returned} =
      Repo.insert_all(Route, [Map.merge(attrs, %{inserted_at: now, updated_at: now})])

    :ok
  end
end
