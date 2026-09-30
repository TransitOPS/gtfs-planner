defmodule GtfsPlanner.Gtfs.StopEditorChangesetTest do
  @moduledoc """
  `Stop.editor_changeset/2` is the changeset every stop-writing surface uses: it
  casts the three fields the importer used to own, requires a name and
  coordinates only where a rider can board, and refuses a `stop_url` that is not
  an absolute web address. `Stop.changeset/2` stays permissive about `level_id`,
  and the station diagram's `Stop.child_stop_changeset/2` keeps that requirement
  for its own form.
  """

  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Stop

  @url_message "must be a full web address starting with https:// or http://"

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    %{organization_id: organization.id, gtfs_version_id: version.id}
  end

  defp attrs(context, extra) do
    Map.merge(
      %{
        stop_id: "1532",
        stop_name: "Main St & 3rd Ave",
        stop_lat: Decimal.new("44.63"),
        stop_lon: Decimal.new("-124.05"),
        location_type: 0,
        organization_id: context.organization_id,
        gtfs_version_id: context.gtfs_version_id
      },
      extra
    )
  end

  describe "editor_changeset/2 required fields" do
    test "a located stop with no name reports the name", context do
      changeset = Stop.editor_changeset(%Stop{}, attrs(context, %{stop_name: nil}))

      assert %{stop_name: ["can't be blank"]} = errors_on(changeset)
      refute changeset.valid?
    end

    test "a located stop with no latitude reports the latitude", context do
      changeset = Stop.editor_changeset(%Stop{}, attrs(context, %{stop_lat: nil}))

      assert %{stop_lat: ["can't be blank"]} = errors_on(changeset)
    end

    test "a located stop with no longitude reports the longitude", context do
      changeset = Stop.editor_changeset(%Stop{}, attrs(context, %{stop_lon: nil}))

      assert %{stop_lon: ["can't be blank"]} = errors_on(changeset)
    end

    test "a station and an entrance still need a name and coordinates", context do
      for type <- [1, 2] do
        changeset =
          Stop.editor_changeset(
            %Stop{},
            attrs(context, %{location_type: type, stop_name: nil, stop_lat: nil})
          )

        assert %{stop_name: [_], stop_lat: [_]} = errors_on(changeset)
      end
    end

    test "a node without a name or coordinates is valid", context do
      changeset =
        Stop.editor_changeset(
          %Stop{},
          attrs(context, %{location_type: 3, stop_name: nil, stop_lat: nil, stop_lon: nil})
        )

      assert changeset.valid?, "expected a type 3 node to need no name or coordinates"
    end

    test "a boarding area without a name or coordinates is valid", context do
      changeset =
        Stop.editor_changeset(
          %Stop{},
          attrs(context, %{location_type: 4, stop_name: nil, stop_lat: nil, stop_lon: nil})
        )

      assert changeset.valid?
    end

    test "an out-of-range latitude is still refused", context do
      changeset = Stop.editor_changeset(%Stop{}, attrs(context, %{stop_lat: 91}))

      assert %{stop_lat: [_]} = errors_on(changeset)
    end
  end

  describe "editor_changeset/2 stop_url" do
    test "rejects a javascript: url", context do
      changeset =
        Stop.editor_changeset(%Stop{}, attrs(context, %{stop_url: "javascript:alert(1)"}))

      assert %{stop_url: [@url_message]} = errors_on(changeset)
    end

    test "rejects a data: url", context do
      changeset =
        Stop.editor_changeset(%Stop{}, attrs(context, %{stop_url: "data:text/html,x"}))

      assert %{stop_url: [@url_message]} = errors_on(changeset)
    end

    test "rejects a bare host with no scheme", context do
      changeset =
        Stop.editor_changeset(%Stop{}, attrs(context, %{stop_url: "northcoast.example"}))

      assert %{stop_url: [@url_message]} = errors_on(changeset)
    end

    test "accepts an https url", context do
      changeset =
        Stop.editor_changeset(
          %Stop{},
          attrs(context, %{stop_url: "https://northcoast.example/stops/1532"})
        )

      assert changeset.valid?
      assert get_change(changeset, :stop_url) == "https://northcoast.example/stops/1532"
    end

    test "accepts an http url", context do
      changeset =
        Stop.editor_changeset(%Stop{}, attrs(context, %{stop_url: "http://northcoast.example"}))

      assert changeset.valid?
    end
  end

  describe "editor_changeset/2 casts" do
    test "casts the sign number, spoken name and web page", context do
      changeset =
        Stop.editor_changeset(
          %Stop{},
          attrs(context, %{
            stop_code: " 1532 ",
            tts_stop_name: "Main Street and Third Avenue",
            stop_url: " https://northcoast.example/stops/1532 "
          })
        )

      assert changeset.valid?
      assert get_change(changeset, :stop_code) == "1532"
      assert get_change(changeset, :tts_stop_name) == "Main Street and Third Avenue"

      assert get_change(changeset, :stop_url) ==
               "https://northcoast.example/stops/1532"
    end

    test "does not cast the fare zone", context do
      changeset = Stop.editor_changeset(%Stop{}, attrs(context, %{zone_id: "A"}))

      assert get_change(changeset, :zone_id) == nil
    end
  end

  describe "level_id" do
    test "changeset/2 accepts a child stop without a level", context do
      changeset =
        Stop.changeset(
          %Stop{},
          attrs(context, %{location_type: 3, parent_station: "ST-NTC", level_id: nil})
        )

      assert changeset.valid?, "expected a child stop to need no level"
    end

    test "changeset/2 still refuses a station that has a parent", context do
      changeset =
        Stop.changeset(
          %Stop{},
          attrs(context, %{location_type: 1, parent_station: "ST-NTC", level_id: "L0"})
        )

      assert %{location_type: ["A station can't be inside another station. Choose another type."]} =
               errors_on(changeset)
    end

    test "child_stop_changeset/2 still requires a level for the diagram's form", context do
      changeset =
        Stop.child_stop_changeset(
          %Stop{},
          attrs(context, %{location_type: 3, parent_station: "ST-NTC", level_id: nil})
        )

      assert %{level_id: ["can't be blank"]} = errors_on(changeset)
      refute changeset.valid?
    end

    test "child_stop_changeset/2 accepts a child stop that names a level", context do
      changeset =
        Stop.child_stop_changeset(
          %Stop{},
          attrs(context, %{location_type: 3, parent_station: "ST-NTC", level_id: "L0"})
        )

      assert changeset.valid?
    end
  end

  describe "import_changeset/2" do
    test "keeps its permissive parent and level rules", context do
      changeset =
        Stop.import_changeset(
          %Stop{},
          attrs(context, %{location_type: 3, parent_station: "ST-NTC", level_id: nil})
        )

      assert changeset.valid?
    end
  end
end
