defmodule GtfsPlanner.Gtfs.StopEditingUpdateTest do
  @moduledoc """
  `StopEditing.update_stop/4` against a real database.

  What is under test is the write boundary, not the update: which fields the
  editor owns, which two are not theirs at all, how far a stop may be moved
  before the command hands the decision back, and that there is no committed
  change without a matching audit entry.

  Every refused case asserts that nothing was written. A move that answers
  `{:review_required, :review}` and still moves the stop is not a review, it is
  a write that skipped its review, and the only way to know the difference is
  to look at the row afterwards.
  """

  use ExUnit.Case

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopEditing
  alias GtfsPlanner.Gtfs.StopPlacement
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo

  # The stop the tests move. A degree of latitude is about 111 320 m, so an
  # offset in degrees is a literal metre distance divided by that; the helper
  # below does the division so each case can name its distance in metres.
  @base_lat 44.6210
  @base_lon -124.0530

  describe "update_stop/4 editor fields" do
    test "saves name, description, sign number, wheelchair access, spoken name and web page" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      stop = seeded_stop(fixture)

      attrs = %{
        "stop_name" => "Main St & 1st Ave",
        "stop_desc" => "Opposite the library",
        "stop_code" => "MS-01",
        "wheelchair_boarding" => 1,
        "tts_stop_name" => "Main Street and First Avenue",
        "stop_url" => "https://example.com/stops/main"
      }

      assert {:ok, updated} = update_stop(stop, attrs, fixture.audit)

      assert updated.stop_name == "Main St & 1st Ave"
      assert updated.stop_desc == "Opposite the library"
      assert updated.stop_code == "MS-01"
      assert updated.wheelchair_boarding == 1
      assert updated.tts_stop_name == "Main Street and First Avenue"
      assert updated.stop_url == "https://example.com/stops/main"

      assert [log] = updated_logs(fixture)
      assert log.entity_type == "stop"
      assert log.action == "updated"
      assert log.entity_id == stop.id
      assert log.entity_external_id == stop.stop_id
      assert log.actor_id == fixture.audit.actor_id
      assert log.actor_email == fixture.audit.actor_email
    end

    test "the audit entry records what each field changed from" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      stop = seeded_stop(fixture, %{stop_desc: "Old description"})

      assert {:ok, _updated} =
               update_stop(stop, %{"stop_desc" => "New description"}, fixture.audit)

      assert [log] = updated_logs(fixture)

      assert log.changed_fields["stop_desc"] == %{
               "from" => "Old description",
               "to" => "New description"
             }
    end

    test "a draft that resubmits a field unchanged records no change for it" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      stop = seeded_stop(fixture, %{stop_name: "Main St", stop_desc: "Unchanged"})

      assert {:ok, _updated} =
               update_stop(
                 stop,
                 %{"stop_name" => "Main St", "stop_desc" => "Changed"},
                 fixture.audit
               )

      assert [log] = updated_logs(fixture)

      # The form sent both fields; only one of them is a change an editor made.
      assert log.changed_fields["stop_desc"] == %{"from" => "Unchanged", "to" => "Changed"}
      refute Map.has_key?(log.changed_fields, "stop_name")
    end

    test "a non-http stop_url is a changeset error and writes nothing" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      stop = seeded_stop(fixture)

      assert {:error, %Ecto.Changeset{} = failed} =
               update_stop(stop, %{"stop_url" => "javascript:alert(1)"}, fixture.audit)

      assert Keyword.has_key?(failed.errors, :stop_url)
      assert reloaded(fixture, stop).stop_url == nil
      assert [] = updated_logs(fixture)
    end

    test "an audit context with no actor_email rolls the update back" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      stop = seeded_stop(fixture)

      audit = %{fixture.audit | actor_email: nil}

      assert {:error, :failed_audit} = update_stop(stop, %{"stop_name" => "Renamed"}, audit)
      assert reloaded(fixture, stop).stop_name == "Main St"
      assert [] = updated_logs(fixture)
    end
  end

  describe "update_stop/4 immutable fields" do
    test "a stop_id in the draft leaves the stop's ID unchanged" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      stop = seeded_stop(fixture, %{stop_id: "1434"})

      assert {:ok, updated} = update_stop(stop, %{"stop_id" => "9999"}, fixture.audit)

      # The stop ID is not the editor's to change. The feed, the rider
      # information and every downstream tool are keyed on this ID; a draft that
      # carries a different one is a bug in the form, not an instruction.
      assert updated.stop_id == "1434"
      assert reloaded(fixture, stop).stop_id == "1434"
    end

    test "a zone_id in the draft leaves the stop's zone unchanged" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      stop = seeded_stop(fixture)
      zoned_stop = unboxed(fn -> set_zone(stop, "A") end)

      assert {:ok, updated} = update_stop(zoned_stop, %{"zone_id" => "X"}, fixture.audit)

      # Settings › Fares owns a zone. The panel shows it read-only and links
      # there, so a zone arriving through the form is ignored rather than
      # honoured.
      assert updated.zone_id == "A"
      assert reloaded(fixture, stop).zone_id == "A"
    end

    test "location_type, parent_station and scope in the draft are ignored" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      other = create_fixture()

      stop = seeded_stop(fixture)

      attrs = %{
        "location_type" => 1,
        "parent_station" => "STATION-1",
        "organization_id" => other.organization.id,
        "gtfs_version_id" => other.version.id
      }

      assert {:ok, updated} = update_stop(stop, attrs, fixture.audit)

      assert updated.location_type == 0
      assert updated.parent_station == nil
      assert updated.organization_id == fixture.organization.id
      assert updated.gtfs_version_id == fixture.version.id
    end
  end

  describe "update_stop/4 move bands" do
    test "a 7.9 m move of a served stop saves" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      stop = served_stop(fixture)

      assert {:ok, updated} = move_stop(stop, 7.9, fixture.audit)

      # Within the column's own resolution: `stops.stop_lat` is `numeric(9, 6)`,
      # a hundredth of a metre at the equator, so the saved point is a tenth of
      # a millimetre... a fraction of a millimetre off the ideal. The band
      # boundaries are asserted with the same tolerance everywhere.
      assert_in_delta metres_between(stop, updated), 7.9, 0.15
      assert [log] = updated_logs(fixture)
      assert log.action == "updated"
    end

    test "an 8.1 m move of a served stop asks for a review and changes nothing" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      stop = served_stop(fixture)

      assert {:review_required, :review} = move_stop(stop, 8.1, fixture.audit)

      assert reloaded(fixture, stop).stop_lat == stop.stop_lat
      assert reloaded(fixture, stop).stop_lon == stop.stop_lon
      assert [] = updated_logs(fixture)
    end

    test "a 101 m move of a served stop is a far move, not a review" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      stop = served_stop(fixture)

      assert {:review_required, :far} = move_stop(stop, 101.0, fixture.audit)

      assert reloaded(fixture, stop).stop_lat == stop.stop_lat
      assert [] = updated_logs(fixture)
    end

    test "a 400 m move of a stop nothing serves saves" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      stop = seeded_stop(fixture)

      # Nothing in the feed puts riders here, so there is no timetable to
      # contradict and the move is a correction however far it goes.
      assert {:ok, updated} = move_stop(stop, 400.0, fixture.audit)

      assert_in_delta metres_between(stop, updated), 400.0, 0.6
    end

    test "a stop served only by a stop_time counts as served" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      # A trip whose pattern has not been built still serves the stop, and
      # treating it as unserved would let a four hundred metre move past the
      # review this rule exists for.
      stop = seeded_stop(fixture)

      unboxed(fn ->
        stop_time_fixture(fixture.organization.id, fixture.version.id, "TRIP-1", stop.stop_id)
      end)

      assert {:review_required, :far} = move_stop(stop, 400.0, fixture.audit)
      assert reloaded(fixture, stop).stop_lat == stop.stop_lat
    end

    test "a stop served only by a pattern occurrence counts as served" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      assert {:review_required, :review} = move_stop(served_stop(fixture), 20.0, fixture.audit)
    end

    test "a move past the band is refused even when it is bundled with a name change" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      stop = served_stop(fixture)

      attrs =
        %{"stop_name" => "Renamed anyway"}
        |> Map.merge(coordinates(50.0))

      assert {:review_required, :review} = update_stop(stop, attrs, fixture.audit)

      # The whole draft is refused, not just the coordinates: an editor shown a
      # review must not find half of what they typed already saved.
      assert reloaded(fixture, stop).stop_name == "Main St"
      assert [] = updated_logs(fixture)
    end
  end

  describe "update_stop/4 staleness" do
    test "a loaded_updated_at older than the row's is stale and writes nothing" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      stop = seeded_stop(fixture)

      # Someone else saved first, so the row's updated_at has moved past the
      # moment this form was rendered from.
      stale_timestamp = DateTime.add(stop.updated_at, -60, :second)

      assert {:error, :stale} =
               update_stop_at(stop, %{"stop_name" => "Mine"}, stale_timestamp, fixture.audit)

      assert reloaded(fixture, stop).stop_name == "Main St"
      assert [] = updated_logs(fixture)
    end

    test "a loaded_updated_at matching the row's saves" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      stop = seeded_stop(fixture)

      assert {:ok, updated} =
               update_stop_at(
                 stop,
                 %{"stop_name" => "Mine"},
                 DateTime.to_iso8601(stop.updated_at),
                 fixture.audit
               )

      assert updated.stop_name == "Mine"
    end

    test "a loaded_updated_at that cannot be read is stale rather than trusted" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      stop = seeded_stop(fixture)

      assert {:error, :stale} =
               update_stop_at(stop, %{"stop_name" => "Mine"}, nil, fixture.audit)

      assert {:error, :stale} =
               update_stop_at(stop, %{"stop_name" => "Mine"}, "yesterday", fixture.audit)

      assert reloaded(fixture, stop).stop_name == "Main St"
    end
  end

  describe "update_stop/4 authorization and scope" do
    test "a non-editor is forbidden and writes nothing" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      stop = seeded_stop(fixture)

      actor = unboxed(fn -> add_actor(fixture.organization.id, "pathways_studio_admin") end)
      audit = %{fixture.audit | actor_id: actor.id, actor_email: actor.email}

      assert {:error, :forbidden} = update_stop(stop, %{"stop_name" => "Renamed"}, audit)
      assert reloaded(fixture, stop).stop_name == "Main St"
      assert [] = updated_logs(fixture)
    end

    test "a deactivated member is forbidden and writes nothing" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      stop = seeded_stop(fixture)

      unboxed(fn ->
        membership =
          Accounts.get_user_org_membership(fixture.actor.id, fixture.organization.id)

        deactivate_membership_fixture(membership)
      end)

      assert {:error, :forbidden} = update_stop(stop, %{"stop_name" => "Renamed"}, fixture.audit)
      assert reloaded(fixture, stop).stop_name == "Main St"
    end

    test "a stop in another organization's version is not found" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      other = create_fixture()
      on_exit(fn -> cleanup_fixture(other) end)

      stop = seeded_stop(fixture)

      # The stop is real, the audit context is not its own, and scoping the
      # load is what makes it invisible rather than merely refused.
      assert {:error, :not_found} = update_stop(stop, %{"stop_name" => "Renamed"}, other.audit)
      assert reloaded(fixture, stop).stop_name == "Main St"
      assert [] = updated_logs(fixture)
    end

    test "an unknown stop id is not found" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      seeded_stop(fixture)

      assert {:error, :not_found} =
               unboxed(fn ->
                 StopEditing.update_stop(
                   Ecto.UUID.generate(),
                   %{"stop_name" => "Renamed"},
                   DateTime.utc_now(),
                   fixture.audit
                 )
               end)
    end
  end

  # --- fixture

  defp create_fixture do
    unboxed(fn ->
      organization = organization_fixture(%{alias: "stop-update-#{stamp()}"})
      version = gtfs_version_fixture(organization.id)
      actor = add_actor(organization.id, "pathways_studio_editor")

      audit = %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        actor_id: actor.id,
        actor_email: actor.email
      }

      %{organization: organization, version: version, actor: actor, audit: audit}
    end)
  end

  # `user_fixture/1` derives its email from `System.unique_integer/1`, which
  # restarts with the VM, so two runs against the same test database can mint
  # the same address. A nanosecond stamp does not, and `cleanup_fixture/1`
  # deletes the user anyway.
  defp add_actor(organization_id, role) do
    actor = user_fixture(%{email: "stop-update-#{stamp()}@example.com"})

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: actor.id,
        organization_id: organization_id,
        roles: [role]
      })

    actor
  end

  # `zone_id` is not in `Stop.changeset/2`'s cast list at all — Settings › Fares
  # owns it — so the only way a stop carries a zone in this test is to write it
  # directly, which is exactly the state the read-only field has to survive.
  defp set_zone(stop, zone_id) do
    stop
    |> Ecto.Changeset.change(zone_id: zone_id)
    |> Repo.update!()
    |> then(fn updated -> Repo.one!(from s in Stop, where: s.id == ^updated.id) end)
  end

  # Reloaded rather than returned from the insert, because that is what a
  # LiveView holds: the form's `loaded_updated_at` comes from a read, and the
  # column keeps whole seconds, so a struct straight from `insert/1` carries
  # microseconds the database never stored.
  defp seeded_stop(fixture, overrides \\ %{}) do
    unboxed(fn ->
      attrs =
        Enum.into(overrides, %{
          stop_id: "1434",
          stop_name: "Main St",
          stop_lat: Decimal.from_float(@base_lat),
          stop_lon: Decimal.from_float(@base_lon)
        })

      stop = stop_fixture(fixture.organization.id, fixture.version.id, attrs)

      Repo.one!(from s in Stop, where: s.id == ^stop.id)
    end)
  end

  # A stop something serves: a pattern occurrence is the normal way a rider is
  # attached to a stop, and the other served case (`stop_times` alone) has its
  # own test.
  defp served_stop(fixture) do
    stop = seeded_stop(fixture)

    unboxed(fn ->
      pattern = route_pattern_fixture(fixture.organization.id, fixture.version.id)
      route_pattern_stop_fixture(pattern, stop.stop_id, 1)
    end)

    stop
  end

  # Metres as a coordinate offset. `StopPlacement` works in `{lon, lat}`, and a
  # degree of latitude is 111 320 m at the equator; the tests move north, so the
  # longitude is untouched and the latitude alone carries the distance.
  defp coordinates(metres) do
    %{
      "stop_lat" => Decimal.from_float(@base_lat + metres / 111_320.0),
      "stop_lon" => Decimal.from_float(@base_lon)
    }
  end

  defp move_stop(stop, metres, audit) do
    update_stop(stop, coordinates(metres), audit)
  end

  defp metres_between(before, after_stop) do
    StopPlacement.distance(
      {Decimal.to_float(before.stop_lon), Decimal.to_float(before.stop_lat)},
      {Decimal.to_float(after_stop.stop_lon), Decimal.to_float(after_stop.stop_lat)}
    )
  end

  defp update_stop(stop, attrs, audit) do
    unboxed(fn -> StopEditing.update_stop(stop.id, attrs, stop.updated_at, audit) end)
  end

  defp update_stop_at(stop, attrs, loaded_updated_at, audit) do
    unboxed(fn -> StopEditing.update_stop(stop.id, attrs, loaded_updated_at, audit) end)
  end

  defp reloaded(fixture, stop) do
    unboxed(fn ->
      Repo.one!(
        from s in Stop,
          where:
            s.organization_id == ^fixture.organization.id and
              s.gtfs_version_id == ^fixture.version.id and
              s.id == ^stop.id
      )
    end)
  end

  defp updated_logs(fixture) do
    unboxed(fn ->
      Repo.all(
        from l in ChangeLog,
          where:
            l.organization_id == ^fixture.organization.id and
              l.gtfs_version_id == ^fixture.version.id and
              l.entity_type == "stop" and
              l.action == "updated"
      )
    end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp stamp, do: System.system_time(:nanosecond)

  defp cleanup_fixture(fixture) do
    unboxed(fn ->
      Repo.delete_all(
        from l in ChangeLog,
          where:
            l.organization_id == ^fixture.organization.id or
              l.gtfs_version_id == ^fixture.version.id
      )

      Repo.delete_all(
        from s in Stop,
          where:
            s.organization_id == ^fixture.organization.id or
              s.gtfs_version_id == ^fixture.version.id
      )

      Repo.delete_all(
        from o in RoutePatternStop,
          where:
            o.organization_id == ^fixture.organization.id or
              o.gtfs_version_id == ^fixture.version.id
      )

      Repo.delete_all(
        from t in StopTime,
          where:
            t.organization_id == ^fixture.organization.id or
              t.gtfs_version_id == ^fixture.version.id
      )

      Repo.delete_all(
        from p in RoutePattern,
          where:
            p.organization_id == ^fixture.organization.id or
              p.gtfs_version_id == ^fixture.version.id
      )

      Repo.delete_all(
        from m in UserOrgMembership,
          where: m.organization_id == ^fixture.organization.id
      )

      Repo.delete_all(from o in Organization, where: o.id == ^fixture.organization.id)

      # An unboxed test commits the users its actor and stranger fixtures
      # created. Deleting the organization removes the membership but not the
      # user, and a leftover user breaks the first-administrator tests, which
      # need a database with no committed users.
      Repo.delete_all(from u in User, where: like(u.email, "stop-update-%"))
    end)
  end
end
