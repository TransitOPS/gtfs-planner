defmodule GtfsPlanner.Gtfs.PathwayEvolution do
  @moduledoc """
  Schema for a scheduled station closure ("closure record").

  A closure removes one pathway from the network for a service-time window on
  every service date of a native calendar. `start_time` and `end_time` are GTFS
  service-day seconds, so a window may continue past midnight by using a value
  above `24:00:00`; wrap-around windows such as 23:00-02:00 are not stored.

  Scope comes from the calling context, never from form params: `organization_id`
  and `gtfs_version_id` are assigned on the struct and are deliberately not cast.
  The identity tuple (`organization_id`, `gtfs_version_id`, `pathway_id`,
  `service_id`, `start_time`, `end_time`) is unique in the database, and
  `pathway_id` must reference a pathway inside the same scope.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  alias GtfsPlanner.Gtfs.GtfsTime

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Largest value the integer seconds columns hold, matching `GtfsTime`.
  @max_seconds 2_147_483_647
  @max_note_length 500
  @service_time_fields [:start_time, :end_time]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          pathway_id: String.t(),
          service_id: String.t(),
          start_time: non_neg_integer(),
          end_time: non_neg_integer(),
          note: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "pathway_evolutions" do
    field :pathway_id, :string
    field :service_id, :string
    field :start_time, :integer
    field :end_time, :integer
    field :note, :string

    # Assigned from the caller's scope, never cast from parameters.
    field :organization_id, :binary_id
    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Parses a service-time value into service-day seconds.

  Accepts `H:MM`, `HH:MM` and `H:MM:SS` strings, plus values that are already
  integer seconds. Hours may exceed 23 so a window can continue past midnight.
  """
  @spec parse_service_time(term()) :: {:ok, non_neg_integer()} | {:error, :invalid_time}
  def parse_service_time(value) when is_integer(value) do
    if value >= 0 and value <= @max_seconds do
      {:ok, value}
    else
      {:error, :invalid_time}
    end
  end

  def parse_service_time(value) when is_binary(value) do
    case String.split(String.trim(value), ":") do
      [hours, minutes] -> GtfsTime.parse("#{hours}:#{minutes}:00")
      parts -> GtfsTime.parse(Enum.join(parts, ":"))
    end
  end

  def parse_service_time(_value), do: {:error, :invalid_time}

  @doc """
  Builds a closure changeset.

  Scope fields are not cast; assign them on the struct. Service times accept
  service-time strings or integer seconds.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(pathway_evolution, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    {attrs, time_errors} = normalize_service_times(attrs)

    pathway_evolution
    |> cast(attrs, [:pathway_id, :service_id, :start_time, :end_time, :note])
    |> trim_string_fields()
    |> validate_required([:pathway_id, :service_id, :start_time, :end_time])
    |> add_service_time_errors(time_errors)
    |> validate_window_order()
    |> validate_length(:note, max: @max_note_length)
    |> unique_constraint(
      [:organization_id, :gtfs_version_id, :pathway_id, :service_id, :start_time, :end_time],
      name: :pathway_evolutions_closure_index,
      error_key: :base,
      message: "This closure already exists."
    )
    |> foreign_key_constraint(:pathway_id, name: :pathway_evolutions_pathway_fkey)
  end

  defp normalize_service_times(attrs) do
    Enum.reduce(@service_time_fields, {attrs, []}, fn field, {acc, errors} ->
      key = Atom.to_string(field)

      case Map.fetch(acc, key) do
        :error ->
          {acc, errors}

        # Blank and missing values fall through to validate_required/2's
        # "can't be blank" error instead of piling a parse error on top.
        {:ok, value} when is_nil(value) ->
          {Map.delete(acc, key), errors}

        {:ok, value} when is_binary(value) ->
          normalize_service_time(acc, errors, field, key, value)

        {:ok, value} ->
          put_parsed_service_time(acc, errors, field, key, value)
      end
    end)
  end

  # A blank string is a missing value and leaves the required error to
  # `validate_required/2`; anything else is parsed.
  defp normalize_service_time(acc, errors, field, key, value) do
    case String.trim(value) do
      "" ->
        {Map.delete(acc, key), errors}

      trimmed ->
        put_parsed_service_time(acc, errors, field, key, trimmed)
    end
  end

  defp put_parsed_service_time(acc, errors, field, key, value) do
    case parse_service_time(value) do
      {:ok, seconds} ->
        {Map.put(acc, key, seconds), errors}

      {:error, :invalid_time} ->
        {Map.delete(acc, key), [{field, "is not a valid service time"} | errors]}
    end
  end

  defp add_service_time_errors(changeset, errors) do
    Enum.reduce(errors, changeset, fn {field, message}, acc ->
      add_error(acc, field, message)
    end)
  end

  defp validate_window_order(changeset) do
    start_time = get_field(changeset, :start_time)
    end_time = get_field(changeset, :end_time)

    if is_integer(start_time) and is_integer(end_time) and end_time <= start_time do
      add_error(
        changeset,
        :end_time,
        "must be later than the start time. A closure that continues past midnight uses a " <>
          "value above 24:00, for example 26:00 for a 23:00-02:00 window."
      )
    else
      changeset
    end
  end
end
