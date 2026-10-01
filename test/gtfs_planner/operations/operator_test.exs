defmodule GtfsPlanner.Operations.OperatorTest do
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Operations.Operator

  import GtfsPlanner.OrganizationsFixtures

  defp valid_attrs(attrs \\ %{}) do
    Map.merge(%{"employee_id" => "E4101", "display_name" => "Aurelia Nowak"}, attrs)
  end

  describe "changeset/2 string fields" do
    test "trims the employee ID and the display name" do
      changeset =
        Operator.changeset(
          %Operator{},
          valid_attrs(%{"employee_id" => " E4101 ", "display_name" => " Aurelia Nowak "})
        )

      assert changeset.changes.employee_id == "E4101"
      assert changeset.changes.display_name == "Aurelia Nowak"
      assert changeset.valid?
    end

    test "requires an employee ID and a display name" do
      changeset = Operator.changeset(%Operator{}, valid_attrs(%{"employee_id" => "  "}))
      refute changeset.valid?
      assert %{employee_id: ["can't be blank"]} = errors_on(changeset)

      changeset = Operator.changeset(%Operator{}, valid_attrs(%{"display_name" => ""}))
      refute changeset.valid?
      assert %{display_name: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects an employee ID longer than 64 characters" do
      changeset =
        Operator.changeset(
          %Operator{},
          valid_attrs(%{"employee_id" => String.duplicate("E", 65)})
        )

      refute changeset.valid?
      assert %{employee_id: ["should be at most 64 character(s)"]} = errors_on(changeset)
    end

    test "rejects a display name longer than 120 characters" do
      changeset =
        Operator.changeset(
          %Operator{},
          valid_attrs(%{"display_name" => String.duplicate("A", 121)})
        )

      refute changeset.valid?
      assert %{display_name: ["should be at most 120 character(s)"]} = errors_on(changeset)
    end
  end

  describe "changeset/2 seniority number" do
    test "accepts no seniority number" do
      changeset = Operator.changeset(%Operator{}, valid_attrs(%{}))
      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :seniority_number)
    end

    test "accepts the lower boundary" do
      changeset = Operator.changeset(%Operator{}, valid_attrs(%{"seniority_number" => 1}))
      assert changeset.valid?
      assert changeset.changes.seniority_number == 1
    end

    test "accepts the upper boundary" do
      changeset = Operator.changeset(%Operator{}, valid_attrs(%{"seniority_number" => 99_999}))
      assert changeset.valid?
      assert changeset.changes.seniority_number == 99_999
    end

    test "rejects zero" do
      changeset = Operator.changeset(%Operator{}, valid_attrs(%{"seniority_number" => 0}))
      refute changeset.valid?
      assert %{seniority_number: ["must be greater than or equal to 1"]} = errors_on(changeset)
    end

    test "rejects 100000" do
      changeset = Operator.changeset(%Operator{}, valid_attrs(%{"seniority_number" => 100_000}))
      refute changeset.valid?
      assert %{seniority_number: ["must be less than or equal to 99999"]} = errors_on(changeset)
    end

    test "rejects a fractional seniority number" do
      changeset = Operator.changeset(%Operator{}, valid_attrs(%{"seniority_number" => "1.5"}))
      refute changeset.valid?
      assert %{seniority_number: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "changeset/2 organization scope" do
    test "ignores organization_id and updated_by_id in attrs" do
      changeset =
        Operator.changeset(
          %Operator{},
          valid_attrs(%{
            "organization_id" => Ecto.UUID.generate(),
            "updated_by_id" => Ecto.UUID.generate()
          })
        )

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :organization_id)
      refute Map.has_key?(changeset.changes, :updated_by_id)
    end

    test "refuses a duplicate employee ID in the same organization" do
      organization = organization_fixture()

      assert {:ok, _operator} =
               %Operator{organization_id: organization.id}
               |> Operator.changeset(valid_attrs())
               |> Repo.insert()

      assert {:error, changeset} =
               %Operator{organization_id: organization.id}
               |> Operator.changeset(valid_attrs(%{"display_name" => "Arjun Menon"}))
               |> Repo.insert()

      refute changeset.valid?
      assert %{employee_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "accepts the same employee ID in another organization" do
      organization = organization_fixture()
      other = organization_fixture()

      assert {:ok, _operator} =
               %Operator{organization_id: organization.id}
               |> Operator.changeset(valid_attrs())
               |> Repo.insert()

      assert {:ok, operator} =
               %Operator{organization_id: other.id}
               |> Operator.changeset(valid_attrs())
               |> Repo.insert()

      assert Repo.get(Operator, operator.id).organization_id == other.id
    end
  end
end
