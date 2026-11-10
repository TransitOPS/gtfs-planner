defmodule GtfsPlanner.Gtfs.Pathway do
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  alias GtfsPlanner.Gtfs.Graph

  @pathway_modes %{
    walkway: 1,
    stairs: 2,
    moving_sidewalk: 3,
    escalator: 4,
    elevator: 5,
    fare_gate: 6,
    exit_gate: 7
  }

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          lock_version: pos_integer(),
          pathway_id: String.t(),
          pathway_mode: integer(),
          is_bidirectional: boolean(),
          traversal_time: integer() | nil,
          length: Decimal.t() | nil,
          stair_count: integer() | nil,
          max_slope: Decimal.t() | nil,
          min_width: Decimal.t() | nil,
          signposted_as: String.t() | nil,
          reversed_signposted_as: String.t() | nil,
          field_notes: String.t() | nil,
          field_completed_at: DateTime.t() | nil,
          from_stop_id: String.t(),
          to_stop_id: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "pathways" do
    field :lock_version, :integer, default: 1, read_after_writes: true
    field :pathway_id, :string
    field :pathway_mode, :integer
    field :is_bidirectional, :boolean, default: true
    field :traversal_time, :integer
    field :length, :decimal
    field :stair_count, :integer
    field :max_slope, :decimal
    field :min_width, :decimal
    field :signposted_as, :string
    field :reversed_signposted_as, :string
    field :field_notes, :string
    field :field_completed_at, :utc_datetime_usec

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion

    field :from_stop_id, :string
    field :to_stop_id, :string

    field :from_stop, :map, virtual: true
    field :to_stop, :map, virtual: true

    timestamps(type: :utc_datetime_usec)
  end

  def pathway_modes, do: @pathway_modes

  # Limits from the ADA Standards. A ramp may be no steeper than 1:12 (0.0833),
  # so the boundary sits just above it and a ramp recorded as 0.083 or 0.0833
  # passes. An opening must be 32 inches (0.8128 m) clear, which the editor
  # stores as 0.81.
  @max_step_free_slope Decimal.new("0.0834")
  @min_step_free_width Decimal.new("0.81")

  @doc """
  Classifies a pathway for the floorplan's step-free view.

    * `:not_step_free` - stairs or an escalator
    * `:barrier` - a step-free type recorded as too steep or too narrow
    * `:step_free` - any other step-free type; blank measurements pass

  Returns `nil` for a `pathway_mode` outside 1..7. The type test is
  `GtfsPlanner.Gtfs.Graph.step_free_mode?/1`, the one the station reports use.
  """
  @spec step_free_state(map()) :: :step_free | :barrier | :not_step_free | nil
  def step_free_state(%{pathway_mode: mode} = pathway) when mode in 1..7 do
    cond do
      not Graph.step_free_mode?(mode) -> :not_step_free
      step_free_barriers(pathway) != [] -> :barrier
      true -> :step_free
    end
  end

  def step_free_state(_pathway), do: nil

  @doc """
  The measurements that stop a wheelchair on a step-free type: `:slope` when the
  absolute `max_slope` is steeper than a 1:12 ramp, `:width` when `min_width` is
  under 0.81 m. Blank, zero and non-decimal values are not barriers.
  """
  @spec step_free_barriers(map()) :: [:slope | :width]
  def step_free_barriers(pathway) do
    slope = Map.get(pathway, :max_slope)
    width = Map.get(pathway, :min_width)

    Enum.filter([:slope, :width], fn
      :slope ->
        match?(%Decimal{}, slope) and Decimal.gt?(Decimal.abs(slope), @max_step_free_slope)

      :width ->
        match?(%Decimal{}, width) and Decimal.positive?(width) and
          Decimal.lt?(width, @min_step_free_width)
    end)
  end

  def mode_label(mode) do
    case mode do
      1 -> "Walkway"
      2 -> "Stairs"
      3 -> "Moving Sidewalk"
      4 -> "Escalator"
      5 -> "Elevator"
      6 -> "Fare Gate"
      7 -> "Exit Gate"
      _ -> "Unknown"
    end
  end

  @editor_fields [
    :pathway_mode,
    :is_bidirectional,
    :traversal_time,
    :length,
    :stair_count,
    :max_slope,
    :min_width,
    :signposted_as,
    :reversed_signposted_as,
    :field_notes,
    :field_completed_at,
    :from_stop_id,
    :to_stop_id
  ]

  @doc "Validates fields editable from the station editor without casting ownership or revision."
  def editor_changeset(pathway, attrs) do
    pathway |> base_changeset(attrs, @editor_fields) |> validate_slope_ratio()
  end

  @doc "Creates an editor pathway with ownership supplied by the selected scope."
  def create_changeset(%__MODULE__{} = pathway, attrs, %{
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id
      }) do
    %{pathway | organization_id: organization_id, gtfs_version_id: gtfs_version_id}
    |> base_changeset(attrs, [:pathway_id | @editor_fields])
    |> validate_slope_ratio()
  end

  def changeset(pathway, attrs) do
    base_changeset(
      pathway,
      attrs,
      [:pathway_id | @editor_fields] ++ [:organization_id, :gtfs_version_id]
    )
  end

  # A slope entered in the editor is a ratio, so a percentage typed by mistake
  # (8.3 for 0.083) is refused here instead of overflowing the column. Imports
  # keep whatever the feed holds: only a changed value is checked.
  defp validate_slope_ratio(changeset) do
    validate_number(changeset, :max_slope,
      greater_than_or_equal_to: -1,
      less_than_or_equal_to: 1,
      message: "must be a ratio between -1 and 1, such as 0.083 for a 1:12 ramp"
    )
  end

  defp base_changeset(pathway, attrs, fields) do
    pathway
    |> cast(attrs, fields)
    |> trim_string_fields()
    |> validate_required([
      :pathway_id,
      :pathway_mode,
      :organization_id,
      :gtfs_version_id,
      :from_stop_id,
      :to_stop_id
    ])
    |> validate_inclusion(:pathway_mode, 1..7)
    |> force_exit_gate_one_way()
    |> unique_constraint([:organization_id, :gtfs_version_id, :pathway_id])
    |> foreign_key_constraint(:organization_id)
  end

  # GTFS requires exit gates (pathway_mode 7) to be one-way. Forcing the value
  # instead of adding an error keeps the editor form, which disables the
  # control for exit gates, from getting stuck on an error the user cannot fix.
  defp force_exit_gate_one_way(changeset) do
    if get_field(changeset, :pathway_mode) == @pathway_modes.exit_gate do
      put_change(changeset, :is_bidirectional, false)
    else
      changeset
    end
  end
end
