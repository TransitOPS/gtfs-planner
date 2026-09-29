defmodule GtfsPlanner.Gtfs.Transfer do
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "transfers" do
    field :from_stop_id, :string
    field :to_stop_id, :string
    field :from_route_id, :string
    field :to_route_id, :string
    field :from_trip_id, :string
    field :to_trip_id, :string
    field :transfer_type, :integer
    field :min_transfer_time, :integer

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          from_stop_id: String.t() | nil,
          to_stop_id: String.t() | nil,
          from_route_id: String.t() | nil,
          to_route_id: String.t() | nil,
          from_trip_id: String.t() | nil,
          to_trip_id: String.t() | nil,
          transfer_type: integer(),
          min_transfer_time: integer() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @editor_fields ~w(from_stop_id to_stop_id from_route_id to_route_id from_trip_id to_trip_id transfer_type min_transfer_time)a

  @audit_fields ~w(from_stop_id to_stop_id from_route_id to_route_id from_trip_id to_trip_id transfer_type min_transfer_time)a

  @min_time_message "Enter a whole number of seconds, zero or more."

  @doc "Creates a changeset for a transfer."
  def changeset(transfer, attrs) do
    transfer
    |> cast(attrs, [
      :from_stop_id,
      :to_stop_id,
      :from_route_id,
      :to_route_id,
      :from_trip_id,
      :to_trip_id,
      :transfer_type,
      :min_transfer_time,
      :organization_id,
      :gtfs_version_id
    ])
    |> trim_string_fields()
    |> validate_required([:transfer_type, :organization_id, :gtfs_version_id])
    |> validate_inclusion(:transfer_type, 0..5)
    |> validate_endpoints()
    |> put_key_constraints()
  end

  @doc """
  Creates a changeset for an interactively created or changed general rule.

  Import acceptance stays permissive: `changeset/2` still casts the tenant columns and
  accepts types 0–5, so it remains the import path. Editor input casts the eight GTFS
  columns only and the organization, version and any existing id come from the struct,
  accepts the general types 0–3, requires both stops, and keeps `min_transfer_time` only
  for type 2.
  """
  @spec editor_changeset(t() | Ecto.Changeset.t(), map() | keyword()) :: Ecto.Changeset.t()
  def editor_changeset(transfer, attrs) do
    transfer
    |> cast(attrs, @editor_fields)
    |> trim_string_fields()
    |> validate_required([:transfer_type, :organization_id, :gtfs_version_id])
    |> validate_inclusion(:transfer_type, 0..3, message: "Choose one of the four transfer types")
    |> validate_required([:from_stop_id, :to_stop_id], message: "Choose a stop or station")
    |> validate_min_time()
    |> put_key_constraints()
  end

  @doc """
  Creates a changeset for an in-seat transfer record authored on a block connection.

  Types 4 and 5 only, with both trips and both handoff stops required, because
  OpenTripPlanner's `TransferMapper` dereferences the stops. The route pair and the
  minimum time are forced to nil, and the organization, version and any existing id
  come from the struct. `changeset/2` stays the permissive import path.
  """
  @spec in_seat_changeset(t() | Ecto.Changeset.t(), map() | keyword()) :: Ecto.Changeset.t()
  def in_seat_changeset(transfer, attrs) do
    transfer
    |> cast(attrs, @editor_fields)
    |> trim_string_fields()
    |> validate_required([:transfer_type, :organization_id, :gtfs_version_id])
    |> validate_inclusion(:transfer_type, 4..5,
      message: "Choose riders stay on board or must re-board"
    )
    |> validate_required([:from_trip_id, :to_trip_id, :from_stop_id, :to_stop_id])
    |> put_change(:from_route_id, nil)
    |> put_change(:to_route_id, nil)
    |> put_change(:min_transfer_time, nil)
    |> put_key_constraints()
  end

  @doc """
  Returns the eight GTFS columns of a transfer as its audit snapshot.

  String keys carry every column, including the nil ones, so a deleted row can be
  re-created from its log.
  """
  @spec audit_snapshot(t()) :: %{String.t() => term()}
  def audit_snapshot(transfer) do
    Map.new(@audit_fields, &{Atom.to_string(&1), Map.fetch!(transfer, &1)})
  end

  @doc """
  Returns the change-log external ID of a transfer.

  The stop pair is always present; the route pair appears when either route is set and
  the trip pair when either trip is set. A missing selector is `*`, so an in-seat row
  without stops reads `*→* trip A→B`.
  """
  @spec audit_external_id(t()) :: String.t()
  def audit_external_id(transfer) do
    selector(transfer.from_stop_id, transfer.to_stop_id)
    |> append_selector("route", transfer.from_route_id, transfer.to_route_id)
    |> append_selector("trip", transfer.from_trip_id, transfer.to_trip_id)
  end

  defp append_selector(external_id, _label, nil, nil), do: external_id

  defp append_selector(external_id, label, from, to),
    do: "#{external_id} #{label} #{selector(from, to)}"

  defp selector(from, to), do: "#{from || "*"}→#{to || "*"}"

  # The six-field key is unique per version with NULLS NOT DISTINCT, and both
  # changesets map its violation and the organization foreign key the same way.
  defp put_key_constraints(changeset) do
    changeset
    |> unique_constraint(
      [
        :organization_id,
        :gtfs_version_id,
        :from_stop_id,
        :to_stop_id,
        :from_route_id,
        :to_route_id,
        :from_trip_id,
        :to_trip_id
      ],
      name: :transfers_org_id_version_id_from_to_stop_route_trip_index
    )
    |> foreign_key_constraint(:organization_id)
  end

  # Type 2 carries the seconds of the transfer; every other general type stores nil.
  # The upper bound is the column's int4 limit, so an oversized value is a field error
  # instead of a database exception.
  defp validate_min_time(changeset) do
    if get_field(changeset, :transfer_type) == 2 do
      changeset
      |> validate_required(:min_transfer_time, message: @min_time_message)
      |> validate_number(:min_transfer_time,
        greater_than_or_equal_to: 0,
        less_than_or_equal_to: 2_147_483_647,
        message: @min_time_message
      )
    else
      put_change(changeset, :min_transfer_time, nil)
    end
  end

  # Types 4 and 5 are in-seat transfers between two trips, so the trips identify
  # the pair and the stops may be empty; every other type needs both stops.
  defp validate_endpoints(changeset) do
    if get_field(changeset, :transfer_type) in [4, 5] do
      validate_required(changeset, [:from_trip_id, :to_trip_id])
    else
      validate_required(changeset, [:from_stop_id, :to_stop_id])
    end
  end
end
