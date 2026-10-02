defmodule GtfsPlanner.FeedPublishing.StaticArtifactTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.FeedPublishing.StaticArtifact

  @full_members [
    {"agency.txt",
     "agency_id,agency_name,agency_url,agency_timezone\n" <>
       "MTA,Metro Transit,https://metro.example,America/New_York\n"},
    {"routes.txt",
     "route_id,agency_id,route_short_name,route_type\n" <>
       "R1,MTA,One,3\nR2,MTA,Two,1\n"},
    {"trips.txt", "trip_id,route_id,service_id\nT1,R1,S1\nT2,R2,S2\nT3,R1,S1\n"},
    {"stops.txt", "stop_id,stop_name\nA1,Alpha\nB1,Bravo\n"},
    {"frequencies.txt", "trip_id,start_time,end_time,headway_secs\nT1,06:00:00,10:00:00,600\n"},
    {"stop_times.txt",
     "trip_id,arrival_time,departure_time,stop_id\n" <>
       "T1,06:00:00,06:00:00,A1\nT1,06:10:00,06:10:00,B1\nT2,07:00:00,07:00:00,A1\n"},
    {"route_patterns.txt", "route_pattern_id,route_id\nRP1,R1\n"},
    {"stop-area.png", "not-really-a-png"}
  ]

  @pathways_members [
    {"stops.txt", "stop_id,stop_name,stop_lat,stop_lon\nP1,Platform,1.0,2.0\n"},
    {"levels.txt", "level_id,level_index\nL1,0.0\n"},
    {"pathways.txt", "pathway_id,from_stop_id,to_stop_id,pathway_mode\nPW1,P1,P1,1\n"},
    {"pathway_evolutions.txt", "evolution_id\nE1\n"},
    {"pathway-diagram.png", "not-really-a-png"}
  ]

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "static_artifact_test_#{Ecto.UUID.generate()}"
      )

    on_exit(fn -> File.rm_rf(dir) end)
    File.mkdir_p!(dir)

    {:ok, dir: dir}
  end

  describe "inspect/1 refusals" do
    test "an operations run is refused from its trusted run type, before the archive is opened",
         %{dir: dir} do
      artifact =
        archive(dir, "gtfs.zip", @full_members ++ [{"vehicles.txt", "vehicle_id\nV1\n"}])

      assert {:error, :operations_profile_not_publishable} =
               StaticArtifact.inspect(%{
                 path: artifact,
                 filename: "gtfs.zip",
                 export_type: :operations,
                 slot: :main
               })

      # The Flex sidecar of an operations run carries the same run type, so it
      # is refused for the same reason rather than published as flex.
      assert {:error, :operations_profile_not_publishable} =
               StaticArtifact.inspect(%{
                 path: artifact,
                 filename: "gtfs.zip",
                 export_type: :operations,
                 slot: :flex
               })

      # The refusal happens before the archive is read, so a path that does not
      # exist is refused the same way instead of raising.
      assert {:error, :operations_profile_not_publishable} =
               StaticArtifact.inspect(%{
                 path: Path.join(dir, "absent.zip"),
                 export_type: :operations
               })
    end

    test "any TODS member refuses the whole candidate without stripping it", %{dir: dir} do
      for member <- [
            "stops_supplement.txt",
            "vehicles.txt",
            "routes_supplement.txt",
            "trips_supplement.txt",
            "stop_times_supplement.txt",
            "calendar_dates_supplement.txt",
            "employee_run_dates.txt",
            "run_events.txt"
          ] do
        name = String.replace(member, ".txt", "") <> "-candidate.zip"
        artifact = archive(dir, name, @full_members ++ [{member, "id\nX\n"}])

        assert {:error, :tods_content_not_publishable} =
                 StaticArtifact.inspect(%{path: artifact, filename: name, export_type: :full})
      end
    end

    test "an unsafe entry name is refused and an unparsable catalog file is typed", %{dir: dir} do
      unsafe = archive(dir, "unsafe.zip", @full_members ++ [{"../escape.txt", "x\n"}])

      assert {:error, :unsafe_entry_name} =
               StaticArtifact.inspect(%{
                 path: unsafe,
                 filename: "unsafe.zip",
                 export_type: :full
               })

      malformed = archive(dir, "malformed.zip", [{"routes.txt", "route_id,route_type\nR1\n"}])

      assert {:error, {:catalog_unreadable, "routes.txt", :wrong_field_count}} =
               StaticArtifact.inspect(%{
                 path: malformed,
                 filename: "malformed.zip",
                 export_type: :full
               })

      not_an_archive = Path.join(dir, "plain.txt")
      File.write!(not_an_archive, "not a zip at all")

      assert {:error, :unreadable_archive} =
               StaticArtifact.inspect(%{
                 path: not_an_archive,
                 filename: "plain.txt",
                 export_type: :full
               })
    end

    test "a digest that no longer describes the bytes is refused", %{dir: dir} do
      artifact = archive(dir, "gtfs.zip", @full_members)
      sha256 = sha256(artifact)

      assert {:ok, %{profile: :static}} =
               StaticArtifact.inspect(%{
                 path: artifact,
                 filename: "gtfs.zip",
                 export_type: :full,
                 sha256: sha256
               })

      assert {:error, :artifact_hash_mismatch} =
               StaticArtifact.inspect(%{
                 path: artifact,
                 filename: "gtfs.zip",
                 export_type: :full,
                 sha256: String.duplicate("0", 64)
               })
    end

    test "a descriptor without a usable path is refused" do
      assert {:error, :invalid_artifact} = StaticArtifact.inspect(%{path: nil})
      assert {:error, :invalid_artifact} = StaticArtifact.inspect(%{path: "/tmp/x.zip"})
    end
  end

  describe "inspect/1 profile and catalog" do
    test "a full artifact is static and its catalog comes from the emitted files", %{dir: dir} do
      artifact = archive(dir, "gtfs.zip", @full_members)

      assert {:ok, result} =
               StaticArtifact.inspect(%{
                 path: artifact,
                 filename: "gtfs.zip",
                 export_type: :full,
                 slot: :main
               })

      assert result.profile == :static
      assert result.inventory == Enum.sort(Enum.map(@full_members, &elem(&1, 0)))

      catalog = result.catalog
      assert catalog.agency_ids == ["MTA"]
      assert catalog.route_ids == ["R1", "R2"]
      assert catalog.route_types == %{"R1" => 3, "R2" => 1}
      assert catalog.stop_ids == ["A1", "B1"]
      assert catalog.trip_ids == ["T1", "T2", "T3"]
      assert catalog.trip_services == %{"T1" => "S1", "T2" => "S2", "T3" => "S1"}
      assert catalog.frequency_starts == %{"T1" => "06:00:00"}
      assert catalog.route_stops == %{"R1" => ["A1", "B1"], "R2" => ["A1"]}
    end

    test "flex-only output in the main slot is classified as flex from its own files", %{dir: dir} do
      artifact =
        archive(dir, "flex-in-main.zip", [
          {"location_groups.txt", "location_group_id,location_group_name\nLG1,Downtown\n"},
          {"trips.txt", "trip_id,route_id,service_id\nF1,FX,S1\n"},
          {"stop_times.txt", "trip_id,stop_id,location_group_id,location_id\nF1,Z1,LG1,L1\n"}
        ])

      assert {:ok, result} =
               StaticArtifact.inspect(%{
                 path: artifact,
                 filename: "flex-in-main.zip",
                 export_type: :full,
                 slot: :main
               })

      assert result.profile == :flex
      assert result.catalog.trip_ids == ["F1"]
    end

    test "a pathways artifact is pathways and discloses its extensions and diagrams", %{dir: dir} do
      artifact = archive(dir, "pathways.zip", @pathways_members)

      assert {:ok, result} =
               StaticArtifact.inspect(%{
                 path: artifact,
                 filename: "pathways.zip",
                 export_type: :pathways,
                 slot: :main
               })

      assert result.profile == :pathways
      assert result.inventory == Enum.sort(Enum.map(@pathways_members, &elem(&1, 0)))
      assert "pathway_evolutions.txt" in result.inventory
      assert "pathway-diagram.png" in result.inventory
      assert result.catalog.stop_ids == ["P1"]
      assert result.catalog.route_ids == []
    end
  end

  describe "mismatches/2" do
    setup %{dir: dir} do
      artifact = archive(dir, "gtfs.zip", @full_members)

      {:ok,
       catalog: elem(StaticArtifact.inspect(%{path: artifact, export_type: :full}), 1).catalog}
    end

    test "selectors the emitted feed answers produce no notice", %{catalog: catalog} do
      snapshots = [
        %{
          id: "11111111-1111-1111-1111-111111111111",
          name: "Blue line signal",
          selectors: %{
            agency_ids: ["MTA"],
            route_ids: ["R1"],
            route_types: [3],
            stop_ids: ["B1"],
            route_stops: [%{route_id: "R1", stop_id: "B1"}],
            trips: [%{trip_id: "T1", start_time: "06:00:00"}]
          }
        }
      ]

      assert StaticArtifact.mismatches(catalog, snapshots) == []
    end

    test "absent identities produce named, sorted notices and change nothing", %{catalog: catalog} do
      alert_id = "22222222-2222-2222-2222-222222222222"
      other_id = "11111111-1111-1111-1111-111111111111"

      snapshots = [
        %{
          id: alert_id,
          name: "Bridge closure",
          selectors: %{
            agency_ids: ["MTA", "OTHER"],
            route_ids: ["R1", "R9"],
            route_types: [900],
            stop_ids: ["Z9"],
            route_stops: [%{route_id: "R2", stop_id: "A1"}],
            trips: [%{trip_id: "T9"}, %{trip_id: "T1", start_time: "09:00:00"}]
          }
        },
        %{id: other_id, name: "No selectors", selectors: %{}},
        %{id: "33333333-3333-3333-3333-333333333333", name: "No selectors key"}
      ]

      before = snapshots

      assert StaticArtifact.mismatches(catalog, snapshots) == [
               %{
                 alert_id: alert_id,
                 alert_name: "Bridge closure",
                 reason: :unknown_agency,
                 ids: ["OTHER"]
               },
               %{
                 alert_id: alert_id,
                 alert_name: "Bridge closure",
                 reason: :unknown_frequency_start_time,
                 ids: ["T1"]
               },
               %{
                 alert_id: alert_id,
                 alert_name: "Bridge closure",
                 reason: :unknown_route,
                 ids: ["R9"]
               },
               %{
                 alert_id: alert_id,
                 alert_name: "Bridge closure",
                 reason: :unknown_route_stop,
                 ids: [{"R2", "A1"}]
               },
               %{
                 alert_id: alert_id,
                 alert_name: "Bridge closure",
                 reason: :unknown_route_type,
                 ids: [900]
               },
               %{
                 alert_id: alert_id,
                 alert_name: "Bridge closure",
                 reason: :unknown_stop,
                 ids: ["Z9"]
               },
               %{
                 alert_id: alert_id,
                 alert_name: "Bridge closure",
                 reason: :unknown_trip,
                 ids: ["T9"]
               }
             ]

      assert snapshots == before
      assert StaticArtifact.mismatches(catalog, []) == []
    end

    test "string-keyed selectors from a stored answer are read the same way", %{catalog: catalog} do
      snapshots = [
        %{
          id: "44444444-4444-4444-4444-444444444444",
          name: "Stored answer",
          selectors: %{
            "route_ids" => ["R1"],
            "route_stops" => [%{"route_id" => "R1", "stop_id" => "A1"}],
            "trips" => [%{"trip_id" => "T3"}]
          }
        }
      ]

      assert StaticArtifact.mismatches(catalog, snapshots) == []
    end
  end

  defp archive(dir, name, members) do
    path = Path.join(dir, name)
    entries = Enum.map(members, fn {member, content} -> {String.to_charlist(member), content} end)

    case :zip.create(String.to_charlist(path), entries) do
      {:ok, _written} -> path
      {:error, reason} -> flunk("could not build #{name}: #{inspect(reason)}")
    end
  end

  defp sha256(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
