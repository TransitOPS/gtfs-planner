defmodule GtfsPlanner.Gtfs.BlockingSetting do
  @moduledoc """
  Schema for the per-version blocking settings used by the Blocks page.

  One row is stored per organization and GTFS version; a version with no row
  uses the defaults (5 minutes minimum layover, no block-length or piece limits,
  0 minutes pull-out buffer, any interlining, no default garage, 30 km/h estimated
  deadhead speed at 1.3 circuity). `changeset/2` casts and range-checks all eight
  settings, and the reader in `GtfsPlanner.Gtfs.Blocking` owns the default map.

  The five crew columns on the same row — `report_pull_out_minutes`,
  `report_relief_minutes`, `sign_off_minutes`, `paid_break_max_minutes` and
  `max_spread_minutes` — are the crew rules, and are deliberately not part of
  `settings_fields/0` or `changeset/2`: `GtfsPlanner.Gtfs.Runs` owns them through
  its own `crew_fields/0` and `crew_changeset/2`, so a Block rules save never
  rewrites a crew rule and a crew save never rewrites a Block rule.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "blocking_settings" do
    field :min_layover_minutes, :integer, default: 5
    field :max_block_minutes, :integer
    field :pull_out_buffer_minutes, :integer, default: 0
    field :interlining, Ecto.Enum, values: [:any, :same_stop, :none], default: :any
    field :deadhead_speed_kmh, :integer, default: 30
    field :deadhead_circuity, :decimal, default: Decimal.new("1.3")
    field :max_piece_minutes, :integer
    field :report_pull_out_minutes, :integer, default: 15
    field :report_relief_minutes, :integer, default: 5
    field :sign_off_minutes, :integer, default: 5
    field :paid_break_max_minutes, :integer, default: 30
    field :max_spread_minutes, :integer, default: 720

    belongs_to :default_garage, GtfsPlanner.Operations.Garage

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          min_layover_minutes: integer(),
          max_block_minutes: integer() | nil,
          pull_out_buffer_minutes: integer(),
          interlining: :any | :same_stop | :none,
          default_garage_id: Ecto.UUID.t() | nil,
          deadhead_speed_kmh: integer(),
          deadhead_circuity: Decimal.t(),
          max_piece_minutes: integer() | nil,
          report_pull_out_minutes: integer(),
          report_relief_minutes: integer(),
          sign_off_minutes: integer(),
          paid_break_max_minutes: integer(),
          max_spread_minutes: integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  # The five crew columns, as the one list the crew writer replaces. It sits with
  # the schema rather than beside the writer so `crew_fields/0` and
  # `crew_changeset/2` cannot drift apart.
  @crew_fields [
    :report_pull_out_minutes,
    :report_relief_minutes,
    :sign_off_minutes,
    :paid_break_max_minutes,
    :max_spread_minutes
  ]

  @doc """
  The five crew rules, in the order the reader returns them.

  They are deliberately not part of `settings_fields/0`: this is the one list the
  crew writer replaces, and the eight Block rules above are the one list the Block
  rules writer replaces, so neither save can rewrite the other's columns.
  """
  @spec crew_fields() :: [atom()]
  def crew_fields, do: @crew_fields

  # A value that must always be submitted: a blank string is not a valid number
  # here, so it is left to `cast/4` as an "is invalid" field error rather than
  # becoming the default. `empty_values: []` keeps the blank out of `nil`, so a
  # cleared input reads as a mistake the user must fix and not as "unset" — a crew
  # rule has no unset state, only a range (CR-3).
  @doc """
  Changeset for the five crew rules.

  Only `crew_fields/0` is cast, so `organization_id` and `gtfs_version_id` in
  submitted parameters are ignored; the caller sets those on the struct. Every
  range from AC-1 is checked here and again by the named database constraint, so a
  value that reaches the table outside this changeset still cannot store.
  """
  @spec crew_changeset(t(), map()) :: Ecto.Changeset.t()
  def crew_changeset(setting, attrs) do
    setting
    |> cast(attrs, @crew_fields, empty_values: [])
    |> validate_required(@crew_fields)
    |> validate_number(:report_pull_out_minutes,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 30,
      message: "must be a whole number between 0 and 30"
    )
    |> validate_number(:report_relief_minutes,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 15,
      message: "must be a whole number between 0 and 15"
    )
    |> validate_number(:sign_off_minutes,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 15,
      message: "must be a whole number between 0 and 15"
    )
    |> validate_number(:paid_break_max_minutes,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 90,
      message: "must be a whole number between 0 and 90"
    )
    |> validate_number(:max_spread_minutes,
      greater_than_or_equal_to: 240,
      less_than_or_equal_to: 1080,
      message: "must be a whole number between 240 and 1080"
    )
    |> check_constraint(:report_pull_out_minutes,
      name: :report_pull_out_range,
      message: "must be a whole number between 0 and 30"
    )
    |> check_constraint(:report_relief_minutes,
      name: :report_relief_range,
      message: "must be a whole number between 0 and 15"
    )
    |> check_constraint(:sign_off_minutes,
      name: :sign_off_range,
      message: "must be a whole number between 0 and 15"
    )
    |> check_constraint(:paid_break_max_minutes,
      name: :paid_break_max_range,
      message: "must be a whole number between 0 and 90"
    )
    |> check_constraint(:max_spread_minutes,
      name: :max_spread_range,
      message: "must be a whole number between 240 and 1080"
    )
  end

  @doc """
  The eight Block rules settings, in the order the reader returns them.

  `organization_id` and `gtfs_version_id` are absent on purpose: they are set by
  the caller from its arguments and are never cast from submitted parameters.
  """
  @spec settings_fields() :: [atom()]
  def settings_fields do
    [
      :min_layover_minutes,
      :max_block_minutes,
      :pull_out_buffer_minutes,
      :interlining,
      :default_garage_id,
      :deadhead_speed_kmh,
      :deadhead_circuity,
      :max_piece_minutes
    ]
  end

  # A value that must always be submitted: a blank string is not a valid number or
  # enum member here, so it is left to `cast/4` as an "is invalid" field error
  # rather than becoming the default.
  @required_fields [
    :min_layover_minutes,
    :pull_out_buffer_minutes,
    :interlining,
    :deadhead_speed_kmh,
    :deadhead_circuity
  ]

  # The optional settings: a blank input means "unset" or "no limit", so they cast to
  # `nil` through Ecto's default `empty_values` and store NULL.
  @optional_fields [:max_block_minutes, :default_garage_id, :max_piece_minutes]

  @interlining_values [:any, :same_stop, :none]

  @doc """
  Changeset for the eight Block rules settings.

  Only `settings_fields/0` is cast, so `organization_id` and `gtfs_version_id` in
  submitted parameters are ignored; the caller sets those on the struct. Every
  range is checked here and again by the named database constraint, so a
  value that reaches the table outside this changeset still cannot store.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, @required_fields, empty_values: [])
    |> cast(attrs, @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:min_layover_minutes,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 120,
      message: "must be a whole number between 0 and 120"
    )
    |> validate_number(:max_block_minutes,
      greater_than_or_equal_to: 60,
      less_than_or_equal_to: 1440,
      message: "must be a whole number between 60 and 1440, or left blank"
    )
    |> validate_number(:pull_out_buffer_minutes,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 60,
      message: "must be a whole number between 0 and 60"
    )
    |> validate_inclusion(:interlining, @interlining_values)
    |> validate_number(:deadhead_speed_kmh,
      greater_than_or_equal_to: 5,
      less_than_or_equal_to: 120,
      message: "must be a whole number between 5 and 120"
    )
    |> validate_number(:deadhead_circuity,
      greater_than_or_equal_to: 1.0,
      less_than_or_equal_to: 3.0,
      message: "must be a number between 1.0 and 3.0"
    )
    |> validate_number(:max_piece_minutes,
      greater_than_or_equal_to: 60,
      less_than_or_equal_to: 720,
      message: "must be a whole number between 60 and 720, or left blank"
    )
    |> check_constraint(:min_layover_minutes,
      name: :min_layover_range,
      message: "must be a whole number between 0 and 120"
    )
    |> check_constraint(:max_block_minutes,
      name: :max_block_minutes_range,
      message: "must be a whole number between 60 and 1440, or left blank"
    )
    |> check_constraint(:pull_out_buffer_minutes,
      name: :pull_out_buffer_range,
      message: "must be a whole number between 0 and 60"
    )
    |> check_constraint(:interlining,
      name: :interlining_values,
      message: "must be one of any, same_stop or none"
    )
    |> check_constraint(:deadhead_speed_kmh,
      name: :deadhead_speed_range,
      message: "must be a whole number between 5 and 120"
    )
    |> check_constraint(:deadhead_circuity,
      name: :deadhead_circuity_range,
      message: "must be a number between 1.0 and 3.0"
    )
    |> check_constraint(:max_piece_minutes,
      name: :max_piece_minutes_range,
      message: "must be a whole number between 60 and 720, or left blank"
    )
    |> foreign_key_constraint(:default_garage_id)
  end
end
