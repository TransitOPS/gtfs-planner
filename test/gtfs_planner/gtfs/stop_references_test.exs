defmodule GtfsPlanner.Gtfs.StopReferencesTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AlertsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.Publication

  alias GtfsPlanner.Gtfs.{
    AlignmentSegment,
    AuditContext,
    DeadheadTime,
    FareLegJoinRule,
    FlexService,
    Pathway,
    ReliefPoint,
    Stop,
    StopArea,
    StopEditing,
    StopReferences,
    StopTime,
    Transfer,
    Translation
  }

  alias GtfsPlanner.Gtfs.Blocking.DeadheadTimes
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations.WalkabilityTest
  alias GtfsPlanner.Versions

  @reference_columns MapSet.new([
                       {"pathways", "from_stop_id"},
                       {"pathways", "to_stop_id"},
                       {"stop_times", "stop_id"},
                       {"transfers", "from_stop_id"},
                       {"transfers", "to_stop_id"},
                       {"stop_areas", "stop_id"},
                       {"fare_leg_join_rules", "from_stop_id"},
                       {"fare_leg_join_rules", "to_stop_id"},
                       {"stops", "parent_station"},
                       {"translations", "record_id"},
                       {"walkability_tests", "stop_id"},
                       {"route_pattern_stops", "stop_id"},
                       {"alignment_segments", "from_stop_id"},
                       {"alignment_segments", "to_stop_id"},
                       {"relief_points", "stop_id"},
                       {"deadhead_times", "from_ref"},
                       {"deadhead_times", "to_ref"},
                       {"flex_services", "first_stop_id"},
                       {"flex_services", "last_stop_id"},
                       {"flex_services", "hub_stop_ids"}
                     ])

  test "catalog covers all conventional stop columns in scoped base tables" do
    columns =
      Repo.query!("""
      SELECT c.table_name, c.column_name
      FROM information_schema.columns c
      JOIN information_schema.tables t
        ON t.table_schema = c.table_schema AND t.table_name = c.table_name
      WHERE c.table_schema = 'public'
        AND t.table_type = 'BASE TABLE'
        AND EXISTS (
          SELECT 1 FROM information_schema.columns owner
          WHERE owner.table_schema = c.table_schema
            AND owner.table_name = c.table_name
            AND owner.column_name = 'organization_id'
        )
        AND (
          c.column_name = 'stop_id'
          OR c.column_name LIKE '%\\_stop\\_id' ESCAPE '\\'
          OR c.column_name LIKE '%\\_stop\\_ids' ESCAPE '\\'
          OR c.column_name = 'parent_station'
        )
      """).rows
      |> MapSet.new(fn [table, column] -> {table, column} end)

    assert columns ==
             @reference_columns
             |> MapSet.delete({"translations", "record_id"})
             |> MapSet.delete({"deadhead_times", "from_ref"})
             |> MapSet.delete({"deadhead_times", "to_ref"})
             |> MapSet.put({"stops", "stop_id"})
             |> MapSet.put({"change_logs", "station_stop_id"})
             |> MapSet.put({"stop_levels", "stop_id"})

    # Tagged references are intentionally classified outside the stop_id wildcard.
    assert %{rows: [["from_ref", "character varying"], ["to_ref", "character varying"]]} =
             Repo.query!("""
             SELECT column_name, data_type FROM information_schema.columns
             WHERE table_schema = 'public' AND table_name = 'deadhead_times'
               AND column_name IN ('from_ref', 'to_ref')
             ORDER BY column_name
             """)

    assert DeadheadTimes.encode_ref({:stop, "A:B"}) == "stop:A:B"
    assert DeadheadTimes.decode_ref("stop:A:B") == {:ok, {:stop, "A:B"}}
    assert DeadheadTimes.decode_ref("stop:") == :error

    catalog_columns =
      StopReferences.catalog()
      |> MapSet.new(fn {_key, schema, field, _kind} ->
        {schema.__schema__(:source), Atom.to_string(field)}
      end)

    assert catalog_columns == @reference_columns

    assert Enum.all?(StopReferences.catalog(), fn {_key, schema, field, kind} ->
             schema.__schema__(:type, field) ==
               if(kind == :array, do: {:array, :string}, else: :string)
           end)

    # stop_levels.stop_id matches the name pattern but stores stops.id, a UUID.
    assert %{rows: [["uuid"]]} =
             Repo.query!("""
             SELECT data_type FROM information_schema.columns
             WHERE table_schema = 'public' AND table_name = 'stop_levels'
               AND column_name = 'stop_id'
             """)
  end

  test "count, rename and dependents cover every field without crossing versions" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    other_version = gtfs_version_fixture(organization.id)

    stop = stop_fixture(organization.id, version.id, stop_id: "S1")
    stop_fixture(organization.id, other_version.id, stop_id: "S1")
    rows = insert_references(organization.id, version.id, "S1")
    other_rows = insert_references(organization.id, other_version.id, "S1")

    counts = StopReferences.count(organization.id, version.id, ["S1"])
    keys = StopReferences.catalog() |> Enum.map(&elem(&1, 0))
    assert Map.take(counts, keys) == Map.new(keys, &{&1, 1})
    assert counts.total == length(keys)
    assert StopReferences.count(organization.id, version.id, []).total == 0

    dependents = StopReferences.dependents(organization.id, version.id, ["S1"])
    assert dependents == Map.drop(counts, [:pathways_from, :pathways_to, :total])

    assert {:ok, ^counts} =
             Repo.transaction(fn ->
               Versions.lock_for_exclusive_write!(organization.id, version.id)
               StopReferences.rename!(organization.id, version.id, %{"S1" => "S2"})
             end)

    assert Repo.get!(Stop, stop.id).stop_id == "S2"

    assert StopReferences.count(organization.id, version.id, ["S1"]).total == 0
    assert StopReferences.count(organization.id, version.id, ["S2"]) == counts
    assert StopReferences.count(organization.id, other_version.id, ["S1"]) == counts
    assert_reference_values(rows, "S2")
    assert_reference_values(other_rows, "S1")
    assert Repo.get!(Translation, rows.other_translation.id).record_id == "S1"
  end

  test "two-phase rename swaps stop IDs and their references" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    a = stop_fixture(organization.id, version.id, stop_id: "A")
    b = stop_fixture(organization.id, version.id, stop_id: "B")

    a_time =
      insert(StopTime, organization.id, version.id, %{
        trip_id: "a",
        stop_id: "A",
        stop_sequence: 1
      })

    b_time =
      insert(StopTime, organization.id, version.id, %{
        trip_id: "b",
        stop_id: "B",
        stop_sequence: 1
      })

    hubs =
      insert(FlexService, organization.id, version.id, %{
        key: "swap_hubs",
        name: "Swap hubs",
        kind: :detour,
        hub_stop_ids: ["A", "B"]
      })

    empty_hubs =
      insert(FlexService, organization.id, version.id, %{
        key: "empty_hubs",
        name: "Empty hubs",
        kind: :detour,
        hub_stop_ids: []
      })

    first_relief = insert(ReliefPoint, organization.id, version.id, %{stop_id: "A"})
    second_relief = insert(ReliefPoint, organization.id, version.id, %{stop_id: "B"})

    first_deadhead =
      insert(DeadheadTime, organization.id, version.id, %{
        from_ref: "stop:A",
        to_ref: "stop:B",
        minutes: 12
      })

    second_deadhead =
      insert(DeadheadTime, organization.id, version.id, %{
        from_ref: "stop:B",
        to_ref: "stop:A",
        minutes: 17
      })

    assert {:ok,
            %{
              stop_times: 2,
              flex_hubs: 1,
              relief_points: 2,
              deadhead_times_from: 2,
              deadhead_times_to: 2,
              total: 9
            }} =
             Repo.transaction(fn ->
               Versions.lock_for_exclusive_write!(organization.id, version.id)
               StopReferences.rename!(organization.id, version.id, %{"A" => "B", "B" => "A"})
             end)

    assert Repo.get!(Stop, a.id).stop_id == "B"
    assert Repo.get!(Stop, b.id).stop_id == "A"
    assert Repo.get!(StopTime, a_time.id).stop_id == "B"
    assert Repo.get!(StopTime, b_time.id).stop_id == "A"
    assert Repo.get!(FlexService, hubs.id).hub_stop_ids == ["B", "A"]
    assert Repo.get!(FlexService, empty_hubs.id).hub_stop_ids == []
    assert Repo.get!(ReliefPoint, first_relief.id).stop_id == "B"
    assert Repo.get!(ReliefPoint, second_relief.id).stop_id == "A"

    assert %{from_ref: "stop:B", to_ref: "stop:A", minutes: 12} =
             Repo.get!(DeadheadTime, first_deadhead.id)

    assert %{from_ref: "stop:A", to_ref: "stop:B", minutes: 17} =
             Repo.get!(DeadheadTime, second_deadhead.id)
  end

  test "an exclusive lock returns the scoped version and rejects another organization" do
    organization = organization_fixture()
    other_organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    assert {:ok, %Versions.GtfsVersion{id: version_id}} =
             Repo.transaction(fn ->
               Versions.lock_for_exclusive_write!(organization.id, version.id)
             end)

    assert version_id == version.id

    assert {:error, :not_found} =
             Repo.transaction(fn ->
               Versions.lock_for_exclusive_write!(other_organization.id, version.id)
             end)
  end

  test "tagged refs keep colons exact and leave garage, unknown and empty tags alone" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    stop = stop_fixture(organization.id, version.id, stop_id: "S:1")
    garage_ref = "garage:#{Ecto.UUID.generate()}"

    tagged =
      insert(DeadheadTime, organization.id, version.id, %{
        from_ref: "stop:S:1",
        to_ref: "stop:S:1",
        minutes: 13
      })

    garage =
      insert(DeadheadTime, organization.id, version.id, %{
        from_ref: garage_ref,
        to_ref: "stop:",
        minutes: 14
      })

    unknown =
      insert(DeadheadTime, organization.id, version.id, %{
        from_ref: "unknown:S:1",
        to_ref: "stop:S:10",
        minutes: 15
      })

    assert %{deadhead_times_from: 1, deadhead_times_to: 1, total: 2} =
             StopReferences.count(organization.id, version.id, ["S:1"])

    assert {:ok, %{total: 2}} =
             Repo.transaction(fn ->
               Versions.lock_for_exclusive_write!(organization.id, version.id)
               StopReferences.rename!(organization.id, version.id, %{"S:1" => "S:2"})
             end)

    assert Repo.get!(Stop, stop.id).stop_id == "S:2"

    assert %{from_ref: "stop:S:2", to_ref: "stop:S:2", minutes: 13} =
             Repo.get!(DeadheadTime, tagged.id)

    assert %{from_ref: ^garage_ref, to_ref: "stop:", minutes: 14} =
             Repo.get!(DeadheadTime, garage.id)

    assert %{from_ref: "unknown:S:1", to_ref: "stop:S:10", minutes: 15} =
             Repo.get!(DeadheadTime, unknown.id)
  end

  describe "organization alert targets" do
    # An alert names the schedule's stops by feed ID, so it is a retained
    # external reference: the stop commands never rewrite it, and a stop the
    # schedule has since lost stays on the alert until an editor repairs it.
    setup do
      organization = organization_fixture()
      active_id = Repo.get!(Organization, organization.id).active_gtfs_version_id
      other = gtfs_version_fixture(organization.id)
      actor = editor_fixture(organization)

      for version_id <- [active_id, other.id], stop_id <- ["S1", "S2", "S3", "S4"] do
        stop_fixture(organization.id, version_id, stop_id: stop_id)
      end

      audit = fn version_id ->
        %AuditContext{
          organization_id: organization.id,
          gtfs_version_id: version_id,
          actor_id: actor.id,
          actor_email: actor.email
        }
      end

      alert =
        alert_fixture(audit.(active_id), %{
          "urgency" => "now",
          "situation" => "stop_closed",
          "cause" => "construction",
          "scope" => %{"shape" => "stop_all_routes", "stop_ids" => ["S1", "S3"]}
        })

      publication =
        Repo.insert!(%Publication{
          organization_id: organization.id,
          alert_id: alert.id,
          desired_revision: alert.revision,
          desired_snapshot: %{"scope" => %{"shape" => "stop_all_routes", "stops" => ["S1", "S3"]}},
          confirmed_revision: alert.revision,
          confirmed_snapshot: %{"scope" => %{"shape" => "stop_all_routes", "stops" => ["S1"]}}
        })

      %{
        organization: organization,
        active_id: active_id,
        other_id: other.id,
        audit: audit,
        alert: alert,
        publication: publication
      }
    end

    test "replace and delete in a non-active version leave the alert and its accepted content",
         context do
      before = retained(context)

      replace!(context, context.other_id, "S1", "S2")
      delete!(context, context.other_id, "S3")

      assert Repo.get_by(Stop, gtfs_version_id: context.other_id, stop_id: "S3") == nil
      assert retained(context) == before

      # The alert's own schedule still holds both stops it names.
      assert [] = stops_missing(context)
    end

    test "replace, delete and rename in the alert's schedule keep its original targets",
         context do
      before = retained(context)

      replace!(context, context.active_id, "S1", "S2")
      delete!(context, context.active_id, "S3")

      # The replace leaves S1 in the schedule; renaming it moves the schedule's stop.
      assert {:ok, _counts} =
               Repo.transaction(fn ->
                 Versions.lock_for_exclusive_write!(context.organization.id, context.active_id)

                 StopReferences.rename!(context.organization.id, context.active_id, %{
                   "S1" => "S9"
                 })
               end)

      # Neither stop the alert names is in the schedule now, and the alert still names both.
      assert stops_missing(context) == ["S1", "S3"]
      assert retained(context) == before

      assert before.scope.stop_ids == ["S1", "S3"]
      assert [%{"gtfs_id" => "S1"}, %{"gtfs_id" => "S3"}] = before.reference["selectors"]["stops"]

      assert {:ok, tabs} =
               Alerts.list_alerts(context.audit.(context.active_id), DateTime.utc_now())

      assert [%{needs_attention?: true}] = Enum.concat(Map.values(tabs))
    end
  end

  defp replace!(context, version_id, old_id, new_id) do
    old = Repo.get_by!(Stop, gtfs_version_id: version_id, stop_id: old_id)
    new = Repo.get_by!(Stop, gtfs_version_id: version_id, stop_id: new_id)
    audit = context.audit.(version_id)

    {:ok, review} = StopEditing.replace_review(old.id, new.id, audit)

    assert {:ok, _result} =
             StopEditing.replace_stop(old.id, new.id, %{fingerprint: review.fingerprint}, audit)
  end

  defp delete!(context, version_id, stop_id) do
    stop = Repo.get_by!(Stop, gtfs_version_id: version_id, stop_id: stop_id)
    audit = context.audit.(version_id)

    {:ok, review} = StopEditing.delete_review(stop.id, audit)

    assert {:ok, _result} = StopEditing.delete_stop(stop.id, review.fingerprint, audit)
  end

  # What a stop command must not touch: the private answer and its capture, the
  # revision they were saved at, and both accepted public snapshots.
  defp retained(context) do
    alert = Repo.get!(Alert, context.alert.id)
    publication = Repo.get!(Publication, context.publication.id)

    %{
      scope: alert.scope,
      reference: alert.target_reference,
      revision: alert.revision,
      updated_at: alert.updated_at,
      desired: publication.desired_snapshot,
      confirmed: publication.confirmed_snapshot
    }
  end

  defp stops_missing(context) do
    alert = Repo.get!(Alert, context.alert.id)

    alert.scope.stop_ids --
      Repo.all(
        from stop in Stop,
          where:
            stop.gtfs_version_id == ^context.active_id and stop.stop_id in ^alert.scope.stop_ids,
          select: stop.stop_id
      )
  end

  defp insert_references(organization_id, version_id, stop_id) do
    pattern = route_pattern_fixture(organization_id, version_id)

    %{
      pathways_from:
        insert(Pathway, organization_id, version_id, %{
          pathway_id: "from",
          pathway_mode: 1,
          from_stop_id: stop_id,
          to_stop_id: "X"
        }),
      pathways_to:
        insert(Pathway, organization_id, version_id, %{
          pathway_id: "to",
          pathway_mode: 1,
          from_stop_id: "X",
          to_stop_id: stop_id
        }),
      stop_times:
        insert(StopTime, organization_id, version_id, %{
          trip_id: "trip",
          stop_id: stop_id,
          stop_sequence: 1
        }),
      transfers_from:
        insert(Transfer, organization_id, version_id, %{
          from_stop_id: stop_id,
          to_stop_id: "X",
          transfer_type: 0
        }),
      transfers_to:
        insert(Transfer, organization_id, version_id, %{
          from_stop_id: "X",
          to_stop_id: stop_id,
          transfer_type: 0
        }),
      stop_areas:
        insert(StopArea, organization_id, version_id, %{area_id: "area", stop_id: stop_id}),
      fare_leg_join_rules_from:
        insert(FareLegJoinRule, organization_id, version_id, %{
          from_stop_id: stop_id,
          to_stop_id: "X"
        }),
      fare_leg_join_rules_to:
        insert(FareLegJoinRule, organization_id, version_id, %{
          from_stop_id: "X",
          to_stop_id: stop_id
        }),
      parent_stations:
        insert(Stop, organization_id, version_id, %{
          stop_id: "child",
          stop_name: "Child",
          parent_station: stop_id
        }),
      translations:
        insert(Translation, organization_id, version_id, %{
          table_name: "stops",
          field_name: "stop_name",
          language: "en",
          translation: "Name",
          record_id: stop_id
        }),
      other_translation:
        insert(Translation, organization_id, version_id, %{
          table_name: "routes",
          field_name: "route_long_name",
          language: "en",
          translation: "Name",
          record_id: stop_id
        }),
      walkability_tests:
        insert(WalkabilityTest, organization_id, version_id, %{
          stop_id: stop_id,
          address: "123 Main St",
          address_lat: Decimal.new("42.3601"),
          address_lon: Decimal.new("-71.0589")
        }),
      route_pattern_stops: route_pattern_stop_fixture(pattern, stop_id, 1),
      alignment_segments_from:
        insert(AlignmentSegment, organization_id, version_id, %{
          from_stop_id: stop_id,
          to_stop_id: "X"
        }),
      alignment_segments_to:
        insert(AlignmentSegment, organization_id, version_id, %{
          from_stop_id: "X",
          to_stop_id: stop_id
        }),
      relief_points: insert(ReliefPoint, organization_id, version_id, %{stop_id: stop_id}),
      deadhead_times_from:
        insert(DeadheadTime, organization_id, version_id, %{
          from_ref: "stop:#{stop_id}",
          to_ref: "garage:#{Ecto.UUID.generate()}",
          minutes: 9
        }),
      deadhead_times_to:
        insert(DeadheadTime, organization_id, version_id, %{
          from_ref: "garage:#{Ecto.UUID.generate()}",
          to_ref: "stop:#{stop_id}",
          minutes: 10
        }),
      flex_first:
        insert(FlexService, organization_id, version_id, %{
          key: "first",
          name: "First",
          kind: :detour,
          first_stop_id: stop_id
        }),
      flex_last:
        insert(FlexService, organization_id, version_id, %{
          key: "last",
          name: "Last",
          kind: :detour,
          last_stop_id: stop_id
        }),
      flex_hubs:
        insert(FlexService, organization_id, version_id, %{
          key: "hubs",
          name: "Hubs",
          kind: :detour,
          hub_stop_ids: [stop_id, "X"]
        })
    }
  end

  defp insert(schema, organization_id, version_id, attrs) do
    schema
    |> struct(Map.merge(attrs, %{organization_id: organization_id, gtfs_version_id: version_id}))
    |> Repo.insert!()
  end

  defp assert_reference_values(rows, expected) do
    for {key, schema, field, kind} <- StopReferences.catalog() do
      row = Repo.get!(schema, Map.fetch!(rows, key).id)
      value = Map.fetch!(row, field)

      case kind do
        :array -> assert value == [expected, "X"]
        {:prefixed, "stop:"} -> assert value == "stop:#{expected}"
        _ -> assert value == expected
      end
    end
  end
end
