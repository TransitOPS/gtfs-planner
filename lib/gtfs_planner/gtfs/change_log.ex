defmodule GtfsPlanner.Gtfs.ChangeLog do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "change_logs" do
    field :entity_type, :string
    field :entity_id, :binary_id
    field :entity_external_id, :string
    field :station_stop_id, :string
    field :actor_id, :binary_id
    field :actor_email, :string
    field :snapshot, :map
    field :changed_fields, :map
    field :action, :string
    field :rolled_back_to_log_id, :binary_id

    belongs_to :organization, GtfsPlanner.Organizations.Organization
    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(change_log, attrs) do
    change_log
    |> cast(attrs, [
      :entity_type,
      :entity_id,
      :entity_external_id,
      :station_stop_id,
      :actor_id,
      :actor_email,
      :snapshot,
      :changed_fields,
      :action,
      :rolled_back_to_log_id,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_required([
      :entity_type,
      :entity_id,
      :entity_external_id,
      :station_stop_id,
      :actor_id,
      :actor_email,
      :action,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_inclusion(:entity_type, ["stop", "pathway", "level"])
    |> validate_inclusion(:action, ["created", "updated", "deleted", "rolled_back"])
  end
end
