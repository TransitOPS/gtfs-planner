defmodule GtfsPlanner.Alerts.ScopeAnswer do
  @moduledoc """
  Who an alert is about, embedded in `service_alerts.scope`.

  `shape` names the one selector the answer builds, and the rest of the fields are
  the values that shape needs. The alert stores intent rather than compiled
  informed entities, so nothing here is written for a consumer directly (R3).

  Every target is the exact GTFS feed ID of a route, stop or trip, compared
  byte for byte: `ABCDEF00-0000-0000-0000-000000000000` is a legitimate feed
  string and keeps its case, so nothing here casts an identity to a UUID. An
  alert names the schedule's entities, not its rows, so an edit to the schedule
  never rewrites who an alert is about; a target the schedule no longer holds
  reads as needing attention until an editor repairs it. `mode_route_type` is
  the only selector that is not a feed ID, and it is a deliberate expansion of
  "every <mode> route" rather than a stored `route_type` selector.

  Target fields are `:string` because this whole schema is stored in the `scope`
  jsonb column.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GtfsPlanner.Alerts.ScopeAnswer.RouteStopPair
  alias GtfsPlanner.Alerts.ScopeAnswer.TripTarget
  alias GtfsPlanner.ChangesetHelpers

  @primary_key false

  @shapes [:system, :routes, :route_direction, :stop_all_routes, :route_stops, :trips]

  @max_ids 200
  @max_pairs 400

  @ids_too_many_message "Choose no more than #{@max_ids}."
  @pairs_too_many_message "Choose no more than #{@max_pairs}."

  embedded_schema do
    field :shape, Ecto.Enum, values: @shapes
    field :mode_route_type, :integer
    field :route_ids, {:array, :string}
    field :stop_ids, {:array, :string}
    embeds_many :route_stop_pairs, RouteStopPair, on_replace: :delete
    embeds_many :trips, TripTarget, on_replace: :delete
    field :direction_id, :integer
    field :all_routes_at_stops, :boolean
    field :stretch_from_stop_id, :string
    field :stretch_to_stop_id, :string
    field :alternative_stop_id, :string
    field :alternative_directions, :string
    field :facility, :string
  end

  @type t :: %__MODULE__{
          shape:
            :system | :routes | :route_direction | :stop_all_routes | :route_stops | :trips | nil,
          mode_route_type: integer() | nil,
          route_ids: [String.t()] | nil,
          stop_ids: [String.t()] | nil,
          route_stop_pairs: [RouteStopPair.t()],
          trips: [TripTarget.t()],
          direction_id: 0 | 1 | nil,
          all_routes_at_stops: boolean() | nil,
          stretch_from_stop_id: String.t() | nil,
          stretch_to_stop_id: String.t() | nil,
          alternative_stop_id: String.t() | nil,
          alternative_directions: String.t() | nil,
          facility: String.t() | nil
        }

  @doc """
  Returns a stable digest of the answer's target selection.

  Two scopes with the same digest name the same targets in the same way, whatever
  order they were entered in, so a message-only or timing-only save can tell that
  it changed nothing an operator selected. `Alerts` compares this digest with the
  one stored in `target_reference` to decide whether the trusted capture still
  describes the answer, rather than re-validating every identity on every save
  (R1, CR-5).

  A nil answer digests as the empty selection, so an alert that has not answered
  the question yet has the same digest as one answered with nothing.
  """
  @spec digest(t() | nil) :: String.t()
  def digest(nil), do: digest(%__MODULE__{})

  def digest(%__MODULE__{} = scope) do
    scope
    |> Map.take([
      :shape,
      :mode_route_type,
      :direction_id,
      :all_routes_at_stops,
      :route_ids,
      :stop_ids,
      :stretch_from_stop_id,
      :stretch_to_stop_id,
      :alternative_stop_id,
      :alternative_directions,
      :facility
    ])
    |> Map.new(fn {key, value} -> {key, normalized(key, value)} end)
    |> Map.put(:route_stop_pairs, pairs_digest(scope.route_stop_pairs))
    |> Map.put(:trips, trips_digest(scope.trips))
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # An identity list and a set mean the same selection, so the digest sorts it:
  # the same routes in another order are the same target selection. Feed IDs are
  # compared exactly, so two spellings that differ only in case are two targets.
  defp normalized(_key, nil), do: nil
  defp normalized(_key, ids) when is_list(ids), do: Enum.sort(ids)
  defp normalized(_key, value), do: value

  defp pairs_digest(pairs) do
    pairs
    |> Enum.map(&{&1.route_id, &1.stop_id})
    |> Enum.sort()
  end

  defp trips_digest(trips) do
    trips
    |> Enum.map(&{&1.trip_id, &1.service_date, &1.start_time})
    |> Enum.sort()
  end

  @doc """
  Creates a changeset for the scope answer.

  Requires nothing, because a draft is saved at every step. Rejects more than
  #{@max_ids} route or stop identities and more than #{@max_pairs} pairs or trips,
  so one answer cannot grow past what the editor and a future feed can carry.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(scope, attrs) do
    scope
    |> cast(attrs, [
      :shape,
      :mode_route_type,
      :route_ids,
      :stop_ids,
      :direction_id,
      :all_routes_at_stops,
      :stretch_from_stop_id,
      :stretch_to_stop_id,
      :alternative_stop_id,
      :alternative_directions,
      :facility
    ])
    |> ChangesetHelpers.trim_string_fields()
    |> cast_embed(:route_stop_pairs, with: &RouteStopPair.changeset/2)
    |> cast_embed(:trips, with: &TripTarget.changeset/2)
    |> validate_direction()
    |> validate_length(:alternative_directions, max: 500)
    |> validate_length(:facility, max: 200)
    |> validate_ids()
    |> validate_pairs()
  end

  defp validate_direction(changeset) do
    validate_change(changeset, :direction_id, fn :direction_id, value ->
      if value in [0, 1], do: [], else: [{:direction_id, "must be 0 or 1"}]
    end)
  end

  defp validate_ids(changeset) do
    changeset
    |> validate_length(:route_ids, max: @max_ids, message: @ids_too_many_message)
    |> validate_length(:stop_ids, max: @max_ids, message: @ids_too_many_message)
  end

  defp validate_pairs(changeset) do
    changeset
    |> validate_count(:route_stop_pairs, @max_pairs, @pairs_too_many_message)
    |> validate_count(:trips, @max_pairs, @pairs_too_many_message)
  end

  # These embeds have no primary key, so Ecto never matches a submitted entry to a
  # stored one: the change list holds the submitted entries plus every stored one
  # as a `:replace` changeset. Only the entries that remain count toward the cap.
  defp validate_count(changeset, field, max, message) do
    validate_change(changeset, field, fn ^field, value ->
      if Enum.count(value, &(&1.action not in [:replace, :delete])) > max,
        do: [{field, message}],
        else: []
    end)
  end
end
