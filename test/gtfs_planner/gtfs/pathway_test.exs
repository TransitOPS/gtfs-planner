defmodule GtfsPlanner.Gtfs.PathwayTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Gtfs.Pathway

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  describe "changeset/2" do
    test "valid changeset with required fields" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)
      from_stop = stop_fixture(organization.id, gtfs_version.id)
      to_stop = stop_fixture(organization.id, gtfs_version.id)

      attrs = %{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        pathway_id: "pathway_123",
        from_stop_id: from_stop.id,
        to_stop_id: to_stop.id,
        pathway_mode: 1,
        is_bidirectional: true
      }

      changeset = Pathway.changeset(%Pathway{}, attrs)
      assert changeset.valid?
    end

    test "invalid changeset missing required fields" do
      changeset = Pathway.changeset(%Pathway{}, %{})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).organization_id
      assert "can't be blank" in errors_on(changeset).gtfs_version_id
      assert "can't be blank" in errors_on(changeset).pathway_id
      assert "can't be blank" in errors_on(changeset).from_stop_id
      assert "can't be blank" in errors_on(changeset).to_stop_id
      assert "can't be blank" in errors_on(changeset).pathway_mode
      # is_bidirectional has a default value of true, so it's not required
    end

    test "invalid pathway_mode out of range" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)
      from_stop = stop_fixture(organization.id, gtfs_version.id)
      to_stop = stop_fixture(organization.id, gtfs_version.id)

      attrs = %{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        pathway_id: "pathway_123",
        from_stop_id: from_stop.id,
        to_stop_id: to_stop.id,
        pathway_mode: 0,
        is_bidirectional: true
      }

      changeset = Pathway.changeset(%Pathway{}, attrs)
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).pathway_mode
    end

    test "valid optional fields" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)
      from_stop = stop_fixture(organization.id, gtfs_version.id)
      to_stop = stop_fixture(organization.id, gtfs_version.id)

      attrs = %{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        pathway_id: "pathway_123",
        from_stop_id: from_stop.id,
        to_stop_id: to_stop.id,
        pathway_mode: 2,
        is_bidirectional: false,
        traversal_time: 120,
        length: Decimal.new("25.5"),
        stair_count: 20
      }

      changeset = Pathway.changeset(%Pathway{}, attrs)
      assert changeset.valid?
    end

    test "unique constraint on organization_id, gtfs_version_id, pathway_id" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)
      from_stop = stop_fixture(organization.id, gtfs_version.id)
      to_stop = stop_fixture(organization.id, gtfs_version.id)

      attrs = %{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        pathway_id: "duplicate_pathway",
        from_stop_id: from_stop.id,
        to_stop_id: to_stop.id,
        pathway_mode: 1,
        is_bidirectional: true
      }

      changeset1 = Pathway.changeset(%Pathway{}, attrs)
      assert {:ok, _} = GtfsPlanner.Repo.insert(changeset1)

      changeset2 = Pathway.changeset(%Pathway{}, attrs)
      assert {:error, changeset2} = GtfsPlanner.Repo.insert(changeset2)
      # The unique constraint error may appear on organization_id due to composite constraint
      assert errors_on(changeset2).organization_id == ["has already been taken"] ||
             errors_on(changeset2).pathway_id == ["has already been taken"]
    end
  end

  describe "pathway_modes/0" do
    test "returns map of integer to atom modes" do
      modes = Pathway.pathway_modes()
      assert is_map(modes)
      assert modes[1] == :walkway
      assert modes[2] == :stairs
      assert modes[3] == :moving_sidewalk
      assert modes[4] == :escalator
      assert modes[5] == :elevator
      assert modes[6] == :fare_gate
      assert modes[7] == :exit_gate
    end
  end
end
