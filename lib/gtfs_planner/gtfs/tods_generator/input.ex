defmodule GtfsPlanner.Gtfs.TodsGenerator.Input do
  @moduledoc """
  The five business inputs of one TODS generator request.

  The generator reads persisted crew, block and roster rules and displays them
  read-only, so this input carries no unsaved rule override: an explicitly
  selected `garage_id` is a fallback for unresolved blocks, never a redefinition
  of a rule. The scoped request token and the source fingerprint are transport
  facts owned by the generator, not business input, and are deliberately absent
  here.

  `normalize/1` returns the canonical form the receipt stores and the plan
  compares: string keys, ISO 8601 dates, the garage UUID and a boolean, so the
  same input hashes and serializes identically everywhere.
  """

  use Ecto.Schema
  import Ecto.Changeset, only: [cast: 3, validate_required: 2]

  @castable_fields [:start_date, :end_date, :representative_week, :garage_id, :terminal_relief?]

  @primary_key false
  @foreign_key_type :binary_id
  embedded_schema do
    field :start_date, :date
    field :end_date, :date
    field :representative_week, :date
    field :garage_id, Ecto.UUID
    field :terminal_relief?, :boolean, default: false
  end

  @type t :: %__MODULE__{
          start_date: Date.t() | nil,
          end_date: Date.t() | nil,
          representative_week: Date.t() | nil,
          garage_id: Ecto.UUID.t() | nil,
          terminal_relief?: boolean()
        }

  @doc """
  Validates the business input, defaulting terminal relief to `false`.

  `active_dates` are the feed's dates with scheduled service. When they are
  known, an input that names no dates defaults to the first active calendar
  week: the Monday of the week holding the first active date, through that
  week's Sunday, with that same Monday as the representative week. An input that
  names dates always keeps its own values, and a feed with no active date has no
  week to default to, so an input naming no dates is refused for its missing ones.
  """
  @spec changeset(t(), map(), [Date.t()]) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = input, attrs, active_dates \\ []) do
    input
    |> default_to_first_active_week(active_dates)
    |> cast(attrs, @castable_fields)
    |> validate_required([:start_date, :end_date, :representative_week, :garage_id])
    |> validate_ordered_dates()
    |> validate_representative_week()
  end

  @doc """
  Returns the Monday and Sunday of the first active calendar week of the feed.

  Returns `nil` when no date in `active_dates` has service, because a feed with
  no active date has no week to default to.
  """
  @spec first_active_week([Date.t()]) :: {Date.t(), Date.t()} | nil
  def first_active_week([]), do: nil

  def first_active_week(active_dates) do
    first = Enum.min(active_dates, Date)
    monday = Date.beginning_of_week(first, :monday)
    {monday, Date.add(monday, 6)}
  end

  @doc """
  Normalizes a valid changeset (or input) to its canonical map.

  Returns `{:ok, normalized}` or `{:error, changeset}`. The normalized map holds
  only the five business inputs, with JSON-storable values.
  """
  @spec normalize(Ecto.Changeset.t() | t()) ::
          {:ok, map()} | {:error, Ecto.Changeset.t()}
  def normalize(%Ecto.Changeset{} = changeset) do
    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, input} -> {:ok, normalized(input)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def normalize(%__MODULE__{} = input), do: normalize(changeset(input, %{}))

  defp default_to_first_active_week(%__MODULE__{} = input, active_dates) do
    case first_active_week(active_dates) do
      {monday, sunday} ->
        %{
          input
          | start_date: input.start_date || monday,
            end_date: input.end_date || sunday,
            representative_week: input.representative_week || monday
        }

      nil ->
        input
    end
  end

  defp normalized(%__MODULE__{} = input) do
    %{
      "start_date" => Date.to_iso8601(input.start_date),
      "end_date" => Date.to_iso8601(input.end_date),
      "representative_week" => Date.to_iso8601(input.representative_week),
      "garage_id" => input.garage_id,
      "terminal_relief?" => input.terminal_relief?
    }
  end

  defp validate_ordered_dates(changeset) do
    start_date = Ecto.Changeset.get_field(changeset, :start_date)
    end_date = Ecto.Changeset.get_field(changeset, :end_date)

    if is_nil(start_date) or is_nil(end_date) or Date.compare(end_date, start_date) != :lt do
      changeset
    else
      Ecto.Changeset.add_error(changeset, :end_date, "must be on or after the start date")
    end
  end

  # A representative week is a whole Monday-to-Sunday week inside the selected
  # range, so it has to start on a Monday and overlap the range it represents.
  defp validate_representative_week(changeset) do
    week = Ecto.Changeset.get_field(changeset, :representative_week)

    cond do
      is_nil(week) ->
        changeset

      is_nil(Ecto.Changeset.get_field(changeset, :start_date)) or
          is_nil(Ecto.Changeset.get_field(changeset, :end_date)) ->
        changeset

      Date.day_of_week(week) != 1 ->
        Ecto.Changeset.add_error(changeset, :representative_week, "must be a Monday")

      Date.compare(week, Ecto.Changeset.get_field(changeset, :end_date)) == :gt or
          Date.compare(week, Ecto.Changeset.get_field(changeset, :start_date)) == :lt ->
        Ecto.Changeset.add_error(
          changeset,
          :representative_week,
          "must fall within the selected dates"
        )

      true ->
        changeset
    end
  end
end
