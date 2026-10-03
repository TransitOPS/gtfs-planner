defmodule GtfsPlanner.Gtfs.TodsGenerator.InputReceiptTest do
  @moduledoc """
  Step 1 covers two contracts that later steps build on and cannot fix later:

    * `TodsGenerator.Input` owns the only five business inputs. It casts nothing
      else, defaults terminal relief to `false` and the dates to the first
      active calendar week of the feed, and normalizes to JSON-storable values.
    * `TodsGeneration` is the durable completed receipt. Its scoped request
      identity is decided by the database, and its rows die with the version
      they describe while organization operators do not.

  Each failure is asserted by its own field and its own literal message, so a
  single validation that swallowed the other inputs would not pass. The receipt
  cases insert through the real schema and `Repo`, because uniqueness and
  cascade behaviour are claims about the database, not about the changeset.

  The feed is a Monday-to-Friday service starting Monday 2026-03-02, so the
  defaulting facts below are read from those literal dates rather than from
  `Date.today/0`.

  Rows are created inside the SQL Sandbox transaction and rolled back.

  Run with:
  `mix test test/gtfs_planner/gtfs/tods_generator/input_receipt_test.exs`.
  """
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs.TodsGeneration
  alias GtfsPlanner.Gtfs.TodsGenerator.Input
  alias GtfsPlanner.Operations.Operator
  alias GtfsPlanner.Repo

  import GtfsPlanner.AccountsFixtures, only: [editor_fixture: 1]
  import GtfsPlanner.BlockingFixtures, only: [calendar_service_fixture: 3]
  import GtfsPlanner.OperationsFixtures, only: [garage_fixture: 1]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 0]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 1]

  @first_active_date ~D[2026-03-02]
  # The feed's first active week is Monday through Friday 2026-03-02..2026-03-06.
  @active_dates Date.range(@first_active_date, Date.add(@first_active_date, 4)) |> Enum.to_list()

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "WK",
      name: "Weekday",
      start_date: @first_active_date,
      end_date: ~D[2026-08-31]
    })

    %{
      organization: organization,
      version: version,
      actor: editor_fixture(organization),
      garage: garage_fixture(organization.id)
    }
  end

  describe "changeset/2 and normalize/1" do
    test "defaults to the feed's first active calendar week and JSON-storable values", context do
      assert {:ok, normalized} =
               %Input{}
               |> Input.changeset(%{"garage_id" => context.garage.id}, @active_dates)
               |> Input.normalize()

      assert normalized == %{
               "start_date" => "2026-03-02",
               "end_date" => "2026-03-08",
               "representative_week" => "2026-03-02",
               "garage_id" => context.garage.id,
               "terminal_relief?" => false
             }

      # The normalized map is what the receipt stores, so it has to survive JSON
      # unchanged and carry no Date structs.
      assert normalized == Jason.decode!(Jason.encode!(normalized))
    end

    test "an explicit date range is kept and terminal relief stays opt-in", context do
      assert {:ok, normalized} =
               %Input{}
               |> Input.changeset(
                 %{
                   "start_date" => "2026-04-06",
                   "end_date" => "2026-04-17",
                   "representative_week" => "2026-04-06",
                   "garage_id" => context.garage.id,
                   "terminal_relief?" => "true"
                 },
                 @active_dates
               )
               |> Input.normalize()

      assert normalized["start_date"] == "2026-04-06"
      assert normalized["end_date"] == "2026-04-17"
      assert normalized["representative_week"] == "2026-04-06"
      assert normalized["terminal_relief?"] == true
    end

    test "an inverted range names the end date and writes nothing", context do
      changeset =
        Input.changeset(
          %Input{},
          %{
            "start_date" => "2026-04-17",
            "end_date" => "2026-04-06",
            "representative_week" => "2026-04-13",
            "garage_id" => context.garage.id
          },
          @active_dates
        )

      assert changeset.valid? == false

      assert errors_on(changeset)[:end_date] == ["must be on or after the start date"]

      assert {:error, _changeset} = Input.normalize(changeset)
      assert Repo.aggregate(TodsGeneration, :count) == 0
    end

    test "a representative week that is not a Monday names the representative week", context do
      changeset =
        Input.changeset(
          %Input{},
          %{
            "start_date" => "2026-03-02",
            "end_date" => "2026-03-08",
            "representative_week" => "2026-03-03",
            "garage_id" => context.garage.id
          },
          @active_dates
        )

      assert changeset.valid? == false
      assert errors_on(changeset)[:representative_week] == ["must be a Monday"]
    end

    test "a representative week outside the range names the representative week", context do
      changeset =
        Input.changeset(
          %Input{},
          %{
            "start_date" => "2026-03-02",
            "end_date" => "2026-03-08",
            "representative_week" => "2026-03-09",
            "garage_id" => context.garage.id
          },
          @active_dates
        )

      assert changeset.valid? == false

      assert errors_on(changeset)[:representative_week] ==
               ["must fall within the selected dates"]
    end

    test "a malformed garage value names the garage and no other input fails" do
      changeset =
        Input.changeset(
          %Input{},
          %{
            "start_date" => "2026-03-02",
            "end_date" => "2026-03-08",
            "representative_week" => "2026-03-02",
            "garage_id" => "not-a-uuid"
          },
          @active_dates
        )

      assert changeset.valid? == false
      assert errors_on(changeset)[:garage_id] == ["is invalid"]
      refute Map.has_key?(errors_on(changeset), :start_date)
      refute Map.has_key?(errors_on(changeset), :end_date)
    end

    test "an input without a selected garage requires one", context do
      changeset = Input.changeset(%Input{}, %{}, @active_dates)

      assert changeset.valid? == false
      assert errors_on(changeset)[:garage_id] == ["can't be blank"]
      assert _ = context
    end

    test "fields outside the five business inputs are never cast", context do
      changeset =
        Input.changeset(
          %Input{},
          %{
            "start_date" => "2026-03-02",
            "end_date" => "2026-03-08",
            "representative_week" => "2026-03-02",
            "garage_id" => context.garage.id,
            "organization_id" => context.organization.id,
            "gtfs_version_id" => context.version.id,
            "request_id" => Ecto.UUID.generate(),
            "source_fingerprint" => "deadbeef",
            "actor_id" => context.actor.id
          },
          @active_dates
        )

      assert changeset.valid?
      assert {:ok, normalized} = Input.normalize(changeset)

      assert Map.keys(normalized) |> Enum.sort() ==
               ["end_date", "garage_id", "representative_week", "start_date", "terminal_relief?"]
    end
  end

  describe "TodsGeneration receipt persistence" do
    test "one scoped request holds one receipt, and another version may reuse the token",
         context do
      request_id = Ecto.UUID.generate()

      assert {:ok, first} = insert_receipt(context, request_id)

      assert {:error, changeset} = insert_receipt(context, request_id)
      assert errors_on(changeset)[:request_id] == ["has already been taken"]
      assert Repo.aggregate(TodsGeneration, :count) == 1

      other_version = gtfs_version_fixture(context.organization.id)

      assert {:ok, reused} =
               insert_receipt(context, request_id, %{gtfs_version_id: other_version.id})

      assert reused.id != first.id
      assert reused.request_id == request_id
      assert Repo.aggregate(TodsGeneration, :count) == 2
    end

    test "a receipt cannot name a version of another organization", context do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      assert {:error, changeset} =
               insert_receipt(context, Ecto.UUID.generate(), %{
                 gtfs_version_id: other_version.id
               })

      assert errors_on(changeset)[:gtfs_version_id] == ["does not exist"]
      assert Repo.aggregate(TodsGeneration, :count) == 0
    end

    test "a receipt stores its normalized inputs, fingerprint and created ids", context do
      operator_ids = [Ecto.UUID.generate()]

      assert {:ok, receipt} =
               insert_receipt(context, Ecto.UUID.generate(), %{
                 normalized_inputs: %{
                   "garage_id" => context.garage.id,
                   "terminal_relief?" => false
                 },
                 source_fingerprint: String.duplicate("a", 64),
                 created_ids: %{"operators" => operator_ids},
                 summary: %{"blocks" => 2}
               })

      stored = Repo.get!(TodsGeneration, receipt.id)

      assert stored.organization_id == context.organization.id
      assert stored.gtfs_version_id == context.version.id
      assert stored.actor_id == context.actor.id

      assert stored.normalized_inputs == %{
               "garage_id" => context.garage.id,
               "terminal_relief?" => false
             }

      assert stored.source_fingerprint == String.duplicate("a", 64)
      assert stored.created_ids == %{"operators" => operator_ids}
      assert stored.summary == %{"blocks" => 2}
      assert %DateTime{} = stored.inserted_at
      assert %DateTime{} = stored.updated_at
    end

    test "deleting an isolated version removes its receipt but not its organization operator",
         context do
      # The shared setup version carries a calendar, and calendars deliberately
      # refuse version deletion. An isolated version is the only one a receipt
      # can be shown to die with.
      isolated_version = gtfs_version_fixture(context.organization.id)

      operator =
        %Operator{}
        |> Operator.changeset(%{
          employee_id: "DEMO-#{isolated_version.id}-001",
          display_name: "Demo operator 001"
        })
        |> Ecto.Changeset.put_change(:organization_id, context.organization.id)
        |> Repo.insert!()

      {:ok, receipt} =
        insert_receipt(context, Ecto.UUID.generate(), %{gtfs_version_id: isolated_version.id})

      Repo.delete!(isolated_version)

      refute Repo.get(TodsGeneration, receipt.id)
      assert Repo.get(Operator, operator.id)
    end
  end

  defp insert_receipt(context, request_id, overrides \\ %{}) do
    %TodsGeneration{}
    |> TodsGeneration.completion_changeset(
      Map.merge(
        %{
          organization_id: context.organization.id,
          gtfs_version_id: context.version.id,
          actor_id: context.actor.id,
          request_id: request_id,
          normalized_inputs: %{"garage_id" => context.garage.id},
          source_fingerprint: "fingerprint",
          created_ids: %{},
          summary: %{}
        },
        overrides
      )
    )
    |> Repo.insert()
  end
end
