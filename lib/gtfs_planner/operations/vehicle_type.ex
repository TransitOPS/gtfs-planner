defmodule GtfsPlanner.Operations.VehicleType do
  @moduledoc """
  An organization-wide vehicle type.

  A type belongs to exactly one organization, ignores GTFS versions and is
  unique within the organization ignoring case. `max_out_minutes` stores the
  optional maximum time away from a garage in integer minutes; the editable
  `max_out_hours` decimal is a virtual field that is validated in hours before
  it is rounded to minutes. `organization_id` and `updated_by_id` are set
  programmatically and are never cast from user params.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  alias GtfsPlanner.Values

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @min_out_hours 1
  @max_out_hours 24

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          name: String.t(),
          max_out_minutes: non_neg_integer() | nil,
          max_out_hours: Decimal.t() | nil,
          updated_by_id: Ecto.UUID.t() | nil,
          vehicle_count: non_neg_integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "vehicle_types" do
    field :name, :string
    field :max_out_minutes, :integer
    field :max_out_hours, :decimal, virtual: true
    field :vehicle_count, :integer, virtual: true, default: 0
    field :updated_by_id, :binary_id

    belongs_to :organization, GtfsPlanner.Organizations.Organization

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  A changeset for creating and updating a vehicle type.

  Casts only the user-editable fields. A stored `max_out_minutes` is presented as
  `max_out_hours` for editing; a supplied blank clears the limit and an absent
  value preserves it.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(vehicle_type, attrs) do
    vehicle_type
    |> cast(attrs, [:name, :max_out_hours])
    |> trim_string_fields()
    |> validate_required([:name])
    |> validate_length(:name, max: 255)
    |> put_hours_change(fetch_attr(attrs, "max_out_hours"))
    |> validate_max_out_hours()
    |> put_max_out_minutes()
    |> unique_constraint(:name, name: :vehicle_types_organization_id_lower_name_index)
  end

  # Casting a blank string to a virtual decimal is indistinguishable from an
  # absent parameter, so blank clearing and stored-minute display are driven from
  # the raw parameter.
  defp put_hours_change(changeset, :__absent__), do: initialize_max_out_hours(changeset)

  defp put_hours_change(changeset, raw) do
    if Values.blank?(raw) do
      changeset
      |> put_change(:max_out_hours, nil)
      |> put_change(:max_out_minutes, nil)
    else
      changeset
    end
  end

  defp initialize_max_out_hours(changeset) do
    cond do
      Map.has_key?(changeset.changes, :max_out_hours) ->
        changeset

      Keyword.has_key?(changeset.errors, :max_out_hours) ->
        changeset

      is_integer(get_field(changeset, :max_out_minutes)) ->
        hours = Decimal.div(get_field(changeset, :max_out_minutes), 60)
        put_change(changeset, :max_out_hours, hours)

      true ->
        changeset
    end
  end

  defp validate_max_out_hours(changeset) do
    if Map.has_key?(changeset.changes, :max_out_hours) do
      validate_number(changeset, :max_out_hours,
        greater_than_or_equal_to: @min_out_hours,
        less_than_or_equal_to: @max_out_hours
      )
    else
      changeset
    end
  end

  # Validate the supplied hours before rounding so 0.999 and 24.001 are rejected
  # rather than rounded into range.
  defp put_max_out_minutes(changeset) do
    cond do
      not Map.has_key?(changeset.changes, :max_out_hours) ->
        changeset

      is_nil(get_change(changeset, :max_out_hours)) ->
        put_change(changeset, :max_out_minutes, nil)

      Keyword.has_key?(changeset.errors, :max_out_hours) ->
        changeset

      true ->
        minutes =
          changeset
          |> get_change(:max_out_hours)
          |> Decimal.mult(60)
          |> Decimal.round(0, :half_up)
          |> Decimal.to_integer()

        put_change(changeset, :max_out_minutes, minutes)
    end
  end

  defp fetch_attr(attrs, key) when is_map(attrs) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, String.to_existing_atom(key), :__absent__)
    end
  end

  defp fetch_attr(_attrs, _key), do: :__absent__
end
