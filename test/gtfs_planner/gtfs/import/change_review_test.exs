defmodule GtfsPlanner.Gtfs.Import.ChangeReviewTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Import.ChangeReview

  @closure_header "pathway_id,service_id,start_time,end_time,is_closed"

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    %{organization: organization, version: version}
  end

  describe "the ignored closure file count" do
    test "counts the entry expanded from an archive without blocking the review", %{
      organization: organization,
      version: version
    } do
      archive =
        zip!([
          {~c"levels.txt", "level_id,level_index,level_name\nREVIEWED,1.0,Reviewed"},
          {~c"station/pathway_evolutions.txt",
           @closure_header <> "\nMERGE_PW,CAL_DAILY,06:00:00,07:00:00,1"}
        ])

      review =
        ChangeReview.compute(organization.id, version.id, [
          %{filename: "station-update.zip", content: archive}
        ])

      assert review.summary.ignored_evolution_files == 1
      assert review.summary.add == 1
      assert review.diagnostics == []
      assert Enum.map(review.decisions, & &1.natural_key) == ["REVIEWED"]
    end

    test "counts every closure file under its normalized path and name", %{
      organization: organization,
      version: version
    } do
      files = [
        %{filename: "UPLOADS/Pathway_Evolutions.TXT", content: @closure_header <> "\n"},
        %{filename: "pathway_evolutions.txt", content: @closure_header <> "\n"}
      ]

      review = ChangeReview.compute(organization.id, version.id, files)

      assert review.summary.ignored_evolution_files == 2
      assert review.diagnostics == []
      assert review.decisions == []
    end

    test "reports zero when the upload does not carry the file", %{
      organization: organization,
      version: version
    } do
      review =
        ChangeReview.compute(organization.id, version.id, [
          %{filename: "levels.txt", content: "level_id,level_index,level_name\nONLY,1.0,Only"}
        ])

      assert review.summary.ignored_evolution_files == 0
      assert review.summary.add == 1
    end
  end

  defp zip!(entries) do
    {:ok, {_name, binary}} = :zip.create(~c"review.zip", entries, [:memory])
    binary
  end
end
