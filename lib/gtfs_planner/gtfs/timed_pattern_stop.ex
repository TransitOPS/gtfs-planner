defmodule GtfsPlanner.Gtfs.TimedPatternStop do
  @moduledoc "Relative timing and stop service values for one pattern occurrence."

  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.TimedPattern

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "timed_pattern_stops" do
    belongs_to :timed_pattern, GtfsPlanner.Gtfs.TimedPattern
    belongs_to :route_pattern_stop, GtfsPlanner.Gtfs.RoutePatternStop
    field :arrival_offset, :integer
    field :departure_offset, :integer
    field :timepoint, :integer
    field :pickup_type, :integer
    field :drop_off_type, :integer
    field :stop_headsign, :string

    timestamps(type: :utc_datetime_usec)
  end

  @offsets_check_constraint "timed_pattern_stops_offsets_both_or_neither"
  @offsets_pair_message "must be set together with departure"

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          timed_pattern_id: Ecto.UUID.t(),
          route_pattern_stop_id: Ecto.UUID.t(),
          arrival_offset: integer() | nil,
          departure_offset: integer() | nil,
          timepoint: integer() | nil,
          pickup_type: integer() | nil,
          drop_off_type: integer() | nil,
          stop_headsign: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  def changeset(timed_pattern_stop, attrs) do
    timed_pattern_stop
    |> cast(attrs, [
      :timed_pattern_id,
      :route_pattern_stop_id,
      :arrival_offset,
      :departure_offset,
      :timepoint,
      :pickup_type,
      :drop_off_type,
      :stop_headsign
    ])
    |> put_loaded_assoc(:timed_pattern, Map.get(attrs, :timed_pattern))
    |> put_loaded_assoc(:route_pattern_stop, Map.get(attrs, :route_pattern_stop))
    |> trim_string_fields()
    |> validate_required([:timed_pattern_id, :route_pattern_stop_id])
    |> validate_offsets_pair()
    |> validate_number(:arrival_offset, greater_than_or_equal_to: -2_147_483_647)
    |> validate_number(:arrival_offset, less_than_or_equal_to: 2_147_483_647)
    |> validate_number(:departure_offset, greater_than_or_equal_to: 0)
    |> validate_number(:departure_offset, less_than_or_equal_to: 2_147_483_647)
    |> validate_inclusion(:timepoint, [0, 1])
    |> validate_inclusion(:pickup_type, 0..3)
    |> validate_inclusion(:drop_off_type, 0..3)
    |> unique_constraint([:timed_pattern_id, :route_pattern_stop_id],
      name: :timed_pattern_stops_timed_pattern_id_occurrence_id_index
    )
    |> foreign_key_constraint(:timed_pattern_id)
    |> foreign_key_constraint(:route_pattern_stop_id)
    |> check_constraint(:arrival_offset,
      name: @offsets_check_constraint,
      message: @offsets_pair_message
    )
    |> validate_occurrence_parent()
  end

  # A non-timepoint stop may have no times at all, but a half-filled pair carries no
  # meaning: the two offsets describe one arrival/departure pair. The database holds
  # the same rule as `timed_pattern_stops_offsets_both_or_neither`; this reports it in
  # the changeset so the editor sees one message rather than a constraint error. The
  # error names :arrival_offset either way, matching the `check_constraint/3` field so
  # both paths attribute the violation to the same key.
  defp validate_offsets_pair(changeset) do
    case {get_field(changeset, :arrival_offset), get_field(changeset, :departure_offset)} do
      {nil, nil} ->
        changeset

      {nil, _departure} ->
        add_error(changeset, :arrival_offset, @offsets_pair_message)

      {_arrival, nil} ->
        add_error(changeset, :arrival_offset, @offsets_pair_message)

      {_arrival, _departure} ->
        changeset
    end
  end

  defp put_loaded_assoc(changeset, _association, nil), do: changeset

  defp put_loaded_assoc(changeset, :timed_pattern, %GtfsPlanner.Gtfs.TimedPattern{} = struct),
    do: put_assoc(changeset, :timed_pattern, struct)

  defp put_loaded_assoc(
         changeset,
         :route_pattern_stop,
         %GtfsPlanner.Gtfs.RoutePatternStop{} = struct
       ),
       do: put_assoc(changeset, :route_pattern_stop, struct)

  defp put_loaded_assoc(changeset, _association, _value), do: changeset

  @doc """
  Whether `timing` and `occurrence` belong to the same route pattern.

  A pattern is identified by its organization, version and GTFS `route_pattern_id`
  together: another scope can repeat the same `route_pattern_id`. Any missing
  component leaves the parent unverifiable, so it does not match. Callers that
  insert rows without this module's changeset check their parents with this
  function.
  """
  @spec same_pattern?(TimedPattern.t(), RoutePatternStop.t()) :: boolean()
  def same_pattern?(%TimedPattern{} = timing, %RoutePatternStop{} = occurrence) do
    scope = pattern_scope(timing)
    scope == pattern_scope(occurrence) and not Enum.any?(Tuple.to_list(scope), &is_nil/1)
  end

  defp pattern_scope(%{
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id,
         route_pattern_id: route_pattern_id
       }),
       do: {organization_id, gtfs_version_id, route_pattern_id}

  defp validate_occurrence_parent(changeset) do
    case {
      get_assoc(changeset, :timed_pattern, :struct),
      get_assoc(changeset, :route_pattern_stop, :struct)
    } do
      {%TimedPattern{} = timing, %RoutePatternStop{} = occurrence} ->
        if same_pattern?(timing, occurrence) do
          changeset
        else
          add_error(
            changeset,
            :route_pattern_stop_id,
            "must belong to the timed pattern's route pattern"
          )
        end

      _ ->
        add_error(
          changeset,
          :route_pattern_stop_id,
          "must be checked against loaded pattern records"
        )
    end
  end
end
