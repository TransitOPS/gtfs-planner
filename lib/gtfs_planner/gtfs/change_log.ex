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

    belongs_to :rolled_back_to_log, GtfsPlanner.Gtfs.ChangeLog,
      foreign_key: :rolled_back_to_log_id,
      type: :binary_id

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
      :entity_external_id,
      :station_stop_id,
      :actor_id,
      :actor_email,
      :action,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_entity_id()
    |> validate_inclusion(:entity_type, ["stop", "pathway", "level"])
    |> validate_inclusion(:action, ["created", "updated", "deleted", "rolled_back"])
    |> validate_rollback_reference()
  end

  defp validate_entity_id(changeset) do
    action = get_field(changeset, :action)
    entity_id = get_field(changeset, :entity_id)

    if action != "created" and is_nil(entity_id) do
      add_error(changeset, :entity_id, "can't be blank")
    else
      changeset
    end
  end

  defp validate_rollback_reference(changeset) do
    action = get_field(changeset, :action)
    rolled_back_to_log_id = get_field(changeset, :rolled_back_to_log_id)

    cond do
      action == "rolled_back" and is_nil(rolled_back_to_log_id) ->
        add_error(changeset, :rolled_back_to_log_id, "must be set when action is rolled_back")

      action != "rolled_back" and not is_nil(rolled_back_to_log_id) ->
        add_error(
          changeset,
          :rolled_back_to_log_id,
          "must not be set unless action is rolled_back"
        )

      true ->
        changeset
    end
  end
end
