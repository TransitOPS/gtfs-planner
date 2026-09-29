defmodule GtfsPlanner.Gtfs.FlexBookingRule do
  @moduledoc """
  One booking rule of a flex service, embedded in `flex_services.booking_rules`.

  `service_id` scopes the rule to one calendar of an area service and is nil
  when the rule covers every calendar of the service. `when` is the booking
  type: booking on the spot (`:now`), on the service day (`:same_day`), or
  earlier (`:earlier_day`). The horizons are whole days or minutes and are
  never negative; `by` is the earlier-day cut-off as `"HH:MM"`, always below
  24:00 (R7).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GtfsPlanner.ChangesetHelpers

  @primary_key false

  @whens [:now, :same_day, :earlier_day]
  @time_format ~r/\A([01]\d|2[0-3]):[0-5]\d\z/
  @time_message "Enter a time as HH:MM, between 00:00 and 23:59."

  embedded_schema do
    field :service_id, :string
    field :when, Ecto.Enum, values: @whens
    field :minutes, :integer
    field :days, :integer
    field :by, :string
    field :business_days, :boolean, default: false
    field :office_service_id, :string
    field :max_days, :integer
  end

  @type t :: %__MODULE__{
          service_id: String.t() | nil,
          when: :now | :same_day | :earlier_day | nil,
          minutes: integer() | nil,
          days: integer() | nil,
          by: String.t() | nil,
          business_days: boolean(),
          office_service_id: String.t() | nil,
          max_days: integer() | nil
        }

  @doc """
  Creates a changeset for one booking rule.

  Requires the booking type, rejects `by` outside `HH:MM` between 00:00 and
  23:59, and rejects negative `minutes`, `days` and `max_days`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(booking_rule, attrs) do
    booking_rule
    |> cast(attrs, [
      :service_id,
      :when,
      :minutes,
      :days,
      :by,
      :business_days,
      :office_service_id,
      :max_days
    ])
    |> ChangesetHelpers.trim_string_fields()
    |> validate_required([:when])
    |> validate_format(:by, @time_format, message: @time_message)
    |> validate_number(:minutes, greater_than_or_equal_to: 0)
    |> validate_number(:days, greater_than_or_equal_to: 0)
    |> validate_number(:max_days, greater_than_or_equal_to: 0)
  end
end
