defmodule GtfsPlanner.Accounts.PasswordResetRequestFormTest do
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.PasswordResetRequestForm
  alias GtfsPlanner.Accounts.User

  describe "changeset/1" do
    test "is valid with a well-shaped email and casts the single email field" do
      changeset = PasswordResetRequestForm.changeset(%{"email" => "user@example.com"})

      assert changeset.valid?
      assert changeset.errors == []
      assert get_field(changeset, :email) == "user@example.com"
      assert changeset.data == %PasswordResetRequestForm{}
      assert changeset.types == %{email: :string}
    end

    test "trims surrounding whitespace from a padded valid email" do
      changeset = PasswordResetRequestForm.changeset(%{"email" => "  user@example.com  "})

      assert changeset.valid?
      assert get_field(changeset, :email) == "user@example.com"
    end

    test "requires an email when the parameter is missing" do
      changeset = PasswordResetRequestForm.changeset(%{})

      refute changeset.valid?
      assert changeset.errors == [email: {"can't be blank", [validation: :required]}]
    end

    test "requires an email when the value is blank" do
      changeset = PasswordResetRequestForm.changeset(%{"email" => ""})

      refute changeset.valid?
      assert errors_on(changeset) == %{email: ["can't be blank"]}
    end

    test "requires an email when the value is whitespace only" do
      changeset = PasswordResetRequestForm.changeset(%{"email" => "   "})

      refute changeset.valid?
      assert errors_on(changeset) == %{email: ["can't be blank"]}
    end

    test "rejects a malformed email with the shared shape message" do
      changeset = PasswordResetRequestForm.changeset(%{"email" => "not-an-email"})

      refute changeset.valid?
      assert errors_on(changeset) == %{email: ["must have the @ sign and no spaces"]}
    end

    test "rejects an email containing inner whitespace after trimming" do
      changeset = PasswordResetRequestForm.changeset(%{"email" => "  has space@example.com  "})

      refute changeset.valid?
      assert errors_on(changeset) == %{email: ["must have the @ sign and no spaces"]}
    end

    test "matches the User changeset's email format error exactly" do
      attrs = %{"email" => "not-an-email"}

      form_error = PasswordResetRequestForm.changeset(attrs).errors[:email]
      user_error = User.changeset(%User{}, attrs).errors[:email]

      assert form_error == {"must have the @ sign and no spaces", [validation: :format]}
      assert form_error == user_error
    end

    test "rejects an email longer than 160 characters" do
      email = String.duplicate("a", 157) <> "@b.c"
      assert String.length(email) == 161

      changeset = PasswordResetRequestForm.changeset(%{"email" => email})

      refute changeset.valid?
      assert errors_on(changeset) == %{email: ["should be at most 160 character(s)"]}
    end

    test "accepts an email of exactly 160 characters" do
      email = String.duplicate("a", 156) <> "@b.c"
      assert String.length(email) == 160

      changeset = PasswordResetRequestForm.changeset(%{"email" => email})

      assert changeset.valid?
      assert changeset.errors == []
    end

    test "existing and absent addresses have identical validation" do
      user = user_fixture()

      existing = PasswordResetRequestForm.changeset(%{"email" => user.email})
      absent = PasswordResetRequestForm.changeset(%{"email" => "absent-" <> user.email})

      assert existing.valid?
      assert absent.valid?
      assert existing.errors == []
      assert absent.errors == []
    end

    test "an address belonging to an account produces no uniqueness metadata" do
      user = user_fixture()

      changeset = PasswordResetRequestForm.changeset(%{"email" => user.email})

      assert changeset.valid?
      assert changeset.errors == []
      assert changeset.constraints == []
    end

    test "supports action-less and :validate action states for interaction timing" do
      clean = PasswordResetRequestForm.changeset(%{})

      assert clean.action == nil
      refute clean.valid?

      assert {:error, validated} = Ecto.Changeset.apply_action(clean, :validate)
      assert validated.action == :validate
      refute validated.valid?
      assert errors_on(validated) == %{email: ["can't be blank"]}
    end

    test "apply_action(:insert) returns the embedded struct for valid input" do
      assert {:ok, %PasswordResetRequestForm{email: "user@example.com"}} =
               %{"email" => "  user@example.com  "}
               |> PasswordResetRequestForm.changeset()
               |> Ecto.Changeset.apply_action(:insert)
    end

    test "drives to_form/2 with as: :user as the step-6 LiveView will" do
      form =
        %{"email" => "user@example.com"}
        |> PasswordResetRequestForm.changeset()
        |> Phoenix.Component.to_form(as: :user)

      assert form.name == "user"
      assert form.id == "user"
      assert form[:email].value == "user@example.com"
    end
  end

  describe "change_password_reset_request/1" do
    test "returns the embedded form changeset with default empty attrs" do
      assert %Ecto.Changeset{data: %PasswordResetRequestForm{}} =
               changeset = Accounts.change_password_reset_request()

      refute changeset.valid?
      assert changeset.action == nil
    end

    test "delegates attrs and returns the same changeset as the form object" do
      attrs = %{"email" => "  user@example.com  "}

      delegated = Accounts.change_password_reset_request(attrs)
      direct = PasswordResetRequestForm.changeset(attrs)

      # Field-by-field: the format regex compiles per invocation, so raw
      # struct equality is never stable for changesets with format rules.
      assert delegated.action == direct.action
      assert delegated.changes == direct.changes
      assert delegated.errors == direct.errors
      assert delegated.constraints == direct.constraints
      assert delegated.data == direct.data
      assert delegated.valid? == direct.valid?
      assert get_field(delegated, :email) == "user@example.com"
    end

    test "delegate validation does not vary with account existence" do
      email = unique_user_email()

      before = Accounts.change_password_reset_request(%{"email" => email})
      _user = user_fixture(email: email)
      after_create = Accounts.change_password_reset_request(%{"email" => email})

      assert before.valid?
      assert after_create.valid?
      assert after_create.errors == before.errors
      assert after_create.constraints == before.constraints
    end
  end
end
