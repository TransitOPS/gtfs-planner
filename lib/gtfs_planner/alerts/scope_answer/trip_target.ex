defmodule GtfsPlanner.Alerts.ScopeAnswer.TripTarget do
  @moduledoc """
  One cancelled or changed trip with the service date it runs on, embedded in
  `scope_answer.trips`.

  `trip_id` is the exact GTFS feed ID, compared byte for byte.

  `service_date` is part of the identity because a trip repeats across its
  service dates and a consumer that reads only the trip ID would match every one
  of them.

  `start_time` is the trip instance's own first departure, spelled the way
  `frequencies.txt` spells one. It may read past 24:00, so it is a `:string` and
  not a `Time`: `25:15:00` is a real first departure of a frequency-based trip,
  and an `Ecto.Time` cannot say so. It is nil for a trip that is not
  frequency-based, which is the one case where the trip ID and the service date
  already identify the instance. It is a `:string` for that reason, and because
  this row is stored inside the `scope` jsonb column.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GtfsPlanner.Gtfs.GtfsTime

  @primary_key false

  embedded_schema do
    field :trip_id, :string
    field :service_date, :date
    field :start_time, :string
  end

  @type t :: %__MODULE__{
          trip_id: String.t() | nil,
          service_date: Date.t() | nil,
          start_time: String.t() | nil
        }

  @doc """
  Creates a changeset for one trip and service date.

  Requires the trip and the date, for the same reason as `RouteStopPair`.

  `start_time` is optional, but a value that is given must be a GTFS clock
  reading, because anything else is not the trip instance a consumer could
  match. It is normalized through `GtfsPlanner.Gtfs.GtfsTime` rather than
  pattern-matched, so `8:00` and `08:00:00` cannot both be stored as spellings
  of one identity.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(trip, attrs) do
    trip
    |> cast(attrs, [:trip_id, :service_date, :start_time])
    |> validate_required([:trip_id, :service_date])
    |> normalize_start_time()
  end

  defp normalize_start_time(changeset) do
    case get_change(changeset, :start_time) do
      nil ->
        changeset

      value ->
        case GtfsTime.parse(value) do
          {:ok, seconds} ->
            put_change(changeset, :start_time, GtfsTime.format(seconds))

          {:error, :invalid_time} ->
            add_error(changeset, :start_time, "must be a GTFS time like 08:00:00 or 25:15:00")
        end
    end
  end
end
