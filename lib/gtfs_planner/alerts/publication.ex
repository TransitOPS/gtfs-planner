defmodule GtfsPlanner.Alerts.Publication do
  @moduledoc """
  One alert's public intent, stored in `alert_publications`.

  A row exists only after an editor explicitly accepted a revision for
  publication, and it belongs to the same organization as its alert through the
  composite `alert_publications_alert_owner_fkey`. It keeps the newest desired
  intent and the last content a served manifest actually included, which is what
  makes the difference between "asked for" and "published" observable; it is not
  a public history, so one alert has exactly one row for its organization.

  Every field is server-owned. The actor and the timestamps record who asked and
  when, so an audit value outlives a user the organization later removes, and no
  client, form param or prepared assistant change writes this row: the `Alerts`
  commands of the accepted-content step own `desired_revision`,
  `desired_snapshot`, `confirmed_revision`, `confirmed_snapshot` and
  `withdrawal`, and the serving steps own `last_published_at` from an observed
  receipt.
  """

  use Ecto.Schema

  alias GtfsPlanner.Alerts.Alert

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # `none` is a draft with no removal requested. `pending` is a confirmed removal
  # the served manifest has not applied yet, so a disable/delete/re-enable cycle
  # cannot resurrect the alert while a refresh is still owed.
  @withdrawals [:none, :pending]

  schema "alert_publications" do
    field :desired_revision, :integer
    field :desired_snapshot, :map
    field :confirmed_revision, :integer
    field :confirmed_snapshot, :map
    field :requested_by_id, Ecto.UUID
    field :requested_at, :utc_datetime_usec
    field :last_published_at, :utc_datetime_usec
    field :withdrawal, Ecto.Enum, values: @withdrawals, default: :none

    belongs_to :organization, GtfsPlanner.Organizations.Organization
    belongs_to :alert, Alert

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          organization_id: Ecto.UUID.t() | nil,
          alert_id: Ecto.UUID.t() | nil,
          desired_revision: integer() | nil,
          desired_snapshot: map() | nil,
          confirmed_revision: integer() | nil,
          confirmed_snapshot: map() | nil,
          requested_by_id: Ecto.UUID.t() | nil,
          requested_at: DateTime.t() | nil,
          last_published_at: DateTime.t() | nil,
          withdrawal: :none | :pending | nil,
          organization:
            GtfsPlanner.Organizations.Organization.t() | Ecto.Association.NotLoaded.t(),
          alert: Alert.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  Lists the stored withdrawal states.

  `none` and `pending` are the two values the table's own check constraint
  accepts; the states a served manifest reaches from them are derived from the
  confirmed snapshot and the receipts, never stored here.
  """
  @spec withdrawals() :: [atom()]
  def withdrawals, do: @withdrawals
end
