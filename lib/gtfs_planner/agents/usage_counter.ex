defmodule GtfsPlanner.Agents.UsageCounter do
  @moduledoc "A persisted daily provider-attempt count for an organization or actor."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_usage_counters" do
    belongs_to :organization, GtfsPlanner.Organizations.Organization
    field :scope_key, :string
    field :day, :date
    field :attempts, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          organization_id: Ecto.UUID.t() | nil,
          scope_key: String.t() | nil,
          day: Date.t() | nil,
          attempts: non_neg_integer(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  def changeset(counter, attrs) do
    counter
    |> cast(attrs, [:organization_id, :scope_key, :day])
    |> validate_required([:organization_id, :scope_key, :day])
    |> foreign_key_constraint(:organization_id)
    |> unique_constraint([:organization_id, :scope_key, :day],
      name: :agent_usage_counters_org_scope_day_index
    )
    |> check_constraint(:attempts, name: :agent_usage_counters_attempts_check)
  end
end
