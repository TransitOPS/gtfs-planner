defmodule GtfsPlanner.Gtfs.StopSelectionTest do
  @moduledoc """
  Merge evidence (EV-12) for `Gtfs.StopSelection.resolve/3`.

  The resolver must never guess, so each case writes the expected match, candidate
  or unresolved line by hand from the fixture: directional twins `S410`/`S411`, a
  stop `A` whose `stop_id` is another stop `B`'s `stop_code`, two stops sharing a code
  and two sharing a name. Stops of another version and organization carry the same
  IDs and must never appear.
  """

  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopSelection

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    # The insert fixture does not cast `stop_code`; codes are written after it.
    stop = fn id, name, code ->
      stop = stop_fixture(organization.id, version.id, %{stop_id: id, stop_name: name})

      if code,
        do: Repo.update_all(from(s in Stop, where: s.id == ^stop.id), set: [stop_code: code])

      Repo.reload!(stop)
    end

    stops = %{
      eb: stop.("S410", "Main St @ St Paul EB", "410E"),
      wb: stop.("S411", "Main St @ St Paul WB", "410W"),
      # `410` is this stop's ID and the next stop's code: the ID tier wins.
      a: stop.("410", "Elm St", nil),
      b: stop.("B-1", "Cedar St", "410"),
      c1: stop.("C-1", "Oak Plaza", "SHARED"),
      c2: stop.("C-2", "Oak Plaza East", "SHARED"),
      n1: stop.("N-1", "Pine & 3rd", nil),
      n2: stop.("N-2", " Pine & 3rd ", nil)
    }

    other_version = gtfs_version_fixture(organization.id)
    foreign_organization = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_organization.id)
    stop_fixture(organization.id, other_version.id, %{stop_id: "S410", stop_name: "Elsewhere"})

    stop_fixture(foreign_organization.id, foreign_version.id, %{
      stop_id: "S999",
      stop_name: "Main St @ St Paul EB"
    })

    %{organization: organization, version: version, stops: stops}
  end

  test "stop IDs resolve to separate matches; the twins' names never merge them", context do
    %{eb: eb, wb: wb} = context.stops

    assert {:ok, %{resolved: [first, second], ambiguous: [], unresolved: []}} =
             resolve(context, ["S411", " S410 "])

    assert first.refs == ["S411"]
    assert {first.basis, first.stop.uuid, first.stop.stop_name} == {:stop_id, wb.id, wb.stop_name}
    assert second.refs == ["S410"]
    assert {second.basis, second.stop.uuid} == {:stop_id, eb.id}

    assert second.stop == %{
             uuid: eb.id,
             stop_id: "S410",
             stop_name: "Main St @ St Paul EB",
             stop_code: "410E",
             location_type: 0,
             parent_station: nil
           }
  end

  test "the ID tier outranks the code tier", context do
    %{a: a} = context.stops

    assert {:ok, %{resolved: [match], ambiguous: [], unresolved: []}} = resolve(context, ["410"])
    assert {match.basis, match.stop.uuid} == {:stop_id, a.id}
  end

  test "a code or a name carried by two stops is ambiguous with sorted candidates", context do
    %{c1: c1, c2: c2, n1: n1, n2: n2} = context.stops

    assert {:ok, %{resolved: [], unresolved: [], ambiguous: [code, name]}} =
             resolve(context, ["SHARED", "Pine & 3rd"])

    assert {code.ref, code.basis, code.candidate_total} == {"SHARED", :stop_code, 2}
    assert Enum.map(code.candidates, & &1.uuid) == [c1.id, c2.id]
    assert {name.ref, name.basis, name.candidate_total} == {"Pine & 3rd", :stop_name, 2}
    assert Enum.map(name.candidates, & &1.uuid) == [n1.id, n2.id]
  end

  test "names match exactly after trimming and nothing else matches", context do
    %{eb: eb} = context.stops

    assert {:ok, %{resolved: [match], unresolved: unresolved}} =
             resolve(context, [
               "  Main St @ St Paul EB  ",
               "main st @ st paul wb",
               "Main St @  St Paul WB"
             ])

    assert {match.basis, match.stop.uuid} == {:stop_name, eb.id}
    assert unresolved == ["main st @ st paul wb", "Main St @  St Paul WB"]
  end

  test "another version's or organization's stops never match, and wildcards are plain text",
       context do
    assert {:ok, %{resolved: [match], unresolved: unresolved}} =
             resolve(context, ["S410", "S999", "Elsewhere", "%", "S4_0", "O'Brien", "Main%"])

    assert match.stop.stop_name == "Main St @ St Paul EB"
    assert unresolved == ["S999", "Elsewhere", "%", "S4_0", "O'Brien", "Main%"]
  end

  test "blank lines are ignored and repeated or equivalent lines collapse into one match",
       context do
    %{eb: eb} = context.stops

    assert {:ok, %{resolved: [match], ambiguous: [], unresolved: []}} =
             resolve(context, ["", "  ", "S410", "S410", "410E", "Main St @ St Paul EB"])

    assert match.refs == ["S410", "410E", "Main St @ St Paul EB"]
    assert {match.basis, match.stop.uuid} == {:stop_id, eb.id}
  end

  test "refuses too many lines, over-long lines and non-strings", context do
    lines = for index <- 1..101, do: "LINE-#{index}"

    assert resolve(context, lines) == {:error, :too_many}
    assert {:ok, %{unresolved: unresolved}} = resolve(context, Enum.take(lines, 100))
    assert length(unresolved) == 100
    # Repeats collapse before the count, so 101 entries of 100 distinct lines are fine.
    assert {:ok, _} = resolve(context, Enum.take(lines, 100) ++ ["LINE-1"])

    assert resolve(context, [String.duplicate("x", 201)]) == {:error, :invalid_input}
    assert {:ok, _} = resolve(context, [String.duplicate("x", 200)])
    assert resolve(context, ["S410", 410]) == {:error, :invalid_input}
    assert resolve(context, "S410") == {:error, :invalid_input}
  end

  test "more than ten candidates are cut with the exact total", context do
    for index <- 1..12 do
      stop_fixture(context.organization.id, context.version.id, %{
        stop_id: "D-#{String.pad_leading("#{index}", 2, "0")}",
        stop_name: "Depot Stop"
      })
    end

    assert {:ok, %{ambiguous: [row]}} = resolve(context, ["Depot Stop"])
    assert row.candidate_total == 12
    assert length(row.candidates) == 10

    assert Enum.map(row.candidates, & &1.stop_id) ==
             for(i <- 1..10, do: "D-#{String.pad_leading("#{i}", 2, "0")}")
  end

  defp resolve(context, refs),
    do: StopSelection.resolve(context.organization.id, context.version.id, refs)
end
