defmodule GtfsPlanner.Authorization.RolesTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Authorization.Roles

  describe "all/0" do
    test "returns map with all canonical role keys" do
      roles = Roles.all()

      assert is_map(roles)
      assert Map.has_key?(roles, :administrator)
      assert Map.has_key?(roles, :pathways_studio_admin)
      assert Map.has_key?(roles, :pathways_studio_editor)
    end

    test "each role has required metadata fields" do
      roles = Roles.all()

      for {_role_atom, role_map} <- roles do
        assert Map.has_key?(role_map, :name)
        assert Map.has_key?(role_map, :description)
        assert Map.has_key?(role_map, :scope)
        assert is_binary(role_map.name)
        assert is_binary(role_map.description)
        assert role_map.scope in [:system, :organization]
      end
    end
  end

  describe "valid?/1 with atom" do
    test "returns true for :administrator" do
      assert Roles.valid?(:administrator)
    end

    test "returns true for all canonical roles" do
      assert Roles.valid?(:administrator)
      assert Roles.valid?(:pathways_studio_admin)
      assert Roles.valid?(:pathways_studio_editor)
    end

    test "returns false for :nonexistent" do
      refute Roles.valid?(:nonexistent)
    end

    test "returns false for invalid role atoms" do
      refute Roles.valid?(:invalid_role)
      refute Roles.valid?(:admin)
      refute Roles.valid?(:user)
    end
  end

  describe "valid?/1 with string" do
    test "returns true for \"administrator\"" do
      assert Roles.valid?("administrator")
    end

    test "returns true for all canonical role strings" do
      assert Roles.valid?("administrator")
      assert Roles.valid?("pathways_studio_admin")
      assert Roles.valid?("pathways_studio_editor")
    end

    test "returns false for \"nonexistent\"" do
      refute Roles.valid?("nonexistent")
    end

    test "returns false for invalid role strings" do
      refute Roles.valid?("invalid_role")
      refute Roles.valid?("admin")
      refute Roles.valid?("user")
    end
  end

  describe "get/1" do
    test "returns expected map for :pathways_studio_editor" do
      role_map = Roles.get(:pathways_studio_editor)

      assert role_map == %{
               name: "Pathways Studio Editor",
               description: "Full access to view and modify GTFS data",
               scope: :organization
             }
    end

    test "returns metadata for atom roles" do
      assert %{name: "Administrator", scope: :system} = Roles.get(:administrator)

      assert %{name: "Pathways Studio Admin", scope: :organization} =
               Roles.get(:pathways_studio_admin)

      assert %{name: "Pathways Studio Editor", scope: :organization} =
               Roles.get(:pathways_studio_editor)
    end

    test "returns metadata for string roles" do
      assert %{name: "Administrator", scope: :system} = Roles.get("administrator")

      assert %{name: "Pathways Studio Admin", scope: :organization} =
               Roles.get("pathways_studio_admin")
    end

    test "returns nil for nonexistent atom role" do
      assert Roles.get(:nonexistent) == nil
    end

    test "returns nil for nonexistent string role" do
      assert Roles.get("nonexistent") == nil
    end
  end

  describe "list_by_scope/1" do
    test "with :system returns only [:administrator]" do
      system_roles = Roles.list_by_scope(:system)

      assert length(system_roles) == 1

      [{role_atom, role_map}] = system_roles
      assert role_atom == :administrator
      assert role_map.name == "Administrator"
      assert role_map.scope == :system
    end

    test "with :organization returns two org-level roles" do
      org_roles = Roles.list_by_scope(:organization)

      assert length(org_roles) == 2

      role_atoms = Enum.map(org_roles, fn {role_atom, _} -> role_atom end)
      assert :pathways_studio_admin in role_atoms
      assert :pathways_studio_editor in role_atoms

      # Verify all have organization scope
      for {_role_atom, role_map} <- org_roles do
        assert role_map.scope == :organization
      end
    end

    test "returns list of tuples with role atom and metadata" do
      org_roles = Roles.list_by_scope(:organization)

      for {role_atom, role_map} <- org_roles do
        assert is_atom(role_atom)
        assert is_map(role_map)
        assert Map.has_key?(role_map, :name)
        assert Map.has_key?(role_map, :description)
        assert Map.has_key?(role_map, :scope)
      end
    end

    test "returns empty list for nonexistent scope" do
      assert Roles.list_by_scope(:nonexistent) == []
    end
  end
end
