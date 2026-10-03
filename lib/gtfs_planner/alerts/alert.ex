defmodule GtfsPlanner.Alerts.Alert do
  @moduledoc """
  One service alert draft, owned by the organization that wrote it.

  The row stores authoring intent, not compiled GTFS-Realtime output: `scope`,
  `timing` and `message` are the operator's own answers in the three embedded
  schemas, and `effect` and the derived dates are set by the `Alerts` commands
  rather than by the editor (R3).

  `source_gtfs_version_id` is optional provenance, not ownership: the alert
  belongs to `organization_id` and survives the deletion of the version it was
  written against. `target_reference` is the server-owned capture of the trusted
  wire IDs and labels those answers resolved to, so a source
  version can disappear without the alert losing its published identity, and an
  identity that no longer resolves is recorded as unresolved rather than
  replaced by a guess.

  Identity, `revision`, `complete`, `effect`, `first_date` and `last_date`,
  `target_reference`, `public_entity_id` and `deleted_at` are server-owned.
  `draft_changeset/2` never casts them, so a form param or a prepared assistant
  change cannot move an alert to another tenant, claim a revision, mark itself
  finished, write an effect the completion rules did not derive, or hand itself
  a public identity (R4, CR-2).

  The embedded answers store civil dates and times with the version's zone name;
  nothing in this schema converts between zones (R12, CR-7). `timezone` is the
  alert's own retained zone, which is NULL when the source had no single usable
  agency zone: publication then requires an explicit organization zone instead
  of inheriting the disclosed display fallback.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GtfsPlanner.Alerts.MessageAnswer
  alias GtfsPlanner.Alerts.ScopeAnswer
  alias GtfsPlanner.Alerts.TimingAnswer
  alias GtfsPlanner.ChangesetHelpers

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @urgencies [:now, :planned]
  @situations [
    :delay,
    :detour,
    :stop_moved,
    :stop_closed,
    :cancelled_trips,
    :accessibility,
    :suspension,
    :service_change
  ]
  @service_change_kinds [:fewer_trips, :extra_service, :information]
  @effects [
    :no_service,
    :reduced_service,
    :significant_delays,
    :detour,
    :additional_service,
    :modified_service,
    :other_effect,
    :unknown_effect,
    :stop_moved,
    :no_effect,
    :accessibility_issue
  ]
  # The 13 GTFS-RT Cause values, including :special_event added in June 2026.
  @causes [
    :unknown_cause,
    :other_cause,
    :technical_problem,
    :strike,
    :demonstration,
    :accident,
    :holiday,
    :weather,
    :maintenance,
    :construction,
    :police_activity,
    :medical_emergency,
    :special_event
  ]

  @max_cause_detail_length 200

  @draft_fields [:urgency, :situation, :service_change_kind, :cause, :cause_detail]

  schema "service_alerts" do
    field :revision, :integer, default: 1
    field :urgency, Ecto.Enum, values: @urgencies
    field :situation, Ecto.Enum, values: @situations
    field :service_change_kind, Ecto.Enum, values: @service_change_kinds
    field :effect, Ecto.Enum, values: @effects
    field :cause, Ecto.Enum, values: @causes
    field :cause_detail, :string
    field :complete, :boolean, default: false
    field :first_date, :date
    field :last_date, :date

    # The trusted capture of the scope answer's resolved identities, owned by the
    # `Alerts` commands and never cast from operator input.
    field :target_reference, :map, default: %{}
    field :timezone, :string
    field :deleted_at, :utc_datetime_usec
    field :public_entity_id, Ecto.UUID

    embeds_one :scope, ScopeAnswer, on_replace: :update
    embeds_one :timing, TimingAnswer, on_replace: :update
    embeds_one :message, MessageAnswer, on_replace: :update

    belongs_to :organization, GtfsPlanner.Organizations.Organization
    belongs_to :source_gtfs_version, GtfsPlanner.Versions.GtfsVersion
    belongs_to :created_by, GtfsPlanner.Accounts.User
    belongs_to :updated_by, GtfsPlanner.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          organization_id: Ecto.UUID.t() | nil,
          source_gtfs_version_id: Ecto.UUID.t() | nil,
          revision: integer() | nil,
          urgency: :now | :planned | nil,
          situation:
            :delay
            | :detour
            | :stop_moved
            | :stop_closed
            | :cancelled_trips
            | :accessibility
            | :suspension
            | :service_change
            | nil,
          service_change_kind: :fewer_trips | :extra_service | :information | nil,
          effect:
            :no_service
            | :reduced_service
            | :significant_delays
            | :detour
            | :additional_service
            | :modified_service
            | :other_effect
            | :unknown_effect
            | :stop_moved
            | :no_effect
            | :accessibility_issue
            | nil,
          cause: atom() | nil,
          cause_detail: String.t() | nil,
          complete: boolean() | nil,
          first_date: Date.t() | nil,
          last_date: Date.t() | nil,
          scope: ScopeAnswer.t() | nil,
          timing: TimingAnswer.t() | nil,
          message: MessageAnswer.t() | nil,
          target_reference: map(),
          timezone: String.t() | nil,
          deleted_at: DateTime.t() | nil,
          public_entity_id: Ecto.UUID.t() | nil,
          organization:
            GtfsPlanner.Organizations.Organization.t() | Ecto.Association.NotLoaded.t(),
          source_gtfs_version:
            GtfsPlanner.Versions.GtfsVersion.t() | Ecto.Association.NotLoaded.t() | nil,
          created_by: GtfsPlanner.Accounts.User.t() | Ecto.Association.NotLoaded.t() | nil,
          updated_by: GtfsPlanner.Accounts.User.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  Lists the situations an alert can be about.

  The same list orders `AlertScript.situation`, so a script is matched against an
  alert's situation with one vocabulary rather than two that can drift.
  """
  @spec situations() :: [atom()]
  def situations, do: @situations

  @doc """
  Lists the effects the completion rules derive, which are also the values the
  public feed's GTFS-RT `Effect` enum accepts.
  """
  @spec effects() :: [atom()]
  def effects, do: @effects

  @doc """
  Lists the causes an alert may state, which are also the values the public
  feed's GTFS-RT `Cause` enum accepts.
  """
  @spec causes() :: [atom()]
  def causes, do: @causes

  @doc """
  Creates the changeset the editor autosaves and the review step saves.

  Casts only the operator's own fields, then each embedded answer through its own
  changeset. Nothing is required, because a draft is saved at every step and
  completeness is a separate derivation. Identity, `revision`, `complete`,
  `effect`, the derived dates, `target_reference` and `public_entity_id` are
  never cast, so they keep the values the `Alerts` commands own.
  """
  @spec draft_changeset(t(), map()) :: Ecto.Changeset.t()
  def draft_changeset(alert, attrs) do
    alert
    |> cast(attrs, @draft_fields)
    |> ChangesetHelpers.trim_string_fields()
    |> validate_length(:cause_detail, max: @max_cause_detail_length)
    |> cast_embed(:scope, with: &ScopeAnswer.changeset/2)
    |> cast_embed(:timing, with: &TimingAnswer.changeset/2)
    |> cast_embed(:message, with: &MessageAnswer.changeset/2)
  end
end
