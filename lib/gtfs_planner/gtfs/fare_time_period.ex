defmodule GtfsPlanner.Gtfs.FareTimePeriod do
  @moduledoc """
  A fare-only time period: the named weekday mask an editor maintains beside the
  `timeframes` rows of one `timeframe_group_id`.

  GTFS has no fare time-period file, so the operator facts — the name, the
  weekday bitmask (Monday `1` through Sunday `64`) and the fare-only
  `service_id` the period's calendar row is written under — live here while the
  ranges themselves stay in `timeframes`. `until_end_of_day` records that the
  last range ends with `"24:00:00"`.

  `changeset/2` casts these five fields only. `organization_id` and
  `gtfs_version_id` are set on the struct by the writer and are never cast
  (AGENTS.md).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @min_weekdays 1
  @max_weekdays 127

  schema "fare_time_periods" do
    field :timeframe_group_id, :string
    field :name, :string
    field :weekdays, :integer
    field :until_end_of_day, :boolean, default: false
    field :service_id, :string

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          organization_id: Ecto.UUID.t() | nil,
          gtfs_version_id: Ecto.UUID.t() | nil,
          timeframe_group_id: String.t() | nil,
          name: String.t() | nil,
          weekdays: integer | nil,
          until_end_of_day: boolean | nil,
          service_id: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  A changeset for one fare time period.

  A blank `weekdays` is valid and means the period's ranges apply every day, so
  the range is only checked when a mask is given; a mask of `0` names no day and
  is refused, as the database check refuses it.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(time_period, attrs) do
    time_period
    |> cast(attrs, [
      :timeframe_group_id,
      :name,
      :weekdays,
      :until_end_of_day,
      :service_id
    ])
    |> validate_length(:name, max: 60)
    |> validate_number(:weekdays,
      greater_than_or_equal_to: @min_weekdays,
      less_than_or_equal_to: @max_weekdays
    )
    |> unique_constraint([:organization_id, :gtfs_version_id, :timeframe_group_id],
      name: :fare_time_periods_org_version_timeframe_group_index
    )
    |> check_constraint(:weekdays, name: :weekdays_must_cover_a_day)
  end
end
