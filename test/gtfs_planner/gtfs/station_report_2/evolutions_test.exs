defmodule GtfsPlanner.Gtfs.StationReport2.EvolutionsTest do
  @moduledoc """
  Merge evidence (EV-17) for the base-versus-effective connection comparison:

  - A station whose only step-free link is an elevator keeps walking when the
    elevator closes and loses step-free in both directions; the same platform is
    then listed under `platforms_without_step_free`.
  - Closing one entrance's elevator reports that pair alone while a second
    entrance still reaches the platform, and a boarding area counts toward its
    parent platform in both directions.
  - Stairs and escalators carry walking but never step-free, an unidirectional
    pathway supplies only its own direction, and closing a bidirectional pathway
    removes both.
  - A pair the base graph never reached is a `baseline_gap`, never a loss, and
    missing entrances, missing platforms and a pathway leaving the station make
    the evaluation `:incomplete` while keeping the pairs that can be computed.

  Every expected pair and finding is hand-enumerated from the fixture graph
  below rather than computed by the module under test. `Graph` is the shared
  traversal primitive both the module and the station report already use, and
  the fixtures are `%Stop{}`/`%Pathway{}` structs of the shape
  `Gtfs.get_station_report_snapshot/3` returns, with a `MapSet` of closed
  `pathway_id`s standing in for the closed set a loaded instant produces. No
  database, calendar or clock is involved.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.StationReport2.Evolutions
  alias GtfsPlanner.Gtfs.Stop

  # GTFS pathway modes: 1 walkway, 2 stairs, 3 moving sidewalk, 4 escalator,
  # 5 elevator, 6 fare gate, 7 exit gate.
  @walkway 1
  @stairs 2
  @escalator 4
  @elevator 5

  describe "evaluate/2" do
    test "counts a boarding area as its platform in both directions" do
      snapshot = %{
        station: station(),
        child_stops: [entrance("ENT_A"), platform("PLAT_1"), boarding_area("BA_1", "PLAT_1")],
        pathways: [pathway("PW_TO_BOARDING_AREA", "ENT_A", "BA_1", @walkway)]
      }

      # The only pathway ends at the boarding area, so both directions depend on
      # the boarding area standing in for its platform.
      assert [pair] = Evolutions.evaluate(snapshot, MapSet.new()).pairs
      assert pair.entrance_id == "ENT_A"
      assert pair.platform_id == "PLAT_1"
      assert pair.walking_to_platform
      assert pair.step_free_to_platform
      assert pair.walking_to_exit
      assert pair.step_free_to_exit
    end

    test "keeps walking and loses step-free when the only elevator closes" do
      snapshot = elevator_and_stairs_station()

      assert %{status: :complete, incomplete_reasons: []} =
               base = Evolutions.evaluate(snapshot, MapSet.new())

      assert [base_pair] = base.pairs
      assert base_pair.walking_to_platform
      assert base_pair.step_free_to_platform
      assert base_pair.walking_to_exit
      assert base_pair.step_free_to_exit

      # The stairs remain: walking survives in both directions while the elevator
      # leaves the step-free graph with no edge at all out of the entrance.
      effective = Evolutions.evaluate(snapshot, MapSet.new(["PW_ELEVATOR_A"]))

      assert effective.pairs == [
               %{
                 entrance_id: "ENT_A",
                 platform_id: "PLAT_1",
                 walking_to_platform: true,
                 step_free_to_platform: false,
                 walking_to_exit: true,
                 step_free_to_exit: false
               }
             ]
    end

    test "never routes step-free through stairs or escalators" do
      snapshot = %{
        station: station(),
        child_stops: [entrance("ENT_A"), platform("PLAT_1")],
        pathways: [
          pathway("PW_STAIRS", "ENT_A", "PLAT_1", @stairs),
          pathway("PW_ESCALATOR", "ENT_A", "PLAT_1", @escalator)
        ]
      }

      base = Evolutions.evaluate(snapshot, MapSet.new())

      assert base.pairs == [
               %{
                 entrance_id: "ENT_A",
                 platform_id: "PLAT_1",
                 walking_to_platform: true,
                 step_free_to_platform: false,
                 walking_to_exit: true,
                 step_free_to_exit: false
               }
             ]

      # Closing the stairs leaves the escalator, so walking survives and the
      # Closing the stairs leaves the escalator, so walking survives and nothing
      # is lost. The two step-free directions are base gaps: no step-free route
      # existed before the closure either, so the platform is not reported as
      # having lost step-free access it never had.
      effective = Evolutions.evaluate(snapshot, MapSet.new(["PW_STAIRS"]))
      comparison = Evolutions.compare(base, effective)
      assert comparison.lost == []

      assert comparison.baseline_gaps == [
               finding("ENT_A", "PLAT_1", :step_free, :to_exit),
               finding("ENT_A", "PLAT_1", :step_free, :to_platform)
             ]

      assert comparison.platforms_without_step_free == %{to_platform: [], to_exit: []}
    end

    test "supplies only the direction a unidirectional pathway provides" do
      snapshot = %{
        station: station(),
        child_stops: [entrance("ENT_A"), platform("PLAT_1")],
        pathways: [pathway("PW_INBOUND", "ENT_A", "PLAT_1", @walkway, bidirectional: false)]
      }

      base = Evolutions.evaluate(snapshot, MapSet.new())
      assert [%{walking_to_platform: true, walking_to_exit: false}] = base.pairs

      effective = Evolutions.evaluate(snapshot, MapSet.new(["PW_INBOUND"]))
      comparison = Evolutions.compare(base, effective)

      assert comparison.lost == [
               finding("ENT_A", "PLAT_1", :step_free, :to_platform),
               finding("ENT_A", "PLAT_1", :walking, :to_platform)
             ]

      assert comparison.baseline_gaps == [
               finding("ENT_A", "PLAT_1", :step_free, :to_exit),
               finding("ENT_A", "PLAT_1", :walking, :to_exit)
             ]

      assert comparison.platforms_without_step_free == %{to_platform: ["PLAT_1"], to_exit: []}
    end

    test "ignores a closed pathway the station does not have" do
      snapshot = elevator_and_stairs_station()

      assert Evolutions.evaluate(snapshot, MapSet.new(["PW_NOT_IN_STATION"])) ==
               Evolutions.evaluate(snapshot, MapSet.new())
    end

    test "is incomplete without entrances and keeps no pairs" do
      snapshot = %{
        station: station(),
        child_stops: [platform("PLAT_1"), boarding_area("BA_1", "PLAT_1")],
        pathways: []
      }

      evaluation = Evolutions.evaluate(snapshot, MapSet.new())
      assert evaluation.status == :incomplete
      assert evaluation.incomplete_reasons == [:no_entrances]
      assert evaluation.pairs == []
    end

    test "is incomplete without platforms and keeps no pairs" do
      snapshot = %{
        station: station(),
        child_stops: [entrance("ENT_A"), passage("NODE_1")],
        pathways: [pathway("PW_DEAD_END", "ENT_A", "NODE_1", @walkway)]
      }

      evaluation = Evolutions.evaluate(snapshot, MapSet.new())
      assert evaluation.status == :incomplete
      assert evaluation.incomplete_reasons == [:no_platforms]
      assert evaluation.pairs == []
    end

    test "is incomplete for a pathway leaving the station and keeps computable pairs" do
      snapshot = %{
        station: station(),
        child_stops: [entrance("ENT_A"), platform("PLAT_1")],
        pathways: [
          pathway("PW_LOCAL", "ENT_A", "PLAT_1", @walkway),
          pathway("PW_ACROSS_THE_TRACKS", "PLAT_1", "OTHER_STATION_PLATFORM", @walkway)
        ]
      }

      evaluation = Evolutions.evaluate(snapshot, MapSet.new())
      assert evaluation.status == :incomplete

      assert evaluation.incomplete_reasons == [
               {:cross_station_pathways, ["PW_ACROSS_THE_TRACKS"]}
             ]

      # The pair the station can answer is still evaluated, so an incomplete
      # result shows what it knows.
      assert [pair] = evaluation.pairs
      assert pair.entrance_id == "ENT_A"
      assert pair.platform_id == "PLAT_1"
      assert pair.walking_to_platform
    end
  end

  describe "compare/2" do
    test "names the lost step-free pair in both directions and nothing else" do
      snapshot = elevator_and_stairs_station()

      comparison =
        Evolutions.compare(
          Evolutions.evaluate(snapshot, MapSet.new()),
          Evolutions.evaluate(snapshot, MapSet.new(["PW_ELEVATOR_A"]))
        )

      assert comparison.lost == [
               finding("ENT_A", "PLAT_1", :step_free, :to_exit),
               finding("ENT_A", "PLAT_1", :step_free, :to_platform)
             ]

      assert comparison.baseline_gaps == []

      assert comparison.platforms_without_step_free == %{
               to_platform: ["PLAT_1"],
               to_exit: ["PLAT_1"]
             }
    end

    test "reports a pair loss without claiming the platform lost step-free" do
      snapshot = two_entrance_station()

      base = Evolutions.evaluate(snapshot, MapSet.new())
      assert base.status == :complete
      assert [%{entrance_id: "ENT_A"}, %{entrance_id: "ENT_B"}] = base.pairs
      assert Enum.all?(base.pairs, & &1.step_free_to_platform)
      assert Enum.all?(base.pairs, & &1.step_free_to_exit)

      # Closing entrance A's elevator removes only that pair: the boarding area
      # still carries entrance B, so the platform keeps step-free access.
      comparison =
        Evolutions.compare(base, Evolutions.evaluate(snapshot, MapSet.new(["PW_ELEVATOR_A"])))

      assert comparison.lost == [
               finding("ENT_A", "PLAT_1", :step_free, :to_exit),
               finding("ENT_A", "PLAT_1", :step_free, :to_platform),
               finding("ENT_A", "PLAT_1", :walking, :to_exit),
               finding("ENT_A", "PLAT_1", :walking, :to_platform)
             ]

      assert comparison.baseline_gaps == []
      assert comparison.platforms_without_step_free == %{to_platform: [], to_exit: []}
    end

    test "lists base gaps as gaps and a bidirectional closure as losses in both directions" do
      snapshot = %{
        station: station(),
        child_stops: [entrance("ENT_A"), entrance("ENT_B"), platform("PLAT_1")],
        pathways: [pathway("PW_ENTRANCE_A", "ENT_A", "PLAT_1", @walkway)]
      }

      comparison =
        Evolutions.compare(
          Evolutions.evaluate(snapshot, MapSet.new()),
          Evolutions.evaluate(snapshot, MapSet.new(["PW_ENTRANCE_A"]))
        )

      # Entrance A reached the platform in both directions and loses both;
      # entrance B never had a route in either direction, so its four directions
      # are gaps and never losses.
      assert comparison.lost == [
               finding("ENT_A", "PLAT_1", :step_free, :to_exit),
               finding("ENT_A", "PLAT_1", :step_free, :to_platform),
               finding("ENT_A", "PLAT_1", :walking, :to_exit),
               finding("ENT_A", "PLAT_1", :walking, :to_platform)
             ]

      assert comparison.baseline_gaps == [
               finding("ENT_B", "PLAT_1", :step_free, :to_exit),
               finding("ENT_B", "PLAT_1", :step_free, :to_platform),
               finding("ENT_B", "PLAT_1", :walking, :to_exit),
               finding("ENT_B", "PLAT_1", :walking, :to_platform)
             ]

      assert comparison.platforms_without_step_free == %{
               to_platform: ["PLAT_1"],
               to_exit: ["PLAT_1"]
             }
    end

    test "sorts findings by platform, entrance, mode and direction" do
      snapshot = %{
        station: station(),
        child_stops: [
          entrance("ENT_A"),
          entrance("ENT_B"),
          platform("PLAT_1"),
          platform("PLAT_2")
        ],
        pathways: [
          pathway("PW_A1", "ENT_A", "PLAT_1", @walkway),
          pathway("PW_B1", "ENT_B", "PLAT_1", @elevator),
          pathway("PW_A2", "ENT_A", "PLAT_2", @walkway),
          pathway("PW_B2", "ENT_B", "PLAT_2", @elevator)
        ]
      }

      closed = MapSet.new(["PW_A1", "PW_B1", "PW_A2", "PW_B2"])

      comparison =
        Evolutions.compare(
          Evolutions.evaluate(snapshot, MapSet.new()),
          Evolutions.evaluate(snapshot, closed)
        )

      # Four pairs, each losing four directions, enumerated in the documented
      # order rather than in the order the graph happens to be walked.
      assert comparison.lost ==
               for(
                 platform_id <- ["PLAT_1", "PLAT_2"],
                 entrance_id <- ["ENT_A", "ENT_B"],
                 mode <- [:step_free, :walking],
                 direction <- [:to_exit, :to_platform],
                 do: finding(entrance_id, platform_id, mode, direction)
               )

      assert comparison.platforms_without_step_free == %{
               to_platform: ["PLAT_1", "PLAT_2"],
               to_exit: ["PLAT_1", "PLAT_2"]
             }
    end

    test "reports nothing when no closure is active" do
      snapshot = two_entrance_station()
      base = Evolutions.evaluate(snapshot, MapSet.new())

      assert Evolutions.compare(base, Evolutions.evaluate(snapshot, MapSet.new())) == %{
               lost: [],
               baseline_gaps: [],
               platforms_without_step_free: %{to_platform: [], to_exit: []}
             }
    end

    test "leaves an incomplete evaluation with no findings to present as an all-clear" do
      snapshot = %{
        station: station(),
        child_stops: [platform("PLAT_1"), boarding_area("BA_1", "PLAT_1")],
        pathways: []
      }

      base = Evolutions.evaluate(snapshot, MapSet.new())
      assert base.status == :incomplete

      assert Evolutions.compare(base, Evolutions.evaluate(snapshot, MapSet.new(["PW_ANY"]))) == %{
               lost: [],
               baseline_gaps: [],
               platforms_without_step_free: %{to_platform: [], to_exit: []}
             }
    end
  end

  # -- fixtures --------------------------------------------------------------

  # Entrance A reaches node 1 by elevator and by stairs, and node 1 reaches the
  # boarding area of platform 1 by walkway. The step-free graph therefore holds
  # the elevator and the concourse, and the walking graph holds all three.
  defp elevator_and_stairs_station do
    %{
      station: station(),
      child_stops: [
        entrance("ENT_A"),
        passage("NODE_1"),
        platform("PLAT_1"),
        boarding_area("BA_1", "PLAT_1")
      ],
      pathways: [
        pathway("PW_ELEVATOR_A", "ENT_A", "NODE_1", @elevator),
        pathway("PW_STAIRS_A", "ENT_A", "NODE_1", @stairs),
        pathway("PW_CONCOURSE", "NODE_1", "BA_1", @walkway)
      ]
    }
  end

  # Two entrances, each with its own elevator, each reaching the same boarding
  # area. Closing one elevator leaves the other entrance's route intact.
  defp two_entrance_station do
    %{
      station: station(),
      child_stops: [
        entrance("ENT_A"),
        entrance("ENT_B"),
        passage("NODE_A"),
        passage("NODE_B"),
        platform("PLAT_1"),
        boarding_area("BA_1", "PLAT_1")
      ],
      pathways: [
        pathway("PW_ELEVATOR_A", "ENT_A", "NODE_A", @elevator),
        pathway("PW_LINK_A", "NODE_A", "BA_1", @walkway),
        pathway("PW_ELEVATOR_B", "ENT_B", "NODE_B", @elevator),
        pathway("PW_LINK_B", "NODE_B", "BA_1", @walkway)
      ]
    }
  end

  defp station(stop_id \\ "STATION_1") do
    %Stop{stop_id: stop_id, stop_name: "Central", location_type: 1}
  end

  defp entrance(stop_id), do: child_stop(stop_id, 2, "STATION_1")
  defp platform(stop_id), do: child_stop(stop_id, 0, "STATION_1")
  defp passage(stop_id), do: child_stop(stop_id, 3, "STATION_1")
  defp boarding_area(stop_id, platform_id), do: child_stop(stop_id, 4, platform_id)

  defp child_stop(stop_id, location_type, parent_station) do
    %Stop{
      stop_id: stop_id,
      stop_name: stop_id,
      location_type: location_type,
      parent_station: parent_station
    }
  end

  defp pathway(pathway_id, from_stop_id, to_stop_id, pathway_mode, opts \\ []) do
    %Pathway{
      pathway_id: pathway_id,
      pathway_mode: pathway_mode,
      is_bidirectional: Keyword.get(opts, :bidirectional, true),
      from_stop_id: from_stop_id,
      to_stop_id: to_stop_id
    }
  end

  defp finding(entrance_id, platform_id, mode, direction) do
    %{entrance_id: entrance_id, platform_id: platform_id, mode: mode, direction: direction}
  end
end
