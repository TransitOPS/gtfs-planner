defmodule GtfsPlanner.Gtfs.Export.PublicationPin do
  @moduledoc """
  A renewable lease on the private bytes of one ready export run.

  A publication pin is not a download claim: it never records a download, it
  only keeps the artifact file that a reviewed public generation is about to
  name from being removed. `ExportRuns.cleanup_expired/1` skips a pinned run, and
  the run's own `ON DELETE CASCADE` from its GTFS version cannot take the pinned
  file away while the pin exists.

  The pin is released once the remote payload receipt is durable; expiry and
  release are both required, so a crashed publisher can never pin a run forever.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GtfsPlanner.Organizations.Organization

  @slots [:main, :flex]
  @max_owner_length 255

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "feed_publication_pins" do
    field :slot, Ecto.Enum, values: @slots
    field :owner_id, :string
    field :pin_token, Ecto.UUID
    field :expires_at, :utc_datetime_usec
    belongs_to :export_run, GtfsPlanner.Gtfs.Export.Run
    belongs_to :organization, Organization
    timestamps(type: :utc_datetime_usec)
  end

  def slots, do: @slots

  @doc "No public params may alter a pin; every field is server-assigned."
  def changeset(pin, _attrs), do: change(pin)

  @doc false
  def system_changeset(pin, attrs) do
    pin
    |> cast(attrs, [:export_run_id, :organization_id, :slot, :owner_id, :pin_token, :expires_at])
    |> validate_required([:export_run_id, :organization_id, :slot, :owner_id, :pin_token])
    |> validate_required([:expires_at])
    |> validate_length(:owner_id, min: 1, max: @max_owner_length)
  end
end
