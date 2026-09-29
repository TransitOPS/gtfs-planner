defmodule GtfsPlanner.Gtfs.DeadheadTime do
  @moduledoc """
  An entered driving time in minutes between two references in one GTFS version.

  Rows are keyed by `(organization_id, gtfs_version_id, from_ref, to_ref)`. The
  references hold garage UUIDs or stop IDs and are set on the struct by the
  caller together with `organization_id` and `gtfs_version_id`; they are never
  cast from submitted parameters.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "deadhead_times" do
    field :from_ref, :string
    field :to_ref, :string
    field :minutes, :integer

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          from_ref: String.t(),
          to_ref: String.t(),
          minutes: integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  Changeset for an entered driving time.

  Casts only the user field `minutes`; the scoping fields are assigned by the
  caller. `minutes` is range-checked here and again by the named database
  constraint, so 0–600 is a changeset error rather than a raised violation, and
  `0` is a real value rather than a missing one.

  One row exists per organization, version and ordered reference pair.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(time, attrs) do
    time
    |> cast(attrs, [:minutes], empty_values: [])
    |> validate_required([:minutes])
    |> validate_number(:minutes,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 600,
      message: "must be a whole number between 0 and 600"
    )
    |> check_constraint(:minutes,
      name: :minutes_range,
      message: "must be a whole number between 0 and 600"
    )
    |> unique_constraint([:organization_id, :gtfs_version_id, :from_ref, :to_ref],
      name: "deadhead_times_organization_id_gtfs_version_id_from_ref_to_ref_"
    )
  end
end
