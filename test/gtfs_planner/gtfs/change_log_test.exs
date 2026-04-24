defmodule GtfsPlanner.Gtfs.ChangeLogTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.ChangeLog

  @valid_attrs %{
    entity_type: "stop",
    entity_id: Ecto.UUID.generate(),
    entity_external_id: "platform_a",
    station_stop_id: "station_central",
    actor_id: Ecto.UUID.generate(),
    actor_email: "user@example.com",
    snapshot: %{"stop_name" => "Platform A"},
    changed_fields: %{"stop_name" => %{"from" => "Old Name", "to" => "Platform A"}},
    action: "updated",
    organization_id: Ecto.UUID.generate(),
    gtfs_version_id: Ecto.UUID.generate()
  }

  describe "changeset/2" do
    test "valid attrs produce a valid changeset" do
      changeset = ChangeLog.changeset(%ChangeLog{}, @valid_attrs)
      assert changeset.valid?
    end

    test "invalid entity_type returns error" do
      changeset = ChangeLog.changeset(%ChangeLog{}, Map.put(@valid_attrs, :entity_type, "invalid"))
      refute changeset.valid?
      assert has_error?(changeset, :entity_type, "is invalid")
    end

    test "invalid action returns error" do
      changeset = ChangeLog.changeset(%ChangeLog{}, Map.put(@valid_attrs, :action, "invalid"))
      refute changeset.valid?
      assert has_error?(changeset, :action, "is invalid")
    end

    test "missing entity_type returns error" do
      changeset = ChangeLog.changeset(%ChangeLog{}, Map.delete(@valid_attrs, :entity_type))
      refute changeset.valid?
      assert has_error?(changeset, :entity_type, "can't be blank")
    end

    test "missing action returns error" do
      changeset = ChangeLog.changeset(%ChangeLog{}, Map.delete(@valid_attrs, :action))
      refute changeset.valid?
      assert has_error?(changeset, :action, "can't be blank")
    end

    test "missing entity_id returns error" do
      changeset = ChangeLog.changeset(%ChangeLog{}, Map.delete(@valid_attrs, :entity_id))
      refute changeset.valid?
      assert has_error?(changeset, :entity_id, "can't be blank")
    end

    test "missing organization_id returns error" do
      changeset = ChangeLog.changeset(%ChangeLog{}, Map.delete(@valid_attrs, :organization_id))
      refute changeset.valid?
      assert has_error?(changeset, :organization_id, "can't be blank")
    end

    test "snapshot and changed_fields are optional" do
      attrs = Map.merge(@valid_attrs, %{snapshot: nil, changed_fields: nil})
      changeset = ChangeLog.changeset(%ChangeLog{}, attrs)
      assert changeset.valid?
    end

    test "allows rolled_back action" do
      changeset = ChangeLog.changeset(%ChangeLog{}, Map.put(@valid_attrs, :action, "rolled_back"))
      assert changeset.valid?
    end

    test "allows deleted action" do
      changeset = ChangeLog.changeset(%ChangeLog{}, Map.put(@valid_attrs, :action, "deleted"))
      assert changeset.valid?
    end

    test "allows created action" do
      changeset = ChangeLog.changeset(%ChangeLog{}, Map.put(@valid_attrs, :action, "created"))
      assert changeset.valid?
    end

    test "sets rolled_back_to_log_id when provided" do
      log_id = Ecto.UUID.generate()
      attrs = Map.put(@valid_attrs, :rolled_back_to_log_id, log_id)
      changeset = ChangeLog.changeset(%ChangeLog{}, attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :rolled_back_to_log_id) == log_id
    end
  end

  defp has_error?(changeset, field, message) do
    errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
    Map.get(errors, field, []) |> Enum.member?(message)
  end
end
