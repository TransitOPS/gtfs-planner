defmodule GtfsPlanner.Validations.WalkabilityTestRunResult do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ["passed", "failed"]
  @failure_categories ["query_failure", "scoring_failure"]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          validation_run_id: Ecto.UUID.t(),
          walkability_test_id: Ecto.UUID.t(),
          order_index: non_neg_integer(),
          status: String.t(),
          failure_category: String.t() | nil,
          route_exists: boolean() | nil,
          duration_seconds: float() | nil,
          distance_meters: float() | nil,
          wheelchair_route_exists: boolean() | nil,
          wheelchair_duration_seconds: float() | nil,
          wheelchair_distance_meters: float() | nil,
          details_json: map() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "walkability_test_run_results" do
    field :order_index, :integer
    field :status, :string
    field :failure_category, :string

    field :route_exists, :boolean
    field :duration_seconds, :float
    field :distance_meters, :float

    field :wheelchair_route_exists, :boolean
    field :wheelchair_duration_seconds, :float
    field :wheelchair_distance_meters, :float

    field :details_json, :map

    belongs_to :validation_run, GtfsPlanner.Validations.ValidationRun
    belongs_to :walkability_test, GtfsPlanner.Validations.WalkabilityTest

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(result, attrs) do
    result
    |> cast(attrs, [
      :validation_run_id,
      :walkability_test_id,
      :order_index,
      :status,
      :failure_category,
      :route_exists,
      :duration_seconds,
      :distance_meters,
      :wheelchair_route_exists,
      :wheelchair_duration_seconds,
      :wheelchair_distance_meters,
      :details_json
    ])
    |> validate_required([:validation_run_id, :walkability_test_id, :order_index, :status])
    |> validate_number(:order_index, greater_than_or_equal_to: 0)
    |> validate_inclusion(:status, @statuses)
    |> validate_failure_category()
    |> foreign_key_constraint(:validation_run_id)
    |> foreign_key_constraint(:walkability_test_id)
    |> unique_constraint(:walkability_test_id,
      name: :walkability_test_run_results_run_case_unique_index
    )
    |> unique_constraint(:order_index,
      name: :walkability_test_run_results_run_order_unique_index
    )
  end

  defp validate_failure_category(changeset) do
    case get_field(changeset, :failure_category) do
      nil -> changeset
      _category -> validate_inclusion(changeset, :failure_category, @failure_categories)
    end
  end
end
