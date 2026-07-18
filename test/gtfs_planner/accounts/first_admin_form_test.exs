defmodule GtfsPlanner.Accounts.FirstAdminFormTest do
  use GtfsPlanner.DataCase, async: true

  import ExUnit.CaptureLog

  alias GtfsPlanner.Accounts.FirstAdminForm
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Organizations.Organization

  @valid_attrs %{
    "email" => "admin@example.com",
    "password" => "valid password 123",
    "password_confirmation" => "valid password 123",
    "organization_name" => "Demo Org",
    "organization_alias" => "Demo Alias"
  }

  @base_message "Setup could not be completed. Please try again."

  defp valid_changeset, do: FirstAdminForm.changeset(@valid_attrs)

  describe "changeset/1" do
    test "is valid with complete matching input and casts all five browser fields" do
      changeset = FirstAdminForm.changeset(@valid_attrs)

      assert changeset.valid?
      assert get_field(changeset, :email) == "admin@example.com"
      assert get_field(changeset, :password) == "valid password 123"
      assert get_field(changeset, :password_confirmation) == "valid password 123"
      assert get_field(changeset, :organization_name) == "Demo Org"
      assert get_field(changeset, :organization_alias) == "Demo Alias"
    end

    test "combines administrator and organization errors under browser-facing keys" do
      changeset =
        FirstAdminForm.changeset(%{
          "email" => "not-an-email",
          "password" => "short",
          "password_confirmation" => "short",
          "organization_name" => "",
          "organization_alias" => ""
        })

      refute changeset.valid?

      assert errors_on(changeset) == %{
               email: ["must have the @ sign and no spaces"],
               password: ["should be at least 12 character(s)"],
               organization_name: ["can't be blank"],
               organization_alias: ["can't be blank"]
             }

      refute Keyword.has_key?(changeset.errors, :name)
      refute Keyword.has_key?(changeset.errors, :alias)
    end

    test "preserves domain error metadata and source order" do
      changeset =
        FirstAdminForm.changeset(%{
          "email" => "not-an-email",
          "password" => "short",
          "password_confirmation" => "short",
          "organization_name" => "",
          "organization_alias" => ""
        })

      assert Keyword.keys(changeset.errors) == [
               :password,
               :email,
               :organization_alias,
               :organization_name
             ]

      assert {"should be at least %{count} character(s)", password_meta} =
               changeset.errors[:password]

      assert password_meta[:count] == 12
      assert password_meta[:validation] == :length
      assert password_meta[:kind] == :min

      assert {"must have the @ sign and no spaces", email_meta} = changeset.errors[:email]
      assert email_meta[:validation] == :format
    end

    test "requires password confirmation when the parameter is missing" do
      attrs = Map.delete(@valid_attrs, "password_confirmation")

      changeset = FirstAdminForm.changeset(attrs)

      refute changeset.valid?

      assert changeset.errors == [
               password_confirmation: {"does not match password", [validation: :required]}
             ]
    end

    test "rejects a confirmation that does not match the password without persisting" do
      attrs = Map.put(@valid_attrs, "password_confirmation", "different password 123")

      changeset = FirstAdminForm.changeset(attrs)

      refute changeset.valid?

      assert changeset.errors == [
               password_confirmation: {"does not match password", [validation: :confirmation]}
             ]

      assert Repo.aggregate(User, :count) == 0
      assert Repo.aggregate(Organization, :count) == 0
    end
  end

  describe "registration_attrs/1" do
    test "converts a valid changeset into explicit user and organization attributes" do
      changeset = FirstAdminForm.changeset(@valid_attrs)

      assert FirstAdminForm.registration_attrs(changeset) == %{
               user: %{email: "admin@example.com", password: "valid password 123"},
               organization: %{name: "Demo Org", alias: "Demo Alias"}
             }
    end

    test "raises for an invalid changeset" do
      changeset = FirstAdminForm.changeset(%{})

      assert_raise FunctionClauseError, fn ->
        FirstAdminForm.registration_attrs(changeset)
      end
    end
  end

  describe "from_transaction_error/3" do
    test "remaps a user constraint changeset onto :email preserving metadata" do
      source =
        %User{}
        |> User.registration_changeset(
          %{email: "taken@example.com", password: "valid password 123"},
          hash_password: false
        )
        |> add_error(:email, "has already been taken",
          constraint: :unique,
          constraint_name: "users_email_index"
        )

      {updated, log} =
        with_log(fn ->
          FirstAdminForm.from_transaction_error(valid_changeset(), :user, source)
        end)

      assert updated.errors[:email] ==
               {"has already been taken",
                [constraint: :unique, constraint_name: "users_email_index"]}

      refute updated.valid?
      refute log =~ "First admin registration failed"
    end

    test "remaps an organization constraint changeset onto :organization_alias" do
      source =
        %Organization{}
        |> Organization.changeset(%{name: "Demo Org", alias: "demo-org"})
        |> add_error(:alias, "has already been taken",
          constraint: :unique,
          constraint_name: "organizations_alias_index"
        )

      updated = FirstAdminForm.from_transaction_error(valid_changeset(), :org, source)

      assert updated.errors[:organization_alias] ==
               {"has already been taken",
                [constraint: :unique, constraint_name: "organizations_alias_index"]}

      refute Keyword.has_key?(updated.errors, :alias)
      refute Keyword.has_key?(updated.errors, :name)
    end

    test "maps unrecognized domain error keys to :base" do
      source =
        %User{}
        |> User.registration_changeset(
          %{email: "admin@example.com", password: "valid password 123"},
          hash_password: false
        )
        |> add_error(:hashed_password, "is invalid")

      updated = FirstAdminForm.from_transaction_error(valid_changeset(), :user, source)

      assert updated.errors[:base] == {"is invalid", []}
      refute Keyword.has_key?(updated.errors, :hashed_password)
    end

    test "adds only the generic base error and logs safe diagnostics for a non-domain failure" do
      changeset =
        FirstAdminForm.changeset(%{
          "email" => "sentinel-email@example.com",
          "password" => "sentinel password 123",
          "password_confirmation" => "sentinel password 123",
          "organization_name" => "Sentinel Org",
          "organization_alias" => "sentinel-org"
        })

      {updated, log} =
        with_log(fn ->
          FirstAdminForm.from_transaction_error(
            changeset,
            :version,
            {:error, "sentinel-raw-adapter-reason"}
          )
        end)

      assert updated.errors == [base: {@base_message, []}]
      refute updated.valid?

      assert log =~ "first_admin_operation=version"
      assert log =~ "failure_class=tuple"
      refute log =~ "sentinel-email@example.com"
      refute log =~ "sentinel password 123"
      refute log =~ "sentinel-raw-adapter-reason"
    end

    test "ignores changeset errors from non-domain operations" do
      membership_reason = Organization.changeset(%Organization{}, %{})

      {updated, log} =
        with_log(fn ->
          FirstAdminForm.from_transaction_error(valid_changeset(), :membership, membership_reason)
        end)

      assert updated.errors == [base: {@base_message, []}]
      refute Keyword.has_key?(updated.errors, :organization_name)
      refute Keyword.has_key?(updated.errors, :organization_alias)

      assert log =~ "first_admin_operation=membership"
      assert log =~ "failure_class=changeset"
      refute log =~ "can't be blank"
    end

    test "classifies atom reasons" do
      {updated, log} =
        with_log(fn ->
          FirstAdminForm.from_transaction_error(valid_changeset(), :confirm_user, :timeout)
        end)

      assert updated.errors == [base: {@base_message, []}]
      assert log =~ "first_admin_operation=confirm_user"
      assert log =~ "failure_class=atom"
      refute log =~ "timeout"
    end

    test "classifies exception reasons without exposing their message" do
      exception = %RuntimeError{message: "sentinel-exception-message"}

      {updated, log} =
        with_log(fn ->
          FirstAdminForm.from_transaction_error(valid_changeset(), :version, exception)
        end)

      assert updated.errors == [base: {@base_message, []}]
      assert log =~ "first_admin_operation=version"
      assert log =~ "failure_class=exception"
      refute log =~ "sentinel-exception-message"
    end

    test "classifies unexpected reasons under an unexpected operation as other" do
      {updated, log} =
        with_log(fn ->
          FirstAdminForm.from_transaction_error(
            valid_changeset(),
            :user,
            "sentinel-binary-reason"
          )
        end)

      assert updated.errors == [base: {@base_message, []}]
      assert log =~ "first_admin_operation=user"
      assert log =~ "failure_class=other"
      refute log =~ "sentinel-binary-reason"
    end
  end

  describe "sanitize_secrets/1" do
    test "removes secret params and changes while retaining errors and non-secret fields" do
      changeset =
        FirstAdminForm.changeset(%{
          "email" => "admin@example.com",
          "password" => "short",
          "password_confirmation" => "short",
          "organization_name" => "Demo Org",
          "organization_alias" => "demo-org"
        })

      sanitized = FirstAdminForm.sanitize_secrets(changeset)

      assert sanitized.params == %{
               "email" => "admin@example.com",
               "organization_name" => "Demo Org",
               "organization_alias" => "demo-org"
             }

      assert sanitized.changes == %{
               email: "admin@example.com",
               organization_name: "Demo Org",
               organization_alias: "demo-org"
             }

      assert sanitized.errors == changeset.errors
      refute sanitized.valid?
    end

    test "removes atom password params and tolerates absent params" do
      changeset = %{
        valid_changeset()
        | params: %{
            "email" => "admin@example.com",
            "password" => "string-secret",
            :password => "atom-secret",
            "password_confirmation" => "string-secret",
            :password_confirmation => "atom-secret"
          }
      }

      sanitized = FirstAdminForm.sanitize_secrets(changeset)

      assert sanitized.params == %{"email" => "admin@example.com"}

      paramless = Ecto.Changeset.change(%FirstAdminForm{})

      assert FirstAdminForm.sanitize_secrets(paramless).params == nil
    end
  end
end
