defmodule GtfsPlanner.Gtfs.Runs do
  @moduledoc """
  Scoped reads and writes for the Runs page.

  This module is the only reader and writer of `trip_runs` and of the five crew
  columns on `blocking_settings`; the page, the plan and the export reach them
  through `Gtfs` facade functions, so a crew rule has one home and a run
  assignment has one writer.

  The crew rules are the work rules a cut is judged against: how long an operator
  reports before a piece, how long a sign-off takes, how long a break may be and
  stay paid, and how long a spread may be. They are stored per published
  organization and version alongside spec 07's Block rules, on the same row, and
  each writer replaces only the columns it owns — a crew save cannot reset a
  minimum layover and a Block rules save cannot reset a crew rule (AC-1, FH-1).

  A version with no stored crew rules reads the researched defaults and writes
  nothing: a read never inserts a row.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @crew_defaults %{
    report_pull_out_minutes: 15,
    report_relief_minutes: 5,
    sign_off_minutes: 5,
    paid_break_max_minutes: 30,
    max_spread_minutes: 720
  }

  # The five crew columns plus the write timestamp: an upsert that replaced more
  # than these would reset the Block rules spec 07 stores on the same row, and one
  # that replaced fewer would leave a previous save's value behind (AC-1, FH-1).
  @replace_crew_columns BlockingSetting.crew_fields() ++ [:updated_at]

  @published_status "published"

  @type crew :: %{
          report_pull_out_minutes: 0..30,
          report_relief_minutes: 0..15,
          sign_off_minutes: 0..15,
          paid_break_max_minutes: 0..90,
          max_spread_minutes: 240..1080
        }

  @doc """
  Returns the crew rules for an organization's GTFS version.

  A version with no stored row returns the researched defaults; the read never
  inserts one, so opening the Runs page cannot create a settings row as a side
  effect of looking at it.
  """
  @spec get_crew_settings(Ecto.UUID.t(), Ecto.UUID.t()) :: crew()
  def get_crew_settings(organization_id, gtfs_version_id) do
    case Repo.one(crew_query(organization_id, gtfs_version_id)) do
      nil -> @crew_defaults
      stored -> stored
    end
  end

  @doc """
  Returns the changeset rendered by the crew rules form.

  `crew` is a value map from `get_crew_settings/2` — or any partial map, which is
  filled from the defaults — and `attrs` are the submitted parameters; an invalid
  value carries the field error.
  """
  @spec change_crew_settings(crew(), map()) :: Ecto.Changeset.t()
  def change_crew_settings(crew, attrs) do
    # The defaults fill in what the caller did not supply, so the merge runs the
    # other way round: merging the defaults over the given crew would replace every
    # value the caller read with a default and the form could never show a stored
    # value.
    values = @crew_defaults |> Map.merge(crew) |> Map.take(BlockingSetting.crew_fields())

    %BlockingSetting{}
    |> Ecto.Changeset.change(values)
    |> BlockingSetting.crew_changeset(attrs)
  end

  @doc """
  Stores the crew rules for one organization's published version.

  The save runs in one transaction whose first statement is the scoped version row
  `FOR SHARE` (`Versions.lock_for_input_write!/2`), so the rules a review loaded
  cannot change under a calendar combination that owns the version, and this save
  waits behind such an owner in turn. It then takes `Blocking.lock_blocking!/1`, so
  a crew save serializes with every other planning-input writer and cannot slip
  between a plan's review and its apply (INV-1, INV-7, rule 13).

  The upsert replaces only the five crew columns and the write timestamp. Its base
  carries the stored Block rules values, so a first save on a version with no row
  satisfies the columns spec 07 owns rather than inserting defaults over them.

  Returns `{:error, :not_found}` when the version is unpublished or belongs to
  another organization, and `{:error, changeset}` when a value is outside its range
  or blank, in which case nothing is written.
  """
  @spec update_crew_settings(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, crew()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_crew_settings(organization_id, gtfs_version_id, attrs) do
    case Repo.transaction(fn -> write_crew_settings!(organization_id, gtfs_version_id, attrs) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  # The version share lock is the first statement of the write transaction, before
  # the published check and the upsert, and `lock_blocking!/1` follows it and
  # nothing else, in INV-1's order, so this writer joins the same serialization
  # point as the block writers instead of taking a second runs lock.
  defp write_crew_settings!(organization_id, gtfs_version_id, attrs) do
    version = Versions.lock_for_input_write!(organization_id, gtfs_version_id)

    if version.publication_status == @published_status do
      :ok = Blocking.lock_blocking!(gtfs_version_id)

      # The stored row is the base rather than a bare struct, so the eight columns
      # this writer does not own are present and satisfy the insert of the version's
      # first row; the upsert then replaces only the crew columns, so writing a
      # crew rule cannot blank a stored layover, interlining rule or piece limit.
      stored = Blocking.get_settings(organization_id, gtfs_version_id)

      changeset =
        %BlockingSetting{organization_id: organization_id, gtfs_version_id: gtfs_version_id}
        |> Ecto.Changeset.change(Map.take(stored, BlockingSetting.settings_fields()))
        |> BlockingSetting.crew_changeset(attrs)

      case Repo.insert(changeset,
             on_conflict: {:replace, @replace_crew_columns},
             conflict_target: [:organization_id, :gtfs_version_id]
           ) do
        {:ok, saved} -> {:ok, crew_values(saved)}
        # Nothing has been written yet, so the transaction commits this result and
        # still leaves the stored row exactly as the previous save left it.
        {:error, invalid} -> {:error, invalid}
      end
    else
      # The shared lock takes no publication stance, so the published requirement
      # stays here, exactly as `Blocking`'s own settings writer applies it.
      {:error, :not_found}
    end
  end

  # Only the five crew columns, in the shape `get_crew_settings/2` answers with, so
  # a caller never has to know the row also carries the Block rules.
  defp crew_values(setting) do
    Map.new(BlockingSetting.crew_fields(), &{&1, Map.fetch!(setting, &1)})
  end

  # Scoped by organization and version like every other read here, and selecting
  # only the crew columns: a caller cannot learn a Block rules value through the
  # crew reader, and the Block rules reader cannot learn a crew value.
  defp crew_query(organization_id, gtfs_version_id) do
    from(s in BlockingSetting,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
      select: %{
        report_pull_out_minutes: s.report_pull_out_minutes,
        report_relief_minutes: s.report_relief_minutes,
        sign_off_minutes: s.sign_off_minutes,
        paid_break_max_minutes: s.paid_break_max_minutes,
        max_spread_minutes: s.max_spread_minutes
      }
    )
  end
end
