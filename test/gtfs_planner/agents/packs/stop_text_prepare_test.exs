defmodule GtfsPlanner.Agents.Packs.StopTextPrepareTest do
  @moduledoc """
  Merge evidence (EV-17) for `prepare_stop_metadata_changes`.

  The approved set is the directional twins `S410` and `S411` plus `S412`, with a
  fourth stop `S900` that exists in the version but is not in the set. Expected
  commands are written by hand: changed fields only, keyed by the stops' own UUIDs,
  sorted by UUID, and carrying no basis, count or digest. The pack prepares through
  `StopEditing.review_metadata_batch/2`, so validation is the native editor's.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.StopHelperFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.StopText
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Stop

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    user = user_fixture()
    organization_membership_fixture(user, organization)

    stop = fn id, name ->
      stop = stop_fixture(organization.id, version.id, %{stop_id: id, stop_name: name})

      Repo.update_all(from(s in Stop, where: s.id == ^stop.id),
        set: [stop_code: String.trim_leading(id, "S"), stop_url: "https://example.org/#{id}"]
      )

      Repo.reload!(stop)
    end

    stops = %{
      "S410" => stop.("S410", "Main Street at Saint Paul EB"),
      "S411" => stop.("S411", "Main Street at Saint Paul WB"),
      "S412" => stop.("S412", "Oak Avenue"),
      "S900" => stop.("S900", "Outside the list")
    }

    scope =
      helper_scope(
        "stop_text",
        organization,
        version,
        user,
        {"stop_set",
         %{
           "schema_version" => 1,
           "stop_uuids" => Enum.map(~w(S410 S411 S412), &stops[&1].id)
         }}
      )

    %{organization: organization, version: version, stops: stops, scope: scope}
  end

  test "prepares changed names for the twins by their own UUIDs and leaves S412 alone",
       context do
    %{"S410" => eb, "S411" => wb} = context.stops
    before = stamps(context)

    assert {:prepared, prepared, result, evidence} =
             prepare(context.scope, %{
               "rows" => [
                 %{"stop_id" => "S411", "stop_name" => "Main St & St Paul (westbound)"},
                 %{"stop_id" => "S410", "stop_name" => "Main St & St Paul (eastbound)"},
                 %{"stop_id" => "S412", "stop_name" => " Oak Avenue "}
               ],
               "basis" => "Main St & Cross St (direction)"
             })

    assert {:stop_metadata, %{rows: rows}} = prepared.command

    assert rows ==
             Enum.sort_by(
               [
                 %{stop_uuid: eb.id, changes: %{"stop_name" => "Main St & St Paul (eastbound)"}},
                 %{stop_uuid: wb.id, changes: %{"stop_name" => "Main St & St Paul (westbound)"}}
               ],
               & &1.stop_uuid
             )

    # The command is exactly the rows: no basis, count or digest.
    assert Map.keys(elem(prepared.command, 1)) == [:rows]

    assert prepared.summary == %{
             title: "Change 2 stops",
             detail: "Main St & Cross St (direction)",
             lines: [
               "2 names change",
               "1 stop already matches",
               "Nothing is saved; coordinates, IDs and accessibility are not changed"
             ]
           }

    assert {result["changed"], result["unchanged"], result["field_counts"]["stop_name"]} ==
             {2, 1, 2}

    assert Enum.sort_by(result["rows"], & &1["stop_id"]) == [
             %{"stop_id" => "S410", "changed_fields" => ["stop_name"]},
             %{"stop_id" => "S411", "changed_fields" => ["stop_name"]}
           ]

    assert evidence.kind == "stop_metadata_batch"
    assert {evidence.total, evidence.total_label} == {2, "stops will change"}
    assert evidence.exclusions == ["S412 already matches"]

    assert Enum.sort_by(evidence.resources, & &1.id) == [
             %{kind: "stop", id: "S410", label: "Main St & St Paul (eastbound)"},
             %{kind: "stop", id: "S411", label: "Main St & St Paul (westbound)"}
           ]

    assert evidence.scope.identity == "version:#{context.version.id}"
    assert stamps(context) == before
  end

  test "refuses a stop outside the approved list, repeated stops and empty rows", context do
    for {rows, expected} <- [
          {[%{"stop_id" => "S900", "stop_name" => "X"}], "S900"},
          {[%{"stop_id" => "NOPE", "stop_name" => "X"}], "NOPE"},
          {[
             %{"stop_id" => "S410", "stop_name" => "X"},
             %{"stop_id" => "S410", "stop_code" => "1"}
           ], "repeated: S410"},
          {[%{"stop_id" => "S410"}], "S410"}
        ] do
      before = stamps(context)
      assert {:tool_error, message} = prepare(context.scope, %{"rows" => rows})
      assert message =~ expected, message
      assert stamps(context) == before
    end

    # A whitespace-only value reaches the pack (the schema only bounds length) and is refused.
    assert {:tool_error, message} =
             prepare(context.scope, %{"rows" => [%{"stop_id" => "S410", "stop_name" => "   "}]})

    assert message =~ "S410"
  end

  test "native validation refuses an unusable URL naming the stop and field", context do
    assert {:tool_error, message} =
             prepare(context.scope, %{
               "rows" => [
                 %{"stop_id" => "S410", "stop_name" => "Fine"},
                 %{"stop_id" => "S411", "stop_url" => "javascript:alert(1)"}
               ]
             })

    assert message =~ "S411 stop_url:"
    assert message =~ "Nothing was prepared"
  end

  test "the declared schema rejects other fields, 101 rows and oversize arguments", context do
    for field <- ~w(wheelchair_boarding stop_lat stop_lon stop_id_new location_type) do
      assert {:tool_error, message} =
               dispatch(context.scope, %{"rows" => [%{"stop_id" => "S410", field => "1"}]})

      assert message =~ field, field
    end

    rows = for n <- 1..101, do: %{"stop_id" => "S#{n}", "stop_name" => "X"}
    assert {:tool_error, message} = dispatch(context.scope, %{"rows" => rows})
    assert message =~ "rows"

    assert {:tool_error, _} = dispatch(context.scope, %{"rows" => []})

    huge = String.duplicate("a", 40_000)

    assert {:tool_error, "Arguments are too large."} =
             dispatch(context.scope, %{"rows" => [], "basis" => huge})

    assert {:tool_error, message} =
             dispatch(context.scope, %{
               "rows" => [%{"stop_id" => "S410", "stop_name" => "X"}],
               "extra" => 1
             })

    assert message =~ "extra"
  end

  test "values that already match are refused; a duplicate name warns and still prepares",
       context do
    assert {:tool_error, message} =
             prepare(context.scope, %{
               "rows" => [%{"stop_id" => "S410", "stop_name" => "Main Street at Saint Paul EB"}]
             })

    assert message =~ "already matches"

    # `S900` is outside the list but is another stop in the version: the name collides.
    assert {:prepared, prepared, result, evidence} =
             prepare(context.scope, %{
               "rows" => [%{"stop_id" => "S410", "stop_name" => "outside the list"}]
             })

    assert List.last(Enum.drop(prepared.summary.lines, -1)) == "1 warning: duplicate names"

    assert result["warnings"] == [
             %{"kind" => "duplicate_name", "name" => "outside the list", "others" => ["S900"]}
           ]

    assert evidence.exclusions == ["outside the list: also used by S900"]

    assert {:stop_metadata, %{rows: [%{changes: %{"stop_name" => "outside the list"}}]}} =
             prepared.command
  end

  test "the review reads current values, not the model's earlier read", context do
    %{"S410" => eb} = context.stops

    # Another editor renamed the stop after the model read the set; the same proposal is
    # now a no-op against the stored value.
    Repo.update_all(from(s in Stop, where: s.id == ^eb.id), set: [stop_name: "Renamed elsewhere"])

    assert {:tool_error, message} =
             prepare(context.scope, %{
               "rows" => [%{"stop_id" => "S410", "stop_name" => "Renamed elsewhere"}]
             })

    assert message =~ "already matches"

    assert {:prepared, %{command: {:stop_metadata, %{rows: [row]}}}, _result, _evidence} =
             prepare(context.scope, %{
               "rows" => [%{"stop_id" => "S410", "stop_name" => "Main Street at Saint Paul EB"}]
             })

    assert row.changes == %{"stop_name" => "Main Street at Saint Paul EB"}
  end

  # -- helpers ----------------------------------------------------------------

  defp prepare(scope, args), do: dispatch(scope, args)

  defp dispatch(scope, args),
    do: Dispatch.call(StopText, scope, "prepare_stop_metadata_changes", Jason.encode!(args))

  defp stamps(context) do
    {Repo.all(
       from(s in Stop,
         order_by: s.id,
         select: {s.id, s.updated_at, s.stop_name, s.stop_code, s.stop_desc, s.stop_url}
       )
     ),
     Repo.aggregate(
       from(l in ChangeLog, where: l.organization_id == ^context.organization.id),
       :count
     )}
  end
end
