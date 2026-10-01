# Step 020 — Prove the export has no dangling stop references (EV-21)
#
# Production-composition test: the real `StopEditing` commands, then the real
# export run's `Worker.build/4`, then the zip's own text files parsed here. The
# question this file answers is the one a validator answers late and a rider
# answers by getting a 404: does any exported file name a stop that
# `stops.txt` does not contain?

defmodule GtfsPlanner.Gtfs.Export.StopReferencesExportTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.Export.Worker
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.FareLegJoinRule
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopArea
  alias GtfsPlanner.Gtfs.StopEditing
  alias GtfsPlanner.Gtfs.Translation
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Repo

  @actor %{id: Ecto.UUID.generate(), email: "stop-refs-export@example.com"}

  # The exported columns that name a stop, per file. A dangling reference is
  # exactly one of these holding an ID `stops.txt` does not list, so the check
  # is a union over the files rather than a per-file assertion: a stop named in
  # three files is one problem, and missing any of the files would miss the
  # problem entirely.
  @stop_referencing_files [
    {"stop_times.txt", ["stop_id"]},
    {"transfers.txt", ["from_stop_id", "to_stop_id"]},
    {"stop_areas.txt", ["stop_id"]},
    {"fare_leg_join_rules.txt", ["from_stop_id", "to_stop_id"]},
    {"translations.txt", ["record_id"]}
  ]

  setup do
    root =
      Path.join(System.tmp_dir!(), "stop-refs-export-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    old_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      File.rm_rf(root)
      restore_env(:gtfs_task_artifacts_path, old_root)
    end)

    %{root: root}
  end

  test "a replace leaves every exported stop reference naming a stop in stops.txt", %{
    root: root
  } do
    fixture = seed_network()

    # S2 is replaced by S5, which is in the feed but in no trip, so the
    # adjacency refusals the replace exists to enforce are not what is under
    # test here — the export is.
    assert {:ok, _result} = replace(fixture, "S2", "S5", %{delete_old: true})

    files = export_files(root, fixture)

    assert_dangling(files)
    assert stop_ids(files["stops.txt"]) == ["S1", "S3", "S4", "S5", "S9"]
    refute "S2" in every_value(files), "the replaced stop's ID reached an exported file"
  end

  test "a delete leaves every exported stop reference naming a stop in stops.txt", %{
    root: root
  } do
    fixture = seed_network()

    # S9 carries only descriptive rows, which is what a delete removes; a stop
    # with a stop time or a pattern occurrence is refused instead (AC-17), and
    # the command tests cover that.
    review = StopEditing.delete_review(stop_id(fixture, "S9").id, fixture.audit)
    assert {:ok, delete_review} = review

    assert {:ok, _result} =
             StopEditing.delete_stop(
               stop_id(fixture, "S9").id,
               delete_review.fingerprint,
               fixture.audit
             )

    files = export_files(root, fixture)

    assert expected_files() -- Map.keys(files) == []
    assert_dangling(files)
    assert stop_ids(files["stops.txt"]) == ["S1", "S2", "S3", "S4", "S5"]
    refute "S9" in every_value(files), "the deleted stop's ID reached an exported file"
  end

  test "a replace and a delete together leave no dangling reference in any file", %{root: root} do
    fixture = seed_network()

    assert {:ok, _result} = replace(fixture, "S2", "S5", %{delete_old: true})

    assert {:ok, delete_review} =
             StopEditing.delete_review(stop_id(fixture, "S9").id, fixture.audit)

    assert {:ok, _result} =
             StopEditing.delete_stop(
               stop_id(fixture, "S9").id,
               delete_review.fingerprint,
               fixture.audit
             )

    files = export_files(root, fixture)

    # Every file the run produced, not only the ones with a stop column: an
    # unlisted file is where an unexpected reference would hide.
    assert files["stops.txt"] != nil
    assert_dangling(files)
    refute "S2" in every_value(files)
    refute "S9" in every_value(files)
  end

  # --- the check itself

  # Every stop reference in every stop-referencing file, resolved against
  # `stops.txt`. Returned rather than asserted so a failure names the exact
  # `{file, column, id}` that dangles.
  # Every file this file makes a claim about. The export omits a file whose
  # table has no rows, so "the file is absent" is a fact to assert rather than a
  # crash to debug: a check that quietly passed on a missing file would be
  # passing for the wrong reason.
  defp expected_files do
    Enum.map(@stop_referencing_files, &elem(&1, 0)) ++ ["stops.txt"]
  end

  defp assert_dangling(files) do
    exported = MapSet.new(stop_ids(files["stops.txt"]))

    dangling =
      for {filename, columns} <- @stop_referencing_files,
          row <- rows(files[filename]),
          column <- columns,
          stop_id = row[column],
          stop_id not in exported,
          do: {filename, column, stop_id}

    if dangling != [] do
      flunk("exported stop references that stops.txt does not name: #{inspect(dangling)}")
    end

    dangling
  end

  defp stop_ids(rows) do
    rows |> Enum.map(& &1["stop_id"]) |> Enum.reject(&(&1 in [nil, ""])) |> Enum.sort()
  end

  defp every_value(files) do
    files
    |> Map.values()
    |> Enum.flat_map(&Enum.flat_map(&1, fn row -> Map.values(row) end))
  end

  # --- the export

  # The real run, the real worker, the real zip — read as text, because the
  # question is what a downstream tool reads.
  defp export_files(root, fixture) do
    {_path, entries} = build_export(root, fixture)

    entries
    |> Enum.map(fn {name, content} -> {to_string(name), parse(content)} end)
    |> Map.new()
  end

  defp build_export(root, fixture) do
    {:ok, run} =
      ExportRuns.create_pending(
        fixture.organization.id,
        fixture.version.id,
        @actor,
        :full
      )

    {:ok, claimed, generation, token} =
      ExportRuns.claim(fixture.organization.id, run.id, :build)

    assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))
    ready = Repo.get!(Run, run.id)
    assert ready.state == :ready

    path =
      Path.join([
        root,
        "export-runs",
        ready.organization_id,
        ready.gtfs_version_id,
        ready.id,
        ready.artifact_key
      ])

    {:ok, entries} = path |> File.read!() |> :zip.unzip([:memory])

    {path, entries}
  end

  defp parse(content) do
    case content |> to_string() |> String.split("\n", trim: true) do
      [] ->
        []

      [header | lines] ->
        columns = header |> String.split(",") |> trim_columns()

        lines
        |> Enum.map(fn line ->
          columns |> Enum.zip(String.split(line, ",")) |> Map.new()
        end)
        |> Enum.reject(&blank_row?/1)
    end
  end

  defp blank_row?(row) do
    Enum.all?(Map.values(row), fn value -> value in [nil, ""] end)
  end

  # The exporter writes a trailing carriage return on some profiles; a column
  # name with one attached matches nothing and a value compared against it
  # never resolves, which would read as a dangling reference rather than a
  # parsing slip.
  defp trim_columns(columns) do
    Enum.map(columns, &(&1 |> String.trim() |> String.trim("\r")))
  end

  defp rows(nil), do: []

  defp rows(rows) when is_list(rows), do: rows

  # --- the commands under test

  defp replace(fixture, old_id, new_id, options) do
    {:ok, review} =
      StopEditing.replace_review(
        stop_id(fixture, old_id).id,
        stop_id(fixture, new_id).id,
        fixture.audit
      )

    StopEditing.replace_stop(
      stop_id(fixture, old_id).id,
      stop_id(fixture, new_id).id,
      Map.put(options, :fingerprint, review.fingerprint),
      fixture.audit
    )
  end

  defp stop_id(fixture, id) do
    Repo.get_by!(Stop, stop_id: id, gtfs_version_id: fixture.version.id)
  end

  # --- the network the commands run against

  # Five stops, one route, one trip, and the descriptive rows the export
  # carries: a transfer, a stop area, a fare leg join and a translation. S9 is
  # the one nothing serves, so it is the stop a delete can remove.
  defp seed_network do
    organization =
      organization_fixture(%{alias: "stop-refs-#{System.unique_integer([:positive])}"})

    version = gtfs_version_fixture(organization.id)
    actor = editor(organization.id)

    for id <- ~w(S1 S2 S3 S4 S5 S9) do
      stop_fixture(organization.id, version.id, stop_id: id, stop_name: "Stop #{id}")
    end

    calendar_fixture(organization.id, version.id, %{service_id: "WEEKDAYS"})
    route_fixture(organization.id, version.id, route_id: "R1")
    trip_fixture(organization.id, version.id, "R1", %{trip_id: "T1", service_id: "WEEKDAYS"})

    for {stop_id, sequence} <- [{"S1", 1}, {"S2", 2}, {"S3", 3}, {"S4", 4}] do
      stop_time_fixture(organization.id, version.id, "T1", stop_id, %{
        stop_sequence: sequence,
        arrival_time: "08:0#{sequence}:00",
        departure_time: "08:0#{sequence}:00"
      })
    end

    transfer_fixture(organization.id, version.id, %{
      from_stop_id: "S2",
      to_stop_id: "S3",
      min_transfer_time: 240
    })

    Repo.insert!(%StopArea{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      area_id: "AREA-1",
      stop_id: "S3"
    })

    Repo.insert!(%FareLegJoinRule{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      from_network_id: "NET-1",
      to_network_id: "NET-2",
      from_stop_id: "S3",
      to_stop_id: "S1"
    })

    for id <- ["S2", "S9"] do
      Repo.insert!(%Translation{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        table_name: "stops",
        field_name: "stop_name",
        language: "es",
        translation: "Parada #{id}",
        record_id: id
      })
    end

    %{
      organization: organization,
      version: version,
      actor: actor,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end

  defp editor(organization_id) do
    actor = user_fixture(%{email: "stop-refs-#{System.unique_integer([:positive])}@example.com"})

    {:ok, _membership} =
      Organizations.add_user_to_organization(actor.id, organization_id, [
        "pathways_studio_editor"
      ])

    actor
  end

  defp restore_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_env(key, value), do: Application.put_env(:gtfs_planner, key, value)
end
