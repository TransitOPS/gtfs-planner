defmodule GtfsPlanner.Gtfs.Calendars.AuthorizationTest do
  use GtfsPlanner.DataCase

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = user_fixture()
    membership = organization_membership_fixture(actor, organization)

    %{
      organization: organization,
      version: version,
      actor: actor,
      membership: membership,
      audit: audit_context(organization, version, actor)
    }
  end

  test "an actor without a membership cannot create, duplicate, review or delete", context do
    outsider = user_fixture()
    audit = %{context.audit | actor_id: outsider.id, actor_email: outsider.email}

    assert {:error, :forbidden} = Gtfs.create_calendar(weekly_attrs(%{}), audit)
    assert {:error, :forbidden} = Gtfs.create_calendar(dates_attrs(%{}), audit)
    assert {:error, :forbidden} = Gtfs.duplicate_calendar("anything", %{}, audit)

    assert {:error, :forbidden} =
             Gtfs.review_calendar_change({:delete, "anything"}, %{"anything" => "token"}, audit)

    assert {:error, :forbidden} =
             Gtfs.apply_calendar_change({:delete, "anything"}, "token", audit)

    refute_any_calendar_rows(context)
  end

  test "a membership without the editor role cannot mutate", context do
    admin = user_fixture()
    organization_membership_fixture(admin, context.organization, ["pathways_studio_admin"])
    audit = %{context.audit | actor_id: admin.id, actor_email: admin.email}

    assert {:error, :forbidden} = Gtfs.create_calendar(weekly_attrs(%{}), audit)
    assert {:error, :forbidden} = Gtfs.duplicate_calendar("anything", %{}, audit)

    assert {:error, :forbidden} =
             Gtfs.review_calendar_change({:delete, "anything"}, %{"anything" => "token"}, audit)

    refute_any_calendar_rows(context)
  end

  test "a deactivated editor membership cannot mutate", context do
    deactivate_membership_fixture(context.membership)
    payload = insert_imported_calendar(context)

    assert {:error, :forbidden} = Gtfs.create_calendar(weekly_attrs(%{}), context.audit)

    assert {:error, :forbidden} =
             Gtfs.review_calendar_change(
               {:delete, "imported"},
               %{"imported" => payload.fingerprint},
               context.audit
             )

    assert {:error, :forbidden} =
             Gtfs.duplicate_calendar("imported", %{}, context.audit)

    assert Repo.exists?(
             from(c in Calendar,
               where: c.gtfs_version_id == ^context.version.id and c.service_id == "imported"
             )
           )
  end

  test "a membership revoked after review blocks the apply without writing", context do
    payload = create_editor_calendar(context, "revoked")

    assert {:ok, review} =
             Gtfs.review_calendar_change(
               {:delete, "revoked"},
               %{"revoked" => payload.fingerprint},
               context.audit
             )

    deactivate_membership_fixture(context.membership)

    assert {:error, :forbidden} =
             Gtfs.apply_calendar_change({:delete, "revoked"}, review.fingerprint, context.audit)

    assert table_present?(context, "revoked")
  end

  test "an actor's membership in another organization does not authorize this scope", context do
    other_organization = organization_fixture()
    other_actor = user_fixture()
    organization_membership_fixture(other_actor, other_organization)

    audit = %{
      context.audit
      | actor_id: other_actor.id,
        actor_email: other_actor.email
    }

    assert {:error, :forbidden} = Gtfs.create_calendar(weekly_attrs(%{}), audit)

    refute Repo.exists?(
             from(a in CalendarAttribute,
               where: a.organization_id == ^context.organization.id
             )
           )

    assert {:error, :forbidden} =
             Gtfs.review_calendar_change({:delete, "svc"}, %{"svc" => "token"}, audit)
  end

  test "foreign and invalid scopes return scoped errors without foreign data", context do
    other_organization = organization_fixture()
    other_version = gtfs_version_fixture(other_organization.id)
    calendar_fixture(other_organization.id, other_version.id, %{service_id: "foreign"})

    assert {:error, :not_found} =
             Gtfs.get_calendar(context.organization.id, other_version.id, "foreign")

    assert {:error, :not_found} =
             Gtfs.list_calendars(context.organization.id, other_version.id, [])

    assert {:error, :not_found} =
             Gtfs.calendar_usage(context.organization.id, other_version.id, "foreign")

    assert {:error, :not_found} =
             Gtfs.feed_service_gaps(context.organization.id, other_version.id, ~D[2026-01-01])

    invalid_organization = %{context.audit | organization_id: "not-a-uuid"}
    assert {:error, :forbidden} = Gtfs.create_calendar(weekly_attrs(%{}), invalid_organization)

    invalid_actor = %{context.audit | actor_id: "not-a-uuid"}
    assert {:error, :forbidden} = Gtfs.create_calendar(weekly_attrs(%{}), invalid_actor)

    invalid_version = %{context.audit | gtfs_version_id: "not-a-uuid"}

    assert {:error, :not_found} = Gtfs.create_calendar(weekly_attrs(%{}), invalid_version)

    assert {:error, :not_found} =
             Gtfs.review_calendar_change({:delete, "svc"}, %{"svc" => "token"}, invalid_version)
  end

  test "an unpublished version cannot be read or mutated", context do
    {:ok, staging} =
      Versions.create_staging_gtfs_version(context.organization.id, %{name: "Staging"})

    audit = %{context.audit | gtfs_version_id: staging.id}

    assert {:error, :not_found} = Gtfs.create_calendar(weekly_attrs(%{}), audit)

    assert {:error, :not_found} =
             Gtfs.review_calendar_change({:delete, "svc"}, %{"svc" => "token"}, audit)

    assert {:error, :not_found} =
             Gtfs.apply_calendar_change({:delete, "svc"}, "token", audit)

    assert {:error, :not_found} =
             Gtfs.list_calendars(context.organization.id, staging.id, [])

    assert {:error, :not_found} = Gtfs.get_calendar(context.organization.id, staging.id, "svc")

    assert {:error, :not_found} =
             Gtfs.feed_service_gaps(context.organization.id, staging.id, ~D[2026-01-01])

    refute Repo.exists?(from(a in CalendarAttribute, where: a.gtfs_version_id == ^staging.id))
    refute Repo.exists?(from(l in ChangeLog, where: l.gtfs_version_id == ^staging.id))
  end

  defp audit_context(organization, version, actor) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }
  end

  defp weekly_attrs(attrs) do
    Map.merge(
      %{
        service_id: "auth_#{System.unique_integer([:positive])}",
        name: "Authorized",
        kind: :weekly,
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 0,
        sunday: 0,
        start_date: ~D[2026-01-05],
        end_date: ~D[2026-01-30]
      },
      Map.new(attrs)
    )
  end

  defp dates_attrs(attrs) do
    Map.merge(
      %{
        service_id: "auth_dates_#{System.unique_integer([:positive])}",
        name: "Authorized Dates",
        kind: :dates_only,
        dates: [~D[2026-07-04]]
      },
      Map.new(attrs)
    )
  end

  defp create_editor_calendar(context, service_id) do
    assert {:ok, payload} =
             Gtfs.create_calendar(
               weekly_attrs(%{service_id: service_id, name: "Editor #{service_id}"}),
               context.audit
             )

    payload
  end

  # An imported native-only identity: reads work, but no metadata anchor exists yet.
  defp insert_imported_calendar(context) do
    calendar_fixture(context.organization.id, context.version.id, %{service_id: "imported"})

    assert {:ok, payload} =
             Gtfs.get_calendar(context.organization.id, context.version.id, "imported")

    payload
  end

  defp table_present?(context, service_id) do
    Repo.exists?(
      from(c in Calendar,
        where: c.gtfs_version_id == ^context.version.id and c.service_id == ^service_id
      )
    ) and
      Repo.exists?(
        from(a in CalendarAttribute,
          where: a.gtfs_version_id == ^context.version.id and a.service_id == ^service_id
        )
      )
  end

  defp refute_any_calendar_rows(context) do
    refute Repo.exists?(from(c in Calendar, where: c.organization_id == ^context.organization.id))

    refute Repo.exists?(
             from(d in CalendarDate, where: d.organization_id == ^context.organization.id)
           )

    refute Repo.exists?(
             from(a in CalendarAttribute, where: a.organization_id == ^context.organization.id)
           )

    refute Repo.exists?(
             from(l in ChangeLog, where: l.organization_id == ^context.organization.id)
           )
  end
end
