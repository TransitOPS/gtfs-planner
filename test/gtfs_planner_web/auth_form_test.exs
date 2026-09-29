defmodule GtfsPlannerWeb.AuthFormTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Accounts.User
  alias GtfsPlannerWeb.AuthForm

  defp password_form(params) do
    %User{}
    |> User.password_changeset(params, hash_password: false)
    |> Map.put(:action, :validate)
    |> Phoenix.Component.to_form(as: "user")
  end

  describe "password_error/2" do
    test "asks for a password when it is blank" do
      assert AuthForm.password_error({"can't be blank", validation: :required}) ==
               "Enter a password."
    end

    test "uses the caller's sentence when the password is blank" do
      assert AuthForm.password_error(
               {"can't be blank", validation: :required},
               "Enter a new password."
             ) == "Enter a new password."
    end

    test "states the minimum length from the changeset" do
      error =
        {"should be at least %{count} character(s)", count: 12, validation: :length, kind: :min}

      assert AuthForm.password_error(error) == "Use at least 12 characters."
    end

    test "states the maximum length from the changeset" do
      error =
        {"should be at most %{count} character(s)", count: 72, validation: :length, kind: :max}

      assert AuthForm.password_error(error) == "Use 72 characters or fewer."
    end

    test "falls back to the changeset message for a rule it does not know" do
      assert AuthForm.password_error({"is invalid", validation: :format}) == "is invalid"
    end
  end

  describe "confirmation_error/2" do
    @mismatch {"does not match password", validation: :confirmation}

    test "asks for the same password in both fields when they differ" do
      assert AuthForm.confirmation_error(@mismatch, %{"password_confirmation" => "other"}) ==
               "Passwords don't match. Type the same password in both fields."
    end

    test "asks for the password again when the confirmation is blank" do
      assert AuthForm.confirmation_error(@mismatch, %{"password_confirmation" => ""}) ==
               "Enter the password again."
    end

    test "treats a whitespace-only confirmation as blank" do
      assert AuthForm.confirmation_error(@mismatch, %{"password_confirmation" => "   "}) ==
               "Enter the password again."
    end

    test "treats missing params as a blank confirmation" do
      assert AuthForm.confirmation_error(@mismatch, nil) == "Enter the password again."
    end

    test "falls back to the changeset message for a rule it does not know" do
      assert AuthForm.confirmation_error({"is invalid", validation: :format}, %{}) ==
               "is invalid"
    end
  end

  describe "used_errors/2" do
    test "maps the errors of a field the person has used" do
      form = password_form(%{"password" => "short"})

      assert AuthForm.used_errors(form[:password], &AuthForm.password_error/1) ==
               ["Use at least 12 characters."]
    end

    test "returns nothing for a field the person has not used" do
      form = password_form(%{"password" => "short", "_unused_password" => ""})

      assert AuthForm.used_errors(form[:password], &AuthForm.password_error/1) == []
    end
  end

  describe "defer_blank_errors/1" do
    test "marks an empty field as unused" do
      assert AuthForm.defer_blank_errors(%{"password" => ""}) ==
               %{"password" => "", "_unused_password" => ""}
    end

    test "marks a whitespace-only field as unused" do
      assert AuthForm.defer_blank_errors(%{"email" => "  "}) ==
               %{"email" => "  ", "_unused_email" => ""}
    end

    test "leaves a field with a value used" do
      assert AuthForm.defer_blank_errors(%{"password" => "secret"}) == %{"password" => "secret"}
    end

    test "does not mark a marker again" do
      params = %{"password" => "", "_unused_password" => ""}

      assert AuthForm.defer_blank_errors(params) == params
    end

    test "leaves values that are not strings alone" do
      params = %{"_target" => ["user", "password"]}

      assert AuthForm.defer_blank_errors(params) == params
    end

    test "keeps an empty field's errors out of the form until submit" do
      form = password_form(AuthForm.defer_blank_errors(%{"password" => ""}))

      assert AuthForm.used_errors(form[:password], &AuthForm.password_error/1) == []
    end
  end

  describe "sanitize_secrets/1" do
    test "drops both passwords but keeps errors and other values" do
      changeset =
        %User{}
        |> User.password_changeset(
          %{"password" => "short", "password_confirmation" => "other", "email" => "a@b.co"},
          hash_password: false
        )

      sanitized = AuthForm.sanitize_secrets(changeset)

      assert sanitized.params == %{"email" => "a@b.co"}
      assert sanitized.changes == %{}
      assert sanitized.errors == changeset.errors
    end
  end
end
