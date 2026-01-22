defmodule GtfsPlanner.VersionsTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Versions

  import GtfsPlanner.OrganizationsFixtures

  describe "gtfs_versions" do
    test "create_gtfs_version/2 creates a version with valid attrs" do
      organization = organization_fixture()
      attrs = %{name: "Spring 2024"}

      assert {:ok, version} = Versions.create_gtfs_version(organization.id, attrs)
      assert version.name == "Spring 2024"
      assert version.organization_id == organization.id
    end

    test "create_gtfs_version/2 returns error with invalid attrs" do
      organization = organization_fixture()
      attrs = %{name: nil}

      assert {:error, changeset} = Versions.create_gtfs_version(organization.id, attrs)
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "create_default_version/1 creates a version named 'First Version'" do
      # Create an organization directly without using the fixture to avoid auto-created version
      {:ok, org} =
        %GtfsPlanner.Organizations.Organization{}
        |> GtfsPlanner.Organizations.Organization.changeset(%{
          alias: "test-org-#{System.unique_integer()}",
          name: "Test Org"
        })
        |> GtfsPlanner.Repo.insert()

      assert {:ok, version} = Versions.create_default_version(org.id)
      assert version.name == "First Version"
      assert version.organization_id == org.id
    end

    test "list_gtfs_versions/1 returns versions for the given organization" do
      org1 = organization_fixture()
      org2 = organization_fixture()

      # org1 already has a "First Version" from the fixture
      {:ok, version2} = Versions.create_gtfs_version(org1.id, %{name: "Second Version"})

      versions = Versions.list_gtfs_versions(org1.id)

      assert length(versions) == 2
      assert Enum.any?(versions, fn v -> v.name == "First Version" end)
      assert Enum.any?(versions, fn v -> v.id == version2.id end)

      # org2 should only have its own version
      org2_versions = Versions.list_gtfs_versions(org2.id)
      assert length(org2_versions) == 1
      assert hd(org2_versions).organization_id == org2.id
    end

    test "get_gtfs_version!/1 returns the version with the given id" do
      organization = organization_fixture()
      {:ok, version} = Versions.create_gtfs_version(organization.id, %{name: "Test Version"})

      fetched_version = Versions.get_gtfs_version!(version.id)
      assert fetched_version.id == version.id
      assert fetched_version.name == "Test Version"
    end

    test "get_gtfs_version!/1 raises for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Versions.get_gtfs_version!(Ecto.UUID.generate())
      end
    end

    test "get_latest_gtfs_version/1 returns latest version when multiple exist" do
      organization = organization_fixture()

      # Create multiple versions with a small delay to ensure different inserted_at times
      {:ok, _version1} = Versions.create_gtfs_version(organization.id, %{name: "Version 1"})
      Process.sleep(10)
      {:ok, _version2} = Versions.create_gtfs_version(organization.id, %{name: "Version 2"})
      Process.sleep(10)
      {:ok, version3} = Versions.create_gtfs_version(organization.id, %{name: "Version 3"})

      # Should return the most recently created version (version3)
      assert {:ok, latest} = Versions.get_latest_gtfs_version(organization.id)
      assert latest.id == version3.id
      assert latest.name == "Version 3"
    end

    test "get_latest_gtfs_version/1 returns error when organization has no versions" do
      # Create an organization directly without using the fixture to avoid auto-created version
      {:ok, org} =
        %GtfsPlanner.Organizations.Organization{}
        |> GtfsPlanner.Organizations.Organization.changeset(%{
          alias: "test-org-#{System.unique_integer()}",
          name: "Test Org"
        })
        |> GtfsPlanner.Repo.insert()

      assert {:error, :no_versions} = Versions.get_latest_gtfs_version(org.id)
    end

    test "list_gtfs_versions_for_dropdown/1 returns list of tuples ordered by inserted_at DESC" do
      organization = organization_fixture()

      # Create multiple versions with delays to ensure different inserted_at times
      {:ok, version1} = Versions.create_gtfs_version(organization.id, %{name: "Version 1"})
      Process.sleep(10)
      {:ok, version2} = Versions.create_gtfs_version(organization.id, %{name: "Version 2"})
      Process.sleep(10)
      {:ok, version3} = Versions.create_gtfs_version(organization.id, %{name: "Version 3"})

      versions = Versions.list_gtfs_versions_for_dropdown(organization.id)

      # Should return list of {id, name} tuples
      assert is_list(versions)
      # 3 created + 1 from fixture
      assert length(versions) == 4

      # Should be ordered by most recent first (DESC)
      assert [{id1, name1}, {id2, name2}, {id3, name3} | _rest] = versions
      assert id1 == version3.id
      assert name1 == "Version 3"
      assert id2 == version2.id
      assert name2 == "Version 2"
      assert id3 == version1.id
      assert name3 == "Version 1"
    end

    test "list_gtfs_versions_for_dropdown/1 returns empty list when organization has no versions" do
      # Create an organization directly without using the fixture to avoid auto-created version
      {:ok, org} =
        %GtfsPlanner.Organizations.Organization{}
        |> GtfsPlanner.Organizations.Organization.changeset(%{
          alias: "test-org-#{System.unique_integer()}",
          name: "Test Org"
        })
        |> GtfsPlanner.Repo.insert()

      versions = Versions.list_gtfs_versions_for_dropdown(org.id)
      assert versions == []
    end
  end
end
