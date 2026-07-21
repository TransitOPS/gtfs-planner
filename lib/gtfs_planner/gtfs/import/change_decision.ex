defmodule GtfsPlanner.Gtfs.Import.ChangeDecision do
  @moduledoc "A bounded persisted station change decision owned by a change run."

  use Ecto.Schema
  import Ecto.Changeset

  alias GtfsPlanner.Gtfs.Import.ChangeRun

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "gtfs_change_decisions" do
    field :decision_id, :string
    field :entity_type, Ecto.Enum, values: [:level, :stop, :pathway]
    field :action, Ecto.Enum, values: [:add, :modify, :remove, :conflict]

    field :status, Ecto.Enum,
      values: [:pending, :approved, :rejected, :preview, :applied, :failed, :stale],
      default: :pending

    field :natural_key, :string
    field :current_values, :map, default: %{}
    field :uploaded_values, :map, default: %{}
    field :changed_fields, {:array, :map}, default: []
    field :dependency_keys, {:array, :string}, default: []
    field :current_fingerprint, :string
    field :user_edited, :boolean, default: false
    field :apply_failure_code, :string
    field :applied_at, :utc_datetime_usec
    belongs_to :change_run, ChangeRun
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(decision, _attrs), do: change(decision)

  def system_changeset(decision, attrs) do
    decision
    |> cast(attrs, [
      :decision_id,
      :entity_type,
      :action,
      :status,
      :natural_key,
      :current_values,
      :uploaded_values,
      :changed_fields,
      :dependency_keys,
      :current_fingerprint,
      :user_edited,
      :apply_failure_code,
      :applied_at,
      :change_run_id
    ])
    |> validate_required([
      :decision_id,
      :entity_type,
      :action,
      :status,
      :natural_key,
      :change_run_id
    ])
    |> validate_length(:decision_id, max: 512)
    |> validate_length(:natural_key, max: 255)
    |> validate_length(:current_fingerprint, max: 128)
    |> validate_length(:apply_failure_code, max: 128)
    |> unique_constraint([:change_run_id, :decision_id],
      name: :gtfs_change_decisions_change_run_decision_id_index
    )
  end
end
