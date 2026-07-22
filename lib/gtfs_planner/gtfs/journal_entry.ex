defmodule GtfsPlanner.Gtfs.JournalEntry do
  use Ecto.Schema

  import Ecto.Changeset

  alias GtfsPlanner.Gtfs.StationJournal.Scope

  @target_types ~w(station node pathway pin)
  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          station_id: Ecto.UUID.t(),
          author_id: Ecto.UUID.t(),
          target_type: String.t(),
          target_id: Ecto.UUID.t() | nil,
          stop_level_id: Ecto.UUID.t() | nil,
          diagram_x: float() | nil,
          diagram_y: float() | nil,
          body: String.t() | nil,
          captured_at: DateTime.t(),
          closed_at: DateTime.t() | nil,
          closed_by: Ecto.UUID.t() | nil,
          lat: float() | nil,
          lon: float() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "journal_entries" do
    belongs_to :organization, GtfsPlanner.Organizations.Organization
    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion
    belongs_to :station, GtfsPlanner.Gtfs.Stop

    field :author_id, :binary_id
    field :target_type, :string
    field :target_id, :binary_id
    field :stop_level_id, :binary_id
    field :diagram_x, :float
    field :diagram_y, :float
    field :body, :string
    field :captured_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    field :closed_by, :binary_id
    field :lat, :float
    field :lon, :float

    has_many :photos, GtfsPlanner.Gtfs.JournalPhoto

    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(t(), map(), Scope.t()) :: Ecto.Changeset.t()
  def create_changeset(entry, client_attrs, %Scope{} = scope) do
    entry
    |> cast(client_attrs, [
      :id,
      :target_type,
      :target_id,
      :stop_level_id,
      :diagram_x,
      :diagram_y,
      :body,
      :captured_at
    ])
    |> put_change(:organization_id, scope.organization_id)
    |> put_change(:gtfs_version_id, scope.gtfs_version_id)
    |> put_change(:station_id, scope.station_id)
    |> put_change(:author_id, scope.actor_id)
    |> validate_entry_fields()
  end

  @spec sync_changeset(t(), map()) :: Ecto.Changeset.t()
  def sync_changeset(entry, client_attrs) do
    entry
    |> cast(client_attrs, [
      :target_type,
      :target_id,
      :stop_level_id,
      :diagram_x,
      :diagram_y,
      :body
    ])
    |> validate_entry_fields(required: false)
  end

  @spec derived_coordinates_changeset(t(), %{lat: float() | nil, lon: float() | nil}) ::
          Ecto.Changeset.t()
  def derived_coordinates_changeset(entry, attrs) do
    entry
    |> cast(attrs, [:lat, :lon])
    |> validate_number(:lat, greater_than_or_equal_to: -90, less_than_or_equal_to: 90)
    |> validate_number(:lon, greater_than_or_equal_to: -180, less_than_or_equal_to: 180)
  end

  @spec close_changeset(t(), DateTime.t(), Ecto.UUID.t()) :: Ecto.Changeset.t()
  def close_changeset(%__MODULE__{} = entry, %DateTime{} = closed_at, closed_by) do
    entry
    |> change()
    |> put_change(:closed_at, closed_at)
    |> put_change(:closed_by, closed_by)
    |> check_constraint(:closed_at, name: :journal_entries_closure_pair_ck)
  end

  @spec reopen_changeset(t()) :: Ecto.Changeset.t()
  def reopen_changeset(%__MODULE__{} = entry) do
    entry
    |> change()
    |> put_change(:closed_at, nil)
    |> put_change(:closed_by, nil)
    |> check_constraint(:closed_at, name: :journal_entries_closure_pair_ck)
  end


  defp validate_entry_fields(changeset, options \\ []) do
    required =
      if Keyword.get(options, :required, true), do: [:id, :target_type, :captured_at], else: []

    changeset
    |> validate_required(required)
    |> validate_inclusion(:target_type, @target_types)
    |> validate_target_shape()
    |> check_constraint(:target_type, name: :journal_entries_target_shape_ck)
    |> check_constraint(:closed_at, name: :journal_entries_closure_pair_ck)
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:gtfs_version_id)
    |> foreign_key_constraint(:station_id)
  end

  defp validate_target_shape(changeset) do
    target_type = get_field(changeset, :target_type)
    target_id = get_field(changeset, :target_id)
    stop_level_id = get_field(changeset, :stop_level_id)
    diagram_x = get_field(changeset, :diagram_x)
    diagram_y = get_field(changeset, :diagram_y)

    valid? =
      case target_type do
        "station" ->
          is_nil(target_id) and is_nil(stop_level_id) and is_nil(diagram_x) and is_nil(diagram_y)

        type when type in ["node", "pathway"] ->
          not is_nil(target_id) and is_nil(stop_level_id) and is_nil(diagram_x) and
            is_nil(diagram_y)

        "pin" ->
          is_nil(target_id) and not is_nil(stop_level_id) and finite_non_negative?(diagram_x) and
            finite_non_negative?(diagram_y)

        _ ->
          true
      end

    if valid?,
      do: changeset,
      else: add_error(changeset, :target_type, "has an invalid target shape")
  end

  defp finite_non_negative?(value) when is_integer(value), do: value >= 0

  defp finite_non_negative?(value) when is_float(value), do: value >= 0

  defp finite_non_negative?(_), do: false
end
