defmodule GtfsPlanner.Alerts.TimingAnswer do
  @moduledoc """
  When an alert applies, embedded in `service_alerts.timing`.

  Every value here is civil: a date, a clock time, or a naive date and time
  together with the IANA zone name they are read in. Nothing converts between
  zones and nothing is stored as a UTC instant, because this package only saves
  and views alerts (R12, CR-7).

  `time_zone` is deliberately not cast: it comes from the version's
  `agency_timezone`, so a form or a prepared assistant change cannot move an
  alert's times into a zone its agency does not use.

  A `:now` alert fills `start_date`/`start_time` and the end answer; a `:planned`
  alert fills `pattern` with `:continuous` or `:weekly`, and the daily window is
  read from the same `start_time`/`end_time`/`all_day` fields.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GtfsPlanner.ChangesetHelpers

  @primary_key false

  @end_kinds [:confirmed, :estimated, :unknown]
  @patterns [:continuous, :weekly]

  @max_exception_dates 60
  @exception_dates_too_many_message "Choose no more than #{@max_exception_dates} dates."

  embedded_schema do
    field :start_date, :date
    field :start_time, :time
    field :end_kind, Ecto.Enum, values: @end_kinds
    field :end_date, :date
    field :end_time, :time
    field :check_in_at, :naive_datetime
    field :pattern, Ecto.Enum, values: @patterns
    field :first_date, :date
    field :weeks, :integer
    field :weekdays, {:array, :integer}
    field :all_day, :boolean
    field :last_date, :date
    field :added_dates, {:array, :date}
    field :removed_dates, {:array, :date}
    field :notice_on, :date
    field :time_zone, :string
    field :delay_minutes, :integer
  end

  @type t :: %__MODULE__{
          start_date: Date.t() | nil,
          start_time: Time.t() | nil,
          end_kind: :confirmed | :estimated | :unknown | nil,
          end_date: Date.t() | nil,
          end_time: Time.t() | nil,
          check_in_at: NaiveDateTime.t() | nil,
          pattern: :continuous | :weekly | nil,
          first_date: Date.t() | nil,
          weeks: integer() | nil,
          weekdays: [integer()] | nil,
          all_day: boolean() | nil,
          last_date: Date.t() | nil,
          added_dates: [Date.t()] | nil,
          removed_dates: [Date.t()] | nil,
          notice_on: Date.t() | nil,
          time_zone: String.t() | nil,
          delay_minutes: integer() | nil
        }

  @doc """
  Creates a changeset for the timing answer.

  Requires nothing, because a draft is saved at every step. Rejects a weekly
  repetition outside 1..52 weeks, a weekday outside ISO 1..7, a delay estimate
  outside 1..240 minutes, and more than #{@max_exception_dates} added or removed
  dates. `time_zone` is never cast.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(timing, attrs) do
    timing
    |> cast(attrs, [
      :start_date,
      :start_time,
      :end_kind,
      :end_date,
      :end_time,
      :check_in_at,
      :pattern,
      :first_date,
      :weeks,
      :weekdays,
      :all_day,
      :last_date,
      :added_dates,
      :removed_dates,
      :notice_on,
      :delay_minutes
    ])
    |> ChangesetHelpers.trim_string_fields()
    |> validate_number(:weeks, greater_than_or_equal_to: 1, less_than_or_equal_to: 52)
    |> validate_number(:delay_minutes, greater_than_or_equal_to: 1, less_than_or_equal_to: 240)
    |> validate_weekdays()
    |> validate_length(:added_dates,
      max: @max_exception_dates,
      message: @exception_dates_too_many_message
    )
    |> validate_length(:removed_dates,
      max: @max_exception_dates,
      message: @exception_dates_too_many_message
    )
  end

  @doc """
  Whether this answer's end can close a period.

  Only a confirmed end with a time actually ends the alert. An estimated or
  unknown end names when recovery is expected or that there is none, and an
  unanswered end names nothing, so both leave the alert open. `check_in_at` is an
  internal operator aid and is never an end: an alert must not expire because no
  one checked in.
  """
  @spec closed_end?(t()) :: boolean()
  def closed_end?(%{end_kind: :confirmed, end_time: %Time{}}), do: true
  def closed_end?(%__MODULE__{}), do: false

  defp validate_weekdays(changeset) do
    validate_change(changeset, :weekdays, fn :weekdays, weekdays ->
      if Enum.all?(weekdays, &(&1 in 1..7)) do
        []
      else
        [{:weekdays, "must be ISO weekdays 1 to 7 (Monday to Sunday)"}]
      end
    end)
  end
end
