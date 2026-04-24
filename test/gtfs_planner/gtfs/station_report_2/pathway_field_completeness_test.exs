defmodule GtfsPlanner.Gtfs.StationReport2.PathwayFieldCompletenessTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.StationReport2.PathwayFieldCompleteness

  defp make_pathway(attrs) do
    Map.merge(
      %{
        pathway_id: "PW_1",
        pathway_mode: 1,
        is_bidirectional: true,
        from_stop_id: "A",
        to_stop_id: "B",
        traversal_time: nil,
        length: nil,
        stair_count: nil,
        min_width: nil,
        max_slope: nil,
        signposted_as: nil,
        reversed_signposted_as: nil
      },
      attrs
    )
  end

  describe "build/1" do
    test "returns empty list for empty pathways" do
      assert PathwayFieldCompleteness.build(%{pathways: []}) == []
    end

    test "returns empty list when all pathways have unknown modes" do
      pathways = [make_pathway(%{pathway_mode: 99}), make_pathway(%{pathway_mode: 0})]
      assert PathwayFieldCompleteness.build(%{pathways: pathways}) == []
    end

    test "groups by mode and returns correct mode labels" do
      pathways = [
        make_pathway(%{pathway_id: "PW_1", pathway_mode: 1, length: Decimal.new("10")}),
        make_pathway(%{pathway_id: "PW_2", pathway_mode: 2, stair_count: 5})
      ]

      groups = PathwayFieldCompleteness.build(%{pathways: pathways})
      assert length(groups) == 2
      assert Enum.at(groups, 0).mode_label == "Walkway"
      assert Enum.at(groups, 1).mode_label == "Stairs"
    end

    test "orders modes as 1, 2, 4, 5, 6, 7, 3" do
      pathways = [
        make_pathway(%{pathway_id: "PW_3", pathway_mode: 3}),
        make_pathway(%{pathway_id: "PW_1", pathway_mode: 1}),
        make_pathway(%{pathway_id: "PW_7", pathway_mode: 7}),
        make_pathway(%{pathway_id: "PW_5", pathway_mode: 5}),
        make_pathway(%{pathway_id: "PW_2", pathway_mode: 2}),
        make_pathway(%{pathway_id: "PW_4", pathway_mode: 4}),
        make_pathway(%{pathway_id: "PW_6", pathway_mode: 6})
      ]

      groups = PathwayFieldCompleteness.build(%{pathways: pathways})
      modes = Enum.map(groups, & &1.mode)
      assert modes == [1, 2, 4, 5, 6, 7, 3]
    end

    test "computes correct field lists per mode" do
      pathways = [
        make_pathway(%{pathway_id: "PW_1", pathway_mode: 1}),
        make_pathway(%{pathway_id: "PW_5", pathway_mode: 5}),
        make_pathway(%{pathway_id: "PW_3", pathway_mode: 3})
      ]

      groups = PathwayFieldCompleteness.build(%{pathways: pathways})
      group_map = Map.new(groups, &{&1.mode, &1})

      assert Enum.map(group_map[1].fields, & &1.field) == [:length]
      assert Enum.map(group_map[5].fields, & &1.field) == [:min_width, :traversal_time]
      assert Enum.map(group_map[3].fields, & &1.field) == [:traversal_time, :length, :min_width]
    end

    test "pass status when all pathways have field present" do
      pathways = [
        make_pathway(%{pathway_id: "PW_1", pathway_mode: 1, length: Decimal.new("10")}),
        make_pathway(%{pathway_id: "PW_2", pathway_mode: 1, length: Decimal.new("20")})
      ]

      [group] = PathwayFieldCompleteness.build(%{pathways: pathways})
      [field] = group.fields

      assert field.status == :pass
      assert field.present == 2
      assert field.total == 2
      assert field.percent == 100
    end

    test "warn status when some pathways have field present" do
      pathways = [
        make_pathway(%{
          pathway_id: "PW_1",
          pathway_mode: 5,
          min_width: Decimal.new("1.2"),
          traversal_time: 30
        }),
        make_pathway(%{pathway_id: "PW_2", pathway_mode: 5, min_width: nil, traversal_time: 30}),
        make_pathway(%{
          pathway_id: "PW_3",
          pathway_mode: 5,
          min_width: Decimal.new("1.5"),
          traversal_time: nil
        })
      ]

      [group] = PathwayFieldCompleteness.build(%{pathways: pathways})

      min_width = Enum.find(group.fields, &(&1.field == :min_width))
      assert min_width.status == :warn
      assert min_width.present == 2
      assert min_width.total == 3
      assert min_width.percent == 67

      traversal = Enum.find(group.fields, &(&1.field == :traversal_time))
      assert traversal.status == :warn
      assert traversal.present == 2
      assert traversal.total == 3
      assert traversal.percent == 67
    end

    test "fail status when no pathways have field present" do
      pathways = [
        make_pathway(%{pathway_id: "PW_1", pathway_mode: 1, length: nil}),
        make_pathway(%{pathway_id: "PW_2", pathway_mode: 1, length: nil})
      ]

      [group] = PathwayFieldCompleteness.build(%{pathways: pathways})
      [field] = group.fields

      assert field.status == :fail
      assert field.present == 0
      assert field.total == 2
      assert field.percent == 0
    end

    test "empty string values are treated as not present" do
      pathways = [
        make_pathway(%{pathway_id: "PW_1", pathway_mode: 1, length: ""})
      ]

      [group] = PathwayFieldCompleteness.build(%{pathways: pathways})
      [field] = group.fields

      assert field.status == :fail
      assert field.present == 0
    end

    test "omits modes with no pathways" do
      pathways = [
        make_pathway(%{pathway_id: "PW_1", pathway_mode: 1, length: Decimal.new("5")})
      ]

      groups = PathwayFieldCompleteness.build(%{pathways: pathways})
      assert length(groups) == 1
      assert hd(groups).mode == 1
    end

    test "handles missing field keys on a pathway as not present" do
      pathways = [
        %{pathway_id: "PW_1", pathway_mode: 1, is_bidirectional: true}
      ]

      [group] = PathwayFieldCompleteness.build(%{pathways: pathways})
      [field] = group.fields

      assert field.status == :fail
      assert field.present == 0
      assert field.total == 1
    end

    test "field labels are correct" do
      pathways = [
        make_pathway(%{pathway_id: "PW_1", pathway_mode: 3})
      ]

      [group] = PathwayFieldCompleteness.build(%{pathways: pathways})
      labels = Enum.map(group.fields, & &1.label)
      assert labels == ["Traversal time", "Length", "Min width"]
    end
  end
end
