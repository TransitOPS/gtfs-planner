defmodule GtfsPlanner.Gtfs.Routes.ReadTest do
  # `async: false` is mandatory: the unavailable case swaps `Repo`'s dynamic
  # repo for an unreachable pool, which is process-global configuration.
  use GtfsPlanner.DataCase, async: false

  import ExUnit.CaptureLog
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Routes
  alias GtfsPlanner.Versions

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    %{organization: organization, version: version}
  end

  describe "route workspace through the default facade/Repo adapter" do
    test "returns scoped route data with real agency options and unknown attribution for imported routes",
         %{organization: org, version: version} do
      agency_fixture(org.id, version.id, %{
        agency_id: "a2",
        agency_name: "Beta Transit",
        agency_url: "https://beta.example.com"
      })

      agency_fixture(org.id, version.id, %{
        agency_id: "a1",
        agency_name: "Alpha Transit",
        agency_url: "https://alpha.example.com"
      })

      route =
        route_fixture(org.id, version.id, %{
          route_id: "r1",
          route_short_name: "32",
          route_long_name: "Crosstown",
          route_type: 3,
          route_color: "0000FF"
        })

      route_fixture(org.id, version.id, %{route_id: "r2", route_type: 3})
      route_fixture(org.id, version.id, %{route_id: "r3", route_type: 0, route_short_name: "7"})
      route_fixture(org.id, version.id, %{route_id: "r4", route_type: 1})

      # Foreign scope noise with the same natural ID must never surface.
      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)
      route_fixture(other_org.id, other_version.id, %{route_id: "r1", route_type: 3})

      assert {:ok, workspace} = Gtfs.load_route_editor(org.id, version.id, "r1")

      assert %Route{} = workspace.route
      assert workspace.route.id == route.id
      assert workspace.source == Routes.source(route)

      assert workspace.agencies == [
               %{
                 agency_id: "a1",
                 agency_name: "Alpha Transit",
                 agency_url: "https://alpha.example.com"
               },
               %{
                 agency_id: "a2",
                 agency_name: "Beta Transit",
                 agency_url: "https://beta.example.com"
               }
             ]

      # Descending frequency, then ascending numeric mode on ties.
      assert workspace.mode_counts == [
               %{route_type: 3, count: 2},
               %{route_type: 0, count: 1},
               %{route_type: 1, count: 1}
             ]

      # Scoped candidates only: the foreign organization's r1 is absent.
      assert Enum.map(workspace.warning_candidates, & &1.route_id) == ["r1", "r2", "r3", "r4"]

      for candidate <- workspace.warning_candidates do
        assert Enum.sort(Map.keys(candidate)) ==
                 Enum.sort([:id, :route_id, :route_short_name, :route_color])
      end

      r1_candidate = Enum.find(workspace.warning_candidates, &(&1.route_id == "r1"))
      assert r1_candidate.id == route.id
      assert r1_candidate.route_short_name == "32"
      assert r1_candidate.route_color == "0000FF"

      # Imported routes carry no audit: unknown attribution.
      assert workspace.last_saved == nil
    end

    test "returns the last route audit for a saved route", %{
      organization: org,
      version: version
    } do
      route = route_fixture(org.id, version.id, %{route_id: "r1", route_short_name: "32"})
      actor = user_fixture()

      audit = %AuditContext{
        organization_id: org.id,
        gtfs_version_id: version.id,
        actor_id: actor.id,
        actor_email: actor.email
      }

      {:ok, log} =
        Repo.transaction(fn ->
          case Gtfs.record_change_in_transaction(audit, :route, route, "updated", %{
                 before: %{"route_short_name" => "31"},
                 after: %{"route_short_name" => "32"}
               }) do
            {:ok, log} -> log
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)

      assert {:ok, workspace} = Gtfs.load_route_editor(org.id, version.id, "r1")

      assert workspace.last_saved == %{
               action: "updated",
               actor_id: actor.id,
               actor_email: actor.email,
               saved_at: log.inserted_at
             }
    end
  end

  describe "scope and availability classification" do
    test "foreign, unpublished and unknown scopes return bare not-found without counts", %{
      organization: org,
      version: version
    } do
      route_fixture(org.id, version.id, %{route_id: "ours"})

      other_version = gtfs_version_fixture(org.id)
      route_fixture(org.id, other_version.id, %{route_id: "r1"})

      {:ok, staging} =
        Versions.create_staging_gtfs_version(org.id, %{
          name: "Staging #{System.unique_integer([:positive])}"
        })

      route_fixture(org.id, staging.id, %{route_id: "r1"})

      other_org = organization_fixture()
      foreign_version = gtfs_version_fixture(other_org.id)
      route_fixture(other_org.id, foreign_version.id, %{route_id: "r1"})

      # Every denial is the same bare two-tuple: no counts or workspace data.
      # The sibling version's route never resolves in our scope (natural ID is
      # not identity), and a known version UUID never leaks another tenant.
      assert Gtfs.load_route_editor(org.id, version.id, "r1") == {:error, :not_found}
      assert Gtfs.load_route_editor(org.id, staging.id, "r1") == {:error, :not_found}
      assert Gtfs.load_route_editor(other_org.id, version.id, "r1") == {:error, :not_found}
      assert Gtfs.load_route_editor(org.id, foreign_version.id, "r1") == {:error, :not_found}
      assert Gtfs.load_route_editor(org.id, version.id, "missing") == {:error, :not_found}
    end

    test "a lost connection is unavailable and distinct from not-found", %{
      organization: org,
      version: version
    } do
      route_fixture(org.id, version.id, %{route_id: "r1"})

      capture_log(fn ->
        with_unreachable_repo(fn ->
          assert Gtfs.load_route_editor(org.id, version.id, "r1") == {:error, :unavailable}
          assert Gtfs.load_route_editor(org.id, version.id, "missing") == {:error, :unavailable}
        end)
      end)
    end

    test "only connection errors are classified as unavailable", %{
      version: version
    } do
      assert_raise Ecto.Query.CastError, fn ->
        Gtfs.load_route_editor("not-a-uuid", version.id, "r1")
      end
    end
  end

  defp with_unreachable_repo(fun) do
    with_started_unreachable_repo(fn pid ->
      previous = GtfsPlanner.Repo.get_dynamic_repo()
      GtfsPlanner.Repo.put_dynamic_repo(pid)

      try do
        fun.()
      after
        GtfsPlanner.Repo.put_dynamic_repo(previous)
      end
    end)
  end

  defp with_started_unreachable_repo(fun) do
    pid =
      start_supervised!(
        {GtfsPlanner.Repo,
         name: nil,
         hostname: "127.0.0.1",
         port: 1,
         username: "postgres",
         password: "postgres",
         database: "gtfs_planner_unreachable",
         pool: DBConnection.ConnectionPool,
         pool_size: 1,
         queue_target: 20,
         queue_interval: 20,
         connect_timeout: 100,
         log: false}
      )

    fun.(pid)
  end
end
