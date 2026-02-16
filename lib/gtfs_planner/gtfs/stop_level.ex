defmodule GtfsPlanner.Gtfs.StopLevel do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          stop_id: Ecto.UUID.t(),
          level_id: Ecto.UUID.t(),
          diagram_filename: String.t() | nil,
          scale_point_a: map() | nil,
          scale_point_b: map() | nil,
          scale_distance_meters: Decimal.t() | nil,
          scale_meters_per_unit: Decimal.t() | nil,
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "stop_levels" do
    field :diagram_filename, :string
    field :scale_point_a, :map
    field :scale_point_b, :map
    field :scale_distance_meters, :decimal
    field :scale_meters_per_unit, :decimal

    belongs_to :stop, GtfsPlanner.Gtfs.Stop
    belongs_to :level, GtfsPlanner.Gtfs.Level
    belongs_to :organization, GtfsPlanner.Organizations.Organization
    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(stop_level, attrs) do
    stop_level
    |> cast(attrs, [
      :stop_id,
      :level_id,
      :diagram_filename,
      :scale_point_a,
      :scale_point_b,
      :scale_distance_meters,
      :scale_meters_per_unit,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_required([:stop_id, :level_id, :organization_id, :gtfs_version_id])
    |> unique_constraint([:organization_id, :gtfs_version_id, :stop_id, :level_id])
  end

  def scale_changeset(stop_level, attrs) do
    stop_level
    |> cast(attrs, [
      :scale_point_a,
      :scale_point_b,
      :scale_distance_meters,
      :scale_meters_per_unit
    ])
    |> validate_scale_all_or_none()
    |> validate_number(:scale_distance_meters, greater_than: 0)
    |> validate_number(:scale_meters_per_unit, greater_than: 0)
    |> validate_scale_point(:scale_point_a)
    |> validate_scale_point(:scale_point_b)
    |> check_constraint(:scale_point_a, name: :stop_levels_scale_all_or_none_ck)
    |> check_constraint(:scale_distance_meters, name: :stop_levels_scale_positive_ck)
    |> check_constraint(:scale_point_a, name: :stop_levels_scale_points_bounds_ck)
  end

  defp validate_scale_all_or_none(changeset) do
    fields = [:scale_point_a, :scale_point_b, :scale_distance_meters, :scale_meters_per_unit]

    present? =
      Enum.map(fields, fn field ->
        case get_field(changeset, field) do
          nil -> false
          _value -> true
        end
      end)

    if Enum.uniq(present?) in [[true], [false]] do
      changeset
    else
      add_error(
        changeset,
        :scale_point_a,
        "scale calibration requires both points, distance, and ratio"
      )
    end
  end

  defp validate_scale_point(changeset, field) do
    validate_change(changeset, field, fn _, value ->
      if valid_scale_point?(value) do
        []
      else
        [{field, "must include numeric x and y coordinates between 0 and 100"}]
      end
    end)
  end

  defp valid_scale_point?(%{} = point) do
    x = point_value(point, :x)
    y = point_value(point, :y)

    is_number(x) and is_number(y) and x >= 0 and x <= 100 and y >= 0 and y <= 100
  end

  defp valid_scale_point?(_), do: false

  defp point_value(point, key) do
    Map.get(point, key) || Map.get(point, Atom.to_string(key))
  end
end
