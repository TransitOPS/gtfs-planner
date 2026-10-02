defmodule GtfsPlanner.Gtfs.Export.FaresValidatorTest do
  @moduledoc """
  Judges the managed fare exports against the tracked MobilityData validator
  (AC-30, FH-43). The clean cases cover a managed version edited through the
  Fares facade, first-use setup, and conversion of imported v1 and v2 feeds.
  A separate invalid cross-group transfer count is inserted into an exported
  converted feed as a negative control, so the clean assertions establish that
  the validator read the fare files rather than silently skipping them.

  The CLI runs with `--skip_validator_update`, uses the tracked 8.0.1 jar and
  makes no network calls. ZIPs and reports live under a per-test temporary
  directory that is removed at test teardown.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures, only: [editor_fixture: 2]
  import GtfsPlanner.FaresFixtures, only: [import!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.FareTransferRule
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.GtfsValidatorCli
  alias GtfsPlanner.Repo

  @moduletag :validator_cli
  @moduletag timeout: 600_000

  @validator_version "8.0.1"
  @fare_files ~w(
    fare_attributes.txt fare_rules.txt fare_products.txt fare_media.txt
    fare_leg_rules.txt fare_leg_join_rules.txt fare_transfer_rules.txt
    fare_timeframes.txt timeframes.txt rider_categories.txt areas.txt
    stop_areas.txt networks.txt route_networks.txt
  )

  test "managed, setup and converted fare exports have no fare ERROR notices" do
    {organization, scope_for} = editor_context!()
    tmp_dir = tmp_dir!()

    managed = new_version!(organization, scope_for, "managed", "no_fare")
    assert {:ok, _setup} = Conversion.setup(managed.scope, flat_answers())

    assert {:ok, _saved} =
             Fares.save_fare(managed.scope, %{
               fare_product_id: "local_ride",
               name: "Local ride",
               kind: "single",
               media_ids: ["cash"],
               prices: %{"adult" => "1.75", "reduced" => "0.75", "child" => "0.00"}
             })

    setup = new_version!(organization, scope_for, "setup", "no_fare")
    assert {:ok, _setup} = Conversion.setup(setup.scope, flat_answers())

    converted_v1 = converted_version!(organization, scope_for, "converted-v1", "north_coast_v1")
    converted_v2 = converted_version!(organization, scope_for, "converted-v2", "north_coast_v2")

    assert_clean_export!(tmp_dir, organization, managed.version, "managed")
    assert_clean_export!(tmp_dir, organization, setup.version, "setup")
    assert_clean_export!(tmp_dir, organization, converted_v1.version, "converted-v1")
    assert_clean_export!(tmp_dir, organization, converted_v2.version, "converted-v2")
  end

  test "the validator reports a cross-group transfer_count in fare_transfer_rules.txt" do
    organization = organization_fixture(%{alias: unique_alias("fares-negative")})

    actor =
      editor_fixture(organization, %{email: "#{unique_alias("fares-negative")}@example.com"})

    version = gtfs_version_fixture(organization.id, %{name: "Invalid cross-group transfer"})
    import!(organization, version, "north_coast_v2")

    scope = scope(organization, version, actor)
    {:ok, plan} = Conversion.preview(organization.id, version.id)
    assert {:ok, _converted} = Conversion.apply(scope, plan.fingerprint, [])

    # Transfer count is legal only when both leg-group ids name the same group.
    %FareTransferRule{}
    |> FareTransferRule.changeset(%{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      from_leg_group_id: "N_LOCAL",
      to_leg_group_id: "N_INTERCITY",
      transfer_count: 2,
      duration_limit: 5400,
      duration_limit_type: 1,
      fare_transfer_type: 0
    })
    |> Repo.insert!()

    tmp_dir = tmp_dir!()
    zip = export_zip!(tmp_dir, organization.id, version.id, "cross-group-transfer-count")

    {header, rows} = zip_csv!(zip, "fare_transfer_rules.txt")
    assert String.starts_with?(header, "from_leg_group_id,to_leg_group_id,transfer_count")
    assert Enum.any?(rows, &String.starts_with?(&1, "N_LOCAL,N_INTERCITY,2,"))

    report = validate!(tmp_dir, "cross-group-transfer-count", zip)

    fare_errors = fare_error_notices(report)

    assert Enum.any?(fare_errors, &transfer_count_error?/1),
           "MobilityData validator #{report_version(report)} did not report the exported " <>
             "cross-group transfer_count: #{inspect(Enum.map(fare_errors, & &1["code"]))}"

    print_observation("cross-group-transfer-count", report, fare_errors)
  end

  defp editor_context! do
    organization = organization_fixture(%{alias: unique_alias("fares-validator")})

    actor =
      editor_fixture(organization, %{email: "#{unique_alias("fares-validator")}@example.com"})

    {organization, &scope(organization, &1, actor)}
  end

  defp new_version!(organization, scope_for, name, fixture) do
    version = gtfs_version_fixture(organization.id, %{name: name})
    import!(organization, version, fixture)
    %{version: version, scope: scope_for.(version)}
  end

  defp converted_version!(organization, scope_for, name, fixture) do
    result = new_version!(organization, scope_for, name, fixture)
    {:ok, plan} = Conversion.preview(organization.id, result.version.id)
    assert {:ok, _converted} = Conversion.apply(result.scope, plan.fingerprint, [])
    result
  end

  defp scope(organization, version, actor) do
    %{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end

  defp flat_answers do
    %{
      kind: :flat,
      adult: Decimal.new("1.50"),
      reduced: true,
      youth: false,
      child: true,
      transfer_minutes: 90
    }
  end

  defp export_zip!(tmp_dir, organization_id, version_id, label) do
    assert {:ok, zip_binary, _warnings} = Export.build_zip(organization_id, version_id, :full, [])
    path = Path.join(tmp_dir, "#{label}.zip")
    File.write!(path, zip_binary)
    path
  end

  defp validate!(tmp_dir, label, zip) do
    report = GtfsValidatorCli.run!(Path.join(tmp_dir, "#{label}-report"), zip)

    assert report_version(report) == @validator_version,
           "expected MobilityData validator #{@validator_version}, got #{report_version(report)}"

    report
  end

  defp assert_clean_export!(tmp_dir, organization, version, label) do
    zip = export_zip!(tmp_dir, organization.id, version.id, label)
    report = validate!(tmp_dir, label, zip)
    fare_errors = fare_error_notices(report)

    print_observation(label, report, fare_errors)

    assert fare_errors == [],
           "MobilityData validator #{report_version(report)} reported fare-related ERROR " <>
             "notices for #{label}: #{inspect(Enum.map(fare_errors, & &1["code"]))}"
  end

  defp report_version(report), do: get_in(report, ["summary", "validatorVersion"])

  defp fare_error_notices(report) do
    report
    |> GtfsValidatorCli.notices()
    |> Enum.filter(fn notice ->
      GtfsValidatorCli.severity(notice) == "ERROR" and
        (String.match?(
           notice["code"] || "",
           ~r/(fare|area|network|timeframe|rider|media|product)/i
         ) or
           Enum.any?(@fare_files, &notice_names_file?(notice, &1)))
    end)
  end

  defp notice_names_file?(notice, filename) do
    notice
    |> Map.get("sampleNotices", [])
    |> Enum.any?(fn sample ->
      Enum.any?(["filename", "childFilename", "parentFilename"], &(sample[&1] == filename))
    end)
  end

  defp transfer_count_error?(notice) do
    code = notice["code"] || ""

    notice_names_file?(notice, "fare_transfer_rules.txt") or
      String.match?(code, ~r/(transfer.*count|count.*transfer)/i)
  end

  defp print_observation(label, report, notices) do
    codes = Enum.map(notices, & &1["code"]) |> Enum.sort()

    IO.puts(
      "EV-43 #{label} validator=#{report_version(report)} fare ERROR codes=#{inspect(codes)}"
    )
  end

  defp zip_csv!(path, filename) do
    {:ok, entries} = :zip.unzip(String.to_charlist(path), [:memory])

    case Enum.find(entries, fn {name, _content} -> List.to_string(name) == filename end) do
      {_name, content} ->
        [header | rows] = String.split(content, "\n", trim: true)
        {header, rows}

      nil ->
        flunk("export has no #{filename}: #{inspect(Enum.map(entries, &elem(&1, 0)))}")
    end
  end

  defp tmp_dir! do
    path = Path.join(System.tmp_dir!(), "fares_validator_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp unique_alias(prefix), do: "#{prefix}-s29-#{System.unique_integer([:positive, :monotonic])}"
end
