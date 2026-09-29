defmodule GtfsPlanner.Gtfs.FlexHours do
  @moduledoc """
  One hours row of a flex service, embedded in `flex_services.hours`.

  `service_id` names the calendar this window belongs to. `area_key` scopes the
  row to one area of the service (`a1`, `a2`…) and is nil when the row covers
  every area. Times are `"HH:MM"` on a 24-hour clock from 00:00 to 23:59; an end
  at or before the start is the next day and exports as 24:00:00 or later (R6).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GtfsPlanner.ChangesetHelpers

  @primary_key false

  @time_format ~r/\A([01]\d|2[0-3]):[0-5]\d\z/
  @time_message "Enter a time as HH:MM, between 00:00 and 23:59."

  embedded_schema do
    field :area_key, :string
    field :service_id, :string
    field :start, :string
    field :end, :string
  end

  @type t :: %__MODULE__{
          area_key: String.t() | nil,
          service_id: String.t() | nil,
          start: String.t() | nil,
          end: String.t() | nil
        }

  @doc """
  Creates a changeset for one hours row.

  Requires the calendar and both times, and rejects any time outside `HH:MM`
  between 00:00 and 23:59.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(hours, attrs) do
    hours
    |> cast(attrs, [:area_key, :service_id, :start, :end])
    |> ChangesetHelpers.trim_string_fields()
    |> validate_required([:service_id, :start, :end])
    |> validate_format(:start, @time_format, message: @time_message)
    |> validate_format(:end, @time_format, message: @time_message)
  end
end
