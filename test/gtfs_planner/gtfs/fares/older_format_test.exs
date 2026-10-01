defmodule GtfsPlanner.Gtfs.Fares.OlderFormatTest do
  @moduledoc """
  Merge evidence (EV-24) for `Fares.set_older_format/2` and the inverse
  `Fares.undo/3` applies (AC-25, AC-26, R14, R15, FH-24).

  Every expected value is worked by hand from R14 and from the prototype's North
  Coast sample, never read back from the code under test (CR-2):

  - `older_format` is `"derived"` on the settings row every managed version
    starts with, whatever created it — a first-use setup or a conversion;
  - `:imported` writes `"imported"`, and `:derived` writes `"derived"` back, so
    the choice is reversible without any other row changing;
  - `:imported` is refused with `{:error, :no_stored_older_format}` on a version
    that holds no `fare_attributes` rows, which is every version the first-use
    setup made managed: it created v2 rows from the operator's answers and never
    imported a v1 file;
  - each choice records one `fare_version` change-log entry whose summary is
    `"Kept the older format as imported"` or
    `"Exported the older format from the stored fares"`.

  The two versions enter rows through the production importer and the production
  `Fares.Conversion` writers, and every write runs inside
  `GtfsPlanner.Gtfs.Fares.VersionLock.transact/3` with `Fares.Normalize.run!/2`
  before the commit, which is the path every writer of this package takes
  (INV-1). Every read here filters by `organization_id` and `gtfs_version_id`
  together (INV-5).

  The export effect of the choice — which rows `fare_attributes.txt` and
  `fare_rules.txt` carry — belongs to step 28's evidence and is not asserted
  here.
  """
  use GtfsPlanner.DataCase, async: true

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures, only: [user_fixture: 1]
  import GtfsPlanner.FaresFixtures, only: [import!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.FareAttribute
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Gtfs.FareVersionSetting
  alias GtfsPlanner.Repo

  setup do
    organization =
      organization_fixture(%{alias: "fares-older-format-#{System.unique_integer([:positive])}"})

    # An explicit email rather than `user_fixture/0`: the smokes on this shared
    # partition commit a `user-1@example.com`, and `System.unique_integer/1`
    # restarts per BEAM, so the default email collides on the second run.
    actor =
      user_fixture(%{
        email: "fares-older-format-#{System.unique_integer([:positive])}@example.com"
      })

    context = %{organization: organization, actor: actor}

    Map.merge(context, converted_v1(context))
  end

  describe "a version converted from an imported older-format feed" do
    test "stores the imported source and restores the derived one", context do
      v1 = context.v1

      # The conversion created the v2 rows beside the v1 rows its import stored,
      # so the version is managed and still holds both sets (R13).
      assert Fares.managed?(v1.organization.id, v1.version.id)
      assert setting(v1).older_format == "derived"

      assert {:ok, imported} = Fares.set_older_format(v1.scope, :imported)
      assert is_binary(imported.operation_id)
      assert setting(v1).older_format == "imported"

      # R13's stored rows are untouched by the choice: five `fare_attributes`
      # rows from the fixture's own file, and the eleven `fare_rules` rows.
      assert stored_attribute_ids(v1) == [
               "COAST",
               "INTERCITY",
               "LOCAL",
               "VALCOAST",
               "VALLEY"
             ]

      assert stored_rule_count(v1) == 11

      assert {:ok, _derived} = Fares.set_older_format(v1.scope, :derived)
      assert setting(v1).older_format == "derived"

      # Restoring the derived source changes no fare row either.
      assert stored_attribute_ids(v1) == [
               "COAST",
               "INTERCITY",
               "LOCAL",
               "VALCOAST",
               "VALLEY"
             ]

      assert stored_rule_count(v1) == 11
    end

    test "records one change-log entry per choice", context do
      v1 = context.v1

      assert {:ok, imported} = Fares.set_older_format(v1.scope, :imported)
      assert [entry] = entries(v1, imported.operation_id)
      assert entry.action == "updated"
      assert entry.changed_fields["summary"] == "Kept the older format as imported"

      assert entry.changed_fields["before"] == [
               %{"fare_version_settings_id" => entry.entity_id, "older_format" => "derived"}
             ]

      assert entry.changed_fields["after"] == [
               %{"fare_version_settings_id" => entry.entity_id, "older_format" => "imported"}
             ]

      assert {:ok, derived} = Fares.set_older_format(v1.scope, :derived)
      assert [entry] = entries(v1, derived.operation_id)
      assert entry.changed_fields["summary"] == "Exported the older format from the stored fares"
    end

    test "undoing a choice restores the source it replaced", context do
      v1 = context.v1

      assert {:ok, %{operation_id: operation_id, inverse: inverse}} =
               Fares.set_older_format(v1.scope, :imported)

      assert {:ok, undone} = Fares.undo(v1.scope, operation_id, inverse)
      assert undone.operation_id == operation_id
      assert setting(v1).older_format == "derived"

      assert [entry] = entries(v1, operation_id)
      assert entry.action == "updated"
    end
  end

  describe "a version made managed by the first-use setup" do
    setup context do
      organization =
        organization_fixture(%{alias: "fares-older-format-setup-#{unique_alias(context)}"})

      version =
        gtfs_version_fixture(organization.id, %{name: "North Coast first-use setup"})

      import!(organization, version, "no_fare")

      scope = scope(organization, version, context.actor)
      assert {:ok, _setup} = Conversion.setup(scope, flat_answers())

      Map.put(context, :setup, %{
        organization: organization,
        version: version,
        scope: scope
      })
    end

    test "refuses the imported source, since no v1 file was ever imported", context do
      setup_version = context.setup

      assert Fares.managed?(setup_version.organization.id, setup_version.version.id)
      assert stored_attribute_count(setup_version) == 0

      assert {:error, :no_stored_older_format} =
               Fares.set_older_format(setup_version.scope, :imported)

      # A refusal writes nothing: the source is still the default and the version
      # has recorded no entry for this operation.
      assert setting(setup_version).older_format == "derived"
      assert conversion_entries(setup_version) == 1

      # The derived source is the one it already holds, so asking for it is
      # written and recorded like any other choice.
      assert {:ok, result} = Fares.set_older_format(setup_version.scope, :derived)
      assert setting(setup_version).older_format == "derived"
      assert [entry] = entries(setup_version, result.operation_id)
      assert entry.changed_fields["summary"] == "Exported the older format from the stored fares"
    end
  end

  describe "a version that is not managed" do
    test "refuses with :unmanaged and writes nothing", context do
      version =
        gtfs_version_fixture(context.organization.id, %{name: "Imported, never converted"})

      import!(context.organization, version, "north_coast_v1")
      scope = scope(context.organization, version, context.actor)

      assert {:error, :unmanaged} = Fares.set_older_format(scope, :imported)
      assert is_nil(Fares.settings(context.organization.id, version.id))
    end
  end

  # A version imported from the sample v1 feed and converted through the
  # production `Conversion.preview/2` and `Conversion.apply/3`, so the managed
  # version under test holds both the stored v1 rows and the derived v2 rows.
  defp converted_v1(context) do
    organization =
      organization_fixture(%{alias: "fares-older-format-v1-#{unique_alias(context)}"})

    version = gtfs_version_fixture(organization.id, %{name: "North Coast older format"})
    import!(organization, version, "north_coast_v1")

    scope = scope(organization, version, context.actor)
    {:ok, plan} = Conversion.preview(organization.id, version.id)
    {:ok, _converted} = Conversion.apply(scope, plan.fingerprint, [])

    %{v1: %{organization: organization, version: version, scope: scope}}
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

  # Two organizations in one setup block, so their aliases cannot collide.
  defp unique_alias(context),
    do: "#{context.organization.id}-#{System.unique_integer([:positive])}"

  defp setting(context) do
    context
    |> scoped(FareVersionSetting)
    |> Repo.one()
  end

  defp stored_attribute_ids(context) do
    context
    |> scoped(FareAttribute)
    |> select([row], row.fare_id)
    |> Repo.all()
    |> Enum.sort()
  end

  defp stored_attribute_count(context), do: stored_attribute_ids(context) |> length()

  # The fixture's eleven `fare_rules.txt` rows, one of them naming a route.
  defp stored_rule_count(context) do
    from(row in FareRule,
      where:
        row.organization_id == ^context.organization.id and
          row.gtfs_version_id == ^context.version.id
    )
    |> Repo.aggregate(:count)
  end

  defp entries(context, operation_id) do
    context
    |> scoped(ChangeLog)
    |> where([entry], entry.entity_type == "fare_version")
    |> where([entry], fragment("?->>?", entry.changed_fields, "operation_id") == ^operation_id)
    |> Repo.all()
  end

  defp conversion_entries(context) do
    context
    |> scoped(ChangeLog)
    |> where([entry], entry.entity_type == "fare_version")
    |> Repo.aggregate(:count)
  end

  defp scoped(queryable, context) do
    where(
      queryable,
      [row],
      row.organization_id == ^context.organization.id and
        row.gtfs_version_id == ^context.version.id
    )
  end

  # The first-use setup's own answers, worked out by hand in `setup_test.exs`:
  # one flat structure, an adult fare of $1.50, a half-price reduced rider, a
  # free child and a 90-minute transfer. No v1 file is imported, so the version
  # this creates holds no `fare_attributes` rows at all.
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
end
