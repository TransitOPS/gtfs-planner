defmodule GtfsPlanner.Agents.UsageCounter do
  @moduledoc "A persisted daily provider-attempt count for an organization or actor."

  use Ecto.Schema

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
end
