defmodule GtfsPlanner.Operations.Operator do
  @moduledoc """
  An organization-wide operator.

  An operator belongs to exactly one organization and ignores GTFS versions: its
  UUID is its identity and `employee_id` is a correctable external ID that is
  unique within the organization. Only the three business fields are personal
  data: `employee_id`, `display_name` and the optional `seniority_number`, which
  orders lists and nothing else. `organization_id` and `updated_by_id` are set
  programmatically and are never cast from user params.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          employee_id: String.t(),
          display_name: String.t(),
          seniority_number: pos_integer() | nil,
          updated_by_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "operators" do
    field :employee_id, :string
    field :display_name, :string
    field :seniority_number, :integer
    field :updated_by_id, :binary_id

    belongs_to :organization, GtfsPlanner.Organizations.Organization

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  A changeset for creating and updating an operator.

  Casts only the user-editable fields. `organization_id` and `updated_by_id` are
  assigned by `GtfsPlanner.Operations`.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(operator, attrs) do
    operator
    |> cast(attrs, [:employee_id, :display_name, :seniority_number])
    |> trim_string_fields()
    |> validate_required([:employee_id, :display_name])
    |> validate_length(:employee_id, min: 1, max: 64)
    |> validate_length(:display_name, min: 1, max: 120)
    |> validate_number(:seniority_number,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 99_999
    )
    |> unique_constraint(:employee_id, name: :operators_organization_id_employee_id_index)
    |> check_constraint(:seniority_number, name: :seniority_number_range)
  end
end
