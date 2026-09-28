defmodule GtfsPlanner.Gtfs.AlignmentSegment do
  @moduledoc """
  An editable path between two stops, scoped to one organization and version.

  Geometry holds interior `[lon, lat]` points only (INV-1); endpoints are the
  stops' current coordinates. `from_occurrence_id` is nil for a shared
  stop-pair path and set for a visit-specific override (INV-6).

  Scope fields (`organization_id`, `gtfs_version_id`, `from_stop_id`,
  `to_stop_id`, `from_occurrence_id`) are set on the struct by
  `GtfsPlanner.Gtfs.Alignments`, never cast from input (CR-2).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @max_points 5_000

  schema "alignment_segments" do
    belongs_to :organization, GtfsPlanner.Organizations.Organization
    field :gtfs_version_id, :binary_id
    field :from_stop_id, :string
    field :to_stop_id, :string

    belongs_to :from_occurrence, GtfsPlanner.Gtfs.RoutePatternStop,
      foreign_key: :from_occurrence_id

    field :points, {:array, {:array, :float}}, default: []
    field :lock_version, :integer, default: 1

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          from_stop_id: String.t(),
          to_stop_id: String.t(),
          from_occurrence_id: Ecto.UUID.t() | nil,
          points: [[float()]],
          lock_version: integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Maximum interior points stored on one segment."
  @spec max_points() :: pos_integer()
  def max_points, do: @max_points

  @doc """
  Creates a changeset for an alignment segment.

  Only `:points` is cast; scope fields must already be set on the struct.
  """
  def changeset(segment, attrs) do
    segment
    |> cast(attrs, [:points])
    |> validate_points()
    |> optimistic_lock(:lock_version)
    |> unique_constraint([:organization_id, :gtfs_version_id, :from_stop_id, :to_stop_id],
      name: :alignment_segments_shared_pair_index
    )
    |> unique_constraint([:from_occurrence_id, :to_stop_id],
      name: :alignment_segments_override_visit_index
    )
    |> foreign_key_constraint(:from_occurrence_id)
  end

  defp validate_points(changeset) do
    # Ecto casts numeric strings to floats, but browser input must already be
    # numbers (R16). Validate the raw params so a string coordinate is
    # rejected instead of silently coerced.
    if Keyword.has_key?(changeset.errors, :points) do
      changeset
    else
      raw = Map.get(changeset.params, "points", :missing)

      points =
        case raw do
          :missing -> get_field(changeset, :points, [])
          _ -> raw
        end

      cond do
        not is_list(points) ->
          add_error(changeset, :points, "must be a list of [lon, lat] pairs")

        length(points) > @max_points ->
          add_error(changeset, :points, "must have at most #{@max_points} points")

        true ->
          case normalize_points(points) do
            {:ok, normalized} -> put_change(changeset, :points, normalized)
            {:error, message} -> add_error(changeset, :points, message)
          end
      end
    end
  end

  defp normalize_points(points) do
    Enum.reduce_while(points, {:ok, []}, fn pair, {:ok, acc} ->
      case normalize_pair(pair) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp normalize_pair([lon, lat]) when is_number(lon) and is_number(lat) do
    lon_f = lon * 1.0
    lat_f = lat * 1.0

    cond do
      lon_f < -180 or lon_f > 180 ->
        {:error, "longitude must be between -180 and 180"}

      lat_f < -90 or lat_f > 90 ->
        {:error, "latitude must be between -90 and 90"}

      true ->
        {:ok, [lon_f, lat_f]}
    end
  end

  defp normalize_pair(_pair) do
    {:error, "must be a list of [lon, lat] pairs"}
  end
end
