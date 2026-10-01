defmodule GtfsPlanner.Operations.OperatorsTest do
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Operations
  alias GtfsPlanner.Operations.Operator

  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures

  defp create_operator(organization_id, attrs) do
    actor = operations_actor()
    {:ok, operator} = Operations.create_operator(organization_id, actor, attrs)
    operator
  end

  defp attrs(employee_id, display_name, seniority_number \\ nil) do
    %{
      "employee_id" => employee_id,
      "display_name" => display_name,
      "seniority_number" => seniority_number
    }
  end

  # {seniority, employee_id, name} per row, so the order is asserted literally.
  defp listing(organization_id) do
    Enum.map(
      Operations.list_operators(organization_id),
      &{&1.seniority_number, &1.employee_id, &1.display_name}
    )
  end

  describe "list_operators/1" do
    test "orders by seniority ascending with blanks last, then employee ID, and unnumbered operators by name" do
      organization = organization_fixture()

      create_operator(organization.id, attrs("E4010", "Zoe Marchetti"))
      create_operator(organization.id, attrs("E4300", "Ana Duarte"))
      create_operator(organization.id, attrs("E4157", "Ines Duarte", 10))
      create_operator(organization.id, attrs("E4200", "Mira Silva", 3))
      create_operator(organization.id, attrs("E4101", "Aurelia Nowak", 10))

      assert listing(organization.id) == [
               {3, "E4200", "Mira Silva"},
               {10, "E4101", "Aurelia Nowak"},
               {10, "E4157", "Ines Duarte"},
               {nil, "E4300", "Ana Duarte"},
               {nil, "E4010", "Zoe Marchetti"}
             ]
    end

    test "keeps blank seniority behind the highest number" do
      organization = organization_fixture()

      # The fixture is the point of the case: one operator at the top of the
      # allowed range and one with no number at all, so "blanks last" is a claim
      # about an order and not about an empty table.
      create_operator(organization.id, attrs("E4900", "Yusuf Demir", 99_999))
      create_operator(organization.id, attrs("E4010", "Zoe Marchetti"))

      assert listing(organization.id) == [
               {99_999, "E4900", "Yusuf Demir"},
               {nil, "E4010", "Zoe Marchetti"}
             ]
    end

    test "excludes other organizations' operators" do
      organization = organization_fixture()
      other = organization_fixture()

      create_operator(organization.id, attrs("E4101", "Aurelia Nowak", 10))
      create_operator(other.id, attrs("E4101", "Foreign Operator", 1))

      assert listing(organization.id) == [{10, "E4101", "Aurelia Nowak"}]
      assert listing(other.id) == [{1, "E4101", "Foreign Operator"}]
    end

    test "returns an empty list for an organization without operators" do
      organization = organization_fixture()

      assert Operations.list_operators(organization.id) == []
    end
  end

  describe "get_operator/2" do
    test "returns the organization's operator" do
      organization = organization_fixture()
      operator = create_operator(organization.id, attrs("E4101", "Aurelia Nowak"))

      assert %Operator{id: id} = Operations.get_operator(organization.id, operator.id)
      assert id == operator.id
    end

    test "returns nil for another organization's, an unknown and a malformed id" do
      organization = organization_fixture()
      other = organization_fixture()
      foreign = create_operator(other.id, attrs("E4101", "Foreign Operator"))

      assert Operations.get_operator(organization.id, foreign.id) == nil
      assert Operations.get_operator(organization.id, Ecto.UUID.generate()) == nil
      assert Operations.get_operator(organization.id, "not-a-uuid") == nil
    end
  end

  describe "change_operator/2" do
    test "returns a changeset for tracking changes" do
      organization = organization_fixture()
      operator = create_operator(organization.id, attrs("E4101", "Aurelia Nowak"))

      changeset = Operations.change_operator(operator, %{"display_name" => "Renamed"})

      assert changeset.valid?
      assert changeset.changes.display_name == "Renamed"
    end
  end

  describe "create_operator/3" do
    test "persists only the caller's organization and records the acting user" do
      organization = organization_fixture()
      other = organization_fixture()
      actor = operations_actor()

      submitted =
        attrs("E4101", "Aurelia Nowak", 10)
        |> Map.merge(%{
          "organization_id" => other.id,
          "updated_by_id" => Ecto.UUID.generate()
        })

      assert {:ok, operator} = Operations.create_operator(organization.id, actor, submitted)
      assert operator.organization_id == organization.id
      assert operator.updated_by_id == actor.id
      assert operator.employee_id == "E4101"
      assert operator.display_name == "Aurelia Nowak"
      assert operator.seniority_number == 10

      stored = Repo.get(Operator, operator.id)
      assert stored.organization_id == organization.id
      assert stored.updated_by_id == actor.id
      assert Operations.list_operators(other.id) == []
    end

    test "stores an operator without a seniority number" do
      organization = organization_fixture()

      assert {:ok, operator} =
               Operations.create_operator(
                 organization.id,
                 operations_actor(),
                 %{"employee_id" => "E4101", "display_name" => "Aurelia Nowak"}
               )

      assert operator.seniority_number == nil
    end

    test "names the holder when the employee ID is already used in the organization" do
      organization = organization_fixture()
      create_operator(organization.id, attrs("E4101", "Aurelia Nowak", 10))

      assert {:error, changeset} =
               Operations.create_operator(
                 organization.id,
                 operations_actor(),
                 attrs("E4101", "Arjun Menon")
               )

      assert %{employee_id: ["E4101 is already used by Aurelia Nowak."]} =
               errors_on(changeset)
    end

    test "compares the trimmed employee ID, so a padded one is the same ID" do
      organization = organization_fixture()
      create_operator(organization.id, attrs("E4101", "Aurelia Nowak"))

      assert {:error, changeset} =
               Operations.create_operator(
                 organization.id,
                 operations_actor(),
                 attrs("  E4101  ", "Arjun Menon")
               )

      assert %{employee_id: ["E4101 is already used by Aurelia Nowak."]} =
               errors_on(changeset)
    end

    test "allows the same employee ID in another organization" do
      organization = organization_fixture()
      other = organization_fixture()
      create_operator(organization.id, attrs("E4101", "Aurelia Nowak"))

      assert {:ok, operator} =
               Operations.create_operator(
                 other.id,
                 operations_actor(),
                 attrs("E4101", "Arjun Menon")
               )

      assert Repo.get(Operator, operator.id).organization_id == other.id
    end

    test "reports the other validation errors" do
      organization = organization_fixture()

      assert {:error, changeset} =
               Operations.create_operator(organization.id, operations_actor(), %{
                 "employee_id" => " E4101 ",
                 "display_name" => "Aurelia Nowak",
                 "seniority_number" => 100_000
               })

      errors = errors_on(changeset)
      assert errors.seniority_number
      refute Map.has_key?(errors, :employee_id)
    end
  end

  describe "update_operator/4" do
    test "updates the organization's operator and records the acting user" do
      organization = organization_fixture()
      operator = create_operator(organization.id, attrs("E4101", "Aurelia Nowak", 10))
      actor = operations_actor()

      assert {:ok, updated} =
               Operations.update_operator(
                 organization.id,
                 actor,
                 operator.id,
                 %{"display_name" => "Aurelia Nowak-Smith", "seniority_number" => 12}
               )

      assert updated.display_name == "Aurelia Nowak-Smith"
      assert updated.seniority_number == 12
      assert updated.updated_by_id == actor.id

      stored = Repo.get(Operator, operator.id)
      assert stored.display_name == "Aurelia Nowak-Smith"
      assert stored.seniority_number == 12
    end

    test "keeps the operator's own employee ID without a refusal" do
      organization = organization_fixture()
      operator = create_operator(organization.id, attrs("E4101", "Aurelia Nowak", 10))

      assert {:ok, updated} =
               Operations.update_operator(
                 organization.id,
                 operations_actor(),
                 operator.id,
                 %{"employee_id" => "E4101", "display_name" => "Aurelia N."}
               )

      assert updated.employee_id == "E4101"
      assert updated.display_name == "Aurelia N."
    end

    test "names the holder when another operator already has the employee ID" do
      organization = organization_fixture()
      holder = create_operator(organization.id, attrs("E4101", "Aurelia Nowak", 10))
      operator = create_operator(organization.id, attrs("E4999", "Arjun Menon"))

      assert {:error, changeset} =
               Operations.update_operator(
                 organization.id,
                 operations_actor(),
                 operator.id,
                 %{"employee_id" => "E4101"}
               )

      assert %{employee_id: ["E4101 is already used by Aurelia Nowak."]} =
               errors_on(changeset)

      assert Repo.get(Operator, operator.id).employee_id == "E4999"
      assert Repo.get(Operator, holder.id).employee_id == "E4101"
    end

    test "returns {:error, :not_found} for another organization's, an unknown and a malformed id" do
      organization = organization_fixture()
      other = organization_fixture()
      foreign = create_operator(other.id, attrs("E4101", "Foreign Operator"))

      for id <- [foreign.id, Ecto.UUID.generate(), "not-a-uuid"] do
        assert Operations.update_operator(organization.id, operations_actor(), id, %{
                 "display_name" => "Hijacked"
               }) == {:error, :not_found}
      end

      assert Repo.get(Operator, foreign.id).display_name == "Foreign Operator"
    end

    test "re-orders the list when the seniority number changes" do
      organization = organization_fixture()
      operator = create_operator(organization.id, attrs("E4101", "Aurelia Nowak", 10))
      create_operator(organization.id, attrs("E4200", "Mira Silva", 3))

      assert listing(organization.id) == [
               {3, "E4200", "Mira Silva"},
               {10, "E4101", "Aurelia Nowak"}
             ]

      assert {:ok, _updated} =
               Operations.update_operator(
                 organization.id,
                 operations_actor(),
                 operator.id,
                 %{"seniority_number" => 1}
               )

      assert listing(organization.id) == [
               {1, "E4101", "Aurelia Nowak"},
               {3, "E4200", "Mira Silva"}
             ]
    end
  end
end
