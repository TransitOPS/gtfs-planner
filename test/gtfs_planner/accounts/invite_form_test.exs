defmodule GtfsPlanner.Accounts.InviteFormTest do
  use GtfsPlanner.DataCase, async: true

  import ExUnit.CaptureLog

  alias GtfsPlanner.Accounts.InviteForm
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership

  @valid_attrs %{"email" => "invitee@example.com", "roles" => ["pathways_studio_editor"]}

  @base_message "The invitation could not be completed. Please try again."
  @duplicate_message "This person is already a member of this organization."

  describe "changeset/1" do
    test "normalizes email by trimming and downcasing while preserving selected roles" do
      changeset =
        InviteForm.changeset(%{
          "email" => "  Invitee@Example.COM  ",
          "roles" => ["pathways_studio_admin", "pathways_studio_editor"]
        })

      assert changeset.valid?
      assert get_field(changeset, :email) == "invitee@example.com"

      assert get_field(changeset, :roles) == [
               "pathways_studio_admin",
               "pathways_studio_editor"
             ]
    end

    test "preserves normalized values on an invalid submission" do
      changeset = InviteForm.changeset(%{"email" => "  Invitee@Example.COM  ", "roles" => []})

      refute changeset.valid?
      assert get_field(changeset, :email) == "invitee@example.com"
    end

    test "rejects a blank email" do
      changeset = InviteForm.changeset(%{"email" => "   ", "roles" => ["pathways_studio_admin"]})

      refute changeset.valid?
      assert errors_on(changeset).email == ["can't be blank"]
    end

    test "rejects a malformed email" do
      changeset =
        InviteForm.changeset(%{"email" => "not-an-email", "roles" => ["pathways_studio_admin"]})

      refute changeset.valid?
      assert errors_on(changeset).email == ["must have the @ sign and no spaces"]
    end

    test "requires at least one role" do
      changeset = InviteForm.changeset(%{"email" => "invitee@example.com", "roles" => []})

      refute changeset.valid?
      assert errors_on(changeset).roles == ["must select at least one role"]
    end

    test "requires at least one role when roles are absent" do
      changeset = InviteForm.changeset(%{"email" => "invitee@example.com"})

      refute changeset.valid?
      assert errors_on(changeset).roles == ["must select at least one role"]
    end

    test "rejects the system administrator role" do
      changeset =
        InviteForm.changeset(%{"email" => "invitee@example.com", "roles" => ["administrator"]})

      refute changeset.valid?
      assert errors_on(changeset).roles == ["contains an invalid role"]
    end

    test "rejects an unknown role value" do
      changeset =
        InviteForm.changeset(%{"email" => "invitee@example.com", "roles" => ["superuser"]})

      refute changeset.valid?
      assert errors_on(changeset).roles == ["contains an invalid role"]
    end

    test "reports email and role errors independently" do
      changeset = InviteForm.changeset(%{"email" => "not-an-email", "roles" => ["administrator"]})

      errors = errors_on(changeset)

      assert errors.email == ["must have the @ sign and no spaces"]
      assert errors.roles == ["contains an invalid role"]
    end

    test "accepts an email that already belongs to a registered account" do
      user = user_fixture()

      changeset =
        InviteForm.changeset(%{"email" => user.email, "roles" => ["pathways_studio_editor"]})

      assert changeset.valid?
    end

    test "ignores a browser-supplied base value" do
      changeset = InviteForm.changeset(Map.put(@valid_attrs, "base", "spoofed"))

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :base)
      assert Map.get(errors_on(changeset), :base) == nil
    end
  end

  describe "available_roles/0" do
    test "offers exactly the two organization roles with their canonical labels" do
      assert InviteForm.available_roles() == [
               {"Pathways Studio Admin", "pathways_studio_admin"},
               {"Pathways Studio Editor", "pathways_studio_editor"}
             ]
    end
  end

  describe "from_transaction_error/3" do
    test "maps a failed user changeset onto the email field" do
      source =
        %User{}
        |> User.invite_changeset(%{email: "not-an-email"})
        |> Map.put(:action, :insert)

      changeset = InviteForm.from_transaction_error(valid_changeset(), :user, source)

      assert errors_on(changeset).email == ["must have the @ sign and no spaces"]
      assert Map.get(errors_on(changeset), :base) == nil
    end

    test "maps a duplicate membership onto a base error naming the conflict" do
      source =
        %UserOrgMembership{}
        |> UserOrgMembership.changeset(%{
          user_id: Ecto.UUID.generate(),
          organization_id: Ecto.UUID.generate(),
          roles: ["pathways_studio_editor"]
        })
        |> Ecto.Changeset.add_error(:user_id, "has already been taken")

      changeset = InviteForm.from_transaction_error(valid_changeset(), :membership, source)

      assert errors_on(changeset).base == [@duplicate_message]
    end

    test "maps invalid membership roles back onto the roles field" do
      source =
        %UserOrgMembership{}
        |> UserOrgMembership.changeset(%{
          user_id: Ecto.UUID.generate(),
          organization_id: Ecto.UUID.generate(),
          roles: ["superuser"]
        })

      changeset = InviteForm.from_transaction_error(valid_changeset(), :membership, source)

      assert errors_on(changeset).roles == ["contains invalid role: superuser"]
    end

    test "maps an unexpected reason onto a generic base error without leaking the reason" do
      log =
        capture_log(fn ->
          changeset =
            InviteForm.from_transaction_error(
              valid_changeset(),
              :token,
              {:postgrex_error, "invitee@example.com secret detail"}
            )

          assert errors_on(changeset).base == [@base_message]
        end)

      assert log =~ "invite_operation=token"
      assert log =~ "failure_class=tuple"
      refute log =~ "secret detail"
    end
  end

  defp valid_changeset, do: InviteForm.changeset(@valid_attrs)
end
