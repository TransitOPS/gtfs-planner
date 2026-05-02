defmodule GtfsPlanner.Gtfs.StopLevel do
  use Ecto.Schema
  import Ecto.Changeset
  alias GtfsPlanner.Gtfs.Coordinates

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          stop_id: Ecto.UUID.t(),
          level_id: Ecto.UUID.t(),
          diagram_filename: String.t() | nil,
          scale_point_a: map() | nil,
          scale_point_b: map() | nil,
          scale_distance_meters: Decimal.t() | nil,
          scale_meters_per_unit: Decimal.t() | nil,
          floorplan_center_lat: float() | nil,
          floorplan_center_lon: float() | nil,
          floorplan_scale_mpp: float() | nil,
          floorplan_rotation_deg: float() | nil,
          saved_synced_alignment: boolean(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @type alignment_transform :: %{
          center_lat: float(),
          center_lon: float(),
          scale_mpp: float(),
          rotation_deg: float()
        }

  @type alignment_transform_error :: :alignment_missing | :invalid_alignment
  @type inverse_alignment_transform_error :: :invalid_transform | :non_invertible_transform
  @type compose_alignment_transform_error :: :invalid_transform
  @type alignment_delta_error ::
          :alignment_missing
          | :invalid_alignment
          | :invalid_transform
          | :non_invertible_transform

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "stop_levels" do
    field :diagram_filename, :string
    field :scale_point_a, :map
    field :scale_point_b, :map
    field :scale_distance_meters, :decimal
    field :scale_meters_per_unit, :decimal
    field :floorplan_center_lat, :float
    field :floorplan_center_lon, :float
    field :floorplan_scale_mpp, :float
    field :floorplan_rotation_deg, :float
    field :saved_synced_alignment, :boolean, default: false

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

  def alignment_changeset(stop_level, attrs) do
    stop_level
    |> cast(attrs, [
      :floorplan_center_lat,
      :floorplan_center_lon,
      :floorplan_scale_mpp,
      :floorplan_rotation_deg
    ])
    |> validate_alignment_all_or_none()
    |> validate_number(:floorplan_center_lat,
      greater_than_or_equal_to: -90,
      less_than_or_equal_to: 90
    )
    |> validate_number(:floorplan_center_lon,
      greater_than_or_equal_to: -180,
      less_than_or_equal_to: 180
    )
    |> validate_number(:floorplan_scale_mpp, greater_than: 0)
  end

  def saved_synced_alignment_changeset(stop_level, attrs) do
    stop_level
    |> cast(attrs, [:saved_synced_alignment])
    |> validate_required([:saved_synced_alignment])
  end

  @spec alignment_complete?(t() | map()) :: boolean()
  def alignment_complete?(%{
        floorplan_center_lat: lat,
        floorplan_center_lon: lon,
        floorplan_scale_mpp: scale,
        floorplan_rotation_deg: rotation
      })
      when is_number(lat) and lat >= -90 and lat <= 90 and is_number(lon) and lon >= -180 and
             lon <= 180 and is_number(scale) and scale > 0 and is_number(rotation) do
    true
  end

  def alignment_complete?(_), do: false

  @spec alignment_transform(t() | map()) ::
          {:ok, alignment_transform()} | {:error, alignment_transform_error()}
  def alignment_transform(%{
        floorplan_center_lat: lat,
        floorplan_center_lon: lon,
        floorplan_scale_mpp: scale,
        floorplan_rotation_deg: rotation
      }) do
    cond do
      is_nil(lat) or is_nil(lon) or is_nil(scale) or is_nil(rotation) ->
        {:error, :alignment_missing}

      not (is_number(lat) and lat >= -90 and lat <= 90) ->
        {:error, :invalid_alignment}

      not (is_number(lon) and lon >= -180 and lon <= 180) ->
        {:error, :invalid_alignment}

      not (is_number(scale) and scale > 0) ->
        {:error, :invalid_alignment}

      not is_number(rotation) ->
        {:error, :invalid_alignment}

      true ->
        {:ok,
         %{
           center_lat: lat * 1.0,
           center_lon: lon * 1.0,
           scale_mpp: scale * 1.0,
           rotation_deg: rotation * 1.0
         }}
    end
  end

  def alignment_transform(_), do: {:error, :alignment_missing}

  @spec invert_alignment_transform(alignment_transform() | map()) ::
          {:ok, alignment_transform()} | {:error, inverse_alignment_transform_error()}
  def invert_alignment_transform(%{
        center_lat: center_lat,
        center_lon: center_lon,
        scale_mpp: scale_mpp,
        rotation_deg: rotation_deg
      })
      when is_number(center_lat) and is_number(center_lon) and is_number(scale_mpp) and
             is_number(rotation_deg) do
    cond do
      scale_mpp == 0 ->
        {:error, :non_invertible_transform}

      scale_mpp < 0 ->
        {:error, :invalid_transform}

      true ->
        {:ok,
         %{
           center_lat: -center_lat * 1.0,
           center_lon: -center_lon * 1.0,
           scale_mpp: 1.0 / (scale_mpp * 1.0),
           rotation_deg: -rotation_deg * 1.0
         }}
    end
  end

  def invert_alignment_transform(_), do: {:error, :invalid_transform}

  @spec compose_alignment_transforms(alignment_transform() | map(), alignment_transform() | map()) ::
          {:ok, alignment_transform()} | {:error, compose_alignment_transform_error()}
  def compose_alignment_transforms(left, right) do
    with {:ok, left_transform} <- normalize_alignment_transform(left),
         {:ok, right_transform} <- normalize_alignment_transform(right) do
      {:ok,
       %{
         center_lat: left_transform.center_lat + right_transform.center_lat,
         center_lon: left_transform.center_lon + right_transform.center_lon,
         scale_mpp: left_transform.scale_mpp * right_transform.scale_mpp,
         rotation_deg: left_transform.rotation_deg + right_transform.rotation_deg
       }}
    end
  end

  @doc """
  Computes an active alignment delta transform from `old_alignment` to
  `new_alignment`.

  The delta is defined as:

      D = T_new ∘ inverse(T_old)

  where each `T_*` is built from the corresponding `floorplan_*` fields.
  """
  @spec active_alignment_delta(t() | map(), t() | map()) ::
          {:ok, alignment_transform()} | {:error, alignment_delta_error()}
  def active_alignment_delta(old_alignment, new_alignment) do
    with {:ok, old_transform} <- alignment_transform(old_alignment),
         {:ok, new_transform} <- alignment_transform(new_alignment),
         {:ok, old_inverse} <- invert_alignment_transform(old_transform),
         {:ok, delta} <- compose_alignment_transforms(new_transform, old_inverse) do
      {:ok, delta}
    end
  end

  defp normalize_alignment_transform(%{
         center_lat: center_lat,
         center_lon: center_lon,
         scale_mpp: scale_mpp,
         rotation_deg: rotation_deg
       })
       when is_number(center_lat) and is_number(center_lon) and is_number(scale_mpp) and
              is_number(rotation_deg) and scale_mpp > 0 do
    {:ok,
     %{
       center_lat: center_lat * 1.0,
       center_lon: center_lon * 1.0,
       scale_mpp: scale_mpp * 1.0,
       rotation_deg: rotation_deg * 1.0
     }}
  end

  defp normalize_alignment_transform(_), do: {:error, :invalid_transform}

  defp validate_alignment_all_or_none(changeset) do
    fields = [
      :floorplan_center_lat,
      :floorplan_center_lon,
      :floorplan_scale_mpp,
      :floorplan_rotation_deg
    ]

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
        :floorplan_center_lat,
        "alignment requires center lat/lon, scale, and rotation together"
      )
    end
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
    x = Coordinates.point_value(point, :x)
    y = Coordinates.point_value(point, :y)

    is_number(x) and is_number(y) and x >= 0 and x <= 100 and y >= 0 and y <= 100
  end

  defp valid_scale_point?(_), do: false
end
