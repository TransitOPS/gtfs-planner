defmodule GtfsPlanner.Repo.Migrations.CreateFeedPublications do
  use Ecto.Migration

  def change do
    # The permanent public prefix an organization claimed once. Every table below
    # references `organizations` with ON DELETE RESTRICT: a claimed namespace
    # outlives the organization's own rows and blocks destructive teardown until
    # an operator withdraws the publication under separate authority.
    create table(:feed_publication_namespaces, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :restrict),
        null: false

      add :prefix, :string, null: false
      add :public_claim, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # A first claim is decided by these unique indexes, not by application code:
    # two concurrent claims of one organization, or of one prefix, resolve to one
    # winner in the database.
    create unique_index(:feed_publication_namespaces, [:organization_id])
    create unique_index(:feed_publication_namespaces, [:prefix])
    create unique_index(:feed_publication_namespaces, [:public_claim])
    create unique_index(:feed_publication_namespaces, [:id, :organization_id])

    create constraint(:feed_publication_namespaces, :feed_publication_namespaces_prefix_length,
             check: "char_length(prefix) <= 255"
           )

    create table(:feed_publications, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :restrict),
        null: false

      add :namespace_id, references(:feed_publication_namespaces, type: :binary_id), null: false

      add :channel, :string, null: false

      add :desired_revision, :bigint, null: false, default: 0
      add :next_sequence, :bigint, null: false, default: 1

      # The attempt this channel currently points at. Added as a plain column and
      # constrained below, because a composite tenant-correct foreign key cannot be
      # expressed reversibly with `references/2` inside `alter/3`.
      add :active_attempt_id, :binary_id

      # Receipts observed from the served manifest, never from a local assumption.
      add :manifest_bytes, :binary
      add :manifest_sha256, :string
      add :manifest_etag, :string
      add :manifest_generation, :string
      add :manifest_sequence, :bigint
      add :manifest_last_modified, :utc_datetime_usec
      add :last_refresh_at, :utc_datetime_usec

      # `disabled` is derived locally from configuration and is never stored.
      add :status, :string, null: false, default: "never_published"
      add :next_retry_at, :utc_datetime_usec
      add :last_error, :text

      add :retired_through_sequence, :bigint, null: false, default: 0
      add :cleanup_cursor, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:feed_publications, [:organization_id, :channel])
    create unique_index(:feed_publications, [:id, :organization_id])
    create index(:feed_publications, [:namespace_id])

    create constraint(:feed_publications, :feed_publications_channel_known,
             check: "channel IN ('full', 'flex', 'pathways', 'alerts')"
           )

    create constraint(:feed_publications, :feed_publications_status_known,
             check:
               "status IN ('never_published', 'pending', 'staging', 'switching', " <>
                 "'reconciling', 'current', 'failed', 'blocked')"
           )

    create constraint(:feed_publications, :feed_publications_revision_positive,
             check: "desired_revision >= 0 and retired_through_sequence >= 0"
           )

    create table(:feed_publication_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :publication_id, references(:feed_publications, type: :binary_id, on_delete: :restrict),
        null: false

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :restrict),
        null: false

      add :sequence, :bigint, null: false
      add :generation, :string, null: false
      add :desired_revision, :bigint, null: false

      # The exact frozen public bytes and their hash. An attempt never changes
      # them, and never changes the predecessor condition recorded beside them.
      add :manifest_body, :binary, null: false
      add :manifest_sha256, :string, null: false
      add :predecessor_etag, :string

      add :object_receipts, :map, null: false, default: %{}
      add :private_snapshot, :map
      add :included_revisions, :map, null: false, default: %{}

      add :actor_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :provenance, :string

      add :lease_token, :string
      add :lease_expires_at, :utc_datetime_usec
      add :state, :string, null: false
      add :retired_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:feed_publication_attempts, [:publication_id, :sequence])
    create unique_index(:feed_publication_attempts, [:generation])
    create unique_index(:feed_publication_attempts, [:id, :organization_id])
    create index(:feed_publication_attempts, [:state])

    create constraint(:feed_publication_attempts, :feed_publication_attempts_sequence_positive,
             check: "sequence >= 1"
           )

    # A channel may only name a namespace and an attempt of its own organization,
    # and an attempt may only belong to a publication of its own organization.
    # These are `NO ACTION` like the existing `service_alerts` ownership key.
    execute(
      """
      ALTER TABLE #{qualified_table(:feed_publications)}
      ADD CONSTRAINT feed_publications_namespace_owner_fkey
      FOREIGN KEY (namespace_id, organization_id)
      REFERENCES #{qualified_table(:feed_publication_namespaces)} (id, organization_id)
      ON DELETE NO ACTION
      """,
      """
      ALTER TABLE #{qualified_table(:feed_publications)}
      DROP CONSTRAINT feed_publications_namespace_owner_fkey
      """
    )

    execute(
      """
      ALTER TABLE #{qualified_table(:feed_publication_attempts)}
      ADD CONSTRAINT feed_publication_attempts_publication_owner_fkey
      FOREIGN KEY (publication_id, organization_id)
      REFERENCES #{qualified_table(:feed_publications)} (id, organization_id)
      ON DELETE NO ACTION
      """,
      """
      ALTER TABLE #{qualified_table(:feed_publication_attempts)}
      DROP CONSTRAINT feed_publication_attempts_publication_owner_fkey
      """
    )

    execute(
      """
      ALTER TABLE #{qualified_table(:feed_publications)}
      ADD CONSTRAINT feed_publications_active_attempt_owner_fkey
      FOREIGN KEY (active_attempt_id, organization_id)
      REFERENCES #{qualified_table(:feed_publication_attempts)} (id, organization_id)
      ON DELETE NO ACTION
      """,
      """
      ALTER TABLE #{qualified_table(:feed_publications)}
      DROP CONSTRAINT feed_publications_active_attempt_owner_fkey
      """
    )
  end

  defp qualified_table(table) do
    case prefix() do
      nil -> Atom.to_string(table)
      schema -> ~s("#{String.replace(schema, "\"", "\"\"")}".#{table})
    end
  end
end
