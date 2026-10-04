defmodule GtfsPlanner.Gtfs.FareZones.SelectionFingerprintTest do
  @moduledoc """
  Merge evidence (EV-2) for the route-selection fingerprint: it is the same for
  repeated reads and for reordered or repeated inputs, and it changes when the
  predicate changes or when any route-served stop (selected or not) changes its
  zone or its serving routes, joins the route or leaves it. A stop name or
  timestamp never changes it.

  Each expected outcome is derived by hand from the stored mutation applied to
  `GtfsPlanner.FareSelectionFixtures`; the tests do not recompute the hash.
  """
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.FareSelectionFixtures
  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.GtfsFixtures
  alias GtfsPlanner.OrganizationsFixtures
  alias GtfsPlanner.Repo
  alias GtfsPlanner.VersionsFixtures

  setup do
    organization = OrganizationsFixtures.organization_fixture()
    version = VersionsFixtures.gtfs_version_fixture(organization.id)
    FareSelectionFixtures.insert_network!(organization, version)

    %{organization: organization, version: version}
  end

  defp fingerprint(organization, version, opts \\ []) do
    {:ok, selection} =
      FareZones.route_selection(organization.id, version.id, %{
        route_ids: Keyword.get(opts, :route_ids, ["R6"]),
        only_unzoned?: Keyword.get(opts, :only_unzoned?, true),
        exclude_stop_ids: Keyword.get(opts, :exclude, ["AIR1"])
      })

    selection.fingerprint
  end

  defp update_stop(organization, version, stop_id, changes) do
    {1, nil} =
      Repo.update_all(
        from(s in Stop,
          where:
            s.organization_id == ^organization.id and s.gtfs_version_id == ^version.id and
              s.stop_id == ^stop_id
        ),
        set: changes
      )
  end

  test "repeated reads and reordered or repeated inputs give one lowercase SHA-256 hex", %{
    organization: organization,
    version: version
  } do
    fp0 = fingerprint(organization, version)

    assert fp0 =~ ~r/\A[0-9a-f]{64}\z/
    assert fingerprint(organization, version) == fp0
    assert fingerprint(organization, version, route_ids: ["R6", "R6"]) == fp0
    assert fingerprint(organization, version, exclude: ["AIR1", "AIR1"]) == fp0

    two_routes = fingerprint(organization, version, route_ids: ["R6", "R9"])
    assert fingerprint(organization, version, route_ids: ["R9", "R6"]) == two_routes
    assert two_routes != fp0
  end

  describe "a change makes the fingerprint differ" do
    test "a non-selected served stop's zone changes (A2 B to C)", %{
      organization: organization,
      version: version
    } do
      fp0 = fingerprint(organization, version)
      update_stop(organization, version, "A2", zone_id: "C")

      assert fingerprint(organization, version) != fp0
    end

    test "a stop joins the route (U1 called at by T6)", %{
      organization: organization,
      version: version
    } do
      fp0 = fingerprint(organization, version)
      GtfsFixtures.stop_time_fixture(organization.id, version.id, "T6", "U1", %{stop_sequence: 9})

      assert fingerprint(organization, version) != fp0
    end

    test "a stop leaves the route (A1's stop_time on T6 deleted)", %{
      organization: organization,
      version: version
    } do
      fp0 = fingerprint(organization, version)

      {1, nil} =
        Repo.delete_all(
          from(st in StopTime,
            where:
              st.organization_id == ^organization.id and st.gtfs_version_id == ^version.id and
                st.trip_id == "T6" and st.stop_id == "A1"
          )
        )

      assert fingerprint(organization, version) != fp0
    end

    test "a served stop gains another serving route (A1 called at by T9)", %{
      organization: organization,
      version: version
    } do
      fp0 = fingerprint(organization, version)
      GtfsFixtures.stop_time_fixture(organization.id, version.id, "T9", "A1", %{stop_sequence: 9})

      assert fingerprint(organization, version) != fp0
    end

    test "the unzoned flag flips or the exclusions change", %{
      organization: organization,
      version: version
    } do
      fp0 = fingerprint(organization, version)

      assert fingerprint(organization, version, only_unzoned?: false) != fp0
      assert fingerprint(organization, version, exclude: []) != fp0
    end
  end

  describe "an incidental change leaves the fingerprint equal" do
    test "a renamed stop and a touched timestamp", %{
      organization: organization,
      version: version
    } do
      fp0 = fingerprint(organization, version)

      update_stop(organization, version, "A1", stop_name: "Alder Street")
      update_stop(organization, version, "A1", updated_at: ~U[2020-01-01 00:00:00.000000Z])

      assert fingerprint(organization, version) == fp0
    end

    test "a stop only another route serves (AIR2 zone changes, R9 only)", %{
      organization: organization,
      version: version
    } do
      fp0 = fingerprint(organization, version)
      update_stop(organization, version, "AIR2", zone_id: "C")

      assert fingerprint(organization, version) == fp0
    end
  end
end
