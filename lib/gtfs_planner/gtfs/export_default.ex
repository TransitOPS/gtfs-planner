defmodule GtfsPlanner.Gtfs.ExportDefault do
  @moduledoc """
  Organization-scoped default settings applied to new GTFS export runs.

  One row is stored per organization. An organization with no row uses the
  defaults `include_flex: true` and `realtime_source: :unsure`, which
  `GtfsPlanner.Gtfs.ExportDefaults.get/1` returns without inserting.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GtfsPlanner.Organizations.Organization

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @realtime_sources [:main, :flex, :own, :none, :unsure]
  @realtime_source_message "Choose one of the listed realtime sources."

  schema "export_defaults" do
    field :include_flex, :boolean, default: true
    field :realtime_source, Ecto.Enum, values: @realtime_sources, default: :unsure

    belongs_to :organization, Organization, foreign_key: :organization_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          organization_id: Ecto.UUID.t() | nil,
          include_flex: boolean(),
          realtime_source: :main | :flex | :own | :none | :unsure,
          organization: Organization.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "The realtime sources the settings page may choose from."
  @spec realtime_sources() :: [:main | :flex | :own | :none | :unsure]
  def realtime_sources, do: @realtime_sources

  @doc """
  Changeset for an organization's export defaults.

  Only the two settings are cast, so `organization_id` in submitted parameters
  is ignored; the caller sets it on the struct. The database check constraint is
  the second guard for a writer that bypasses `Ecto.Enum`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(export_default, attrs) do
    export_default
    |> cast(attrs, [:include_flex, :realtime_source])
    |> validate_required([:include_flex, :realtime_source])
    |> check_constraint(:realtime_source,
      name: :realtime_source,
      message: @realtime_source_message
    )
  end
end
